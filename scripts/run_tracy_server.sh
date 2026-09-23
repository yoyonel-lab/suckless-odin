#!/usr/bin/env bash
set -euo pipefail

PROFILER_BIN="deps/tracy/profiler/build/tracy-profiler"

if [ ! -x "$PROFILER_BIN" ]; then
    echo "❌ Erreur: $PROFILER_BIN introuvable. Lancez 'task build-tracy-server'."
    exit 1
fi

# Résolution automatique du port Tracy réel dans la plage canonique [8086..8105]
RESOLVED_PORT=$(python3 - << 'EOF'
import socket

def resolve_tracy_port():
    for p in range(8086, 8106):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.1)
        res = s.connect_ex(('127.0.0.1', p))
        s.close()
        if res == 0:
            # Port occupé : vérifie si c'est un client Tracy en écoute
            try:
                probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                probe.settimeout(0.2)
                probe.connect(('127.0.0.1', p))
                probe.sendall(b'TracyPrf\x4c\x00\x00\x00')
                resp = probe.recv(4)
                probe.close()
                if resp == b'\x00\x00\x00\x00':
                    return p # Client Tracy trouvé sur ce port
            except Exception:
                pass
            # Port occupé par un autre service (ex: Docker HTTP), on teste le suivant
            continue
        else:
            # Premier port libre : c'est celui que le client Tracy sélectionnera
            return p
    return 8086

print(resolve_tracy_port())
EOF
)

echo "[Tracy Server] Port Tracy cible identifié : $RESOLVED_PORT"
echo "[Tracy Server] Lancement de Tracy Profiler (auto-connexion sur 127.0.0.1:$RESOLVED_PORT)..."
exec "$PROFILER_BIN" -a 127.0.0.1 -p "$RESOLVED_PORT" "$@"
