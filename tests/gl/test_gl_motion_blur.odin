// +build test
// Motion Blur + FXAA Pre-Pass Regression Test.
//
// Two-phase approach:
//   Phase 1 — Full-res (1169×977): user's exact velocity values, always exports PNGs.
//   Phase 2 — Half-res (584×488): stochastic sampling of the (angle, magnitude) space
//             with deterministic seed. Only exports PNGs when a regression is detected.
//
// Regression metrics (per MB-only vs FXAA+MB pair):
//   - PSNR > 20 dB (global similarity)
//   - Gradient variance ratio ≤ 1.15 (stair-step detector)
//   - Edge energy ratio ≤ 1.10 (artifact amplification detector)
//
// Budget: 3 full-res renders + 64 half-res renders = 67 total.
//
// Run: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
package test_gl

import "core:testing"
import "core:fmt"
import "core:math"
import "core:os"
import "core:c"
import "core:strings"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import shader "../../src/rendering/shader"
import postfx "../../src/rendering/postfx"

// --- Constants ---

OUTPUT_DIR :: "/tmp/mb_sampling"

STOCHASTIC_SAMPLES :: 64 // pairs (×2 = 128 renders)
STOCHASTIC_W :: i32(584)
STOCHASTIC_H :: i32(488)
STOCHASTIC_SEED :: u64(0xDEAD_BEEF_CAFE_1234)

MB_INTENSITY :: f32(2.099)

// --- Test infrastructure ---

@(private)
Mb_Test_Resources :: struct {
	program:          u32,
	fbo:              u32,
	color_tex:        u32,
	ubo:              u32,
	vao:              u32,
	vbo:              u32,
	screen_tex:       u32,
	bloom_tex:        u32,
	depth_tex:        u32,
	auto_exp_tex:     u32,
	velocity_tex:     u32,
	dof_tex:          u32,
	neighbor_max_tex: u32,
	tile_max_tex:     u32,
	lut3d_tex:        u32,
}

@(private)
mb_test_setup :: proc(t: ^testing.T, w, h: i32) -> (res: Mb_Test_Resources, ok: bool) {
	res.program, ok = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/postfx.frag")
	if !ok {
		testing.expect(t, false, "Failed to load postfx program")
		return
	}

	gl.GenFramebuffers(1, &res.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, res.fbo)
	gl.GenTextures(1, &res.color_tex)
	gl.BindTexture(gl.TEXTURE_2D, res.color_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, res.color_tex, 0)

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		testing.expect(t, false, "FBO incomplete")
		mb_test_cleanup(&res)
		ok = false
		return
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	gl.GenBuffers(1, &res.ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, res.ubo)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(postfx.Post_FX_UBO), nil, gl.DYNAMIC_DRAW)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, res.ubo)

	verts := [6]f32{-1.0, -1.0, 3.0, -1.0, -1.0, 3.0}
	gl.GenVertexArrays(1, &res.vao)
	gl.GenBuffers(1, &res.vbo)
	gl.BindVertexArray(res.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, res.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)
	gl.BindVertexArray(0)

	black_rgb := make([]f32, int(w * h * 3))
	defer delete(black_rgb)
	res.bloom_tex = create_tex_rgb16f(w, h, raw_data(black_rgb))
	res.dof_tex = create_tex_rgb16f(w, h, raw_data(black_rgb))

	exp_data := [1]f32{1.0}
	res.auto_exp_tex = create_tex_r16f(1, 1, &exp_data)

	gl.GenTextures(1, &res.lut3d_tex)
	gl.BindTexture(gl.TEXTURE_3D, res.lut3d_tex)
	gl.TexImage3D(gl.TEXTURE_3D, 0, gl.RGB16F, 2, 2, 2, 0, gl.RGB, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	ok = true
	return
}

