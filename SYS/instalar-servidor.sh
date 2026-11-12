#!/bin/bash
# =====================================================================
# Serverfitpower - Instalación y configuración integral
# Linux Mint 22.3 LTS (XFCE)
#
#   sudo ./instalar-servidor.sh             instalación completa
#   sudo ./instalar-servidor.sh --solo-ssl  solo certificado HTTPS
# =====================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" -ne 0 ]; then echo "Ejecutar con sudo."; exit 1; fi
# shellcheck source=config.env
source "$DIR/config.env"

mkdir -p /etc/fitpower
LOG=/var/log/fitpower-instalacion.log
exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive

paso()  { echo; echo "==== $* ===="; }
aviso() { echo "[AVISO] $*"; }

# ---------------------------------------------------------------------
paquetes() {
  paso "1/11 Paquetes y nombre del servidor"
  apt-get update -y
  apt-get install -y openssh-server nftables mariadb-server apache2 \
    php libapache2-mod-php php-mysql git rclone certbot \
    python3-certbot-apache curl openssl rsyslog network-manager
  systemctl disable --now ufw 2>/dev/null || true
  hostnamectl set-hostname "$HOSTNAME_SRV"
  grep -q "$HOSTNAME_SRV" /etc/hosts || echo "127.0.1.1 $HOSTNAME_SRV" >> /etc/hosts
  install -m 600 -o root -g root "$DIR/config.env" /etc/fitpower/fitpower.conf
}

# ---------------------------------------------------------------------
crear_usuario() {
  local u="$1" p="$2"
  id "$u" &>/dev/null || useradd -m -s /bin/bash "$u"
  echo "$u:$p" | chpasswd
}

usuarios() {
  paso "2/11 Usuarios, permisos y entorno"
  crear_usuario administrador "$PASS_ADMIN"
  usermod -aG sudo administrador
  crear_usuario subadmin "$PASS_SUBADMIN"
  crear_usuario estandar "$PASS_ESTANDAR"

  chmod 750 /home/administrador /home/subadmin
  chmod 700 /home/estandar

  cat > /etc/sudoers.d/subadmin <<'EOF'
subadmin ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ssh, /usr/bin/systemctl start ssh, /usr/bin/systemctl stop ssh, /usr/bin/systemctl status ssh
EOF
  chmod 440 /etc/sudoers.d/subadmin
  visudo -cf /etc/sudoers.d/subadmin || { rm -f /etc/sudoers.d/subadmin; exit 1; }

  # Variables de entorno y alias del administrador
  local rc=/home/administrador/.bashrc
  if ! grep -q '# >>> fitpower >>>' "$rc"; then
    cat >> "$rc" <<'EOF'

# >>> fitpower >>>
export BACKUP_DIR="/srv/backups"
export EDITOR="nano"

alias ll='ls -lah'
alias verlogs='sudo tail -f /var/log/syslog'
alias respaldar='sudo /srv/backups/respaldo.sh'
alias reiniciarssh='sudo systemctl restart ssh'
alias verpuertos='sudo ss -tulnp'
alias verreglas='sudo nft list ruleset'
alias operador='sudo /usr/local/sbin/operador.sh'
# <<< fitpower <<<
EOF
  fi
  chown administrador:administrador "$rc"
}

# ---------------------------------------------------------------------
ssh_config() {
  paso "3/11 SSH"
  cat > /etc/ssh/sshd_config.d/00-fitpower.conf <<'EOF'
Port 22
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers administrador subadmin estandar
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
Banner /etc/issue.net
EOF
  echo "Serverfitpower - Acceso autorizado unicamente" > /etc/issue.net
  sshd -t
  systemctl enable ssh
  systemctl restart ssh
}

# ---------------------------------------------------------------------
firewall() {
  paso "4/11 Firewall nftables"
  cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport 22 ct state new limit rate 10/minute accept
    tcp dport { 80, 443 } accept
    limit rate 5/minute log prefix "nft-drop: "
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF
  nft -c -f /etc/nftables.conf
  systemctl enable nftables
  systemctl restart nftables
}

# ---------------------------------------------------------------------
base_datos() {
  paso "5/11 MariaDB"
  systemctl enable --now mariadb
  cat > /etc/mysql/mariadb.conf.d/99-fitpower.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
EOF
  if [ ! -f /etc/fitpower/db.pass ]; then
    (umask 077; openssl rand -base64 24 | tr -d '/+=\n' > /etc/fitpower/db.pass)
  fi
  local DBPASS
  DBPASS="$(cat /etc/fitpower/db.pass)"
  mariadb <<SQL
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS $DB_NOMBRE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USUARIO'@'localhost' IDENTIFIED BY '$DBPASS';
ALTER USER '$DB_USUARIO'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $DB_NOMBRE.* TO '$DB_USUARIO'@'localhost';
FLUSH PRIVILEGES;
SQL
  systemctl restart mariadb
}

