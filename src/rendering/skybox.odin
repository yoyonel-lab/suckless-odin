package rendering

import gl "vendor:OpenGL"
import "core:os"

import log "../core/log"
import dbg "../core/gl_debug"
import mt  "../core/math_types"

// Skybox renders the HDR environment as an equirectangular background.
// Uses a fullscreen triangle (3 vertices, no VBO needed with gl_VertexID).
Skybox :: struct {
	program:     u32,
	env_tex:     u32,     // HDR texture to display
	fullscr_vao: u32,     // empty VAO for fullscreen draw
	blur_lod:    f32,     // mip level for blur effect
}

skybox_create :: proc(sky: ^Skybox, env_tex: u32, vert_path, frag_path: string) -> bool {
	sky.env_tex = env_tex
	sky.blur_lod = 0.0

	// Load skybox shader
	sky.program = load_skybox_shader(vert_path, frag_path) or_return

	// Fullscreen quad VAO (we'll provide vertices via a VBO for the background.vert)
	gl.GenVertexArrays(1, &sky.fullscr_vao)
	gl.BindVertexArray(sky.fullscr_vao)

	// Create a fullscreen triangle (covers clip space)
	fullscr_verts := [9]f32{
		-1.0, -1.0, 0.0,
		 3.0, -1.0, 0.0,
		-1.0,  3.0, 0.0,
	}

	vbo: u32
	gl.GenBuffers(1, &vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(fullscr_verts), &fullscr_verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)

	gl.BindVertexArray(0)

	dbg.object_label(gl.VERTEX_ARRAY, sky.fullscr_vao, "Skybox_VAO")

	log.log_info("suckless-odin.skybox", "Skybox created (program=%d)", sky.program)
	return true
}

// Render the skybox. Must be called BEFORE opaque geometry with depth func <= .
skybox_render :: proc(sky: ^Skybox, view, proj: mt.Mat4) {
	if sky.program == 0 { return }

	// Remove translation from view matrix
	view_no_translate := view
	view_no_translate[3][0] = 0.0
	view_no_translate[3][1] = 0.0
	view_no_translate[3][2] = 0.0

	// Compute inverse view-proj
	vp := mt.mat4_mul(proj, view_no_translate)
	inv_vp := mt.mat4_inverse(vp)

	// Draw skybox at far depth (lequal)
	prev_depth_func: i32
	gl.GetIntegerv(gl.DEPTH_FUNC, &prev_depth_func)
	gl.DepthFunc(gl.LEQUAL)

	gl.UseProgram(sky.program)

	// uniform layout(location = 0) m_inv_view_proj
	gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

	// uniform layout(location = 4) blur_lod
	gl.Uniform1f(4, sky.blur_lod)

	// Bind environment map to unit 0
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, sky.env_tex)

	gl.BindVertexArray(sky.fullscr_vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.DepthFunc(u32(prev_depth_func))
	gl.UseProgram(0)
}

skybox_destroy :: proc(sky: ^Skybox) {
	if sky.program != 0 {
		gl.DeleteProgram(sky.program)
		sky.program = 0
	}
	if sky.fullscr_vao != 0 {
		gl.DeleteVertexArrays(1, &sky.fullscr_vao)
		sky.fullscr_vao = 0
	}
}

@(private)
load_skybox_shader :: proc(vert_path, frag_path: string) -> (u32, bool) {
	vert_data, vert_err := os.read_entire_file_from_path(vert_path, context.allocator)
	if vert_err != nil {
		log.log_error("suckless-odin.skybox", "Failed to read %s", vert_path)
		return 0, false
	}
	defer delete(vert_data)

	frag_data, frag_err := os.read_entire_file_from_path(frag_path, context.allocator)
	if frag_err != nil {
		log.log_error("suckless-odin.skybox", "Failed to read %s", frag_path)
		return 0, false
	}
	defer delete(frag_data)

	program, ok := gl.load_shaders_source(string(vert_data), string(frag_data))
	if !ok {
		log.log_error("suckless-odin.skybox", "Shader compilation failed: %s + %s", vert_path, frag_path)
		return 0, false
	}

	bin_size: i32
	gl.GetProgramiv(program, gl.PROGRAM_BINARY_LENGTH, &bin_size)
	log.log_info("Shader", "Linked shader program '%s + %s' (ID %d). Binary size: %d bytes",
		vert_path, frag_path, program, bin_size)

	return program, true
}
