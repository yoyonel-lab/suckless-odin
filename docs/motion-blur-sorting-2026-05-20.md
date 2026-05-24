# Motion Blur & Billboard Sorting — Port Summary

**Date:** 2026-05-20 (updated 2026-05-21)
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

### Synthetic Velocity Injection (Debug Tool)

Eliminates the need to manually move the camera to test motion blur. Injects a constant, uniform velocity across the entire screen by offsetting `prev_view_proj` with an NDC-space translation matrix.

**How it works:**
- User sets direction (0–360°) and magnitude (UV-space, same units as `max_velocity`)
- Each frame, `prev_view_proj = NDC_offset_matrix * current_VP`
- The velocity buffer naturally computes the desired velocity everywhere
- Full pipeline is exercised: velocity generation → tile-max → neighbor-max → sampling

**GUI:** Post-FX tab → Motion Blur → "Synthetic Velocity (Debug)" section. Quick presets for direction (Right/Up/Left/Down) and speed (Slow/Medium/Fast/Max).

**Implementation:** `MB_Debug_Inject` struct on `Pipeline` (not serialized/persisted). Injection logic in `scene_render` after VP computation.

### Debug Views (exclusive selector, `mb_debugMode` in UBO)

| Mode | Name | Description |
|------|------|-------------|
| 0 | Velocity (RG) | Raw `abs(velocity) * 20` as red/green channels |
| 1 | Tile-Max (Heatmap) | Per-tile 16×16 max velocity, blue→red color ramp |
| 2 | Neighbor-Max (Heatmap) | 3×3 dilated tile max, blue→red color ramp |
| 3 | Speed (Heatmap) | Per-pixel velocity magnitude, blue→red color ramp |
| — | Vector Field | SDF arrows on 48px grid, HSV-colored by direction (bit 22) |

**Heatmap ramp:** black → blue → cyan → yellow → red (5-stop gradient, `velocityHeatmap()` in shader).

**Usage pattern:** Enable "Synthetic Velocity" injection + select a debug view to validate each pipeline stage without camera manipulation.

### Parameters (UBO)

| Param | Default | Range | Unit |
|-------|---------|-------|------|
| intensity | 1.0 | 0–3 | multiplier |
| max_velocity | 0.05 | 0.001–0.3 | UV space |
| samples | 8 | 2–32 | taps |
| debug_mode | 0 | 0–3 | see table above |

### Debugging Workflow

1. Enable Motion Blur effect
2. Enable "Synthetic Velocity" injection (direction=0°, magnitude=0.03)
3. Select debug view "Speed (Heatmap)" — verify uniform blue/cyan across moving objects
4. Switch to "Tile-Max (Heatmap)" — verify tiles show consistent color
5. Switch to "Neighbor-Max (Heatmap)" — verify 1-tile dilation around edges
6. Switch to "Off" — observe the actual blur result
7. Adjust magnitude up/down to test clamp behavior at `max_velocity` boundary

### Bug Fixes (2026-05-21)

- **max_velocity unit mismatch**: Preset JSON files stored `40.0` (pixel-space legacy value). Corrected to `0.05` UV-space. The GUI slider range (0.001–0.3) was already correct.
- **mb_debugMode dead code**: The UBO field was declared but never read by the shader. Now properly wired: modes 0–3 select different visualizations.
- **tileMaxTexture sampler missing**: Texture was bound at unit 7 but not declared in shader. Added `layout(binding = 7)` declaration.

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
| 2 | Depth | DEPTH32F |
| 3 | Auto-Exposure | R32F (1×1) |
| 4 | Velocity | RG16F |
| 5 | DoF blur | RGBA16F |
| 6 | Neighbor-Max | RG16F |
| 7 | Tile-Max | RG16F |
| 8 | LUT 3D | RGB16F (3D) |

---

## Known Limitations

- Motion blur is screen-space post-process (McGuire 2012): silhouette bleeding at depth discontinuities is inherent to the technique.
- No per-object alpha/edge-aware blur (legacy has same limitation).
- GPU bitonic sort not ported — only CPU variants available.
- Synthetic velocity injection produces uniform velocity (no perspective variation) — this is intentional for debug but differs from real camera motion.
