package rendering

import gl "vendor:OpenGL"
import dbg "../core/gl_debug"

// Canonical Fullscreen Triangle vertices (covers viewport [-1, 1] with 3 clip-space vertices).
// Single oversized triangle covering viewport; more efficient than a quad: no diagonal seam.
fullscreen_triangle_verts := [6]f32{
	-1.0, -1.0,
	 3.0, -1.0,
	-1.0,  3.0,
}

// Reusable Fullscreen Triangle GPU resources (VAO/VBO).
Fullscreen_Triangle :: struct {
	vao: u32,
	vbo: u32,
}

// Creates the fullscreen triangle VAO/VBO.
fullscreen_triangle_create :: proc(ft: ^Fullscreen_Triangle) {
	gl.GenVertexArrays(1, &ft.vao)
	gl.GenBuffers(1, &ft.vbo)

	gl.BindVertexArray(ft.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ft.vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		size_of(fullscreen_triangle_verts),
		&fullscreen_triangle_verts,
		gl.STATIC_DRAW,
	)

	// Layout 0: vec2 clip position
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)

	gl.BindVertexArray(0)

	dbg.object_label(gl.VERTEX_ARRAY, ft.vao, "Fullscreen_Triangle_VAO")
	dbg.object_label(gl.BUFFER, ft.vbo, "Fullscreen_Triangle_VBO")
}

// Draws the fullscreen triangle (3 vertices, single triangle covers screen).
fullscreen_triangle_draw :: proc(ft: ^Fullscreen_Triangle) {
	if ft.vao == 0 do return
	gl.BindVertexArray(ft.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.BindVertexArray(0)
}

// Destroys fullscreen triangle GPU resources.
fullscreen_triangle_destroy :: proc(ft: ^Fullscreen_Triangle) {
	if ft.vbo != 0 {
		gl.DeleteBuffers(1, &ft.vbo)
		ft.vbo = 0
	}
	if ft.vao != 0 {
		gl.DeleteVertexArrays(1, &ft.vao)
		ft.vao = 0
	}
}
