#!/bin/bash
# Serverfitpower - Validación integral del sistema
#   validar.sh            verificaciones
#   validar.sh --respaldo además crea un respaldo local de prueba
source /etc/fitpower/fitpower.conf
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar con sudo."; exit 1; }

LOG=/var/log/fitpower-validacion.log
exec > >(tee "$LOG") 2>&1

OK=0; FALLO=0
chk() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '[ OK  ] %s\n' "$d"; OK=$((OK+1))
  else printf '[FALLO] %s\n' "$d"; FALLO=$((FALLO+1)); fi
}

echo "Validación Serverfitpower - $(date '+%F %T')"
echo

echo "-- Sistema y red"
chk "Sistema operativo Linux Mint"              grep -qi 'linux mint' /etc/os-release
chk "Nombre del servidor = $HOSTNAME_SRV"       test "$(hostname)" = "$HOSTNAME_SRV"
if [ "$CONFIGURAR_RED" = "si" ]; then
  chk "IP fija ${IP_FIJA%/*} asignada"          bash -c "ip -4 addr | grep -q '${IP_FIJA%/*}'"
  chk "Ruta por defecto vía $GATEWAY"           bash -c "ip route | grep -q 'default via $GATEWAY'"
fi
chk "Resolución DNS"                            getent hosts debian.org

echo "-- Servicios"
for s in ssh apache2 mariadb nftables cron; do
  chk "Servicio $s activo"                      systemctl is-active --quiet "$s"
done
for p in 22 80 443; do
  chk "Puerto $p en escucha"                    bash -c "ss -tln | grep -q ':$p '"
done

echo "-- Seguridad"
chk "nftables con política drop"                bash -c "nft list ruleset | grep -q 'policy drop'"
chk "SSH sin acceso root"                       bash -c "sshd -T | grep -qi '^permitrootlogin no'"
chk "SSH limitado a usuarios definidos"         bash -c "sshd -T | grep -qi '^allowusers.*administrador'"

echo "-- Usuarios y permisos"
chk "administrador en grupo sudo"               bash -c "id -nG administrador | grep -qw sudo"
chk "estandar sin sudo"                         bash -c "! id -nG estandar | grep -qw sudo"
chk "subadmin solo gestiona SSH"                bash -c "sudo -l -U subadmin | grep -q 'systemctl restart ssh' && ! sudo -l -U subadmin | grep -qE '\) (NOPASSWD: )?ALL\$'"
chk "Carpeta /home/estandar con modo 700"       test "$(stat -c %a /home/estandar)" = "700"
chk "Carpeta $DIR_BACKUPS con modo 750"         test "$(stat -c %a "$DIR_BACKUPS")" = "750"
chk "Alias y variables del administrador"       grep -q 'alias respaldar' /home/administrador/.bashrc

echo "-- Base de datos"
chk "Base $DB_NOMBRE existe"                    mariadb -e "USE $DB_NOMBRE"
chk "Base $DB_NOMBRE con tablas"                bash -c "[ \"\$(mariadb -N -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NOMBRE'\")\" -gt 0 ]"
chk "MariaDB solo en 127.0.0.1"                 bash -c "ss -tln | grep ':3306 ' | grep -q '127.0.0.1'"

echo "-- Apache, programa y SSL"
chk "Configuración de Apache válida"            apache2ctl configtest
chk "Programa publicado en $DIR_WEB"            test -d "$DIR_WEB"
chk "Sitio responde por HTTP/HTTPS"             curl -fsSkL -o /dev/null http://localhost/
chk "Puerto 443 entrega certificado"            bash -c "echo | openssl s_client -connect localhost:443 2>/dev/null | grep -q 'BEGIN CERTIFICATE'"
if [ -d /etc/letsencrypt/live ] && [ -n "$(ls -A /etc/letsencrypt/live 2>/dev/null)" ]; then
  echo "[INFO ] Certificado: Let's Encrypt"
else
  echo "[INFO ] Certificado: autofirmado (sin certificado de Let's Encrypt)"
fi

echo "-- Respaldos y crontab"
chk "Script respaldo.sh ejecutable"             test -x "$DIR_BACKUPS/respaldo.sh"
chk "Script limpiar-respaldos.sh ejecutable"    test -x "$DIR_BACKUPS/limpiar-respaldos.sh"
chk "Script operador.sh instalado"              test -x /usr/local/sbin/operador.sh
chk "Crontab: respaldo del sábado"              bash -c "crontab -l | grep -q 'respaldo.sh --subir'"
chk "Crontab: limpieza del domingo"             bash -c "crontab -l | grep -q 'limpiar-respaldos.sh'"
chk "Remoto Backblaze b2fitpower configurado"   bash -c "rclone listremotes | grep -q '^b2fitpower:\$'"
if [ "${1:-}" = "--respaldo" ]; then
  chk "Respaldo local de prueba"                "$DIR_BACKUPS/respaldo.sh"
fi

echo
echo "Resultado: $OK correctas, $FALLO con fallo."
[ "$FALLO" -eq 0 ]
