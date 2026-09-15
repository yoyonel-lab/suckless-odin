// +build test
// Complete IBL Cubemap Seam Bisection Oracle Suite (Tests A, B, C, D)
// Guard-first external verification on synthetic C-infinity HDR envmap.
package test_gl

import "core:testing"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import gl "vendor:OpenGL"

import shader "../../src/rendering/shader"
import rendering "../../src/rendering"
import rend_types "../../src/rendering/types"
import mt "../../src/core/math_types"
import sc "../../src/scene"

@(private)
inject_defines :: proc(source: string, defines: string) -> string {
	if len(defines) == 0 { return strings.clone(source) }
	version_end := strings.index(source, "\n")
	if version_end < 0 {
		return strings.concatenate({source, "\n", defines})
	}
	return strings.concatenate({source[:version_end + 1], defines, source[version_end + 1:]})
}

@(private)
load_compute_shader :: proc(path: string, defines: string = "") -> (u32, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read compute shader: %s", path)
		return 0, false
	}
	defer delete(data)
	src := string(data)

	src_to_compile := src
	defer if len(defines) > 0 { delete(src_to_compile) }
	if len(defines) > 0 {
		src_to_compile = inject_defines(src, defines)
	}

	shader := gl.CreateShader(gl.COMPUTE_SHADER)
	src_cstr := strings.clone_to_cstring(src_to_compile)
	defer delete(src_cstr)
	gl.ShaderSource(shader, 1, &src_cstr, nil)
	gl.CompileShader(shader)

	success: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &success)
	if success == 0 {
		buf: [1024]u8
		log_len: i32
		gl.GetShaderInfoLog(shader, 1024, &log_len, &buf[0])
		fmt.eprintfln("Compute shader compile error (%s):\n%s", path, cstring(&buf[0]))
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
		fmt.eprintfln("Compute shader link error (%s):\n%s", path, cstring(&buf[0]))
		gl.DeleteShader(shader)
		gl.DeleteProgram(program)
		return 0, false
	}

	gl.DeleteShader(shader)
	return program, true
}

// =============================================================================
// ÉTAPE 0: Synthetic Procedural C-infinity HDR Ground Truth Environment Map
// =============================================================================
// Strictly smooth everywhere on S2 with zero sampling singularities or high-freq noise,
// but with high HDR dynamic range (up to ~35.0) and high-contrast smooth bands crossing
// all 12 cubemap edge boundaries.
@(private)
generate_synthetic_equirect_texture :: proc(width, height: i32) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, width, height)

	pixels := make([]f32, int(width * height * 4))
	defer delete(pixels)

	// Gaussian spot centers along cubemap edges (where |x|=|y|, |y|=|z|, |x|=|z|)
	inv_sqrt2 :: f32(0.70710678)
	edge_spots := [6]struct{
		pos:    mt.Vec3,
		weight: f32,
	}{
		{{ inv_sqrt2,  inv_sqrt2, 0.0},       20.0}, // Edge +X/+Y
		{{ 0.0,        inv_sqrt2, inv_sqrt2}, 20.0}, // Edge +Y/+Z
		{{ inv_sqrt2,  0.0,       inv_sqrt2}, 20.0}, // Edge +X/+Z
		{{-inv_sqrt2, -inv_sqrt2, 0.0},       15.0}, // Edge -X/-Y
		{{ 0.0,       -inv_sqrt2, -inv_sqrt2},15.0}, // Edge -Y/-Z
		{{-inv_sqrt2,  0.0,       -inv_sqrt2},15.0}, // Edge -X/-Z
	}

	for j in 0..<height {
		v := (f32(j) + 0.5) / f32(height)
		lat := (v - 0.5) * math.PI
		sin_lat := math.sin(lat)
		cos_lat := math.cos(lat)

		for i in 0..<width {
			u := (f32(i) + 0.5) / f32(width)
			lon := (u - 0.5) * 2.0 * math.PI
			x := cos_lat * math.cos(lon)
			z := cos_lat * math.sin(lon)
			y := sin_lat

			d := mt.Vec3{x, y, z}

			// 1. Base harmonic smooth gradient
			lum := 3.0 + 2.0 * y + 0.5 * x

			// 2. High-contrast C-infinity smooth oscillatory bands crossing all faces
			band := math.sin(3.0 * x) * math.cos(3.0 * y) + math.sin(3.0 * z)
			lum += 6.0 * (band * band)

			// 3. High HDR Gaussian peaks directly straddling cube edges
			for spot in edge_spots {
				dot_prod := d.x * spot.pos.x + d.y * spot.pos.y + d.z * spot.pos.z
				lum += spot.weight * math.exp(-5.0 * (1.0 - dot_prod))
			}

			idx := int(j * width + i) * 4
			pixels[idx + 0] = lum
			pixels[idx + 1] = lum * 0.95
			pixels[idx + 2] = lum * 0.90
			pixels[idx + 3] = 1.0
		}
	}

	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.FLOAT, raw_data(pixels))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	return tex
}

