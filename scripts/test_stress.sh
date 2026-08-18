#!/usr/bin/env bash
# =============================================================================
# STRESS TEST: High-Speed Async Pump (Fullscreen + HDR Spam + Smooth Camera)
# =============================================================================
# Spams fullscreen toggles and in-flight HDR environment changes at high speed
# without blocking/synchronous waits, while running a smooth continuous camera motion.
# Tests resilience against rapid user inputs, in-flight cancellation, and resize events.
#
# Usage:
#   ./scripts/test_stress.sh <path_to_app> [duration_sec] [action_delay_ms] [--headless]
#
# Examples:
#   ./scripts/test_stress.sh ./build/release/suckless-odin 15 60
#   ./scripts/test_stress.sh ./build/release/suckless-odin 10 50 --headless
# =============================================================================

set -eo pipefail

HEADLESS=false
POSITIONAL_ARGS=()
for arg in "$@"; do
	if [ "$arg" == "--headless" ]; then
		HEADLESS=true
	elif [ "$arg" == "--display" ]; then
		HEADLESS=false
	else
		POSITIONAL_ARGS+=("$arg")
	fi
done

APP_PATH="${POSITIONAL_ARGS[0]:-./build/release/suckless-odin}"
DURATION_SEC="${POSITIONAL_ARGS[1]:-15}"
ACTION_DELAY_MS="${POSITIONAL_ARGS[2]:-60}"

if [ ! -f "$APP_PATH" ]; then
	echo "Info: $APP_PATH introuvable, tentative avec ./build/debug/suckless-odin"
	APP_PATH="./build/debug/suckless-odin"
	if [ ! -f "$APP_PATH" ]; then
		echo "Erreur: Binaire $APP_PATH introuvable. Lancez d'abord 'task build-release'."
		exit 1
	fi
fi

# Re-exec under Xvfb if headless mode requested
if [ "$HEADLESS" = true ] && [ -z "${IN_XVFB:-}" ]; then
	if ! command -v xvfb-run >/dev/null 2>&1; then
		echo "Erreur: xvfb-run n'est pas installé."
		exit 1
	fi
	echo "→ Relancement sous environnement virtuel Xvfb..."
	exec xvfb-run -a -s "-screen 0 1024x768x24" env IN_XVFB=1 "$0" "$APP_PATH" "$DURATION_SEC" "$ACTION_DELAY_MS" --headless
fi

WINDOW_NAME="Icosphere Phong"
TMP_DIR=$(mktemp -d)
LOG_FILE="${TMP_DIR}/stress_unified_$$.log"
STACKS_FILE="${TMP_DIR}/stress_unified_$$.stacks"

trap 'rm -rf "$TMP_DIR"' EXIT
: >"$LOG_FILE"

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     HAUTE VITESSE : STRESS TEST FLUIDE & ASYNCHRONE          ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC} Binaire:     ${YELLOW}$APP_PATH${NC}"
echo -e "${CYAN}║${NC} Durée:       ${YELLOW}${DURATION_SEC}s (Spam continu non bloquant)${NC}"
echo -e "${CYAN}║${NC} Cadence:     ${YELLOW}Action toutes les ${ACTION_DELAY_MS}ms${NC}"
echo -e "${CYAN}║${NC} Scénario:    ${YELLOW}Spam Fullscreen + Spam HDR in-flight + Caméra smooth${NC}"
echo -e "${CYAN}║${NC} Mode:        ${YELLOW}$([ "$HEADLESS" = true ] && echo "Headless (Xvfb)" || echo "Display matériel ($DISPLAY)")${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# Launch application with Sanitizer options active
echo -e "\n${CYAN}[INIT]${NC} Démarrage du moteur..."
export ASAN_OPTIONS="exitcode=1:detect_leaks=1:symbolize=1:halt_on_error=0:verify_asan_link_order=0"
export LSAN_OPTIONS="suppressions=lsan.supp"
stdbuf -oL -eL "$APP_PATH" >"$LOG_FILE" 2>&1 &
APP_PID=$!