@(private)
mb_test_cleanup :: proc(res: ^Mb_Test_Resources) {
	if res.program != 0          { gl.DeleteProgram(res.program) }
	if res.fbo != 0              { gl.DeleteFramebuffers(1, &res.fbo) }
	if res.color_tex != 0        { gl.DeleteTextures(1, &res.color_tex) }
	if res.ubo != 0              { gl.DeleteBuffers(1, &res.ubo) }
	if res.vao != 0              { gl.DeleteVertexArrays(1, &res.vao) }
	if res.vbo != 0              { gl.DeleteBuffers(1, &res.vbo) }
	if res.screen_tex != 0       { gl.DeleteTextures(1, &res.screen_tex) }
	if res.bloom_tex != 0        { gl.DeleteTextures(1, &res.bloom_tex) }
	if res.depth_tex != 0        { gl.DeleteTextures(1, &res.depth_tex) }
	if res.auto_exp_tex != 0     { gl.DeleteTextures(1, &res.auto_exp_tex) }
	if res.velocity_tex != 0     { gl.DeleteTextures(1, &res.velocity_tex) }
	if res.dof_tex != 0          { gl.DeleteTextures(1, &res.dof_tex) }
	if res.neighbor_max_tex != 0 { gl.DeleteTextures(1, &res.neighbor_max_tex) }
	if res.tile_max_tex != 0     { gl.DeleteTextures(1, &res.tile_max_tex) }
	if res.lut3d_tex != 0        { gl.DeleteTextures(1, &res.lut3d_tex) }
}

// --- Texture helpers ---

@(private)
create_tex_r16f :: proc(w, h: i32, data: rawptr) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R16F, w, h, 0, gl.RED, gl.FLOAT, data)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return tex
}

@(private)
create_tex_rg16f :: proc(w, h: i32, data: rawptr) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RG16F, w, h, 0, gl.RG, gl.FLOAT, data)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return tex
}

@(private)
create_tex_rgb16f :: proc(w, h: i32, data: rawptr) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB16F, w, h, 0, gl.RGB, gl.FLOAT, data)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return tex
}

// --- Render helpers ---

@(private)
mb_render_pass :: proc(res: ^Mb_Test_Resources, w, h: i32) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, res.fbo)
	gl.Viewport(0, 0, w, h)
	gl.Disable(gl.DEPTH_TEST)
	gl.ClearColor(0.0, 0.0, 0.0, 1.0)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	gl.UseProgram(res.program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, res.screen_tex)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, res.bloom_tex)
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, res.depth_tex)
	gl.ActiveTexture(gl.TEXTURE3)
	gl.BindTexture(gl.TEXTURE_2D, res.auto_exp_tex)
	gl.ActiveTexture(gl.TEXTURE4)
	gl.BindTexture(gl.TEXTURE_2D, res.velocity_tex)
	gl.ActiveTexture(gl.TEXTURE5)
	gl.BindTexture(gl.TEXTURE_2D, res.dof_tex)
	gl.ActiveTexture(gl.TEXTURE6)
	gl.BindTexture(gl.TEXTURE_2D, res.neighbor_max_tex)
	gl.ActiveTexture(gl.TEXTURE7)
	gl.BindTexture(gl.TEXTURE_2D, res.tile_max_tex)
	gl.ActiveTexture(gl.TEXTURE8)
	gl.BindTexture(gl.TEXTURE_3D, res.lut3d_tex)

	gl.BindVertexArray(res.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

@(private)
mb_capture_and_save :: proc(res: ^Mb_Test_Resources, w, h: i32, path: string) -> bool {
	gl.BindFramebuffer(gl.FRAMEBUFFER, res.fbo)
	pixels := make([]u8, int(w * h * 4))
	defer delete(pixels)
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	row_size := int(w * 4)
	row_buf := make([]u8, row_size)
	defer delete(row_buf)
	for y in 0 ..< int(h) / 2 {
		top := y * row_size
		bot := (int(h) - 1 - y) * row_size
		copy(row_buf, pixels[top:top + row_size])
		copy(pixels[top:top + row_size], pixels[bot:bot + row_size])
		copy(pixels[bot:bot + row_size], row_buf)
	}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	result := stbi.write_png(c_path, c.int(w), c.int(h), 4, raw_data(pixels), c.int(w * 4))
	return result != 0
}

@(private)
mb_update_velocity :: proc(res: ^Mb_Test_Resources, w, h: i32, vx, vy: f32) {
	vel_data := make([]f32, int(w * h * 2))
	defer delete(vel_data)
	for i in 0 ..< int(w * h) {
		vel_data[i * 2 + 0] = vx
		vel_data[i * 2 + 1] = vy
	}
	data_ptr := raw_data(vel_data)
	gl.BindTexture(gl.TEXTURE_2D, res.velocity_tex)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RG, gl.FLOAT, data_ptr)
	gl.BindTexture(gl.TEXTURE_2D, res.neighbor_max_tex)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RG, gl.FLOAT, data_ptr)
	gl.BindTexture(gl.TEXTURE_2D, res.tile_max_tex)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RG, gl.FLOAT, data_ptr)
}

