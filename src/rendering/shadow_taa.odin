package rendering

import gl "vendor:OpenGL"
import "../core/log"
import "../core/gl_state"
import dbg "../core/gl_debug"
import "../core/tracy"
import mt "../core/math_types"
import "shader"

// Tracy profiler source location
srcloc_shadow_taa := tracy.Source_Location_Data{
	name     = "Shadow_TAA",
	function = "shadow_taa_render",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_GPU_SHADOW,
}

Shadow_TAA_Params :: struct {
	enabled:             bool,
	mode:                i32,  // 0: Off (Raw Passthrough), 1: Simple EMA Blend, 2: TAA Reprojection
	alpha:               f32,  // Current frame blend weight (default 0.15, range 0.01..1.00)
	depth_threshold:     f32,  // Disocclusion depth tolerance in meters (default 0.30)
	clamping_enabled:    bool, // 3x3 neighborhood bounding box clamping
	temporal_jitter:     bool, // Golden-Ratio frame rotation
}

Shadow_TAA :: struct {
	width, height:        i32,
	history_fbo:          [2]u32,
	history_tex:          [2]u32,
	acceptance_tex:       u32,
	history_idx:          int,
	history_valid:        bool,
	prev_view_proj:       mt.Mat4,
	prev_inv_view_proj:   mt.Mat4,
	prev_cam_pos:         mt.Vec3,

	// Shader program & uniform locations
	program:              u32,
	loc_inv_view_proj:    i32,
	loc_prev_view_proj:   i32,
	loc_cam_pos:          i32,
	loc_prev_cam_pos:     i32,
	loc_near_plane:       i32,
	loc_far_plane:        i32,
	loc_taa_mode:         i32,
	loc_alpha:            i32,
	loc_depth_threshold:  i32,
	loc_clamping_enabled: i32,
	loc_history_valid:    i32,

	triangle:             Fullscreen_Triangle,
	params:               Shadow_TAA_Params,
}

shadow_taa_default_params :: proc() -> Shadow_TAA_Params {
	return Shadow_TAA_Params{
		enabled          = true,
		mode             = 2, // TAA Reprojection
		alpha            = 0.15,
		depth_threshold  = 0.30,
		clamping_enabled = true,
		temporal_jitter  = true,
	}
}

shadow_taa_create_fbo_textures :: proc(st: ^Shadow_TAA, width, height: i32) -> bool {
	st.width = max(1, width)
	st.height = max(1, height)

	// 1. Acceptance Map Texture (GL_RGBA8)
	gl.GenTextures(1, &st.acceptance_tex)
	gl.BindTexture(gl.TEXTURE_2D, st.acceptance_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, st.width, st.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	dbg.object_label(gl.TEXTURE, st.acceptance_tex, "Shadow_TAA_Acceptance_Tex")

	// 2. Double-buffered History FBOs & Textures (GL_RGBA16F)
	for i in 0..<2 {
		gl.GenTextures(1, &st.history_tex[i])
		gl.BindTexture(gl.TEXTURE_2D, st.history_tex[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, st.width, st.height, 0, gl.RGBA, gl.FLOAT, nil)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		dbg.object_label(gl.TEXTURE, st.history_tex[i], "Shadow_TAA_History_Tex")

		gl.GenFramebuffers(1, &st.history_fbo[i])
		gl.BindFramebuffer(gl.FRAMEBUFFER, st.history_fbo[i])
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, st.history_tex[i], 0)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, st.acceptance_tex, 0)

		history_draw_bufs := [2]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1}
		gl.DrawBuffers(2, &history_draw_bufs[0])

		h_status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
		if h_status != gl.FRAMEBUFFER_COMPLETE {
			log.log_error("suckless-odin.shadow", "Shadow TAA History FBO %d incomplete: 0x%X", i, h_status)
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			return false
		}
		dbg.object_label(gl.FRAMEBUFFER, st.history_fbo[i], "Shadow_TAA_History_FBO")
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	return true
}

shadow_taa_destroy_fbo_textures :: proc(st: ^Shadow_TAA) {
	for i in 0..<2 {
		if st.history_fbo[i] != 0 {
			gl.DeleteFramebuffers(1, &st.history_fbo[i])
			st.history_fbo[i] = 0
		}
		if st.history_tex[i] != 0 {
			gl.DeleteTextures(1, &st.history_tex[i])
			st.history_tex[i] = 0
		}
	}
	if st.acceptance_tex != 0 {
		gl.DeleteTextures(1, &st.acceptance_tex)
		st.acceptance_tex = 0
	}
}

