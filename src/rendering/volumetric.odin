package rendering

import gl "vendor:OpenGL"
import "core:math"

import dbg "../core/gl_debug"
import log "../core/log"
import gl_state "../core/gl_state"
import mt "../core/math_types"
import shader "./shader"

// Fullscreen quad vertices for volumetric raymarching
@(private, rodata)
volumetric_quad_verts := [6]f32{
	-1.0, -1.0,
	 3.0, -1.0,
	-1.0,  3.0,
}

// Phase 3 & 4: Volumetric Lighting & TAA Reprojection State
Volumetric_Renderer :: struct {
	enabled:                bool,
	fbo:                    u32, // Raw raymarching FBO
	raw_tex:                u32, // GL_RGBA16F, W/2 x H/2 (Raw newly raymarched in-scattering)
	width:                  i32, // Low-res width (W / 2)
	height:                 i32, // Low-res height (H / 2)
	full_width:             i32,
	full_height:            i32,

	// Physical medium parameters
	step_count:             i32,  // Raymarching steps (default 16, range 4..64)
	scattering_coeff:       f32,  // Scattering coefficient sigma_s (default 0.025)
	extinction_coeff:       f32,  // Extinction coefficient sigma_t (default 0.05)
	anisotropy_g:           f32,  // Henyey-Greenstein eccentricity g (default 0.55)
	intensity_mult:         f32,  // Volumetric master intensity multiplier (default 1.0)
	jitter_enabled:         bool, // Spatial/temporal ray jittering
	composite_in_scene:     bool, // Additively blend in-scattering directly into 3D scene viewport
	shadows_enabled:        bool, // Cast volumetric shadow shafts (God Rays) via shadow cubemap
	isolate_in_scene:       bool, // Debug mode: Isolate volumetric lighting (black background / no IBL)

	// Phase 4: TAA Temporal Reprojection & History Blending State
	taa_mode:               i32,  // 0: Off (Raw Jitter Grain), 1: Simple Blend (EMA), 2: TAA Reprojection
	taa_alpha:              f32,  // Current frame blend weight (default 0.20, range 0.05..1.0)
	taa_depth_threshold:    f32,  // Disocclusion depth tolerance in meters (default 0.80)
	taa_clamping_enabled:   bool, // 3x3 color neighborhood bounding box clamping
	history_valid:          bool, // False on reset / resize / camera teleport
	history_fbo:            [2]u32,
	history_tex:            [2]u32, // GL_RGBA16F, W/2 x H/2 (Ping-pong accumulated TAA buffer)
	history_idx:            int,
	acceptance_tex:         u32,    // GL_RGBA8, W/2 x H/2 (Debug view: Green/Red/Blue)
	prev_view_proj:         mt.Mat4,
	prev_inv_view_proj:     mt.Mat4,
	prev_cam_pos:           mt.Vec3,

	// Raymarching Shader & Uniform Locations
	program:                u32,
	composite_program:      u32,
	loc_inv_view_proj:      i32,
	loc_cam_pos:            i32,
	loc_near_plane:         i32,
	loc_far_plane:          i32,
	loc_frame_idx:          i32,
	loc_light_pos:          i32,
	loc_light_radius:       i32,
	loc_light_color:        i32,
	loc_light_intensity:    i32,
	loc_shadow_bias:        i32,
	loc_shadows_enabled:    i32,
	loc_step_count:         i32,
	loc_scattering_coeff:   i32,
	loc_extinction_coeff:   i32,
	loc_anisotropy_g:       i32,
	loc_intensity_mult:     i32,
	loc_jitter_enabled:     i32,

	// TAA Reprojection Shader & Uniform Locations
	taa_program:            u32,
	loc_taa_inv_view_proj:  i32,
	loc_taa_prev_view_proj: i32,
	loc_taa_cam_pos:        i32,
	loc_taa_prev_cam_pos:   i32,
	loc_taa_near_plane:     i32,
	loc_taa_far_plane:      i32,
	loc_taa_mode:           i32,
	loc_taa_alpha:          i32,
	loc_taa_depth_threshold: i32,
	loc_taa_clamping_enabled: i32,
	loc_taa_history_valid:  i32,

	// Preview RGBA texture & FBO for Dear ImGui Inspector
	preview_fbo:            u32,
	preview_tex:            u32, // GL_RGBA8, W/2 x H/2
	preview_program:        u32,
	preview_loc_boost:      i32,
	preview_loc_mode:       i32,
	preview_mode:           i32, // 0: Final In-Scattering, 1: Raw Pre-TAA Grain, 2: Heatmap, 3: TAA Acceptance, 4: Transmittance
	preview_exposure_boost: f32, // default 1.0 (range 1.0..10.0)
	preview_dirty:          bool,

	// Fullscreen Triangle VAO
	vao:                    u32,
	vbo:                    u32,
}