Edge_Side :: enum {
	Left,
	Right,
	Top,
	Bottom,
}

Cube_Edge :: struct {
	face_a: int,
	side_a: Edge_Side,
	face_b: int,
	side_b: Edge_Side,
	flip:   bool,
}

// 12 Adjacent Cubemap Edges derived from cubemap_face_view_matrix & OpenGL cube conventions
CUBEMAP_EDGES :: [12]Cube_Edge{
	{0, .Top,    2, .Right,  true},
	{0, .Bottom, 3, .Right,  false},
	{0, .Left,   4, .Right,  false},
	{0, .Right,  5, .Left,   false},
	{1, .Top,    2, .Left,   false},
	{1, .Bottom, 3, .Left,   true},
	{1, .Right,  4, .Left,   false},
	{1, .Left,   5, .Right,  false},
	{2, .Bottom, 4, .Top,    false},
	{2, .Top,    5, .Top,    true},
	{3, .Top,    4, .Bottom, false},
	{3, .Bottom, 5, .Bottom, true},
}

// Measures max and average edge divergence between adjacent cubemap faces
@(private)
measure_cubemap_edge_divergence :: proc(cubemap: u32, mip: i32, size: i32) -> (max_div: f32, avg_div: f32) {
	fbo: u32
	gl.GenFramebuffers(1, &fbo)
	defer gl.DeleteFramebuffers(1, &fbo)

	face_pixels: [6][]f32
	for f in 0..<6 {
		face_pixels[f] = make([]f32, int(size * size * 4))
		gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
		gl.FramebufferTexture2D(
			gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
			gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(f),
			cubemap, mip,
		)
		gl.ReadPixels(0, 0, size, size, gl.RGBA, gl.FLOAT, raw_data(face_pixels[f]))
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	}
	defer {
		for f in 0..<6 do delete(face_pixels[f])
	}

	div_count := 0
	for e in CUBEMAP_EDGES {
		for idx in 0..<size {
			xa, ya: i32
			switch e.side_a {
			case .Left:   xa = 0;        ya = idx
			case .Right:  xa = size - 1; ya = idx
			case .Top:    xa = idx;      ya = 0
			case .Bottom: xa = idx;      ya = size - 1
			}

			b_idx := (size - 1 - idx) if e.flip else idx
			xb, yb: i32
			switch e.side_b {
			case .Left:   xb = 0;        yb = b_idx
			case .Right:  xb = size - 1; yb = b_idx
			case .Top:    xb = b_idx;    yb = 0
			case .Bottom: xb = b_idx;    yb = size - 1
			}

			pa := face_pixels[e.face_a][int(ya * size + xa) * 4]
			pb := face_pixels[e.face_b][int(yb * size + xb) * 4]

			diff := math.abs(pa - pb) / max(pa, 0.01)
			if diff > max_div do max_div = diff
			avg_div += diff
			div_count += 1
		}
	}

	if div_count > 0 {
		avg_div /= f32(div_count)
	}
	return max_div, avg_div
}

// Converts equirectangular texture to cubemap mip 0 and generates mips using glGenerateMipmap
@(private)
create_source_cubemap_with_gl_mips :: proc(synth_tex: u32, base_size: i32, total_mips: i32) -> (u32, bool) {
	cubemap: u32
	gl.GenTextures(1, &cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, cubemap)
	gl.TexStorage2D(gl.TEXTURE_CUBE_MAP, total_mips, gl.RGBA16F, base_size, base_size)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	fbo: u32
	gl.GenFramebuffers(1, &fbo)
	defer gl.DeleteFramebuffers(1, &fbo)

	conv_prog, conv_ok := shader.load_program("shaders/equirect_to_cubemap.vert", "shaders/equirect_to_cubemap.frag")
	if !conv_ok {
		gl.DeleteTextures(1, &cubemap)
		return 0, false
	}
	defer gl.DeleteProgram(conv_prog)

	conv_vao, conv_vbo: u32
	gl.GenVertexArrays(1, &conv_vao)
	defer gl.DeleteVertexArrays(1, &conv_vao)
	gl.GenBuffers(1, &conv_vbo)
	defer gl.DeleteBuffers(1, &conv_vbo)

	gl.BindVertexArray(conv_vao)
	verts := [9]f32{-1.0, -1.0, 0.0, 3.0, -1.0, 0.0, -1.0, 3.0, 0.0}
	gl.BindBuffer(gl.ARRAY_BUFFER, conv_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)
	gl.BindVertexArray(0)

	face_views := [6]mt.Mat4{
		mt.look_at({0, 0, 0}, { 1,  0,  0}, {0, -1,  0}),
		mt.look_at({0, 0, 0}, {-1,  0,  0}, {0, -1,  0}),
		mt.look_at({0, 0, 0}, { 0,  1,  0}, {0,  0,  1}),
		mt.look_at({0, 0, 0}, { 0, -1,  0}, {0,  0, -1}),
		mt.look_at({0, 0, 0}, { 0,  0,  1}, {0, -1,  0}),
		mt.look_at({0, 0, 0}, { 0,  0, -1}, {0, -1,  0}),
	}
	proj := mt.perspective(mt.radians(90.0), 1.0, 0.1, 10.0)

	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.Viewport(0, 0, base_size, base_size)
	gl.UseProgram(conv_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, synth_tex)
	gl.BindVertexArray(conv_vao)

	for face in 0..<6 {
		gl.FramebufferTexture2D(
			gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
			gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face),
			cubemap, 0,
		)
		inv_vp := mt.mat4_inverse(mt.mat4_mul(proj, face_views[face]))
		gl.UniformMatrix4fv(0, 1, false, &inv_vp[0][0])
		gl.DrawArrays(gl.TRIANGLES, 0, 3)
	}
	gl.BindVertexArray(0)
	gl.UseProgram(0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	// Defective path on beceae5: glGenerateMipmap per-face downsampler
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, cubemap)
	gl.GenerateMipmap(gl.TEXTURE_CUBE_MAP)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)
	gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT | gl.FRAMEBUFFER_BARRIER_BIT)

	return cubemap, true
}

