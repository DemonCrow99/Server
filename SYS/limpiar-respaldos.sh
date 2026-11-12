#!/bin/bash
# Serverfitpower - Elimina los respaldos anteriores y conserva el más reciente
# (local en /srv/backups y remoto en Backblaze B2)
set -euo pipefail
source /etc/fitpower/fitpower.conf

[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo)."; exit 1; }
LOG=/var/log/fitpower-respaldo.log
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

mapfile -t locales < <(ls -1 "$DIR_BACKUPS"/fitpower_*.tar.gz 2>/dev/null | sort || true)
if [ "${#locales[@]}" -gt 1 ]; then
  for f in "${locales[@]:0:${#locales[@]}-1}"; do
    rm -f "$f" "$f.sha256"
    log "Eliminado local: $f"
  done
fi

if rclone listremotes | grep -q '^b2fitpower:$'; then
  mapfile -t remotos < <(rclone lsf "b2fitpower:$B2_BUCKET" --files-only | grep -E '^fitpower_.*\.tar\.gz$' | sort || true)
  if [ "${#remotos[@]}" -gt 1 ]; then
    for f in "${remotos[@]:0:${#remotos[@]}-1}"; do
      rclone deletefile "b2fitpower:$B2_BUCKET/$f"
      log "Eliminado remoto: $f"
    done
  fi
else
  log "Remoto b2fitpower no configurado: solo se limpió lo local"
fi
