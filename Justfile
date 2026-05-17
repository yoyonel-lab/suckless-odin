# suckless-odin — Justfile
# Build, run, and lint recipes for the Odin OpenGL PBR engine port.

# Build output base directory (each config gets its own subdir)
build_base := "build"

# Extra linker flags (libc++ from linuxbrew, X11 for imgui_impl_glfw)
extra_linker_flags := "-L/home/linuxbrew/.linuxbrew/lib -Wl,-rpath,/home/linuxbrew/.linuxbrew/lib -lX11"

# Default recipe: build + run
default: build run

# --- Build ---

# Debug build
build:
    @mkdir -p {{build_base}}/debug
    odin build src/ -out:{{build_base}}/debug/suckless-odin -debug -extra-linker-flags:"{{extra_linker_flags}}"

# Release build (optimized)
build-release:
    @mkdir -p {{build_base}}/release
    odin build src/ -out:{{build_base}}/release/suckless-odin -o:speed -extra-linker-flags:"{{extra_linker_flags}}"

# Build with all vet checks + strict style (lint errors = build errors)
build-strict:
    @mkdir -p {{build_base}}/debug
    odin build src/ -out:{{build_base}}/debug/suckless-odin -debug -vet -strict-style -warnings-as-errors -extra-linker-flags:"{{extra_linker_flags}}"

# Sanitizer build (address + undefined behavior)
build-sanitize:
    @mkdir -p {{build_base}}/sanitize
    odin build src/ -out:{{build_base}}/sanitize/suckless-odin -debug -sanitize:address -extra-linker-flags:"{{extra_linker_flags}}"

# --- Run ---

# Run the application (debug)
run:
    ./{{build_base}}/debug/suckless-odin

# Run release build
run-release:
    ./{{build_base}}/release/suckless-odin

# Build and run in one step
br: build run

# --- Test ---

# Run all tests (external + in-package + shader + GL)
test: test-unit test-cli test-shader test-gl

# Unit tests (camera, settings, material, rendering)
test-unit:
    odin test tests/

# CLI tests (in main package)
test-cli:
    odin test src/

# Shader CPU tests (in-package, tests private helpers)
test-shader:
    odin test src/rendering/shader/

# Headless GL tests (shader compilation, GPU validation — single-threaded)
test-gl:
    odin test tests/gl/ -define:ODIN_TEST_THREADS=1 -extra-linker-flags:"{{extra_linker_flags}}"

# --- Lint ---

# Full lint: vet + strict style (no binary output)
lint:
    odin check src/ -vet -strict-style -warnings-as-errors

# Vet only (unused vars, imports, shadowing, casts)
vet:
    odin check src/ -vet

# Style check only (1TBS, trailing commas, deprecated syntax)
style:
    odin check src/ -strict-style

# --- Format ---

# Remove unneeded semicolons
strip-semicolons:
    odin strip-semicolon src/

# --- Clean ---

# Remove all build artifacts
clean:
    rm -rf {{build_base}}
    rm -f *.o

# --- Dependencies ---

# Rebuild Dear ImGui library (requires python3, clang, ar)
build-imgui:
    cd deps/odin-imgui && rm -rf .venv && python3 -m venv .venv && . .venv/bin/activate && pip install -q ply && python ../../scripts/build_imgui_parallel.py

# Update Dear ImGui submodule to latest upstream commit and rebuild
update-imgui:
    git submodule update --remote deps/odin-imgui
    just build-imgui
    @echo "Updated odin-imgui to:" && git -C deps/odin-imgui log --oneline -1

# --- CI (local) ---

# Full CI pipeline (lint + build + all tests) — mirrors GitHub Actions
ci: lint build test-unit test-cli test-shader test-gl-xvfb

# GL tests under xvfb (headless, for CI or systems without display)
test-gl-xvfb:
    xvfb-run -a -s "-screen 0 1024x768x24" odin test tests/gl/ -define:ODIN_TEST_THREADS=1 -extra-linker-flags:"{{extra_linker_flags}}"

# Generate visual regression references (DESTRUCTIVE — overwrites refs, requires confirmation)
[confirm("⚠️  This will OVERWRITE all visual reference images. Continue?")]
gen-refs:
    GEN_REFS=1 odin test tests/gl/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_gl.test_visual_scene_multi_view -extra-linker-flags:"{{extra_linker_flags}}"

# Generate refs under xvfb (DESTRUCTIVE — overwrites refs, requires confirmation)
[confirm("⚠️  This will OVERWRITE all visual reference images. Continue?")]
gen-refs-xvfb:
    xvfb-run -a -s "-screen 0 1024x768x24" env GEN_REFS=1 odin test tests/gl/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_gl.test_visual_scene_multi_view -extra-linker-flags:"{{extra_linker_flags}}"
