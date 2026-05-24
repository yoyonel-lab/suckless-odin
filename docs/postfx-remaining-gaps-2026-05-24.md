# PostFX Remaining Gaps — suckless-ogl → suckless-odin

**Date**: 2026-05-24
**Branch**: `feat/postfx-pipeline`
**Status**: Port ~98% complete — all shader effects functional

## Porting Summary

All 15 post-processing effects from the legacy C11 pipeline have been successfully
ported to idiomatic Odin with full shader, GUI, preset, and session persistence
support:

| Effect | Shader | Code | GUI | Presets | Session |
|--------|:------:|:----:|:---:|:-------:|:-------:|
| Vignette | ✅ | ✅ | ✅ | ✅ | ✅ |
| Film Grain (tri-zone) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Exposure | ✅ | ✅ | ✅ | ✅ | ✅ |
| Chromatic Aberration | ✅ | ✅ | ✅ | ✅ | ✅ |
| White Balance + Color Grading | ✅ | ✅ | ✅ | ✅ | ✅ |
| Tonemapping (ACES) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Bloom (prefilter + 5-mip chain) | ✅ | ✅ | ✅ | ✅ | ✅ |
| FXAA (+ dedicated pre-pass) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Depth of Field (gather-based) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auto-Exposure (compute) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Motion Blur (tile-max compute) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Banding (5 artistic modes) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fog (IQ analytical height) | ✅ | ✅ | ✅ | ✅ | ✅ |
| LUT 3D (.cube loader) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Luminance Stops (debug) | ✅ | ✅ | ✅ | — | ✅ |

All 15/15 presets ported (including banding/fog/LUT-dependent ones).

## Remaining Gaps (2 items)

### 1. Camera Profile System (Priority: Low)

**Legacy behavior**: 4 camera profiles (Sony α7S III, Fujifilm X-T4, Leica M11,
Canon C70) bundled:

- Specific film grain characteristics (size, intensity per zone)
- Tone mapping curve tuning (slope/toe/shoulder per profile)
- Color grading + white balance presets
- LUT selection (e.g., S-Cinetone for Sony)
- Bokeh/DoF params (anamorphic stretch ratio)
- Runtime cycling via `F8` keybind

**Current state**: Not started. In practice, camera profiles are "super-presets"
that group existing effect parameters — no new GPU code is required.

**Effort estimate**: Small — define 4 preset bundles + keybind handler.

**Implementation path**:

1. Add `Camera_Profile` enum (Sony/Fujifilm/Leica/Canon)
2. Map each profile to a `Preset` with curated values
3. Add `F8` keybind in input handler to cycle profiles
4. GUI indicator showing active profile name
5. Session persistence for active profile

### 2. LUT Gallery Hotkey Cycling (Priority: Low)

**Legacy behavior**: Dedicated keybind to cycle through available `.cube` LUT
files without opening the GUI picker.

**Current state**: LUT selection works via ImGui file picker dropdown. The full
gallery of 7 LUT assets is loaded and functional. Missing only the keyboard
shortcut for rapid cycling.

**Effort estimate**: Trivial — single keybind + index increment.

**Implementation path**:

1. Add `F9` (or configurable) keybind in input handler
2. Cycle `lut3d.current_index` through loaded LUT list
3. Toast/overlay showing active LUT name on switch

## Improvements Over Legacy

The Odin port includes several architectural improvements not present in the
original C11 implementation:

- **Fog-aware bloom prefilter** — fogged objects no longer generate bloom halos
- **FXAA pre-pass before motion blur** — prevents MB from amplifying AA edges
- **Per-effect A/B split** — independent split position per effect (legacy had global only)
- **Colored split indicators** — Glasbey-derived unique colors per effect
- **Single-pass auto-exposure** — one compute dispatch vs legacy's 3-pass reduce
- **Shader variant cache** — compile-time `#define` specialization, no runtime branching
- **GPU timers per pass** — double-buffered `GL_TIME_ELAPSED` queries
- **Luminance stops visualization** — Filament-style 16-stop color-coded debug view
- **`@header` include system** — recursive shader include preprocessor (ported from legacy)

## Conclusion

The post-FX pipeline port is functionally complete. The 2 remaining gaps are UX
conveniences (keybinds for profile/LUT cycling) that require zero new GPU code.
They can be addressed in a follow-up feature branch if desired.