@(private)
mb_readback_pixels :: proc(res: ^Mb_Test_Resources, w, h: i32) -> []u8 {
	gl.BindFramebuffer(gl.FRAMEBUFFER, res.fbo)
	pixels := make([]u8, int(w * h * 4))
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	return pixels
}

// --- Analysis ---

@(private)
Render_Stats :: struct {
	label:         string,
	avg_lum:       f32,
	non_black_pct: f32,
	gradient_var:  f32,
	edge_energy:   f32,
}

@(private)
Pair_Comparison :: struct {
	label:               string,
	psnr_db:             f32,
	gradient_var_ratio:  f32,
	edge_energy_ratio:   f32,
	regression_detected: bool,
}

@(private)
pixel_luminance :: proc(pixels: []u8, idx: int) -> f32 {
	r := f32(pixels[idx * 4 + 0]) / 255.0
	g := f32(pixels[idx * 4 + 1]) / 255.0
	b := f32(pixels[idx * 4 + 2]) / 255.0
	return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

@(private)
compute_render_stats :: proc(pixels: []u8, w, h: i32, label: string) -> Render_Stats {
	pixel_count := int(w * h)
	total_lum: f64
	non_black_count := 0

	for i in 0 ..< pixel_count {
		lum := pixel_luminance(pixels, i)
		total_lum += f64(lum)
		if lum > 0.004 { non_black_count += 1 }
	}

	// Gradient variance (horizontal luminance differences)
	grad_sum: f64
	grad_sq_sum: f64
	grad_count := 0
	for y in 0 ..< int(h) {
		for x in 1 ..< int(w) {
			idx := y * int(w) + x
			diff := f64(pixel_luminance(pixels, idx) - pixel_luminance(pixels, idx - 1))
			grad_sum += diff
			grad_sq_sum += diff * diff
			grad_count += 1
		}
	}
	grad_mean := grad_sum / f64(grad_count)
	gradient_var := f32(grad_sq_sum / f64(grad_count) - grad_mean * grad_mean)

	// Edge energy (central differences, |dx| + |dy|)
	edge_sum: f64
	edge_count := 0
	for y in 1 ..< int(h) - 1 {
		for x in 1 ..< int(w) - 1 {
			idx := y * int(w) + x
			dx := pixel_luminance(pixels, idx + 1) - pixel_luminance(pixels, idx - 1)
			dy := pixel_luminance(pixels, idx + int(w)) - pixel_luminance(pixels, idx - int(w))
			edge_sum += f64(math.abs(dx) + math.abs(dy))
			edge_count += 1
		}
	}

	return Render_Stats{
		label         = label,
		avg_lum       = f32(total_lum / f64(pixel_count)),
		non_black_pct = f32(non_black_count) / f32(pixel_count) * 100.0,
		gradient_var  = gradient_var,
		edge_energy   = f32(edge_sum / f64(edge_count)),
	}
}

@(private)
compute_psnr :: proc(pixels_a, pixels_b: []u8, w, h: i32) -> f32 {
	pixel_count := int(w * h)
	mse_sum: f64
	for i in 0 ..< pixel_count {
		for ch in 0 ..< 3 {
			a := f64(pixels_a[i * 4 + ch])
			b := f64(pixels_b[i * 4 + ch])
			diff := a - b
			mse_sum += diff * diff
		}
	}
	mse := mse_sum / f64(pixel_count * 3)
	if mse < 0.01 { return 99.0 }
	return f32(10.0 * math.log10(255.0 * 255.0 / mse))
}

PSNR_THRESHOLD :: f32(20.0)
GRADIENT_VAR_RATIO_MAX :: f32(1.15)
EDGE_ENERGY_RATIO_MAX :: f32(1.10)

@(private)
compare_pair :: proc(
	mb_stats, fxaa_stats: Render_Stats,
	pixels_mb, pixels_fxaa: []u8,
	w, h: i32,
	label: string,
) -> Pair_Comparison {
	psnr := compute_psnr(pixels_mb, pixels_fxaa, w, h)

	grad_ratio := f32(1.0)
	if mb_stats.gradient_var > 1e-8 {
		grad_ratio = fxaa_stats.gradient_var / mb_stats.gradient_var
	}
	edge_ratio := f32(1.0)
	if mb_stats.edge_energy > 1e-8 {
		edge_ratio = fxaa_stats.edge_energy / mb_stats.edge_energy
	}

	regression := psnr < PSNR_THRESHOLD ||
		grad_ratio > GRADIENT_VAR_RATIO_MAX ||
		edge_ratio > EDGE_ENERGY_RATIO_MAX

	return Pair_Comparison{
		label               = label,
		psnr_db             = psnr,
		gradient_var_ratio  = grad_ratio,
		edge_energy_ratio   = edge_ratio,
		regression_detected = regression,
	}
}

// --- FXAA pre-pass ---

@(private)
Fxaa_Prepass_Resources :: struct {
	program: u32,
	fbo:     u32,
	tex:     u32,
}

@(private)
fxaa_prepass_setup :: proc(t: ^testing.T, w, h: i32) -> (fxaa: Fxaa_Prepass_Resources, ok: bool) {
	fxaa.program, ok = shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/fxaa_prepass.frag")
	if !ok {
		testing.expect(t, false, "Failed to load FXAA pre-pass shader")
		return
	}
	gl.UseProgram(fxaa.program)
	loc := gl.GetUniformLocation(fxaa.program, "screenTexture")
	if loc >= 0 { gl.Uniform1i(loc, 0) }
	gl.UseProgram(0)

	gl.GenFramebuffers(1, &fxaa.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fxaa.fbo)
	gl.GenTextures(1, &fxaa.tex)
	gl.BindTexture(gl.TEXTURE_2D, fxaa.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fxaa.tex, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	ok = true
	return
}

@(private)
fxaa_prepass_cleanup :: proc(fxaa: ^Fxaa_Prepass_Resources) {
	if fxaa.program != 0 { gl.DeleteProgram(fxaa.program) }
	if fxaa.fbo != 0     { gl.DeleteFramebuffers(1, &fxaa.fbo) }
	if fxaa.tex != 0     { gl.DeleteTextures(1, &fxaa.tex) }
}

@(private)
fxaa_prepass_render :: proc(fxaa: ^Fxaa_Prepass_Resources, res: ^Mb_Test_Resources, w, h: i32) {
	ubo: postfx.Post_FX_UBO
	ubo.active_effects = 1 << u32(postfx.Post_Effect.FXAA)
	ubo.screen_texel_size = {1.0 / f32(w), 1.0 / f32(h)}
	ubo.fxaa_subpix = 0.75
	ubo.fxaa_edge_threshold = 0.125
	ubo.fxaa_edge_threshold_min = 0.063
	ubo.exposure_manual = 1.0
	ubo.z_near = 0.1
	ubo.z_far = 100.0
	gl.BindBuffer(gl.UNIFORM_BUFFER, res.ubo)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(postfx.Post_FX_UBO), &ubo)

	gl.BindFramebuffer(gl.FRAMEBUFFER, fxaa.fbo)
	gl.Viewport(0, 0, w, h)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.UseProgram(fxaa.program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, res.screen_tex)
	gl.BindVertexArray(res.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.UseProgram(0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// --- Render mode helpers ---

@(private)
render_mb_only :: proc(res: ^Mb_Test_Resources, w, h: i32) {
	ubo: postfx.Post_FX_UBO
	ubo.active_effects = 1 << u32(postfx.Post_Effect.Motion_Blur)
	ubo.screen_texel_size = {1.0 / f32(w), 1.0 / f32(h)}
	ubo.mb_intensity = MB_INTENSITY
	ubo.mb_max_velocity = 0.085
	ubo.mb_samples = 32
	ubo.exposure_manual = 1.0
	ubo.z_near = 0.1
	ubo.z_far = 100.0
	gl.BindBuffer(gl.UNIFORM_BUFFER, res.ubo)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(postfx.Post_FX_UBO), &ubo)
	mb_render_pass(res, w, h)
}

@(private)
render_fxaa_then_mb :: proc(fxaa: ^Fxaa_Prepass_Resources, res: ^Mb_Test_Resources, w, h: i32) {
	fxaa_prepass_render(fxaa, res, w, h)

	saved := res.screen_tex
	res.screen_tex = fxaa.tex
	gl.BindTexture(gl.TEXTURE_2D, fxaa.tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.GenerateMipmap(gl.TEXTURE_2D)

	ubo: postfx.Post_FX_UBO
	ubo.active_effects = 1 << u32(postfx.Post_Effect.Motion_Blur)
	ubo.screen_texel_size = {1.0 / f32(w), 1.0 / f32(h)}
	ubo.mb_intensity = MB_INTENSITY
	ubo.mb_max_velocity = 0.085
	ubo.mb_samples = 32
	ubo.exposure_manual = 1.0
	ubo.z_near = 0.1
	ubo.z_far = 100.0
	gl.BindBuffer(gl.UNIFORM_BUFFER, res.ubo)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(postfx.Post_FX_UBO), &ubo)

	mb_render_pass(res, w, h)
	res.screen_tex = saved
}

// --- Deterministic PRNG (PCG-XSH-RR, reproducible across runs) ---

@(private)
Prng :: struct { state: u64 }

@(private)
prng_create :: proc(seed: u64) -> Prng {
	return Prng{state = seed}
}

@(private)
prng_float32 :: proc(p: ^Prng) -> f32 {
	p.state = p.state * 6364136223846793005 + 1442695040888963407
	xorshifted := u32(((p.state >> 18) ~ p.state) >> 27)
	rot := u32(p.state >> 59)
	result := (xorshifted >> rot) | (xorshifted << ((~rot + 1) & 31))
	return f32(result) / f32(0xFFFFFFFF)
}

// --- Fixture upload (shared texture, full-res) ---

@(private)
upload_fixture_texture :: proc(img_data: [^]u8, img_w, img_h: c.int) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB16F, i32(img_w), i32(img_h), 0, gl.RGB, gl.UNSIGNED_BYTE, img_data)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	return tex
}

// =============================================================================
// TEST — Phase helpers
// =============================================================================

// Setup velocity + depth textures for a given resolution.
@(private)
mb_init_velocity_depth :: proc(res: ^Mb_Test_Resources, w, h: i32) {
	vel_init := make([]f32, int(w * h * 2))
	defer delete(vel_init)
	res.velocity_tex = create_tex_rg16f(w, h, raw_data(vel_init))
	res.neighbor_max_tex = create_tex_rg16f(w, h, raw_data(vel_init))
	res.tile_max_tex = create_tex_rg16f(w, h, raw_data(vel_init))

	depth_data := make([]f32, int(w * h))
	defer delete(depth_data)
	for i in 0 ..< int(w * h) { depth_data[i] = 0.5 }
	res.depth_tex = create_tex_r16f(w, h, raw_data(depth_data))
}

// Phase 1: Full-res user's exact values — always exports PNGs.
// Returns render count.
@(private)
run_fullres_user_values :: proc(
	t: ^testing.T,
	fixture_tex: u32,
	img_w, img_h: i32,
	comparisons: ^[dynamic]Pair_Comparison,
) -> (renders: int, ok: bool) {
	w, h := img_w, img_h

	res: Mb_Test_Resources
	res, ok = mb_test_setup(t, w, h)
	if !ok { return }
	defer mb_test_cleanup(&res)

	res.screen_tex = fixture_tex
	mb_init_velocity_depth(&res, w, h)

	fxaa: Fxaa_Prepass_Resources
	fxaa, ok = fxaa_prepass_setup(t, w, h)
	if !ok { return }
	defer fxaa_prepass_cleanup(&fxaa)

	// User's exact velocity: (-0.1076, -0.0173) / intensity
	mb_update_velocity(&res, w, h, f32(-0.1076) / MB_INTENSITY, f32(-0.0173) / MB_INTENSITY)

	// MB-only
	render_mb_only(&res, w, h)
	pixels_mb := mb_readback_pixels(&res, w, h)
	mb_capture_and_save(&res, w, h, OUTPUT_DIR + "/user_repro_exact_mb.png")
	stats_mb := compute_render_stats(pixels_mb, w, h, "EXACT MB")

	// FXAA pre-pass + MB
	render_fxaa_then_mb(&fxaa, &res, w, h)
	pixels_fxaa := mb_readback_pixels(&res, w, h)
	mb_capture_and_save(&res, w, h, OUTPUT_DIR + "/user_repro_exact_fxaa_mb.png")
	stats_fxaa := compute_render_stats(pixels_fxaa, w, h, "EXACT FXAA+MB")

	// No effects (passthrough)
	{
		ubo: postfx.Post_FX_UBO
		ubo.screen_texel_size = {1.0 / f32(w), 1.0 / f32(h)}
		ubo.exposure_manual = 1.0
		ubo.z_near = 0.1
		ubo.z_far = 100.0
		gl.BindBuffer(gl.UNIFORM_BUFFER, res.ubo)
		gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(postfx.Post_FX_UBO), &ubo)
	}
	mb_render_pass(&res, w, h)
	mb_capture_and_save(&res, w, h, OUTPUT_DIR + "/user_repro_no_fx.png")

	append(comparisons, compare_pair(stats_mb, stats_fxaa, pixels_mb, pixels_fxaa, w, h, "EXACT(-0.1076,-0.0173)"))
	delete(pixels_mb)
	delete(pixels_fxaa)

	res.screen_tex = 0 // Prevent double-free of shared fixture_tex
	renders = 3
	ok = true
	return
}

