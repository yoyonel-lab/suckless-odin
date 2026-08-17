#!/usr/bin/env bash
set -euo pipefail

# test_integration_e2e.sh — End-to-End Integration Test Scenario
# Runs a normalized 15s session: default config, HDR cycling x2, clean exit, frame count validation.

APP_BIN="${1:-./build/release/suckless-odin}"
if [ ! -f "$APP_BIN" ]; then
	echo "Info: $APP_BIN introuvable, tentative avec ./build/debug/suckless-odin"
	APP_BIN="./build/debug/suckless-odin"
	if [ ! -f "$APP_BIN" ]; then
		echo "Erreur: binaire $APP_BIN manquant. Lancez d'abord 'task build-release'."
		exit 1
	fi
fi

HEADLESS=false
for arg in "$@"; do
	if [ "$arg" == "--headless" ]; then
		HEADLESS=true
	fi
done

TMP_DIR=$(mktemp -d)
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

chmod +x ./scripts/interactive_runner.sh

echo "=========================================================================="
echo "🧪 TEST D'INTÉGRATION E2E — SCÉNARIO NORMALISÉ (15s Timebox)"
echo "=========================================================================="
echo "  Binaire       : $APP_BIN"
echo "  Mode          : $([ "$HEADLESS" = true ] && echo "Headless (Xvfb)" || echo "Display matériel ($DISPLAY)")"
echo "  Scénario      : Démarrage (4.5s) -> HDR Cycle #1 (4.5s) -> HDR Cycle #2 (4.5s) -> Escape (propre)"
echo "--------------------------------------------------------------------------"

if [ "$HEADLESS" = true ]; then
	if ! command -v xvfb-run >/dev/null 2>&1; then
		echo "Erreur: xvfb-run n'est pas installé."
		exit 1
	fi
	xvfb-run -n 99 -s "-screen 0 1920x1080x24" env TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh "$APP_BIN"
else
	env TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh "$APP_BIN"
fi

RUNNER_LOG_FILE=$(find "$TMP_DIR" -name "runner_app_*.log" 2>/dev/null | head -n1 || true)
if [ -z "$RUNNER_LOG_FILE" ] || [ ! -f "$RUNNER_LOG_FILE" ]; then
	echo "❌ ÉCHEC : Journal d'exécution introuvable."
	exit 1
fi

FRAMES=$(grep -oE "Total frames rendered during this run: [0-9]+" "$RUNNER_LOG_FILE" 2>/dev/null | awk '{print $NF}' | tail -n1 || echo "0")
echo "--------------------------------------------------------------------------"
echo "📊 RÉSULTAT DU SCÉNARIO D'INTÉGRATION :"
echo "  Total frames rendues : $FRAMES"

# Vérification du seuil minimal de frames (normalisation)
MIN_EXPECTED_FRAMES=100
if [ "$FRAMES" -ge "$MIN_EXPECTED_FRAMES" ]; then
	AVG_FPS=$(awk -v f="$FRAMES" 'BEGIN { printf "%.1f", f / 13.5 }')
	echo "  FPS moyen normalisé  : ~$AVG_FPS FPS"
	echo "✅ SUCCÈS : Le scénario s'est exécuté sans deadlock et a validé le débit minimal ($FRAMES >= $MIN_EXPECTED_FRAMES frames)."
	echo "=========================================================================="
	exit 0
else
	echo "❌ ÉCHEC : Nombre de frames insuffisant ($FRAMES < $MIN_EXPECTED_FRAMES)."
	cat "$RUNNER_LOG_FILE"
	echo "=========================================================================="
	exit 1
fi
