# suckless-odin — Justfile
# Build, run, and lint recipes for the Odin OpenGL PBR engine port.

# Build output base directory (each config gets its own subdir)
build_base := "build"

# Default recipe: build + run
default: build run

# --- Build ---

# Debug build
build:
    @mkdir -p {{build_base}}/debug
    odin build src/ -out:{{build_base}}/debug/suckless-odin -debug

# Release build (optimized)
build-release:
    @mkdir -p {{build_base}}/release
    odin build src/ -out:{{build_base}}/release/suckless-odin -o:speed

# Build with all vet checks + strict style (lint errors = build errors)
build-strict:
    @mkdir -p {{build_base}}/debug
    odin build src/ -out:{{build_base}}/debug/suckless-odin -debug -vet -strict-style -warnings-as-errors

# Sanitizer build (address + undefined behavior)
build-sanitize:
    @mkdir -p {{build_base}}/sanitize
    odin build src/ -out:{{build_base}}/sanitize/suckless-odin -debug -sanitize:address

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
    odin test tests/gl/ -define:ODIN_TEST_THREADS=1

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

# --- CI (local) ---

# Full CI pipeline (lint + build + all tests) — mirrors GitHub Actions
ci: lint build test-unit test-cli test-shader test-gl-xvfb

# GL tests under xvfb (headless, for CI or systems without display)
test-gl-xvfb:
    xvfb-run -a -s "-screen 0 1024x768x24" odin test tests/gl/ -define:ODIN_TEST_THREADS=1

# Generate visual regression references (run once, commit results)
gen-refs:
    GEN_REFS=1 odin test tests/gl/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_gl.test_visual_scene_multi_view

# Generate refs under xvfb (headless)
gen-refs-xvfb:
    xvfb-run -a -s "-screen 0 1024x768x24" env GEN_REFS=1 odin test tests/gl/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_gl.test_visual_scene_multi_view
