# Glasbey Palette Integration

**Date:** 2026-05-23
**Status:** In progress
**Branch:** `feat/postfx-pipeline`

## Context

The A/B split debug view draws colored vertical lines to indicate which post-effect
owns each screen region. Each effect needs a visually distinct color so the user can
instantly identify overlapping splits.

### Why Glasbey?

Ad-hoc palette selection (hand-picked hues) breaks down past ~8 colors: adjacent
entries become confusable, especially for color-vision-deficient users. The Glasbey
algorithm (Glasbey et al., 2007) solves this by iteratively choosing each successive
color to maximize the minimum perceptual distance (ΔE* in CIELAB) from all
previously chosen colors.

> **Reference:** Glasbey, C., van der Heijden, G., Toh, V.F.K., Gray, A. (2007).
> "Colour Displays for Categorical Images." *Color Research & Application*, 32(4),
> 304–309. DOI: 10.1002/col.20327

## Generation

```python
import glasbey  # v0.3.0+

palette = glasbey.create_palette(
    palette_size=256,
    lightness_bounds=(20, 90),
    chroma_bounds=(20, 100),
)
# Returns list of hex strings: ['#d70000', '#8651e3', ...]
```

**Parameters chosen:**

| Parameter         | Value     | Rationale                                      |
|-------------------|-----------|------------------------------------------------|
| `palette_size`    | 256       | Future-proof: covers any enum expansion        |
| `lightness_bounds`| (20, 90)  | Avoids near-black/near-white (poor on any bg)  |
| `chroma_bounds`   | (20, 100) | Ensures saturated, visually salient colors     |

## Architecture

```
src/rendering/postfx/glasbey_palette.odin
├── GLASBEY_256 :: [256][3]f32   ← compile-time constant, indexed by enum ordinal

shaders/postfx/postfx.frag
├── splitColors[24]              ← first 24 entries (matches Post_Effect enum size)

src/gui/gui_postfx.odin
├── draw_split_indicator()       ← reads GLASBEY_256[u32(effect)] at runtime
```

**Adding a new post-effect:**

1. Add variant to `Post_Effect` enum → gets next ordinal (e.g. 24)
2. Shader: bump `splitColors` array size and loop bound
3. GUI: nothing to change — `draw_split_indicator` auto-indexes

## Properties

- **Maximin in CIELAB** — each color maximizes min(ΔE*) vs all predecessors
- **Deterministic** — same seed/bounds → same palette (reproducible)
- **256 entries** — enough for any foreseeable expansion
- **Compile-time** — zero runtime cost (Odin `::` constant, GLSL `const`)

## Next Steps

- [ ] Expand to full enum coverage in shader (done: 24 entries)
- [ ] Consider accessibility: overlay effect name text alongside color?
- [ ] Evaluate if split line thickness should scale with DPI
- [ ] Palette subset visualization in ImGui (color swatches in tooltip?)
