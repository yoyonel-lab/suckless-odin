package tests

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"
import "core:time"
import stbi "vendor:stb/image"
import simd "../src/core/simd_utils"

@(test)
test_simd_float_to_half_basic :: proc(t: ^testing.T) {
	src := [?]f32{0.0, 1.0, -1.0, 0.5, -0.5, 2.0, 65504.0, -65504.0}
	dst_simd: [len(src)]u16
	dst_scalar: [len(src)]u16

	simd.convert_float_to_half_simd(&src[0], &dst_simd[0], len(src))
	simd.convert_float_to_half_scalar(&src[0], &dst_scalar[0], len(src))

	for i in 0 ..< len(src) {
		testing.expect_value(t, dst_simd[i], dst_scalar[i])
	}

	// Exact IEEE-754 half-precision values
	testing.expect_value(t, dst_simd[0], u16(0x0000)) // +0.0
	testing.expect_value(t, dst_simd[1], u16(0x3C00)) // +1.0
	testing.expect_value(t, dst_simd[2], u16(0xBC00)) // -1.0
	testing.expect_value(t, dst_simd[3], u16(0x3800)) // +0.5
	testing.expect_value(t, dst_simd[4], u16(0xB800)) // -0.5
	testing.expect_value(t, dst_simd[5], u16(0x4000)) // +2.0
	testing.expect_value(t, dst_simd[6], u16(0x7BFF)) // max normal half
	testing.expect_value(t, dst_simd[7], u16(0xFBFF)) // min normal half
}

@(test)
test_simd_float_to_half_edge_cases :: proc(t: ^testing.T) {
	pos_inf := f32(1e38) * f32(1e38)
	neg_inf := -pos_inf
	nan_val := pos_inf - pos_inf

	src := [?]f32{
		-0.0,
		1e-7,       // subnormal in half precision
		1e-8,       // subnormal in half precision
		1e-10,      // flush to zero in half precision
		100000.0,   // overflow -> +Inf
		-100000.0,  // underflow -> -Inf
		pos_inf,
		neg_inf,
		nan_val,
	}

	dst_simd: [len(src)]u16
	dst_scalar: [len(src)]u16

	simd.convert_float_to_half_simd(&src[0], &dst_simd[0], len(src))
	simd.convert_float_to_half_scalar(&src[0], &dst_scalar[0], len(src))

	// -0.0
	testing.expect_value(t, dst_simd[0], u16(0x8000))
	// Overflows
	testing.expect_value(t, dst_simd[4], u16(0x7C00)) // +Inf
	testing.expect_value(t, dst_simd[5], u16(0xFC00)) // -Inf
	testing.expect_value(t, dst_simd[6], u16(0x7C00)) // +Inf
	testing.expect_value(t, dst_simd[7], u16(0xFC00)) // -Inf

	// NaN check (exponent must be 0x1F and mantissa non-zero)
	exp_simd := (dst_simd[8] >> 10) & 0x1F
	testing.expect(t, exp_simd == 0x1F, "NaN must have exponent 0x1F")

	// Compare rest with scalar
	for i in 0 ..< 8 {
		testing.expect_value(t, dst_simd[i], dst_scalar[i])
	}
}

@(test)
test_simd_float_to_half_unaligned_counts :: proc(t: ^testing.T) {
	counts := [?]uint{0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256, 1023, 1024, 1025}

	for count in counts {
		if count == 0 {
			simd.convert_float_to_half_simd(nil, nil, 0)
			continue
		}

		src := make([]f32, count)
		defer delete(src)
		dst_simd := make([]u16, count)
		defer delete(dst_simd)
		dst_scalar := make([]u16, count)
		defer delete(dst_scalar)

		for i in 0 ..< count {
			src[i] = f32(i) * 0.125
		}

		simd.convert_float_to_half_simd(&src[0], &dst_simd[0], count)
		simd.convert_float_to_half_scalar(&src[0], &dst_scalar[0], count)

		for i in 0 ..< count {
			if dst_simd[i] != dst_scalar[i] {
				testing.fail_now(t, fmt.tprintf("Mismatch at count=%d idx=%d: simd=%04X scalar=%04X src=%f",
					count, i, dst_simd[i], dst_scalar[i], src[i]))
			}
		}
	}
}