// Henyey-Greenstein Normalized Phase Function (phase == 1.0 when g == 0.0, ISO legacy)
// P(theta, g) = (1 - g^2) / (1 + g^2 - 2*g*cos(theta))^(3/2)
volumetric_henyey_greenstein :: proc(cos_theta, g: f32) -> f32 {
	g2 := g * g
	denom := 1.0 + g2 - 2.0 * g * cos_theta
	denom = max(denom, 0.0001)
	return (1.0 - g2) / (denom * math.sqrt(denom))
}

// Ray-Sphere intersection calculation (CPU analytic)
volumetric_intersect_ray_sphere :: proc(
	ray_orig, ray_dir, sphere_center: mt.Vec3,
	radius: f32,
) -> (hit: bool, t0, t1: f32) {
	oc := ray_orig - sphere_center
	b := mt.vec3_dot(ray_dir, oc)
	c := mt.vec3_dot(oc, oc) - radius * radius
	discr := b * b - c

	if discr < 0.0 {
		return false, 0.0, 0.0
	}

	sqrt_discr := math.sqrt(discr)
	return true, -b - sqrt_discr, -b + sqrt_discr
}

// Initializes the volumetric lighting pipeline and GPU resources
volumetric_create :: proc(vr: ^Volumetric_Renderer, full_width, full_height: i32) -> bool {
	vr.enabled = true
	vr.full_width = max(2, full_width)
	vr.full_height = max(2, full_height)
	vr.width = max(1, full_width / 2)
	vr.height = max(1, full_height / 2)

	vr.step_count = 16
	vr.scattering_coeff = 0.025
	vr.extinction_coeff = 0.05
	vr.anisotropy_g = 0.55
	vr.intensity_mult = 1.0
	vr.jitter_enabled = true
	vr.composite_in_scene = true
	vr.shadows_enabled = true

	// Phase 4 Defaults
	vr.taa_mode = 2 // TAA Reprojection
	vr.taa_alpha = 0.20
	vr.taa_depth_threshold = 0.80
	vr.taa_clamping_enabled = true
	vr.history_valid = false
	vr.history_idx = 0

	vr.preview_mode = 0
	vr.preview_exposure_boost = 1.0
	vr.preview_dirty = true

	// 1. Load Shaders
	vr.program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_raymarch.frag") or_return
	vr.loc_inv_view_proj    = gl.GetUniformLocation(vr.program, "u_inv_view_proj")
	vr.loc_cam_pos          = gl.GetUniformLocation(vr.program, "u_cam_pos")
	vr.loc_near_plane       = gl.GetUniformLocation(vr.program, "u_near_plane")
	vr.loc_far_plane        = gl.GetUniformLocation(vr.program, "u_far_plane")
	vr.loc_frame_idx        = gl.GetUniformLocation(vr.program, "u_frame_idx")
	vr.loc_light_pos        = gl.GetUniformLocation(vr.program, "u_light_pos")
	vr.loc_light_radius     = gl.GetUniformLocation(vr.program, "u_light_radius")
	vr.loc_light_color      = gl.GetUniformLocation(vr.program, "u_light_color")
	vr.loc_light_intensity  = gl.GetUniformLocation(vr.program, "u_light_intensity")
	vr.loc_shadow_bias      = gl.GetUniformLocation(vr.program, "u_shadow_bias")
	vr.loc_shadows_enabled  = gl.GetUniformLocation(vr.program, "u_shadows_enabled")
	vr.loc_step_count       = gl.GetUniformLocation(vr.program, "u_step_count")
	vr.loc_scattering_coeff = gl.GetUniformLocation(vr.program, "u_scattering_coeff")
	vr.loc_extinction_coeff = gl.GetUniformLocation(vr.program, "u_extinction_coeff")
	vr.loc_anisotropy_g     = gl.GetUniformLocation(vr.program, "u_anisotropy_g")
	vr.loc_intensity_mult   = gl.GetUniformLocation(vr.program, "u_intensity_mult")
	vr.loc_jitter_enabled   = gl.GetUniformLocation(vr.program, "u_jitter_enabled")

	// TAA Reprojection Program
	vr.taa_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_taa.frag") or_return
	vr.loc_taa_inv_view_proj   = gl.GetUniformLocation(vr.taa_program, "u_inv_view_proj")
	vr.loc_taa_prev_view_proj  = gl.GetUniformLocation(vr.taa_program, "u_prev_view_proj")
	vr.loc_taa_cam_pos         = gl.GetUniformLocation(vr.taa_program, "u_cam_pos")
	vr.loc_taa_prev_cam_pos    = gl.GetUniformLocation(vr.taa_program, "u_prev_cam_pos")
	vr.loc_taa_near_plane      = gl.GetUniformLocation(vr.taa_program, "u_near_plane")
	vr.loc_taa_far_plane       = gl.GetUniformLocation(vr.taa_program, "u_far_plane")
	vr.loc_taa_mode            = gl.GetUniformLocation(vr.taa_program, "u_taa_mode")
	vr.loc_taa_alpha           = gl.GetUniformLocation(vr.taa_program, "u_alpha")
	vr.loc_taa_depth_threshold = gl.GetUniformLocation(vr.taa_program, "u_depth_threshold")
	vr.loc_taa_clamping_enabled = gl.GetUniformLocation(vr.taa_program, "u_clamping_enabled")
	vr.loc_taa_history_valid   = gl.GetUniformLocation(vr.taa_program, "u_history_valid")

	vr.preview_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_preview.frag") or_return
	vr.preview_loc_boost = gl.GetUniformLocation(vr.preview_program, "u_exposure_boost")
	vr.preview_loc_mode  = gl.GetUniformLocation(vr.preview_program, "u_preview_mode")

	vr.composite_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_composite_simple.frag") or_return

	// 2. Fullscreen Triangle VAO
	gl.GenVertexArrays(1, &vr.vao)
	gl.GenBuffers(1, &vr.vbo)
	gl.BindVertexArray(vr.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vr.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(volumetric_quad_verts), &volumetric_quad_verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)
	gl.BindVertexArray(0)

	// 3. FBO & Textures
	create_volumetric_fbo(vr) or_return

	dbg.object_label(gl.FRAMEBUFFER, vr.fbo, "Volumetric_Raw_FBO")
	dbg.object_label(gl.TEXTURE, vr.raw_tex, "Volumetric_Raw_RGBA16F")
	dbg.object_label(gl.FRAMEBUFFER, vr.history_fbo[0], "Volumetric_History_FBO_0")
	dbg.object_label(gl.FRAMEBUFFER, vr.history_fbo[1], "Volumetric_History_FBO_1")
	dbg.object_label(gl.TEXTURE, vr.history_tex[0], "Volumetric_History_RGBA16F_0")
	dbg.object_label(gl.TEXTURE, vr.history_tex[1], "Volumetric_History_RGBA16F_1")
	dbg.object_label(gl.TEXTURE, vr.acceptance_tex, "Volumetric_Acceptance_RGBA8")
	dbg.object_label(gl.TEXTURE, vr.preview_tex, "Volumetric_Preview_RGBA8")

	log.log_info("suckless-odin.volumetric", "Volumetric renderer with TAA created (%dx%d -> %dx%d)", vr.full_width, vr.full_height, vr.width, vr.height)
	return true
}

