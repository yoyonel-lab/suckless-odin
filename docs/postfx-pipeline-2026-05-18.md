# Post-Processing Pipeline Architecture

**Date:** 2026-05-18  
**Status:** Complete (Phase 1–5)  
**Scope:** Full-screen post-processing with modular effects, bloom, GPU profiling, and shader variant cache

## Overview

The post-processing pipeline renders the 3D scene into an HDR framebuffer, then applies a chain of full-screen effects via an uber-shader before presenting to screen.

```
Scene Render → HDR FBO (RGBA16F) → Bloom Multi-Pass → Composite (uber-shader) → Screen
```

## Package Layout

```
src/rendering/postfx/
├── types.odin          # Effect enum, bit_set flags, param structs, UBO layout
├── pipeline.odin       # Pipeline lifecycle (create/destroy/begin/end/resize)
├── bloom.odin          # Multi-pass bloom (5-mip downsample/upsample)
├── presets.odin        # Named configurations (Default, Subtle, Cinematic, etc.)
├── gpu_timers.odin     # Double-buffered GL_TIME_ELAPSED queries
└── shader_cache.odin   # Compile-time optimized shader variants

shaders/postfx/
├── postfx.vert         # Fullscreen quad vertex shader
├── postfx.frag         # Uber-shader (all effects, #ifdef STATIC_* support)
├── bloom_prefilter.frag   # UE4 quadratic threshold curve
├── bloom_downsample.frag  # 13-tap Jimenez (CoD:AW)
└── bloom_upsample.frag    # 9-tap tent filter
```

## Effect Pipeline

Effects are applied in this order inside `postfx.frag`:

1. **Chromatic Aberration** — Radial R/B channel offset
2. **FXAA** — FXAA 3.11 (5-step quality, runs on LDR-approximated luma)
3. **Bloom** — Additive blend of bloom texture (multi-pass computed separately)
4. **Exposure** — Manual exposure multiplier
5. **Tonemapping** — UE4 filmic curve (slope, toe, shoulder, clips)
6. **Color Grading** — Saturation, contrast, gamma, gain, offset, lift + white balance
7. **Vignette** — Circular/elliptical darkening
8. **Film Grain** — Hash-based temporal grain with per-zone intensity

## Architecture Decisions

### Uber-Shader with Runtime Bitfield

Each effect is gated by a bit in `activeEffects` (uint, UBO binding 0). This allows toggling effects at runtime without shader recompilation:

```glsl
bool enableVignette = (activeEffects & (1u << 0u)) != 0u;
```

### Shader Variant Cache (Optional Optimization)

For known configurations, the shader cache compiles optimized variants with `#define STATIC_*` flags that convert runtime checks to compile-time constants:

```glsl
#ifdef STATIC_VIGNETTE
    bool enableVignette = true;   // dead-code eliminates the branch
#else
    bool enableVignette = (activeEffects & (1u << 0u)) != 0u;
#endif
```

Up to 8 variants cached simultaneously. Cache lookup is O(n) over the active set.

### Bloom: Jimenez 13-tap + Tent Upsample

Multi-pass bloom uses a 5-mip chain (halving resolution at each step):

```
Scene → Prefilter (threshold) → Down[0] → Down[1] → ... → Down[4]
                                  ↑          ↑                 |
                               Up[0] ← Up[1] ← ... ← --------+
```

- **Prefilter**: UE4 soft threshold curve (avoids harsh cutoff)
- **Downsample**: 13-tap weighted average (energy-preserving, reduces shimmer)
- **Upsample**: 9-tap tent filter with additive blending (GL_ONE, GL_ONE)

Internal format: `R11F_G11F_B10F` (HDR, compact, no alpha needed)

### GPU Timer Queries

Double-buffered `GL_TIME_ELAPSED` queries measure per-pass cost without stalling:

| Timer Pass | What it measures |
|-----------|-----------------|
| Bloom | All bloom passes (prefilter + 5 down + 5 up) |
| Composite | UBO upload + uber-shader draw |
| Total | Bloom + Composite combined |

Previous frame's results are read each frame (1-frame latency, no pipeline stall).

### UBO Layout (std140)

Single UBO at binding 0, `#packed` struct in Odin maps directly to GLSL `layout(std140)`:

| Section | Size | Contents |
|---------|------|----------|
| Header | 16B | activeEffects (u32), time (f32), screenTexelSize (vec2) |
| Vignette | 16B | intensity, smoothness, roundness, pad |
| Grain | 32B | 7 parameters + pad |
| Exposure | 16B | manual + pad |
| Chrom. Aberration | 16B | strength + pad |
| White Balance | 16B | temperature, tint + pad |
| Color Grading | 32B | saturation, contrast, gamma, gain, offset, lift + pad |
| Tonemapping | 32B | slope, toe, shoulder, black_clip, white_clip + pad |
| Bloom | 16B | intensity, threshold, soft_threshold, radius |
| FXAA | 16B | subpix, edge_threshold, edge_threshold_min + pad |

Total: 208 bytes, updated per-frame via `glBufferSubData`.

## API Usage

```odin
import postfx "rendering/postfx"

// Create
p: postfx.Pipeline
postfx.pipeline_create(&p, width, height)
defer postfx.pipeline_destroy(&p)

// Each frame:
postfx.pipeline_update(&p, dt)
postfx.pipeline_begin(&p)       // Binds scene FBO
    render_scene()              // Your 3D rendering
postfx.pipeline_end(&p)         // Runs effects, composites to screen

// Toggle effects
postfx.pipeline_toggle(&p, .Bloom)
postfx.pipeline_enable(&p, .Vignette)
postfx.pipeline_disable(&p, .FXAA)

// Apply named preset
postfx.pipeline_apply_preset(&p, .Cinematic)

// Compile optimized variant for current config
p.shader_cache.enabled = true
postfx.pipeline_compile_variant(&p)
```

## Preset System

5 built-in presets defined as compile-time constants:

| Preset | Key Characteristics |
|--------|-------------------|
| Default | All effects, balanced parameters |
| Subtle | Mild vignette + grain, warm WB |
| Cinematic | Strong vignette, low sat, cool WB, bloom |
| Vibrant | High saturation, warm, aggressive bloom |
| Clean | Exposure + tonemap only, no grain/vignette |

Applied via CLI (`--postfx-preset=cinematic`) or GUI dropdown.

## Testing

GL tests in `tests/gl/test_gl_postfx.odin`:
- Shader compilation (vert + all frag shaders)
- Program linking (composite + bloom passes)
- Variant compilation (all defines, minimal, mixed, empty)
- Uniform validation (sampler locations)

## Future (Phase 7–8)

- **Depth of Field**: Bokeh DoF using the existing `depth_tex` attachment
- **Auto-Exposure**: Compute shader histogram → average luminance → exposure feedback
