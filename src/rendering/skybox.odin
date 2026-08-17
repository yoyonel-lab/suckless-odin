package rendering

import gl "vendor:OpenGL"
import "core:os"
import "core:fmt"

import dbg "../core/gl_debug"
import log "../core/log"
import mt  "../core/math_types"
import tracy "../core/tracy"
import settings "../core/settings"

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

Cubemap_Gen_Phase :: enum {
	Init,
	Mip0_Faces,
	Downsample,
	Done,
}

Cubemap_Gen_State :: struct {
	in_progress:   bool,
	cubemap:       u32,
	fbo:           u32,
	convert_prog:  u32,
	vbo:           u32,
	vao:           u32,
	
	mipmap_mode:   Mipmap_Mode,
	phase:         Cubemap_Gen_Phase,
	current_face:  i32,
	current_mip:   i32,
	
	prev_viewport: [4]i32,
}

// Skybox renders the HDR environment as background.
// Supports equirectangular (2D) or cubemap sampling.
Skybox :: struct {
	program_equirect:          u32,
	program_cubemap:           u32,
	program_downsample:        u32,         // for seamless mipmap generation
	program_diff:              u32,         // debug: amplified difference view
	program_equirect_to_cubemap: u32,       // cached conversion shader
	env_tex:                   u32,         // HDR 2D texture (equirectangular)
	ibl_prefilter_tex:         u32,         // IBL prefiltered specular map (2D equirect)
	cubemap_tex:               u32,         // Active cubemap (current mipmap_mode)
	cubemap_gl:                u32,         // Cubemap with glGenerateMipmap
	cubemap_seamless:          u32,         // Cubemap with seamless mipmaps
	fullscr_vao:               u32,         // empty VAO for fullscreen draw
	blur_lod:                  f32,         // mip level for blur effect
	diff_gain:                 f32,         // amplification for diff debug view
	mode:                      Skybox_Mode,
	mipmap_mode:        Mipmap_Mode,
	blur_source:        Blur_Source,
	show_diff:          bool,        // debug: show amplified mipmap diff
	cubemap_dirty:      bool,        // set by GUI to trigger cubemap regeneration
	gen_state:          Cubemap_Gen_State,
	compute_tuning:     settings.Compute_Tuning_Params,
}

