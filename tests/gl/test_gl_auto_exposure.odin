// +build test
// Auto-Exposure GPU Benchmark.
//
// Measures auto-exposure compute dispatch time in isolation using GL_TIME_ELAPSED.
// Runs WARMUP_ITERS warmup iterations then BENCH_ITERS timed iterations.
//
// Run: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
package test_gl

import "core:testing"
import "core:fmt"
import "core:time"

import gl "vendor:OpenGL"

import postfx "../../src/rendering/postfx"

// --- Benchmark Parameters ---

BENCH_SCENE_W :: i32(512)
BENCH_SCENE_H :: i32(384)
WARMUP_ITERS :: 20
BENCH_ITERS :: 100

// =============================================================================
// GL Timer Query helpers
// =============================================================================

@(private)
Gpu_Timer :: struct {
	queries: [2]u32, // begin/end
}

@(private)
gpu_timer_create :: proc() -> Gpu_Timer {
	t: Gpu_Timer
	gl.GenQueries(2, raw_data(&t.queries))
	return t
}

@(private)
gpu_timer_destroy :: proc(t: ^Gpu_Timer) {
	gl.DeleteQueries(2, raw_data(&t.queries))
}

@(private)
gpu_timer_begin :: proc(t: ^Gpu_Timer) {
	gl.QueryCounter(t.queries[0], gl.TIMESTAMP)
}

@(private)
gpu_timer_end :: proc(t: ^Gpu_Timer) {
	gl.QueryCounter(t.queries[1], gl.TIMESTAMP)
}

@(private)
gpu_timer_elapsed_ms :: proc(t: ^Gpu_Timer) -> f64 {
	start, end: u64
	gl.GetQueryObjectui64v(t.queries[0], gl.QUERY_RESULT, &start)
	gl.GetQueryObjectui64v(t.queries[1], gl.QUERY_RESULT, &end)
	return f64(end - start) / 1_000_000.0
}

// =============================================================================
// Scene texture creation (random noise HDR)
// =============================================================================

@(private)
create_bench_scene_texture :: proc(w, h: i32) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)

	// Fill with pseudo-random HDR data (deterministic pattern)
	pixel_count := int(w * h)
	data := make([]f32, pixel_count * 4)
	defer delete(data)

	seed := u32(0x12345678)
	for i in 0 ..< pixel_count {
		// Simple xorshift32
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		r := f32(seed & 0xFFFF) / 65535.0 * 4.0 // HDR range [0, 4]
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		g := f32(seed & 0xFFFF) / 65535.0 * 4.0
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		b := f32(seed & 0xFFFF) / 65535.0 * 4.0

		data[i * 4 + 0] = r
		data[i * 4 + 1] = g
		data[i * 4 + 2] = b
		data[i * 4 + 3] = 1.0
	}

	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, raw_data(data))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	return tex
}

// =============================================================================
// BENCHMARK TEST
// =============================================================================

@(test)
test_auto_exposure_benchmark :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// Create scene texture
	scene_tex := create_bench_scene_texture(BENCH_SCENE_W, BENCH_SCENE_H)
	defer gl.DeleteTextures(1, &scene_tex)

	// Create auto-exposure resources
	fx: postfx.Auto_Exposure_FX
	ok := postfx.auto_exposure_create(&fx)
	if !ok {
		testing.expect(t, false, "Failed to create auto-exposure resources")
		return
	}
	defer postfx.auto_exposure_destroy(&fx)

	// GPU timer
	timer := gpu_timer_create()
	defer gpu_timer_destroy(&timer)

	// Warmup (stabilize GPU clocks, fill caches)
	for _ in 0 ..< WARMUP_ITERS {
		postfx.auto_exposure_render(&fx, scene_tex, 0.016)
	}
	gl.Finish()

	// Timed iterations
	times: [BENCH_ITERS]f64
	for i in 0 ..< BENCH_ITERS {
		gpu_timer_begin(&timer)
		postfx.auto_exposure_render(&fx, scene_tex, 0.016)
		gpu_timer_end(&timer)
		gl.Finish() // ensure timer result is available

		times[i] = gpu_timer_elapsed_ms(&timer)
	}

	// Statistics
	total: f64
	min_t := times[0]
	max_t := times[0]
	for i in 0 ..< BENCH_ITERS {
		total += times[i]
		if times[i] < min_t { min_t = times[i] }
		if times[i] > max_t { max_t = times[i] }
	}
	avg := total / f64(BENCH_ITERS)

	// Compute p50/p95 (simple sort)
	sorted := times
	for i in 0 ..< BENCH_ITERS {
		for j in i + 1 ..< BENCH_ITERS {
			if sorted[j] < sorted[i] {
				sorted[i], sorted[j] = sorted[j], sorted[i]
			}
		}
	}
	p50 := sorted[BENCH_ITERS / 2]
	p95 := sorted[BENCH_ITERS * 95 / 100]

	fmt.printf("\n[AUTO-EXPOSURE BENCHMARK] %dx%d, %d iterations\n", BENCH_SCENE_W, BENCH_SCENE_H, BENCH_ITERS)
	fmt.printf("  Avg:  %.3f ms\n", avg)
	fmt.printf("  P50:  %.3f ms\n", p50)
	fmt.printf("  P95:  %.3f ms\n", p95)
	fmt.printf("  Min:  %.3f ms\n", min_t)
	fmt.printf("  Max:  %.3f ms\n", max_t)

	// Verify exposure converged to a reasonable value
	exposure := fx.current_exposure
	fmt.printf("  Final exposure: %.4f\n", exposure)
	testing.expect(t, exposure > 0.0, fmt.tprintf("Exposure should be positive, got %.4f", exposure))
}
