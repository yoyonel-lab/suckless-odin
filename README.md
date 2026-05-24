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

Requires [Just](https://github.com/casey/just) task runner.

> **Note:** For systems using isolated containers (like Bazzite or Fedora Silverblue), see [Distrobox Environment & Native GPU Offloading (Optimus)](docs/distrobox-optimus-2026-05-24.md) for compiling inside `distrobox` while running natively on the host GPU.

```bash
# Debug build (default)
just build
just run

# Build and run in one step (all targets)
just br            # debug
just br-release    # optimized
just br-ultra      # maximum perf
just br-profile    # Tracy profiler

# Profile build (Tracy Profiler enabled)
just build-profile
just run-profile

# All available recipes
just --list
```

### Build Modes

| Mode | Optimization | Safety | Use Case |
|------|-------------|--------|----------|
| `build` | `-debug` | Full | Development, debugging |
| `build-release` | `-o:speed` | Full | Production |
| `build-ultra` | `-o:aggressive -microarch:native` | None (`-no-bounds-check -no-type-assert`) | Benchmarking, max perf |
| `build-profile` | `-o:speed -define:TRACY_ENABLE=true` | Full | Tracy profiling |
| `build-sanitize` | `-debug -sanitize:address` | Full + ASAN | Memory bug detection |

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
