# Post-Processing Pipeline Architecture

**Date:** 2026-05-18 (updated 2026-05-22)  
**Status:** Complete (Phase 1–6, debug views, FXAA pre-pass)  
**Scope:** Full-screen post-processing with modular effects, bloom, DoF, auto-exposure, GPU profiling, shader variant cache, and A/B split debug

## Overview

The post-processing pipeline renders the 3D scene into an HDR framebuffer, then applies a chain of full-screen effects via an uber-shader before presenting to screen.

```
Scene Render → HDR FBO (RGBA16F) → Bloom Multi-Pass → DoF Quarter-Res → Auto-Exposure
  → [FXAA Pre-Pass if FXAA+MB] → Mipmap Gen → Composite (uber-shader) → Screen
```

## Package Layout

```
src/rendering/postfx/
├── types.odin          # Effect enum, bit_set flags, param structs, UBO layout
├── pipeline.odin       # Pipeline lifecycle (create/destroy/begin/end/resize)
├── bloom.odin          # Multi-pass bloom (5-mip downsample/upsample)
├── dof.odin            # Depth of Field (quarter-res blur + CoC mix)
├── auto_exposure.odin  # Compute luminance → adaptive exposure
├── presets.odin        # 15 named configurations + WIP table
├── gpu_timers.odin     # Double-buffered GL_TIME_ELAPSED queries (4 passes)
├── fxaa_prepass.odin   # FXAA pre-pass FBO/texture/shader (when FXAA+MB)
└── shader_cache.odin   # Compile-time optimized shader variants

shaders/postfx/
├── postfx.vert         # Fullscreen quad vertex shader
├── postfx.frag         # Uber-shader (all effects, #ifdef STATIC_* support)
├── fxaa_prepass.frag      # Standalone FXAA 3.11 (pre-pass before MB)
├── bloom_prefilter.frag   # UE4 quadratic threshold curve
├── bloom_downsample.frag  # 13-tap Jimenez (CoD:AW)
└── bloom_upsample.frag    # 9-tap tent filter
```

## Effect Pipeline

Effects are applied in this order inside `postfx.frag`:

1. **Chromatic Aberration** — Radial R/B channel offset
2. **FXAA** — FXAA 3.11 (5-step quality, runs on LDR-approximated luma)
3. **Depth of Field** — CoC from depth buffer, quarter-res blur mix
4. **Bloom** — Additive blend of bloom texture (multi-pass computed separately)
5. **Exposure** — Manual or Auto-Exposure multiplier
6. **Tonemapping** — UE4 filmic curve (slope, toe, shoulder, clips)
7. **Color Grading** — Saturation, contrast, gamma, gain, offset, lift + white balance
8. **Vignette** — Circular/elliptical darkening
9. **Film Grain** — Hash-based temporal grain with per-zone intensity

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
| DoF | Quarter-res blur pass |
| Auto-Exp | Luminance compute + exposure adaptation |
| Composite | UBO upload + uber-shader draw |
| Total | All passes combined |

Previous frame's results are read each frame (1-frame latency, no pipeline stall).

### UBO Layout (std140)

Single UBO at binding 0, `#packed` struct in Odin maps directly to GLSL `layout(std140)`.

**IMPORTANT**: Never use `float name[N]` arrays for padding in the GLSL block — std140 rounds array stride to 16 bytes per element. Always use individual scalars for padding.

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
| DoF | 16B | focal_distance, focal_range, bokeh_scale, anamorphic_ratio |
| Camera | 16B | z_near, z_far + pad |
| Motion Blur | 16B | intensity, max_velocity, samples + pad |
| Banding | 32B | mode, levels, dither_strength, perceptual_gamma, channel_levels + pad |
| Fog | 112B | density, start, height_falloff, max_opacity, color, cam_pos, inv_view_proj |
| LUT3D | 16B | intensity + pad |
| Debug Split | 16B | debugSplitMask (u32) + pad |

Total: 432 bytes, updated per-frame via `glBufferSubData`.

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

// A/B split-screen debug (left=with effect, right=bypass)
postfx.pipeline_toggle_split(&p, .Vignette)

// Reset single effect to default values
postfx.pipeline_reset_effect(&p, .Bloom)

