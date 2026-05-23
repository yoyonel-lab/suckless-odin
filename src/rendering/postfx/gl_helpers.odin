package postfx

import gl "vendor:OpenGL"

// --- GPU Resource Helpers ---
// Idiomatic Odin wrappers for common GL allocation patterns.
// Reduce boilerplate and ensure consistent state.

// Texture filtering modes for create_texture_2d.
Tex_Filter :: enum i32 {
	Nearest = gl.NEAREST,
	Linear  = gl.LINEAR,
}

// Create a 2D texture with standard parameters. Returns the GL handle.
create_texture_2d :: proc(
	width, height: i32,
	internal_format: i32,
	format: u32 = gl.RGBA,
	pixel_type: u32 = gl.FLOAT,
	filter: Tex_Filter = .Linear,
	data: rawptr = nil,
) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, internal_format, width, height, 0, format, pixel_type, data)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(filter))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(filter))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return tex
}

// Delete a GL texture if non-zero, and zero the handle.
delete_texture :: proc(tex: ^u32) {
	if tex^ != 0 {
		gl.DeleteTextures(1, tex)
		tex^ = 0
	}
}

// Delete a GL program if non-zero, and zero the handle.
delete_program :: proc(prog: ^u32) {
	if prog^ != 0 {
		gl.DeleteProgram(prog^)
		prog^ = 0
	}
}

// Delete a GL framebuffer if non-zero, and zero the handle.
delete_fbo :: proc(fbo: ^u32) {
	if fbo^ != 0 {
		gl.DeleteFramebuffers(1, fbo)
		fbo^ = 0
	}
}

// Delete a GL buffer if non-zero, and zero the handle.
delete_buffer :: proc(buf: ^u32) {
	if buf^ != 0 {
		gl.DeleteBuffers(1, buf)
		buf^ = 0
	}
}

// Set a uniform i32 on a program (used for sampler bindings).
set_uniform_i32 :: proc(program: u32, name: cstring, value: i32) {
	loc := gl.GetUniformLocation(program, name)
	if loc >= 0 {
		gl.Uniform1i(loc, value)
	}
}

// Set a uniform f32 on a program (used for compute shader params).
set_uniform_f32 :: proc(program: u32, name: cstring, value: f32) {
	loc := gl.GetUniformLocation(program, name)
	if loc >= 0 {
		gl.Uniform1f(loc, value)
	}
}

// Set all sampler texture unit uniforms on a postfx composite program.
set_sampler_uniforms :: proc(program: u32) {
	set_uniform_i32(program, "screenTexture",       TEX_UNIT_SCENE)
	set_uniform_i32(program, "bloomTexture",        TEX_UNIT_BLOOM)
	set_uniform_i32(program, "depthTexture",        TEX_UNIT_DEPTH)
	set_uniform_i32(program, "autoExposureTexture", TEX_UNIT_EXPOSURE)
	set_uniform_i32(program, "velocityTexture",     TEX_UNIT_VELOCITY)
	set_uniform_i32(program, "dofBlurTexture",      TEX_UNIT_DOF)
	set_uniform_i32(program, "neighborMaxTexture",  TEX_UNIT_NEIGHBOR_MAX)
	set_uniform_i32(program, "tileMaxTexture",      TEX_UNIT_TILE_MAX)
	set_uniform_i32(program, "lut3dTexture",        TEX_UNIT_LUT3D)
}

// Upload Glasbey split-line colors (first 24 entries) as a uniform vec3 array.
// Called once per program variant at creation time (static data).
set_split_colors_uniform :: proc(program: u32) {
	loc := gl.GetUniformLocation(program, "splitColors")
	if loc >= 0 {
		colors := GLASBEY_256
		gl.Uniform3fv(loc, 24, ([^]f32)(raw_data(&colors)))
	}
}