// Converts equirectangular texture to cubemap using production Env_Manager (Option B scratch ping-pong)
@(private)
create_source_cubemap_production :: proc(synth_tex: u32) -> (u32, bool) {
	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	if !ok do return 0, false

	mgr.pending_hdr_tex = synth_tex
	mgr.ibl_clamp_threshold = 100.0
	mgr.ibl_state = .Cube_Convert

	sc.env_manager_update(&mgr, nil, 0.016)
	if mgr.ibl_state != .Specular_Init {
		mgr.pending_hdr_tex = 0
		sc.env_manager_destroy(&mgr)
		return 0, false
	}

	// Copy all mips to a standalone cubemap to keep it valid after mgr destruction
	res_cubemap: u32
	gl.GenTextures(1, &res_cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, res_cubemap)
	gl.TexStorage2D(gl.TEXTURE_CUBE_MAP, rendering.PREFILTER_MIP_LEVELS, gl.RGBA16F, rendering.PREFILTER_SIZE, rendering.PREFILTER_SIZE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)

	for mip in 0..<i32(rendering.PREFILTER_MIP_LEVELS) {
		mip_size := i32(rendering.PREFILTER_SIZE) >> u32(mip)
		if mip_size < 1 do mip_size = 1
		gl.CopyImageSubData(
			mgr.pending_spec_tex, gl.TEXTURE_CUBE_MAP, mip, 0, 0, 0,
			res_cubemap, gl.TEXTURE_CUBE_MAP, mip, 0, 0, 0,
			mip_size, mip_size, 6,
		)
	}

	mgr.pending_hdr_tex = 0
	sc.env_manager_destroy(&mgr)
	return res_cubemap, true
}

// =============================================================================
// TEST A: Source Cubemap Mip Chain Continuity (HEAD Production Downsampler)
// =============================================================================
@(test)
test_gl_ibl_mip_edge_continuity :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	synth_tex := generate_synthetic_equirect_texture(1024, 512)
	defer gl.DeleteTextures(1, &synth_tex)

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "failed to create env manager")
	defer sc.env_manager_destroy(&mgr)

	mgr.pending_hdr_tex = synth_tex
	mgr.ibl_clamp_threshold = 100.0
	mgr.ibl_state = .Cube_Convert

	// Drive the REAL production env_manager_ibl_cube_convert of HEAD
	sc.env_manager_update(&mgr, nil, 0.016)
	testing.expect(t, mgr.ibl_state == .Specular_Init, "Cube_Convert did not advance to Specular_Init")

	cubemap := mgr.pending_spec_tex

	fmt.println("\n-------------------------------------------------------------------------------")
	fmt.println("=== TEST A: SOURCE CUBEMAP MIP CHAIN CONTINUITY (HEAD PRODUCTION DOWNSAMPLE) ===")
	fmt.println("-------------------------------------------------------------------------------")
	fmt.println(" Mip | Resolution | Max Divergence | Avg Divergence | Geometric Bound | Verdict")
	fmt.println("-----+------------+----------------+----------------+-----------------+--------")

	all_within_bound := true

	for mip in 0..<8 {
		size := i32(rendering.PREFILTER_SIZE >> u32(mip))
		max_d, avg_d := measure_cubemap_edge_divergence(cubemap, i32(mip), size)
		// Geometric rate of texel center separation: Δθ = sqrt(2)/size ~ 0.005 * 2^mip
		bound := 0.005 * f32(u32(1) << u32(mip))
		if mip == 0 do bound = 0.005
		verdict := "PASS (SMOOTH)"
		if max_d > bound {
			verdict = "FAIL (DISCONTINUOUS)"
			all_within_bound = false
		}
		fmt.printfln("  %2d | %4dx%4d  | %13.2f%% | %13.2f%% | %14.2f%% | %s",
			mip, size, size, max_d * 100.0, avg_d * 100.0, bound * 100.0, verdict)
	}
	fmt.println("-------------------------------------------------------------------------------")

	testing.expect(t, all_within_bound, "Test A (Source Mips): edge divergence exceeds smooth geometric bound")
}

