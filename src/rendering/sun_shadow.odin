package rendering

import "core:math"
import "core:math/linalg/glsl"
import gl "vendor:OpenGL"

import dbg "../core/gl_debug"
import log "../core/log"
import gl_state "../core/gl_state"
import mt "../core/math_types"
import tracy "../core/tracy"
import shader "./shader"

@(private)
srcloc_sun_shadow := tracy.Source_Location_Data{
	name     = "Sun_Shadow_Render",
	function = "sun_shadow_render",
	file     = #file,
	line     = #line,
	color    = 0xD08770,
}

// ─── Sun Detection Results & Math ──────────────────────────────────────────

Sun_Detection :: struct {
	direction:      mt.Vec3,
	azimuth:        f32,
	elevation:      f32,
	peak_intensity: f32,
	confidence:     i32,
	sun_detected:   bool,
}

// Fallback fixed direction: 45 deg elevation, south (+Z)
SUN_FALLBACK_DIRECTION :: mt.Vec3{0.0, 0.70710678, 0.70710678}
SUN_FALLBACK_AZIMUTH   :: 90.0
SUN_FALLBACK_ELEVATION :: 45.0

// Convert UV to equirectangular world direction (equivalent to shader uvToDir)
sun_uv_to_dir :: proc(uv: [2]f32) -> mt.Vec3 {
	phi := (uv.x - 0.5) * (2.0 * math.PI)
	theta := (uv.y - 0.5) * math.PI
	cos_theta := math.cos(theta)
	return mt.Vec3{
		cos_theta * math.cos(phi),
		math.sin(theta),
		cos_theta * math.sin(phi),
	}
}

// Convert world direction to equirectangular UV (equivalent to shader dirToUV)
sun_dir_to_uv :: proc(v: mt.Vec3) -> [2]f32 {
	phi: f32 = 0.0
	if math.abs(v.z) >= 1e-5 || math.abs(v.x) >= 1e-5 {
		phi = math.atan2(v.z, v.x)
	}
	theta := math.asin(clamp(v.y, -1.0, 1.0))
	u := phi / (2.0 * math.PI) + 0.5
	v_coord := theta / math.PI + 0.5
	return [2]f32{u, v_coord}
}

// Convert azimuth and elevation in degrees to normalized world direction vector
sun_angles_to_dir :: proc(azimuth_deg, elevation_deg: f32) -> mt.Vec3 {

	az_rad := math.to_radians(azimuth_deg)
	el_rad := math.to_radians(elevation_deg)
	cos_el := math.cos(el_rad)
	return mt.Vec3{
		cos_el * math.cos(az_rad),
		math.sin(el_rad),
		cos_el * math.sin(az_rad),
	}
}


@(private)
get_fp16_val :: proc(val_u16: u16) -> f32 {
	f := f32(transmute(f16)val_u16)
	if math.is_nan(f) do return 0.0
	if math.is_inf(f) do return 65504.0
	return max(0.0, f)
}

