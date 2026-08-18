#!/usr/bin/env bash
# Build libtracy.a (Tracy client + GPU wrapper + glad) from source.
# Output: deps/libtracy.a
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACY_DIR="$ROOT_DIR/deps/tracy"
GLAD_DIR="$ROOT_DIR/deps/glad"
BUILD_DIR="$ROOT_DIR/deps/tracy_build"
NPROCS=$(( $(nproc) - 2 ))

CXX="${CXX:-g++}"
CC="${CC:-gcc}"
AR="${AR:-ar}"

CXXFLAGS="-O2 -DTRACY_ENABLE -DTRACY_ON_DEMAND -DTRACY_FIBERS -w"
CXXFLAGS="$CXXFLAGS -I$TRACY_DIR/public"
CXXFLAGS="$CXXFLAGS -I$GLAD_DIR/include"
CXXFLAGS="$CXXFLAGS -I$ROOT_DIR/deps"

CFLAGS="-O2 -w -I$GLAD_DIR/include"

# SIMD utils flags: enable AVX2/F16C for FP32→FP16 conversion (ISO: simd_utils.c)
SIMD_CFLAGS="-O3 -w -mavx2 -mf16c -I$ROOT_DIR/deps"


rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[1/4] Compiling TracyClient.cpp..."
$CXX $CXXFLAGS -std=c++17 -c "$TRACY_DIR/public/TracyClient.cpp" -o "$BUILD_DIR/TracyClient.o"

echo "[2/4] Compiling tracy_gpu.cpp..."
$CXX $CXXFLAGS -std=c++17 -c "$ROOT_DIR/deps/tracy_gpu.cpp" -o "$BUILD_DIR/tracy_gpu.o"

echo "[3/4] Compiling glad.c..."
$CC $CFLAGS -c "$GLAD_DIR/src/glad.c" -o "$BUILD_DIR/glad.o"

echo "[4/4] Compiling simd_utils.c (AVX2/F16C)..."
$CC $SIMD_CFLAGS -c "$ROOT_DIR/deps/simd_utils.c" -o "$BUILD_DIR/simd_utils.o"

echo "[+] Archiving libtracy.a..."
$AR rcs "$ROOT_DIR/deps/libtracy.a" \
    "$BUILD_DIR/TracyClient.o" \
    "$BUILD_DIR/tracy_gpu.o" \
    "$BUILD_DIR/glad.o"

echo "[+] Archiving libsimd.a..."
$AR rcs "$ROOT_DIR/deps/libsimd.a" \
    "$BUILD_DIR/simd_utils.o"

rm -rf "$BUILD_DIR"

echo "[✓] deps/libtracy.a built (Tracy v0.13.1, ON_DEMAND mode)"
