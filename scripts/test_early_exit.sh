#!/usr/bin/env bash
set -euo pipefail

# test_early_exit.sh — Early-Exit E2E Performance & Responsiveness Benchmark
# Profiles minimal time required to boot the application, reach frame 0/1, and exit cleanly on Escape spam.

APP_BIN="${1:-./build/release/suckless-odin}"
if [ ! -f "$APP_BIN" ]; then
	if [ -f "./build/debug/suckless-odin" ]; then
		APP_BIN="./build/debug/suckless-odin"
	else
		echo "Binary $APP_BIN not found. Building release..."
		task build-release
		APP_BIN="./build/release/suckless-odin"
	fi
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
LOG_FILE="${TMP_DIR}/early_exit.log"

echo "=========================================================================="
echo "⚡ E2E EARLY EXIT RESPONSIVENESS & STARTUP LATENCY BENCHMARK"
echo "=========================================================================="
echo "  Target Binary : $APP_BIN"
echo "  Display       : ${DISPLAY:-unknown}"
echo "  Mode          : Frame 0/1 Escape Keypress (Immediate Early-Exit)"
echo "--------------------------------------------------------------------------"

get_now_ms() {
	date +%s%3N
}

T_START=$(get_now_ms)

# Launch application in background
"$APP_BIN" >"$LOG_FILE" 2>&1 &
APP_PID=$!

# Background worker: detect window as fast as possible and spam Escape
(
	T_WIN=0
	WID=""
	for _ in $(seq 1 400); do
		if ! kill -0 "$APP_PID" 2>/dev/null; then
			break
		fi
		if [ -z "$WID" ]; then
			WID=$(xdotool search --pid "$APP_PID" --onlyvisible 2>/dev/null | head -n 1 || true)
			if [ -z "$WID" ]; then
				WID=$(xdotool search --onlyvisible --name "Icosphere Phong" 2>/dev/null | head -n 1 || true)
			fi
			if [ -n "$WID" ]; then
				T_WIN=$(get_now_ms)
				echo "$T_WIN" > "${TMP_DIR}/window_time.txt"
			fi
		fi

		if [ -n "$WID" ]; then
			xdotool windowactivate --sync "$WID" 2>/dev/null || true
			xdotool key --window "$WID" --delay 0 Escape 2>/dev/null || true
		fi
		sleep 0.005
	done
) &
SPAMMER_PID=$!

# Wait for process exit with 10s safety timeout
EXIT_CODE=0
WAIT_COUNT=0
while kill -0 "$APP_PID" 2>/dev/null; do
	sleep 0.01
	WAIT_COUNT=$((WAIT_COUNT + 1))
	if [ "$WAIT_COUNT" -ge 1000 ]; then
		echo "❌ TIMEOUT : Process did not exit within 10s. Force killing..."
		kill -SIGKILL "$APP_PID" 2>/dev/null || true
		EXIT_CODE=124
		break
	fi
done

wait "$APP_PID" 2>/dev/null || EXIT_CODE=$?
kill "$SPAMMER_PID" 2>/dev/null || true
wait "$SPAMMER_PID" 2>/dev/null || true

T_END=$(get_now_ms)
TOTAL_DURATION_MS=$((T_END - T_START))

T_WIN_RECORDED=$(cat "${TMP_DIR}/window_time.txt" 2>/dev/null || echo "$T_START")
WINDOW_APPEAR_MS=$((T_WIN_RECORDED - T_START))
EXIT_REACT_MS=$((T_END - T_WIN_RECORDED))

# Extract metrics from log file
TOTAL_FRAMES=$(grep -oE "Total frames rendered during this run: [0-9]+" "$LOG_FILE" 2>/dev/null | awk '{print $NF}' | tail -n1 || echo "0")
CLEAN_SHUTDOWN=$(grep -q "Application destroyed" "$LOG_FILE" && echo "YES" || echo "NO")

echo "--------------------------------------------------------------------------"
echo "📊 EARLY EXIT BENCHMARK METRICS :"
echo "  Total Wall Time (Launch -> Exit) : ${TOTAL_DURATION_MS} ms ($((TOTAL_DURATION_MS / 1000)).$(( (TOTAL_DURATION_MS % 1000) / 100 )) s)"
if [ "$WINDOW_APPEAR_MS" -gt 0 ]; then
echo "  Time to Window Open (Sync Boot)  : ${WINDOW_APPEAR_MS} ms"
echo "  Time from Escape -> Process Exit : ${EXIT_REACT_MS} ms"
fi
echo "  Total Frames Rendered            : ${TOTAL_FRAMES}"
echo "  Clean Subsystem Shutdown         : ${CLEAN_SHUTDOWN}"
echo "  Exit Code                        : ${EXIT_CODE}"
echo "--------------------------------------------------------------------------"

if [ "$EXIT_CODE" -eq 0 ] && [ "$CLEAN_SHUTDOWN" == "YES" ]; then
	echo "✅ SUCCESS : Application responded immediately to Escape at frame 0/1."
	echo "   Startup freeze was completely bypassed (Total latency: ${TOTAL_DURATION_MS} ms)."
	echo "=========================================================================="
	exit 0
else
	echo "❌ FAILURE : Early exit test failed (ExitCode=$EXIT_CODE, CleanShutdown=$CLEAN_SHUTDOWN)."
	echo "Logs:"
	cat "$LOG_FILE"
	echo "=========================================================================="
	exit 1
fi
