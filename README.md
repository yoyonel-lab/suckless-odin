# suckless-odin

![PBR rendering — front view](tests/references/ref_front.png)

Suckless OpenGL rendering engine — ISO port from [suckless-ogl](https://github.com/yoyonel/suckless-ogl) (C) to [Odin](https://odin-lang.org/).

PBR physically-based rendering, IBL image-based lighting, uber-shader post-processing pipeline, Dear ImGui GUI, Tracy profiling.

## Features

- **PBR/IBL** — Cook-Torrance BRDF, irradiance/prefilter/BRDF-LUT compute, instanced billboard spheres (100 materials, SSBO-driven)
- **Post-Processing** (15 effects, uber-shader): Bloom, Motion Blur, FXAA, DoF, Auto-Exposure, Tonemapping, Vignette, Film Grain, Chromatic Aberration, Color Grading, 3D LUT, Fog, Banding suppression, Stencil Debug, Vector Field Debug
- **Dear ImGui** integration — full GUI control over all effects + session persistence
- **Tracy Profiler** — CPU zones + GPU timing + frame screenshots
- **Visual Regression** — automated headless GL tests with SSIM comparison
- **Benchmarking** — GPU render bench, fuzzy search bench, comparative runs

## Architecture

| Package | Description |
|---------|-------------|
| `src/app/` | Window, input, main loop (GLFW) |
| `src/scene/` | Scene graph, PBR draw, skybox |
| `src/rendering/` | Billboard, IBL, instancing, materials, skybox, overlay |
| `src/rendering/postfx/` | Uber-shader pipeline, bloom, DoF, motion blur, auto-exposure, FXAA, LUT3D |
| `src/rendering/shader/` | Shader cache, variant compilation |
| `src/camera/` | Orbit camera, physics, smooth input |
| `src/gui/` | Dear ImGui panels (postfx, camera, scene controls) |
| `src/core/log/` | Structured logging |
| `src/core/settings/` | Compile-time defaults |
| `src/core/session/` | JSON session persistence (load/save all state) |
| `src/core/glasbey/` | Perceptually-uniform palette generation |
| `src/core/gl_debug/` | OpenGL debug groups (RenderDoc/NSight labels) |
| `src/core/tracy/` | Tracy integration + frame image capture |
| `src/core/perf_mode/` | Runtime performance mode toggling |
| `src/core/search/` | Fuzzy search (Levenshtein + scoring) |
| `src/core/math_types/` | Shared math types (Mat4, Vec3, etc.) |
| `shaders/` | GLSL 4.50 (PBR, background, IBL compute, post-FX) |
| `tests/` | Unit tests (63) + GL headless tests (45) |

## Build & Run

Requires [Odin](https://odin-lang.org/) dev-2026-05+ and [Task](https://taskfile.dev) (go-task).

> **Note:** For systems using isolated containers (Bazzite, Fedora Silverblue), see [Distrobox Environment & Native GPU Offloading](docs/distrobox-optimus-2026-05-24.md).  
> **Toolchain Note:** If upgrading Odin and hitting `vendor:stb` compile-time panics, see [Odin vendor:stb Toolchain Setup](docs/toolchain-stb-vendor-setup-2026-08-17.md).

```bash
# Debug build (default)
task build
task run

# Build and run in one step
task br            # debug
task br-release    # optimized
task br-ultra      # maximum perf
task br-profile    # Tracy profiler

# All available tasks
task --list
```

### Build Modes

| Mode | Optimization | Safety | Use Case |
|------|-------------|--------|----------|
| `build` | `-debug` | Full | Development, debugging |
| `build-fast-release` | `-o:speed` | Full | Quick release builds |
| `build-release` | `-o:speed` | Full | Production |
| `build-ultra` | `-o:aggressive -microarch:native` | None | Benchmarking, max perf |
| `build-profile` | `-o:speed -define:TRACY_ENABLE=true` | Full | Tracy profiling |
| `build-sanitize` | `-debug -sanitize:address` | Full + ASAN | Memory bug detection |

## Command-Line Interface (CLI)

The compiled engine supports a robust set of command-line arguments to customize rendering features, apply post-processing presets, execute benchmarks, or switch performance profiles:

```bash
# General Usage
./build/release/suckless-odin [options]
```

### Available Options

| Option | Argument Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `-h`, `--help` | — | — | Displays the command-line help message and usage layout. |
| `-v`, `--version` | — | — | Prints the version information. |
| `--no-postfx` | — | — | Completely disables the post-processing uber-shader pipeline. |
| `--postfx-preset=<name>` | `string` | — | Applies a post-processing aesthetic preset: `default`, `subtle`, `cinematic`, `vibrant`, `clean`. |
| `--vsync` | — | `off` | Enables vertical synchronization. |
| `--benchmark` | — | — | Executes a headless automated rendering benchmark, reports statistics, and exits. |
| `--benchmark-frames=<N>`| `integer` | `300` | Overrides the number of frames evaluated during a benchmark run. |
| `--compute-profile=<name>`| `string` | `legacy`| Configures compute shader integration details: `legacy` (default, high-fidelity) or `optimized` (fast, low-overhead). |

For complete documentation regarding compute tuning parameters, dynamic macro generation, and preprocessor VRAM injection, see [Compute Shader Tuning & Dynamic Quality Profiles](docs/compute-shader-tuning-2026-05-27.md).

## Testing & Memory Sanitization

```bash
task test            # All tests (unit + CLI + shader + GL headless)
task test-unit       # Unit tests only (63 tests)
task test-gl-xvfb   # GL tests under xvfb (45 tests, headless)
task valgrind        # Run release build under Valgrind Memcheck with suppressions
task valgrind-xvfb   # Run headless benchmark under Valgrind Memcheck
task ci              # Full CI pipeline (lint + build + all tests)
```

For a comprehensive breakdown of memory leak prevention, compiler-optimization warning bypasses, and custom driver suppression architectures, see the [Memory Safety Audit & Valgrind Sanitization Guide](docs/valgrind-memory-sanitization-2026-05-27.md).

## Profiling & Performance Analysis

The project integrates advanced memory, CPU, cache, and frame-level profiling tools:

```bash
# Heap Memory Allocations (Heaptrack)
task profile-heaptrack         # Run automated allocation analysis & CLI summary
task profile-heaptrack-gui     # Open allocation trace in heaptrack_gui

# Hardware Performance & Cache Misses (Intel VTune Profiler)
task profile-vtune-hotspots    # CPU Hotspots & disassembly analysis
task profile-vtune-memory      # L1/L2/L3 cache misses, DRAM bandwidth, latency
task profile-vtune-threading   # Thread concurrency, lock contention, waits
task profile-vtune-gui         # Open latest VTune report in GUI

# CPU Instruction Call Tree (Valgrind Callgrind)
task profile-callgrind         # Instruction count profiling & annotation
task profile-callgrind-gui     # Open call graph in KCachegrind

# Real-Time Frame Profiling (Tracy Profiler)
task build-profile             # Build with Tracy instrumentation
task profile                   # Automated Tracy capture run
```

For complete documentation, see the [Advanced Profiling Guide](docs/profiling_advanced.md).


### Docker Local CI

ISO reproduction of GitHub Actions for debugging CI issues locally:

```bash
task ci-docker-build       # Build the Docker image (ubuntu:24.04, Odin, Mesa)
task ci-docker             # Run full CI inside Docker
task ci-docker test-unit   # Run only unit tests
task ci-docker-shell       # Interactive shell for debugging
```

## Dependencies

Odin vendor packages (bundled with compiler):
- `vendor:glfw` — Window management & input
- `vendor:OpenGL` — OpenGL 4.5 bindings

External (in-repo):
- `deps/odin-imgui/` — Dear ImGui bindings + prebuilt static lib
- `deps/tracy/` — Tracy profiler client
- `assets/textures/hdr/` — HDR environment maps
- `assets/luts/` — 3D color LUT files (.cube)
- `assets/fonts/` — FiraCode for text overlay
- `assets/materials/` — PBR material presets (JSON)

## Relationship to suckless-ogl

This is an **ISO port** — functionally identical to the C original:
- Same OpenGL pipeline (PBR, IBL, compute shaders, post-processing)
- Same shader files (GLSL is language-agnostic)
- Same rendering techniques and algorithms
- Odin-idiomatic code style (no raw pointers where slices suffice, context system for allocators, `#soa` arrays, etc.)
- Self-contained: all assets are tracked in this repo (no sibling repo dependency)