@(private)
create_volumetric_fbo :: proc(vr: ^Volumetric_Renderer) -> bool {
	// 1. Raw volumetric HDR texture & FBO (GL_RGBA16F)
	gl.GenTextures(1, &vr.raw_tex)
	gl.BindTexture(gl.TEXTURE_2D, vr.raw_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, vr.width, vr.height, 0, gl.RGBA, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenFramebuffers(1, &vr.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, vr.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, vr.raw_tex, 0)

	draw_buf := [1]u32{gl.COLOR_ATTACHMENT0}
	gl.DrawBuffers(1, &draw_buf[0])

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.volumetric", "Volumetric Raw FBO incomplete: 0x%X", status)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return false
	}

	// 2. TAA Acceptance Map Debug Texture (GL_RGBA8)
	gl.GenTextures(1, &vr.acceptance_tex)
	gl.BindTexture(gl.TEXTURE_2D, vr.acceptance_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, vr.width, vr.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	// 3. Double-buffered TAA History FBOs & Textures (GL_RGBA16F)
	for i in 0..<2 {
		gl.GenTextures(1, &vr.history_tex[i])
		gl.BindTexture(gl.TEXTURE_2D, vr.history_tex[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, vr.width, vr.height, 0, gl.RGBA, gl.FLOAT, nil)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

		gl.GenFramebuffers(1, &vr.history_fbo[i])
		gl.BindFramebuffer(gl.FRAMEBUFFER, vr.history_fbo[i])
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, vr.history_tex[i], 0)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, vr.acceptance_tex, 0)

		history_draw_bufs := [2]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1}
		gl.DrawBuffers(2, &history_draw_bufs[0])

		h_status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
		if h_status != gl.FRAMEBUFFER_COMPLETE {
			log.log_error("suckless-odin.volumetric", "Volumetric History FBO %d incomplete: 0x%X", i, h_status)
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			return false
		}
	}

	// 4. Preview RGBA texture & FBO
	gl.GenTextures(1, &vr.preview_tex)
	gl.BindTexture(gl.TEXTURE_2D, vr.preview_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, vr.width, vr.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenFramebuffers(1, &vr.preview_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, vr.preview_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, vr.preview_tex, 0)
	gl.DrawBuffers(1, &draw_buf[0])

	preview_status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if preview_status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.volumetric", "Volumetric preview FBO incomplete: 0x%X", preview_status)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return false
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	return true
}

