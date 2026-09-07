package rendering

import gl "vendor:OpenGL"
import "core:math"

import dbg "../core/gl_debug"
import log "../core/log"
import gl_state "../core/gl_state"
import mt "../core/math_types"
import tracy "../core/tracy"
import shader "./shader"

@(private)
srcloc_volumetric_render := tracy.Source_Location_Data{
	name     = "Volumetric_Pipeline",
	function = "volumetric_render",
	file     = #file,
	line     = #line,
	color    = 0x88C0D0,
}

@(private)
srcloc_volumetric_raymarch := tracy.Source_Location_Data{
	name     = "Volumetric_Raymarch",
	function = "volumetric_render",
	file     = #file,
	line     = #line,
	color    = 0x81A1C1,
}

@(private)
srcloc_volumetric_taa := tracy.Source_Location_Data{
	name     = "Volumetric_TAA",
	function = "volumetric_render",
	file     = #file,
	line     = #line,
	color    = 0x5E81AC,
}

@(private)
srcloc_volumetric_blur := tracy.Source_Location_Data{
	name     = "Volumetric_Bilateral_Blur",
	function = "volumetric_render",
	file     = #file,
	line     = #line,
	color    = 0xB48EAD,
}

@(private)
srcloc_volumetric_composite := tracy.Source_Location_Data{
	name     = "Volumetric_Composite_JBU",
	function = "volumetric_composite_to_scene",
	file     = #file,
	line     = #line,
	color    = 0xA3BE8C,
}

// Debug view enumeration for volumetric lighting pipeline inspection
Volumetric_Debug_View :: enum u32 {
	Disabled               = 0,
	Shadow_Cubemap_Cross   = 1, // Phase 1: Shadow cubemap unfolded inspection
	Low_Res_Depth          = 2, // Phase 2: Downsampled linear depth map
	Depth_Discontinuities  = 3, // Phase 2: Silhouette edge discontinuity mask
	Raw_Raymarching        = 4, // Phase 3: Raw in-scattering without TAA/blur
	TAA_Acceptance_Map     = 5, // Phase 4: History reprojection validity RGB map
	Bilateral_Blur_Diff    = 6, // Phase 5: Blur delta map (|blurred - raw|)
	Volumetric_Only        = 7, // Phase 6: Isolated in-scattering buffer
	AB_Split_Comparison    = 8, // Phase 6: A/B interactive split comparison
}

// Tunable volumetric medium & filtering parameters (serializable for presets)
Volumetric_Params :: struct {
	enabled:                      bool,
	composite_in_scene:           bool, // Additively blend in-scattering into scene HDR
	isolate_in_scene:             bool, // Debug mode: Isolate volumetric lighting (black background / no IBL)
	shadows_enabled:              bool, // Cast volumetric shadow shafts (God Rays) via shadow cubemap

	// Physical medium parameters
	step_count:                   i32,  // Raymarching steps (default 16, range 4..64)
	scattering_coeff:             f32,  // Scattering coefficient sigma_s (default 0.025)
	extinction_coeff:             f32,  // Extinction coefficient sigma_t (default 0.05)
	anisotropy_g:                 f32,  // Henyey-Greenstein eccentricity g (default 0.55)
	intensity_mult:               f32,  // Volumetric master intensity multiplier (default 1.0)
	jitter_enabled:               bool, // Spatial/temporal ray jittering

	// Phase 4: TAA Temporal Reprojection parameters
	taa_mode:                     i32,  // 0: Off, 1: Simple EMA Blend, 2: Motion-Aware TAA Reprojection
	taa_alpha:                    f32,  // Current frame blend weight (default 0.20, range 0.02..1.0)
	taa_depth_threshold:          f32,  // Disocclusion depth tolerance in meters (default 0.80)
	taa_clamping_enabled:         bool, // 3x3 color neighborhood bounding box clamping

	// Phase 5: Separable Joint Bilateral Blur parameters
	blur_mode:                    i32,  // 0: None, 1: 5-tap Bilateral, 2: 9-tap Bilateral
	blur_sharpness:               f32,  // Depth falloff sharpness (default 500.0)
	viewport_debug_mode:          i32,  // 0: Normal Scene, 1: Neon Silhouette Highlight, 2: Isolated Silhouettes

	// Phase 6: Joint Bilateral Upsampling (JBU) parameters
	upsample_mode:                i32,  // 0: Bilinear Standard, 1: Nearest-Depth Fast JBU, 2: Joint Bilateral Upsampling 2x2
	upsample_sharpness:           f32,  // Sharpness for JBU depth guidance (default 200.0)
	resolution_divider:           i32,  // Volumetric buffer divider (1: Full 1/1, 2: Half 1/2, 4: Quarter 1/4)

	// Preview / Inspector tools
	preview_mode:                 i32,  // 0..9 preview visualization modes
	preview_exposure_boost:       f32,  // default 1.0 (range 1.0..10.0)
	zoom_scale:                   f32,  // Loupe zoom (1.0 to 16.0)
	zoom_center:                  mt.Vec2, // (0.5, 0.5)
}

