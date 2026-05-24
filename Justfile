# suckless-odin — Justfile
# Build, run, and lint recipes for the Odin OpenGL PBR engine port.
# Build output base directory (each config gets its own subdir)

set dotenv-load

build_base := "build"

# --- Transparent Distrobox Execution Wrappers ---
# Auto-detect: inside container, or distrobox available on host, or native (no distrobox)
in_container := env_var_or_default("CONTAINER_ID", "")
distrobox_container := "clang-dev"
has_distrobox := `which distrobox >/dev/null 2>&1 && echo "yes" || echo ""`
# "native" is non-empty when we should run tools directly (in container OR no distrobox)
native := if in_container != "" { "yes" } else if has_distrobox == "" { "yes" } else { "" }
dbx := if native != "" { "" } else { "distrobox enter " + distrobox_container + " -- " }

odin := if native != "" { "odin" } else { "env ODIN_ROOT=/usr/lib/odin " + dbx + "odin" }
# odin without dbx prefix (for use inside xvfb_run which already enters the container)
odin_inner := if native != "" { "odin" } else { "env ODIN_ROOT=/usr/lib/odin odin" }
python3 := if native != "" { "python3" } else { dbx + "python3" }
cmake := if native != "" { "cmake" } else { dbx + "cmake" }
bash := if native != "" { "bash" } else { dbx + "bash" }
xvfb_run := if native != "" { "xvfb-run" } else { dbx + "xvfb-run" }

# Extra linker flags (libc++ from linuxbrew, X11 for imgui_impl_glfw)
# Inside container: libs already in default search path; native or distrobox host: need explicit -L
extra_linker_flags := if in_container != "" { "-Wl,-rpath,/home/linuxbrew/.linuxbrew/lib -lX11" } else { "-L/home/linuxbrew/.linuxbrew/lib -Wl,-rpath,/home/linuxbrew/.linuxbrew/lib -lX11" }

# Tracy profiler extra linker flags (C++ runtime + libtracy.a deps)
tracy_linker_flags := extra_linker_flags + " -lstdc++"

# Native execution runner (e.g., mangohud) loaded from .env
runner := if env_var_or_default("USE_MANGOHUD", "0") == "1" { "mangohud " } else { "" }

# Parallelism for C++ builds (leave 2 cores free)
nprocs := `echo $(( $(nproc) - 2 ))`

# X11 vs Wayland auto-detection for Tracy server backend
tracy_legacy := if env_var_or_default("XDG_SESSION_TYPE", "x11") == "wayland" { "OFF" } else { "ON" }

# Optimization flag for release builds (maximum optimization level)
opt_flag := "speed"

# Default recipe: build + run
default: build run

# --- Build ---

# Debug build
build:
    @mkdir -p {{ build_base }}/debug
    {{ odin }} build src/ -out:{{ build_base }}/debug/suckless-odin -debug -use-separate-modules -extra-linker-flags:"{{ extra_linker_flags }}"

# Release build (optimized)
build-release:
    @mkdir -p {{ build_base }}/release
    {{ odin }} build src/ -out:{{ build_base }}/release/suckless-odin -o:{{ opt_flag }} -use-separate-modules -extra-linker-flags:"{{ extra_linker_flags }}"

# Ultra-release build (maximum optimization, native arch, no safety checks)
build-ultra:
    @mkdir -p {{ build_base }}/ultra
    {{ odin }} build src/ -out:{{ build_base }}/ultra/suckless-odin -o:aggressive -microarch:native -no-bounds-check -no-type-assert -extra-linker-flags:"{{ extra_linker_flags }}"

# Profile build (with Tracy Profiler active)
build-profile:
    @mkdir -p {{ build_base }}/profile
    {{ odin }} build src/ -out:{{ build_base }}/profile/suckless-odin -o:{{ opt_flag }} -define:TRACY_ENABLE=true -extra-linker-flags:"{{ tracy_linker_flags }}"

# Build with all vet checks + strict style (lint errors = build errors)
build-strict:
    @mkdir -p {{ build_base }}/debug
    {{ odin }} build src/ -out:{{ build_base }}/debug/suckless-odin -debug -use-separate-modules -vet -strict-style -warnings-as-errors -extra-linker-flags:"{{ extra_linker_flags }}"