// Analyzes decoded HDR pixels (in FP16 format) on CPU to detect the dominant sun direction.
sun_detect_from_fp16 :: proc(half_data: [^]u16, width, height: i32) -> Sun_Detection {
	result: Sun_Detection
	result.direction = SUN_FALLBACK_DIRECTION
	result.azimuth = SUN_FALLBACK_AZIMUTH
	result.elevation = SUN_FALLBACK_ELEVATION
	result.peak_intensity = 0.0
	result.confidence = 0
	result.sun_detected = false

	if half_data == nil || width <= 0 || height <= 0 {
		return result
	}

	total_pixels := int(width) * int(height)
	max_lum: f32 = 0.0
	sum_lum: f64 = 0.0

	// Step 1: Scan max luminance and mean luminance
	for y in 0 ..< int(height) {
		for x in 0 ..< int(width) {
			idx := (y * int(width) + x) * 4
			r := get_fp16_val(half_data[idx + 0])
			g := get_fp16_val(half_data[idx + 1])
			b := get_fp16_val(half_data[idx + 2])
			lum := 0.2126 * r + 0.7152 * g + 0.0722 * b
			if lum > max_lum {
				max_lum = lum
			}
			sum_lum += f64(lum)
		}
	}

	result.peak_intensity = max_lum
	if max_lum <= 0.001 {
		return result
	}

	mean_lum := f32(sum_lum / f64(total_pixels))

	// Step 2: Build log2 histogram for 99.99th percentile
	HIST_BINS :: 1024
	LOG_MIN :: -14.0 // 2^-14 ~= 0.00006
	LOG_MAX :: 17.0  // 2^17  = 131072
	hist: [HIST_BINS]int

	for y in 0 ..< int(height) {
		for x in 0 ..< int(width) {
			idx := (y * int(width) + x) * 4
			r := get_fp16_val(half_data[idx + 0])
			g := get_fp16_val(half_data[idx + 1])
			b := get_fp16_val(half_data[idx + 2])
			lum := 0.2126 * r + 0.7152 * g + 0.0722 * b
			if lum > 0.0001 {
				log_val := math.log2(lum)
				norm_val := (log_val - LOG_MIN) / (LOG_MAX - LOG_MIN)
				bin := clamp(int(norm_val * f32(HIST_BINS)), 0, HIST_BINS - 1)
				hist[bin] += 1
			} else {
				hist[0] += 1
			}
		}
	}

	// 99.99th percentile corresponds to top 0.01% brightest pixels
	target_top_count := max(1, int(f64(total_pixels) * 0.0001))
	cum_count := 0
	threshold_bin := HIST_BINS - 1
	for b := HIST_BINS - 1; b >= 0; b -= 1 {
		cum_count += hist[b]
		if cum_count >= target_top_count {
			threshold_bin = b
			break
		}
	}

	bin_norm := (f32(threshold_bin) + 0.5) / f32(HIST_BINS)
	threshold_p9999 := math.pow(f32(2.0), LOG_MIN + bin_norm * (LOG_MAX - LOG_MIN))

	// Adaptative threshold: isolate high-intensity hotspot if direct sun exists
	threshold_lum := max(threshold_p9999, max_lum * 0.10)

	// Step 3: Compute luminance-weighted direction centroid
	acc_dir := mt.Vec3{0, 0, 0}
	conf_count: i32 = 0

	for y in 0 ..< int(height) {
		for x in 0 ..< int(width) {
			idx := (y * int(width) + x) * 4
			r := get_fp16_val(half_data[idx + 0])
			g := get_fp16_val(half_data[idx + 1])
			b := get_fp16_val(half_data[idx + 2])
			lum := 0.2126 * r + 0.7152 * g + 0.0722 * b
			if lum >= threshold_lum && lum > 0.0 {
				u := (f32(x) + 0.5) / f32(width)
				v := (f32(y) + 0.5) / f32(height)
				dir := sun_uv_to_dir([2]f32{u, v})
				acc_dir += dir * lum
				conf_count += 1
			}
		}
	}

	result.confidence = conf_count

	len_acc := mt.vec3_length(acc_dir)
	cand_dir: mt.Vec3
	if len_acc > 1e-6 {
		cand_dir = acc_dir / len_acc
	} else {
		cand_dir = SUN_FALLBACK_DIRECTION
	}

	raw_azimuth := math.to_degrees(math.atan2(cand_dir.z, cand_dir.x))
	raw_elevation := math.to_degrees(math.asin(clamp(cand_dir.y, -1.0, 1.0)))

	// Direct sunlight criteria:
	// - Elevation must be above horizon (> 5.0 deg)
	// - Peak luminance must indicate natural or strong directional source (>= 500.0)
	// - Clear contrast ratio vs average luminance
	ratio := max_lum / max(0.01, mean_lum)
	is_sun := (raw_elevation > 5.0) && (max_lum >= 500.0) && (ratio >= 500.0) && (conf_count > 0)

	if is_sun {
		result.direction = cand_dir
		result.azimuth = raw_azimuth
		result.elevation = raw_elevation
		result.sun_detected = true
	} else {
		// Indoor/diffuse envmap fallback
		result.direction = SUN_FALLBACK_DIRECTION
		result.azimuth = SUN_FALLBACK_AZIMUTH
		result.elevation = SUN_FALLBACK_ELEVATION
		result.sun_detected = false
	}

	return result
}

// ─── Orthographic Sun Shadow Map Subsystem ───────────────────────────────────

