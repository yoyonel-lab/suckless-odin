# Equirectangular Environment Map — Bicubic Filtering

**Date:** 2026-05-21
**Branch:** `feat/postfx-pipeline`

---

## Problem

At high mip levels (LOD 5+), hardware bilinear filtering of equirectangular environment maps produces blocky, starburst-like artifacts at poles. The equirectangular parametrization degenerates at poles (entire top/bottom texel row maps to a single point), and low-res mip levels expose this as a radial star pattern.

## Solution

Replaced single `textureLod` call with **bicubic Catmull-Rom filtering** using 4 hardware bilinear taps (Sigg & Hadwiger 2005, GPU Gems 2). This gives an effective 4×4 kernel with C1 continuity — much smoother transitions at high LODs.

### Implementation (`shaders/background.frag`)

- `textureBicubicLod(sampler2D, uv, lod)` computes Catmull-Rom weights (w0..w3) for the fractional texel position
- Combines weight pairs (s0 = w0+w1, s1 = w2+w3) and uses bilinear hardware at optimized offsets (f0 = w1/s0, f1 = w3/s1)
- 4 bilinear taps at 2×2 grid positions → effective 4×4 kernel
- Only active when `blur_lod > 0` (sharp skybox at LOD 0 uses standard single tap — zero cost)

### Performance

- **Cost:** 4× texture lookups vs 1× when blur active
- **Acceptable:** skybox is a single full-screen quad, bandwidth-bound not ALU-bound; 4 taps is negligible

### Texture Wrap Mode Fix

`TEXTURE_WRAP_S` was incorrectly set to `CLAMP_TO_EDGE` — should be `REPEAT` for longitude axis (ISO legacy). This caused a visible seam at the 360° equirectangular wrap boundary.

### Remaining Limitations

- **Pole singularity persists** — it's a parametrization issue, not a filtering issue. Bicubic smooths the transitions but the convergence pattern at poles remains at extreme LODs
- A full fix requires converting to cubemap at load time (6 faces, uniform solid angle per texel, no pole singularity)
- Alternative: pre-compute a Gaussian blur in spherical domain at init (expensive, deferred)