// Apply named preset
postfx.pipeline_apply_preset(&p, .Cinematic)
```

## Preset System

15 built-in presets defined as compile-time constants:

| Preset | Key Characteristics |
|--------|-------------------|
| Default | All effects, balanced parameters |
| Subtle | Mild vignette + grain, warm WB |
| Cinematic | Strong vignette, low sat, cool WB, bloom |
| Vibrant | High saturation, warm, aggressive bloom |
| Clean | Exposure + tonemap only, no grain/vignette |
| Vintage | Low sat, strong grain, warm tint |
| Matrix | Green tint, high contrast |
| BW_Contrast | Desaturated, high contrast B&W |
| Posterized | **(WIP)** Requires Banding |
| Retro | **(WIP)** Requires Banding |
| Analog | **(WIP)** Requires Banding |
| Channel_GFX | **(WIP)** Requires Banding |
| Blueprint | **(WIP)** Requires Banding |
| Nordic_Noir | **(WIP)** Requires Fog |
| Sony_A7SIII | **(WIP)** Requires LUT3D |

WIP presets are greyed out in GUI (non-selectable) until their dependencies are ported.

Applied via CLI (`--postfx-preset=cinematic`) or GUI dropdown.

## Debug Views & A/B Split

### Per-Effect Debug

- **Bloom Debug**: Shows intensity-weighted bloom texture directly
- **DoF Debug**: Color-coded focus zones (green=focused, blue=far, red=near)
- **FXAA Debug**: Edge detection visualization (red=edge, blue=subpixel, gray=untouched)

Debug toggles live inside each effect's Settings tree in the Post-FX GUI tab.

### A/B Split-Screen

Every implemented effect has an "A/B Split" checkbox:
- Left half: effect applied
- Right half: effect bypassed
- Yellow vertical separator line at center

Split state is cached when an effect is disabled and restored on re-enable.
Applying a preset clears all split/debug state.

## Testing

GL tests in `tests/gl/`:
- Shader compilation (vert + all frag shaders)
- Program linking (composite + bloom passes)
- Variant compilation (all defines, minimal, mixed, empty)
- Uniform validation (sampler locations)
- Full pipeline lifecycle (create, render, destroy)
- Bloom, DoF, auto-exposure multi-pass validation

## Not Yet Ported (see postfx-porting-gap-2026-05-19.md)

- **Motion Blur** (Phase 4): tile-max/neighbor-max compute, velocity buffer
- **Banding** (Phase 2): 5 artistic quantization modes
- **Fog** (Phase 3): exponential height-based atmospheric
- **LUT3D** (Phase 5): .cube file loading, 3D texture

## Skybox Blur Source: IBL Prefilter (2026-05-21)

The skybox blur originally used cubemap mipmap LOD sampling. This produced face-boundary seams at high LODs because:
1. `glGenerateMipmap` does per-face box filtering (edge texels get clamped, not cross-face)
2. A manual "seamless" downsample (via `GL_TEXTURE_CUBE_MAP_SEAMLESS`) produced identical results because modern drivers already use seamless filtering for `glGenerateMipmap`
3. The bilinear cross-face kernel at sample time is too narrow at high LODs to hide accumulated artifacts

**Solution:** Reuse the IBL prefiltered specular map (2D equirect, 2048×1024, 5 mip levels) as an alternative blur source. This map is generated via importance-sampled GGX convolution (compute shader `spmap.glsl`), producing physically-correct blur with no face seams.

### GUI Controls (Scene tab)
- **Blur Source**: `Mipmap LOD` (standard) / `IBL Prefilter` (new)
- **Show Blur Diff**: Debug comparison — amplified difference between standard mip blur and IBL prefilter at the same blur_lod
- **Diff Gain**: Amplification factor (1–100×)

### Implementation
- `Blur_Source` enum added to `Skybox` struct
- When `IBL_Prefilter` selected: equirect shader renders with `ibl.prefilter_map` instead of `env_tex`
- `blur_lod [0..8]` mapped to `prefilter_lod [0..4]` (linear scale to PREFILTER_MIP_LEVELS-1)
- Diff shader: `shaders/background_blur_diff.frag` (compares both 2D equirect sources side-by-side)