# ---------------------------------------------------------------------
escribir_vhost_http() {
  local SN="${DOMINIO:-$HOSTNAME_SRV}"
  local redir=""
  if [ "${1:-}" = "redirigir" ]; then
    redir='    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]'
  fi
  cat > /etc/apache2/sites-available/fitpower.conf <<EOF
<VirtualHost *:80>
    ServerName $SN
    DocumentRoot $DIR_WEB
    <Directory $DIR_WEB>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
$redir
    ErrorLog \${APACHE_LOG_DIR}/fitpower-error.log
    CustomLog \${APACHE_LOG_DIR}/fitpower-access.log combined
</VirtualHost>
EOF
}

apache_programa() {
  paso "6/11 Apache y programa"
  systemctl enable --now apache2
  a2enmod rewrite headers ssl >/dev/null

  cat > /etc/apache2/conf-available/fitpower-seguridad.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
EOF
  a2enconf fitpower-seguridad >/dev/null

  if [ -n "$REPO_URL" ]; then
    if [ -d "$DIR_WEB/.git" ]; then
      git -c safe.directory="$DIR_WEB" -C "$DIR_WEB" pull --ff-only || aviso "No se pudo actualizar el repositorio"
    else
      rm -rf "$DIR_WEB"
      git clone --depth 1 -b "$REPO_RAMA" "$REPO_URL" "$DIR_WEB"
    fi
  else
    aviso "REPO_URL vacío: se publica una página mínima en lugar del programa"
    mkdir -p "$DIR_WEB"
    [ -f "$DIR_WEB/index.html" ] || echo "<h1>Serverfitpower en línea</h1>" > "$DIR_WEB/index.html"
  fi
  chown -R www-data:www-data "$DIR_WEB"

  escribir_vhost_http
  a2dissite 000-default >/dev/null 2>&1 || true
  a2ensite fitpower >/dev/null
  apache2ctl configtest
  systemctl reload apache2
}

# ---------------------------------------------------------------------
origen_datos() {
  paso "7/11 Origen de datos"
  local n sql
  n="$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NOMBRE'")"
  if [ "$n" -gt 0 ]; then echo "La base ya contiene tablas: no se modifica."; return 0; fi

  sql="$(find "$DIR_WEB" -maxdepth 3 -type f -name '*.sql' -not -path '*/.git/*' -print -quit)"
  if [ -n "$sql" ]; then
    echo "Importando $sql"
    mariadb "$DB_NOMBRE" < "$sql"
  else
    echo "Sin .sql en el programa: se crea el esquema base."
    mariadb "$DB_NOMBRE" <<'SQL'
CREATE TABLE planes (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nombre VARCHAR(60) NOT NULL,
  precio DECIMAL(10,2) NOT NULL
);
CREATE TABLE socios (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nombre VARCHAR(100) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE,
  plan_id INT NOT NULL,
  fecha_alta DATE NOT NULL,
  FOREIGN KEY (plan_id) REFERENCES planes(id)
);
CREATE TABLE asistencias (
  id INT AUTO_INCREMENT PRIMARY KEY,
  socio_id INT NOT NULL,
  fecha DATETIME NOT NULL,
  FOREIGN KEY (socio_id) REFERENCES socios(id)
);
INSERT INTO planes (nombre, precio) VALUES ('Basico', 20.00), ('Estandar', 35.00), ('Premium', 50.00);
INSERT INTO socios (nombre, email, plan_id, fecha_alta) VALUES
  ('Socio Uno', 'socio1@fitpower.local', 1, CURDATE()),
  ('Socio Dos', 'socio2@fitpower.local', 2, CURDATE()),
  ('Socio Tres', 'socio3@fitpower.local', 3, CURDATE());
INSERT INTO asistencias (socio_id, fecha) VALUES (1, NOW()), (2, NOW()), (3, NOW());
SQL
  fi
}

