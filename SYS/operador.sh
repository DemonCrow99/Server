#!/bin/bash
# =====================================================================
# Serverfitpower - Operador de centro de cómputos (ABML) - versión 1.0
# Tareas: servicios, procesos, respaldos y usuarios (Alta, Baja,
# Modificación, Listado)
# Uso: sudo operador.sh
# =====================================================================
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar con sudo: sudo operador.sh"; exit 1; }
source /etc/fitpower/fitpower.conf

SERVICIOS=(ssh apache2 mariadb nftables cron)
PROTEGIDOS=(root administrador)

pausa()  { echo; read -rp "Enter para continuar..." _; }
anota()  { logger -t fitpower-operador "$*"; }
cabecera() { clear; echo "=== Serverfitpower - Operador ($1) ==="; echo; }

pedir_servicio() {
  read -rp "Servicio (${SERVICIOS[*]}): " SERV
  [[ " ${SERVICIOS[*]} " == *" $SERV "* ]] || { echo "Servicio no válido."; return 1; }
}

# ------------------------------ SERVICIOS ----------------------------
menu_servicios() {
  while true; do
    cabecera "Servicios"
    echo "1) Estado de todos     2) Iniciar     3) Detener"
    echo "4) Reiniciar           5) Estado detallado de uno"
    echo "0) Volver"
    read -rp "Opción: " o
    case "$o" in
      1) for s in "${SERVICIOS[@]}"; do printf '%-10s %s\n' "$s" "$(systemctl is-active "$s")"; done; pausa ;;
      2) pedir_servicio && systemctl start "$SERV" && anota "inicia $SERV" && echo "Hecho."; pausa ;;
      3) pedir_servicio && systemctl stop "$SERV" && anota "detiene $SERV" && echo "Hecho."; pausa ;;
      4) pedir_servicio && systemctl restart "$SERV" && anota "reinicia $SERV" && echo "Hecho."; pausa ;;
      5) pedir_servicio && systemctl status "$SERV" --no-pager; pausa ;;
      0) return ;;
      *) echo "Opción no válida."; sleep 1 ;;
    esac
  done
}

# ------------------------------ PROCESOS -----------------------------
menu_procesos() {
  while true; do
    cabecera "Procesos"
    echo "1) Top 10 por CPU      2) Top 10 por memoria"
    echo "3) Buscar por nombre   4) Terminar proceso (PID)"
    echo "0) Volver"
    read -rp "Opción: " o
    case "$o" in
      1) ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 11; pausa ;;
      2) ps -eo pid,user,%cpu,%mem,comm --sort=-%mem | head -n 11; pausa ;;
      3) read -rp "Nombre: " n; pgrep -a -f -- "$n" || echo "Sin coincidencias."; pausa ;;
      4) read -rp "PID: " pid
         if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; then
           read -rp "¿Forzar con -9? (s/N): " f
           if [ "$f" = "s" ]; then kill -9 "$pid"; else kill "$pid"; fi
           anota "kill PID $pid"
         else echo "PID no válido."; fi
         pausa ;;
      0) return ;;
      *) echo "Opción no válida."; sleep 1 ;;
    esac
  done
}

# ------------------------------ RESPALDOS ----------------------------
menu_respaldos() {
  while true; do
    cabecera "Respaldos"
    echo "1) Crear respaldo local"
    echo "2) Crear respaldo local y subir a Backblaze"
    echo "3) Listar respaldos locales"
    echo "4) Listar respaldos remotos"
    echo "5) Restaurar base de datos desde un respaldo local"
    echo "6) Eliminar respaldos anteriores (conserva el más reciente)"
    echo "0) Volver"
    read -rp "Opción: " o
    case "$o" in
      1) "$DIR_BACKUPS/respaldo.sh"; pausa ;;
      2) "$DIR_BACKUPS/respaldo.sh" --subir; pausa ;;
      3) ls -lh "$DIR_BACKUPS"/fitpower_*.tar.gz 2>/dev/null || echo "Sin respaldos."; pausa ;;
      4) rclone ls "b2fitpower:$B2_BUCKET" || echo "Remoto no disponible."; pausa ;;
      5) ls -1 "$DIR_BACKUPS"/fitpower_*.tar.gz 2>/dev/null
         read -rp "Ruta completa del respaldo: " f
         if [ -f "$f" ]; then
           read -rp "Se sobrescribirá la base $DB_NOMBRE. Escriba SI para continuar: " c
           if [ "$c" = "SI" ]; then
             tar -xzOf "$f" db.sql | mariadb && anota "restaura BD desde $f" && echo "Restaurada."
           fi
         else echo "Archivo no encontrado."; fi
         pausa ;;
      6) "$DIR_BACKUPS/limpiar-respaldos.sh"; pausa ;;
      0) return ;;
      *) echo "Opción no válida."; sleep 1 ;;
    esac
  done
}

