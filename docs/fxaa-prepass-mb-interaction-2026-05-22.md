# FXAA Pre-Pass & Motion Blur Interaction Fix

**Date:** 2026-05-22
**Branch:** `feat/postfx-pipeline`
**Status:** Complete

## Problem

When both FXAA and Motion Blur are active, the uber-shader applies them sequentially:
FXAA runs on the already-blurred image and detects MB gradients as edges, creating
visible halo artifacts along motion trails.

## Solution: Multi-Pass Architecture

Split FXAA into a **pre-pass** that runs before motion blur:

```
Scene → [FXAA Pre-Pass] → Anti-aliased Scene → [Motion Blur] → Composite
```

### New Files

- `shaders/postfx/fxaa_prepass.frag` — Standalone FXAA 3.11 fragment shader
  (5-step quality, identical algorithm to uber-shader but isolated)
- `src/rendering/postfx/fxaa_prepass.odin` — GPU resource management
  (FBO, RGBA16F texture, shader compilation, create/destroy/resize)

### Pipeline Changes (`pipeline.odin`)

1. After bloom/DoF/auto-exposure/MB-compute, run FXAA pre-pass into `fxaa_tex`
2. Choose composite source: `fxaa_tex` (if pre-pass ran) or `scene_color_tex`
3. Generate mipmaps on composite source (for MB LOD sampling)
4. Temporarily clear FXAA bit in UBO so uber-shader skips redundant FXAA
5. Composite pass reads from pre-filtered source
6. Restore FXAA bit + mipmap filter state

### Condition

Pre-pass only activates when **both** `.FXAA` and `.Motion_Blur` are in `active_effects`.
When only FXAA is active (no MB), the uber-shader path remains unchanged.

## Motion Blur Sampling Improvements (`postfx.frag`)

### Adaptive Sample Count

Previously: `actual_samples = speed_ratio * mb_samples` (velocity relative to max).
Now: `actual_samples = pixel_span` (blur extent in pixels). Ensures ≥1 sample/pixel.

### Mipmap LOD Sampling

When step size > 1px, the gather loop undersamples thin features. New behavior:
`mb_lod = log2(step_pixels) + 1.0` — pre-filters source proportionally to step size
(UE4-style). At sub-pixel steps, LOD stays at 0.

### R1 Jitter (Golden Ratio)

Replaced single `InterleavedGradientNoise` with per-sample R1 sequence:
`noise = fract(spatialHash(gl_FragCoord.xy) + i * 0.618...)`.
Eliminates the diagonal banding pattern inherent to IGN when used across samples.

### `spatialHash()` Function

Dave Hoskins hash without structured diagonal pattern. Used as base noise for
the R1 per-sample sequence.

### `textureLod` Migration

All `texture()` calls on `screenTexture` replaced with `textureLod(..., 0.0)` to
prevent implicit mipmap reads from bleeding FXAA pre-pass data into wrong LOD levels.

## Regression Test

`tests/gl/test_gl_motion_blur.odin` — 64 stochastic samples + user repro values:

- **Phase 1**: Full-res (1169×977) with user's exact velocity, always exports PNGs
- **Phase 2**: Half-res (584×488) stochastic sweep, exports only on regression
- **Metrics**: PSNR (≥20dB), gradient variance ratio (≤1.15), edge energy ratio (≤1.10)
- **Runtime**: ~18s, 44 tests, 65/65 pairs pass
- **Fixture**: `tests/gl/fixtures/mb_input_envmap_crop.png` (captured viewport)