// Phase 2: Stochastic sweep at half-res. Only exports PNGs on regression.
// Returns render count.
@(private)
run_stochastic_sweep :: proc(
	t: ^testing.T,
	fixture_tex: u32,
	comparisons: ^[dynamic]Pair_Comparison,
) -> (renders: int, ok: bool) {
	w, h := STOCHASTIC_W, STOCHASTIC_H

	res: Mb_Test_Resources
	res, ok = mb_test_setup(t, w, h)
	if !ok { return }
	defer mb_test_cleanup(&res)

	res.screen_tex = fixture_tex
	mb_init_velocity_depth(&res, w, h)

	fxaa: Fxaa_Prepass_Resources
	fxaa, ok = fxaa_prepass_setup(t, w, h)
	if !ok { return }
	defer fxaa_prepass_cleanup(&fxaa)

	rng := prng_create(STOCHASTIC_SEED)

	fmt.printf("\n[MB+FXAA] Stochastic sweep: %d samples at %dx%d (seed=0x%X)\n",
		STOCHASTIC_SAMPLES, w, h, STOCHASTIC_SEED)

	for sample_idx in 0 ..< STOCHASTIC_SAMPLES {
		angle_deg := prng_float32(&rng) * 360.0
		magnitude := 0.01 + prng_float32(&rng) * 0.19

		dir_rad := angle_deg * math.RAD_PER_DEG
		vx := magnitude * math.cos(dir_rad) / MB_INTENSITY
		vy := magnitude * math.sin(dir_rad) / MB_INTENSITY
		mb_update_velocity(&res, w, h, vx, vy)

		// MB-only
		render_mb_only(&res, w, h)
		pixels_mb := mb_readback_pixels(&res, w, h)
		stats_mb := compute_render_stats(pixels_mb, w, h,
			fmt.tprintf("S%02d dir=%.1f mag=%.3f MB", sample_idx, angle_deg, magnitude))

		// FXAA pre-pass + MB
		render_fxaa_then_mb(&fxaa, &res, w, h)
		pixels_fxaa := mb_readback_pixels(&res, w, h)
		stats_fxaa := compute_render_stats(pixels_fxaa, w, h,
			fmt.tprintf("S%02d dir=%.1f mag=%.3f FXAA+MB", sample_idx, angle_deg, magnitude))

		// Pair comparison + conditional export
		pair_label := fmt.tprintf("S%02d dir=%.1f mag=%.3f", sample_idx, angle_deg, magnitude)
		cmp := compare_pair(stats_mb, stats_fxaa, pixels_mb, pixels_fxaa, w, h, pair_label)
		append(comparisons, cmp)

		if cmp.regression_detected {
			mb_capture_and_save(&res, w, h,
				fmt.tprintf("%s/REGRESS_s%02d_dir%.0f_mag%.0f_mb.png", OUTPUT_DIR, sample_idx, angle_deg, magnitude * 1000))
			mb_capture_and_save(&res, w, h,
				fmt.tprintf("%s/REGRESS_s%02d_dir%.0f_mag%.0f_fxaa_mb.png", OUTPUT_DIR, sample_idx, angle_deg, magnitude * 1000))
			fmt.printf("  [!] REGRESSION S%02d: dir=%.1f° mag=%.3f PSNR=%.1fdB grad=%.3f edge=%.3f\n",
				sample_idx, angle_deg, magnitude, cmp.psnr_db, cmp.gradient_var_ratio, cmp.edge_energy_ratio)
		}

		delete(pixels_mb)
		delete(pixels_fxaa)
		renders += 2
	}

	res.screen_tex = 0
	ok = true
	return
}