// Phase 3, 4 & 5: Volumetric Lighting & Filtering Renderer
Volumetric_Renderer :: struct {
	params:                 Volumetric_Params,
	fbo:                    u32, // Raw raymarching FBO
	raw_tex:                u32, // GL_RGBA16F, W/2 x H/2 (Raw newly raymarched in-scattering)
	width:                  i32, // Low-res width (W / 2)
	height:                 i32, // Low-res height (H / 2)
	full_width:             i32,
	full_height:            i32,

	// TAA Temporal Accumulation Ping-Pong Buffers
	history_valid:          bool, // False on reset / resize / camera teleport
	history_fbo:            [2]u32,
	history_tex:            [2]u32, // GL_RGBA16F, W/2 x H/2
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

	// Phase 5: Separable Joint Bilateral Blur State
	blur_fbo:               [2]u32, // FBO 0: Horizontal pass, FBO 1: Vertical pass
	blur_tex:               [2]u32, // GL_RGBA16F, W/2 x H/2
	blur_program:           u32,
	loc_blur_dir_step:      i32,
	loc_blur_mode:          i32,
	loc_blur_sharpness:     i32,

	// Preview RGBA texture & FBO for Dear ImGui Inspector
	preview_fbo:                   u32,
	preview_tex:                   u32, // GL_RGBA8, W/2 x H/2
	preview_program:               u32,
	preview_loc_volumetric_tex:    i32,
	preview_loc_unblurred_tex:     i32,
	preview_loc_depth_tex:         i32,
	preview_loc_discontinuity_tex: i32,
	preview_loc_boost:             i32,
	preview_loc_mode:              i32,
	preview_loc_sharpness:         i32,
	preview_loc_texel_size:        i32,
	preview_loc_zoom_scale:        i32,
	preview_loc_zoom_center:       i32,
	preview_dirty:                 bool,

	// Composite Shader Uniforms
	loc_comp_volumetric_tex:       i32,
	loc_comp_unblurred_tex:        i32,
	loc_comp_discontinuity_tex:    i32,
	loc_comp_depth_tex:            i32,
	loc_comp_full_depth_tex:       i32,
	loc_comp_upsample_mode:        i32,
	loc_comp_upsample_sharpness:   i32,
	loc_comp_near_plane:           i32,
	loc_comp_far_plane:            i32,
	loc_comp_low_res_size:         i32,
	loc_comp_composite_mode:       i32,
	loc_comp_exposure_boost:       i32,
	loc_comp_sharpness:            i32,
	loc_comp_texel_size:           i32,

	// Fullscreen Triangle
	triangle:                      Fullscreen_Triangle,

	// Phase 7: GPU Timers & Profiling
	timers:                        Volumetric_Gpu_Timers,
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
	vr.params = Volumetric_Params{
		enabled                = true,
		composite_in_scene     = true,
		isolate_in_scene       = false,
		shadows_enabled        = true,
		step_count             = 16,
		scattering_coeff       = 0.025,
		extinction_coeff       = 0.05,
		anisotropy_g           = 0.55,
		intensity_mult         = 1.0,
		jitter_enabled         = true,
		taa_mode               = 2, // TAA Reprojection
		taa_alpha              = 0.20,
		taa_depth_threshold    = 0.80,
		taa_clamping_enabled   = true,
		blur_mode              = 2, // 9-tap Bilateral (Smooth ISO legacy)
		blur_sharpness         = 500.0,
		viewport_debug_mode    = 0,
		upsample_mode          = 2, // Joint Bilateral Upsampling (JBU 2x2 Depth-Guided)
		upsample_sharpness     = 200.0,
		resolution_divider     = 2, // Half-resolution buffer (1/2 default)
		preview_mode           = 0,
		preview_exposure_boost = 1.0,
		zoom_scale             = 1.0,
		zoom_center            = mt.Vec2{0.5, 0.5},
	}

	div := max(1, vr.params.resolution_divider)
	vr.full_width = max(2, full_width)
	vr.full_height = max(2, full_height)
	vr.width = max(1, full_width / div)
	vr.height = max(1, full_height / div)
	vr.history_valid = false
	vr.history_idx = 0
	vr.preview_dirty = true

	// 1. Load Shaders & static sampler uniforms
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

	gl.UseProgram(vr.program)
	gl.Uniform1i(gl.GetUniformLocation(vr.program, "u_low_res_depth"), 0)
	gl.Uniform1i(gl.GetUniformLocation(vr.program, "u_shadow_cubemap"), 1)
	gl.UseProgram(0)

	// TAA Program
	vr.taa_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_taa.frag") or_return
	vr.loc_taa_inv_view_proj    = gl.GetUniformLocation(vr.taa_program, "u_inv_view_proj")
	vr.loc_taa_prev_view_proj   = gl.GetUniformLocation(vr.taa_program, "u_prev_view_proj")
	vr.loc_taa_cam_pos          = gl.GetUniformLocation(vr.taa_program, "u_cam_pos")
	vr.loc_taa_prev_cam_pos     = gl.GetUniformLocation(vr.taa_program, "u_prev_cam_pos")
	vr.loc_taa_near_plane       = gl.GetUniformLocation(vr.taa_program, "u_near_plane")
	vr.loc_taa_far_plane        = gl.GetUniformLocation(vr.taa_program, "u_far_plane")
	vr.loc_taa_mode             = gl.GetUniformLocation(vr.taa_program, "u_taa_mode")
	vr.loc_taa_alpha            = gl.GetUniformLocation(vr.taa_program, "u_alpha")
	vr.loc_taa_depth_threshold  = gl.GetUniformLocation(vr.taa_program, "u_depth_threshold")
	vr.loc_taa_clamping_enabled = gl.GetUniformLocation(vr.taa_program, "u_clamping_enabled")
	vr.loc_taa_history_valid    = gl.GetUniformLocation(vr.taa_program, "u_history_valid")

	gl.UseProgram(vr.taa_program)
	gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_current_volumetric"), 0)
	gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_history_volumetric"), 1)
	gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_current_depth"), 2)
	gl.Uniform1i(gl.GetUniformLocation(vr.taa_program, "u_history_depth"), 3)
	gl.UseProgram(0)

	// Phase 5 Bilateral Blur Program
	vr.blur_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_bilateral_blur.frag") or_return
	vr.loc_blur_dir_step  = gl.GetUniformLocation(vr.blur_program, "u_blur_dir_step")
	vr.loc_blur_mode      = gl.GetUniformLocation(vr.blur_program, "u_blur_mode")
	vr.loc_blur_sharpness = gl.GetUniformLocation(vr.blur_program, "u_sharpness")

	gl.UseProgram(vr.blur_program)
	gl.Uniform1i(gl.GetUniformLocation(vr.blur_program, "u_source_tex"), 0)
	gl.Uniform1i(gl.GetUniformLocation(vr.blur_program, "u_depth_tex"), 1)
	gl.UseProgram(0)

	// Preview Program
	vr.preview_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_preview.frag") or_return
	vr.preview_loc_volumetric_tex    = gl.GetUniformLocation(vr.preview_program, "u_volumetric_tex")
	vr.preview_loc_unblurred_tex     = gl.GetUniformLocation(vr.preview_program, "u_unblurred_tex")
	vr.preview_loc_depth_tex         = gl.GetUniformLocation(vr.preview_program, "u_depth_tex")
	vr.preview_loc_discontinuity_tex = gl.GetUniformLocation(vr.preview_program, "u_discontinuity_tex")
	vr.preview_loc_boost             = gl.GetUniformLocation(vr.preview_program, "u_exposure_boost")
	vr.preview_loc_mode              = gl.GetUniformLocation(vr.preview_program, "u_preview_mode")
	vr.preview_loc_sharpness         = gl.GetUniformLocation(vr.preview_program, "u_sharpness")
	vr.preview_loc_texel_size        = gl.GetUniformLocation(vr.preview_program, "u_texel_size")
	vr.preview_loc_zoom_scale        = gl.GetUniformLocation(vr.preview_program, "u_zoom_scale")
	vr.preview_loc_zoom_center       = gl.GetUniformLocation(vr.preview_program, "u_zoom_center")

	gl.UseProgram(vr.preview_program)
	gl.Uniform1i(vr.preview_loc_volumetric_tex, 0)
	gl.Uniform1i(vr.preview_loc_unblurred_tex, 1)
	gl.Uniform1i(vr.preview_loc_depth_tex, 2)
	gl.Uniform1i(vr.preview_loc_discontinuity_tex, 3)
	gl.UseProgram(0)

	// Composite Program (Phase 6 Joint Bilateral Upsampling)
	vr.composite_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_composite_simple.frag") or_return
	vr.loc_comp_volumetric_tex    = gl.GetUniformLocation(vr.composite_program, "u_volumetric_tex")
	vr.loc_comp_unblurred_tex     = gl.GetUniformLocation(vr.composite_program, "u_unblurred_tex")
	vr.loc_comp_discontinuity_tex = gl.GetUniformLocation(vr.composite_program, "u_discontinuity_tex")
	vr.loc_comp_depth_tex         = gl.GetUniformLocation(vr.composite_program, "u_low_depth_tex")
	vr.loc_comp_full_depth_tex    = gl.GetUniformLocation(vr.composite_program, "u_full_depth_tex")
	vr.loc_comp_upsample_mode     = gl.GetUniformLocation(vr.composite_program, "u_upsample_mode")
	vr.loc_comp_upsample_sharpness= gl.GetUniformLocation(vr.composite_program, "u_upsample_sharpness")
	vr.loc_comp_near_plane        = gl.GetUniformLocation(vr.composite_program, "u_near_plane")
	vr.loc_comp_far_plane         = gl.GetUniformLocation(vr.composite_program, "u_far_plane")
	vr.loc_comp_low_res_size      = gl.GetUniformLocation(vr.composite_program, "u_low_res_size")
	vr.loc_comp_composite_mode    = gl.GetUniformLocation(vr.composite_program, "u_composite_mode")
	vr.loc_comp_exposure_boost    = gl.GetUniformLocation(vr.composite_program, "u_exposure_boost")
	vr.loc_comp_sharpness         = gl.GetUniformLocation(vr.composite_program, "u_sharpness")
	vr.loc_comp_texel_size        = gl.GetUniformLocation(vr.composite_program, "u_texel_size")

	gl.UseProgram(vr.composite_program)
	gl.Uniform1i(vr.loc_comp_volumetric_tex, 0)
	gl.Uniform1i(vr.loc_comp_unblurred_tex, 1)
	gl.Uniform1i(vr.loc_comp_discontinuity_tex, 2)
	gl.Uniform1i(vr.loc_comp_depth_tex, 3)
	gl.Uniform1i(vr.loc_comp_full_depth_tex, 4)
	gl.UseProgram(0)

	// 2. Fullscreen Triangle VAO
	fullscreen_triangle_create(&vr.triangle)

	// 3. FBO & Textures
	create_volumetric_fbo(vr) or_return

	// 4. Phase 7 GPU Profiling Timers
	volumetric_timers_create(&vr.timers)

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

	// 4. Double-buffered Bilateral Blur FBOs & Textures (GL_RGBA16F)
	for i in 0..<2 {
		gl.GenTextures(1, &vr.blur_tex[i])
		gl.BindTexture(gl.TEXTURE_2D, vr.blur_tex[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, vr.width, vr.height, 0, gl.RGBA, gl.FLOAT, nil)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

		gl.GenFramebuffers(1, &vr.blur_fbo[i])
		gl.BindFramebuffer(gl.FRAMEBUFFER, vr.blur_fbo[i])
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, vr.blur_tex[i], 0)
		gl.DrawBuffers(1, &draw_buf[0])

		b_status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
		if b_status != gl.FRAMEBUFFER_COMPLETE {
			log.log_error("suckless-odin.volumetric", "Volumetric Blur FBO %d incomplete: 0x%X", i, b_status)
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			return false
		}
	}

	// 5. Preview RGBA texture & FBO
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
		if vr.blur_fbo[i] != 0 {
			gl.DeleteFramebuffers(1, &vr.blur_fbo[i])
			vr.blur_fbo[i] = 0
		}
		if vr.blur_tex[i] != 0 {
			gl.DeleteTextures(1, &vr.blur_tex[i])
			vr.blur_tex[i] = 0
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

// Resizes volumetric buffers on viewport or resolution divider changes
volumetric_resize :: proc(vr: ^Volumetric_Renderer, full_width, full_height: i32, resolution_divider: i32 = 2) {
	div := max(1, resolution_divider)
	new_w := max(1, full_width / div)
	new_h := max(1, full_height / div)
	if full_width == vr.full_width && full_height == vr.full_height && vr.width == new_w && vr.height == new_h do return

	vr.full_width = max(2, full_width)
	vr.full_height = max(2, full_height)
	vr.width = new_w
	vr.height = new_h
	vr.history_valid = false

	destroy_volumetric_fbo(vr)
	create_volumetric_fbo(vr)
	log.log_info("suckless-odin.volumetric", "Volumetric renderer resized to %dx%d (1/%d from %dx%d)", vr.width, vr.height, div, vr.full_width, vr.full_height)
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
	light: ^Point_Light,
	frame_idx: i32,
) {
	if !vr.params.enabled || vr.fbo == 0 || vr.program == 0 do return

	zone_pipeline := tracy.zone_begin(&srcloc_volumetric_render)
	defer tracy.zone_end(zone_pipeline)

	dbg.push_group("Volumetric_Pipeline")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	// =========================================================================
	// Pass 1: Raw Analytical Raymarching into vr.raw_tex
	// =========================================================================
	volumetric_timer_begin(&vr.timers, .Raymarching)
	zone_raymarch := tracy.zone_begin(&srcloc_volumetric_raymarch)
	dbg.push_group("Volumetric_Raymarch_Pass")
	gl.BindFramebuffer(gl.FRAMEBUFFER, vr.fbo)
	gl.Viewport(0, 0, vr.width, vr.height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(vr.program)

	// Bind Low-Res Depth (unit 0) & Shadow Cubemap (unit 1)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)

	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, shadow_cubemap_tex)

	// Upload Camera & Medium Uniforms
	gl.UniformMatrix4fv(vr.loc_inv_view_proj, 1, false, &inv_view_proj[0][0])
	gl.Uniform3f(vr.loc_cam_pos, cam_pos.x, cam_pos.y, cam_pos.z)
	gl.Uniform1f(vr.loc_near_plane, near_plane)
	gl.Uniform1f(vr.loc_far_plane, far_plane)
	gl.Uniform1i(vr.loc_frame_idx, frame_idx)

	// Upload Point Light Uniforms (from Point_Light aggregate)
	light_pos := point_light_get_position(light, f32(frame_idx) * 0.016) if light != nil else mt.Vec3{}
	light_radius := light.radius if light != nil else 10.0
	light_color := light.color if light != nil else mt.Vec3{1, 1, 1}
	light_intensity := light.intensity if light != nil else 1.0
	shadow_bias := light.shadow_bias if light != nil else 0.001
	shadows_enabled := (light != nil && light.enabled && vr.params.shadows_enabled)

	gl.Uniform3f(vr.loc_light_pos, light_pos.x, light_pos.y, light_pos.z)
	gl.Uniform1f(vr.loc_light_radius, light_radius)
	gl.Uniform3f(vr.loc_light_color, light_color.x, light_color.y, light_color.z)
	gl.Uniform1f(vr.loc_light_intensity, light_intensity)
	gl.Uniform1f(vr.loc_shadow_bias, shadow_bias)
	gl.Uniform1i(vr.loc_shadows_enabled, 1 if shadows_enabled else 0)

	// Upload Raymarching parameters
	gl.Uniform1i(vr.loc_step_count, vr.params.step_count)
	gl.Uniform1f(vr.loc_scattering_coeff, vr.params.scattering_coeff)
	gl.Uniform1f(vr.loc_extinction_coeff, vr.params.extinction_coeff)
	gl.Uniform1f(vr.loc_anisotropy_g, vr.params.anisotropy_g)
	gl.Uniform1f(vr.loc_intensity_mult, vr.params.intensity_mult)
	gl.Uniform1i(vr.loc_jitter_enabled, 1 if vr.params.jitter_enabled else 0)

	fullscreen_triangle_draw(&vr.triangle)

	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
	dbg.pop_group()
	tracy.zone_end(zone_raymarch)
	volumetric_timer_end(&vr.timers, .Raymarching)

	// =========================================================================
	// Pass 2: Phase 4 TAA Reprojection & History Blending
	// =========================================================================
	if vr.params.taa_mode > 0 && vr.taa_program != 0 {
		volumetric_timer_begin(&vr.timers, .TAA_Blend)
		zone_taa := tracy.zone_begin(&srcloc_volumetric_taa)
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

		// Unit 1: History Volumetric Texture
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_2D, prev_tex)

		// Unit 2: Current Low-Res Depth
		gl.ActiveTexture(gl.TEXTURE2)
		gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)

		// Unit 3: History Low-Res Depth
		gl.ActiveTexture(gl.TEXTURE3)
		gl.BindTexture(gl.TEXTURE_2D, prev_low_res_depth_tex)

		// Matrix and Camera Uniforms
		gl.UniformMatrix4fv(vr.loc_taa_inv_view_proj, 1, false, &inv_view_proj[0][0])
		gl.UniformMatrix4fv(vr.loc_taa_prev_view_proj, 1, false, &vr.prev_view_proj[0][0])
		gl.Uniform3f(vr.loc_taa_cam_pos, cam_pos.x, cam_pos.y, cam_pos.z)
		gl.Uniform3f(vr.loc_taa_prev_cam_pos, vr.prev_cam_pos.x, vr.prev_cam_pos.y, vr.prev_cam_pos.z)
		gl.Uniform1f(vr.loc_taa_near_plane, near_plane)
		gl.Uniform1f(vr.loc_taa_far_plane, far_plane)

		// Dynamic responsive TAA alpha during light motion with smooth graceful transition
		effective_alpha := vr.params.taa_alpha
		if light != nil && (light.is_interacting || light.motion_cooldown > 0.0) {
			blend := min(f32(1.0), light.motion_cooldown / 0.40)
			blend_smooth := blend * blend * (3.0 - 2.0 * blend)
			effective_alpha = math.lerp(vr.params.taa_alpha, 0.70, blend_smooth)
		}

		// TAA parameters
		gl.Uniform1i(vr.loc_taa_mode, vr.params.taa_mode)
		gl.Uniform1f(vr.loc_taa_alpha, effective_alpha)
		gl.Uniform1f(vr.loc_taa_depth_threshold, vr.params.taa_depth_threshold)
		gl.Uniform1i(vr.loc_taa_clamping_enabled, 1 if vr.params.taa_clamping_enabled else 0)
		gl.Uniform1i(vr.loc_taa_history_valid, 1 if vr.history_valid else 0)

		fullscreen_triangle_draw(&vr.triangle)

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
		tracy.zone_end(zone_taa)
		volumetric_timer_end(&vr.timers, .TAA_Blend)
	} else {
		// No temporal accumulation
		vr.history_valid = false
		vr.prev_view_proj = view_proj^
		vr.prev_inv_view_proj = inv_view_proj^
		vr.prev_cam_pos = cam_pos
	}

	// =========================================================================
	// Pass 3: Phase 5 Separable Joint Bilateral Blur (5-tap & 9-tap)
	// =========================================================================
	if vr.params.blur_mode > 0 && vr.blur_program != 0 {
		volumetric_timer_begin(&vr.timers, .Bilateral_Blur)
		zone_blur := tracy.zone_begin(&srcloc_volumetric_blur)
		dbg.push_group("Volumetric_Bilateral_Blur_Pass")

		blur_src_tex := vr.history_tex[1 - vr.history_idx] if (vr.params.taa_mode > 0 && vr.history_valid) else vr.raw_tex

		gl.UseProgram(vr.blur_program)
		gl.Uniform1i(vr.loc_blur_mode, vr.params.blur_mode)
		gl.Uniform1f(vr.loc_blur_sharpness, vr.params.blur_sharpness)

		// 1. Horizontal Pass: blur_src_tex -> vr.blur_fbo[0]
		gl.BindFramebuffer(gl.FRAMEBUFFER, vr.blur_fbo[0])
		gl.Viewport(0, 0, vr.width, vr.height)
		gl.Disable(gl.DEPTH_TEST)
		gl.Disable(gl.BLEND)

		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, blur_src_tex)

		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)

		gl.Uniform2f(vr.loc_blur_dir_step, 1.0 / f32(max(1, vr.width)), 0.0)

		fullscreen_triangle_draw(&vr.triangle)

		// 2. Vertical Pass: vr.blur_tex[0] -> vr.blur_fbo[1]
		gl.BindFramebuffer(gl.FRAMEBUFFER, vr.blur_fbo[1])
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, vr.blur_tex[0])

		gl.Uniform2f(vr.loc_blur_dir_step, 0.0, 1.0 / f32(max(1, vr.height)))

		fullscreen_triangle_draw(&vr.triangle)

		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		gl.UseProgram(0)

		dbg.pop_group()
		tracy.zone_end(zone_blur)
		volumetric_timer_end(&vr.timers, .Bilateral_Blur)
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	vr.preview_dirty = true
}