@(private)
destroy_volumetric_fbo :: proc(vr: ^Volumetric_Renderer) {
	if vr.fbo != 0 {
		gl.DeleteFramebuffers(1, &vr.fbo)
		vr.fbo = 0
	}
	if vr.raw_tex != 0 {
		gl.DeleteTextures(1, &vr.raw_tex)
		vr.raw_tex = 0
	}
	for i in 0..<2 {
		if vr.history_fbo[i] != 0 {
			gl.DeleteFramebuffers(1, &vr.history_fbo[i])
			vr.history_fbo[i] = 0
		}
		if vr.history_tex[i] != 0 {
			gl.DeleteTextures(1, &vr.history_tex[i])
			vr.history_tex[i] = 0
		}
	}
	if vr.acceptance_tex != 0 {
		gl.DeleteTextures(1, &vr.acceptance_tex)
		vr.acceptance_tex = 0
	}
	if vr.preview_fbo != 0 {
		gl.DeleteFramebuffers(1, &vr.preview_fbo)
		vr.preview_fbo = 0
	}
	if vr.preview_tex != 0 {
		gl.DeleteTextures(1, &vr.preview_tex)
		vr.preview_tex = 0
	}
}

// Resizes volumetric buffers
volumetric_resize :: proc(vr: ^Volumetric_Renderer, full_width, full_height: i32) {
	if full_width == vr.full_width && full_height == vr.full_height do return
	vr.full_width = max(2, full_width)
	vr.full_height = max(2, full_height)
	vr.width = max(1, full_width / 2)
	vr.height = max(1, full_height / 2)
	vr.history_valid = false

	destroy_volumetric_fbo(vr)
	create_volumetric_fbo(vr)
	log.log_info("suckless-odin.volumetric", "Volumetric renderer resized to %dx%d (from %dx%d)", vr.width, vr.height, vr.full_width, vr.full_height)
}