@(test)
test_simd_bit_for_bit_vs_scalar_1m :: proc(t: ^testing.T) {
	count :: 1_000_000

	alloc_bytes_src := (count * size_of(f32) + 63) & ~uint(63)
	alloc_bytes_dst := (count * size_of(u16) + 63) & ~uint(63)

	src := cast([^]f32)libc.aligned_alloc(64, alloc_bytes_src)
	defer libc.free(src)
	dst_simd := cast([^]u16)libc.aligned_alloc(64, alloc_bytes_dst)
	defer libc.free(dst_simd)
	dst_scalar := cast([^]u16)libc.aligned_alloc(64, alloc_bytes_dst)
	defer libc.free(dst_scalar)

	testing.expect(t, src != nil && dst_simd != nil && dst_scalar != nil, "Memory allocation failed")

	// Fill with wide variety of HDR values, standard floats, small decimals, negative values
	rng := rand.default_random_generator()
	for i in 0 ..< count {
		r := rand.float32(rng)
		switch i % 5 {
		case 0: src[i] = r * 100.0          // Standard radiance
		case 1: src[i] = r * 65000.0        // Extreme HDR highlights
		case 2: src[i] = -r * 50.0          // Negative values
		case 3: src[i] = r * 0.001          // Very small values
		case 4: src[i] = (r - 0.5) * 10.0   // Mixed sign
		}
	}

	simd.convert_float_to_half_simd(src, dst_simd, count)
	simd.convert_float_to_half_scalar(src, dst_scalar, count)

	mismatch_count := 0
	for i in 0 ..< count {
		if dst_simd[i] != dst_scalar[i] {
			mismatch_count += 1
			if mismatch_count <= 5 {
				testing.expectf(t, false, "Bit-for-bit mismatch at index %d: src=%f, SIMD=%04X, Scalar=%04X",
					i, src[i], dst_simd[i], dst_scalar[i])
			}
		}
	}

	testing.expect_value(t, mismatch_count, 0)
}

@(test)
test_simd_micro_benchmark_4k :: proc(t: ^testing.T) {
	// 4K HDR texture = 4096 x 2048 x 4 RGBA floats = 33,554,432 floats = 134.2 MB FP32
	count :: 4096 * 2048 * 4
	bytes_in :: count * size_of(f32)
	bytes_out :: count * size_of(u16)

	src := cast([^]f32)libc.aligned_alloc(64, bytes_in)
	defer libc.free(src)
	dst := cast([^]u16)libc.aligned_alloc(64, bytes_out)
	defer libc.free(dst)

	testing.expect(t, src != nil && dst != nil, "Memory allocation failed")

	for i in 0 ..< count {
		src[i] = f32(i % 1024) * 0.1
	}

	// Warmup
	simd.convert_float_to_half_simd(src, dst, count)

	// Measure 50 iterations
	iterations :: 50
	start := time.tick_now()
	for _ in 0 ..< iterations {
		simd.convert_float_to_half_simd(src, dst, count)
	}
	elapsed := time.tick_since(start)
	elapsed_ms := time.duration_milliseconds(elapsed)
	avg_ms := elapsed_ms / f64(iterations)

	total_gb_processed := f64(bytes_in + bytes_out) * f64(iterations) / (1024.0 * 1024.0 * 1024.0)
	throughput_gb_s := total_gb_processed / (f64(time.duration_seconds(elapsed)))

	fmt.printf("\n[SIMD 4K HDR MICRO-BENCHMARK]\n")
	fmt.printf("  Data Size: %d floats (%.1f MB FP32 -> %.1f MB FP16)\n", count, f64(bytes_in)/(1024*1024), f64(bytes_out)/(1024*1024))
	fmt.printf("  Avg Time per 4K Conversion: %.2f ms\n", avg_ms)
	fmt.printf("  Effective Memory Throughput: %.2f GB/s\n", throughput_gb_s)

	testing.expect(t, avg_ms < 50.0, "Conversion time should be well under 50ms")
}

