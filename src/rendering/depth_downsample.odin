package rendering

import gl "vendor:OpenGL"

import dbg "../core/gl_debug"
import log "../core/log"
import gl_state "../core/gl_state"
import shader "./shader"

// Fullscreen triangle for downsampling pass
@(private, rodata)
fullscreen_quad_verts := [6]f32{
	-1.0, -1.0,
	 3.0, -1.0,
	-1.0,  3.0,
}

// Depth downsample state: produces half-resolution linear depth and geometric edge mask
Depth_Downsample :: struct {
	fbo:                u32,
	low_res_depth_tex:  u32, // GL_R32F, W/2 x H/2 (Linear view space depth in meters)
	discontinuity_tex:  u32, // GL_R8,   W/2 x H/2 (0 or 1 edge mask)
	full_width:         i32,
	full_height:        i32,
	width:              i32, // Low-res width (W / 2)
	height:             i32, // Low-res height (H / 2)
	edge_threshold:     f32, // Discontinuity threshold in meters (default 0.25)

	// Downsample program & uniforms
	program:            u32,
	loc_texel_size:     i32,
	loc_near_plane:     i32,
	loc_far_plane:      i32,
	loc_edge_threshold: i32,
	vao:                u32,
	vbo:                u32,

	// Preview RGBA texture for Dear ImGui Inspector
	preview_fbo:        u32,
	preview_tex:        u32, // GL_RGBA8, W/2 x H/2
	preview_program:    u32,
	preview_loc_mode:   i32,
	preview_loc_min:    i32,
	preview_loc_max:    i32,
	preview_mode:       i32, // 0: Turbo Heatmap, 1: Linear Grayscale, 2: Discontinuity Mask
	preview_min_depth:  f32, // default 0.5 m
	preview_max_depth:  f32, // default 35.0 m
	preview_dirty:      bool,
}

// Creates the depth downsample pass resources
depth_downsample_create :: proc(dd: ^Depth_Downsample, full_width, full_height: i32) -> bool {
	dd.full_width = max(2, full_width)
	dd.full_height = max(2, full_height)
	dd.width = max(1, full_width / 2)
	dd.height = max(1, full_height / 2)
	dd.edge_threshold = 0.25 // 25 cm depth step
	dd.preview_mode = 0 // Turbo Heatmap
	dd.preview_min_depth = 0.5
	dd.preview_max_depth = 35.0

	// 1. Shaders
	dd.program = shader.load_program("shaders/postfx/postfx.vert", "shaders/depth_downsample.frag") or_return
	dd.loc_texel_size = gl.GetUniformLocation(dd.program, "u_texel_size")
	dd.loc_near_plane = gl.GetUniformLocation(dd.program, "u_near_plane")
	dd.loc_far_plane = gl.GetUniformLocation(dd.program, "u_far_plane")
	dd.loc_edge_threshold = gl.GetUniformLocation(dd.program, "u_edge_threshold")

	dd.preview_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/debug_depth_preview.frag") or_return
	dd.preview_loc_mode = gl.GetUniformLocation(dd.preview_program, "u_mode")
	dd.preview_loc_min = gl.GetUniformLocation(dd.preview_program, "u_min_depth")
	dd.preview_loc_max = gl.GetUniformLocation(dd.preview_program, "u_max_depth")

	// 2. Fullscreen Triangle VAO
	gl.GenVertexArrays(1, &dd.vao)
	gl.GenBuffers(1, &dd.vbo)
	gl.BindVertexArray(dd.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, dd.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(fullscreen_quad_verts), &fullscreen_quad_verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)
	gl.BindVertexArray(0)

	// 3. Create Textures and FBO
	create_fbo(dd) or_return

	dbg.object_label(gl.FRAMEBUFFER, dd.fbo, "Depth_Downsample_FBO")
	dbg.object_label(gl.TEXTURE, dd.low_res_depth_tex, "Low_Res_Depth_Tex")
	dbg.object_label(gl.TEXTURE, dd.discontinuity_tex, "Depth_Discontinuity_Tex")
	dbg.object_label(gl.TEXTURE, dd.preview_tex, "Depth_Preview_Tex")

	log.log_info("suckless-odin.volumetric", "Depth downsampler created (%dx%d -> %dx%d)", dd.full_width, dd.full_height, dd.width, dd.height)
	return true
}

@(private)
create_fbo :: proc(dd: ^Depth_Downsample) -> bool {
	// Low-res linear depth texture (GL_R32F)
	gl.GenTextures(1, &dd.low_res_depth_tex)
	gl.BindTexture(gl.TEXTURE_2D, dd.low_res_depth_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R32F, dd.width, dd.height, 0, gl.RED, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	// Low-res geometric discontinuity mask (GL_R8)
	gl.GenTextures(1, &dd.discontinuity_tex)
	gl.BindTexture(gl.TEXTURE_2D, dd.discontinuity_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, dd.width, dd.height, 0, gl.RED, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	// FBO with 2 color attachments
	gl.GenFramebuffers(1, &dd.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, dd.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, dd.low_res_depth_tex, 0)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, dd.discontinuity_tex, 0)

	draw_buffers := [2]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1}
	gl.DrawBuffers(2, &draw_buffers[0])

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.volumetric", "Depth downsample FBO incomplete: 0x%X", status)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return false
	}

	// Preview RGBA texture & FBO
	gl.GenTextures(1, &dd.preview_tex)
	gl.BindTexture(gl.TEXTURE_2D, dd.preview_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, dd.width, dd.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenFramebuffers(1, &dd.preview_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, dd.preview_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, dd.preview_tex, 0)

	preview_draw_buf := [1]u32{gl.COLOR_ATTACHMENT0}
	gl.DrawBuffers(1, &preview_draw_buf[0])

	preview_status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if preview_status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.volumetric", "Depth preview FBO incomplete: 0x%X", preview_status)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return false
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	return true
}