get_target_wid() {
	local wid=""
	wid=$(timeout 2 xdotool search --pid "$APP_PID" --onlyvisible 2>/dev/null | head -n 1 || true)
	if [ -z "$wid" ]; then
		wid=$(timeout 2 xdotool search --onlyvisible --name "$WINDOW_NAME" 2>/dev/null | head -n 1 || true)
	fi
	if [ -z "$wid" ]; then
		wid=$(timeout 2 xdotool search --name "$WINDOW_NAME" 2>/dev/null | head -n 1 || true)
	fi
	echo "$wid"
}

# Wait for process to spawn window
WID=""
for _ in {1..50}; do
	if ! kill -0 "$APP_PID" 2>/dev/null; then
		echo -e "${RED}[FATAL]${NC} L'application s'est arrêtée au démarrage."
		cat "$LOG_FILE"
		exit 1
	fi
	WID=$(get_target_wid)
	if [ -n "$WID" ]; then
		break
	fi
	sleep 0.05
done

if [ -n "$WID" ]; then
	timeout 2 xdotool windowactivate --sync "$WID" 2>/dev/null || timeout 2 xdotool windowfocus --sync "$WID" 2>/dev/null || true
fi

# Wait for initial boot
LOG_LINE_OFFSET=0
wait_for_log() {
	local pattern="$1"
	local timeout="$2"
	local start_time
	start_time=$(date +%s)
	while true; do
		if [ -f "$LOG_FILE" ]; then
			local match
			match=$(tail -n +"$((LOG_LINE_OFFSET + 1))" "$LOG_FILE" 2>/dev/null | grep -nE "$pattern" | head -n 1 || true)
			if [ -n "$match" ]; then
				local rel_line
				rel_line=$(echo "$match" | cut -d: -f1)
				LOG_LINE_OFFSET=$((LOG_LINE_OFFSET + rel_line))
				return 0
			fi
		fi
		if ! kill -0 "$APP_PID" 2>/dev/null; then return 1; fi
		local now
		now=$(date +%s)
		if (( now - start_time >= timeout )); then return 2; fi
		sleep 0.02
	done
}

echo -e "${CYAN}[INIT]${NC} Attente de l'initialisation du moteur..."
if ! wait_for_log "Application initialized" 10; then
	echo -e "${YELLOW}[WARN]${NC} Pas de log d'initialisation, poursuite..."
fi

echo -e "\n${CYAN}[START]${NC} Début du streaming d'actions haute vitesse (${DURATION_SEC}s)..."
echo ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SEC))

ACTION_COUNT=0
TOGGLE_COUNT=0
HDR_COUNT=0
CAM_RESET_COUNT=0
CRASH_DETECTED=false

CAM_DIRS=("w" "d" "s" "a" "q" "e")
CURRENT_CAM_DIR=""
CAM_TICKS=0

send_key() {
	local key="$1"
	local wid
	wid=$(get_target_wid)
	if [ -n "$wid" ]; then
		timeout 1 xdotool key --window "$wid" --delay 0 "$key" 2>/dev/null || true
	fi
}

send_keydown() {
	local key="$1"
	local wid
	wid=$(get_target_wid)
	if [ -n "$wid" ]; then
		timeout 1 xdotool keydown --window "$wid" "$key" 2>/dev/null || true
	fi
}

send_keyup() {
	local key="$1"
	local wid
	wid=$(get_target_wid)
	if [ -n "$wid" ]; then
		timeout 1 xdotool keyup --window "$wid" "$key" 2>/dev/null || true
	fi
}

# Initial cam direction
CURRENT_CAM_DIR="${CAM_DIRS[0]}"
send_keydown "$CURRENT_CAM_DIR"