// Print summary table, return regression count.
@(private)
print_regression_summary :: proc(comparisons: []Pair_Comparison, render_count: int) -> int {
	regression_count := 0
	for cmp in comparisons {
		if cmp.regression_detected { regression_count += 1 }
	}

	fmt.printf("\n[MB+FXAA] Results: %d renders, %d/%d pairs passed, %d regressions\n",
		render_count, len(comparisons) - regression_count, len(comparisons), regression_count)

	fmt.printf("%-35s | %8s | %10s | %10s | %s\n", "Pair", "PSNR_dB", "GradRatio", "EdgeRatio", "Result")
	fmt.printf("%s\n", "------------------------------------------------------------------------------------")
	for cmp in comparisons {
		result := "PASS" if !cmp.regression_detected else "REGRESS!"
		fmt.printf("%-35s | %8.2f | %10.4f | %10.4f | %s\n",
			cmp.label, cmp.psnr_db, cmp.gradient_var_ratio, cmp.edge_energy_ratio, result)
	}

	return regression_count
}

// =============================================================================
// TEST ENTRY POINT
// =============================================================================

@(test)
test_mb_fxaa_prepass :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }
	os.make_directory(OUTPUT_DIR)

	// Load fixture
	INPUT_PATH :: "tests/gl/fixtures/mb_input_envmap_crop.png"
	input_path_c := strings.clone_to_cstring(INPUT_PATH)
	defer delete(input_path_c)

	img_w, img_h, img_ch: c.int
	img_data := stbi.load(input_path_c, &img_w, &img_h, &img_ch, 3)
	if img_data == nil {
		testing.expect(t, false, "Failed to load fixture")
		return
	}
	defer stbi.image_free(img_data)

	fixture_tex := upload_fixture_texture(img_data, img_w, img_h)
	defer gl.DeleteTextures(1, &fixture_tex)

	comparisons: [dynamic]Pair_Comparison
	defer delete(comparisons)

	// Phase 1: full-res user values (3 renders, always export PNGs)
	renders_p1, ok_p1 := run_fullres_user_values(t, fixture_tex, i32(img_w), i32(img_h), &comparisons)
	if !ok_p1 { return }

	// Phase 2: stochastic sweep at half-res (128 renders, export only on regression)
	renders_p2, ok_p2 := run_stochastic_sweep(t, fixture_tex, &comparisons)
	if !ok_p2 { return }

	// Summary + assertion
	regression_count := print_regression_summary(comparisons[:], renders_p1 + renders_p2)
	testing.expect(t, regression_count == 0,
		fmt.tprintf("REGRESSION: %d/%d pairs failed", regression_count, len(comparisons)))

	fmt.printf("\n[MB+FXAA] Outputs: %s/ (full-res user values always exported)\n", OUTPUT_DIR)
}