@(test)
test_fast_hdr_get_dimensions :: proc(t: ^testing.T) {
	path := "assets/textures/hdr/cedar_bridge_2_4k.hdr"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		path = "../assets/textures/hdr/cedar_bridge_2_4k.hdr"
		data, err = os.read_entire_file_from_path(path, context.allocator)
	}
	testing.expect(t, err == nil, "Failed to read HDR asset file")
	defer delete(data)

	w, h: i32
	ret := simd.fast_hdr_get_dimensions(raw_data(data), uint(len(data)), &w, &h)
	testing.expect_value(t, ret, 1)
	testing.expect_value(t, w, 4096)
	testing.expect_value(t, h, 2048)
}

@(test)
test_fast_hdr_accuracy_vs_stb :: proc(t: ^testing.T) {
	path := "assets/textures/hdr/cedar_bridge_2_4k.hdr"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		path = "../assets/textures/hdr/cedar_bridge_2_4k.hdr"
		data, err = os.read_entire_file_from_path(path, context.allocator)
	}
	testing.expect(t, err == nil, "Failed to read HDR asset file")
	defer delete(data)

	// 1. Decode with fast direct HDR decoder (FP16)
	w, h: i32
	ret := simd.fast_hdr_get_dimensions(raw_data(data), uint(len(data)), &w, &h)
	testing.expect_value(t, ret, 1)

	pixel_count := uint(w) * uint(h) * 4
	bytes_fp16 := (pixel_count * size_of(u16) + 63) & ~uint(63)
	fast_fp16 := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
	defer libc.free(fast_fp16)

	decode_ok := simd.fast_hdr_decode_fp16(raw_data(data), uint(len(data)), &w, &h, fast_fp16, pixel_count, 1)
	testing.expect_value(t, decode_ok, 1)

	// 2. Decode with reference STB + convert_float_to_half_simd
	stbi.set_flip_vertically_on_load(1)
	w_c, h_c, ch_c: c.int
	path_cstr := fmt.ctprintf("%s", path)
	stb_data := stbi.loadf(path_cstr, &w_c, &h_c, &ch_c, 4)
	testing.expect(t, stb_data != nil, "STB load failed")
	defer stbi.image_free(stb_data)

	testing.expect_value(t, i32(w_c), w)
	testing.expect_value(t, i32(h_c), h)

	stb_fp16 := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
	defer libc.free(stb_fp16)
	simd.convert_float_to_half_simd(stb_data, stb_fp16, pixel_count)

	mismatches := 0
	for i in 0 ..< pixel_count {
		if fast_fp16[i] != stb_fp16[i] {
			mismatches += 1
			if mismatches <= 5 {
				fmt.printf("Elem %d: Fast=0x%04X, STB=0x%04X, STB_F32=%f\n",
					i, fast_fp16[i], stb_fp16[i], stb_data[i])
			}
		}
	}
	testing.expect_value(t, mismatches, 0)
}