SUN_SHADOW_RESOLUTIONS :: [4]i32{512, 1024, 2048, 4096}
DEFAULT_SUN_SHADOW_RES :: 1024

Sun_Shadow :: struct {
	fbo:              u32,
	depth_texture:    u32, // GL_TEXTURE_2D, GL_DEPTH_COMPONENT32F
	resolution:       i32,
	near_plane:       f32,
	far_plane:        f32,
	ortho_bounds:     [4]f32, // left, right, bottom, top
	view_matrix:      mt.Mat4,
	proj_matrix:      mt.Mat4,
	view_proj:        mt.Mat4,

	detection:        Sun_Detection,
	is_dirty:         bool,
	enabled:          bool,

	// Shaders for analytical billboard shadow casting
	program:          u32,
	loc_view:         i32,
	loc_proj:         i32,
	loc_sun_dir:      i32,

	// 2D Preview Atlas for ImGui Inspection
	preview_fbo:      u32,
	preview_tex:      u32, // GL_RGBA8, 512 x 512
	preview_w:        i32,
	preview_h:        i32,
	preview_program:  u32,
	preview_triangle: Fullscreen_Triangle,
	preview_dirty:    bool,
}

@(private)
sun_shadow_create_fbo_texture :: proc(ss: ^Sun_Shadow, resolution: i32) -> bool {
	ss.resolution = resolution

	// 1. Create Hardware Depth 2D Texture (GL_DEPTH_COMPONENT32F)
	gl.GenTextures(1, &ss.depth_texture)
	gl.BindTexture(gl.TEXTURE_2D, ss.depth_texture)
	gl.TexImage2D(
		gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT32F,
		resolution, resolution, 0,
		gl.DEPTH_COMPONENT, gl.FLOAT, nil,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_BORDER)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_BORDER)
	border_color := [4]f32{1.0, 1.0, 1.0, 1.0}
	gl.TexParameterfv(gl.TEXTURE_2D, gl.TEXTURE_BORDER_COLOR, &border_color[0])
	gl.BindTexture(gl.TEXTURE_2D, 0)

	// 2. Create Depth FBO
	gl.GenFramebuffers(1, &ss.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, ss.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, ss.depth_texture, 0)
	gl.DrawBuffer(gl.NONE)
	gl.ReadBuffer(gl.NONE)

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("render.shadow", "Sun shadow FBO incomplete: 0x%X", status)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return false
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	dbg.object_label(gl.FRAMEBUFFER, ss.fbo, "Sun_Shadow_FBO")
	dbg.object_label(gl.TEXTURE, ss.depth_texture, "Sun_Shadow_Depth_Tex")
	return true
}

@(private)
sun_shadow_destroy_fbo_texture :: proc(ss: ^Sun_Shadow) {
	if ss.fbo != 0 {
		gl.DeleteFramebuffers(1, &ss.fbo)
		ss.fbo = 0
	}
	if ss.depth_texture != 0 {
		gl.DeleteTextures(1, &ss.depth_texture)
		ss.depth_texture = 0
	}
}

