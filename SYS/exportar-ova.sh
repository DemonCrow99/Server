#!/bin/bash
# Serverfitpower - Exportación a .OVA (se ejecuta en el equipo anfitrión)
#   ./exportar-ova.sh [nombre_vm] [archivo_salida]
set -euo pipefail
VM="${1:-Serverfitpower}"
SALIDA="${2:-Serverfitpower.ova}"

if VBoxManage list runningvms | grep -q "\"$VM\""; then
  VBoxManage controlvm "$VM" acpipowerbutton
  while VBoxManage list runningvms | grep -q "\"$VM\""; do sleep 3; done
fi

VBoxManage export "$VM" --output "$SALIDA" --ovf20 --manifest \
  --vsys 0 --product "Serverfitpower" --version "1.0" \
  --description "Servidor Linux Mint 22.3 LTS: Apache, MariaDB, nftables, SSH, respaldos"
echo "Generado: $SALIDA"
