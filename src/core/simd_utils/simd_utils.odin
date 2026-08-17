package simd_utils

// SIMD FP32→FP16 conversion — ISO: suckless-ogl/src/simd_utils.c
// Uses AVX2/F16C intrinsics (compiled with -mavx2 -mf16c).
// Linked via deps/libtracy.a (shared native deps archive).

foreign import lib "../../../deps/libsimd.a"

@(default_calling_convention = "c")
foreign lib {
	// Convert `count` float32 values to float16 (half) values.
	// src: pointer to float32 array
	// dst: pointer to uint16 array (caller-allocated, count elements)
	// count: number of float values (NOT pixels — for RGBA: width*height*4)
	convert_float_to_half_simd :: proc(src: [^]f32, dst: [^]u16, count: uint) ---
}
