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

CXXFLAGS="-O2 -DTRACY_ENABLE -DTRACY_ON_DEMAND -w"
CXXFLAGS="$CXXFLAGS -I$TRACY_DIR/public"
CXXFLAGS="$CXXFLAGS -I$GLAD_DIR/include"
CXXFLAGS="$CXXFLAGS -I$ROOT_DIR/deps"

CFLAGS="-O2 -w -I$GLAD_DIR/include"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[1/3] Compiling TracyClient.cpp..."
$CXX $CXXFLAGS -std=c++17 -c "$TRACY_DIR/public/TracyClient.cpp" -o "$BUILD_DIR/TracyClient.o"

echo "[2/3] Compiling tracy_gpu.cpp..."
$CXX $CXXFLAGS -std=c++17 -c "$ROOT_DIR/deps/tracy_gpu.cpp" -o "$BUILD_DIR/tracy_gpu.o"

echo "[3/3] Compiling glad.c..."
$CC $CFLAGS -c "$GLAD_DIR/src/glad.c" -o "$BUILD_DIR/glad.o"

echo "[+] Archiving libtracy.a..."
$AR rcs "$ROOT_DIR/deps/libtracy.a" \
    "$BUILD_DIR/TracyClient.o" \
    "$BUILD_DIR/tracy_gpu.o" \
    "$BUILD_DIR/glad.o"

rm -rf "$BUILD_DIR"

echo "[✓] deps/libtracy.a built (Tracy v0.13.1, ON_DEMAND mode)"
