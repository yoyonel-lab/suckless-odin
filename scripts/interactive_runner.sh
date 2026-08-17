#!/usr/bin/env bash
set -euo pipefail

# interactive_runner.sh — Automation runner for profiling & integration sessions
# Launches the engine, targets the GLFW window, cycles HDR maps, animates camera, and closes cleanly.

TMP_DIR="${TMP_DIR:-/tmp}"
RUNNER_LOG="${TMP_DIR}/runner_app_${USER}_$$.log"

"$@" >"$RUNNER_LOG" 2>&1 &
APP_PID=$!

echo "[Runner] Application lancée (PID=$APP_PID). Recherche de la fenêtre GLFW..."

WINDOW_ID=""
for _ in {1..35}; do
	if ! kill -0 "$APP_PID" 2>/dev/null; then
		echo "[Runner] Erreur : Le processus de l'application s'est arrêté prématurément."
		cat "$RUNNER_LOG"
		exit 1
	fi
	WINDOW_ID=$(xdotool search --onlyvisible --name "Icosphere Phong" 2>/dev/null | head -n 1 || true)
	if [ -z "$WINDOW_ID" ]; then
		WINDOW_ID=$(xdotool search --onlyvisible --class "suckless-odin" 2>/dev/null | head -n 1 || true)
	fi
	if [ -n "$WINDOW_ID" ]; then
		break
	fi
	sleep 0.2
done

if [ -n "$WINDOW_ID" ]; then
	echo "[Runner] Fenêtre trouvée (WID=$WINDOW_ID). Activation..."
	xdotool windowfocus --sync "$WINDOW_ID" 2>/dev/null || true

	echo "[Runner] Attente 4.0s (initialisation moteur & premier bake IBL)..."
	sleep 4.0

	echo "[Runner] 🌍 Changement environnement HDR #1 (Touche Prior / Page_Up)..."
	xdotool key --window "$WINDOW_ID" Prior
	sleep 5.0

	echo "[Runner] 🎥 Déplacement caméra vers l'avant (Touche W)..."
	xdotool keydown --window "$WINDOW_ID" w
	sleep 1.2
	xdotool keyup --window "$WINDOW_ID" w
	sleep 1.0

	echo "[Runner] 🌍 Changement environnement HDR #2 (Touche Next / Page_Down)..."
	xdotool key --window "$WINDOW_ID" Next
	sleep 5.0

	echo "[Runner] 🚪 Fermeture propre via Escape..."
	xdotool key --window "$WINDOW_ID" Escape
else
	echo "[Runner] AVERTISSEMENT : Fenêtre introuvable. Envoi global de touches..."
	sleep 4.0
	xdotool key Prior || true
	sleep 5.0
	xdotool key Next || true
	sleep 5.0
	xdotool key Escape || true
fi

# Attente de la fermeture normale
for _ in {1..30}; do
	if ! kill -0 "$APP_PID" 2>/dev/null; then
		break
	fi
	sleep 0.2
done

# Si toujours en vie après Escape, fermeture contrôlée
if kill -0 "$APP_PID" 2>/dev/null; then
	echo "[Runner] Arrêt forcé du processus..."
	CHILD_PIDS=$(pgrep -P "$APP_PID" 2>/dev/null || echo "")
	kill -SIGTERM "$APP_PID" 2>/dev/null || true
	for CPID in $CHILD_PIDS; do
		kill -SIGTERM "$CPID" 2>/dev/null || true
	done
	sleep 1
	if kill -0 "$APP_PID" 2>/dev/null; then
		kill -SIGKILL "$APP_PID" 2>/dev/null || true
	fi
fi

wait "$APP_PID" 2>/dev/null || true
echo "[Runner] Session interactive terminée avec succès."
