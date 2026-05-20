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
