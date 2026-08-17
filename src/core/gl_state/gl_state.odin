package gl_state

// High-Performance OpenGL State Cache Layer.
// Filters redundant driver state transitions (glUseProgram, glBindVertexArray,
// glActiveTexture, glBindTexture, glViewport, etc.) to minimize CPU overhead in Mesa Gallium.

import gl "vendor:OpenGL"

MAX_TEXTURE_UNITS :: 32

GL_State :: struct {
	current_program:     u32,
	current_vao:         u32,
	current_draw_fbo:    u32,
	current_read_fbo:    u32,
	active_texture_unit: u32, // GL_TEXTURE0 .. GL_TEXTURE31
	bound_textures_2d:   [MAX_TEXTURE_UNITS]u32,
	bound_textures_cube: [MAX_TEXTURE_UNITS]u32,
	viewport_x:          i32,
	viewport_y:          i32,
	viewport_w:          i32,
	viewport_h:          i32,
	blend_enabled:       i8, // -1: unknown, 0: false, 1: true
	depth_test_enabled:  i8,
	cull_face_enabled:   i8,
}

@private
s_state := GL_State{
	current_program     = 0xFFFFFFFF,
	current_vao         = 0xFFFFFFFF,
	current_draw_fbo    = 0xFFFFFFFF,
	current_read_fbo    = 0xFFFFFFFF,
	active_texture_unit = 0xFFFFFFFF,
	viewport_x          = -1,
	viewport_y          = -1,
	viewport_w          = -1,
	viewport_h          = -1,
	blend_enabled       = -1,
	depth_test_enabled  = -1,
	cull_face_enabled   = -1,
}

// Invalidate state cache when external systems (like Dear ImGui) mutate OpenGL state directly
reset :: proc() {
	s_state.current_program     = 0xFFFFFFFF
	s_state.current_vao         = 0xFFFFFFFF
	s_state.current_draw_fbo    = 0xFFFFFFFF
	s_state.current_read_fbo    = 0xFFFFFFFF
	s_state.active_texture_unit = 0xFFFFFFFF
	for i in 0 ..< MAX_TEXTURE_UNITS {
		s_state.bound_textures_2d[i]   = 0xFFFFFFFF
		s_state.bound_textures_cube[i] = 0xFFFFFFFF
	}
	s_state.viewport_x         = -1
	s_state.viewport_y         = -1
	s_state.viewport_w         = -1
	s_state.viewport_h         = -1
	s_state.blend_enabled      = -1
	s_state.depth_test_enabled = -1
	s_state.cull_face_enabled  = -1
}

// Filtered glUseProgram
use_program :: proc(program: u32) {
	if s_state.current_program == program {
		return
	}
	gl.UseProgram(program)
	s_state.current_program = program
}

// Filtered glBindVertexArray
bind_vertex_array :: proc(vao: u32) {
	if s_state.current_vao == vao {
		return
	}
	gl.BindVertexArray(vao)
	s_state.current_vao = vao
}

// Filtered glBindFramebuffer
bind_framebuffer :: proc(target: u32, fbo: u32) {
	switch target {
	case gl.FRAMEBUFFER:
		if s_state.current_draw_fbo == fbo && s_state.current_read_fbo == fbo {
			return
		}
		gl.BindFramebuffer(target, fbo)
		s_state.current_draw_fbo = fbo
		s_state.current_read_fbo = fbo
	case gl.DRAW_FRAMEBUFFER:
		if s_state.current_draw_fbo == fbo {
			return
		}
		gl.BindFramebuffer(target, fbo)
		s_state.current_draw_fbo = fbo
	case gl.READ_FRAMEBUFFER:
		if s_state.current_read_fbo == fbo {
			return
		}
		gl.BindFramebuffer(target, fbo)
		s_state.current_read_fbo = fbo
	}
}

// Filtered glActiveTexture
active_texture :: proc(unit: u32) {
	if s_state.active_texture_unit == unit {
		return
	}
	gl.ActiveTexture(unit)
	s_state.active_texture_unit = unit
}

// Filtered glBindTexture
bind_texture :: proc(target: u32, texture: u32) {
	unit_idx := u32(0)
	if s_state.active_texture_unit >= gl.TEXTURE0 && s_state.active_texture_unit < gl.TEXTURE0 + MAX_TEXTURE_UNITS {
		unit_idx = s_state.active_texture_unit - gl.TEXTURE0
	}

	switch target {
	case gl.TEXTURE_2D:
		if unit_idx < MAX_TEXTURE_UNITS && s_state.bound_textures_2d[unit_idx] == texture {
			return
		}
		gl.BindTexture(target, texture)
		if unit_idx < MAX_TEXTURE_UNITS {
			s_state.bound_textures_2d[unit_idx] = texture
		}
	case gl.TEXTURE_CUBE_MAP:
		if unit_idx < MAX_TEXTURE_UNITS && s_state.bound_textures_cube[unit_idx] == texture {
			return
		}
		gl.BindTexture(target, texture)
		if unit_idx < MAX_TEXTURE_UNITS {
			s_state.bound_textures_cube[unit_idx] = texture
		}
	case:
		gl.BindTexture(target, texture)
	}
}

// Filtered glViewport
set_viewport :: proc(x, y, w, h: i32) {
	if s_state.viewport_x == x && s_state.viewport_y == y &&
	   s_state.viewport_w == w && s_state.viewport_h == h {
		return
	}
	gl.Viewport(x, y, w, h)
	s_state.viewport_x = x
	s_state.viewport_y = y
	s_state.viewport_w = w
	s_state.viewport_h = h
}

// Filtered gl.Enable
enable :: proc(cap: u32) {
	switch cap {
	case gl.BLEND:
		if s_state.blend_enabled == 1 do return
		gl.Enable(cap)
		s_state.blend_enabled = 1
	case gl.DEPTH_TEST:
		if s_state.depth_test_enabled == 1 do return
		gl.Enable(cap)
		s_state.depth_test_enabled = 1
	case gl.CULL_FACE:
		if s_state.cull_face_enabled == 1 do return
		gl.Enable(cap)
		s_state.cull_face_enabled = 1
	case:
		gl.Enable(cap)
	}
}

// Filtered gl.Disable
disable :: proc(cap: u32) {
	switch cap {
	case gl.BLEND:
		if s_state.blend_enabled == 0 do return
		gl.Disable(cap)
		s_state.blend_enabled = 0
	case gl.DEPTH_TEST:
		if s_state.depth_test_enabled == 0 do return
		gl.Disable(cap)
		s_state.depth_test_enabled = 0
	case gl.CULL_FACE:
		if s_state.cull_face_enabled == 0 do return
		gl.Disable(cap)
		s_state.cull_face_enabled = 0
	case:
		gl.Disable(cap)
	}
}
