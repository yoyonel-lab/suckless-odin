// SIMD FP32→FP16 conversion & Fast Direct HDR Decoder.
// High-performance AVX2/F16C conversion with Non-Temporal Streaming Stores.
// Eliminates Read-For-Ownership (RFO) traffic, prevents cache thrashing, and decodes
// Radiance RGBE HDR directly to FP16 in L1 cache with 0 intermediate heap allocations.

#include "simd_utils.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>

// --- Static Precomputed Exponent Lookup Table for RGBE ---
// s_exp_table[e] = ldexpf(1.0f, e - (128 + 8)) = 2^(e - 136) for e > 0; 0 for e == 0
static float s_exp_table[256];
static bool s_exp_table_initialized = false;

static void init_exp_table(void)
{
	if (s_exp_table_initialized) return;
	s_exp_table[0] = 0.0f;
	for (int e = 1; e < 256; ++e) {
		s_exp_table[e] = ldexpf(1.0f, e - 136);
	}
	s_exp_table_initialized = true;
}

// --- Reference Scalar IEEE-754 Converter ---
static uint16_t float_to_half_scalar_impl(float value)
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

void convert_float_to_half_scalar(const float* src, uint16_t* dst, size_t count)
{
	for (size_t i = 0; i < count; ++i) {
		dst[i] = float_to_half_scalar_impl(src[i]);
	}
}

#if defined(__F16C__) && defined(__AVX__)

#include <immintrin.h>

#define F16C_ROUND_MODE (_MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC)
#define SIMD_BLOCK_SIZE 32
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
	// Check if destination pointer is 16-byte aligned for streaming stores
	bool dst_aligned = (((uintptr_t)dst) & 0xF) == 0;

	if (dst_aligned) {
		// Quad-unrolled main loop (32 floats = 128 bytes read, 64 bytes written per iteration)
		for (; idx + SIMD_BLOCK_SIZE <= count; idx += SIMD_BLOCK_SIZE) {
			_mm_prefetch((const char*)&src[idx + 64], _MM_HINT_T0);
			_mm_prefetch((const char*)&src[idx + 96], _MM_HINT_T0);

			__m256 v0 = _mm256_loadu_ps(&src[idx + 0]);
			__m256 v1 = _mm256_loadu_ps(&src[idx + 8]);
			__m256 v2 = _mm256_loadu_ps(&src[idx + 16]);
			__m256 v3 = _mm256_loadu_ps(&src[idx + 24]);

			__m128i h0 = _mm256_cvtps_ph(v0, F16C_ROUND_MODE);
			__m128i h1 = _mm256_cvtps_ph(v1, F16C_ROUND_MODE);
			__m128i h2 = _mm256_cvtps_ph(v2, F16C_ROUND_MODE);
			__m128i h3 = _mm256_cvtps_ph(v3, F16C_ROUND_MODE);

			_mm_stream_si128((__m128i*)&dst[idx + 0], h0);
			_mm_stream_si128((__m128i*)&dst[idx + 8], h1);
			_mm_stream_si128((__m128i*)&dst[idx + 16], h2);
			_mm_stream_si128((__m128i*)&dst[idx + 24], h3);
		}

		for (; idx + SIMD_BATCH_SIZE <= count; idx += SIMD_BATCH_SIZE) {
			__m256 v = _mm256_loadu_ps(&src[idx]);
			__m128i h = _mm256_cvtps_ph(v, F16C_ROUND_MODE);
			_mm_stream_si128((__m128i*)&dst[idx], h);
		}

		_mm_sfence();
	} else {
		for (; idx + SIMD_BATCH_SIZE <= count; idx += SIMD_BATCH_SIZE) {
			__m256 v = _mm256_loadu_ps(&src[idx]);
			__m128i h = _mm256_cvtps_ph(v, F16C_ROUND_MODE);
			_mm_storeu_si128((__m128i*)&dst[idx], h);
		}
	}
#endif

	for (; idx < count; ++idx) {
		dst[idx] = float_to_half_intrinsic(src[idx]);
	}
}

#else // Software fallback

void convert_float_to_half_simd(const float* src, uint16_t* dst, size_t count)
{
	convert_float_to_half_scalar(src, dst, count);
}

#endif

// --- Fast Radiance HDR Parser & Direct FP16 Decoder ---