skybox_create :: proc(sky: ^Skybox, env_tex: u32, ibl_prefilter_tex: u32, vert_path, frag_path: string, compute_tuning: settings.Compute_Tuning_Params = settings.DEFAULT_COMPUTE_TUNING) -> bool {
	sky.env_tex = env_tex
	sky.ibl_prefilter_tex = ibl_prefilter_tex
	sky.blur_lod = 0.0
	sky.diff_gain = 10.0
	sky.mode = .Equirectangular
	sky.mipmap_mode = .Seamless
	sky.compute_tuning = compute_tuning

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

	// Load conversion shader (compile once, cached for amortized generations)
	sky.program_equirect_to_cubemap = load_skybox_shader(
		"shaders/equirect_to_cubemap.vert", "shaders/equirect_to_cubemap.frag",
	) or_return

	// Enable seamless cubemap filtering (cross-face bilinear at sample time)
	gl.Enable(gl.TEXTURE_CUBE_MAP_SEAMLESS)

	// Generate cubemaps if env texture is available (skipped on initial async load)
	if env_tex != 0 {
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
	}

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
skybox_render :: proc(sky: ^Skybox, view, proj: mt.Mat4, split_enabled: bool = false, split_pos: f32 = 0.5) {
	// Skip rendering if no environment loaded yet (async initial load in progress)
	if sky.env_tex == 0 { return }

	// Choose program based on mode and debug state
	program: u32
	if sky.show_diff {
		program = sky.program_diff
	} else if sky.blur_source == .IBL_Prefilter && sky.ibl_prefilter_tex != 0 {
		program = sky.program_equirect
	} else if sky.mode == .Cubemap && sky.cubemap_tex != 0 {
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

	// Pass Specular AA split-screen uniforms if using standard shaders
	if program == sky.program_equirect || program == sky.program_cubemap {
		gl.Uniform1i(10, 1 if split_enabled else 0)
		gl.Uniform1f(11, split_pos)
	}

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
	case sky.mode == .Cubemap && sky.cubemap_tex != 0:
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
	if sky.program_equirect_to_cubemap != 0 {
		gl.DeleteProgram(sky.program_equirect_to_cubemap)
		sky.program_equirect_to_cubemap = 0
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

	// Safely clean up transient in-progress or leftover generation resources unconditionally.
	// We MUST NOT delete gen_state.cubemap and gen_state.convert_prog because they are references
	// to persistent textures (cubemap_seamless / cubemap_gl) and programs (program_equirect_to_cubemap)
	// which are owned by the main Skybox struct and cleaned up above.
	if sky.gen_state.fbo != 0 { gl.DeleteFramebuffers(1, &sky.gen_state.fbo) }
	if sky.gen_state.vbo != 0 { gl.DeleteBuffers(1, &sky.gen_state.vbo) }
	if sky.gen_state.vao != 0 { gl.DeleteVertexArrays(1, &sky.gen_state.vao) }
	sky.gen_state = {}
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

	// Allocate all 6 faces at all mip levels atomically
	gl.TexStorage2D(
		gl.TEXTURE_CUBE_MAP,
		CUBEMAP_MIP_LEVELS,
		gl.RGBA16F,
		CUBEMAP_FACE_SIZE,
		CUBEMAP_FACE_SIZE,
	)
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

// Update environment textures after a dynamic env map swap.
// Lazy: only stores new texture handles and invalidates cubemaps.
// Cubemap regeneration is deferred until mode == .Cubemap (on-demand).
// ISO: called by env_manager after IBL swap completes.
skybox_update_env :: proc(sky: ^Skybox, new_env_tex: u32, new_prefilter_tex: u32) {
	sky.env_tex = new_env_tex
	sky.ibl_prefilter_tex = new_prefilter_tex

	// We persistently reuse sky.cubemap_gl and sky.cubemap_seamless to avoid VRAM reallocation stalls.
	sky.cubemap_tex = 0

	// Mark dirty so cubemap is regenerated on-demand when mode == .Cubemap
	sky.cubemap_dirty = true
	log.log_info("suckless-odin.skybox", "Environment updated, cubemaps invalidated (lazy regen)")
}

@(private)
skybox_gen_init_loc := tracy.Source_Location_Data{
	name     = "Cubemap_Gen_Init",
	function = "skybox_start_cubemap_gen",
	file     = #file,
	line     = #line,
	color    = 0xD08770, // Nord Orange
}

@(private)
skybox_gen_face_loc := tracy.Source_Location_Data{
	name     = "Cubemap_Gen_Face",
	function = "skybox_tick_cubemap_gen",
	file     = #file,
	line     = #line,
	color    = 0x5E81AC, // Nord Blue
}

@(private)
skybox_gen_downsample_loc := tracy.Source_Location_Data{
	name     = "Cubemap_Gen_Downsample",
	function = "skybox_tick_cubemap_gen",
	file     = #file,
	line     = #line,
	color    = 0xB48EAD, // Nord Purple
}

@(private)
skybox_start_cubemap_gen :: proc(sky: ^Skybox) {
	zone := tracy.zone_begin(&skybox_gen_init_loc)
	defer tracy.zone_end(zone)

	log.log_info("suckless-odin.skybox", "Starting amortized cubemap generation for mode=%v...", sky.mipmap_mode)

	state := &sky.gen_state
	state.mipmap_mode = sky.mipmap_mode
	state.phase = .Init

	// 1. Reuse or generate texture
	if sky.mipmap_mode == .Seamless {
		if sky.cubemap_seamless == 0 {
			gl.GenTextures(1, &sky.cubemap_seamless)
			gl.BindTexture(gl.TEXTURE_CUBE_MAP, sky.cubemap_seamless)
			gl.TexStorage2D(
				gl.TEXTURE_CUBE_MAP,
				CUBEMAP_MIP_LEVELS,
				gl.RGBA16F,
				CUBEMAP_FACE_SIZE,
				CUBEMAP_FACE_SIZE,
			)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
		}
		state.cubemap = sky.cubemap_seamless
	} else {
		if sky.cubemap_gl == 0 {
			gl.GenTextures(1, &sky.cubemap_gl)
			gl.BindTexture(gl.TEXTURE_CUBE_MAP, sky.cubemap_gl)
			gl.TexStorage2D(
				gl.TEXTURE_CUBE_MAP,
				CUBEMAP_MIP_LEVELS,
				gl.RGBA16F,
				CUBEMAP_FACE_SIZE,
				CUBEMAP_FACE_SIZE,
			)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
		}
		state.cubemap = sky.cubemap_gl
	}

	// 2. FBO for rendering
	gl.GenFramebuffers(1, &state.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, state.fbo)

	// 3. Reuse cached conversion shader
	state.convert_prog = sky.program_equirect_to_cubemap

	// 4. Save viewport and viewport size
	gl.GetIntegerv(gl.VIEWPORT, &state.prev_viewport[0])

	// 5. Fullscreen triangle
	gl.GenVertexArrays(1, &state.vao)
	gl.BindVertexArray(state.vao)
	verts := [9]f32{-1.0, -1.0, 0.0, 3.0, -1.0, 0.0, -1.0, 3.0, 0.0}
	gl.GenBuffers(1, &state.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, state.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)

	gl.BindVertexArray(0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	state.in_progress = true
	state.phase = .Mip0_Faces
	state.current_face = 0
	state.current_mip = 1
	sky.cubemap_dirty = false
}

@(private)
skybox_cubemap_gen_phase_mip0 :: proc(sky: ^Skybox, face_views: ^[6]mt.Mat4, proj: ^mt.Mat4) {
	state := &sky.gen_state
	dbg.push_group("Skybox: Cubemap Gen Face")
	defer dbg.pop_group()

	zone := tracy.zone_begin(&skybox_gen_face_loc)
	defer tracy.zone_end(zone)

	face := state.current_face
	log.log_info("suckless-odin.skybox", "Amortized cubemap: Rendering face %d of Mip 0...", face)

	gl.BindFramebuffer(gl.FRAMEBUFFER, state.fbo)
	gl.Viewport(0, 0, CUBEMAP_FACE_SIZE, CUBEMAP_FACE_SIZE)
	gl.UseProgram(state.convert_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, sky.env_tex)
	gl.BindVertexArray(state.vao)

	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
		gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face), state.cubemap, 0)

	inv_vp := mt.mat4_inverse(mt.mat4_mul(proj^, face_views[face]))
	gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT | gl.FRAMEBUFFER_BARRIER_BIT)

	state.current_face += 1
	if state.current_face >= 6 {
		state.phase = .Downsample
		state.current_mip = 1
		state.current_face = 0
	}
}

@(private)
skybox_cubemap_gen_phase_downsample :: proc(sky: ^Skybox, face_views: ^[6]mt.Mat4, proj: ^mt.Mat4) {
	state := &sky.gen_state
	dbg.push_group("Skybox: Cubemap Gen Downsample")
	defer dbg.pop_group()

	zone := tracy.zone_begin(&skybox_gen_downsample_loc)
	defer tracy.zone_end(zone)

	switch state.mipmap_mode {
	case .Gl_Generate:
		log.log_info("suckless-odin.skybox", "Amortized cubemap: Generating mipmaps via glGenerateMipmap...")
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, state.cubemap)
		gl.GenerateMipmap(gl.TEXTURE_CUBE_MAP)
		gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)
		state.phase = .Done

	case .Seamless:
		mip := state.current_mip
		face := state.current_face

		gl.BindFramebuffer(gl.FRAMEBUFFER, state.fbo)
		gl.UseProgram(sky.program_downsample)
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, state.cubemap)
		gl.BindVertexArray(state.vao)

		// Clamp max LOD to prevent sampling from uninitialized higher mips
		gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, mip - 1)

		mip_size := i32(CUBEMAP_FACE_SIZE) >> u32(mip)
		if mip_size < 1 { mip_size = 1 }
		gl.Viewport(0, 0, mip_size, mip_size)

		// Source LOD = previous mip level
		gl.Uniform1f(4, f32(mip - 1))

		// If it's a large mip level, downsample 1 face per frame to avoid pixel rendering stalls.
		// Otherwise, downsample all 6 faces in a single frame since the size is extremely small.
		if mip <= sky.compute_tuning.slicing.seamless_downsample_progressive_mip_threshold {
			tracy.message_c(fmt.tprintf("Skybox: Downsample Seamless Mip %d Face %d/6", mip, face + 1), 0x55FF55)
			log.log_info("suckless-odin.skybox", "Amortized cubemap: Downsampling Seamless Mip %d Face %d...", mip, face)

			gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
				gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face), state.cubemap, mip)

			inv_vp := mt.mat4_inverse(mt.mat4_mul(proj^, face_views[face]))
			gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

			gl.DrawArrays(gl.TRIANGLES, 0, 3)
			gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT | gl.FRAMEBUFFER_BARRIER_BIT)

			state.current_face += 1
			if state.current_face >= 6 {
				state.current_face = 0
				state.current_mip += 1
			}
		} else {
			tracy.message_c(fmt.tprintf("Skybox: Downsample Seamless Mip %d (all faces)", mip), 0x55FF55)
			log.log_info("suckless-odin.skybox", "Amortized cubemap: Downsampling Seamless Mip %d (all faces)...", mip)

			for f in 0..<6 {
				gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
					gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(f), state.cubemap, mip)

				inv_vp := mt.mat4_inverse(mt.mat4_mul(proj^, face_views[f]))
				gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])

				gl.DrawArrays(gl.TRIANGLES, 0, 3)
			}
			gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT | gl.FRAMEBUFFER_BARRIER_BIT)

			state.current_face = 0
			state.current_mip += 1
		}

		if state.current_mip >= i32(CUBEMAP_MIP_LEVELS) {
			gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, CUBEMAP_MIP_LEVELS - 1)
			state.phase = .Done
		}
	}
}