# Sanitizer build (address + undefined behavior)
build-sanitize:
    @mkdir -p {{ build_base }}/sanitize
    {{ odin }} build src/ -out:{{ build_base }}/sanitize/suckless-odin -debug -use-separate-modules -sanitize:address -extra-linker-flags:"{{ extra_linker_flags }}"

# --- Run ---

# Run the application (debug)
run:
    {{ runner }}./{{ build_base }}/debug/suckless-odin

# Run release build
run-release:
    {{ runner }}./{{ build_base }}/release/suckless-odin

# Run ultra-release build
run-ultra:
    {{ runner }}./{{ build_base }}/ultra/suckless-odin

# Run profile build
run-profile:
    {{ runner }}./{{ build_base }}/profile/suckless-odin

# Build and run in one step
br: build run

# Build and run release
br-release: build-release run-release

# Build and run ultra-release
br-ultra: build-ultra run-ultra

# Build and run profile (Tracy)
br-profile: build-profile run-profile

# --- Test ---

# Run all tests (external + in-package + shader + GL)
test: test-unit test-cli test-shader test-gl

# Unit tests (camera, settings, material, rendering)
test-unit:
    {{ odin }} test tests/ -out:/tmp/odin-test-unit

# CLI tests (in main package)
test-cli:
    {{ odin }} test src/ -out:/tmp/odin-test-cli

# Shader CPU tests (in-package, tests private helpers)
test-shader:
    {{ odin }} test src/rendering/shader/ -out:/tmp/odin-test-shader

# Headless GL tests (shader compilation, GPU validation — single-threaded)
test-gl:
    {{ odin }} test tests/gl/ -out:/tmp/odin-test-gl -define:ODIN_TEST_THREADS=1 -extra-linker-flags:"{{ extra_linker_flags }}"

# --- Lint ---

# Full lint: vet + strict style (no binary output)
lint:
    {{ odin }} check src/ -vet -strict-style -warnings-as-errors

# Vet only (unused vars, imports, shadowing, casts)
vet:
    {{ odin }} check src/ -vet

# Style check only (1TBS, trailing commas, deprecated syntax)
style:
    {{ odin }} check src/ -strict-style

# --- Format ---

# Remove unneeded semicolons
strip-semicolons:
    {{ odin }} strip-semicolon src/

# --- Clean ---

# Remove all build artifacts
clean:
    rm -rf {{ build_base }}
    rm -f *.o

# --- Dependencies ---

# Rebuild Dear ImGui library (requires python3, clang, ar)
build-imgui:
    {{ bash }} -c 'cd deps/odin-imgui && rm -rf .venv && python3 -m venv .venv && . .venv/bin/activate && pip install -q ply && python ../../scripts/build_imgui_parallel.py'

# Update Dear ImGui submodule to latest upstream commit and rebuild
update-imgui:
    {{ bash }} -c 'git submodule update --remote deps/odin-imgui && just build-imgui && echo "Updated odin-imgui to:" && git -C deps/odin-imgui log --oneline -1'

# Build Tracy client library from source (deps/libtracy.a)
build-tracy-lib:
    {{ bash }} scripts/build_tracy_lib.sh

# Build Tracy profiler server GUI (CMake, downloads deps via CPM)
build-tracy-server:
    {{ cmake }} -B deps/tracy/profiler/build -S deps/tracy/profiler -DCMAKE_BUILD_TYPE=Release -DLEGACY={{ tracy_legacy }} -Wno-dev
    {{ cmake }} --build deps/tracy/profiler/build --parallel {{ nprocs }}

# Launch Tracy profiler server (auto-connects to instrumented app)
tracy-server:
    {{ dbx }}deps/tracy/profiler/build/tracy-profiler

# Full Tracy setup: build client lib + server
build-tracy: build-tracy-lib build-tracy-server

