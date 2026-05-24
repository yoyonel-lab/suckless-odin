package rendering

import gl "vendor:OpenGL"
import "core:os"

import log "../core/log"
import dbg "../core/gl_debug"
import mt  "../core/math_types"

Skybox_Mode :: enum i32 {
	Equirectangular = 0,
	Cubemap         = 1,
}

Mipmap_Mode :: enum i32 {
	Gl_Generate = 0,   // glGenerateMipmap (fast, has seams)
	Seamless    = 1,   // Manual downsample with cross-face filtering (no seams)
}

Blur_Source :: enum i32 {
	Mipmap_Lod    = 0,   // Standard mipmap LOD sampling (cubemap or equirect)
	IBL_Prefilter = 1,   // IBL prefiltered specular map (physically-based blur)
}

// Skybox renders the HDR environment as background.
// Supports equirectangular (2D) or cubemap sampling.
Skybox :: struct {
	program_equirect:   u32,
	program_cubemap:    u32,
	program_downsample: u32,         // for seamless mipmap generation
	program_diff:       u32,         // debug: amplified difference view
	env_tex:            u32,         // HDR 2D texture (equirectangular)
	ibl_prefilter_tex:  u32,         // IBL prefiltered specular map (2D equirect)
	cubemap_tex:        u32,         // Active cubemap (current mipmap_mode)
	cubemap_gl:         u32,         // Cubemap with glGenerateMipmap
	cubemap_seamless:   u32,         // Cubemap with seamless mipmaps
	fullscr_vao:        u32,         // empty VAO for fullscreen draw
	blur_lod:           f32,         // mip level for blur effect
	diff_gain:          f32,         // amplification for diff debug view
	mode:               Skybox_Mode,
	mipmap_mode:        Mipmap_Mode,
	blur_source:        Blur_Source,
	show_diff:          bool,        // debug: show amplified mipmap diff
	cubemap_dirty:      bool,        // set by GUI to trigger cubemap regeneration
}

skybox_create :: proc(sky: ^Skybox, env_tex: u32, ibl_prefilter_tex: u32, vert_path, frag_path: string) -> bool {
	sky.env_tex = env_tex
	sky.ibl_prefilter_tex = ibl_prefilter_tex
	sky.blur_lod = 0.0
	sky.diff_gain = 10.0
	sky.mode = .Equirectangular
	sky.mipmap_mode = .Seamless

	// Load equirectangular skybox shader
	sky.program_equirect = load_skybox_shader(vert_path, frag_path) or_return

	// Load cubemap skybox shader
	sky.program_cubemap = load_skybox_shader(vert_path, "shaders/background_cubemap.frag") or_return

	// Load downsample shader (for seamless mipmap generation)
	sky.program_downsample = load_skybox_shader(
		"shaders/equirect_to_cubemap.vert", "shaders/downsample_cubemap.frag",
	) or_return

	// Load diff debug shader (compares standard blur vs IBL prefilter)
	sky.program_diff = load_skybox_shader(vert_path, "shaders/background_blur_diff.frag") or_return

	// Enable seamless cubemap filtering (cross-face bilinear at sample time)
	gl.Enable(gl.TEXTURE_CUBE_MAP_SEAMLESS)

	// Generate both cubemap variants for comparison
	sky.cubemap_gl = equirect_to_cubemap(env_tex, sky.program_downsample, .Gl_Generate)
	if sky.cubemap_gl == 0 {
		log.log_error("suckless-odin.skybox", "Failed to create cubemap (glGenerateMipmap)")
		return false
	}
	sky.cubemap_seamless = equirect_to_cubemap(env_tex, sky.program_downsample, .Seamless)
	if sky.cubemap_seamless == 0 {
		log.log_error("suckless-odin.skybox", "Failed to create cubemap (seamless)")
		return false
	}

	// Set active cubemap based on mode
	sky.cubemap_tex = sky.cubemap_seamless if sky.mipmap_mode == .Seamless else sky.cubemap_gl

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

	log.log_info("suckless-odin.skybox", "Skybox created (equirect=%d, cubemap=%d)",
		sky.program_equirect, sky.program_cubemap)
	return true
}