static const char* hdr_get_line(const uint8_t** p_ptr, const uint8_t* end, char* buffer, size_t max_buf)
{
	const uint8_t* ptr = *p_ptr;
	size_t i = 0;
	while (ptr < end && *ptr != '\n') {
		if (i + 1 < max_buf) {
			buffer[i++] = (char)*ptr;
		}
		ptr++;
	}
	if (ptr < end && *ptr == '\n') ptr++;
	buffer[i] = '\0';
	*p_ptr = ptr;
	return buffer;
}

int fast_hdr_get_dimensions(const uint8_t* data, size_t size, int* out_w, int* out_h)
{
	if (!data || size < 16) return 0;

	// Check magic
	if (memcmp(data, "#?RADIANCE", 10) != 0 && memcmp(data, "#?RGBE", 6) != 0) {
		return 0;
	}

	const uint8_t* ptr = data;
	const uint8_t* end = data + size;
	char line[256];

	// Skip header until empty line
	while (ptr < end) {
		hdr_get_line(&ptr, end, line, sizeof(line));
		if (line[0] == '\0' || (line[0] == '\r' && line[1] == '\0')) {
			break;
		}
	}

	// Read resolution line (e.g. "-Y 2048 +X 4096")
	if (ptr >= end) return 0;
	hdr_get_line(&ptr, end, line, sizeof(line));

	int h = 0, w = 0;
	const char* y_pos = strstr(line, "-Y ");
	if (!y_pos) y_pos = strstr(line, "+Y ");
	const char* x_pos = strstr(line, "+X ");
	if (!x_pos) x_pos = strstr(line, "-X ");

	if (y_pos && x_pos) {
		h = (int)strtol(y_pos + 3, NULL, 10);
		w = (int)strtol(x_pos + 3, NULL, 10);
	}

	if (w > 0 && h > 0) {
		if (out_w) *out_w = w;
		if (out_h) *out_h = h;
		return 1;
	}

	return 0;
}

int fast_hdr_decode_fp16(const uint8_t* data, size_t size, int* out_w, int* out_h, uint16_t* out_fp16, size_t max_elements, int flip_y)
{
	init_exp_table();

	if (!data || size < 16 || !out_fp16) return 0;

	const uint8_t* ptr = data;
	const uint8_t* end = data + size;
	char line[256];

	// Check magic
	if (memcmp(data, "#?RADIANCE", 10) != 0 && memcmp(data, "#?RGBE", 6) != 0) {
		return 0;
	}

	// Parse header
	while (ptr < end) {
		hdr_get_line(&ptr, end, line, sizeof(line));
		if (line[0] == '\0' || (line[0] == '\r' && line[1] == '\0')) {
			break;
		}
	}

	if (ptr >= end) return 0;
	hdr_get_line(&ptr, end, line, sizeof(line));

	int w = 0, h = 0;
	const char* y_pos = strstr(line, "-Y ");
	if (!y_pos) y_pos = strstr(line, "+Y ");
	const char* x_pos = strstr(line, "+X ");
	if (!x_pos) x_pos = strstr(line, "-X ");

	if (y_pos && x_pos) {
		h = (int)strtol(y_pos + 3, NULL, 10);
		w = (int)strtol(x_pos + 3, NULL, 10);
	}

	if (w <= 0 || h <= 0) return 0;
	if (out_w) *out_w = w;
	size_t total_elements = (size_t)w * (size_t)h * 4;
	if (total_elements > max_elements) return 0;
	if (w < 8 || w > 8192) return 0;

	return fast_hdr_decode_fp16_threaded(data, size, out_w, out_h, out_fp16, max_elements, flip_y, 1);
}

typedef struct {
	int w;
	int h;
	int start_y;
	int end_y;
	const uint8_t* const* scanline_ptrs;
	const uint8_t* data_end;
	uint16_t* out_fp16;
	int flip_y;
	int success;
} Hdr_Slice_Task;

