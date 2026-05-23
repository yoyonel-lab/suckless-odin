# GUI Session Persistence & ImGui Tab Restore

**Date:** 2026-05-21
**Branch:** `feat/postfx-pipeline`

---

## Context

The `session.json` save/restore system existed but was incomplete — several Scene tab parameters and the active GUI tab were not persisted across runs.

## Missing Fields Added to `Session_State`

| Field | Type | Purpose |
|-------|------|---------|
| `skybox_blur_lod` | `f32` | Skybox blur level (slider in Scene tab) |
| `sort_mode` | `i32` | Billboard sort algorithm (None/CPU/Radix) |
| `gui_active_tab` | `i32` | Active tab index in Engine Controls window |
| `perf_mode_active` | `bool` | Performance mode enabled state (added 2026-05-23) |
| `debug_split` | `u32` | A/B split bitfield — which effects have split active (added 2026-05-23) |
| `split_positions` | `[24]f32` | Per-effect split slider positions (added 2026-05-23) |

## ImGui Tab Restore — Lessons Learned

Restoring the active tab in a Dear ImGui `BeginTabBar`/`BeginTabItem` loop is **non-trivial** due to ImGui's deferred internal state management.

### The Problem (3 layers)

1. **`SetSelected` is deferred**: The `TabItemFlags{.SetSelected}` flag sets `NextSelectedTabId` internally, which only takes effect on the NEXT frame's `BeginTabBar` call — not immediately.

2. **Tab bar initialization**: On the very first frame a tab bar is rendered, ImGui creates internal state and defaults to the first submitted tab. `SetSelected` is queued but hasn't propagated yet.

3. **First-tab-wins race condition**: On the current frame, `BeginTabItem("Camera")` returns `true` (it's the default first tab). If you naively write `g.active_tab = 0` inside its block, you overwrite the restore target index. Next frame, `tab_flags` checks `g.active_tab == target_idx` — but `active_tab` is now 0, not the saved value.

### The Fix

```
active_tab:   i32   // Persisted tab index
restore_tab:  i32   // Frame counter (set to 3 on restore)
```

While `restore_tab > 0`:
- Apply `{.SetSelected}` flag to the tab matching `active_tab`
- **Do NOT update** `active_tab` from `BeginTabItem` results (guard: `if !restoring`)
- Decrement counter each frame

The 3-frame window guarantees `SetSelected` propagates through ImGui's deferred selection pipeline regardless of when the tab bar's internal state is first created.

### Key Insight

ImGui's tab selection is a **2-frame pipeline**: frame N sets `NextSelectedTabId`, frame N+1 applies it. Combined with the initialization frame, you need at least 3 frames of `SetSelected` without overwriting the target to reliably restore a tab.

---

## Skybox Rendering Modes — Trade-off Analysis

**Date:** 2026-05-21

The skybox now supports two rendering modes (GUI toggle + session-persisted):

### Mode 1: Equirectangular + Bicubic Filtering (default)

- **Shader:** `background.frag` — Catmull-Rom 4-tap bicubic filtering (`textureBicubicLod`) when `blur_lod > 0`
- **Artifacts:** Pole singularities (pinching at top/bottom of sphere parameterization)
- **Mitigation:** Bicubic filtering smooths the pole discontinuity significantly at higher blur LODs
- **Verdict:** ✅ Good enough for production — poles are rarely in view, bicubic makes them organic

### Mode 2: Cubemap (experimental alternative)

- **Shader:** `background_cubemap.frag` — `textureLod(samplerCube, dir, blur_lod)`
- **Conversion:** `equirect_to_cubemap.{vert,frag}` renders 6 faces at 1024×1024 via FBO
- **Artifacts:** Visible seams at cubemap face boundaries, especially at higher mip levels
- **Root cause:** `glGenerateMipmap(GL_TEXTURE_CUBE_MAP)` generates mipmaps **per-face independently** without cross-face filtering. `GL_TEXTURE_CUBE_MAP_SEAMLESS` only fixes hardware filtering at render time, NOT mipmap generation.
- **Seam Fix:** Castaño stretch edge fixup (toggle via GUI checkbox "Cubemap Seam Fix")

### Cubemap Seam Fix Techniques (Industry Reference)

Three documented techniques exist to mitigate cubemap face seams. **None are runtime-only standalone fixes** — all require either offline texture pre-processing or coupled generation+sampling steps.

#### 1. Stretch Edge Fixup (Ignacio Castaño, NVTT) — ❌ NOT VIABLE STANDALONE

- **Principle:** TWO coupled steps: (1) Generate texture faces with stretched/extended edge texels, then (2) at runtime, contract the direction vector's non-dominant components toward the face center
- **Critical constraint:** Step 2 (runtime contraction) WITHOUT step 1 (pre-stretched textures) produces WORSE artifacts — visible rectangular gaps at face boundaries
- **Tested:** Implemented and tested in this project; confirmed worse than no fix
- **Reference:** NVTT source (`CubeSurface.cpp`), Lagarde AMD CubemapGen article

#### 2. Warp Edge Fixup (NVTT)

- **Principle:** Cubic distortion of texel coordinates at generation time: `u' = a * u³ + u` where `a = size² / (size-1)³`
- **Applied:** During cubemap face generation (offline only)
- **Requirement:** Custom mipmap generation pipeline with cross-face awareness
- **Reference:** NVTT source, Lagarde recommends as default starting method

#### 3. Bent Edge Fixup (Tri-Ace, CEDEC 2011)

- **Principle:** Slerp the texel direction vector away from the face normal, proportional to distance from center
- **Applied:** During cubemap face generation (offline only)
- **Reference:** Tri-Ace CEDEC 2011 presentation

#### 4. Hardware: `GL_TEXTURE_CUBE_MAP_SEAMLESS`

- **Principle:** Cross-face bilinear/trilinear filtering at GPU hardware level
- **Limitation:** Does NOT affect `glGenerateMipmap` — only fixes filtering at sample boundaries
- **Status:** Enabled in our pipeline (`skybox_create`) — helps at low blur but insufficient at high mips

### Conclusion

| | Equirect+Bicubic | Cubemap |
|---|---|---|
| Artifact type | Pole pinching | Face edge seams |
| Severity | Low (softened by bicubic) | Medium (sharp discontinuities) |
| Runtime fix available | N/A (already mitigated) | **None** — all fixes require offline pre-processing |
| Recommendation | **Primary mode** | Optional/experimental |

**Key insight:** There is no purely runtime shader fix for cubemap mipmap seams. All documented techniques (Stretch, Warp, Bent) require offline texture generation with cross-face awareness. The standard OpenGL `glGenerateMipmap` operates per-face independently, and `GL_TEXTURE_CUBE_MAP_SEAMLESS` only helps at the bilinear filtering stage, not at mip generation. For a realtime-only pipeline using `glGenerateMipmap`, the equirectangular+bicubic approach remains superior.