# ------------------------------ USUARIOS -----------------------------
es_protegido() { [[ " ${PROTEGIDOS[*]} " == *" $1 "* ]]; }

usuario_alta() {
  read -rp "Nombre del nuevo usuario: " u
  [[ "$u" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] || { echo "Nombre no válido (minúsculas, 3-32 caracteres)."; return; }
  id "$u" &>/dev/null && { echo "El usuario ya existe."; return; }
  useradd -m -s /bin/bash "$u" && chmod 700 "/home/$u" && passwd "$u" && anota "alta usuario $u" \
    && echo "Usuario $u creado."
}

usuario_baja() {
  read -rp "Usuario a eliminar: " u
  es_protegido "$u" && { echo "Usuario protegido."; return; }
  id "$u" &>/dev/null || { echo "No existe."; return; }
  read -rp "Se borrará $u y su carpeta. Escriba SI para continuar: " c
  [ "$c" = "SI" ] && userdel -r "$u" && anota "baja usuario $u" && echo "Usuario eliminado."
}

usuario_modificar() {
  read -rp "Usuario a modificar: " u
  id "$u" &>/dev/null || { echo "No existe."; return; }
  es_protegido "$u" && { echo "Usuario protegido."; return; }
  echo "1) Cambiar contraseña  2) Bloquear  3) Desbloquear  4) Cambiar nombre completo"
  read -rp "Opción: " o
  case "$o" in
    1) passwd "$u" && anota "cambio de contraseña $u" ;;
    2) usermod -L "$u" && anota "bloqueo $u" && echo "Bloqueado." ;;
    3) usermod -U "$u" && anota "desbloqueo $u" && echo "Desbloqueado." ;;
    4) read -rp "Nombre completo: " nc; usermod -c "$nc" "$u" && anota "modifica nombre $u" && echo "Actualizado." ;;
    *) echo "Opción no válida." ;;
  esac
}

usuario_listado() {
  printf '%-16s %-6s %-22s %s\n' USUARIO UID CARPETA ESTADO
  awk -F: '$3>=1000 && $3<65534 {print $1" "$3" "$6}' /etc/passwd | while read -r u id h; do
    printf '%-16s %-6s %-22s %s\n' "$u" "$id" "$h" "$(passwd -S "$u" | awk '{print $2}')"
  done
}

menu_usuarios() {
  while true; do
    cabecera "Usuarios"
    echo "1) Alta   2) Baja   3) Modificación   4) Listado   0) Volver"
    read -rp "Opción: " o
    case "$o" in
      1) usuario_alta; pausa ;;
      2) usuario_baja; pausa ;;
      3) usuario_modificar; pausa ;;
      4) usuario_listado; pausa ;;
      0) return ;;
      *) echo "Opción no válida."; sleep 1 ;;
    esac
  done
}

# ------------------------------ PRINCIPAL ----------------------------
while true; do
  cabecera "Menú principal"
  echo "1) Servicios"
  echo "2) Procesos"
  echo "3) Respaldos"
  echo "4) Usuarios (ABML)"
  echo "5) Validación integral del sistema"
  echo "0) Salir"
  read -rp "Opción: " op
  case "$op" in
    1) menu_servicios ;;
    2) menu_procesos ;;
    3) menu_respaldos ;;
    4) menu_usuarios ;;
    5) /usr/local/sbin/validar.sh; pausa ;;
    0) exit 0 ;;
    *) echo "Opción no válida."; sleep 1 ;;
  esac
done
