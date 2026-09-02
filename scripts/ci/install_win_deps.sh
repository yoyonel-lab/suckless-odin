#!/usr/bin/env bash
# scripts/ci/install_win_deps.sh — Restore pre-built Windows dependencies into Odin root and workspace
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPS_DIR="$ROOT_DIR/deps"
ODIN_ROOT="${ODIN_ROOT:-$(odin root 2>/dev/null || echo "/opt/odin")}"

mkdir -p "$ODIN_ROOT/vendor/glfw/lib" "$ODIN_ROOT/vendor/stb/lib" 2>/dev/null || true

if [ -f "$DEPS_DIR/glfw_build_win/src/libglfw3.a" ]; then
    cp -f "$DEPS_DIR/glfw_build_win/src/libglfw3.a" "$ODIN_ROOT/vendor/glfw/lib/glfw3_mt.lib" 2>/dev/null || true
fi

if [ -d "$DEPS_DIR/stb_win_libs" ]; then
    cp -f "$DEPS_DIR/stb_win_libs/"*.lib "$ODIN_ROOT/vendor/stb/lib/" 2>/dev/null || true
fi

echo "==> Pre-built Windows dependencies restored successfully into $ODIN_ROOT."
