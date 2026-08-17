#!/usr/bin/env bash
set -euo pipefail

# benchmark_tracy.sh — Automated Tracy capture and verification for suckless-odin
# (ISO parity with suckless-vulkan benchmark-tracy)

TMP_DIR="${TMP_DIR:-/tmp}"
OUTPUT_DIR="build/profiling/tracy"
mkdir -p "$OUTPUT_DIR"

TRACE_FILE="$OUTPUT_DIR/session.tracy"
rm -f "$TRACE_FILE"

echo "=========================================================================="
echo "🎯 BENCHMARK & CAPTURE TRACY PROFILER"
echo "=========================================================================="

TRACY_CAPTURE_BIN="deps/tracy/capture/build/tracy-capture"
if [ ! -x "$TRACY_CAPTURE_BIN" ]; then
	TRACY_CAPTURE_BIN=$(which tracy-capture || echo "/home/latty/.local/bin/tracy-capture")
fi
if [ ! -x "$TRACY_CAPTURE_BIN" ]; then
	echo "❌ Erreur: tracy-capture introuvable. Lancez 'task build-tracy-tools'."
	exit 1
fi

# 1. Démarrer le serveur de capture Tracy en arrière-plan
echo "[Tracy] Démarrage du serveur de capture (16s timebox)..."
"$TRACY_CAPTURE_BIN" -o "$TRACE_FILE" -s 16 -f >"$TMP_DIR/tracy_capture.log" 2>&1 &
CAPTURE_PID=$!
sleep 1

# 2. Lancer la session interactive sous build-profile
echo "[Tracy] Lancement de l'application instrumentée..."
TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh ./build/profile/suckless-odin

# 3. Attendre la fin de la capture
echo "[Tracy] Finalisation du fichier trace..."
wait "$CAPTURE_PID" 2>/dev/null || true

if [ ! -f "$TRACE_FILE" ]; then
	echo "❌ Échec: Le fichier trace $TRACE_FILE n'a pas été généré."
	cat "$TMP_DIR/tracy_capture.log"
	exit 1
fi

TRACE_SIZE=$(stat -c%s "$TRACE_FILE" 2>/dev/null || stat -f%z "$TRACE_FILE" 2>/dev/null)
echo "✅ Trace générée : $TRACE_FILE ($(( TRACE_SIZE / 1024 )) KB)"

# 4. Vérification et assertion programmatique de la trace
python3 scripts/verify_tracy_trace.py "$TRACE_FILE"
