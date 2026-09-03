#!/usr/bin/env bash
# setup_win_toolchain.sh — Setup Windows cross-compilation toolchain and Wine environment on Ubuntu runner.
set -euo pipefail

WITH_PACKAGING="${1:-false}"

PACKAGES=(
    gcc-mingw-w64-x86-64
    g++-mingw-w64-x86-64
    clang-19
    lld-19
    llvm-19
    cmake
    git
    wine
    wine64
    libgl1-mesa-dev
    libgl1-mesa-dri
    xvfb
    python3-ply
    python3-pip
)

if [ "$WITH_PACKAGING" = "true" ]; then
    PACKAGES+=(zstd zip mesa-utils rsync imagemagick xdotool ffmpeg)
fi

SUDO=""
if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

$SUDO apt-get update -qq
$SUDO apt-get install -y -qq "${PACKAGES[@]}" >/dev/null

# Configure Clang-19 / LLVM-19 symlinks as default
$SUDO ln -sf /usr/bin/clang-19 /usr/bin/clang
$SUDO ln -sf /usr/bin/clang++-19 /usr/bin/clang++
$SUDO ln -sf /usr/bin/lld-19 /usr/bin/lld
$SUDO ln -sf /usr/bin/llvm-ar-19 /usr/bin/llvm-ar

# Initialize 64-bit Wine prefix quietly
WINEDEBUG=-all WINEARCH=win64 wineboot --init || true
echo "==> Windows cross-compilation toolchain configured successfully."