// Executes the Volumetric Raymarching and TAA Reprojection passes
volumetric_render :: proc(
	vr: ^Volumetric_Renderer,
	low_res_depth_tex: u32,
	prev_low_res_depth_tex: u32,
	shadow_cubemap_tex: u32,
	inv_view_proj: ^mt.Mat4,
	view_proj: ^mt.Mat4,
	cam_pos: mt.Vec3,
	near_plane, far_plane: f32,
	light_pos: mt.Vec3,
	light_radius: f32,
	light_color: mt.Vec3,
	light_intensity: f32,
	shadow_bias: f32,
	shadows_enabled: bool,
	frame_idx: i32,
) {
	if !vr.enabled || vr.fbo == 0 || vr.program == 0 do return

	dbg.push_group("Volumetric_Pipeline")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	// =========================================================================
	// Pass 1: Raw Analytical Raymarching into vr.raw_tex
	// =========================================================================
	dbg.push_group("Volumetric_Raymarch_Pass")
	gl.BindFramebuffer(gl.FRAMEBUFFER, vr.fbo)
	gl.Viewport(0, 0, vr.width, vr.height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(vr.program)

	// Bind Low-Res Depth (unit 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)
	gl.Uniform1i(gl.GetUniformLocation(vr.program, "u_low_res_depth"), 0)

	// Bind Omnidirectional Shadow Cubemap (unit 1)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, shadow_cubemap_tex)
	gl.Uniform1i(gl.GetUniformLocation(vr.program, "u_shadow_cubemap"), 1)

	// Upload Camera & Medium Uniforms
	gl.UniformMatrix4fv(vr.loc_inv_view_proj, 1, false, &inv_view_proj[0][0])
	gl.Uniform3f(vr.loc_cam_pos, cam_pos.x, cam_pos.y, cam_pos.z)
	gl.Uniform1f(vr.loc_near_plane, near_plane)
	gl.Uniform1f(vr.loc_far_plane, far_plane)
	gl.Uniform1i(vr.loc_frame_idx, frame_idx)

	// Upload Point Light Uniforms
	gl.Uniform3f(vr.loc_light_pos, light_pos.x, light_pos.y, light_pos.z)
	gl.Uniform1f(vr.loc_light_radius, light_radius)
	gl.Uniform3f(vr.loc_light_color, light_color.x, light_color.y, light_color.z)
	gl.Uniform1f(vr.loc_light_intensity, light_intensity)
	gl.Uniform1f(vr.loc_shadow_bias, shadow_bias)
	gl.Uniform1i(vr.loc_shadows_enabled, 1 if shadows_enabled else 0)

	// Upload Raymarching parameters
	gl.Uniform1i(vr.loc_step_count, vr.step_count)
	gl.Uniform1f(vr.loc_scattering_coeff, vr.scattering_coeff)
	gl.Uniform1f(vr.loc_extinction_coeff, vr.extinction_coeff)
	gl.Uniform1f(vr.loc_anisotropy_g, vr.anisotropy_g)
	gl.Uniform1f(vr.loc_intensity_mult, vr.intensity_mult)
	gl.Uniform1i(vr.loc_jitter_enabled, 1 if vr.jitter_enabled else 0)

	gl.BindVertexArray(vr.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.BindVertexArray(0)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
	dbg.pop_group()

	// =========================================================================
	// Pass 2: Phase 4 TAA Reprojection & History Blending
	// =========================================================================
	if vr.taa_mode > 0 && vr.taa_program != 0 {
		dbg.push_group("Volumetric_TAA_Reprojection_Pass")

		dest_fbo := vr.history_fbo[vr.history_idx]
		prev_tex := vr.history_tex[1 - vr.history_idx]

		gl.BindFramebuffer(gl.FRAMEBUFFER, dest_fbo)
		gl.Viewport(0, 0, vr.width, vr.height)
		gl.Disable(gl.DEPTH_TEST)
		gl.Disable(gl.BLEND)

		gl.UseProgram(vr.taa_program)

		// Unit 0: Current Volumetric Raw Texture
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, vr.raw_tex)
		gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_current_volumetric"), 0)

		// Unit 1: History Volumetric Texture
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_2D, prev_tex)
		gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_history_volumetric"), 1)

		// Unit 2: Current Low-Res Depth
		gl.ActiveTexture(gl.TEXTURE2)
		gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)
		gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_current_depth"), 2)

		// Unit 3: History Low-Res Depth
		gl.ActiveTexture(gl.TEXTURE3)
		gl.BindTexture(gl.TEXTURE_2D, prev_low_res_depth_tex)
		gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_history_depth"), 3)

		// Matrix and Camera Uniforms
		gl.UniformMatrix4fv(vr.loc_taa_inv_view_proj, 1, false, &inv_view_proj[0][0])
		gl.UniformMatrix4fv(vr.loc_taa_prev_view_proj, 1, false, &vr.prev_view_proj[0][0])
		gl.Uniform3f(vr.loc_taa_cam_pos, cam_pos.x, cam_pos.y, cam_pos.z)
		gl.Uniform3f(vr.loc_taa_prev_cam_pos, vr.prev_cam_pos.x, vr.prev_cam_pos.y, vr.prev_cam_pos.z)
		gl.Uniform1f(vr.loc_taa_near_plane, near_plane)
		gl.Uniform1f(vr.loc_taa_far_plane, far_plane)

		// TAA parameters
		gl.Uniform1i(vr.loc_taa_mode, vr.taa_mode)
		gl.Uniform1f(vr.loc_taa_alpha, vr.taa_alpha)
		gl.Uniform1f(vr.loc_taa_depth_threshold, vr.taa_depth_threshold)
		gl.Uniform1i(vr.loc_taa_clamping_enabled, 1 if vr.taa_clamping_enabled else 0)
		gl.Uniform1i(vr.loc_taa_history_valid, 1 if vr.history_valid else 0)

		gl.BindVertexArray(vr.vao)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)

		gl.BindVertexArray(0)
		for u in u32(0)..=3 {
			gl.ActiveTexture(gl.TEXTURE0 + u)
			gl.BindTexture(gl.TEXTURE_2D, 0)
		}
		gl.UseProgram(0)

		// Advance Ping-Pong history index
		vr.history_idx = 1 - vr.history_idx
		vr.prev_view_proj = view_proj^
		vr.prev_inv_view_proj = inv_view_proj^
		vr.prev_cam_pos = cam_pos
		vr.history_valid = true

		dbg.pop_group()
	} else {
		// No temporal accumulation
		vr.history_valid = false
		vr.prev_view_proj = view_proj^
		vr.prev_inv_view_proj = inv_view_proj^
		vr.prev_cam_pos = cam_pos
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	vr.preview_dirty = true
}