@(private)
skybox_cubemap_gen_phase_done :: proc(sky: ^Skybox) {
	state := &sky.gen_state
	// Persistent texture reuse: state.cubemap is already sky.cubemap_gl or sky.cubemap_seamless.
	sky.cubemap_tex = state.cubemap

	dbg.object_label(gl.TEXTURE, state.cubemap, "Skybox_Cubemap")
	gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT | gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)

	// Delete temporary helpers
	gl.DeleteBuffers(1, &state.vbo)
	gl.DeleteVertexArrays(1, &state.vao)
	gl.DeleteFramebuffers(1, &state.fbo)

	log.log_info("suckless-odin.skybox", "Amortized cubemap generation completed.")

	// Reset state
	sky.gen_state = {}
	sky.cubemap_dirty = false
}

@(private)
skybox_tick_cubemap_gen :: proc(sky: ^Skybox) {
	state := &sky.gen_state
	if !state.in_progress { return }

	face_views := [6]mt.Mat4{
		mt.look_at({0, 0, 0}, { 1,  0,  0}, {0, -1,  0}), // +X
		mt.look_at({0, 0, 0}, {-1,  0,  0}, {0, -1,  0}), // -X
		mt.look_at({0, 0, 0}, { 0,  1,  0}, {0,  0,  1}), // +Y
		mt.look_at({0, 0, 0}, { 0, -1,  0}, {0,  0, -1}), // -Y
		mt.look_at({0, 0, 0}, { 0,  0,  1}, {0, -1,  0}), // +Z
		mt.look_at({0, 0, 0}, { 0,  0, -1}, {0, -1,  0}), // -Z
	}
	proj := mt.perspective(mt.radians(90.0), 1.0, 0.1, 10.0)

	prev_viewport: [4]i32
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])
	prev_fbo: i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)

	switch state.phase {
	case .Init:
		// unreachable, initialized in start
		state.phase = .Mip0_Faces

	case .Mip0_Faces:
		skybox_cubemap_gen_phase_mip0(sky, &face_views, &proj)

	case .Downsample:
		skybox_cubemap_gen_phase_downsample(sky, &face_views, &proj)

	case .Done:
		skybox_cubemap_gen_phase_done(sky)
	}

	// Restore original viewport and FBO
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.UseProgram(0)
}