# Update Tracy submodule to latest tag and rebuild everything
update-tracy:
    {{ bash }} -c 'set -euo pipefail && cd deps/tracy && git fetch --tags && LATEST=$(git tag --sort=-v:refname | head -1) && CURRENT=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD) && if [[ "$LATEST" == "$CURRENT" ]]; then echo "Tracy already at latest: $CURRENT"; exit 0; fi && echo "Updating Tracy: $CURRENT -> $LATEST" && git checkout "$LATEST" && cd ../.. && just build-tracy && echo "✓ Tracy updated to $LATEST (lib + server rebuilt)"'

# --- CI (local) ---

# Install git hooks via pre-commit framework (https://pre-commit.com)
pre-commit-install:
    pre-commit install
    pre-commit install --hook-type pre-push
    @echo "✅ Git hooks installed (pre-commit: lint, pre-push: lint+build+tests)"

# Full CI pipeline (lint + build + all tests) — mirrors GitHub Actions
ci: lint build test-unit test-cli test-shader test-gl-xvfb

# GL tests under xvfb (headless, for CI or systems without display)
test-gl-xvfb:
    {{ xvfb_run }} -a -s "-screen 0 1024x768x24" {{ odin_inner }} test tests/gl/ -out:/tmp/odin-test-gl -define:ODIN_TEST_THREADS=1 -extra-linker-flags:"{{ extra_linker_flags }}"

# Generate visual regression references (DESTRUCTIVE — overwrites refs, requires confirmation)
[confirm("⚠️  This will OVERWRITE all visual reference images. Continue?")]
gen-refs:
    GEN_REFS=1 {{ odin_inner }} test tests/gl/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_gl.test_visual_scene_multi_view -extra-linker-flags:"{{ extra_linker_flags }}"

# Generate refs under xvfb (DESTRUCTIVE — overwrites refs, requires confirmation)
[confirm("⚠️  This will OVERWRITE all visual reference images. Continue?")]
gen-refs-xvfb:
    {{ xvfb_run }} -a -s "-screen 0 1024x768x24" env GEN_REFS=1 {{ odin_inner }} test tests/gl/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_gl.test_visual_scene_multi_view -extra-linker-flags:"{{ extra_linker_flags }}"

# --- Benchmarks ---

# Run all benchmarks
bench: bench-search bench-render

# GPU render benchmark (all postfx effects, glFinish per frame, 200 frames)
bench-render: build-release
    {{ runner }}env vblank_mode=0 __GL_SYNC_TO_VBLANK=0 ./{{ build_base }}/release/suckless-odin --benchmark --benchmark-frames=200

# GPU render benchmark (debug build)
bench-render-debug: build
    {{ runner }}env vblank_mode=0 __GL_SYNC_TO_VBLANK=0 ./{{ build_base }}/debug/suckless-odin --benchmark --benchmark-frames=200

# Fuzzy search benchmark (measures ns/call for fuzzy_match + levenshtein)
bench-search:
    {{ odin }} run benchmarks/search/ -o:speed -out:/tmp/odin-bench-search

# Compare benchmark against baseline (run twice, report delta)
bench-search-compare:
    @echo "── Baseline (current commit) ──"
    @{{ odin }} run benchmarks/search/ -o:speed -out:/tmp/odin-bench-search 2>/dev/null
    @echo ""
    @echo "Tip: run 'just bench-search' before and after changes to compare ns/call"

# A/B commit comparison: checkout two commits, run benchmark, show delta table

# Usage: just bench-compare search [commitA] [commitB]
bench-compare name *args:
    {{ bash }} ./scripts/bench_compare.sh {{ name }} {{ args }}

# --- RenderDoc (Frame Analysis) ---

renderdoc_dir := env_var_or_default("RENDERDOC_DIR", "/usr/bin")

# Launch qrenderdoc GUI with debug build for frame analysis
renderdoc: build
    {{ renderdoc_dir }}/qrenderdoc --working-dir . ./{{ build_base }}/debug/suckless-odin

# Capture a frame via renderdoccmd CLI (headless, outputs .rdc file)
renderdoc-capture: build
    {{ renderdoc_dir }}/renderdoccmd capture --working-dir . ./{{ build_base }}/debug/suckless-odin
