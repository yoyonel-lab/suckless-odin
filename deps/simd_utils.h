#ifndef SIMD_UTILS_H
#define SIMD_UTILS_H

#include <stddef.h>
#include <stdint.h>

// Convert float32 array to float16 (half) array using SIMD (AVX2/F16C).
// Falls back to scalar IEEE-754 conversion if F16C unavailable.
// ISO: suckless-ogl/src/simd_utils.c
void convert_float_to_half_simd(const float* src, uint16_t* dst, size_t count);

#endif