// Returns the active volumetric texture (Bilateral Blurred if active, TAA Filtered if active, or Raw)
volumetric_get_active_texture :: proc(vr: ^Volumetric_Renderer) -> u32 {
	if vr == nil do return 0
	if vr.params.blur_mode > 0 {
		return vr.blur_tex[1]
	}
	if vr.params.taa_mode > 0 && vr.history_valid {
		return vr.history_tex[1 - vr.history_idx]
	}
	return vr.raw_tex
}

// Returns the volumetric texture BEFORE the bilateral blur stage (either TAA filtered or Raw)
volumetric_get_unblurred_texture :: proc(vr: ^Volumetric_Renderer) -> u32 {
	if vr == nil do return 0
	if vr.params.taa_mode > 0 && vr.history_valid {
		return vr.history_tex[1 - vr.history_idx]
	}
	return vr.raw_tex
}

// Updates the Dear ImGui RGBA preview texture on-demand with multi-texture edge debugging support
volumetric_update_preview :: proc(
	vr: ^Volumetric_Renderer,
	low_res_depth_tex: u32 = 0,
	discontinuity_tex: u32 = 0,
) {
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

	// Unit 0: Active volumetric texture
	gl.ActiveTexture(gl.TEXTURE0)
	if vr.params.preview_mode == 1 {
		gl.BindTexture(gl.TEXTURE_2D, vr.raw_tex)
	} else if vr.params.preview_mode == 3 {
		gl.BindTexture(gl.TEXTURE_2D, vr.acceptance_tex)
	} else if vr.params.preview_mode == 4 {
		gl.BindTexture(gl.TEXTURE_2D, vr.blur_tex[1] if vr.params.blur_mode > 0 else volumetric_get_active_texture(vr))
	} else {
		gl.BindTexture(gl.TEXTURE_2D, volumetric_get_active_texture(vr))
	}

	// Unit 1: Unblurred volumetric texture
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, volumetric_get_unblurred_texture(vr))

	// Unit 2: Low-res linear depth
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)

	// Unit 3: Edge discontinuity mask
	gl.ActiveTexture(gl.TEXTURE3)
	gl.BindTexture(gl.TEXTURE_2D, discontinuity_tex)

	// Uniforms
	gl.Uniform1f(vr.preview_loc_boost, vr.params.preview_exposure_boost)
	gl.Uniform1i(vr.preview_loc_mode, vr.params.preview_mode)
	gl.Uniform1f(vr.preview_loc_sharpness, vr.params.blur_sharpness)
	gl.Uniform2f(vr.preview_loc_texel_size, 1.0 / f32(max(1, vr.width)), 1.0 / f32(max(1, vr.height)))
	gl.Uniform1f(vr.preview_loc_zoom_scale, vr.params.zoom_scale)
	gl.Uniform2f(vr.preview_loc_zoom_center, vr.params.zoom_center.x, vr.params.zoom_center.y)

	fullscreen_triangle_draw(&vr.triangle)

	for u in u32(0)..=3 {
		gl.ActiveTexture(gl.TEXTURE0 + u)
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}
	gl.UseProgram(0)

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	vr.preview_dirty = false
}

