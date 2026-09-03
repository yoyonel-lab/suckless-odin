#!/usr/bin/env bash
# Test packaged Windows release integrity in an isolated sandbox directory.
set -euo pipefail

VERSION="${1:-v0.1.0}"
RELEASE_BASE_DIR="build-release"
ARCHIVE_PATH="${RELEASE_BASE_DIR}/suckless-odin-windows-${VERSION}.tar.zst"

if [ ! -f "${ARCHIVE_PATH}" ]; then
    echo "==> Archive ${ARCHIVE_PATH} not found. Running package_win.sh..."
    ./scripts/package_win.sh "${VERSION}"
fi

TMP_DIR="$(mktemp -d /tmp/suckless-odin-pkg-test-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Extracting ${ARCHIVE_PATH} into sandbox (${TMP_DIR})..."
tar -I zstd -xf "${ARCHIVE_PATH}" -C "${TMP_DIR}"

EXTRACTED_DIR="${TMP_DIR}/suckless-odin-windows-${VERSION}"
if [ ! -d "${EXTRACTED_DIR}" ]; then
    echo "Error: Extracted directory not found at ${EXTRACTED_DIR}"
    exit 1
fi

WINE_CMD="$(command -v wine 2>/dev/null || command -v wine64 2>/dev/null || echo "wine")"

echo "==> Testing version banner under Wine..."
(
    cd "${EXTRACTED_DIR}"
    WINEDEBUG=-all "$WINE_CMD" suckless-odin.exe -v
)

echo "==> Testing headless standalone benchmark under Wine (20 frames)..."
(
    cd "${EXTRACTED_DIR}"
    export WINEDEBUG=-all
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
    export MESA_GL_VERSION_OVERRIDE=4.5
    export MESA_GLSL_VERSION_OVERRIDE=450

    if [ -n "${CI:-}" ] || [ -z "${DISPLAY:-}" ] || (! command -v xdpyinfo >/dev/null 2>&1) || (! xdpyinfo >/dev/null 2>&1); then
        if command -v xvfb-run >/dev/null 2>&1; then
            xvfb-run -a -s "-screen 0 1024x768x24" "$WINE_CMD" suckless-odin.exe --benchmark --benchmark-frames=20
        else
            "$WINE_CMD" suckless-odin.exe --benchmark --benchmark-frames=20
        fi
    else
        "$WINE_CMD" suckless-odin.exe --benchmark --benchmark-frames=20
    fi
)

echo "[✓] Standalone Windows package test PASSED!"
