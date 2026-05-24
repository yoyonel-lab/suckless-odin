#ifndef TRACY_GPU_H
#define TRACY_GPU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef TRACY_ENABLE

/** @brief Initialize the Tracy GPU context. Must be called after OpenGL context
 * creation. */
void tracy_gpu_init(void);

/** @brief Collect GPU profiling events. Usually called before or after swap
 * buffers. */
void tracy_gpu_collect(void);

/** @brief Take a screenshot of the current frame. */
void tracy_gpu_screenshot(const void* data, uint16_t w, uint16_t h);

/** @brief Begin a GPU zone in Tracy. Returns a context handle. */
void* tracy_gpu_zone_begin(const char* name, const char* function,
                           const char* file, uint32_t line, uint32_t color);

/** @brief End a GPU zone in Tracy. */
void tracy_gpu_zone_end(void* ctx);

#else

#define tracy_gpu_init() ((void)0)
#define tracy_gpu_collect() ((void)0)
#define tracy_gpu_zone_begin(name, function, file, line, color) (0)
#define tracy_gpu_zone_end(ctx) ((void)0)

#endif

#ifdef __cplusplus
}
#endif

#endif  // TRACY_GPU_H
