#!/usr/bin/env bash
# build_tracy_linux.sh — Build Tracy client & SIMD libraries for Linux CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sudo apt-get update -qq
sudo apt-get install -y -qq libgl1-mesa-dev >/dev/null

bash "$ROOT_DIR/scripts/build_tracy_lib.sh"
