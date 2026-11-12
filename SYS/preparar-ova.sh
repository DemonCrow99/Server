#!/bin/bash
# Serverfitpower - Limpieza final dentro de la VM antes de exportar el .OVA
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar con sudo."; exit 1; }

apt-get -y autoremove
apt-get -y clean
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -name '*.log' -exec truncate -s 0 {} \;
find /var/log -type f \( -name '*.gz' -o -name '*.1' \) -delete
rm -f /root/.bash_history /home/*/.bash_history
fstrim -av || true
sync
echo "VM lista. Apagar con: sudo poweroff"
