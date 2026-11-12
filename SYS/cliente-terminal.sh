#!/bin/bash
# Serverfitpower - Configuración de una terminal cliente (misma red local)
#   ./cliente-terminal.sh [ip_servidor]
set -euo pipefail
IP_SERVIDOR="${1:-192.168.1.3}"
NOMBRE="serverfitpower"

grep -q "$NOMBRE" /etc/hosts || echo "$IP_SERVIDOR $NOMBRE" | sudo tee -a /etc/hosts >/dev/null
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if ! grep -q "^Host $NOMBRE" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<EOF

Host $NOMBRE
    HostName $IP_SERVIDOR
    User administrador
    Port 22
EOF
fi
chmod 600 ~/.ssh/config
ping -c 2 "$NOMBRE"
echo "Conexión: ssh $NOMBRE"
