#!/usr/bin/env bash
set -euo pipefail

# benchmark_tracy.sh — Automated Tracy capture and verification for suckless-odin
# (ISO parity with suckless-vulkan benchmark-tracy)

TMP_DIR="${TMP_DIR:-/tmp}"
OUTPUT_DIR="build/profiling/tracy"
mkdir -p "$OUTPUT_DIR"

TARGET_MODE="${1:-linux}"
if [ "$TARGET_MODE" = "--win" ] || [ "$TARGET_MODE" = "win" ]; then
	APP_CMD=(wine ./build/profile-win/suckless-odin.exe)
	TRACE_FILE="$OUTPUT_DIR/session_win.tracy"
	TARGET_NAME="Windows x64 (Wine / Proton)"
else
	APP_CMD=(./build/profile/suckless-odin)
	TRACE_FILE="$OUTPUT_DIR/session.tracy"
	TARGET_NAME="Linux Native x86_64"
fi
rm -f "$TRACE_FILE"

echo "=========================================================================="
echo "🎯 BENCHMARK & CAPTURE TRACY PROFILER — $TARGET_NAME"
echo "=========================================================================="

TRACY_CAPTURE_BIN="deps/tracy/capture/build/tracy-capture"
if [ ! -x "$TRACY_CAPTURE_BIN" ]; then
	TRACY_CAPTURE_BIN=$(which tracy-capture || echo "$HOME/.local/bin/tracy-capture")
fi
if [ ! -x "$TRACY_CAPTURE_BIN" ]; then
	echo "❌ Erreur: tracy-capture introuvable. Lancez 'task build-tracy-tools'."
	exit 1
fi

export TRACY_CAPTURE_BIN
export TRACY_TRACE_FILE="$TRACE_FILE"

# 1. Lancer la session interactive instrumentée (tracy-capture démarre de manière synchrone dès que l'app est prête)
echo "[Tracy] Lancement de l'application instrumentée ($TARGET_NAME)..."
TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh "${APP_CMD[@]}"

if [ ! -f "$TRACE_FILE" ]; then
	echo "❌ Échec: Le fichier trace $TRACE_FILE n'a pas été généré."
	if [ -f "$TMP_DIR/tracy_capture.log" ]; then
		cat "$TMP_DIR/tracy_capture.log"
	fi
	exit 1
fi

TRACE_SIZE=$(stat -c%s "$TRACE_FILE" 2>/dev/null || stat -f%z "$TRACE_FILE" 2>/dev/null)
echo "✅ Trace générée : $TRACE_FILE ($(( TRACE_SIZE / 1024 )) KB)"

# 2. Vérification et assertion programmatique de la trace
python3 scripts/verify_tracy_trace.py "$TRACE_FILE"