// Additively composites volumetric in-scattering into the scene HDR buffer with Phase 6 Joint Bilateral Upsampling
volumetric_composite_to_scene :: proc(
	vr: ^Volumetric_Renderer,
	target_fbo: u32,
	width, height: i32,
	discontinuity_tex: u32 = 0,
	low_res_depth_tex: u32 = 0,
	full_res_depth_tex: u32 = 0,
	near_plane: f32 = 0.1,
	far_plane: f32 = 100.0,
) {
	active_tex := volumetric_get_active_texture(vr)
	if !vr.params.enabled || !vr.params.composite_in_scene || vr.composite_program == 0 || active_tex == 0 do return

	zone_comp := tracy.zone_begin(&srcloc_volumetric_composite)
	defer tracy.zone_end(zone_comp)

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

	// Unit 0: Active volumetric texture
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, active_tex)

	// Unit 1: Unblurred volumetric texture
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, volumetric_get_unblurred_texture(vr))

	// Unit 2: Edge discontinuity mask
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, discontinuity_tex)

	// Unit 3: Low-res linear depth
	gl.ActiveTexture(gl.TEXTURE3)
	gl.BindTexture(gl.TEXTURE_2D, low_res_depth_tex)

	// Unit 4: Full-res non-linear depth
	gl.ActiveTexture(gl.TEXTURE4)
	gl.BindTexture(gl.TEXTURE_2D, full_res_depth_tex)

	// JBU Depth-Guided Upsampling Uniforms
	gl.Uniform1i(vr.loc_comp_upsample_mode, vr.params.upsample_mode)
	gl.Uniform1f(vr.loc_comp_upsample_sharpness, vr.params.upsample_sharpness)
	gl.Uniform1f(vr.loc_comp_near_plane, near_plane)
	gl.Uniform1f(vr.loc_comp_far_plane, far_plane)
	gl.Uniform2f(vr.loc_comp_low_res_size, f32(max(1, vr.width)), f32(max(1, vr.height)))

	gl.Uniform1i(vr.loc_comp_composite_mode, vr.params.viewport_debug_mode)
	gl.Uniform1f(vr.loc_comp_exposure_boost, vr.params.preview_exposure_boost)
	gl.Uniform1f(vr.loc_comp_sharpness, vr.params.blur_sharpness)
	gl.Uniform2f(vr.loc_comp_texel_size, 1.0 / f32(max(1, vr.width)), 1.0 / f32(max(1, vr.height)))

	volumetric_timer_begin(&vr.timers, .Composite_Upsample)
	fullscreen_triangle_draw(&vr.triangle)
	volumetric_timer_end(&vr.timers, .Composite_Upsample)

	for u in u32(0)..=4 {
		gl.ActiveTexture(gl.TEXTURE0 + u)
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}
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
	fullscreen_triangle_destroy(&vr.triangle)
	volumetric_timers_destroy(&vr.timers)

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
