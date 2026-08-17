// SIMD FP32→FP16 conversion utility.
// ISO: suckless-ogl/src/simd_utils.c — ported verbatim.
// Uses AVX2/F16C intrinsics with scalar fallback.

#include "simd_utils.h"

#include <stdbool.h>
#include <stdint.h>

#if defined(__F16C__) && defined(__AVX__)

#include <immintrin.h>

#define F16C_ROUND_MODE (_MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC)
#define SIMD_BATCH_SIZE 8

static inline uint16_t float_to_half_intrinsic(float value)
{
	__m128 vec = _mm_set_ss(value);
	__m128i result = _mm_cvtps_ph(vec, F16C_ROUND_MODE);
	return (uint16_t)_mm_cvtsi128_si32(result);
}

void convert_float_to_half_simd(const float* src, uint16_t* dst, size_t count)
{
	size_t idx = 0;

#ifdef __AVX2__
	for (; idx + SIMD_BATCH_SIZE <= count; idx += SIMD_BATCH_SIZE) {
		__m256 v_fp32 = _mm256_loadu_ps(&src[idx]);
		__m128i v_fp16 = _mm256_cvtps_ph(v_fp32, F16C_ROUND_MODE);
		_mm_storeu_si128((__m128i*)&dst[idx], v_fp16);
	}
#endif

	// Scalar tail using F16C
	for (; idx < count; ++idx) {
		dst[idx] = float_to_half_intrinsic(src[idx]);
	}
}

#else // Software fallback (no F16C)

// IEEE 754 float32 → float16 scalar conversion
static uint16_t float_to_half_scalar(float value)
{
	uint32_t f;
	__builtin_memcpy(&f, &value, sizeof(f));

	uint16_t sign = (f >> 16) & 0x8000;
	int32_t exp = ((f >> 23) & 0xFF) - 127 + 15;
	uint32_t mantissa = f & 0x7FFFFF;

	if (exp <= 0) {
		if (exp < -10) {
			return sign; // too small, flush to zero
		}
		// Denormalized half
		mantissa |= 0x800000;
		uint32_t shift = (uint32_t)(14 - exp);
		// Round to nearest even
		uint32_t round_bit = 1u << (shift - 1);
		uint32_t result = mantissa >> shift;
		if ((mantissa & round_bit) && (result & 1 || (mantissa & (round_bit - 1)))) {
			result++;
		}
		return sign | (uint16_t)result;
	} else if (exp == 0xFF - 127 + 15) {
		if (mantissa == 0) {
			return sign | 0x7C00; // Inf
		}
		return sign | 0x7E00; // NaN
	} else if (exp > 30) {
		return sign | 0x7C00; // Overflow → Inf
	}

	// Round to nearest even
	uint16_t half = sign | ((uint16_t)exp << 10) | (uint16_t)(mantissa >> 13);
	if ((mantissa >> 12) & 1) {
		if ((half & 1) || (mantissa & 0xFFF)) {
			half++;
		}
	}
	return half;
}

void convert_float_to_half_simd(const float* src, uint16_t* dst, size_t count)
{
	for (size_t i = 0; i < count; ++i) {
		dst[i] = float_to_half_scalar(src[i]);
	}
}

#endif
