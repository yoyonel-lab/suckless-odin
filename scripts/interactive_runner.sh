#!/usr/bin/env bash
set -euo pipefail

# interactive_runner.sh — Event-driven automation runner for profiling & integration sessions
# Launches the engine, captures application log events, triggers inputs synchronously with state machine,
# and exits cleanly without arbitrary sleep delays.

TMP_DIR="${TMP_DIR:-/tmp}"
RUNNER_LOG="${TMP_DIR}/runner_app_${USER}_$$.log"
rm -f "$RUNNER_LOG"
touch "$RUNNER_LOG"

LOG_LINE_OFFSET=0

# Log synchronization helper: waits for a pattern appearing in log lines produced after LOG_LINE_OFFSET
wait_for_next_log() {
	local pattern="$1"
	local timeout="${2:-120}"
	local desc="${3:-$pattern}"
	local start_time
	start_time=$(date +%s)

	while true; do
		if [ -f "$RUNNER_LOG" ]; then
			local match
			match=$(tail -n +"$((LOG_LINE_OFFSET + 1))" "$RUNNER_LOG" 2>/dev/null | grep -nE "$pattern" | head -n 1 || true)
			if [ -n "$match" ]; then
				local rel_line
				rel_line=$(echo "$match" | cut -d: -f1)
				LOG_LINE_OFFSET=$((LOG_LINE_OFFSET + rel_line))
				return 0
			fi
		fi

		if ! kill -0 "$APP_PID" 2>/dev/null; then
			echo "[Runner] Erreur : L'application s'est arrêtée inopinément pendant l'attente de: $desc"
			cat "$RUNNER_LOG"
			exit 1
		fi

		local now
		now=$(date +%s)
		if (( now - start_time >= timeout )); then
			echo "[Runner] Avertissement : Timeout ($timeout s) atteint pour: $desc"
			LOG_LINE_OFFSET=$(wc -l <"$RUNNER_LOG" 2>/dev/null || echo "$LOG_LINE_OFFSET")
			return 1
		fi
		sleep 0.05
	done
}

"$@" >"$RUNNER_LOG" 2>&1 &
APP_PID=$!

echo "[Runner] Application lancée (PID=$APP_PID). Recherche de la fenêtre GLFW..."

WINDOW_ID=""
for _ in {1..50}; do
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
	sleep 0.05
done

activate_window() {
	if [ -n "$WINDOW_ID" ]; then
		xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || xdotool windowfocus --sync "$WINDOW_ID" 2>/dev/null || true
	fi
}

send_key() {
	local key="$1"
	if [ -n "$WINDOW_ID" ]; then
		xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || true
		xdotool key --window "$WINDOW_ID" "$key" 2>/dev/null || true
	fi
	xdotool key "$key" 2>/dev/null || true
}


if [ -n "$WINDOW_ID" ]; then
	echo "[Runner] Fenêtre trouvée (WID=$WINDOW_ID). Activation..."
	activate_window
else
	echo "[Runner] AVERTISSEMENT : Fenêtre introuvable. Mode injection globale actif..."
fi

echo "[Runner] ⏳ Attente initialisation moteur & premier bake IBL (State -> Idle)..."
wait_for_next_log "Transition state: .* -> Idle" 120 "Initialisation IBL Idle"

echo "[Runner] 🌍 Changement environnement HDR #1 (Touche Page_Up)..."
send_key "Page_Up"
wait_for_next_log "Transition state: .* -> Idle" 120 "Bake HDR #1 Idle"

echo "[Runner] 🎥 Déplacement caméra vers l'avant (Touche W)..."
if [ -n "$WINDOW_ID" ]; then
	xdotool keydown --window "$WINDOW_ID" w 2>/dev/null || xdotool keydown w 2>/dev/null || true
else
	xdotool keydown w 2>/dev/null || true
fi
sleep 1.0
if [ -n "$WINDOW_ID" ]; then
	xdotool keyup --window "$WINDOW_ID" w 2>/dev/null || xdotool keyup w 2>/dev/null || true
else
	xdotool keyup w 2>/dev/null || true
fi

echo "[Runner] 🌍 Changement environnement HDR #2 (Touche Page_Down)..."
send_key "Page_Down"
wait_for_next_log "Transition state: .* -> Idle" 120 "Bake HDR #2 Idle"

echo "[Runner] 🚪 Fermeture propre via Escape..."
send_key "Escape"

# Attente de la fermeture normale
for _ in {1..80}; do
	if ! kill -0 "$APP_PID" 2>/dev/null; then
		break
	fi
	sleep 0.1
done



# Arrêt forcé de sécurité si l'application ne s'est pas fermée
if kill -0 "$APP_PID" 2>/dev/null; then
	echo "[Runner] Arrêt forcé du processus..."
	CHILD_PIDS=$(pgrep -P "$APP_PID" 2>/dev/null || echo "")
	kill -SIGTERM "$APP_PID" 2>/dev/null || true
	for CPID in $CHILD_PIDS; do
		kill -SIGTERM "$CPID" 2>/dev/null || true
	done
	sleep 0.5
	if kill -0 "$APP_PID" 2>/dev/null; then
		kill -SIGKILL "$APP_PID" 2>/dev/null || true
	fi
fi

wait "$APP_PID" 2>/dev/null || true
echo "[Runner] Session interactive terminée avec succès."

