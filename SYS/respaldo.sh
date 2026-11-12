#!/bin/bash
# Serverfitpower - Respaldo de base de datos + programa + configuración
#   respaldo.sh           respaldo local en /srv/backups
#   respaldo.sh --subir   respaldo local y copia a Backblaze B2
set -euo pipefail
source /etc/fitpower/fitpower.conf

[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo)."; exit 1; }

LOG=/var/log/fitpower-respaldo.log
FECHA="$(date +%Y%m%d_%H%M%S)"
ARCHIVO="$DIR_BACKUPS/fitpower_$FECHA.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

log "Inicio de respaldo"
mariadb-dump --single-transaction --routines --databases "$DB_NOMBRE" > "$TMP/db.sql"
tar -czf "$ARCHIVO" -C "$TMP" db.sql \
    -C / "${DIR_WEB#/}" etc/apache2 etc/nftables.conf etc/ssh/sshd_config.d etc/sudoers.d/subadmin
sha256sum "$ARCHIVO" > "$ARCHIVO.sha256"
chown root:administrador "$ARCHIVO" "$ARCHIVO.sha256"
chmod 640 "$ARCHIVO" "$ARCHIVO.sha256"
log "Respaldo local creado: $ARCHIVO"

if [ "${1:-}" = "--subir" ]; then
  if rclone listremotes | grep -q '^b2fitpower:$'; then
    rclone copyto "$ARCHIVO" "b2fitpower:$B2_BUCKET/$(basename "$ARCHIVO")"
    log "Respaldo subido a b2fitpower:$B2_BUCKET"
  else
    log "ERROR: remoto b2fitpower no configurado"
    exit 2
  fi
fi
log "Fin de respaldo"
