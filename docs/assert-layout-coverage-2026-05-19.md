# Compile-Time Layout Assert Strategy — Coverage Analysis

**Date**: 2026-05-19  
**Scope**: `src/rendering/types/types.odin` (Sphere_Instance) + `src/rendering/postfx/types.odin` (Post_FX_UBO)

## Strategy

Odin `#assert` with `size_of` and `offset_of` provides **compile-time** verification that struct memory layout matches the corresponding GLSL declaration. The struct is the single source on the Odin side; the asserts act as a safety net against accidental drift.

Two complementary guards:

1. **`size_of(T) == N`** — total size invariant
2. **`offset_of(T, field) == N`** — section boundary anchors

Together they partition the struct into **sections** delimited by checkpoints. Any mutation that changes the size of the struct or shifts a checkpoint field is caught at compile time.

---

## Error Classification

### Detected (compile fails immediately)

| Error Type | Caught By | Example |
|---|---|---|
| Field added | `size_of` | New `emission: f32` inserted → size ≠ expected |
| Field removed | `size_of` | Remove `ao: f32` → size shrinks |
| Type widened/narrowed | `size_of` + `offset_of` | `f32` → `f64` shifts everything after |
| Padding removed | `size_of` + `offset_of` | Delete `_: f32` → downstream offsets shift |
| Padding added incorrectly | `size_of` | Extra `_: [2]f32` → size grows |
| Field inserted before checkpoint | `offset_of` | Insert field before `albedo` → offset ≠ 64 |
| Field reorder across section boundary | `offset_of` | Move `ao` below `prev_center` → offsets shift |
| Array size changed | `size_of` + `offset_of` | `[3]f32` → `[4]f32` in padding |

### NOT Detected (silent — compiles fine but GPU reads wrong data)

| Error Type | Why Missed | Example |
|---|---|---|
| Swap of same-typed fields within a section | Same sizes → offsets unchanged | Swap `metallic` ↔ `roughness` (both `f32`, same section) |
| Two compensating mutations | Net size unchanged, checkpoints unmoved | Add one `f32`, remove another in same section |
| Semantic type mismatch (same size) | Odin doesn't encode GPU semantics | Replace `metallic: f32` with `emissive: f32` (same offset, wrong meaning) |
| Field renamed without layout change | Rename is invisible to `offset_of` | Rename `ao` → `occlusion` (layout identical) |

---

## Per-Struct Coverage

### `Sphere_Instance` (128B, std430, 3 asserts)

```
Checkpoint 0: size_of == 128
Checkpoint 1: offset_of(albedo) == 64
Checkpoint 2: offset_of(prev_center) == 92
```

**Section map:**

| Section | Byte Range | Fields | Internal Swap Risk |
|---|---|---|---|
| A | 0–63 | `model` (Mat4, 64B) | **None** — single field |
| B | 64–91 | `albedo` (Vec3), `metallic`, `roughness`, `ao`, `_` | **Medium** — 4 adjacent `f32` fields interchangeable |
| C | 92–127 | `prev_center` (Vec3) + trailing alignment | **None** — single field + implicit padding |

**Escape set**: swap any pair among `{metallic, roughness, ao, _}` within section B.

**Fix to reach 100%**: add `offset_of(Sphere_Instance, roughness) == 80` — splits section B into two sub-sections of 1-2 fields each, eliminating all same-type swap ambiguity.

### `Post_FX_UBO` (512B since 2026-05-20, was 240B at time of writing, std140)

> **Note:** This analysis was written when the UBO was 240B with 13 asserts.
> The UBO has since grown to 512B with additional sections (motion blur, banding,
> luminance stops, A/B split). The methodology below remains valid; the coverage
> numbers are for the original 240B subset only.

