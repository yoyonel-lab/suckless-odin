#!/usr/bin/env bash
# =============================================================================
# STRESS TEST: Fullscreen ↔ Windowed Toggle
# =============================================================================
# Detects deadlocks and regressions by monitoring engine LOG OUTPUT.
#
# Detection strategy:
#   After each 'F' keypress, wait for the app to log either:
#     "Switched to fullscreen"  or  "Switched to windowed"
#   If the expected log line does NOT appear within TIMEOUT_SEC → DEADLOCK.
#
# Usage:
#   ./scripts/test_stress_fullscreen.sh <path_to_app> [iterations] [delay_ms] [--headless]
#
# Examples:
#   ./scripts/test_stress_fullscreen.sh ./build/release/suckless-odin 100 20
#   ./scripts/test_stress_fullscreen.sh ./build/release/suckless-odin 50 10 --headless
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
ITERATIONS="${POSITIONAL_ARGS[1]:-100}"
DELAY_MS="${POSITIONAL_ARGS[2]:-50}"

if [ ! -f "$APP_PATH" ]; then
	echo "Info: $APP_PATH introuvable, tentative avec ./build/debug/suckless-odin"
	APP_PATH="./build/debug/suckless-odin"
	if [ ! -f "$APP_PATH" ]; then
		echo "Erreur: Binaire $APP_PATH introuvable. Lancez d'abord 'task build-release'."
		exit 1
	fi
fi

# If headless requested and not already under Xvfb, re-exec under xvfb-run
if [ "$HEADLESS" = true ] && [ -z "${IN_XVFB:-}" ]; then
	if ! command -v xvfb-run >/dev/null 2>&1; then
		echo "Erreur: xvfb-run n'est pas installé."
		exit 1
	fi
	echo "→ Relancement sous environnement virtuel Xvfb..."
	exec xvfb-run -a -s "-screen 0 1024x768x24" env IN_XVFB=1 "$0" "$APP_PATH" "$ITERATIONS" "$DELAY_MS" --headless
fi

WINDOW_NAME="Icosphere Phong"
TMP_DIR=$(mktemp -d)
LOG_FILE="${TMP_DIR}/stress_fullscreen_$$.log"
STACKS_FILE="${TMP_DIR}/stress_fullscreen_$$.stacks"
TIMEOUT_SEC=5

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
echo -e "${CYAN}║           FULLSCREEN TOGGLE STRESS TEST                     ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC} Binaire:     ${YELLOW}$APP_PATH${NC}"
echo -e "${CYAN}║${NC} Itérations:  ${YELLOW}$ITERATIONS${NC}"
echo -e "${CYAN}║${NC} Délai inter: ${YELLOW}${DELAY_MS}ms${NC}"
echo -e "${CYAN}║${NC} Timeout:     ${YELLOW}${TIMEOUT_SEC}s par bascule${NC}"
echo -e "${CYAN}║${NC} Mode:        ${YELLOW}$([ "$HEADLESS" = true ] && echo "Headless (Xvfb)" || echo "Display matériel ($DISPLAY)")${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# Launch application
echo -e "\n${CYAN}[INIT]${NC} Démarrage du moteur..."
export ASAN_OPTIONS="exitcode=1:detect_leaks=1:symbolize=1:halt_on_error=0:verify_asan_link_order=0"
export LSAN_OPTIONS="suppressions=lsan.supp"
stdbuf -oL -eL "$APP_PATH" >"$LOG_FILE" 2>&1 &
APP_PID=$!

get_target_wid() {
	local wid=""
	# 1. Recherche par PID du processus (précision maximale)
	wid=$(timeout 2 xdotool search --pid "$APP_PID" --onlyvisible 2>/dev/null | head -n 1 || true)
	if [ -z "$wid" ]; then
		# 2. Recherche par nom exact de fenêtre
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

# Wait for initial engine IBL baking to finish (event-driven)
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
		if ! kill -0 "$APP_PID" 2>/dev/null; then
			return 1 # Crash
		fi
		local now
		now=$(date +%s)
		if (( now - start_time >= timeout )); then
			return 2 # Timeout (Hang)
		fi
		sleep 0.02
	done
}

echo -e "${CYAN}[INIT]${NC} Attente de l'initialisation de l'application..."
if ! wait_for_log "Application initialized" 10; then
	echo -e "${YELLOW}[WARN]${NC} Pas de log d'initialisation explicite, poursuite..."
fi

echo -e "\n${CYAN}[START]${NC} Début du test de stress : $ITERATIONS cycles de bascule plein écran/fenêtré"
echo ""

SUCCESS_COUNT=0
HANG_COUNT=0
CRASH_DETECTED=false
START_TIME=$(date +%s)
EXPECT_FULLSCREEN=true