@(test)
test_fast_hdr_benchmark :: proc(t: ^testing.T) {
	path := "assets/textures/hdr/cedar_bridge_2_4k.hdr"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		path = "../assets/textures/hdr/cedar_bridge_2_4k.hdr"
		data, err = os.read_entire_file_from_path(path, context.allocator)
	}
	testing.expect(t, err == nil, "Failed to read HDR asset file")
	defer delete(data)

	w, h: i32
	simd.fast_hdr_get_dimensions(raw_data(data), uint(len(data)), &w, &h)
	pixel_count := uint(w) * uint(h) * 4
	bytes_fp16 := (pixel_count * size_of(u16) + 63) & ~uint(63)
	fast_fp16 := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
	defer libc.free(fast_fp16)

	// Benchmark Fast Direct HDR Decoder
	iterations :: 20
	start_fast := time.tick_now()
	for _ in 0 ..< iterations {
		simd.fast_hdr_decode_fp16(raw_data(data), uint(len(data)), &w, &h, fast_fp16, pixel_count, 1)
	}
	elapsed_fast := time.tick_since(start_fast)
	avg_fast_ms := time.duration_milliseconds(elapsed_fast) / f64(iterations)

	// Benchmark STB Decoder
	stbi.set_flip_vertically_on_load(1)
	w_c, h_c, ch_c: c.int
	path_cstr := fmt.ctprintf("%s", path)

	start_stb := time.tick_now()
	for _ in 0 ..< 5 {
		stb_data := stbi.loadf(path_cstr, &w_c, &h_c, &ch_c, 4)
		if stb_data != nil {
			simd.convert_float_to_half_simd(stb_data, fast_fp16, pixel_count)
			stbi.image_free(stb_data)
		}
	}
	elapsed_stb := time.tick_since(start_stb)
	avg_stb_ms := time.duration_milliseconds(elapsed_stb) / 5.0

	// Benchmark Multi-Threaded Fast Direct HDR Decoder (8 threads)
	start_threaded := time.tick_now()
	for _ in 0 ..< iterations {
		simd.fast_hdr_decode_fp16_threaded(raw_data(data), uint(len(data)), &w, &h, fast_fp16, pixel_count, 1, 8)
	}
	elapsed_threaded := time.tick_since(start_threaded)
	avg_threaded_ms := time.duration_milliseconds(elapsed_threaded) / f64(iterations)

	fmt.printf("\n[HDR 4K DECODE COMPARISON BENCHMARK]\n")
	fmt.printf("  STB image loadf + FP16 SIMD   : %.2f ms (with ~134MB heap alloc/free)\n", avg_stb_ms)
	fmt.printf("  Fast Direct HDR (Single-Thread): %.2f ms (0 heap allocs, L1 streaming)\n", avg_fast_ms)
	fmt.printf("  Fast Direct HDR (8 Threads)   : %.2f ms (0 heap allocs, parallel slices)\n", avg_threaded_ms)
	fmt.printf("  Speedup vs STB                : %.2fx faster!\n", avg_stb_ms / avg_threaded_ms)
	fmt.printf("  Speedup vs Single-Thread      : %.2fx faster!\n", avg_fast_ms / avg_threaded_ms)

	testing.expect(t, avg_threaded_ms < avg_fast_ms, "Multi-threaded decoder must be faster than single-threaded")
}

@(test)
test_fast_hdr_threaded_accuracy :: proc(t: ^testing.T) {
	path := "assets/textures/hdr/cedar_bridge_2_4k.hdr"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		path = "../assets/textures/hdr/cedar_bridge_2_4k.hdr"
		data, err = os.read_entire_file_from_path(path, context.allocator)
	}
	testing.expect(t, err == nil, "Failed to read HDR asset file")
	defer delete(data)

	w, h: i32
	ret := simd.fast_hdr_get_dimensions(raw_data(data), uint(len(data)), &w, &h)
	testing.expect_value(t, ret, 1)

	pixel_count := uint(w) * uint(h) * 4
	bytes_fp16 := (pixel_count * size_of(u16) + 63) & ~uint(63)

	single_fp16 := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
	defer libc.free(single_fp16)
	simd.fast_hdr_decode_fp16(raw_data(data), uint(len(data)), &w, &h, single_fp16, pixel_count, 1)

	multi_fp16 := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
	defer libc.free(multi_fp16)
	simd.fast_hdr_decode_fp16_threaded(raw_data(data), uint(len(data)), &w, &h, multi_fp16, pixel_count, 1, 8)

	mismatches := 0
	for i in 0 ..< pixel_count {
		if single_fp16[i] != multi_fp16[i] {
			mismatches += 1
		}
	}
	testing.expect_value(t, mismatches, 0)
}
