package rendering

import gl "vendor:OpenGL"
import "core:os"
import "core:time"

import log "../core/log"

// IBL textures produced by compute shaders
IBL_Resources :: struct {
	irradiance_map: u32,  // unit 15
	prefilter_map:  u32,  // unit 16
	brdf_lut:       u32,  // unit 17

	// Compute programs
	irmap_program:  u32,
	spmap_program:  u32,
	spbrdf_program: u32,
}

// Sizes matching suckless-ogl
IRRADIANCE_SIZE :: 64
PREFILTER_SIZE  :: 1024
BRDF_LUT_SIZE   :: 512
PREFILTER_MIP_LEVELS :: 5

IBL_IRRADIANCE_UNIT :: 15
IBL_PREFILTER_UNIT  :: 16
IBL_BRDF_LUT_UNIT   :: 17

// Create IBL resources: compute irradiance, prefilter, and BRDF LUT from an HDR env map
ibl_create :: proc(ibl: ^IBL_Resources, env_tex: u32) -> bool {
	// Load compute shaders
	ibl.irmap_program  = load_compute_shader("shaders/IBL/irmap.glsl") or_return
	ibl.spmap_program  = load_compute_shader("shaders/IBL/spmap.glsl") or_return
	ibl.spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl") or_return

	// --- BRDF LUT ---
	t_start := time.now()

	gl.GenTextures(1, &ibl.brdf_lut)
	gl.BindTexture(gl.TEXTURE_2D, ibl.brdf_lut)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RG16F, BRDF_LUT_SIZE, BRDF_LUT_SIZE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	gl.UseProgram(ibl.spbrdf_program)
	gl.BindImageTexture(0, ibl.brdf_lut, 0, false, 0, gl.WRITE_ONLY, gl.RG16F)
	dispatch_compute(BRDF_LUT_SIZE, BRDF_LUT_SIZE)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	gl.Finish()

	t_brdf := time.duration_milliseconds(time.diff(t_start, time.now()))
	log.log_info("perf.ibl", "IBL: BRDF LUT (%dx%d): %.2f ms", BRDF_LUT_SIZE, BRDF_LUT_SIZE, t_brdf)

	// --- Irradiance Map ---
	t_start = time.now()

	gl.GenTextures(1, &ibl.irradiance_map)
	gl.BindTexture(gl.TEXTURE_2D, ibl.irradiance_map)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, IRRADIANCE_SIZE * 2, IRRADIANCE_SIZE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	gl.UseProgram(ibl.irmap_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, env_tex)
	gl.BindImageTexture(1, ibl.irradiance_map, 0, false, 0, gl.WRITE_ONLY, gl.RGBA16F)

	// Set uniforms
	gl.Uniform1f(gl.GetUniformLocation(ibl.irmap_program, "clamp_threshold"), 100.0)
	gl.Uniform1i(gl.GetUniformLocation(ibl.irmap_program, "u_offset_y"), 0)
	gl.Uniform1i(gl.GetUniformLocation(ibl.irmap_program, "u_max_y"), IRRADIANCE_SIZE)

	dispatch_compute(IRRADIANCE_SIZE * 2, IRRADIANCE_SIZE)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	gl.Finish()

	t_irr := time.duration_milliseconds(time.diff(t_start, time.now()))
	log.log_info("perf.ibl", "IBL: Irradiance (%dx%d): %.2f ms", IRRADIANCE_SIZE * 2, IRRADIANCE_SIZE, t_irr)

	// --- Prefilter Map (with mipmaps) ---
	t_start = time.now()

	gl.GenTextures(1, &ibl.prefilter_map)
	gl.BindTexture(gl.TEXTURE_2D, ibl.prefilter_map)
	gl.TexStorage2D(gl.TEXTURE_2D, PREFILTER_MIP_LEVELS, gl.RGBA16F, PREFILTER_SIZE * 2, PREFILTER_SIZE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	gl.UseProgram(ibl.spmap_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, env_tex)

	for mip in 0..<PREFILTER_MIP_LEVELS {
		mip_w := max(i32(1), (PREFILTER_SIZE * 2) >> u32(mip))
		mip_h := max(i32(1), PREFILTER_SIZE >> u32(mip))
		roughness := f32(mip) / f32(PREFILTER_MIP_LEVELS - 1)

		gl.BindImageTexture(1, ibl.prefilter_map, i32(mip), false, 0, gl.WRITE_ONLY, gl.RGBA16F)
		gl.Uniform1f(gl.GetUniformLocation(ibl.spmap_program, "roughnessValue"), roughness)
		gl.Uniform1i(gl.GetUniformLocation(ibl.spmap_program, "currentMipLevel"), i32(mip))
		gl.Uniform1f(gl.GetUniformLocation(ibl.spmap_program, "clampThreshold"), 100.0)
		gl.Uniform1i(gl.GetUniformLocation(ibl.spmap_program, "u_offset_y"), 0)
		gl.Uniform1i(gl.GetUniformLocation(ibl.spmap_program, "u_max_y"), mip_h)

		dispatch_compute(mip_w, mip_h)
		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	}
	gl.Finish()

	t_pf := time.duration_milliseconds(time.diff(t_start, time.now()))
	log.log_info("perf.ibl", "IBL: Prefilter (%dx%d, %d mips): %.2f ms",
		PREFILTER_SIZE * 2, PREFILTER_SIZE, PREFILTER_MIP_LEVELS, t_pf)

	gl.UseProgram(0)
	return true
}

// Bind IBL textures to their fixed texture units for rendering
ibl_bind :: proc(ibl: ^IBL_Resources) {
	gl.ActiveTexture(gl.TEXTURE0 + IBL_IRRADIANCE_UNIT)
	gl.BindTexture(gl.TEXTURE_2D, ibl.irradiance_map)

	gl.ActiveTexture(gl.TEXTURE0 + IBL_PREFILTER_UNIT)
	gl.BindTexture(gl.TEXTURE_2D, ibl.prefilter_map)

	gl.ActiveTexture(gl.TEXTURE0 + IBL_BRDF_LUT_UNIT)
	gl.BindTexture(gl.TEXTURE_2D, ibl.brdf_lut)
}

ibl_destroy :: proc(ibl: ^IBL_Resources) {
	if ibl.irradiance_map != 0 { gl.DeleteTextures(1, &ibl.irradiance_map) }
	if ibl.prefilter_map  != 0 { gl.DeleteTextures(1, &ibl.prefilter_map) }
	if ibl.brdf_lut       != 0 { gl.DeleteTextures(1, &ibl.brdf_lut) }
	if ibl.irmap_program  != 0 { gl.DeleteProgram(ibl.irmap_program) }
	if ibl.spmap_program  != 0 { gl.DeleteProgram(ibl.spmap_program) }
	if ibl.spbrdf_program != 0 { gl.DeleteProgram(ibl.spbrdf_program) }
	ibl^ = {}
}

// ---- Internal helpers ----

@(private)
dispatch_compute :: proc(width, height: i32) {
	gx := (width  + 31) / 32
	gy := (height + 31) / 32
	gl.DispatchCompute(u32(gx), u32(gy), 1)
}

@(private)
load_compute_shader :: proc(path: string) -> (u32, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.ibl", "Failed to read compute shader: %s", path)
		return 0, false
	}
	src := string(data)

	shader := gl.CreateShader(gl.COMPUTE_SHADER)
	src_cstr := cstring(raw_data(src))
	src_len  := i32(len(src))
	gl.ShaderSource(shader, 1, &src_cstr, &src_len)
	gl.CompileShader(shader)

	success: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &success)
	if success == 0 {
		buf: [1024]u8
		log_len: i32
		gl.GetShaderInfoLog(shader, 1024, &log_len, &buf[0])
		log.log_error("suckless-odin.ibl", "Compute shader compile error (%s):\n%s", path, cstring(&buf[0]))
		gl.DeleteShader(shader)
		return 0, false
	}

	program := gl.CreateProgram()
	gl.AttachShader(program, shader)
	gl.LinkProgram(program)

	gl.GetProgramiv(program, gl.LINK_STATUS, &success)
	if success == 0 {
		buf: [1024]u8
		log_len: i32
		gl.GetProgramInfoLog(program, 1024, &log_len, &buf[0])
		log.log_error("suckless-odin.ibl", "Compute shader link error (%s):\n%s", path, cstring(&buf[0]))
		gl.DeleteShader(shader)
		gl.DeleteProgram(program)
		return 0, false
	}

	gl.DeleteShader(shader)
	log.log_info("suckless-odin.ibl", "Compute shader loaded: %s (program=%d)", path, program)
	return program, true
}