@(private)
destroy_fbo :: proc(dd: ^Depth_Downsample) {
	if dd.fbo != 0 {
		gl.DeleteFramebuffers(1, &dd.fbo)
		dd.fbo = 0
	}
	if dd.low_res_depth_tex != 0 {
		gl.DeleteTextures(1, &dd.low_res_depth_tex)
		dd.low_res_depth_tex = 0
	}
	if dd.discontinuity_tex != 0 {
		gl.DeleteTextures(1, &dd.discontinuity_tex)
		dd.discontinuity_tex = 0
	}
	if dd.preview_fbo != 0 {
		gl.DeleteFramebuffers(1, &dd.preview_fbo)
		dd.preview_fbo = 0
	}
	if dd.preview_tex != 0 {
		gl.DeleteTextures(1, &dd.preview_tex)
		dd.preview_tex = 0
	}
}

// Resizes downsampler buffers on viewport changes
depth_downsample_resize :: proc(dd: ^Depth_Downsample, full_width, full_height: i32) {
	if full_width == dd.full_width && full_height == dd.full_height do return
	dd.full_width = max(2, full_width)
	dd.full_height = max(2, full_height)
	dd.width = max(1, full_width / 2)
	dd.height = max(1, full_height / 2)

	destroy_fbo(dd)
	create_fbo(dd)
	log.log_info("suckless-odin.volumetric", "Depth downsampler resized to %dx%d (from %dx%d)", dd.width, dd.height, dd.full_width, dd.full_height)
}

// Executes the Rank/Median 4-tap depth downsample pass
depth_downsample_render :: proc(dd: ^Depth_Downsample, full_depth_tex: u32, near_plane, far_plane: f32) {
	if dd.fbo == 0 || full_depth_tex == 0 do return

	dbg.push_group("Depth_Downsample_Pass")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, dd.fbo)
	gl.Viewport(0, 0, dd.width, dd.height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(dd.program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, full_depth_tex)
	gl.Uniform1i(gl.GetUniformLocation(dd.program, "u_full_depth_tex"), 0)

	gl.Uniform2f(dd.loc_texel_size, 1.0 / f32(dd.full_width), 1.0 / f32(dd.full_height))
	gl.Uniform1f(dd.loc_near_plane, near_plane)
	gl.Uniform1f(dd.loc_far_plane, far_plane)
	gl.Uniform1f(dd.loc_edge_threshold, dd.edge_threshold)

	gl.BindVertexArray(dd.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.BindVertexArray(0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	dd.preview_dirty = true
}

// Updates the Dear ImGui RGBA preview texture on-demand
depth_downsample_update_preview :: proc(dd: ^Depth_Downsample) {
	if dd.preview_fbo == 0 || dd.preview_program == 0 do return

	dbg.push_group("Depth_Preview_Pass")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, dd.preview_fbo)
	gl.Viewport(0, 0, dd.width, dd.height)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(dd.preview_program)
	gl.ActiveTexture(gl.TEXTURE0)

	// Bind source texture based on selected preview mode
	if dd.preview_mode == 2 {
		gl.BindTexture(gl.TEXTURE_2D, dd.discontinuity_tex)
	} else {
		gl.BindTexture(gl.TEXTURE_2D, dd.low_res_depth_tex)
	}
	gl.Uniform1i(gl.GetUniformLocation(dd.preview_program, "u_tex"), 0)
	gl.Uniform1i(dd.preview_loc_mode, dd.preview_mode)
	gl.Uniform1f(dd.preview_loc_min, dd.preview_min_depth)
	gl.Uniform1f(dd.preview_loc_max, dd.preview_max_depth)

	gl.BindVertexArray(dd.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.BindVertexArray(0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)

	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	dd.preview_dirty = false
}

// Releases all GPU resources
depth_downsample_destroy :: proc(dd: ^Depth_Downsample) {
	destroy_fbo(dd)

	if dd.vao != 0 {
		gl.DeleteVertexArrays(1, &dd.vao)
		dd.vao = 0
	}
	if dd.vbo != 0 {
		gl.DeleteBuffers(1, &dd.vbo)
		dd.vbo = 0
	}
	if dd.program != 0 {
		gl.DeleteProgram(dd.program)
		dd.program = 0
	}
	if dd.preview_program != 0 {
		gl.DeleteProgram(dd.preview_program)
		dd.preview_program = 0
	}
	dd^ = {}
}