// =============================================================================
// TEST B: Specular Convolution Continuity (spmap.glsl Oracle)
// =============================================================================
@(test)
test_gl_ibl_prefilter_continuity :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	synth_tex := generate_synthetic_equirect_texture(1024, 512)
	defer gl.DeleteTextures(1, &synth_tex)

	src_cubemap, ok := create_source_cubemap_production(synth_tex)
	testing.expect(t, ok, "failed to create source cubemap")
	defer if ok do gl.DeleteTextures(1, &src_cubemap)

	spmap_prog, spmap_ok := load_compute_shader("shaders/IBL/spmap.glsl", "#define SAMPLE_COUNT 1024u\n")
	testing.expect(t, spmap_ok, "failed to compile spmap.glsl")
	defer if spmap_ok do gl.DeleteProgram(spmap_prog)

	// 1. Allocate production prefilter cubemap matching PREFILTER_SIZE (1024) and PREFILTER_MIP_LEVELS (11)
	prefilter_cubemap: u32
	gl.GenTextures(1, &prefilter_cubemap)
	defer gl.DeleteTextures(1, &prefilter_cubemap)

	gl.BindTexture(gl.TEXTURE_CUBE_MAP, prefilter_cubemap)
	gl.TexStorage2D(gl.TEXTURE_CUBE_MAP, rendering.PREFILTER_MIP_LEVELS, gl.RGBA16F, rendering.PREFILTER_SIZE, rendering.PREFILTER_SIZE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)

	// 2. Dispatch spmap.glsl for each mip level (matching production env_manager_dispatch_specular_mip)
	gl.UseProgram(spmap_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, src_cubemap)

	for mip in 0..<rendering.PREFILTER_MIP_LEVELS {
		mip_w := max(i32(1), rendering.PREFILTER_SIZE >> u32(mip))
		roughness := f32(mip) / f32(rendering.PREFILTER_MIP_LEVELS - 1)

		gl.BindImageTexture(1, prefilter_cubemap, i32(mip), true, 0, gl.WRITE_ONLY, gl.RGBA16F)
		gl.Uniform1f(gl.GetUniformLocation(spmap_prog, "roughnessValue"), roughness)
		gl.Uniform1f(gl.GetUniformLocation(spmap_prog, "clamp_threshold"), 100.0)
		gl.Uniform1i(gl.GetUniformLocation(spmap_prog, "u_offset_y"), 0)
		gl.Uniform1i(gl.GetUniformLocation(spmap_prog, "u_max_y"), mip_w)

		gx := u32((mip_w + 15) / 16)
		gy := u32((mip_w + 15) / 16)
		gl.DispatchCompute(gx, gy, 6)
	}
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
	gl.UseProgram(0)

	fmt.println("\n-------------------------------------------------------------------------------")
	fmt.println("=== TEST B: SPECULAR PREFILTER CONTINUITY (spmap.glsl PRODUCTION MIPS) ===")
	fmt.println("-------------------------------------------------------------------------------")
	fmt.println(" Mip | Roughness | Resolution | Max Divergence | Avg Divergence | Verdict")
	fmt.println("-----+-----------+------------+----------------+----------------+--------")

	max_spmap_divergence: f32 = 0.0

	for mip in 0..<8 {
		size := i32(rendering.PREFILTER_SIZE >> u32(mip))
		roughness := f32(mip) / f32(rendering.PREFILTER_MIP_LEVELS - 1)
		max_d, avg_d := measure_cubemap_edge_divergence(prefilter_cubemap, i32(mip), size)
		verdict := "PASS (SMOOTH)"
		if max_d >= MAX_PREFILTER_DIVERGENCE_THRESHOLD do verdict = "FAIL (SEAM)"
		if max_d > max_spmap_divergence do max_spmap_divergence = max_d

		fmt.printfln("  %2d |      %4.2f | %4dx%4d  | %13.2f%% | %13.2f%% | %s",
			mip, roughness, size, size, max_d * 100.0, avg_d * 100.0, verdict)
	}
	fmt.println("-------------------------------------------------------------------------------")

	MAX_PREFILTER_DIVERGENCE_THRESHOLD :: f32(0.08)
	testing.expect(t, max_spmap_divergence < MAX_PREFILTER_DIVERGENCE_THRESHOLD,
		fmt.tprintf("Test B (spmap Prefilter) FAILED: max divergence %.2f%% >= threshold %.2f%%",
			max_spmap_divergence * 100.0, MAX_PREFILTER_DIVERGENCE_THRESHOLD * 100.0))
}

