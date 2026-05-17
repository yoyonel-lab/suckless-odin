# suckless-odin — Justfile
# Build, run, and lint recipes for the Odin OpenGL PBR engine port.

# Default recipe: build + run
default: build run

# --- Build ---

# Debug build
build:
    odin build src/ -out:suckless-odin -debug

# Release build (optimized)
build-release:
    odin build src/ -out:suckless-odin -o:speed

# Build with all vet checks + strict style (lint errors = build errors)
build-strict:
    odin build src/ -out:suckless-odin -debug -vet -strict-style -warnings-as-errors

# --- Run ---

# Run the application
run:
    ./suckless-odin

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

# Remove build artifacts
clean:
    rm -f suckless-odin
