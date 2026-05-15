# suckless-odin

Suckless OpenGL rendering engine — ISO port from [suckless-ogl](https://github.com/yoyonel/suckless-ogl) (C) to [Odin](https://odin-lang.org/).

PBR, IBL, compute shaders, post-processing pipeline.

## Architecture

| Subsystem | Package |
|-----------|---------|
| **Core App** | `src/app/` |
| **Scene** | `src/scene/` |
| **Rendering** | `src/rendering/` |
| **PBR / IBL** | `src/pbr/` |
| **Post-Processing** | `src/postprocess/` |
| **Shaders** | `shaders/` (GLSL, shared with C version) |
| **Input** | `src/input/` |
| **Profiling** | `src/profiling/` |
| **Camera** | `src/camera/` |
| **Core Utilities** | `src/core/` |

## Build & Run

```bash
odin build src/ -out:suckless-odin
./suckless-odin

# Debug build
odin build src/ -out:suckless-odin -debug

# Run directly
odin run src/
```

## Dependencies

Odin vendor packages (bundled with the compiler):
- `vendor:glfw` — Window management & input
- `vendor:OpenGL` — OpenGL 4.6 bindings
- `core:math/linalg/glsl` — GLSL-compatible linear algebra (vec3, mat4, etc.)

External (assets):
- HDR environment maps in `assets/textures/`
- LUT files in `assets/luts/`
- Fonts in `assets/fonts/`

## Relationship to suckless-ogl

This is an **ISO port** — functionally identical to the C original:
- Same OpenGL pipeline (PBR, IBL, compute shaders, post-processing)
- Same shader files (GLSL is language-agnostic)
- Same rendering techniques and algorithms
- Odin-idiomatic code style (no raw pointers where slices suffice, context system for allocators, etc.)
