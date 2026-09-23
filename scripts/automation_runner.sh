#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="${TMP_DIR:-/tmp}"
AUTO_SOCK="/tmp/suckless_odin_$$.sock"
TRACY_LOG="${TMP_DIR}/tracy_capture.log"
PORT_FILE="/tmp/suckless_odin_tracy.port"

cleanup() {
    rm -f "$AUTO_SOCK"
}
trap cleanup EXIT INT TERM

APP_CMD=("${@}")
APP_CMD+=("--automation-socket=$AUTO_SOCK")

echo "[Runner] Lancement de l'application..."
"${APP_CMD[@]}" >"${TMP_DIR}/app_auto_$$.log" 2>&1 &
APP_PID=$!

TRACY_PID=""
if [ -n "${TRACY_CAPTURE_BIN:-}" ] && [ -n "${TRACY_TRACE_FILE:-}" ]; then
    echo "[Runner] Détection dynamique du port d'écoute Tracy..."
    TRACY_PORT=""
    for _ in {1..50}; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "❌ Erreur: L'application s'est arrêtée inopinément au démarrage."
            cat "${TMP_DIR}/app_auto_$$.log" 2>/dev/null || true
            exit 1
        fi
        DETECTED=$( (ss -tlpn 2>/dev/null || true) | (grep "pid=${APP_PID}," || true) | awk '{print $4}' | awk -F: '{print $NF}' | head -n1 )
        if [ -n "$DETECTED" ]; then
            TRACY_PORT="$DETECTED"
            break
        fi
        sleep 0.1
    done

    if [ -z "$TRACY_PORT" ]; then
        echo "❌ Erreur: Impossible de détecter le port Tracy pour PID $APP_PID"
        exit 1
    fi

    echo "[Runner] Port Tracy détecté dynamiquement : $TRACY_PORT"
    echo "[Runner] Démarrage de tracy-capture sur le port $TRACY_PORT..."
    rm -f "$TRACY_LOG"
    stdbuf -oL "$TRACY_CAPTURE_BIN" -a 127.0.0.1 -p "$TRACY_PORT" -o "$TRACY_TRACE_FILE" -s 60 -f >"$TRACY_LOG" 2>&1 &
    TRACY_PID=$!

    echo "[Runner] Attente connexion active de tracy-capture..."
    TRACY_CONNECTED=false
    for _ in {1..100}; do
        if ss -tan "( sport = :$TRACY_PORT or dport = :$TRACY_PORT )" 2>/dev/null | grep -q "ESTAB"; then
            echo "[Runner] Tracy Profiler connecté avec succès (socket ESTABLISHED)."
            TRACY_CONNECTED=true
            break
        fi
        if ! kill -0 "$TRACY_PID" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    if [ "$TRACY_CONNECTED" = false ]; then
        echo "❌ Erreur : tracy-capture n'a pas pu finaliser la connexion."
        cat "$TRACY_LOG" 2>/dev/null || true
        exit 1
    fi
    sleep 0.5 # Laisse la poignée de main initiale finaliser l'enregistrement
fi

echo "[Runner] Exécution du script client Python via UNIX socket..."
python3 scripts/automation_client.py "$AUTO_SOCK"

if [ -n "$TRACY_PID" ]; then
    echo "[Runner] Attente de la finalisation de la trace Tracy..."
    wait "$TRACY_PID" 2>/dev/null || true
fi

wait "$APP_PID" 2>/dev/null || true
echo "[Runner] Session automatisée terminée avec succès."
