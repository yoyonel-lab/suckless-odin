# Motion Blur & Billboard Sorting — Port Summary

**Date:** 2026-05-20
**Branch:** `feat/postfx-pipeline`
**Source:** `suckless-ogl` (C11) → `suckless-odin` (Odin)

---

## Motion Blur

### Architecture (3-pass + uber-shader)

1. **Velocity Buffer** (MRT): `pbr_billboard.frag` outputs per-pixel velocity to `GL_COLOR_ATTACHMENT1` (RG16F). Velocity = difference between current NDC (from raytraced hitPos) and previous NDC (from `u_previousViewProj * prevHitPos`). Background writes `vec2(0.0)`.

2. **Tile-Max Compute** (`tile_max_velocity.comp`): Reduces full-res velocity to per-tile (16×16) maximum velocity vector. Dispatch: one workgroup per tile.

3. **Neighbor-Max Compute** (`neighbor_max_velocity.comp`): 3×3 dilation over tile-max texture. Ensures nearby fast-moving objects contribute to blur of slower neighbors.

4. **Uber-shader Sampling** (`postfx.frag`): `applyMotionBlur()` implements McGuire 2012 reconstruction — adaptive sample count, interleaved gradient noise jitter, soft depth-testing to reduce silhouette bleeding.

### Pipeline Integration

- `getSceneSource(uv)` wraps motion blur: returns blurred color if MB enabled, raw texture otherwise.
- Chromatic Aberration calls `getSceneSource()` internally (ISO legacy).
- `prev_view_proj` stored per-frame, initialized to first frame's VP to avoid flash.

### Debug Views (exclusive selector)

- **Velocity (RG)** — bit 11: `abs(velocity) * 20` red/green visualization
- **Vector Field** — bit 22: SDF arrows on 48px grid, HSV-colored by direction, scene darkened 0.3×

### Parameters (UBO)

| Param | Default | Range | Unit |
|-------|---------|-------|------|
| intensity | 1.0 | 0–3 | multiplier |
| max_velocity | 0.05 | 0.001–0.3 | UV space |
| samples | 8 | 2–32 | taps |

---

## Billboard Sorting (CPU)

### Purpose

Back-to-front (descending depth) sorting for correct rendering order of raymarched billboard spheres. Required for correct motion blur sampling across overlapping instances and proper FXAA edge detection.

### Algorithms

1. **CPU qsort** (`instanced_sort_cpu`): Proxy array of `{index, depth²}`, sorted via `slice.sort_by`, then instance reordering. O(n log n).

2. **CPU Radix** (`instanced_sort_radix`): IEEE 754 float-to-sortable-uint trick, 4 passes of 8-bit counting sort with ping-pong buffers, descending order. O(n), stable.

### Integration

- Called in `scene_update` between `instanced_update_prev_centers` and `instanced_upload`.
- Sort mode selectable at runtime via GUI (None / CPU qsort / CPU Radix).
- GPU bitonic sort variant not ported (compute shader + multiple SSBOs, deferred to future).

---

## Texture Unit Layout

| Unit | Texture | Format |
|------|---------|--------|
| 0 | Scene color | RGBA16F |
| 1 | Bloom | RGBA16F |
| 2 | Depth | DEPTH24 |
| 3 | Auto-Exposure | R32F (1×1) |
| 4 | Velocity | RG16F |
| 5 | DoF blur | RGBA16F |
| 6 | Neighbor-Max | RG16F |
| 7 | Tile-Max | RG16F |
| 8 | LUT 3D | RGB (3D) |

---

## Known Limitations

- Motion blur is screen-space post-process (McGuire 2012): silhouette bleeding at depth discontinuities is inherent to the technique.
- No per-object alpha/edge-aware blur (legacy has same limitation).
- GPU bitonic sort not ported — only CPU variants available.
- Edge factor (analytic billboard AA) not yet ported from legacy.

---

## Skybox Blur Quality (2026-05-21)

### Problem

At high mip levels (LOD 5+), hardware bilinear filtering of equirectangular environment maps produces blocky, starburst-like artifacts at poles. The equirectangular parametrization degenerates at poles (entire top/bottom texel row maps to a single point), and low-res mip levels expose this as a radial star pattern.

### Solution

Replaced single `textureLod` call with **bicubic Catmull-Rom filtering** using 4 hardware bilinear taps (Sigg & Hadwiger 2005, GPU Gems 2). This gives an effective 4×4 kernel with C1 continuity — much smoother transitions at high LODs.

- **Cost:** 4× texture lookups when `blur_lod > 0`, zero cost at LOD 0 (sharp skybox)
- **Pole singularity persists** (it's a parametrization issue, not filtering), but transitions are organic instead of blocky
- A full fix requires converting to cubemap at load time (6 faces, no pole singularity)

### Texture Wrap Mode Fix

`TEXTURE_WRAP_S` was incorrectly set to `CLAMP_TO_EDGE` — should be `REPEAT` for longitude axis (ISO legacy). This caused a visible seam at the equirectangular wrap boundary.

---

## Session Persistence (2026-05-21)

### Missing Fields Added

The `session.json` save/restore system existed but was incomplete:
- `skybox_blur_lod` — was never persisted (reset to 0 on restart)
- `sort_mode` — was never persisted
- `gui_active_tab` — active GUI tab was never persisted

### ImGui Tab Restore — Lessons Learned

Restoring the active tab in a Dear ImGui `BeginTabBar`/`BeginTabItem` loop is non-trivial:

1. **`SetSelected` is deferred**: The flag sets `NextSelectedTabId` internally, which only takes effect on the NEXT frame's `BeginTabBar` call.

2. **First-tab-wins race condition**: On the current frame, `BeginTabItem` returns `true` for the default first tab. If you naively set `active_tab = current_tab_index` inside each `BeginTabItem` block, you overwrite the target index before the deferred selection takes effect.

3. **Fix**: Use a frame counter (`restore_tab: i32`, set to 3 on restore). While `restore_tab > 0`:
   - Apply `{.SetSelected}` flag to the target tab index
   - Do NOT update `active_tab` from `BeginTabItem` results (guard with `if !restoring`)
   - Decrement counter each frame

This 3-frame window guarantees `SetSelected` has time to propagate through ImGui's deferred tab selection pipeline.