// =============================================================================
// TEST C: Diffuse Convolution Continuity (irmap.glsl Oracle)
// =============================================================================
@(test)
test_gl_ibl_irradiance_continuity :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	synth_tex := generate_synthetic_equirect_texture(1024, 512)
	defer gl.DeleteTextures(1, &synth_tex)

	src_cubemap, ok := create_source_cubemap_production(synth_tex)
	testing.expect(t, ok, "failed to create source cubemap")
	defer if ok do gl.DeleteTextures(1, &src_cubemap)

	irmap_prog, irmap_ok := load_compute_shader("shaders/IBL/irmap.glsl", "#define SAMPLE_DELTA 0.025\n")
	testing.expect(t, irmap_ok, "failed to compile irmap.glsl")
	defer if irmap_ok do gl.DeleteProgram(irmap_prog)

	IRMAP_SIZE :: 32
	irr_cubemap: u32
	gl.GenTextures(1, &irr_cubemap)
	defer gl.DeleteTextures(1, &irr_cubemap)

	gl.BindTexture(gl.TEXTURE_CUBE_MAP, irr_cubemap)
	gl.TexStorage2D(gl.TEXTURE_CUBE_MAP, 1, gl.RGBA16F, IRMAP_SIZE, IRMAP_SIZE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)

	gl.UseProgram(irmap_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, src_cubemap)
	gl.BindImageTexture(1, irr_cubemap, 0, true, 0, gl.WRITE_ONLY, gl.RGBA16F)

	gl.Uniform1f(gl.GetUniformLocation(irmap_prog, "clamp_threshold"), 100.0)
	gl.Uniform1i(gl.GetUniformLocation(irmap_prog, "u_offset_y"), 0)
	gl.Uniform1i(gl.GetUniformLocation(irmap_prog, "u_max_y"), IRMAP_SIZE)

	// irmap workgroup: local_size_x = 16, local_size_y = 4, local_size_z = 1
	gl.DispatchCompute(IRMAP_SIZE / 16, IRMAP_SIZE / 4, 6)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
	gl.UseProgram(0)

	fmt.println("\n-------------------------------------------------------------------------------")
	fmt.println("=== TEST C: DIFFUSE IRRADIANCE CONTINUITY (irmap.glsl) ===")
	fmt.println("-------------------------------------------------------------------------------")
	fmt.println(" Stage   | Resolution | Max Divergence | Avg Divergence | Verdict")
	fmt.println("---------+------------+----------------+----------------+--------")

	max_d, avg_d := measure_cubemap_edge_divergence(irr_cubemap, 0, IRMAP_SIZE)
	verdict := "PASS (CONTINUOUS)"
	if max_d >= 0.025 do verdict = "FAIL (SEAM)"

	fmt.printfln(" Irradiance | %4dx%4d  | %13.2f%% | %13.2f%% | %s",
		IRMAP_SIZE, IRMAP_SIZE, max_d * 100.0, avg_d * 100.0, verdict)
	fmt.println("-------------------------------------------------------------------------------")

	MAX_IRRADIANCE_DIVERGENCE_THRESHOLD :: f32(0.025)
	testing.expect(t, max_d < MAX_IRRADIANCE_DIVERGENCE_THRESHOLD,
		fmt.tprintf("Test C (irmap Irradiance) FAILED: max divergence %.2f%% >= threshold %.2f%%",
			max_d * 100.0, MAX_IRRADIANCE_DIVERGENCE_THRESHOLD * 100.0))
}