sun_shadow_create :: proc(ss: ^Sun_Shadow, resolution: i32 = DEFAULT_SUN_SHADOW_RES) -> bool {
	ss.enabled = true
	ss.is_dirty = true
	ss.detection = Sun_Detection{
		direction      = SUN_FALLBACK_DIRECTION,
		azimuth        = SUN_FALLBACK_AZIMUTH,
		elevation      = SUN_FALLBACK_ELEVATION,
		peak_intensity = 0.0,
		confidence     = 0,
		sun_detected   = false,
	}

	if !sun_shadow_create_fbo_texture(ss, resolution) {
		return false
	}

	// Load shadow casting shaders
	ss.program = shader.load_program("shaders/sun_shadow.vert", "shaders/sun_shadow.frag") or_return
	ss.loc_view    = gl.GetUniformLocation(ss.program, "u_view")
	ss.loc_proj    = gl.GetUniformLocation(ss.program, "u_projection")
	ss.loc_sun_dir = gl.GetUniformLocation(ss.program, "u_sun_dir")

	// Create 2D Preview Atlas Resources (512x512)
	ss.preview_w = 512
	ss.preview_h = 512
	gl.GenTextures(1, &ss.preview_tex)
	gl.BindTexture(gl.TEXTURE_2D, ss.preview_tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, ss.preview_w, ss.preview_h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenFramebuffers(1, &ss.preview_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, ss.preview_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, ss.preview_tex, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	ss.preview_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/debug_sun_shadow_preview.frag") or_return
	gl.UseProgram(ss.preview_program)
	gl.Uniform1i(gl.GetUniformLocation(ss.preview_program, "u_sun_depth_map"), 0)
	gl.UseProgram(0)

	fullscreen_triangle_create(&ss.preview_triangle)
	dbg.object_label(gl.TEXTURE, ss.preview_tex, "Sun_Shadow_Preview_Tex")

	ss.preview_dirty = true
	log.log_info("render.shadow", "Sun directional shadow map renderer created (%dx%d)", resolution, resolution)
	return true
}

sun_shadow_resize :: proc(ss: ^Sun_Shadow, new_resolution: i32) -> bool {
	if ss.resolution == new_resolution && ss.fbo != 0 do return true
	sun_shadow_destroy_fbo_texture(ss)
	if !sun_shadow_create_fbo_texture(ss, new_resolution) {
		return false
	}
	ss.is_dirty = true
	ss.preview_dirty = true
	log.log_debug("render.shadow", "Sun shadow map resized to %dx%d", new_resolution, new_resolution)
	return true
}

sun_shadow_destroy :: proc(ss: ^Sun_Shadow) {
	fullscreen_triangle_destroy(&ss.preview_triangle)

	if ss.preview_fbo != 0 {
		gl.DeleteFramebuffers(1, &ss.preview_fbo)
		ss.preview_fbo = 0
	}
	if ss.preview_tex != 0 {
		gl.DeleteTextures(1, &ss.preview_tex)
		ss.preview_tex = 0
	}
	if ss.preview_program != 0 {
		gl.DeleteProgram(ss.preview_program)
		ss.preview_program = 0
	}
	if ss.program != 0 {
		gl.DeleteProgram(ss.program)
		ss.program = 0
	}
	sun_shadow_destroy_fbo_texture(ss)
}

// Compute stable orthonormal basis and tight orthographic projection fit on sphere scene
sun_shadow_update_matrices :: proc(ss: ^Sun_Shadow, spheres: ^Instanced_Spheres) {
	sun_dir := ss.detection.direction
	len_dir := mt.vec3_length(sun_dir)
	if len_dir < 1e-5 {
		sun_dir = SUN_FALLBACK_DIRECTION
	} else {
		sun_dir = sun_dir / len_dir
	}

	// Light camera looks in direction: -sun_dir
	forward := -sun_dir
	up: mt.Vec3
	if math.abs(forward.y) > 0.99 {
		up = mt.Vec3{0.0, 0.0, 1.0}
	} else {
		up = mt.Vec3{0.0, 1.0, 0.0}
	}

	// Compute scene bounds
	scene_center := mt.Vec3{0.0, 0.0, 0.0}
	count := int(spheres.count) if spheres != nil else 0

	if count > 0 {
		models := spheres.instances.model[:]
		sum_pos := mt.Vec3{0.0, 0.0, 0.0}
		for i in 0 ..< count {
			sum_pos += mt.Vec3{models[i][3][0], models[i][3][1], models[i][3][2]}
		}
		scene_center = sum_pos / f32(count)
	}

	// Eye positioned along sun direction at suitable offset
	eye := scene_center + sun_dir * 50.0
	ss.view_matrix = mt.look_at(eye, scene_center, up)

	// Project all spheres into light view space to compute tight AABB
	min_x: f32 = 1e9
	max_x: f32 = -1e9
	min_y: f32 = 1e9
	max_y: f32 = -1e9
	min_z: f32 = 1e9
	max_z: f32 = -1e9

	if count > 0 {
		models := spheres.instances.model[:]
		for i in 0 ..< count {
			center_w := mt.Vec3{models[i][3][0], models[i][3][1], models[i][3][2]}
			scale_x := mt.vec3_length(mt.Vec3{models[i][0][0], models[i][0][1], models[i][0][2]})
			scale_y := mt.vec3_length(mt.Vec3{models[i][1][0], models[i][1][1], models[i][1][2]})
			scale_z := mt.vec3_length(mt.Vec3{models[i][2][0], models[i][2][1], models[i][2][2]})
			radius := max(scale_x, max(scale_y, scale_z))

			center_v4 := ss.view_matrix * mt.Vec4{center_w.x, center_w.y, center_w.z, 1.0}
			cv := center_v4.xyz

			min_x = min(min_x, cv.x - radius)
			max_x = max(max_x, cv.x + radius)
			min_y = min(min_y, cv.y - radius)
			max_y = max(max_y, cv.y + radius)
			min_z = min(min_z, cv.z - radius)
			max_z = max(max_z, cv.z + radius)
		}
	} else {
		min_x = -15.0; max_x = 15.0
		min_y = -15.0; max_y = 15.0
		min_z = -65.0; max_z = -35.0
	}

	// 5% margin on bounds
	margin_x := max(0.5, (max_x - min_x) * 0.05)
	margin_y := max(0.5, (max_y - min_y) * 0.05)
	left := min_x - margin_x
	right := max_x + margin_x
	bottom := min_y - margin_y
	top := max_y + margin_y

	// In OpenGL view space, camera looks down -Z.
	// Nearest point has largest Z (closest to camera): dist_near = -max_z.
	// Furthest point has smallest Z: dist_far = -min_z.
	dist_near := -max_z
	dist_far  := -min_z
	depth_range := max(1.0, dist_far - dist_near)
	margin_z := depth_range * 0.05

	near := max(0.1, dist_near - margin_z)
	far  := dist_far + margin_z

	ss.near_plane = near
	ss.far_plane = far
	ss.ortho_bounds = [4]f32{left, right, bottom, top}

	ss.proj_matrix = glsl.mat4Ortho3d(left, right, bottom, top, near, far)
	ss.view_proj = ss.proj_matrix * ss.view_matrix
}

// Renders the scene's instanced spheres into the directional shadow map
sun_shadow_render :: proc(
	ss: ^Sun_Shadow,
	spheres: ^Instanced_Spheres,
	billboard: ^Billboard,
	force: bool = false,
) {
	if !ss.enabled || ss.fbo == 0 do return
	if !ss.is_dirty && !force do return

	zone := tracy.zone_begin(&srcloc_sun_shadow)
	defer tracy.zone_end(zone)

	sun_shadow_update_matrices(ss, spheres)

	dbg.push_group("Sun_Shadow_Pass")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, ss.fbo)
	gl.Viewport(0, 0, ss.resolution, ss.resolution)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.DepthMask(true)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.BLEND)

	gl.Clear(gl.DEPTH_BUFFER_BIT)

	gl.UseProgram(ss.program)
	gl.UniformMatrix4fv(ss.loc_view, 1, false, &ss.view_matrix[0][0])
	gl.UniformMatrix4fv(ss.loc_proj, 1, false, &ss.proj_matrix[0][0])
	gl.Uniform3f(ss.loc_sun_dir, ss.detection.direction.x, ss.detection.direction.y, ss.detection.direction.z)

	instanced_bind(spheres)
	gl.BindVertexArray(billboard.vao)
	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, spheres.count)

	gl.BindVertexArray(0)
	gl.UseProgram(0)

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	ss.is_dirty = false
	ss.preview_dirty = true
}

// Updates the 2D preview texture for Dear ImGui display
sun_shadow_update_preview_atlas :: proc(ss: ^Sun_Shadow) {
	if ss.preview_fbo == 0 || ss.depth_texture == 0 do return

	dbg.push_group("Sun_Shadow_Preview_Pass")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])
	prev_depth := gl.IsEnabled(gl.DEPTH_TEST)
	prev_blend := gl.IsEnabled(gl.BLEND)

	gl.BindFramebuffer(gl.FRAMEBUFFER, ss.preview_fbo)
	gl.Viewport(0, 0, ss.preview_w, ss.preview_h)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(ss.preview_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, ss.depth_texture)

	fullscreen_triangle_draw(&ss.preview_triangle)

	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	if prev_depth do gl.Enable(gl.DEPTH_TEST)
	if prev_blend do gl.Enable(gl.BLEND)
	gl_state.reset()
	dbg.pop_group()

	ss.preview_dirty = false
}