shadow_taa_create :: proc(st: ^Shadow_TAA, width, height: i32) -> bool {
	st.params = shadow_taa_default_params()
	st.history_valid = false
	st.history_idx = 0

	// 1. Load TAA Shader
	st.program = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/shadow_taa.frag") or_return
	st.loc_inv_view_proj    = gl.GetUniformLocation(st.program, "u_inv_view_proj")
	st.loc_prev_view_proj   = gl.GetUniformLocation(st.program, "u_prev_view_proj")
	st.loc_cam_pos          = gl.GetUniformLocation(st.program, "u_cam_pos")
	st.loc_prev_cam_pos     = gl.GetUniformLocation(st.program, "u_prev_cam_pos")
	st.loc_near_plane       = gl.GetUniformLocation(st.program, "u_near_plane")
	st.loc_far_plane        = gl.GetUniformLocation(st.program, "u_far_plane")
	st.loc_taa_mode         = gl.GetUniformLocation(st.program, "u_taa_mode")
	st.loc_alpha            = gl.GetUniformLocation(st.program, "u_alpha")
	st.loc_depth_threshold  = gl.GetUniformLocation(st.program, "u_depth_threshold")
	st.loc_clamping_enabled = gl.GetUniformLocation(st.program, "u_clamping_enabled")
	st.loc_history_valid    = gl.GetUniformLocation(st.program, "u_history_valid")

	gl.UseProgram(st.program)
	gl.Uniform1i(gl.GetUniformLocation(st.program, "u_current_shadow"), 0)
	gl.Uniform1i(gl.GetUniformLocation(st.program, "u_history_shadow"), 1)
	gl.Uniform1i(gl.GetUniformLocation(st.program, "u_current_depth"), 2)
	gl.Uniform1i(gl.GetUniformLocation(st.program, "u_history_depth"), 3)
	gl.UseProgram(0)

	// 2. Fullscreen Triangle
	fullscreen_triangle_create(&st.triangle)

	// 3. FBO Textures
	if !shadow_taa_create_fbo_textures(st, width, height) {
		return false
	}

	log.log_info("suckless-odin.shadow", "Shadow TAA renderer initialized (%dx%d)", st.width, st.height)
	return true
}

shadow_taa_resize :: proc(st: ^Shadow_TAA, width, height: i32) -> bool {
	if st.width == width && st.height == height { return true }
	shadow_taa_destroy_fbo_textures(st)
	st.history_valid = false
	return shadow_taa_create_fbo_textures(st, width, height)
}

shadow_taa_reset_history :: proc(st: ^Shadow_TAA) {
	st.history_valid = false
}

shadow_taa_render :: proc(
	st: ^Shadow_TAA,
	current_shadow_tex: u32,
	current_depth_tex: u32,
	prev_depth_tex: u32,
	view_proj: ^mt.Mat4,
	inv_view_proj: ^mt.Mat4,
	cam_pos: mt.Vec3,
	near_plane: f32,
	far_plane: f32,
) -> (output_tex: u32) {
	if st.program == 0 {
		return current_shadow_tex
	}

	zone_taa := tracy.zone_begin(&srcloc_shadow_taa)
	dbg.push_group("Shadow_TAA_Pass")

	write_fbo := st.history_fbo[st.history_idx]
	history_tex := st.history_tex[1 - st.history_idx]

	gl.BindFramebuffer(gl.FRAMEBUFFER, write_fbo)
	gl.Viewport(0, 0, st.width, st.height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(st.program)

	// Unit 0: Current Shadow
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, current_shadow_tex)

	// Unit 1: History Shadow
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, history_tex)

	// Unit 2: Current Depth
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, current_depth_tex)

	// Unit 3: History Depth
	gl.ActiveTexture(gl.TEXTURE3)
	gl.BindTexture(gl.TEXTURE_2D, prev_depth_tex)

	// Uniforms
	gl.UniformMatrix4fv(st.loc_inv_view_proj, 1, false, &inv_view_proj[0][0])
	gl.UniformMatrix4fv(st.loc_prev_view_proj, 1, false, &st.prev_view_proj[0][0])
	gl.Uniform3f(st.loc_cam_pos, cam_pos.x, cam_pos.y, cam_pos.z)
	gl.Uniform3f(st.loc_prev_cam_pos, st.prev_cam_pos.x, st.prev_cam_pos.y, st.prev_cam_pos.z)
	gl.Uniform1f(st.loc_near_plane, near_plane)
	gl.Uniform1f(st.loc_far_plane, far_plane)

	gl.Uniform1i(st.loc_taa_mode, st.params.mode if st.params.enabled else 0)
	gl.Uniform1f(st.loc_alpha, st.params.alpha)
	gl.Uniform1f(st.loc_depth_threshold, st.params.depth_threshold)
	gl.Uniform1i(st.loc_clamping_enabled, 1 if st.params.clamping_enabled else 0)
	gl.Uniform1i(st.loc_history_valid, 1 if st.history_valid else 0)

	fullscreen_triangle_draw(&st.triangle)

	for u in u32(0)..=3 {
		gl.ActiveTexture(gl.TEXTURE0 + u)
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}
	gl.UseProgram(0)

	output_tex = st.history_tex[st.history_idx]

	// Advance ping-pong state
	st.history_idx = 1 - st.history_idx
	st.prev_view_proj = view_proj^
	st.prev_inv_view_proj = inv_view_proj^
	st.prev_cam_pos = cam_pos
	st.history_valid = true

	gl_state.reset()
	dbg.pop_group()
	tracy.zone_end(zone_taa)
	return output_tex
}

shadow_taa_destroy :: proc(st: ^Shadow_TAA) {
	shadow_taa_destroy_fbo_textures(st)
	fullscreen_triangle_destroy(&st.triangle)
	if st.program != 0 {
		gl.DeleteProgram(st.program)
		st.program = 0
	}
}