static void decode_scanline_slice(int w, int h, int start_y, int end_y,
                                 const uint8_t* const* scanline_ptrs,
                                 const uint8_t* end,
                                 uint16_t* out_fp16, int flip_y,
                                 int* p_success)
{
	uint8_t scanline_r[8192];
	uint8_t scanline_g[8192];
	uint8_t scanline_b[8192];
	uint8_t scanline_e[8192];
	uint8_t* scanline_channels[4] = { scanline_r, scanline_g, scanline_b, scanline_e };
	const uint16_t half_one = 0x3C00;

	for (int y = start_y; y < end_y; ++y) {
		const uint8_t* ptr = scanline_ptrs[y];
		if (!ptr || ptr + 4 > end) { *p_success = 0; return; }

		if (ptr[0] != 2 || ptr[1] != 2 || (ptr[2] & 128) != 0) {
			*p_success = 0; return;
		}

		int line_w = ((int)ptr[2] << 8) | (int)ptr[3];
		if (line_w != w) { *p_success = 0; return; }
		ptr += 4;

		for (int c = 0; c < 4; ++c) {
			uint8_t* chan = scanline_channels[c];
			int x = 0;
			while (x < w && ptr < end) {
				uint8_t count = *ptr++;
				if (count > 128) {
					int run = count - 128;
					if (x + run > w || ptr >= end) { *p_success = 0; return; }
					uint8_t val = *ptr++;
					memset(chan + x, val, (size_t)run);
					x += run;
				} else {
					int run = count;
					if (x + run > w || ptr + run > end) { *p_success = 0; return; }
					memcpy(chan + x, ptr, (size_t)run);
					ptr += run;
					x += run;
				}
			}
			if (x != w) { *p_success = 0; return; }
		}

		int dst_y = flip_y ? (h - 1 - y) : y;
		uint16_t* dst_row = out_fp16 + (size_t)dst_y * (size_t)w * 4;

#if defined(__AVX2__) && defined(__F16C__)
		int x = 0;
		for (; x + 8 <= w; x += 8) {
			float f_rgba[32];
			for (int i = 0; i < 8; ++i) {
				uint8_t e = scanline_e[x + i];
				float scale = s_exp_table[e];
				f_rgba[i * 4 + 0] = (float)scanline_r[x + i] * scale;
				f_rgba[i * 4 + 1] = (float)scanline_g[x + i] * scale;
				f_rgba[i * 4 + 2] = (float)scanline_b[x + i] * scale;
				f_rgba[i * 4 + 3] = 1.0f;
			}

			__m256 v0 = _mm256_loadu_ps(&f_rgba[0]);
			__m256 v1 = _mm256_loadu_ps(&f_rgba[8]);
			__m256 v2 = _mm256_loadu_ps(&f_rgba[16]);
			__m256 v3 = _mm256_loadu_ps(&f_rgba[24]);

			__m128i h0 = _mm256_cvtps_ph(v0, F16C_ROUND_MODE);
			__m128i h1 = _mm256_cvtps_ph(v1, F16C_ROUND_MODE);
			__m128i h2 = _mm256_cvtps_ph(v2, F16C_ROUND_MODE);
			__m128i h3 = _mm256_cvtps_ph(v3, F16C_ROUND_MODE);

			_mm_stream_si128((__m128i*)&dst_row[(x + 0) * 4], h0);
			_mm_stream_si128((__m128i*)&dst_row[(x + 2) * 4], h1);
			_mm_stream_si128((__m128i*)&dst_row[(x + 4) * 4], h2);
			_mm_stream_si128((__m128i*)&dst_row[(x + 6) * 4], h3);
		}

		for (; x < w; ++x) {
			uint8_t e = scanline_e[x];
			float scale = s_exp_table[e];
			float r = (float)scanline_r[x] * scale;
			float g = (float)scanline_g[x] * scale;
			float b = (float)scanline_b[x] * scale;

			dst_row[x * 4 + 0] = float_to_half_intrinsic(r);
			dst_row[x * 4 + 1] = float_to_half_intrinsic(g);
			dst_row[x * 4 + 2] = float_to_half_intrinsic(b);
			dst_row[x * 4 + 3] = half_one;
		}
#else
		for (int x = 0; x < w; ++x) {
			uint8_t e = scanline_e[x];
			float scale = s_exp_table[e];
			float r = (float)scanline_r[x] * scale;
			float g = (float)scanline_g[x] * scale;
			float b = (float)scanline_b[x] * scale;

			dst_row[x * 4 + 0] = float_to_half_scalar_impl(r);
			dst_row[x * 4 + 1] = float_to_half_scalar_impl(g);
			dst_row[x * 4 + 2] = float_to_half_scalar_impl(b);
			dst_row[x * 4 + 3] = half_one;
		}
#endif
	}

	*p_success = 1;
}

static void* hdr_slice_worker(void* arg)
{
	Hdr_Slice_Task* task = (Hdr_Slice_Task*)arg;
	decode_scanline_slice(task->w, task->h, task->start_y, task->end_y,
	                      task->scanline_ptrs, task->data_end,
	                      task->out_fp16, task->flip_y,
	                      &task->success);
	return NULL;
}