capture_stacks() {
	local iteration=$1
	local direction=$2
	echo -e "${YELLOW}[DIAG]${NC} Capture des traces d'exécution (Itération $iteration, $direction)..."
	{
		echo "============================================================"
		echo "DEADLOCK à l'itération $iteration ($direction)"
		echo "Timestamp: $(date -Iseconds)"
		echo "PID: $APP_PID"
		echo "============================================================"
	} >>"$STACKS_FILE"

	if command -v gdb &>/dev/null; then
		gdb -batch \
			-ex "set pagination off" \
			-ex "thread apply all bt full" \
			-ex "info threads" \
			-ex "detach" \
			-p "$APP_PID" 2>/dev/null >>"$STACKS_FILE" || true
	else
		for tid_dir in /proc/"$APP_PID"/task/*/; do
			tid=$(basename "$tid_dir")
			echo "--- Thread $tid stack ---" >>"$STACKS_FILE"
			cat /proc/"$APP_PID"/task/"$tid"/stack 2>/dev/null >>"$STACKS_FILE" || true
		done
	fi
}

send_toggle_key() {
	local wid
	wid=$(get_target_wid)
	if [ -n "$wid" ]; then
		timeout 2 xdotool windowfocus "$wid" 2>/dev/null || true
		timeout 2 xdotool key --window "$wid" --delay 0 f 2>/dev/null || true
	fi
}

for ((i = 1; i <= ITERATIONS; i++)); do
	if ! kill -0 "$APP_PID" 2>/dev/null; then
		echo -e "${RED}[CRASH]${NC} L'application a crashé à l'itération $i / $ITERATIONS"
		CRASH_DETECTED=true
		break
	fi

	# Send toggle key strictly to the target window
	send_toggle_key

	if [ "$DELAY_MS" -gt 0 ]; then
		sleep "$(awk "BEGIN{printf \"%.3f\", $DELAY_MS/1000}")"
	fi

	# Wait for event acknowledgment in logs (either direction)
	status=0
	wait_for_log "Switched to (fullscreen|windowed)" "$TIMEOUT_SEC" || status=$?

	if [ $status -eq 1 ]; then
		echo -e "${RED}[CRASH]${NC} Crash détecté pendant la bascule #$i"
		CRASH_DETECTED=true
		break
	elif [ $status -eq 2 ]; then
		if kill -0 "$APP_PID" 2>/dev/null; then
			HANG_COUNT=$((HANG_COUNT + 1))
			echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
			echo -e "${RED}║  DEADLOCK DÉTECTÉ à la bascule #$i${NC}"
			echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
			echo -e "${RED}[HANG]${NC} L'application est active (PID $APP_PID) mais n'a pas répondu dans le délai imparti."

			capture_stacks "$i" "Toggle"
			kill -9 "$APP_PID" 2>/dev/null || true
			break
		else
			echo -e "${RED}[CRASH]${NC} L'application s'est arrêtée inopinément."
			CRASH_DETECTED=true
			break
		fi
	fi

	SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

	if (((i * 2) % 20 == 0)) || ((i == ITERATIONS)); then
		elapsed=$(($(date +%s) - START_TIME))
		echo -e "${GREEN}[OK]${NC}    Bascule $i / $ITERATIONS réussie (${elapsed}s écoulées, ${SUCCESS_COUNT} complétées)"
	fi
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                RÉSULTATS DU STRESS TEST                      ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC} Bascules réussies: ${GREEN}$SUCCESS_COUNT${NC} / $((ITERATIONS))"
echo -e "${CYAN}║${NC} Blocages (hangs):  $(if [ $HANG_COUNT -gt 0 ]; then echo -e "${RED}$HANG_COUNT${NC}"; else echo -e "${GREEN}0${NC}"; fi)"
echo -e "${CYAN}║${NC} Crash détecté:     $(if $CRASH_DETECTED; then echo -e "${RED}OUI${NC}"; else echo -e "${GREEN}NON${NC}"; fi)"
echo -e "${CYAN}║${NC} Temps total:       ${TOTAL_TIME}s"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# Clean shutdown
if kill -0 "$APP_PID" 2>/dev/null; then
	wid=$(get_target_wid)
	if [ -n "$wid" ]; then
		timeout 2 xdotool windowfocus "$wid" 2>/dev/null || true
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

if [ -f "$STACKS_FILE" ] && [ -s "$STACKS_FILE" ]; then
	echo -e "\n${YELLOW}─── TRACES DU DEADLOCK ───${NC}"
	cat "$STACKS_FILE"
fi

if $CRASH_DETECTED || [ $HANG_COUNT -gt 0 ]; then
	echo -e "\n${RED}─── DERNIERS LOGS AVANT L'ARRÊT ───${NC}"
	tail -n 30 "$LOG_FILE"
	echo -e "\n${RED}❌ ÉCHEC : Le test de stress fullscreen a échoué.${NC}"
	exit 1
else
	echo -e "\n${GREEN}✅ SUCCÈS : Le test de stress fullscreen s'est terminé sans aucune erreur ($SUCCESS_COUNT bascules).${NC}"
	exit 0
fi