// Returns the active volumetric texture (Filtered TAA texture if active, or Raw Raymarched texture)
volumetric_get_active_texture :: proc(vr: ^Volumetric_Renderer) -> u32 {
	if vr == nil do return 0
	if vr.taa_mode > 0 && vr.history_valid {
		return vr.history_tex[1 - vr.history_idx]
	}
	return vr.raw_tex
}

// Updates the Dear ImGui RGBA preview texture on-demand
volumetric_update_preview :: proc(vr: ^Volumetric_Renderer) {
	if vr.preview_fbo == 0 || vr.preview_program == 0 do return

	dbg.push_group("Volumetric_Preview_Pass")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, vr.preview_fbo)
	gl.Viewport(0, 0, vr.width, vr.height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(vr.preview_program)
	gl.ActiveTexture(gl.TEXTURE0)

	// Bind preview source texture based on selected mode
	switch vr.preview_mode {
	case 1: // Raw Pre-TAA Grain
		gl.BindTexture(gl.TEXTURE_2D, vr.raw_tex)
		gl.Uniform1i(vr.preview_loc_mode, 0)
	case 2: // Heatmap
		gl.BindTexture(gl.TEXTURE_2D, volumetric_get_active_texture(vr))
		gl.Uniform1i(vr.preview_loc_mode, 2)
	case 3: // TAA Acceptance Map
		gl.BindTexture(gl.TEXTURE_2D, vr.acceptance_tex)
		gl.Uniform1i(vr.preview_loc_mode, 0)
	case 4: // Transmittance
		gl.BindTexture(gl.TEXTURE_2D, volumetric_get_active_texture(vr))
		gl.Uniform1i(vr.preview_loc_mode, 1)
	case: // 0: Final In-Scattering
		gl.BindTexture(gl.TEXTURE_2D, volumetric_get_active_texture(vr))
		gl.Uniform1i(vr.preview_loc_mode, 0)
	}

	gl.Uniform1i(gl.GetUniformLocation(vr.preview_program, "u_volumetric_tex"), 0)
	gl.Uniform1f(vr.preview_loc_boost, vr.preview_exposure_boost)

	gl.BindVertexArray(vr.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.BindVertexArray(0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	vr.preview_dirty = false
}

// Additively composites volumetric in-scattering into the scene HDR buffer
volumetric_composite_to_scene :: proc(vr: ^Volumetric_Renderer, target_fbo: u32, width, height: i32) {
	active_tex := volumetric_get_active_texture(vr)
	if !vr.enabled || !vr.composite_in_scene || vr.composite_program == 0 || active_tex == 0 do return

	dbg.push_group("Volumetric_Composite_Direct")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, target_fbo)
	gl.Viewport(0, 0, width, height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE) // Pure additive in-scattering into scene HDR

	gl.UseProgram(vr.composite_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, active_tex)
	gl.Uniform1i(gl.GetUniformLocation(vr.composite_program, "u_volumetric_tex"), 0)

	gl.BindVertexArray(vr.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.BindVertexArray(0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
	gl.Disable(gl.BLEND)

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()
}

// Releases all GPU resources
volumetric_destroy :: proc(vr: ^Volumetric_Renderer) {
	destroy_volumetric_fbo(vr)

	if vr.vao != 0 {
		gl.DeleteVertexArrays(1, &vr.vao)
		vr.vao = 0
	}
	if vr.vbo != 0 {
		gl.DeleteBuffers(1, &vr.vbo)
		vr.vbo = 0
	}
	if vr.program != 0 {
		gl.DeleteProgram(vr.program)
		vr.program = 0
	}
	if vr.taa_program != 0 {
		gl.DeleteProgram(vr.taa_program)
		vr.taa_program = 0
	}
	if vr.preview_program != 0 {
		gl.DeleteProgram(vr.preview_program)
		vr.preview_program = 0
	}
	if vr.composite_program != 0 {
		gl.DeleteProgram(vr.composite_program)
		vr.composite_program = 0
	}
	vr^ = {}
}