# ---------------------------------------------------------------------
respaldos_cron() {
  paso "8/11 Scripts, respaldos y crontab"
  install -d -m 750 -o root -g administrador "$DIR_BACKUPS"
  install -m 750 "$DIR/respaldo.sh"           "$DIR_BACKUPS/respaldo.sh"
  install -m 750 "$DIR/limpiar-respaldos.sh"  "$DIR_BACKUPS/limpiar-respaldos.sh"
  install -m 750 "$DIR/operador.sh"           /usr/local/sbin/operador.sh
  install -m 750 "$DIR/validar.sh"            /usr/local/sbin/validar.sh

  if [ -n "$B2_KEY_ID" ] && [ -n "$B2_APP_KEY" ]; then
    rclone config create b2fitpower b2 account "$B2_KEY_ID" key "$B2_APP_KEY" --non-interactive >/dev/null
    chmod 600 "$RCLONE_CONFIG"
    rclone mkdir "b2fitpower:$B2_BUCKET" || aviso "No se pudo acceder al bucket $B2_BUCKET"
  else
    aviso "Claves de Backblaze vacías: respaldo remoto sin configurar"
  fi

  crontab -u root "$DIR/fitpower.crontab"
  touch /var/log/fitpower-cron.log /var/log/fitpower-respaldo.log
}

# ---------------------------------------------------------------------
autofirmado() {
  local SN="${DOMINIO:-$HOSTNAME_SRV}"
  aviso "Se instala un certificado autofirmado para $SN"
  install -d -m 700 /etc/ssl/fitpower
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout /etc/ssl/fitpower/fitpower.key -out /etc/ssl/fitpower/fitpower.crt \
    -subj "/CN=$SN/O=Serverfitpower" -addext "subjectAltName=DNS:$SN"
  cat > /etc/apache2/sites-available/fitpower-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName $SN
    DocumentRoot $DIR_WEB
    SSLEngine on
    SSLCertificateFile /etc/ssl/fitpower/fitpower.crt
    SSLCertificateKeyFile /etc/ssl/fitpower/fitpower.key
    Header always set Strict-Transport-Security "max-age=31536000"
    <Directory $DIR_WEB>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/fitpower-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/fitpower-ssl-access.log combined
</VirtualHost>
EOF
  escribir_vhost_http redirigir
  a2ensite fitpower-ssl >/dev/null
  apache2ctl configtest
  systemctl reload apache2
}

ssl() {
  paso "9/11 SSL / HTTPS"
  if [ -n "$DOMINIO" ] && [ -n "$EMAIL_SSL" ]; then
    local ip_dom ip_pub
    ip_dom="$(getent ahostsv4 "$DOMINIO" | awk 'NR==1{print $1}' || true)"
    ip_pub="$(curl -fsS4 --max-time 10 https://api.ipify.org || true)"
    if [ -n "$ip_dom" ] && [ "$ip_dom" = "$ip_pub" ]; then
      escribir_vhost_http
      systemctl reload apache2
      if certbot --apache -d "$DOMINIO" -m "$EMAIL_SSL" --agree-tos --no-eff-email \
           --non-interactive --redirect; then
        echo "Certificado Let's Encrypt instalado para $DOMINIO"
        return 0
      fi
      aviso "certbot no pudo emitir el certificado"
    else
      aviso "El dominio ($ip_dom) no apunta a la IP pública de este equipo ($ip_pub)"
    fi
  else
    aviso "DOMINIO o EMAIL_SSL vacíos"
  fi
  autofirmado
}

# ---------------------------------------------------------------------
red() {
  paso "10/11 Red"
  if [ "$CONFIGURAR_RED" != "si" ]; then echo "Omitido (CONFIGURAR_RED=$CONFIGURAR_RED)"; return 0; fi
  local IF="${IFACE:-}" CON
  [ -n "$IF" ] || IF="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "$IF" ] || IF="$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="ethernet"{print $1; exit}')"
  CON="$(nmcli -t -g GENERAL.CONNECTION device show "$IF")"
  if [ -z "$CON" ] || [ "$CON" = "--" ]; then
    nmcli con add type ethernet ifname "$IF" con-name fitpower-lan
    CON="fitpower-lan"
  fi
  nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$IP_FIJA" \
    ipv4.gateway "$GATEWAY" ipv4.dns "$DNS_SERVERS"
  nmcli con up "$CON" || aviso "No se pudo reactivar la conexión $CON"
  sleep 5
}

# ---------------------------------------------------------------------
if [ "${1:-}" = "--solo-ssl" ]; then ssl; exit 0; fi

paquetes
usuarios
ssh_config
firewall
base_datos
apache_programa
origen_datos
respaldos_cron
ssl
red
paso "11/11 Validación"
/usr/local/sbin/validar.sh || true
echo
echo "Instalación finalizada. Registro: $LOG"
