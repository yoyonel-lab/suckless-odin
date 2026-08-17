#ifndef SIMD_UTILS_H
#define SIMD_UTILS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Convert float32 array to float16 (half) array using SIMD (AVX2/F16C)
// with Non-Temporal Streaming Stores (_mm_stream_si128) and unrolling.
// Falls back to scalar IEEE-754 conversion if F16C unavailable.
void convert_float_to_half_simd(const float* src, uint16_t* dst, size_t count);

// Fast direct Radiance HDR (RGBE) -> FP16 Decoder.
// Decodes 32-bit RLE RGBE scanlines in L1 cache and writes RGBA half-floats directly
// using AVX2 non-temporal streaming stores, bypassing intermediate FP32 heap buffers.
// Returns 1 on success, 0 on failure/unsupported format.
int fast_hdr_get_dimensions(const uint8_t* data, size_t size, int* out_w, int* out_h);
int fast_hdr_decode_fp16(const uint8_t* data, size_t size, int* out_w, int* out_h, uint16_t* out_fp16, size_t max_elements, int flip_y);
int fast_hdr_decode_fp16_threaded(const uint8_t* data, size_t size, int* out_w, int* out_h, uint16_t* out_fp16, size_t max_elements, int flip_y, int num_threads);

#ifdef __cplusplus
}
#endif

#endif