// Generate the cubemap for the current mipmap_mode if not already available.
// Called on-demand when mode is switched to .Cubemap or mipmap_mode changes.
skybox_ensure_cubemap :: proc(sky: ^Skybox) {
	when ODIN_DEBUG {
		assert(sky != nil, "Pre-condition Violated: sky is nil")
		if sky.gen_state.in_progress {
			assert(sky.gen_state.fbo != 0, "Invariant Violated: In-progress gen must have an active FBO")
			assert(sky.gen_state.vbo != 0, "Invariant Violated: In-progress gen must have an active VBO")
			assert(sky.gen_state.vao != 0, "Invariant Violated: In-progress gen must have an active VAO")
			assert(sky.program_equirect_to_cubemap != 0, "Invariant Violated: Persistent shader program is zero")
		}
	}

	if sky.env_tex == 0 { return }

	if sky.cubemap_dirty {
		if sky.gen_state.in_progress {
			// Abort active generation since parameters changed (e.g., mipmap_mode toggled)
			log.log_info("suckless-odin.skybox", "Aborting in-progress cubemap generation for mipmap_mode change.")
			// We MUST NOT delete gen_state.cubemap and gen_state.convert_prog because they are references
			// to persistent textures (cubemap_seamless / cubemap_gl) and programs (program_equirect_to_cubemap)
			// owned by the main Skybox struct.
			if sky.gen_state.fbo != 0 { gl.DeleteFramebuffers(1, &sky.gen_state.fbo) }
			if sky.gen_state.vbo != 0 { gl.DeleteBuffers(1, &sky.gen_state.vbo) }
			if sky.gen_state.vao != 0 { gl.DeleteVertexArrays(1, &sky.gen_state.vao) }
			sky.gen_state = {}
		}

		dbg.push_group("Skybox: Start Cubemap Gen")
		skybox_start_cubemap_gen(sky)
		dbg.pop_group()
	} else if sky.gen_state.in_progress {
		skybox_tick_cubemap_gen(sky)
	}
}