// =============================================================================
// TEST D: Image-Space Rough Sphere Headless Render Oracle (PBR Sobel Seam Filter)
// =============================================================================
@(test)
test_gl_ibl_image_space_oracle :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// 1. Generate synthetic ground truth equirect
	synth_tex := generate_synthetic_equirect_texture(1024, 512)
	defer gl.DeleteTextures(1, &synth_tex)

	// 2. Generate source cubemap with production Env_Manager (Option B scratch ping-pong)
	src_cubemap, ok := create_source_cubemap_production(synth_tex)
	testing.expect(t, ok, "failed to create source cubemap")
	defer if ok do gl.DeleteTextures(1, &src_cubemap)

	// 3. Compute Irradiance Map (32x32)
	irmap_prog, irmap_ok := load_compute_shader("shaders/IBL/irmap.glsl", "#define SAMPLE_DELTA 0.025\n")
	testing.expect(t, irmap_ok, "failed to compile irmap.glsl")
	defer if irmap_ok do gl.DeleteProgram(irmap_prog)

	irr_cubemap: u32
	gl.GenTextures(1, &irr_cubemap)
	defer gl.DeleteTextures(1, &irr_cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, irr_cubemap)
	gl.TexStorage2D(gl.TEXTURE_CUBE_MAP, 1, gl.RGBA16F, 32, 32)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)

	gl.UseProgram(irmap_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, src_cubemap)
	gl.BindImageTexture(1, irr_cubemap, 0, true, 0, gl.WRITE_ONLY, gl.RGBA16F)
	gl.Uniform1f(gl.GetUniformLocation(irmap_prog, "clamp_threshold"), 100.0)
	gl.Uniform1i(gl.GetUniformLocation(irmap_prog, "u_offset_y"), 0)
	gl.Uniform1i(gl.GetUniformLocation(irmap_prog, "u_max_y"), 32)
	gl.DispatchCompute(32 / 16, 32 / 4, 6)
	gl.UseProgram(0)

	// 4. Compute Prefilter Map (11 mips matching production)
	spmap_prog, spmap_ok := load_compute_shader("shaders/IBL/spmap.glsl", "#define SAMPLE_COUNT 1024u\n")
	testing.expect(t, spmap_ok, "failed to compile spmap.glsl")
	defer if spmap_ok do gl.DeleteProgram(spmap_prog)

	prefilter_cubemap: u32
	gl.GenTextures(1, &prefilter_cubemap)
	defer gl.DeleteTextures(1, &prefilter_cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, prefilter_cubemap)
	gl.TexStorage2D(gl.TEXTURE_CUBE_MAP, rendering.PREFILTER_MIP_LEVELS, gl.RGBA16F, rendering.PREFILTER_SIZE, rendering.PREFILTER_SIZE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)

	gl.UseProgram(spmap_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, src_cubemap)
	for mip in 0..<rendering.PREFILTER_MIP_LEVELS {
		mip_w := max(i32(1), rendering.PREFILTER_SIZE >> u32(mip))
		roughness := f32(mip) / f32(rendering.PREFILTER_MIP_LEVELS - 1)
		gl.BindImageTexture(1, prefilter_cubemap, i32(mip), true, 0, gl.WRITE_ONLY, gl.RGBA16F)
		gl.Uniform1f(gl.GetUniformLocation(spmap_prog, "roughnessValue"), roughness)
		gl.Uniform1f(gl.GetUniformLocation(spmap_prog, "clamp_threshold"), 100.0)
		gl.Uniform1i(gl.GetUniformLocation(spmap_prog, "u_offset_y"), 0)
		gl.Uniform1i(gl.GetUniformLocation(spmap_prog, "u_max_y"), mip_w)
		gx := u32((mip_w + 15) / 16)
		gy := u32((mip_w + 15) / 16)
		gl.DispatchCompute(gx, gy, 6)
	}
	gl.UseProgram(0)

	// 5. Compute BRDF LUT (512x512)
	brdf_prog, brdf_ok := load_compute_shader("shaders/IBL/spbrdf.glsl", "#define SAMPLE_COUNT 1024u\n")
	testing.expect(t, brdf_ok, "failed to compile spbrdf.glsl")
	defer if brdf_ok do gl.DeleteProgram(brdf_prog)

	brdf_lut: u32
	gl.GenTextures(1, &brdf_lut)
	defer gl.DeleteTextures(1, &brdf_lut)
	gl.BindTexture(gl.TEXTURE_2D, brdf_lut)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RG16F, 512, 512)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	gl.UseProgram(brdf_prog)
	gl.Uniform1i(0, 0)
	gl.BindImageTexture(0, brdf_lut, 0, false, 0, gl.WRITE_ONLY, gl.RG16F)
	gl.DispatchCompute(32, 32, 1)
	gl.UseProgram(0)

	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)

	// 6. Setup Headless Offscreen Render Target (512x512 RGBA16F)
	RENDER_WIDTH  :: 512
	RENDER_HEIGHT :: 512

	fbo, color_rb, depth_rb: u32
	gl.GenFramebuffers(1, &fbo)
	defer gl.DeleteFramebuffers(1, &fbo)
	gl.GenTextures(1, &color_rb)
	defer gl.DeleteTextures(1, &color_rb)
	gl.BindTexture(gl.TEXTURE_2D, color_rb)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, RENDER_WIDTH, RENDER_HEIGHT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

	gl.GenRenderbuffers(1, &depth_rb)
	defer gl.DeleteRenderbuffers(1, &depth_rb)
	gl.BindRenderbuffer(gl.RENDERBUFFER, depth_rb)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, RENDER_WIDTH, RENDER_HEIGHT)

	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color_rb, 0)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depth_rb)
	testing.expect(t, gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE, "FBO incomplete")

	// 7. Setup Production PBR Billboard Pipeline
	pbr_prog, pbr_ok := shader.load_program("shaders/pbr_billboard.vert", "shaders/pbr_billboard.frag")
	testing.expect(t, pbr_ok, "failed to compile pbr_billboard program")
	defer if pbr_ok do gl.DeleteProgram(pbr_prog)

	bb_vao, bb_vbo: u32
	gl.GenVertexArrays(1, &bb_vao)
	defer gl.DeleteVertexArrays(1, &bb_vao)
	gl.GenBuffers(1, &bb_vbo)
	defer gl.DeleteBuffers(1, &bb_vbo)

	gl.BindVertexArray(bb_vao)
	quad_verts := [12]f32{
		-0.5,  0.5, 0.0,
		-0.5, -0.5, 0.0,
		 0.5,  0.5, 0.0,
		 0.5, -0.5, 0.0,
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, bb_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad_verts), &quad_verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)
	gl.BindVertexArray(0)

	ssbo: u32
	gl.GenBuffers(1, &ssbo)
	defer gl.DeleteBuffers(1, &ssbo)

	// Camera setup: Camera positioned along the +X/+Z cubemap boundary diagonal (45 degrees)
	// directly framing the cardinal seam vertically down the center of the sphere
	cam_pos := mt.Vec3{2.12132, 0.0, 2.12132}
	view_mat := mt.look_at(cam_pos, {0, 0, 0}, {0, 1, 0})
	proj_mat := mt.perspective(mt.radians(45.0), 1.0, 0.1, 10.0)
	prev_vp := mt.mat4_mul(proj_mat, view_mat)

	lum_at :: proc(pix: []f32, px, py: int) -> f32 {
		idx := (py * RENDER_WIDTH + px) * 4
		return 0.2126 * pix[idx + 0] + 0.7152 * pix[idx + 1] + 0.0722 * pix[idx + 2]
	}

	Material_Case :: struct {
		name:           string,
		metallic:       f32,
		roughness:      f32,
		grad_threshold: f32,
	}

	material_cases := [2]Material_Case{
		{"dielectric", 0.0, 0.7, 0.038},
		{"metallic",   1.0, 0.7, 0.150},
	}

	for mat in material_cases {
		instance: rend_types.Sphere_Instance
		instance.model = mt.MAT4_IDENTITY
		instance.albedo = mt.Vec3{1.0, 1.0, 1.0}
		instance.metallic = mat.metallic
		instance.roughness = mat.roughness
		instance.ao = 1.0
		instance.id = 0
		instance.prev_center = mt.Vec3{0, 0, 0}

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo)
		gl.BufferData(gl.SHADER_STORAGE_BUFFER, size_of(rend_types.Sphere_Instance), &instance, gl.STATIC_DRAW)
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0)

		// Render the sphere
		gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
		gl.Viewport(0, 0, RENDER_WIDTH, RENDER_HEIGHT)
		gl.ClearColor(0.0, 0.0, 0.0, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		gl.Enable(gl.DEPTH_TEST)

		gl.UseProgram(pbr_prog)
		gl.UniformMatrix4fv(gl.GetUniformLocation(pbr_prog, "u_view"), 1, false, &view_mat[0][0])
		gl.UniformMatrix4fv(gl.GetUniformLocation(pbr_prog, "u_projection"), 1, false, &proj_mat[0][0])
		gl.UniformMatrix4fv(gl.GetUniformLocation(pbr_prog, "u_prev_view_proj"), 1, false, &prev_vp[0][0])
		gl.Uniform3f(gl.GetUniformLocation(pbr_prog, "u_cam_pos"), cam_pos.x, cam_pos.y, cam_pos.z)
		gl.Uniform2f(gl.GetUniformLocation(pbr_prog, "u_screen_size"), f32(RENDER_WIDTH), f32(RENDER_HEIGHT))
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_edge_aa_mode"), 0)
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_specular_aa_enabled"), 0)
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_specular_occlusion_enabled"), 0)
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_horizon_clipping_enabled"), 0)
		gl.Uniform1f(gl.GetUniformLocation(pbr_prog, "u_point_light_intensity"), 0.0)
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_point_shadows_enabled"), 0)
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_pbr_debug_mode"), 0)
		gl.Uniform1i(gl.GetUniformLocation(pbr_prog, "u_use_baked_ao"), 0)

		// Bind IBL texture units
		gl.ActiveTexture(gl.TEXTURE15)
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, irr_cubemap)
		gl.ActiveTexture(gl.TEXTURE16)
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, prefilter_cubemap)
		gl.ActiveTexture(gl.TEXTURE17)
		gl.BindTexture(gl.TEXTURE_2D, brdf_lut)

		// Bind SSBO instance
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, ssbo)

		gl.BindVertexArray(bb_vao)
		gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 1)
		gl.BindVertexArray(0)
		gl.UseProgram(0)

		// 8. Readback Framebuffer Pixels
		rendered_pixels := make([]f32, RENDER_WIDTH * RENDER_HEIGHT * 4)
		defer delete(rendered_pixels)
		gl.ReadPixels(0, 0, RENDER_WIDTH, RENDER_HEIGHT, gl.RGBA, gl.FLOAT, raw_data(rendered_pixels))
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

		// Save visual captures for operator audit
		png_pixels := make([]u8, int(RENDER_WIDTH * RENDER_HEIGHT * 4))
		defer delete(png_pixels)
		for i in 0..<int(RENDER_WIDTH * RENDER_HEIGHT) {
			src_y := i / int(RENDER_WIDTH)
			src_x := i % int(RENDER_WIDTH)
			dst_y := int(RENDER_HEIGHT) - 1 - src_y
			dst_idx := (dst_y * int(RENDER_WIDTH) + src_x) * 4
			src_idx := i * 4
			png_pixels[dst_idx + 0] = u8(clamp(rendered_pixels[src_idx + 0] * 255.0 / 25.0, 0.0, 255.0))
			png_pixels[dst_idx + 1] = u8(clamp(rendered_pixels[src_idx + 1] * 255.0 / 25.0, 0.0, 255.0))
			png_pixels[dst_idx + 2] = u8(clamp(rendered_pixels[src_idx + 2] * 255.0 / 25.0, 0.0, 255.0))
			png_pixels[dst_idx + 3] = 255
		}
		path_doc := fmt.tprintf("docs/images/seam_bisection_%s.png", mat.name)
		path_brain := fmt.tprintf("/home/latty/.gemini/antigravity-cli/brain/533f2e12-19a0-4fd4-965d-38fff1d9bead/seam_bisection_%s.png", mat.name)
		save_png(path_doc, png_pixels, RENDER_WIDTH, RENDER_HEIGHT)
		save_png(path_brain, png_pixels, RENDER_WIDTH, RENDER_HEIGHT)

		// 9. CPU Analytic Mask & Sobel Gradient Analysis
		cx: f32 = 256.0
		cy: f32 = 256.0
		mask_radius: f32 = 150.0
		mask_radius_sq: f32 = mask_radius * mask_radius

		max_gradient: f32 = 0.0
		max_gx, max_gy: int = 0, 0

		for y in 1..<(RENDER_HEIGHT - 1) {
			for x in 1..<(RENDER_WIDTH - 1) {
				dx := f32(x) - cx
				dy := f32(y) - cy
				if (dx * dx + dy * dy) > mask_radius_sq {
					continue
				}

				l00 := lum_at(rendered_pixels, x - 1, y - 1)
				l10 := lum_at(rendered_pixels, x,     y - 1)
				l20 := lum_at(rendered_pixels, x + 1, y - 1)

				l01 := lum_at(rendered_pixels, x - 1, y)
				l21 := lum_at(rendered_pixels, x + 1, y)

				l02 := lum_at(rendered_pixels, x - 1, y + 1)
				l12 := lum_at(rendered_pixels, x,     y + 1)
				l22 := lum_at(rendered_pixels, x + 1, y + 1)

				gx := (l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02)
				gy := (l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20)

				grad_mag := math.sqrt(gx * gx + gy * gy) / 8.0

				if grad_mag > max_gradient {
					max_gradient = grad_mag
					max_gx = x
					max_gy = y
				}
			}
		}

		fmt.println("\n-------------------------------------------------------------------------------")
		fmt.printfln("=== TEST D: IMAGE-SPACE PBR SPHERE ORACLE [%s: metallic=%.1f, rough=%.1f] ===",
			mat.name, mat.metallic, mat.roughness)
		fmt.println("-------------------------------------------------------------------------------")
		fmt.printfln(" Max Inner Gradient Magnitude: %.5f at pixel (%d, %d)", max_gradient, max_gx, max_gy)

		// Sample a 1D horizontal profile across the vertical meridian (x: 240..272, y = 256)
		fmt.println(" 1D Horizontal Luminance & Gradient Profile across central seam:")
		seam_gx_max: f32 = 0.0
		for px in 240..=272 {
			idx := int(256 * RENDER_WIDTH + px) * 4
			lum := 0.2126 * rendered_pixels[idx + 0] + 0.7152 * rendered_pixels[idx + 1] + 0.0722 * rendered_pixels[idx + 2]
			l00 := lum_at(rendered_pixels, px - 1, 255)
			l10 := lum_at(rendered_pixels, px,     255)
			l20 := lum_at(rendered_pixels, px + 1, 255)
			l01 := lum_at(rendered_pixels, px - 1, 256)
			l21 := lum_at(rendered_pixels, px + 1, 256)
			l02 := lum_at(rendered_pixels, px - 1, 257)
			l12 := lum_at(rendered_pixels, px,     257)
			l22 := lum_at(rendered_pixels, px + 1, 257)
			gx := (l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02)
			gy := (l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20)
			grad := math.sqrt(gx * gx + gy * gy) / 8.0
			gx_norm := math.abs(gx / 8.0)
			if px >= 254 && px <= 258 && gx_norm > seam_gx_max {
				seam_gx_max = gx_norm
			}
			fmt.printfln("   x = %3d: Lum = %.4f, ||grad|| = %.5f, gx = %+.5f", px, lum, grad, gx / 8.0)
		}

		fmt.printfln(" Seam Spike Detection Threshold: %.5f", mat.grad_threshold)
		fmt.printfln(" Max Central Seam Jump |gx|: %.5f (threshold 0.01500)", seam_gx_max)
		verdict := "PASS (SMOOTH)"
		if max_gradient >= mat.grad_threshold || seam_gx_max >= 0.015 do verdict = "FAIL (SEAM ARTEFACT DETECTED)"
		fmt.printfln(" Image-Space Verdict (%s): %s", mat.name, verdict)
		fmt.println("-------------------------------------------------------------------------------")

		testing.expect(t, max_gradient < mat.grad_threshold,
			fmt.tprintf("Test D (%s) FAILED: gradient spike %.5f >= threshold %.5f",
				mat.name, max_gradient, mat.grad_threshold))
		testing.expect(t, seam_gx_max < 0.015,
			fmt.tprintf("Test D (%s) FAILED: seam jump |gx| %.5f >= threshold 0.015",
				mat.name, seam_gx_max))
	}
}
