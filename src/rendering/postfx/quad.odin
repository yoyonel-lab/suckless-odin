package postfx

import gl "vendor:OpenGL"

// Fullscreen triangle vertices (covers entire screen with a single triangle).
// More efficient than a quad: no diagonal seam, 3 vertices instead of 4.
// Vertex positions in clip space — fragment shader uses gl_FragCoord for UVs.
@(private, rodata)
fullscreen_triangle_verts := [6]f32{
	-1.0, -1.0,
	 3.0, -1.0,
	-1.0,  3.0,
}

// Fullscreen quad resources for post-processing passes.
Fullscreen_Quad :: struct {
	vao: u32,
	vbo: u32,
}

// Create the fullscreen triangle VAO/VBO.
quad_create :: proc(q: ^Fullscreen_Quad) {
	gl.GenVertexArrays(1, &q.vao)
	gl.GenBuffers(1, &q.vbo)

	gl.BindVertexArray(q.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, q.vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		size_of(fullscreen_triangle_verts),
		&fullscreen_triangle_verts,
		gl.STATIC_DRAW,
	)

	// Layout 0: position (vec2)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)

	gl.BindVertexArray(0)
}

// Draw the fullscreen triangle (3 vertices, single triangle covers screen).
quad_draw :: proc(q: ^Fullscreen_Quad) {
	gl.BindVertexArray(q.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
}

// Destroy fullscreen quad resources.
quad_destroy :: proc(q: ^Fullscreen_Quad) {
	delete_buffer(&q.vbo)
	if q.vao != 0 {
		gl.DeleteVertexArrays(1, &q.vao)
		q.vao = 0
	}
}