// Render the skybox. Must be called BEFORE opaque geometry with depth func <= .
skybox_render :: proc(sky: ^Skybox, view, proj: mt.Mat4) {
	// Choose program based on mode and debug state
	program: u32
	if sky.show_diff {
		program = sky.program_diff
	} else if sky.blur_source == .IBL_Prefilter && sky.ibl_prefilter_tex != 0 {
		program = sky.program_equirect
	} else if sky.mode == .Cubemap {
		program = sky.program_cubemap
	} else {
		program = sky.program_equirect
	}
	if program == 0 { return }

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

	gl.UseProgram(program)

	// uniform layout(location = 0) m_inv_view_proj
	gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

	// Bind textures based on mode
	switch {
	case sky.show_diff:
		// Diff mode: compare standard mip blur vs IBL prefilter
		// Bind standard source (equirect env) on unit 0
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, sky.env_tex)
		// Bind IBL prefilter on unit 1
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_2D, sky.ibl_prefilter_tex)
		// blur_lod for standard, prefilter_lod for IBL
		gl.Uniform1f(4, sky.blur_lod)
		prefilter_lod := sky.blur_lod * (f32(PREFILTER_MIP_LEVELS - 1) / 8.0)
		gl.Uniform1f(5, prefilter_lod)
		gl.Uniform1f(6, sky.diff_gain)
	case sky.blur_source == .IBL_Prefilter && sky.ibl_prefilter_tex != 0:
		// IBL prefilter mode: use equirect shader with prefilter map
		// Map blur_lod [0..8] → prefilter mip [0..4]
		prefilter_lod := sky.blur_lod * (f32(PREFILTER_MIP_LEVELS - 1) / 8.0)
		gl.Uniform1f(4, prefilter_lod)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, sky.ibl_prefilter_tex)
	case sky.mode == .Cubemap:
		gl.Uniform1f(4, sky.blur_lod)
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, sky.cubemap_tex)
	case:
		gl.Uniform1f(4, sky.blur_lod)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, sky.env_tex)
	}

	gl.BindVertexArray(sky.fullscr_vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.DepthFunc(u32(prev_depth_func))
	gl.UseProgram(0)
}

