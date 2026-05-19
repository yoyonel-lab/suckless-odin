package rendering

import gl "vendor:OpenGL"

import log "../core/log"
import dbg "../core/gl_debug"

// Quad vertices for billboard rendering (triangle strip: 4 verts = 2 tris).
// ISO port of render_utils_create_quad_vbo() from suckless-ogl.
@(private, rodata)
quad_vertices := [12]f32{
	-0.5,  0.5, 0.0,
	-0.5, -0.5, 0.0,
	 0.5,  0.5, 0.0,
	 0.5, -0.5, 0.0,
}

// Billboard rendering resources for a single sphere (MVP).
// Will evolve to instanced multi-sphere later.
Billboard :: struct {
	vao:      u32,
	quad_vbo: u32,
}

// Creates the billboard quad geometry (VAO + VBO).
billboard_create :: proc(bb: ^Billboard) {
	gl.GenVertexArrays(1, &bb.vao)
	gl.GenBuffers(1, &bb.quad_vbo)

	gl.BindVertexArray(bb.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, bb.quad_vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		size_of(quad_vertices),
		&quad_vertices,
		gl.STATIC_DRAW,
	)

	// Layout 0: position (vec3)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)

	gl.BindVertexArray(0)

	dbg.object_label(gl.VERTEX_ARRAY, bb.vao, "Billboard_VAO")
	dbg.object_label(gl.BUFFER, bb.quad_vbo, "Billboard_QuadVBO")

	log.log_info("suckless-odin.billboard", "Billboard quad created")
}

// Draws the billboard quad (triangle strip, 4 vertices).
billboard_draw :: proc(bb: ^Billboard) {
	if bb.vao == 0 { return }

	// Disable face culling for billboards (both sides visible)
	culling_enabled := gl.IsEnabled(gl.CULL_FACE)
	gl.Disable(gl.CULL_FACE)

	gl.BindVertexArray(bb.vao)
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)

	if culling_enabled {
		gl.Enable(gl.CULL_FACE)
	}
}

// Cleans up billboard GPU resources.
billboard_destroy :: proc(bb: ^Billboard) {
	if bb.vao != 0 {
		gl.DeleteVertexArrays(1, &bb.vao)
		bb.vao = 0
	}
	if bb.quad_vbo != 0 {
		gl.DeleteBuffers(1, &bb.quad_vbo)
		bb.quad_vbo = 0
	}
}