TICK=0
while [ "$(date +%s)" -lt "$END_TIME" ]; do
	if ! kill -0 "$APP_PID" 2>/dev/null; then
		echo -e "\n${RED}[CRASH]${NC} L'application s'est arrêtée inopinément !"
		CRASH_DETECTED=true
		break
	fi

	TICK=$((TICK + 1))
	ACTION_COUNT=$((ACTION_COUNT + 1))

	# 1. Gestion continue et fluide de la caméra (changement toutes les 8 ticks ~ 0.5s)
	CAM_TICKS=$((CAM_TICKS + 1))
	if [ "$CAM_TICKS" -ge 8 ]; then
		send_keyup "$CURRENT_CAM_DIR"
		# Choisir nouvelle direction
		next_idx=$(( (TICK / 8) % ${#CAM_DIRS[@]} ))
		CURRENT_CAM_DIR="${CAM_DIRS[$next_idx]}"
		send_keydown "$CURRENT_CAM_DIR"
		CAM_TICKS=0
	fi

	# Retour régulier à la position initiale toutes les 24 ticks (~1.5s)
	if (( TICK % 24 == 0 )); then
		send_key "space"
		CAM_RESET_COUNT=$((CAM_RESET_COUNT + 1))
	fi

	# 2. Intercalage rapide : Plein écran ou switch HDR (Spam asynchrone continu)
	if (( TICK % 2 == 0 )); then
		# Spam toggle plein écran
		send_key "f"
		TOGGLE_COUNT=$((TOGGLE_COUNT + 1))
	else
		# Spam cycle HDR (en vol)
		if (( (TICK / 2) % 3 == 0 )); then
			send_key "Page_Up"
		else
			send_key "Page_Down"
		fi
		HDR_COUNT=$((HDR_COUNT + 1))
	fi

	# Cadence fluide
	sleep "$(awk "BEGIN{printf \"%.3f\", $ACTION_DELAY_MS/1000}")"

	# Affichage progression
	elapsed=$(( $(date +%s) - START_TIME ))
	if (( TICK % 20 == 0 )); then
		echo -e "${GREEN}[PUMP]${NC}   ${elapsed}s/${DURATION_SEC}s écoulées — Actions: $ACTION_COUNT (Bascule: $TOGGLE_COUNT, HDR: $HDR_COUNT, Cam Resets: $CAM_RESET_COUNT)"
	fi
done

# Release held camera key
if [ -n "$CURRENT_CAM_DIR" ]; then
	send_keyup "$CURRENT_CAM_DIR"
fi

# Final camera reset
send_key "space"
sleep 0.2

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        RÉSULTATS DU STRESS TEST HAUTE VITESSE                ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC} Durée totale:      ${TOTAL_ELAPSED}s"
echo -e "${CYAN}║${NC} Actions injectées: ${GREEN}$ACTION_COUNT${NC} (~$(( ACTION_COUNT / (TOTAL_ELAPSED > 0 ? TOTAL_ELAPSED : 1) )) actions/sec)"
echo -e "${CYAN}║${NC} Bascules écran:    ${GREEN}$TOGGLE_COUNT${NC}"
echo -e "${CYAN}║${NC} Switches HDR:      ${GREEN}$HDR_COUNT${NC}"
echo -e "${CYAN}║${NC} Resets caméra:     ${GREEN}$CAM_RESET_COUNT${NC}"
echo -e "${CYAN}║${NC} Crash détecté:     $(if $CRASH_DETECTED; then echo -e "${RED}OUI${NC}"; else echo -e "${GREEN}NON${NC}"; fi)"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# Clean shutdown
if kill -0 "$APP_PID" 2>/dev/null; then
	wid=$(get_target_wid)
	if [ -n "$wid" ]; then
		timeout 2 xdotool key --window "$wid" space 2>/dev/null || true
		timeout 2 xdotool key --window "$wid" Escape 2>/dev/null || true
	else
		kill -SIGTERM "$APP_PID" 2>/dev/null || true
	fi
	for _ in {1..40}; do
		if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
		sleep 0.05
	done
	if kill -0 "$APP_PID" 2>/dev/null; then
		kill -9 "$APP_PID" 2>/dev/null || true
	fi
fi

# Sanitizer checks
if grep -qE "ERROR: (Address|Leak|Thread|UndefinedBehavior)Sanitizer" "$LOG_FILE" 2>/dev/null; then
	echo -e "${RED}[FAIL]${NC} Erreurs Sanitizer détectées dans les logs !"
	grep -E "ERROR: (Address|Leak|Thread|UndefinedBehavior)Sanitizer" "$LOG_FILE" | head -n 10
	exit 1
fi

if $CRASH_DETECTED; then
	echo -e "\n${RED}─── DERNIERS LOGS AVANT L'ARRÊT ───${NC}"
	tail -n 30 "$LOG_FILE"
	echo -e "\n${RED}❌ ÉCHEC : Le stress test haute vitesse a détecté un crash.${NC}"
	exit 1
else
	echo -e "\n${GREEN}✅ SUCCÈS : Le stress test haute vitesse s'est terminé sans aucune erreur ni blocage ($ACTION_COUNT actions fluides).${NC}"
	exit 0
fi