```
Checkpoint 0:  size_of == 240  (now 512)
Checkpoint 1:  offset_of(active_effects)     == 0
Checkpoint 2:  offset_of(vignette_intensity)  == 16
Checkpoint 3:  offset_of(grain_intensity)     == 32
Checkpoint 4:  offset_of(exposure_manual)     == 64
Checkpoint 5:  offset_of(chrom_abbr_strength) == 80
Checkpoint 6:  offset_of(wb_temperature)      == 96
Checkpoint 7:  offset_of(grading_saturation)  == 112
Checkpoint 8:  offset_of(tonemap_slope)       == 144
Checkpoint 9:  offset_of(bloom_intensity)     == 176
Checkpoint 10: offset_of(fxaa_subpix)         == 192
Checkpoint 11: offset_of(dof_focal_distance)  == 208
Checkpoint 12: offset_of(z_near)              == 224
```

**Section map:**

| Section | Byte Range | Size | Named Fields | Max internal swap pairs |
|---|---|---|---|---|
| Header | 0–15 | 16B | `active_effects`, `time`, `screen_texel_size` | 1 (`time` ↔ `screen_texel_size[0]`) — unlikely, different semantics |
| Vignette | 16–31 | 16B | `intensity`, `smoothness`, `roundness`, `_` | 3 pairs among 3 f32 |
| Grain | 32–63 | 32B | 7 named + 1 pad | 21 pairs among 7 f32 |
| Exposure | 64–79 | 16B | `exposure_manual`, `_[3]` | 0 (1 named field) |
| ChromAbbr | 80–95 | 16B | `chrom_abbr_strength`, `_[3]` | 0 (1 named field) |
| WhiteBalance | 96–111 | 16B | `wb_temperature`, `wb_tint`, `_[2]` | 1 pair |
| ColorGrading | 112–143 | 32B | 6 named + `_[2]` | 15 pairs among 6 f32 |
| Tonemap | 144–175 | 32B | 5 named + `_[3]` | 10 pairs among 5 f32 |
| Bloom | 176–191 | 16B | 4 named | 6 pairs among 4 f32 |
| FXAA | 192–207 | 16B | 3 named + `_` | 3 pairs among 3 f32 |
| DoF | 208–223 | 16B | 4 named | 6 pairs among 4 f32 |
| Camera | 224–239 | 16B | `z_near`, `z_far`, `_[2]` | 1 pair |

**Escape set**: any same-type swap within a section. The **Grain** (7 fields) and **ColorGrading** (6 fields) sections have the largest unguarded internal reorder space.

**Mitigation factors:**
- Field names match GLSL names → swap requires ignoring an obvious naming discrepancy
- Most sections have ≤ 4 named fields → limited combinatorial risk
- The dangerous sections (Grain, Tonemap, ColorGrading) could be tightened by adding 1 mid-section `offset_of` each

---

## Theoretical Coverage Metric

For a struct with `F` named fields and `C` offset_of checkpoints:

- **Perfect coverage**: `C = F` (every field anchored) → 0 undetected swaps
- **Current coverage**: detects any mutation that crosses a checkpoint boundary
- **Undetected permutations per section of N fields**: `N! - 1` (all permutations except identity)

| Struct | Named Fields | Checkpoints | Largest Unguarded Section | Undetected Perms in That Section |
|---|---|---|---|---|
| Sphere_Instance | 7 | 2 | 4 fields (section B) | 23 |
| Post_FX_UBO | 39 | 12 | 7 fields (Grain) | 5039 |

In practice, the risk is low because:
1. Field names mirror GLSL — a human would notice a semantic mismatch during editing
2. Tests exercise the rendering pipeline — wrong values produce visible artifacts
3. The asserts catch the **most common** real-world errors: forgotten padding, added/removed fields, struct reorganization

---

## Recommendations

| Action | Effort | Impact |
|---|---|---|
| Add `offset_of(Sphere_Instance, roughness) == 80` | 1 line | Closes section B completely |
| Add mid-section assert in Grain (`grain_texel_size == 56`) | 1 line | Cuts Grain escape set from 5039 to ~120 |
| Add mid-section assert in ColorGrading (`grading_lift == 132`) | 1 line | Cuts ColorGrading escape set from 719 to ~24 |
| Full per-field offset_of (nuclear option) | +39 lines for UBO | 0 undetected permutations — but noisy |

The current strategy provides **excellent protection against structural errors** (the common case) with **minimal noise**. The undetected cases require a developer to deliberately swap two identically-typed fields within the same logical group — an unlikely accident that would also produce visible rendering bugs.