int fast_hdr_decode_fp16_threaded(const uint8_t* data, size_t size, int* out_w, int* out_h, uint16_t* out_fp16, size_t max_elements, int flip_y, int num_threads)
{
	init_exp_table();

	if (!data || size < 16 || !out_fp16) return 0;

	const uint8_t* ptr = data;
	const uint8_t* end = data + size;
	char line[256];

	// Check magic
	if (memcmp(data, "#?RADIANCE", 10) != 0 && memcmp(data, "#?RGBE", 6) != 0) {
		return 0;
	}

	// Parse header
	while (ptr < end) {
		hdr_get_line(&ptr, end, line, sizeof(line));
		if (line[0] == '\0' || (line[0] == '\r' && line[1] == '\0')) {
			break;
		}
	}

	if (ptr >= end) return 0;
	hdr_get_line(&ptr, end, line, sizeof(line));

	int w = 0, h = 0;
	const char* y_pos = strstr(line, "-Y ");
	if (!y_pos) y_pos = strstr(line, "+Y ");
	const char* x_pos = strstr(line, "+X ");
	if (!x_pos) x_pos = strstr(line, "-X ");

	if (y_pos && x_pos) {
		h = (int)strtol(y_pos + 3, NULL, 10);
		w = (int)strtol(x_pos + 3, NULL, 10);
	}

	if (w <= 0 || h <= 0) return 0;
	if (out_w) *out_w = w;
	if (out_h) *out_h = h;

	size_t total_elements = (size_t)w * (size_t)h * 4;
	if (total_elements > max_elements) return 0;
	if (w < 8 || w > 8192) return 0;

	// Fast indexing pass (find start of each scanline)
	const uint8_t** scanline_ptrs = (const uint8_t**)malloc((size_t)h * sizeof(const uint8_t*));
	if (!scanline_ptrs) return 0;

	const uint8_t* scan_ptr = ptr;
	for (int y = 0; y < h; ++y) {
		if (scan_ptr + 4 > end) { free(scanline_ptrs); return 0; }
		if (scan_ptr[0] != 2 || scan_ptr[1] != 2 || (scan_ptr[2] & 128) != 0) {
			free(scanline_ptrs); return 0;
		}
		int line_w = ((int)scan_ptr[2] << 8) | (int)scan_ptr[3];
		if (line_w != w) { free(scanline_ptrs); return 0; }
		scanline_ptrs[y] = scan_ptr;
		scan_ptr += 4;
		for (int c = 0; c < 4; ++c) {
			int x = 0;
			while (x < w && scan_ptr < end) {
				uint8_t count = *scan_ptr++;
				if (count > 128) {
					x += (count - 128);
					if (scan_ptr < end) scan_ptr++;
				} else {
					x += count;
					scan_ptr += count;
				}
			}
			if (x != w) { free(scanline_ptrs); return 0; }
		}
	}

	if (num_threads <= 1 || h < 64) {
		int success = 0;
		decode_scanline_slice(w, h, 0, h, scanline_ptrs, end, out_fp16, flip_y, &success);
#if defined(__AVX2__) && defined(__F16C__)
		_mm_sfence();
#endif
		free(scanline_ptrs);
		return success;
	}

	if (num_threads > 32) num_threads = 32;
	if (num_threads > h) num_threads = h;

	pthread_t threads[32];
	Hdr_Slice_Task tasks[32];
	int rows_per_thread = h / num_threads;
	int actual_threads = 0;

	for (int i = 0; i < num_threads; ++i) {
		tasks[i].w = w;
		tasks[i].h = h;
		tasks[i].start_y = i * rows_per_thread;
		tasks[i].end_y = (i == num_threads - 1) ? h : (i + 1) * rows_per_thread;
		tasks[i].scanline_ptrs = scanline_ptrs;
		tasks[i].data_end = end;
		tasks[i].out_fp16 = out_fp16;
		tasks[i].flip_y = flip_y;
		tasks[i].success = 0;

		if (pthread_create(&threads[i], NULL, hdr_slice_worker, &tasks[i]) == 0) {
			actual_threads++;
		} else {
			// Run inline on failure
			hdr_slice_worker(&tasks[i]);
		}
	}

	int all_success = 1;
	for (int i = 0; i < actual_threads; ++i) {
		pthread_join(threads[i], NULL);
		if (!tasks[i].success) all_success = 0;
	}

#if defined(__AVX2__) && defined(__F16C__)
	_mm_sfence();
#endif

	free(scanline_ptrs);
	return all_success;
}