skybox_destroy :: proc(sky: ^Skybox) {
	if sky.program_equirect != 0 {
		gl.DeleteProgram(sky.program_equirect)
		sky.program_equirect = 0
	}
	if sky.program_cubemap != 0 {
		gl.DeleteProgram(sky.program_cubemap)
		sky.program_cubemap = 0
	}
	if sky.program_downsample != 0 {
		gl.DeleteProgram(sky.program_downsample)
		sky.program_downsample = 0
	}
	if sky.program_diff != 0 {
		gl.DeleteProgram(sky.program_diff)
		sky.program_diff = 0
	}
	if sky.cubemap_gl != 0 {
		gl.DeleteTextures(1, &sky.cubemap_gl)
		sky.cubemap_gl = 0
	}
	if sky.cubemap_seamless != 0 {
		gl.DeleteTextures(1, &sky.cubemap_seamless)
		sky.cubemap_seamless = 0
	}
	sky.cubemap_tex = 0
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

// Convert an equirectangular 2D HDR texture to a cubemap.
// Renders 6 faces using FBO + equirect sampling shader.
// mipmap_mode controls how mipmaps are generated:
//   .Gl_Generate — uses glGenerateMipmap (per-face, has seams at higher mips)
//   .Seamless    — manual downsample with GL_TEXTURE_CUBE_MAP_SEAMLESS (cross-face, no seams)
CUBEMAP_FACE_SIZE :: 1024
CUBEMAP_MIP_LEVELS :: 11

@(private)
equirect_to_cubemap :: proc(env_tex: u32, downsample_prog: u32, mipmap_mode: Mipmap_Mode) -> u32 {
	cubemap: u32
	gl.GenTextures(1, &cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, cubemap)

	// Allocate all 6 faces at all mip levels
	for mip in 0..<i32(CUBEMAP_MIP_LEVELS) {
		mip_size := i32(CUBEMAP_FACE_SIZE) >> u32(mip)
		if mip_size < 1 { mip_size = 1 }
		for face in 0..<6 {
			gl.TexImage2D(
				gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face),
				mip, gl.RGBA16F,
				mip_size, mip_size,
				0, gl.RGBA, gl.FLOAT, nil,
			)
		}
	}
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)

	// FBO for rendering to each face
	fbo: u32
	gl.GenFramebuffers(1, &fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)

	// Load conversion shader
	convert_prog, conv_ok := load_skybox_shader("shaders/equirect_to_cubemap.vert", "shaders/equirect_to_cubemap.frag")
	if !conv_ok {
		gl.DeleteTextures(1, &cubemap)
		gl.DeleteFramebuffers(1, &fbo)
		return 0
	}

	// View matrices for each cubemap face (looking outward from origin)
	face_views := [6]mt.Mat4{
		mt.look_at({0, 0, 0}, { 1,  0,  0}, {0, -1,  0}), // +X
		mt.look_at({0, 0, 0}, {-1,  0,  0}, {0, -1,  0}), // -X
		mt.look_at({0, 0, 0}, { 0,  1,  0}, {0,  0,  1}), // +Y
		mt.look_at({0, 0, 0}, { 0, -1,  0}, {0,  0, -1}), // -Y
		mt.look_at({0, 0, 0}, { 0,  0,  1}, {0, -1,  0}), // +Z
		mt.look_at({0, 0, 0}, { 0,  0, -1}, {0, -1,  0}), // -Z
	}

	// 90° FOV projection for cubemap face
	proj := mt.perspective(mt.radians(90.0), 1.0, 0.1, 10.0)

	// Save/restore viewport
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	// Fullscreen triangle for rendering
	conv_vao: u32
	gl.GenVertexArrays(1, &conv_vao)
	gl.BindVertexArray(conv_vao)
	verts := [9]f32{-1.0, -1.0, 0.0, 3.0, -1.0, 0.0, -1.0, 3.0, 0.0}
	vbo: u32
	gl.GenBuffers(1, &vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)

	// === Pass 1: Render mip 0 from equirectangular ===
	gl.Viewport(0, 0, CUBEMAP_FACE_SIZE, CUBEMAP_FACE_SIZE)
	gl.UseProgram(convert_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, env_tex)

	for face in 0..<6 {
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
			gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face), cubemap, 0)

		inv_vp := mt.mat4_inverse(mt.mat4_mul(proj, face_views[face]))
		gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

		gl.Clear(gl.COLOR_BUFFER_BIT)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)
	}

	// === Pass 2: Generate mipmaps ===
	switch mipmap_mode {
	case .Gl_Generate:
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, cubemap)
		gl.GenerateMipmap(gl.TEXTURE_CUBE_MAP)

	case .Seamless:
		// Manual downsample: for each mip level, render by sampling the previous
		// mip of the cubemap. GL_TEXTURE_CUBE_MAP_SEAMLESS provides cross-face
		// filtering, producing seamless mipmaps without face boundary artifacts.
		gl.UseProgram(downsample_prog)
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, cubemap)

		// Clamp max LOD to prevent sampling from uninitialized higher mips
		gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, 0)

		for mip in 1..<i32(CUBEMAP_MIP_LEVELS) {
			mip_size := i32(CUBEMAP_FACE_SIZE) >> u32(mip)
			if mip_size < 1 { mip_size = 1 }
			gl.Viewport(0, 0, mip_size, mip_size)

			// Allow reading up to mip-1 (previous level we just wrote)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, mip - 1)

			// Source LOD = previous mip level
			gl.Uniform1f(4, f32(mip - 1))

			for face in 0..<6 {
				gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
					gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face), cubemap, mip)

				inv_vp := mt.mat4_inverse(mt.mat4_mul(proj, face_views[face]))
				gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

				gl.DrawArrays(gl.TRIANGLES, 0, 3)
			}
		}

		// Restore max level to allow full mipchain sampling
		gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, CUBEMAP_MIP_LEVELS - 1)
	}

	// Cleanup
	gl.DeleteBuffers(1, &vbo)
	gl.DeleteVertexArrays(1, &conv_vao)
	gl.DeleteFramebuffers(1, &fbo)
	gl.DeleteProgram(convert_prog)

	// Restore viewport
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	dbg.object_label(gl.TEXTURE, cubemap, "Skybox_Cubemap")
	log.log_info("suckless-odin.skybox", "Cubemap created from equirect (%dx%d, %d mip levels, mode=%v)",
		CUBEMAP_FACE_SIZE, CUBEMAP_FACE_SIZE, CUBEMAP_MIP_LEVELS, mipmap_mode)

	return cubemap
}

// Switch active cubemap based on current mipmap_mode (called from GUI toggle).
skybox_regenerate_cubemap :: proc(sky: ^Skybox) {
	sky.cubemap_tex = sky.cubemap_seamless if sky.mipmap_mode == .Seamless else sky.cubemap_gl
	log.log_info("suckless-odin.skybox", "Cubemap switched to mode=%v", sky.mipmap_mode)
}
