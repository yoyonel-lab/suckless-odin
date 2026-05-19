# std140 UBO Padding Strategy

**Date**: 2026-05-19  
**Context**: Port of suckless-ogl Post-FX pipeline to Odin

## Problem

OpenGL `std140` UBOs require manual padding to match GPU layout rules:
- `vec4` aligned to 16 bytes
- Scalars (`float`) aligned to 4 bytes, but array elements to 16
- Structs padded to multiple of their largest alignment (at least 16)
- `vec3` occupies 16 bytes (not 12!)

This forces `_pad` fields on both Odin structs and GLSL UBO blocks.

## Why Odin Can't Eliminate Padding Automatically

Odin's `#align(N)` and `#packed` control **CPU** struct layout (like C's
`__attribute__((packed))`). They follow the system ABI.

`std140` is a **GPU-specific** convention that no CPU language handles natively.
There is no `#std140` directive in Odin (nor in C, Rust, Zig, etc.).

## Alternatives Considered

| Approach | Verdict |
|----------|---------|
| `std430` layout | Only for SSBOs, not UBOs in core profile |
| Push constants | Not available in OpenGL (Vulkan only) |
| SSBO instead of UBO | Works but loses UBO caching benefits |
| Code-gen from GLSL | Over-engineered for this project size |

## Strategy Adopted

1. **`#packed`** on UBO struct — prevent Odin from adding its own CPU padding
2. **`_: [N]f32`** — Odin blank identifier for padding (idiomatic, multiple allowed)
3. **`#assert(size_of(...) == N)`** — compile-time guard against layout drift
4. **Field ordering** — group fields to fill 16-byte blocks naturally, minimizing waste
5. **Comments** — annotate each section with byte size for quick visual audit

## Layout Rules Quick Reference (std140)

```
Type         Alignment    Size
float        4            4
vec2         8            8
vec3         16           16 (!)
vec4         16           16
mat4         16           64 (4 × vec4)
float[N]     16           N × 16 (!)
struct       16           roundup(contents, 16)
```

## Current UBO: Post_FX_UBO (240 bytes)

| Section        | Fields | Useful bytes | Pad bytes | Total |
|----------------|--------|-------------|-----------|-------|
| Header         | 4      | 16          | 0         | 16    |
| Vignette       | 3      | 12          | 4         | 16    |
| Grain          | 7      | 28          | 4         | 32    |
| Exposure       | 1      | 4           | 12        | 16    |
| Chrom. Abbr    | 1      | 4           | 12        | 16    |
| White Balance  | 2      | 8           | 8         | 16    |
| Color Grading  | 6      | 24          | 8         | 32    |
| Tonemap        | 5      | 20          | 12        | 32    |
| Bloom          | 4      | 16          | 0         | 16    |
| FXAA           | 3      | 12          | 4         | 16    |
| DoF            | 4      | 16          | 0         | 16    |
| Camera planes  | 2      | 8           | 8         | 16    |
| **Total**      | 42     | **168**     | **72**    | **240** |

Padding overhead: 30% — acceptable for a single UBO uploaded once per frame.

## Future Optimization

If more parameters are added, reorder to fill existing padding slots:
- Exposure section has 12 bytes free → can absorb 3 more floats
- Chrom. Abbr has 12 bytes free → can absorb 3 more floats
- White Balance has 8 bytes free → can absorb 2 more floats
- Camera planes has 8 bytes free → can absorb 2 more floats
