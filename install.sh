#!/usr/bin/env bash
# NOTAS: Interface: as páginas de Sistema passam para o menu "Sistema" no canto superior direito.
# =============================================================================
#  IDDigital Hosting v2.12.1 — instalador (MiniPainel)
#  Painel de alojamento mínimo: nginx + PHP-FPM (várias versões) + MariaDB + phpMyAdmin,
#  gestor de ficheiros e estatísticas de recursos
#  Os sites são servidos por porta: http://IP:PORTA ou http://localhost:PORTA
#  Suporta: Debian 12/13, Ubuntu 22.04/24.04, AlmaLinux/Rocky 9/10
#
#  Uso:
#    bash minipainel-install-v2.12.1.sh [--php "7.4 8.3 8.4"] [--panel-port 2443] [--force]
#  (por omissão instala do PHP 7.0 ao 8.5; no AlmaLinux/Rocky o repositório Remi só tem do 7.4 para cima)
#
#  Pode ser executado novamente (atualiza a partir da v1.0.0 ou acrescenta
#  versões de PHP com --php); sites, bases de dados, extensões e password do
#  painel são preservados. Sem --php, numa atualização mantêm-se as versões
#  de PHP já instaladas.
# =============================================================================
set -Eeuo pipefail

MP_VERSION="2.12.1"
PHP_VERSIONS="7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5"
PHP_ALL="$PHP_VERSIONS"
PANEL_PORT=2443
PANEL_PORT_ARG=0
PHP_ARG=0
FORCE=0

trap 'echo -e "\n\033[31m[ERRO]\033[0m Falha na linha $LINENO: $BASH_COMMAND" >&2' ERR

say(){  echo -e "\033[36m==>\033[0m $*"; }
ok(){   echo -e "\033[32m[OK]\033[0m $*"; }
warn(){ echo -e "\033[33m[AVISO]\033[0m $*" >&2; }
die(){  echo -e "\033[31m[ERRO]\033[0m $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --php)        PHP_VERSIONS="${2:-}"; PHP_ARG=1; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-}"; PANEL_PORT_ARG=1; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    *)            die "Opção desconhecida: $1" ;;
  esac
done

# ----------------------------------------------------------------------------
# Verificações iniciais
# ----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Executa como root."
[ -r /etc/os-release ] || die "Não foi possível identificar a distribuição (/etc/os-release)."
[[ "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$PANEL_PORT" -ge 1 ] && [ "$PANEL_PORT" -le 65535 ] || die "Porta do painel inválida: $PANEL_PORT"
for v in $PHP_VERSIONS; do [[ "$v" =~ ^[5-8]\.[0-9]{1,2}$ ]] || die "Versão PHP inválida: $v"; done
[ -n "$PHP_VERSIONS" ] || die "Indica pelo menos uma versão de PHP."

# shellcheck source=/dev/null
. /etc/os-release
OS_ID="${ID:-}"
OS_VER="${VERSION_ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"
EL_MAJOR=""

case "$OS_ID" in
  debian)
    OS_FAMILY=debian
    case "${OS_VER%%.*}" in 12|13) ;; *) warn "Debian $OS_VER não foi testado." ;; esac ;;
  ubuntu)
    OS_FAMILY=debian
    case "$OS_VER" in 22.04|24.04) ;; *) warn "Ubuntu $OS_VER não foi testado." ;; esac ;;
  almalinux|rocky|rhel|centos|ol)
    OS_FAMILY=rhel
    EL_MAJOR="${OS_VER%%.*}"
    [[ "$EL_MAJOR" =~ ^[0-9]+$ ]] && [ "$EL_MAJOR" -ge 9 ] || die "Requer versão 9 ou superior (detetado: $OS_VER)." ;;
  *)
    die "Distribuição não suportada: $OS_ID" ;;
esac
[ "$OS_FAMILY" = debian ] && [ -z "$OS_CODENAME" ] && die "Não foi possível obter o codename da distribuição."

if [ "$OS_FAMILY" = debian ]; then WEB_USER=www-data; WEB_GROUP=www-data; else WEB_USER=nginx; WEB_GROUP=nginx; fi
NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"

UPGRADE=0
[ -f /etc/minipainel/minipainel.conf ] && UPGRADE=1
PREV_VERSION=$(cat /etc/minipainel/version 2>/dev/null || echo 0)
conf_get(){ grep -m1 "^$1=" /etc/minipainel/minipainel.conf 2>/dev/null | cut -d= -f2- || true; }

if [ "$UPGRADE" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  for p in /usr/local/mgr5 /usr/local/hestia /usr/local/vesta /usr/local/cpanel /usr/local/psa /usr/local/directadmin /usr/local/CyberCP /home/clp; do
    [ -e "$p" ] && die "Foi detetado outro painel ($p). Usa um servidor limpo ou --force."
  done
  extra=()
  shopt -s nullglob
  for f in /etc/nginx/conf.d/*.conf; do extra+=("$f"); done
  for f in /etc/nginx/sites-enabled/*; do [ "$(basename "$f")" = default ] || extra+=("$f"); done
  shopt -u nullglob
  if [ ${#extra[@]} -gt 0 ]; then
    die "O nginx já tem configurações (${extra[*]}). O IDDigital Hosting substitui o nginx.conf; usa --force para continuar."
  fi
  if [ -n "$(ss -Hltn "sport = :$PANEL_PORT" 2>/dev/null)" ]; then
    die "A porta $PANEL_PORT já está em uso. Escolhe outra com --panel-port."
  fi
fi

# ----------------------------------------------------------------------------
# Funções auxiliares PHP (iguais às do CLI)
# ----------------------------------------------------------------------------
php_vv(){ echo "${1/./}"; }
php_pool_dir(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/pool.d"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.d"; fi; }
php_service(){  if [ "$OS_FAMILY" = debian ]; then echo "php$1-fpm"; else echo "php$(php_vv "$1")-php-fpm"; fi; }
php_fpm_bin(){  if [ "$OS_FAMILY" = debian ]; then echo "/usr/sbin/php-fpm$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/sbin/php-fpm"; fi; }
php_fpm_conf(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/php-fpm.conf"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.conf"; fi; }
php_cli(){      if [ "$OS_FAMILY" = debian ]; then echo "/usr/bin/php$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/bin/php"; fi; }
php_run_dir(){  if [ "$OS_FAMILY" = debian ]; then echo "/run/php"; else echo "/var/opt/remi/php$(php_vv "$1")/run/php-fpm"; fi; }
php_www_sock(){ if [ "$OS_FAMILY" = debian ]; then echo "/run/php/php$1-fpm.sock"; else echo "$(php_run_dir "$1")/www.sock"; fi; }
php_installed(){
  local d v
  if [ "$OS_FAMILY" = debian ]; then
    for d in /etc/php/*/fpm/pool.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/php/}"; v="${v%%/*}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  else
    for d in /etc/opt/remi/php*/php-fpm.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/opt/remi/php}"; v="${v%%/*}"; v="${v:0:1}.${v:1}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  fi | sort -V
}

export DEBIAN_FRONTEND=noninteractive
pkg_install(){
  if [ "$OS_FAMILY" = debian ]; then apt-get install -y -q --no-install-recommends "$@"
  else dnf install -y -q "$@"; fi
}
pkg_install_soft(){
  # Instala a lista; se falhar em bloco tenta pacote a pacote (ignora os inexistentes)
  if pkg_install "$@" >/dev/null 2>&1; then return 0; fi
  local p
  for p in "$@"; do
    if ! pkg_install "$p" >/dev/null 2>&1; then warn "Pacote indisponível/ignorado: $p"; fi
  done
  return 0
}
selinux_on(){ command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; }

# ----------------------------------------------------------------------------
# 1. Pacotes base e repositórios PHP
# ----------------------------------------------------------------------------
say "A instalar pacotes base ($OS_ID $OS_VER)..."
if [ "$OS_FAMILY" = debian ]; then
  apt-get update -q
  pkg_install ca-certificates curl gnupg jq openssl iproute2 procps logrotate nftables cron pigz rclone certbot nginx mariadb-server mariadb-client
  if [ "$OS_ID" = ubuntu ]; then
    pkg_install software-properties-common
    add-apt-repository -y ppa:ondrej/php
  else
    curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i /tmp/debsuryorg-archive-keyring.deb >/dev/null
    rm -f /tmp/debsuryorg-archive-keyring.deb
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
      > /etc/apt/sources.list.d/php-sury.list
  fi
  apt-get update -q
else
  dnf install -y -q epel-release || dnf install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJOR}.noarch.rpm"
  dnf install -y -q dnf-plugins-core || true
  dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
  rpm -q remi-release >/dev/null 2>&1 || dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${EL_MAJOR}.rpm"
  pkg_install nginx mariadb-server mariadb jq openssl curl iproute procps-ng logrotate nftables cronie pigz policycoreutils-python-utils
  pkg_install_soft rclone certbot
fi
ok "Pacotes base instalados."

if [ "$UPGRADE" -eq 1 ] && [ "$PHP_ARG" -eq 0 ]; then
  CUR_PHP="$(php_installed | tr '\n' ' ')"
  [ -n "${CUR_PHP// /}" ] && PHP_VERSIONS="$CUR_PHP"
  # ao passar para a v2.4.0 (uma só vez) acrescentam-se as versões do 7.0 ao 8.5 que faltem
  if [ "$PREV_VERSION" != 0 ] && [ "$(printf '%s\n%s\n' "$PREV_VERSION" 2.4.0 | sort -V | head -1)" = "$PREV_VERSION" ] && [ "$PREV_VERSION" != 2.4.0 ]; then
    PHP_VERSIONS="$(printf '%s\n' $CUR_PHP $PHP_ALL | sort -uV | tr '\n' ' ')"
  fi
fi
say "A instalar versões de PHP: $PHP_VERSIONS"
for v in $PHP_VERSIONS; do
  pkgs=()
  if [ "$OS_FAMILY" = debian ]; then
    for e in fpm cli common mysql curl gd mbstring xml zip intl bcmath opcache soap sqlite3 readline; do pkgs+=("php$v-$e"); done
    case "$v" in 5.*|7.*) pkgs+=("php$v-json") ;; esac
  else
    vv="$(php_vv "$v")"
    for e in php-fpm php-cli php-common php-mysqlnd php-gd php-mbstring php-xml php-pecl-zip php-intl php-bcmath php-opcache php-soap php-pdo php-process; do pkgs+=("php$vv-$e"); done
    case "$v" in 5.*|7.*) pkgs+=("php$vv-php-json") ;; esac
  fi
  pkg_install_soft "${pkgs[@]}"
  if [ -x "$(php_fpm_bin "$v")" ]; then ok "PHP $v instalado."; else warn "PHP $v não ficou instalado (indisponível nesta distribuição?)."; fi
done

ALL_PHP="$(php_installed | tr '\n' ' ')"
[ -n "${ALL_PHP// /}" ] || die "Nenhuma versão de PHP ficou instalada."
HIGHEST_PHP="$(php_installed | tail -n1)"
for c in 8.4 8.3 8.2; do if php_installed | grep -qx "$c"; then HIGHEST_PHP=$c; break; fi; done

# ----------------------------------------------------------------------------
# 2. Configuração do MiniPainel
# ----------------------------------------------------------------------------
PANEL_USER="admin"
DEFAULT_PHP="$HIGHEST_PHP"
if [ "$UPGRADE" -eq 1 ]; then
  old="$(conf_get PANEL_USER)"; [ -n "$old" ] && PANEL_USER="$old"
  old="$(conf_get DEFAULT_PHP)"
  if [ -n "$old" ] && [ -x "$(php_fpm_bin "$old")" ]; then DEFAULT_PHP="$old"; fi
  if [ "$PANEL_PORT_ARG" -eq 0 ]; then old="$(conf_get PANEL_PORT)"; [ -n "$old" ] && PANEL_PORT="$old"; fi
fi
PANEL_PHP="$HIGHEST_PHP"

IPV6=0
if [ -f /proc/net/if_inet6 ] && [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then IPV6=1; fi

say "A criar utilizador e pastas do painel..."
id minipainel >/dev/null 2>&1 || useradd -r -U -M -d /var/lib/minipainel -s "$NOLOGIN" -c "MiniPainel" minipainel
install -d -m 755 /srv/www /etc/minipainel /opt/minipainel /opt/minipainel/public
install -d -m 700 /etc/minipainel/sites /etc/minipainel/ssl
install -d -m 755 /etc/nginx/minipainel /etc/nginx/minipainel/sites
install -d -o root -g minipainel -m 750 /var/lib/minipainel
install -d -o minipainel -g minipainel -m 700 /var/lib/minipainel/queue /var/lib/minipainel/tmp \
  /var/lib/minipainel/sessions /var/lib/minipainel/ratelimit /var/lib/minipainel/logs
install -d -o root -g minipainel -m 2770 /var/lib/minipainel/results
id minipainel-pma >/dev/null 2>&1 || useradd -r -U -M -d /var/lib/minipainel-pma -s "$NOLOGIN" -c "MiniPainel phpMyAdmin" minipainel-pma
install -d -o root -g minipainel-pma -m 750 /var/lib/minipainel-pma
install -d -o minipainel-pma -g minipainel-pma -m 700 /var/lib/minipainel-pma/tmp /var/lib/minipainel-pma/sessions /var/lib/minipainel-pma/logs

cat > /etc/minipainel/minipainel.conf <<EOF
# MiniPainel — gerado pelo instalador v$MP_VERSION (não editar sem necessidade)
MP_INSTALLED_VERSION=$MP_VERSION
OS_FAMILY=$OS_FAMILY
WEB_USER=$WEB_USER
WEB_GROUP=$WEB_GROUP
NOLOGIN=$NOLOGIN
PANEL_PORT=$PANEL_PORT
PANEL_USER=$PANEL_USER
PANEL_SYSUSER=minipainel
PANEL_PHP=$PANEL_PHP
DEFAULT_PHP=$DEFAULT_PHP
SITE_PORT_START=8001
IPV6=$IPV6
EOF
chmod 644 /etc/minipainel/minipainel.conf

# ----------------------------------------------------------------------------
# 3. MariaDB
# ----------------------------------------------------------------------------
say "A configurar MariaDB..."
if [ "$OS_FAMILY" = debian ]; then MYCNF_DIR=/etc/mysql/mariadb.conf.d; else MYCNF_DIR=/etc/my.cnf.d; fi
mkdir -p "$MYCNF_DIR"
if [ ! -f "$MYCNF_DIR/99-minipainel.cnf" ]; then
  cat > "$MYCNF_DIR/99-minipainel.cnf" <<'EOF'
# MiniPainel — MariaDB apenas acessível localmente
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
fi
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb
if [ "$UPGRADE" -eq 0 ]; then
  mysql -uroot -e "DROP USER IF EXISTS ''@'localhost'; DROP USER IF EXISTS ''@'$(hostname)'; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" \
    || warn "Não foi possível aplicar a limpeza inicial do MariaDB."
fi
ok "MariaDB ativo (apenas 127.0.0.1)."

# ----------------------------------------------------------------------------
# 4. nginx
# ----------------------------------------------------------------------------
say "A configurar nginx..."
if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.minipainel-orig ]; then
  cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.minipainel-orig
fi
if [ "$OS_FAMILY" = debian ]; then NGX_MODULES="include /etc/nginx/modules-enabled/*.conf;"; else NGX_MODULES="include /usr/share/nginx/modules/*.conf;"; fi

cat > /etc/nginx/nginx.conf <<EOF
# Gerado pelo MiniPainel v$MP_VERSION (original em nginx.conf.minipainel-orig)
user $WEB_USER;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
$NGX_MODULES

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    tcp_nopush    on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    server_tokens off;
    fastcgi_hide_header X-Powered-By;
    client_max_body_size 128M;
    access_log /var/log/nginx/access.log;

    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css text/xml application/javascript application/json application/xml image/svg+xml;

    include /etc/nginx/minipainel/panel.conf;
    include /etc/nginx/minipainel/conf.d/*.conf;
    include /etc/nginx/minipainel/sites/*.conf;
}
EOF

PANEL_SOCK="$(php_run_dir "$PANEL_PHP")/minipainel.sock"
PMA_SOCK="$(php_run_dir "$PANEL_PHP")/minipainel-pma.sock"
PANEL_RUN="$(php_run_dir "$PANEL_PHP")"
L6=""
[ "$IPV6" = 1 ] && L6="    listen [::]:$PANEL_PORT ssl;"
install -d -m 755 /etc/nginx/minipainel/conf.d /etc/nginx/minipainel/inc /var/www/minipainel-acme
[ -f /etc/nginx/minipainel/panel-allow.inc ] || echo "# IDDigital Hosting — IPs autorizados a abrir o painel (todos)" > /etc/nginx/minipainel/panel-allow.inc
[ -f /etc/nginx/minipainel/ports-allow.inc ] || echo "# IDDigital Hosting — acesso pelas portas dos sites (todos)" > /etc/nginx/minipainel/ports-allow.inc
cat > /etc/nginx/minipainel/panel.inc <<EOF
# IDDigital Hosting — conteúdo do painel (porta própria e domínio do painel)
    include /etc/nginx/minipainel/panel-allow.inc;
    root /opt/minipainel/public;
    access_log /var/log/nginx/minipainel.access.log;
    error_log  /var/log/nginx/minipainel.error.log;

    location = /favicon.ico { access_log off; log_not_found off; return 204; }

    # Verificação de sessão do painel (usada para proteger o phpMyAdmin)
    location = /_mp_auth {
        internal;
        client_max_body_size 0;
        fastcgi_pass_request_body off;
        fastcgi_param SCRIPT_FILENAME /opt/minipainel/public/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
        fastcgi_param REQUEST_METHOD GET;
        fastcgi_param REQUEST_URI /_mp_auth;
        fastcgi_param QUERY_STRING "";
        fastcgi_param CONTENT_LENGTH "";
        fastcgi_param CONTENT_TYPE "";
        fastcgi_param REMOTE_ADDR \$remote_addr;
        fastcgi_param SERVER_NAME \$server_name;
        fastcgi_param HTTPS on;
        fastcgi_param MP_AUTH_CHECK 1;
        fastcgi_pass unix:$PANEL_SOCK;
    }

    # phpMyAdmin — só acessível com sessão iniciada no painel
    location = /phpmyadmin { return 301 /phpmyadmin/; }
    location ^~ /phpmyadmin/ {
        auth_request /_mp_auth;
        error_page 401 = @mp_login;
        alias /opt/minipainel/phpmyadmin/;
        index index.php;
        client_max_body_size 512M;
        location ~ ^/phpmyadmin/(setup|libraries|templates|vendor|sql|locale|src)(/|\$) { deny all; }
        location ~ /\. { deny all; }
        location ~ ^/phpmyadmin/.+\.php\$ {
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            fastcgi_param HTTPS on;
            fastcgi_pass unix:$PMA_SOCK;
            fastcgi_read_timeout 900s;
            fastcgi_buffer_size 32k;
            fastcgi_buffers 16 16k;
        }
    }
    location @mp_login { return 302 /?p=resumo; }

    # Gestor de ficheiros — pool PHP-FPM de cada site (corre como o utilizador do site)
    location ~ "^/ficheiros/(?<fmsite>[a-z][a-z0-9-]{0,23})/\$" {
        auth_request /_mp_auth;
        error_page 401 = @mp_login;
        client_max_body_size 72M;
        fastcgi_buffering off;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /opt/minipainel/files/index.php;
        fastcgi_param SCRIPT_NAME /ficheiros/\$fmsite/;
        fastcgi_param MP_FM_SITE \$fmsite;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:$PANEL_RUN/mp-fm-\$fmsite.sock;
        fastcgi_read_timeout 900s;
        fastcgi_send_timeout 900s;
    }

    location = /ficheiros/_email/ {
        auth_request /_mp_auth;
        error_page 401 = @mp_login;
        client_max_body_size 72M;
        fastcgi_buffering off;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /opt/minipainel/files/index.php;
        fastcgi_param SCRIPT_NAME /ficheiros/_email/;
        fastcgi_param MP_FM_SITE _email;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:$PANEL_RUN/mp-fm-_email.sock;
        fastcgi_read_timeout 900s;
        fastcgi_send_timeout 900s;
    }

    # terminal (ttyd numa socket local; só existe enquanto o terminal está aberto)
    location ^~ /terminal/ {
        auth_request /_mp_auth;
        error_page 401 = @mp_login;
        proxy_pass http://unix:/run/minipainel-term/term.sock;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering off;
    }

    location / {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
        fastcgi_pass unix:$PANEL_SOCK;
        fastcgi_read_timeout 900s;
    }
EOF
cat > /etc/nginx/minipainel/panel.conf <<EOF
# MiniPainel — painel de administração
server {
    listen $PANEL_PORT ssl;
$L6
    server_name _;

    ssl_certificate     /etc/minipainel/ssl/panel.crt;
    ssl_certificate_key /etc/minipainel/ssl/panel.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:MPSSL:1m;
    error_page 497 =301 https://\$host:\$server_port\$request_uri;

    include /etc/nginx/minipainel/panel.inc;
}
EOF

if [ ! -s /etc/minipainel/ssl/panel.crt ] || [ ! -s /etc/minipainel/ssl/panel.key ]; then
  say "A gerar certificado autoassinado para o painel..."
  SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SAN="DNS:localhost,IP:127.0.0.1"
  [ -n "$SRV_IP" ] && SAN="$SAN,IP:$SRV_IP"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/minipainel/ssl/panel.key -out /etc/minipainel/ssl/panel.crt \
    -subj "/CN=MiniPainel" -addext "subjectAltName=$SAN" >/dev/null 2>&1
  chmod 600 /etc/minipainel/ssl/panel.key
  chmod 644 /etc/minipainel/ssl/panel.crt
fi

# ----------------------------------------------------------------------------
# 5. PHP-FPM: pool mínimo por versão + pool do painel
# ----------------------------------------------------------------------------
say "A configurar PHP-FPM..."
for v in $ALL_PHP; do
  pd="$(php_pool_dir "$v")"
  if [ -f "$pd/www.conf" ] && [ ! -f "$pd/www.conf.minipainel-orig" ]; then cp -a "$pd/www.conf" "$pd/www.conf.minipainel-orig"; fi
  cat > "$pd/www.conf" <<EOF
; MiniPainel — pool mínimo (necessário para o serviço arrancar; não serve sites)
[www]
user = $WEB_USER
group = $WEB_GROUP
listen = $(php_www_sock "$v")
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
EOF
  rm -f "$pd/minipainel.conf" "$pd/minipainel-pma.conf"
done

cat > "$(php_pool_dir "$PANEL_PHP")/minipainel.conf" <<EOF
; MiniPainel — pool do painel de administração
[minipainel]
user = minipainel
group = minipainel
listen = $PANEL_SOCK
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
request_terminate_timeout = 0
php_admin_value[open_basedir] = /opt/minipainel/:/var/lib/minipainel/:/var/backups/minipainel/:/var/log/minipainel/sites/:/var/log/minipainel/terminal/:/var/lib/minipainel/geoip/
php_admin_value[session.save_path] = /var/lib/minipainel/sessions
php_admin_value[upload_tmp_dir] = /var/lib/minipainel/tmp
php_admin_value[sys_temp_dir] = /var/lib/minipainel/tmp
php_admin_value[error_log] = /var/lib/minipainel/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_value[max_execution_time] = 870
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[session.gc_maxlifetime] = 7200
php_admin_flag[session.cookie_secure] = on
php_admin_flag[session.cookie_httponly] = on
php_admin_flag[session.use_strict_mode] = on
php_admin_value[session.cookie_samesite] = Strict
EOF

cat > "$(php_pool_dir "$PANEL_PHP")/minipainel-pma.conf" <<EOF
; MiniPainel — pool do phpMyAdmin
[minipainel-pma]
user = minipainel-pma
group = minipainel-pma
listen = $PMA_SOCK
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 6
pm.process_idle_timeout = 30s
request_terminate_timeout = 900s
php_admin_value[open_basedir] = /opt/minipainel/phpmyadmin/:/var/lib/minipainel-pma/
php_admin_value[session.save_path] = /var/lib/minipainel-pma/sessions
php_admin_value[upload_tmp_dir] = /var/lib/minipainel-pma/tmp
php_admin_value[sys_temp_dir] = /var/lib/minipainel-pma/tmp
php_admin_value[error_log] = /var/lib/minipainel-pma/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 600
php_admin_value[max_input_time] = 600
php_admin_value[max_input_vars] = 10000
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[session.gc_maxlifetime] = 7200
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF

# ----------------------------------------------------------------------------
# 6. Painel web
# ----------------------------------------------------------------------------
say "A instalar o painel web..."
cat > /opt/minipainel/public/index.php <<'MPPANEL'
<?php
/**
 * IDDigital Hosting v2.12.1 — painel web (MiniPainel)
 * O painel não executa comandos: lê o estado (state.json) e coloca tarefas
 * numa fila, processadas como root pelo worker (mpanel worker).
 * As tarefas são assíncronas: o painel acompanha-as sem ficar bloqueado,
 * o que permite reiniciar serviços (incluindo o PHP do próprio painel).
 */
declare(strict_types=1);

const MP_VERSION = '2.12.1';
const MP_DATA    = '/var/lib/minipainel';
const MP_QUEUE   = MP_DATA . '/queue';
const MP_RESULTS = MP_DATA . '/results';
const MP_TMP     = MP_DATA . '/tmp';
const MP_RL      = MP_DATA . '/ratelimit';
const MP_STATE   = MP_DATA . '/state.json';
const MP_AUTH    = MP_DATA . '/auth.json';
const MP_IDLE    = 7200;
const MP_STATS   = MP_DATA . '/stats';
const MP_BK      = '/var/backups/minipainel';
const RX_SITE    = '/^[a-z][a-z0-9-]{0,23}$/';
const RX_DB      = '/^[a-z][a-z0-9_]{0,31}$/';
const RX_PASS    = '/^[A-Za-z0-9._@%+=:,!#*-]{8,64}$/';
const RX_PHP     = '/^[5-8]\.[0-9]{1,2}$/';
const RX_EXT     = '/^[a-z0-9_]{2,20}$/';
const RX_SVC     = '/^(nginx|mariadb|php-[5-8]\.[0-9]{1,2})$/';

/* chave => [rótulo, mínimo, máximo, unidade, opção do CLI, diretiva] */
const LIMITS = [
    'memory'     => ['Memória', 32, 8192, 'MB', '--memory', 'memory_limit'],
    'upload'     => ['Upload máximo', 1, 8192, 'MB', '--upload', 'upload_max_filesize e post_max_size'],
    'exec'       => ['Tempo de execução', 5, 3600, 's', '--exec', 'max_execution_time'],
    'input_time' => ['Tempo de receção de dados', 5, 3600, 's', '--input-time', 'max_input_time'],
    'input_vars' => ['Máximo de variáveis', 100, 100000, '', '--input-vars', 'max_input_vars'],
];
const LIMIT_DEFAULTS = ['memory' => 256, 'upload' => 128, 'exec' => 120, 'input_time' => 120, 'input_vars' => 5000];

/* Pedido interno do nginx (auth_request) para proteger o phpMyAdmin.
   Não bloqueia a sessão, para não atrasar os pedidos paralelos do phpMyAdmin. */
if ((string)($_SERVER['MP_AUTH_CHECK'] ?? '') === '1') {
    $authOk = false;
    session_name('MPSESS');
    if (isset($_COOKIE['MPSESS']) && is_string($_COOKIE['MPSESS']) && preg_match('/^[A-Za-z0-9,-]{20,128}$/', $_COOKIE['MPSESS'])) {
        session_start(['read_and_close' => true]);
        $seen = (int)($_SESSION['seen'] ?? 0);
        $authOk = !empty($_SESSION['user']) && time() - $seen <= MP_IDLE;
        if ($authOk && time() - $seen > 60) { session_start(); $_SESSION['seen'] = time(); session_write_close(); }
    }
    http_response_code($authOk ? 204 : 401);
    exit;
}

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");

session_name('MPSESS');
session_start();

/* ---------- utilitários ---------- */
function h($v): string { return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function post(string $k): string { $v = $_POST[$k] ?? ''; return is_string($v) ? trim($v) : ''; }
function post_raw(string $k): string { $v = $_POST[$k] ?? ''; return is_string($v) ? $v : ''; }
function qget(string $k): string { $v = $_GET[$k] ?? ''; return is_string($v) ? $v : ''; }
function jload(string $f): ?array {
    $d = @file_get_contents($f);
    if ($d === false) return null;
    $j = json_decode($d, true);
    return is_array($j) ? $j : null;
}
function csrf(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));
    return $_SESSION['csrf'];
}
function csrf_ok(): bool {
    $t = $_POST['csrf'] ?? '';
    return is_string($t) && $t !== '' && hash_equals((string)($_SESSION['csrf'] ?? ''), $t);
}
function csrf_field(): string { return '<input type="hidden" name="csrf" value="' . h(csrf()) . '">'; }
function act_fields(string $a, array $extra = []): string {
    $o = csrf_field() . '<input type="hidden" name="a" value="' . h($a) . '">';
    foreach ($extra as $k => $v) $o .= '<input type="hidden" name="' . h($k) . '" value="' . h($v) . '">';
    return $o;
}
function flash(bool $ok, string $m, bool $sticky = false): void { $_SESSION['flash'][] = [$ok, $m, $sticky || !$ok]; }
function go(string $p, array $q = []): void {
    $ref = (string)($_SERVER['HTTP_REFERER'] ?? '');
    if (!isset($q['t']) && preg_match('/[?&]p=' . preg_quote($p, '/') . '(&|$)/', $ref) && preg_match('/[?&]t=([a-z]{2,20})(&|$)/', $ref, $mm)) $q['t'] = $mm[1];
    header('Location: ?' . http_build_query(['p' => $p] + $q));
    exit;
}
/* ---------- auditoria e verificação em dois passos ---------- */
function audit(string $action, bool $ok = true, ?string $user = null): void {
    $line = json_encode(['ts' => time(), 'ip' => (string)($_SERVER['REMOTE_ADDR'] ?? ''), 'user' => substr((string)($user ?? ($_SESSION['user'] ?? '')), 0, 40), 'action' => substr($action, 0, 300), 'ok' => $ok], JSON_UNESCAPED_UNICODE);
    @file_put_contents(MP_DATA . '/logs/audit.log', $line . "\n", FILE_APPEND | LOCK_EX);
    if (function_exists('openlog')) { @openlog('minipainel-audit', LOG_PID, LOG_AUTHPRIV); @syslog($ok ? LOG_NOTICE : LOG_WARNING, $line); @closelog(); }
}
function b32_encode(string $b): string {
    $a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; $bits = ''; $o = '';
    foreach (str_split($b) as $c) $bits .= str_pad(decbin(ord($c)), 8, '0', STR_PAD_LEFT);
    foreach (str_split($bits, 5) as $ch) $o .= $a[bindec(str_pad($ch, 5, '0'))];
    return $o;
}
function b32_decode(string $s): string {
    $a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; $bits = ''; $o = '';
    foreach (str_split(strtoupper(preg_replace('/[^A-Za-z2-7]/', '', $s) ?? '')) as $c) $bits .= str_pad(decbin((int)strpos($a, $c)), 5, '0', STR_PAD_LEFT);
    foreach (str_split($bits, 8) as $by) if (strlen($by) === 8) $o .= chr(bindec($by));
    return $o;
}
function totp_code(string $secret, int $step): string {
    $h = hash_hmac('sha1', pack('N2', 0, $step), b32_decode($secret), true);
    $p = ord($h[19]) & 0x0f;
    $v = ((ord($h[$p]) & 0x7f) << 24) | (ord($h[$p + 1]) << 16) | (ord($h[$p + 2]) << 8) | ord($h[$p + 3]);
    return str_pad((string)($v % 1000000), 6, '0', STR_PAD_LEFT);
}
function totp_verify(string $secret, string $code): ?int {
    $code = preg_replace('/\D/', '', $code) ?? '';
    if (strlen($code) !== 6 || $secret === '') return null;
    $now = intdiv(time(), 30);
    for ($d = -1; $d <= 1; $d++) { if (hash_equals(totp_code($secret, $now + $d), $code)) return $now + $d; }
    return null;
}
function totp_ok(array $auth, string $code): bool { // código de 6 dígitos, sem reutilização
    $st = totp_verify((string)($auth['totp'] ?? ''), $code);
    if ($st === null) return false;
    $f = MP_RL . '/totp-last.json';
    $last = (int)((jload($f) ?? [])['step'] ?? 0);
    if ($st <= $last) return false;
    @file_put_contents($f, (string)json_encode(['step' => $st]), LOCK_EX);
    return true;
}
function recovery_use(array $auth, string $code): bool {
    $c = strtolower(preg_replace('/[^0-9a-fA-F]/', '', $code) ?? '');
    if (strlen($c) !== 12) return false;
    $h = hash('sha256', substr($c, 0, 6) . '-' . substr($c, 6));
    $list = is_array($auth['recovery'] ?? null) ? $auth['recovery'] : [];
    if (!in_array($h, $list, true)) return false;
    $uf = MP_DATA . '/logs/2fa-used.json';
    $used = jload($uf) ?? [];
    if (in_array($h, $used, true)) return false;
    $used[] = $h;
    @file_put_contents($uf, (string)json_encode($used), LOCK_EX);
    return true;
}
function reauth_ok(?array $auth): bool { // password atual e, com 2FA ativo, também o código
    if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) return false;
    if (!empty($auth['totp']) && !totp_ok($auth, post('code')) && !recovery_use($auth, post('code'))) return false;
    return true;
}
function reauth_fields(?array $auth): string {
    $h = '<label class="fld">Password do painel<input class="in" type="password" name="atual" required autocomplete="current-password"></label>';
    if (!empty($auth['totp'])) $h .= '<label class="fld">Código de verificação<input class="in mono" name="code" required inputmode="numeric" autocomplete="one-time-code" maxlength="14"></label>';
    return $h;
}
function ip_in(string $ip, string $net): bool {
    $p = explode('/', $net, 2);
    $a = @inet_pton($ip); $b = @inet_pton($p[0]);
    if ($a === false || $b === false || strlen($a) !== strlen($b)) return false;
    $bits = isset($p[1]) ? (int)$p[1] : strlen($a) * 8;
    $by = intdiv($bits, 8); $r = $bits % 8;
    if (substr($a, 0, $by) !== substr($b, 0, $by)) return false;
    if ($r === 0) return true;
    $m = (0xFF << (8 - $r)) & 0xFF;
    return (ord($a[$by]) & $m) === (ord($b[$by]) & $m);
}
/* ---------- logs dos sites (nginx: lidos diretamente; PHP e cron: pelo gestor de ficheiros do site) ---------- */
const MP_SITE_LOGS = '/var/log/minipainel/sites';
const MP_TERM_LOG  = '/var/log/minipainel/terminal';
function log_tail(string $f, int $max, string $grep = '', int $maxBytes = 33554432): array {
    if (!is_file($f) || is_link($f)) return [];
    $fh = @fopen($f, 'r'); if (!$fh) return [];
    $size = (int)filesize($f); $pos = $size; $buf = ''; $out = [];
    while ($pos > 0 && count($out) < $max && $size - $pos < $maxBytes) {
        $rd = min(65536, $pos); $pos -= $rd; fseek($fh, $pos); $buf = (string)fread($fh, $rd) . $buf;
        $parts = explode("\n", $buf); $buf = $pos > 0 ? (string)array_shift($parts) : '';
        $sel = [];
        foreach ($parts as $ln) { if ($ln === '') continue; if ($grep !== '' && stripos($ln, $grep) === false) continue; $sel[] = $ln; }
        $out = array_merge($sel, $out);
    }
    if ($buf !== '' && ($grep === '' || stripos($buf, $grep) !== false)) array_unshift($out, $buf);
    fclose($fh);
    return array_slice($out, -$max);
}
function log_parse(string $ln): ?array { // formato "combined" do nginx
    if (!preg_match('/^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3}) (\d+|-) "([^"]*)" "([^"]*)"/', $ln, $m)) return null;
    $t = DateTime::createFromFormat('d/M/Y:H:i:s O', $m[2]);
    $rt = null; $cs = '';
    if (preg_match('/ rt=([0-9.]+)(?: urt=\S+)?(?: cs=(\S+))?\s*$/', $ln, $x)) { $rt = (float)$x[1]; $cs = ($x[2] ?? '') === '-' ? '' : (string)($x[2] ?? ''); }
    return ['ip' => $m[1], 't' => $t ? $t->getTimestamp() : 0, 'm' => $m[3], 'u' => $m[4], 's' => (int)$m[5], 'b' => $m[6] === '-' ? 0 : (int)$m[6], 'r' => $m[7], 'a' => $m[8], 'rt' => $rt, 'cs' => $cs];
}
function log_is_bot(string $ua): bool { return (bool)preg_match('/bot|crawl|spider|slurp|bingpreview|facebookexternalhit|curl|wget|python|go-http|semrush|ahrefs|mj12|petal|yandex|dotbot|scrapy/i', $ua); }
function log_summary(string $f): array { // últimas 24 h
    $since = time() - 86400; $sum = ['total' => 0, 'c' => ['2' => 0, '3' => 0, '4' => 0, '5' => 0], 'bots' => 0, 'bytes' => 0, 'ips' => [], 'e404' => [], 'e5xx' => [], 'slow' => [], 'cache' => [], 'rtn' => 0, 'rts' => 0.0];
    foreach (log_tail($f, 300000, '', 67108864) as $ln) {
        $p = log_parse($ln); if (!$p || $p['t'] < $since) continue;
        $sum['total']++; $k = (string)intdiv($p['s'], 100); if (isset($sum['c'][$k])) $sum['c'][$k]++;
        $sum['bytes'] += $p['b']; if (log_is_bot($p['a'])) $sum['bots']++;
        $sum['ips'][$p['ip']] = ($sum['ips'][$p['ip']] ?? 0) + 1;
        $u = strtok($p['u'], '?') ?: $p['u'];
        if ($p['s'] === 404) $sum['e404'][$u] = ($sum['e404'][$u] ?? 0) + 1;
        if ($p['s'] >= 500) $sum['e5xx'][$u] = ($sum['e5xx'][$u] ?? 0) + 1;
        if ($p['rt'] !== null && !preg_match('/\.(css|js|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|map)$/i', $u)) {
            $sum['rtn']++; $sum['rts'] += $p['rt'];
            $q0 = $sum['slow'][$u] ?? [0, 0.0, 0.0]; $sum['slow'][$u] = [$q0[0] + 1, $q0[1] + $p['rt'], max($q0[2], $p['rt'])];
        }
        if ($p['cs'] !== '') $sum['cache'][$p['cs']] = ($sum['cache'][$p['cs']] ?? 0) + 1;
    }
    $sum['slow'] = array_filter($sum['slow'], function ($v) { return $v[0] >= 2; });
    uasort($sum['slow'], function ($a, $b) { return ($b[1] / $b[0]) <=> ($a[1] / $a[0]); });
    $sum['slow'] = array_slice($sum['slow'], 0, 10, true);
    foreach (['ips', 'e404', 'e5xx'] as $k) { arsort($sum[$k]); $sum[$k] = array_slice($sum[$k], 0, 10, true); }
    return $sum;
}
/* ---------- países (base DB-IP Lite, consultada localmente) e paginação ---------- */
const MP_GEO = '/var/lib/minipainel/geoip';
function geo_cc(string $ip): string {
    static $fh = [], $n = [], $cache = [];
    if (isset($cache[$ip])) return $cache[$ip];
    $v6 = strpos($ip, ':') !== false; $k = $v6 ? 6 : 4; $rec = $v6 ? 34 : 10; $cc = '';
    if (!isset($fh[$k])) { $f = MP_GEO . '/v' . $k . '.bin'; $fh[$k] = is_readable($f) ? fopen($f, 'rb') : false; $n[$k] = $fh[$k] ? intdiv((int)filesize($f), $rec) : 0; }
    if ($fh[$k]) {
        if ($v6) { $x = @inet_pton($ip); if ($x === false || strlen($x) !== 16) return $cache[$ip] = ''; }
        else { $x = ip2long($ip); if ($x === false) return $cache[$ip] = ''; }
        $lo = 0; $hi = $n[$k] - 1;
        while ($lo <= $hi) {
            $mid = ($lo + $hi) >> 1; fseek($fh[$k], $mid * $rec); $r = (string)fread($fh[$k], $rec);
            if ($v6) { $a = substr($r, 0, 16); $b = substr($r, 16, 16); $lt = strcmp($x, $a) < 0; $gt = strcmp($x, $b) > 0; }
            else { $u = unpack('Na/Nb', $r); $lt = $x < $u['a']; $gt = $x > $u['b']; }
            if ($lt) $hi = $mid - 1; elseif ($gt) $lo = $mid + 1; else { $cc = substr($r, $rec - 2, 2); break; }
        }
    }
    return $cache[$ip] = $cc;
}
function cc_name(string $cc): string {
    if (!preg_match('/^[A-Z]{2}$/', $cc)) return 'Rede local ou desconhecido';
    if (class_exists('Locale')) { $n = Locale::getDisplayRegion('-' . $cc, 'pt_PT'); if ($n !== '' && $n !== $cc) return $n; }
    return $cc;
}
function cc_flag(string $cc): string { return preg_match('/^[A-Z]{2}$/', $cc) ? mb_chr(127397 + ord($cc[0])) . mb_chr(127397 + ord($cc[1])) : '🌐'; }
function paginate(array $items, int $per = 50, string $param = 'pg'): array {
    $total = count($items); $pages = max(1, (int)ceil($total / $per)); $pg = min($pages, max(1, (int)qget($param)));
    return [array_slice($items, ($pg - 1) * $per, $per), $pg, $pages, $total];
}
function pager(int $pg, int $pages, int $total, string $param = 'pg', string $what = 'itens'): string {
    if ($pages <= 1) return '';
    $q = $_GET; $link = function (int $p) use ($q, $param) { $q[$param] = $p; return '?' . h(http_build_query($q)); };
    $h = '<nav class="pager" aria-label="Páginas"><span class="mu">' . $total . ' ' . h($what) . '</span>';
    $h .= $pg > 1 ? '<a class="chip sm" href="' . $link($pg - 1) . '">‹ Anterior</a>' : '';
    foreach (array_unique([1, max(1, $pg - 2), $pg - 1, $pg, $pg + 1, min($pages, $pg + 2), $pages]) as $p) {
        if ($p < 1 || $p > $pages) continue;
        $h .= '<a class="chip sm' . ($p === $pg ? ' prim' : '') . '" href="' . $link($p) . '">' . $p . '</a>';
    }
    $h .= $pg < $pages ? '<a class="chip sm" href="' . $link($pg + 1) . '">Seguinte ›</a>' : '';
    return $h . '</nav>';
}
/* ---------- processos: origem de cada um ---------- */
function proc_origin(string $user, string $args): array { // [tipo, rótulo, site]
    if (preg_match('/^mp_([a-z][a-z0-9-]{0,23})$/', $user, $m)) return ['site', 'Site ' . $m[1], $m[1]];
    if (preg_match('/php-fpm: pool mp-fm-/', $args)) return ['painel', 'Painel (ficheiros)', ''];
    if (preg_match('/php-fpm: pool mp-([a-z][a-z0-9-]{0,23})\b/', $args, $m)) return ['site', 'Site ' . $m[1], $m[1]];
    if (preg_match('/^\[.*\]$/', $args)) return ['sistema', 'Kernel', ''];
    if (strpos($args, 'php-fpm: master') === 0) return ['web', 'PHP (FPM)', ''];
    if (in_array($user, ['vmail', 'dovecot', 'dovenull', 'postfix', '_rspamd', 'rspamd', 'redis', 'clamav', 'unbound', 'opendkim'], true)
        || preg_match('#^(/usr/lib/postfix/|/usr/libexec/postfix/|/usr/sbin/(dovecot|rspamd|clamd|freshclam|unbound|postfix)|dovecot/|rspamd:|redis-server|/usr/bin/redis)#', $args)) return ['email', 'Email', ''];
    if ($user === 'mysql' || preg_match('#(^|/)(mariadbd|mysqld)\b#', $args)) return ['bd', 'Base de dados', ''];
    if (in_array($user, ['www-data', 'nginx'], true) || strpos($args, 'nginx:') === 0) return ['web', 'Servidor web', ''];
    if (in_array($user, ['minipainel', 'minipainel-pma', 'mp-webmail'], true) || preg_match('#mpanel|minipainel|ttyd#', $args)) return ['painel', 'Painel', ''];
    if ($user === 'nsd' || preg_match('#(^|/)nsd\b#', $args)) return ['sistema', 'DNS', ''];
    if (preg_match('#pure-ftpd#', $args)) return ['sistema', 'FTP', ''];
    return ['sistema', 'Sistema operativo', ''];
}
function proc_protected_php(int $pid, string $comm, string $args, string $user): bool { // só para a interface; o servidor volta a verificar
    if ($pid <= 2 || preg_match('/^\[.*\]$/', $args)) return true;
    if (preg_match('/^(systemd|systemd-.*|init|dbus-daemon|dbus-broker|agetty|cron|crond|rsyslogd|journald|udevd|polkitd|mariadbd|mysqld|master|containerd|dockerd)$/', $comm)) return true;
    if (preg_match('#^(nginx: master|php-fpm: master|php-fpm: pool minipainel|sshd: /usr/sbin/sshd|/usr/sbin/sshd|/usr/sbin/dovecot|/usr/sbin/nsd|nsd -c)#', $args) || preg_match('#mpanel-stats|mpanel worker#', $args) || $args === 'dovecot') return true;
    return $user === 'minipainel' && strpos($args, 'php-fpm') === 0;
}
function valid_net(string $s): bool {
    $ip = $s; $bits = null;
    if (strpos($s, '/') !== false) { [$ip, $bits] = explode('/', $s, 2); if (!ctype_digit($bits)) return false; }
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return $bits === null || ((int)$bits >= 8 && (int)$bits <= 32);
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return $bits === null || ((int)$bits >= 32 && (int)$bits <= 128);
    return false;
}
/* Descrição em português de uma expressão cron (casos comuns; o resto fica "personalizada") */
function cron_human(string $w): string {
    $w = trim(preg_replace('/\s+/', ' ', $w));
    $macros = ['@hourly' => 'De hora a hora', '@daily' => 'Todos os dias à meia-noite', '@weekly' => 'Aos domingos à meia-noite', '@monthly' => 'No dia 1 de cada mês à meia-noite', '@yearly' => 'Uma vez por ano (1 de janeiro)', '@annually' => 'Uma vez por ano (1 de janeiro)'];
    if (isset($macros[$w])) return $macros[$w];
    $p = explode(' ', $w);
    if (count($p) !== 5) return 'Expressão inválida';
    [$mi, $ho, $dm, $mo, $dw] = $p;
    $days = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
    $hm = function ($h, $m) { return sprintf('%02d:%02d', (int)$h, (int)$m); };
    $n = '/^\d+$/';
    if ($dm === '*' && $mo === '*' && $dw === '*') {
        if ($mi === '*' && $ho === '*') return 'A cada minuto';
        if (preg_match('/^\*\/(\d+)$/', $mi, $m) && $ho === '*') return 'A cada ' . $m[1] . ' minutos';
        if (preg_match($n, $mi) && $ho === '*') return 'De hora a hora, ao minuto ' . (int)$mi;
        if (preg_match($n, $mi) && preg_match('/^\*\/(\d+)$/', $ho, $m)) return 'A cada ' . $m[1] . ' horas, ao minuto ' . (int)$mi;
        if (preg_match($n, $mi) && preg_match($n, $ho)) return 'Todos os dias às ' . $hm($ho, $mi);
    }
    if (preg_match($n, $mi) && preg_match($n, $ho) && $dm === '*' && $mo === '*') {
        if (preg_match('/^[0-7]$/', $dw)) return 'À ' . $days[(int)$dw] . ' às ' . $hm($ho, $mi);
        if ($dw === '1-5') return 'Dias úteis às ' . $hm($ho, $mi);
    }
    if (preg_match($n, $mi) && preg_match($n, $ho) && preg_match($n, $dm) && $mo === '*' && $dw === '*') return 'No dia ' . (int)$dm . ' de cada mês às ' . $hm($ho, $mi);
    return 'Expressão personalizada';
}
function ago(int $t, int $now): string {
    $d = $now - $t;
    if ($d < 60) return 'há instantes';
    if ($d < 3600) return 'há ' . intdiv($d, 60) . ' min';
    if ($d < 86400) return 'há ' . intdiv($d, 3600) . ' h';
    return 'há ' . intdiv($d, 86400) . ' d';
}
function fw_secs_php(string $d): int {
    if (!preg_match('/^(\d+)([smhd]?)$/', $d, $m)) return 0;
    return (int)$m[1] * ['' => 1, 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86400][$m[2]];
}
function valid_site(string $s): bool { return (bool)preg_match(RX_SITE, $s) && substr($s, -1) !== '-'; }
function site_limits(array $s): array {
    $l = is_array($s['limits'] ?? null) ? $s['limits'] : [];
    $o = [];
    foreach (LIMIT_DEFAULTS as $k => $d) $o[$k] = (int)($l[$k] ?? $d);
    $o['display_errors'] = !empty($l['display_errors']);
    return $o;
}
function host_only(): string {
    $h = (string)($_SERVER['HTTP_HOST'] ?? '');
    if ($h === '') $h = (string)($_SERVER['SERVER_ADDR'] ?? 'localhost');
    if ($h !== '' && $h[0] === '[') { $p = strpos($h, ']'); return $p === false ? $h : substr($h, 0, $p + 1); }
    return (string)preg_replace('/:\d+$/', '', $h);
}
function site_url(string $host, int $port): string { return 'http://' . $host . ($port === 80 ? '' : ':' . $port) . '/'; }
function fmt_uptime(int $s): string {
    if ($s >= 86400) { $d = intdiv($s, 86400); return $d . ($d === 1 ? ' dia' : ' dias'); }
    if ($s >= 3600) return intdiv($s, 3600) . ' h';
    return max(1, intdiv($s, 60)) . ' min';
}
function tone(string $name): string {
    $t = ['t-acc', 't-blue', 't-vio', 't-warn'];
    return $t[abs(crc32($name)) % 4];
}

/* ---------- ícones (SVG em linha, sem recursos externos) ---------- */
const ICONS = [
    'dash'   => '<rect x="4" y="4" width="6" height="8" rx="1.5"/><rect x="14" y="4" width="6" height="5" rx="1.5"/><rect x="4" y="16" width="6" height="4" rx="1.5"/><rect x="14" y="13" width="6" height="7" rx="1.5"/>',
    'world'  => '<circle cx="12" cy="12" r="9"/><path d="M3.6 9h16.8M3.6 15h16.8M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    'db'     => '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
    'code'   => '<path d="M7 8l-4 4 4 4M17 8l4 4-4 4M14 4l-4 16"/>',
    'pulse'  => '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
    'user'   => '<circle cx="12" cy="8" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/>',
    'plus'   => '<path d="M12 5v14M5 12h14"/>',
    'dots'   => '<circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="12" cy="19" r="1"/>',
    'reload' => '<path d="M20 11A8 8 0 0 0 5.3 7.5M4 4v4h4M4 13a8 8 0 0 0 14.7 3.5M20 20v-4h-4"/>',
    'power'  => '<path d="M7 6a7.8 7.8 0 1 0 10 0M12 4v8"/>',
    'play'   => '<path d="M7 4v16l13-8z"/>',
    'stop'   => '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    'moon'   => '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/>',
    'sun'    => '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    'out'    => '<path d="M14 8V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2M9 12h12M18 9l3 3-3 3"/>',
    'menu'   => '<path d="M4 6h16M4 12h16M4 18h16"/>',
    'x'      => '<path d="M18 6L6 18M6 6l12 12"/>',
    'ext'    => '<path d="M12 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6M11 13l9-9M15 4h5v5"/>',
    'server' => '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    'cpu'    => '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M10 10h4v4h-4zM3 10h3M3 14h3M18 10h3M18 14h3M10 3v3M14 3v3M10 18v3M14 18v3"/>',
    'sliders'=> '<path d="M4 6h8M16 6h4M4 12h2M10 12h10M4 18h11M19 18h1"/><circle cx="14" cy="6" r="2"/><circle cx="8" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
    'trash'  => '<path d="M4 7h16M10 11v6M14 11v6M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
    'key'    => '<circle cx="8" cy="15" r="4"/><path d="M10.8 12.2L20 3M16 7l3 3M14 9l2 2"/>',
    'lock'   => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    'toggle' => '<rect x="2" y="7" width="20" height="10" rx="5"/><circle cx="8" cy="12" r="2.5"/>',
    'check'  => '<path d="M5 12l5 5L20 7"/>',
    'alert'  => '<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>',
    'table'  => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 10v10M15 10v10"/>',
    'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
    'folder' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    'folderplus' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 10.5v5M9.5 13h5"/>',
    'file'   => '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    'zip'    => '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M10 5h1M10 8h1M10 11h1M10 14h1v3h-1z"/>',
    'upload' => '<path d="M12 16V4M7 9l5-5 5 5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    'download' => '<path d="M12 4v12M7 11l5 5 5-5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    'home'   => '<path d="M4 11l8-7 8 7M6 9.5V20h12V9.5"/>',
    'edit'   => '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
    'move'   => '<path d="M5 12h14M15 8l4 4-4 4M5 5v14"/>',
    'up'     => '<path d="M12 19V5M6 11l6-6 6 6"/>',
    'chev'   => '<path d="M6 9l6 6 6-6"/>',
    'ban'    => '<circle cx="12" cy="12" r="9"/><path d="M5.7 5.7l12.6 12.6"/>',
    'clock'  => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
    'bell'   => '<path d="M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
    'term'   => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M12 15h5"/>',
    'logs'   => '<path d="M5 4h14v16H5z"/><path d="M8 8h8M8 12h8M8 16h5"/>',
    'dns'    => '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/><circle cx="12" cy="12" r="2"/>',
    'mail'   => '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    'archive'=> '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>',
];
/* Logótipo IDDigital Hosting (SVG em linha; o texto usa Arial ou equivalente métrico) */
function brand_logo(string $cls = 'brand-logo'): string {
    return '<svg class="' . h($cls) . '" viewBox="0 0 62.97 18.26" role="img" aria-label="IDDigital Hosting" xmlns="http://www.w3.org/2000/svg">'
        . '<path fill="#fff" d="M 10.696104,17.232981 C 9.5129773,16.842176 8.7260574,16.372185 7.9458244,15.590365 c -1.114,-1.116262 -1.7157692,-2.493883 -1.784426,-4.085056 -0.014374,-0.333159 -0.00865,-0.457078 0.029917,-0.647164 0.099813,-0.491997 0.3189197,-0.9047228 0.6668116,-1.2560559 0.8274806,-0.8356635 2.1314767,-1.0014038 3.189827,-0.405435 0.261545,0.1472777 0.723354,0.5928945 0.865202,0.8348679 0.214006,0.365059 0.316112,0.722462 0.350283,1.226095 0.0346,0.509923 0.209212,0.888772 0.54975,1.192761 0.343775,0.306876 0.717013,0.444297 1.196753,0.440625 0.525886,-0.004 0.905248,-0.154464 1.248715,-0.495181 0.235108,-0.233227 0.351055,-0.432298 0.431021,-0.740031 0.05275,-0.202983 0.05767,-0.273977 0.0419,-0.604108 C 14.662552,9.6065015 14.075119,8.3362136 12.999265,7.3056355 12.048684,6.3950566 10.862731,5.8387523 9.4907979,5.6598913 9.0218609,5.5987579 8.1134294,5.6186003 7.6756472,5.6995508 6.3679108,5.9413587 5.3155828,6.4713126 4.423572,7.3373012 3.910517,7.8353884 3.5632817,8.3130464 3.2715718,8.9219956 2.8556734,9.7901897 2.6909166,10.742689 2.7685575,11.830049 c 0.055923,0.783182 0.1672461,1.327816 0.436759,2.136766 0.1797827,0.539622 0.1806174,0.605202 0.00988,0.77594 -0.094738,0.09474 -0.119626,0.105283 -0.248473,0.105283 -0.1660019,0 -0.2799034,-0.05074 -0.3567817,-0.158919 C 2.5458511,14.598936 2.3598961,14.029801 2.2414377,13.561284 1.9117912,12.2575 1.8815863,10.789106 2.1618329,9.6914849 2.5560106,8.147645 3.6460195,6.7437251 5.1475424,5.8459267 7.3224606,4.545487 10.115883,4.5274669 12.319362,5.7996657 c 1.715935,0.9907074 2.873217,2.6135551 3.201846,4.4899243 0.07645,0.436502 0.110227,0.99086 0.07811,1.282039 -0.09176,0.832016 -0.604065,1.554468 -1.370112,1.932141 -0.425591,0.209822 -0.613626,0.24943 -1.177703,0.248064 -0.448773,-0.0011 -0.503433,-0.007 -0.732963,-0.07746 -0.87301,-0.268526 -1.522411,-0.925309 -1.734383,-1.754115 -0.02862,-0.111896 -0.06518,-0.356227 -0.08124,-0.542947 -0.03397,-0.394862 -0.102412,-0.627427 -0.25685,-0.872738 C 10.033828,10.167463 9.6093692,9.8704218 9.1869714,9.7634095 8.9528412,9.7040972 8.5620269,9.7097502 8.3021585,9.7762077 7.7275959,9.9231553 7.3086886,10.298932 7.111982,10.843844 c -0.074054,0.205143 -0.079853,0.249702 -0.077714,0.597194 0.00823,1.338483 0.5321468,2.601535 1.4809618,3.57036 0.7632773,0.779376 1.5081182,1.232518 2.5716382,1.564519 0.385877,0.120458 0.468886,0.189169 0.489653,0.405307 0.01075,0.111391 0.0027,0.152793 -0.03858,0.199197 -0.06269,0.07051 -0.307281,0.189422 -0.384621,0.187006 -0.03048,-9.44e-4 -0.236233,-0.06145 -0.457226,-0.134457 z M 6.6904661,17.164437 C 6.6024841,17.126114 6.1242485,16.631374 5.8040522,16.247429 5.3889771,15.749717 4.8134382,14.798822 4.5796876,14.224554 4.2080316,13.311486 4.0390981,12.44863 4.0344449,11.439633 4.0315488,10.812052 4.0523334,10.622866 4.1714275,10.192654 4.4032301,9.3552972 4.7979022,8.7065962 5.4566054,8.0802783 6.6288369,6.9656805 8.3477125,6.53442 9.9677565,6.9484445 11.395991,7.3134498 12.624593,8.385578 13.130529,9.7084047 c 0.179752,0.4699833 0.277045,0.9492623 0.284758,1.4027433 0.0039,0.2333 -0.0034,0.280082 -0.05759,0.367839 -0.07922,0.128173 -0.185,0.182331 -0.356132,0.182331 -0.271196,0 -0.421017,-0.180507 -0.42109,-0.50734 C 12.580366,10.630453 12.386096,9.9467474 12.106308,9.4850986 11.519961,8.5176305 10.503356,7.8549032 9.3382846,7.6806177 8.9765395,7.6265032 8.2377737,7.6433484 7.9250422,7.712841 6.3064884,8.0725247 5.1663437,9.216776 4.9019127,10.74686 c -0.048713,0.281867 -0.040483,1.037965 0.016134,1.482521 0.1392626,1.093469 0.435231,1.866856 1.1081841,2.895762 0.2908723,0.444728 0.4825181,0.683363 0.8959562,1.115635 0.2592815,0.271092 0.3388777,0.372163 0.3531957,0.448482 0.04265,0.227351 -0.069562,0.416401 -0.2855706,0.48112 -0.138344,0.04144 -0.193019,0.04037 -0.299346,-0.0059 z m 5.5207159,-1.54205 C 11.244805,15.510073 10.366448,15.094396 9.6752993,14.422292 8.8680425,13.637276 8.3961892,12.623707 8.3226635,11.516734 c -0.014569,-0.219391 -0.00898,-0.29249 0.029947,-0.394527 0.085794,-0.224661 0.3138299,-0.316951 0.5552824,-0.224741 0.1893172,0.0723 0.2336623,0.167004 0.2626962,0.561026 0.047867,0.649573 0.2164175,1.171521 0.5465019,1.692305 0.478925,0.755612 1.285532,1.346508 2.129856,1.56027 0.515341,0.130473 0.954321,0.158609 1.522371,0.09758 0.25322,-0.02721 0.502392,-0.04158 0.553715,-0.03196 0.0597,0.01126 0.129162,0.05719 0.192819,0.127645 0.08538,0.09451 0.0995,0.129217 0.0995,0.244514 0,0.157022 -0.07723,0.291864 -0.21238,0.370795 -0.171403,0.100097 -1.271672,0.163198 -1.791791,0.102753 z M 1.5515958,7.1526948 C 1.4873796,7.1293278 1.3569964,7.0003509 1.3135813,6.9172481 1.2251437,6.7479642 1.2653004,6.6170208 1.5014118,6.304768 2.2840541,5.2697396 3.2799235,4.4288405 4.4123052,3.8468473 5.3878281,3.345472 6.3437639,3.0512582 7.537093,2.8851119 c 0.4932469,-0.068671 1.9175775,-0.068671 2.4108249,0 2.4273701,0.3379607 4.3925631,1.4211281 5.8350501,3.2161431 0.273249,0.3400272 0.399842,0.5400029 0.399842,0.6316181 0,0.2252296 -0.195182,0.4254658 -0.414722,0.4254658 -0.07467,0 -0.158537,-0.019956 -0.201131,-0.047867 C 15.526779,7.0841417 15.377686,6.9100193 15.235648,6.7235286 14.506048,5.7655897 13.583182,5.007309 12.512436,4.485975 11.291939,3.8917299 10.097979,3.6209526 8.7009401,3.6215672 7.275676,3.6221957 6.0752471,3.8976143 4.8738546,4.4996332 3.7786794,5.0484254 2.900244,5.7808957 2.1395936,6.779554 2.0080624,6.952241 1.8662182,7.1112306 1.8243846,7.132865 1.7480846,7.172322 1.6292648,7.18096 1.5515958,7.1526948 Z M 3.8100123,2.7920664 C 3.497075,2.6920703 3.4166986,2.3074566 3.6618987,2.0833121 3.8117352,1.9463439 4.7695509,1.5215205 5.4243361,1.3016113 6.1572227,1.0554732 6.9907558,0.87692327 7.7864887,0.79561623 8.1981408,0.75355388 9.2857142,0.75413562 9.7123764,0.79666083 10.709221,0.89598665 11.56665,1.0988344 12.497294,1.4555195 12.959321,1.6326 13.75672,1.9956248 13.830686,2.0625642 13.908374,2.1328789 13.975124,2.3346744 13.95533,2.4394218 13.925446,2.5975653 13.842688,2.700374 13.702032,2.7540914 13.537356,2.8169826 13.504967,2.807915 12.926808,2.5369619 11.598059,1.9142622 10.445355,1.6422506 8.9975808,1.6097578 7.2861158,1.5713503 5.8249633,1.8966278 4.3478231,2.6448848 4.0272707,2.8072624 3.9358377,2.8322874 3.8100123,2.7920828 Z"/>'
        . '<g font-family="Arial,\'Liberation Sans\',Helvetica,sans-serif" font-weight="700">'
        . '<text x="18.0823" y="12.868" font-size="11.6841" fill="#16a596">id</text>'
        . '<text x="28.9553" y="12.7322" font-size="11.4367" fill="#fff">digital</text>'
        . '<text x="60.362" y="15.427" font-size="2.88254" font-weight="400" fill="#fff" text-anchor="end">hosting</text>'
        . '</g></svg>';
}

function ic(string $n, string $cls = ''): string {
    return '<svg class="i' . ($cls !== '' ? ' ' . $cls : '') . '" viewBox="0 0 24 24" aria-hidden="true">' . (ICONS[$n] ?? '') . '</svg>';
}

/* ---------- fila de tarefas (assíncrona) ---------- */
function job_submit(string $action, array $args, string $label): bool {
    $id = bin2hex(random_bytes(8));
    $payload = json_encode(['id' => $id, 'action' => $action, 'args' => array_values(array_map('strval', $args))]);
    $tmp = MP_TMP . '/' . $id . '.json';
    if (@file_put_contents($tmp, (string)$payload) === false || !@rename($tmp, MP_QUEUE . '/' . $id . '.json')) {
        @unlink($tmp);
        flash(false, 'Não foi possível colocar a tarefa na fila. Verifica as permissões de ' . MP_DATA . '.');
        return false;
    }
    $_SESSION['jobs'][$id] = ['label' => $label, 't' => time()];
    audit($label);
    return true;
}
function job_collect(): int {
    $jobs = is_array($_SESSION['jobs'] ?? null) ? $_SESSION['jobs'] : [];
    foreach ($jobs as $id => $j) {
        $id = (string)$id;
        if (!preg_match('/^[a-f0-9]{16}$/', $id)) { unset($jobs[$id]); continue; }
        $res = MP_RESULTS . '/' . $id . '.json';
        clearstatcache(true, $res);
        if (is_file($res)) {
            $r = jload($res);
            @unlink($res);
            unset($jobs[$id]);
            $ok  = (bool)($r['ok'] ?? false);
            $msg = trim((string)($r['msg'] ?? ''));
            if ($msg === '') $msg = $j['label'] . ($ok ? ': concluído.' : ': falhou.');
            flash($ok, $msg, stripos($msg, 'password') !== false || stripos($msg, 'chave') !== false || stripos($msg, 'recupera') !== false);
            audit($j['label'] . ($ok ? ' — concluído' : ' — falhou'), $ok);
        } elseif (time() - (int)($j['t'] ?? 0) > 1800) {
            unset($jobs[$id]);
            flash(false, $j['label'] . ': sem resposta. No servidor: systemctl status minipainel-worker.path');
        }
    }
    $_SESSION['jobs'] = $jobs;
    return count($jobs);
}

/* ---------- limite de tentativas de login ---------- */
function rl_file(): string { return MP_RL . '/' . hash('sha256', (string)($_SERVER['REMOTE_ADDR'] ?? '')) . '.json'; }
function rl_wait(): int { $d = jload(rl_file()); $u = (int)($d['until'] ?? 0); return $u > time() ? $u - time() : 0; }
function rl_fail(): void {
    $f = rl_file();
    $d = jload($f);
    if ($d === null || time() - (int)($d['first'] ?? 0) > 900) $d = ['n' => 0, 'first' => time()];
    $d['n'] = (int)($d['n'] ?? 0) + 1;
    if ($d['n'] >= 5) $d = ['n' => 0, 'first' => time(), 'until' => time() + 600];
    @file_put_contents($f, (string)json_encode($d), LOCK_EX);
}
function rl_clear(): void { @unlink(rl_file()); }

/* ---------- estilos ---------- */
function mp_head(string $title): string {
    return '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' . h($title) . ' · IDDigital Hosting</title>'
        . '<script>(function(){var t=null;try{t=localStorage.getItem("mp-theme")}catch(e){}if(!t)t=matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";document.documentElement.setAttribute("data-theme",t)})();</script>'
        . mp_css();
}
function mp_css(): string {
    return <<<'CSS'
<style>
:root{--bg:#e8edf2;--card:#fff;--ink:#14222f;--ink-2:#5f6e7c;--ink-3:#8d9aa6;--line:#e1e7ed;--line-2:#edf1f5;--hover:#f6f9fb;
--side:#13283a;--side-ink:#a9b8c6;--side-on:#1f5f8b;--acc:#1f5f8b;--acc-2:#184d72;--acc-bg:#e2edf6;--acc-ink:#1f5f8b;
--field:#eef3f9;--field-line:#d8e2ec;--hl:#1f5f8b;--c1:#1f5f8b;--c2:#66a8d8;--c3:#e0a33a;
--ok:#1c6b40;--ok-bg:#e2f5ea;--err:#b3261e;--err-bg:#fdecea;--warn:#9a5b08;--warn-bg:#fdf1dc;--blue-bg:#e8ecfb;--blue-ink:#3b4fb0;--vio-bg:#f1e9fb;--vio-ink:#6a3fa8;
--shadow:0 1px 2px rgba(16,24,40,.05);--pop:0 16px 40px rgba(16,24,40,.16);color-scheme:light}
[data-theme=dark]{--bg:#0d151d;--card:#16212c;--ink:#e6edf3;--ink-2:#a3b1bf;--ink-3:#728191;--line:#253342;--line-2:#1e2b38;--hover:#1a2733;
--side:#0a131b;--side-ink:#8fa1b3;--side-on:#2a6f9f;--acc:#3584bd;--acc-2:#4996cf;--acc-bg:#16334a;--acc-ink:#8cc4ec;
--field:#1b2836;--field-line:#2a3a4a;--hl:#235b84;--c1:#4a9ad3;--c2:#a8cdee;--c3:#f0b75a;
--ok:#7ed3a4;--ok-bg:#15372a;--err:#f19c95;--err-bg:#3d1b1a;--warn:#f0c27a;--warn-bg:#3a2b12;--blue-bg:#1e2a52;--blue-ink:#a9b6f5;--vio-bg:#2d2143;--vio-ink:#c8adf0;
--shadow:none;--pop:0 16px 40px rgba(0,0,0,.45);color-scheme:dark}
*{box-sizing:border-box}
html,body{margin:0}
body{font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,"Helvetica Neue",sans-serif;background:var(--bg);color:var(--ink);-webkit-font-smoothing:antialiased}
a{color:var(--acc-ink)}
:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
svg.i{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.app{display:grid;grid-template-columns:240px minmax(0,1fr);min-height:100vh}
.side{position:sticky;top:0;height:100vh;background:var(--side);color:var(--side-ink);display:flex;flex-direction:column;gap:2px;padding:18px 14px}
.brand{display:flex;align-items:center;gap:10px;color:#fff;font-weight:650;font-size:17px;padding:2px 10px 22px;text-decoration:none}
.logo{width:32px;height:32px;border-radius:9px;background:var(--acc);display:grid;place-items:center;color:#fff}
.nav a{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:9px;color:var(--side-ink);text-decoration:none;font-weight:500}
.nav a:hover{color:#fff;background:rgba(255,255,255,.04)}
.nav a.on{background:var(--side-on);color:#fff}
.nav a.on svg{color:#5fd0d1}
.nav a svg.tail{width:14px;height:14px;margin-left:auto;opacity:.6}
.side-foot{margin-top:auto;border-top:1px solid rgba(255,255,255,.08);padding:14px 6px 0 10px;display:flex;align-items:center;justify-content:space-between;gap:8px}
.side-foot b{display:block;color:#fff;font-weight:600}
.side-foot span{font-size:12px}
.side-foot form{margin:0}
.iconbtn{display:inline-grid;place-items:center;width:38px;height:38px;border-radius:9px;border:1px solid var(--line);background:var(--card);color:var(--ink-2);cursor:pointer;text-decoration:none}
.iconbtn:hover{color:var(--ink);border-color:var(--ink-3)}
.side .iconbtn{background:transparent;border-color:rgba(255,255,255,.12);color:var(--side-ink)}
.side .iconbtn:hover{color:#fff;border-color:rgba(255,255,255,.3)}
.main{display:flex;flex-direction:column;min-width:0}
.top{display:flex;align-items:center;gap:14px;padding:24px 32px 4px}
.top .grow{flex:1;min-width:0}
.top h1{margin:0;font-size:22px;font-weight:650;letter-spacing:-.01em}
.top p{margin:2px 0 0;color:var(--ink-2);font-size:13px}
.top-actions{display:flex;align-items:center;gap:8px}
.top-actions form{margin:0}
.burger{display:none}
.content{padding:18px 32px 36px;display:flex;flex-direction:column;gap:20px}
.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;box-shadow:var(--shadow);min-width:0}
.stat>div{min-width:0;flex:1}
.tile{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;flex:none}
.tile svg.i{width:21px;height:21px}
.t-acc{background:var(--acc-bg);color:var(--acc-ink)}.t-blue{background:var(--blue-bg);color:var(--blue-ink)}.t-vio{background:var(--vio-bg);color:var(--vio-ink)}.t-warn{background:var(--warn-bg);color:var(--warn)}
.stat .k{color:var(--ink-2);font-size:13px}
.stat .v{font-size:24px;font-weight:650;line-height:1.25}
.stat .v small{font-size:13px;font-weight:500;color:var(--ink-2)}
.meter{height:5px;border-radius:3px;background:var(--line-2);overflow:hidden;margin-top:6px}
.meter i{display:block;height:100%;background:var(--acc);border-radius:3px}
.meter i.hi{background:var(--err)}
.grid2{display:grid;grid-template-columns:minmax(0,3fr) minmax(0,2fr);gap:20px;align-items:start}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);min-width:0}
.card-h{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--line-2)}
.card-h h2{margin:0;font-size:15px;font-weight:650}
.card-h p{margin:0;color:var(--ink-2);font-size:13px}
.card-b{padding:18px}
.card-f{padding:12px 18px;border-top:1px solid var(--line-2);font-size:13px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:38px;padding:0 16px;border-radius:9px;border:1px solid transparent;background:var(--acc);color:#fff;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;white-space:nowrap}
.btn:hover{background:var(--acc-2)}
.btn.sec{background:var(--card);color:var(--ink);border-color:var(--line)}
.btn.sec:hover{border-color:var(--ink-3)}
.btn.dan{background:var(--err);color:#fff}
.btn.dan:hover{filter:brightness(.93)}
.btn.sm{height:32px;padding:0 11px;font-size:13px;border-radius:8px;gap:6px}
.btn.sm svg.i{width:15px;height:15px}
.btn:disabled{opacity:.6;cursor:wait}
.list{width:100%;border-collapse:collapse}
.list th{font-size:12px;font-weight:600;color:var(--ink-2);text-align:left;padding:10px 18px;border-bottom:1px solid var(--line-2)}
.list td{padding:12px 18px;border-bottom:1px solid var(--line-2);vertical-align:middle}
.list tr:last-child td{border-bottom:0}
.list tbody tr:hover td{background:var(--hover)}
.list .r{text-align:right}
.who{display:flex;align-items:center;gap:12px;min-width:0}
.av{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:650;flex:none;text-transform:uppercase}
.nm{font-weight:600}
.mu{color:var(--ink-2);font-size:12.5px}
.pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.pill::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
.p-ok{background:var(--ok-bg);color:var(--ok)}.p-warn{background:var(--warn-bg);color:var(--warn)}.p-off{background:var(--line-2);color:var(--ink-2)}.p-err{background:var(--err-bg);color:var(--err)}
.port{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-weight:600;background:var(--acc-bg);color:var(--acc-ink);padding:2px 8px;border-radius:6px;font-size:12.5px}
.lim{display:flex;flex-wrap:wrap;gap:4px 10px;color:var(--ink-2);font-size:12.5px}
.lim b{color:var(--ink);font-weight:600}
.links a{display:inline-flex;align-items:center;gap:5px;text-decoration:none;font-weight:500}
.links a svg.i{width:14px;height:14px}
.row-list .item{display:flex;align-items:center;gap:12px;padding:12px 18px;border-bottom:1px solid var(--line-2)}
.row-list .item:last-child{border-bottom:0}
.row-list .grow{flex:1;min-width:0}
.row-list .item>.pill:first-child{min-width:74px;justify-content:center}
.svc-acts{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.svc-acts form{margin:0}
details.dd{position:relative;display:inline-block}
details.dd>summary{list-style:none;cursor:pointer}
details.dd>summary::-webkit-details-marker{display:none}
.dd-menu{position:absolute;right:0;top:calc(100% + 6px);z-index:30;min-width:220px;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:6px}
.dd-menu form{margin:0}
.dd-menu a,.dd-menu button{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;background:none;border-radius:8px;color:var(--ink);font:inherit;text-align:left;cursor:pointer;text-decoration:none}
.dd-menu a:hover,.dd-menu button:hover{background:var(--line-2)}
.dd-menu .dan{color:var(--err)}
.dd-menu hr{border:0;border-top:1px solid var(--line-2);margin:6px 2px}
dialog{border:0;padding:0;border-radius:16px;background:var(--card);color:var(--ink);width:min(520px,calc(100vw - 24px));max-height:calc(100vh - 24px);box-shadow:var(--pop)}
dialog::backdrop{background:rgba(8,14,20,.55)}
dialog[open]{display:flex;flex-direction:column}
dialog form{display:flex;flex-direction:column;min-height:0;flex:1;margin:0}
dialog.drawer{margin:0 0 0 auto;height:100vh;max-height:100vh;width:min(480px,100vw);border-radius:16px 0 0 16px}
.dlg-h{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:18px 22px;border-bottom:1px solid var(--line-2)}
.dlg-h h3{margin:0;font-size:17px;font-weight:650}
.dlg-h p{margin:2px 0 0;color:var(--ink-2);font-size:13px}
.dlg-b{padding:20px 22px;display:grid;gap:16px;overflow:auto;flex:1;align-content:start}
.dlg-f{display:flex;justify-content:flex-end;gap:8px;padding:14px 22px;border-top:1px solid var(--line-2)}
.fld{display:flex;flex-direction:column;gap:6px;font-size:13px;color:var(--ink-2);font-weight:500}
.fld small{font-weight:400;color:var(--ink-3);font-size:12px}
.in{height:40px;padding:0 12px;border:1px solid var(--line);border-radius:9px;background:var(--card);color:var(--ink);font:inherit;width:100%}
.in:focus{outline:0;border-color:var(--acc);box-shadow:0 0 0 3px var(--acc-bg)}
.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.fsec{margin:6px 0 -4px;padding-top:14px;border-top:1px solid var(--line-2);font-size:13px;font-weight:650;color:var(--ink)}
.chk{display:flex;align-items:center;gap:10px;font-size:14px;color:var(--ink);font-weight:400}
.chk input{width:18px;height:18px;accent-color:var(--acc)}
.warnbox{padding:12px 14px;border-radius:10px;background:var(--warn-bg);color:var(--warn);font-size:13px}
.pills{display:flex;flex-wrap:wrap;gap:6px}
.pills a{padding:5px 12px;border:1px solid var(--line);border-radius:999px;color:var(--ink);text-decoration:none;font-size:13px;font-weight:500}
.pills a:hover{border-color:var(--ink-3)}
.pills a.on{background:var(--acc);border-color:var(--acc);color:#fff}
.lead{margin:0;padding:14px 18px 0;color:var(--ink-2);font-size:13px}
.exts{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px;padding:16px 18px 18px}
.ext{display:flex;align-items:center;justify-content:space-between;gap:12px;border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.ext.on{border-color:var(--ok-bg);background:var(--hover)}
.ext .d{min-width:0}
.ext .d b{display:block;font-weight:600}
.ext .d span{display:block;color:var(--ink-2);font-size:12.5px}
.ext form{display:flex;align-items:center;gap:8px;margin:0}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{padding:2px 9px;border:1px solid var(--line);border-radius:6px;background:var(--hover);font-size:12px}
.empty{padding:40px 20px;text-align:center;color:var(--ink-2)}
.empty b{display:block;color:var(--ink);font-size:15px;margin-bottom:4px}
.empty .btn{margin-top:14px}
.toasts{position:fixed;top:16px;right:16px;z-index:100;display:flex;flex-direction:column;gap:10px;width:min(420px,calc(100vw - 32px))}
.toast{display:flex;gap:12px;align-items:flex-start;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:12px 12px 12px 14px}
.toast .ti{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;flex:none}
.toast .ti svg.i{width:15px;height:15px}
.toast.ok .ti{background:var(--ok-bg);color:var(--ok)}
.toast.err .ti{background:var(--err-bg);color:var(--err)}
.toast .msg{flex:1;min-width:0;white-space:pre-wrap;font-size:13.5px;padding-top:2px;overflow-wrap:anywhere}
.toast .msg.mono{font-size:12.5px}
.toast button{border:0;background:none;color:var(--ink-3);cursor:pointer;padding:2px;display:grid}
.spin{width:16px;height:16px;border:2px solid var(--line);border-top-color:var(--acc);border-radius:50%;animation:sp .8s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.scrim{display:none}
.login{min-height:100vh;display:grid;place-items:center;padding:24px}
.login form{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--pop);padding:30px;display:flex;flex-direction:column;gap:16px}
.login .brand{color:var(--ink);justify-content:center;padding:0 0 6px}
.login .err{padding:10px 12px;border-radius:10px;background:var(--err-bg);color:var(--err);font-size:13px}
a.stat{color:inherit;text-decoration:none}
a.stat:hover{border-color:var(--ink-3)}
.stat.hot{border-color:var(--err)}
.stat.hot .v,.stat.hot .k{color:var(--err)}
.stats5{grid-template-columns:repeat(5,minmax(0,1fr))}
.stats5 .v small{display:block;font-size:12.5px;line-height:1.4;margin-top:2px}
.stats5 .v small,.stats5 .mu{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.stats5 .mu{font-size:12.5px}
@media (max-width:1600px) and (min-width:1181px){.stats5 .tile{display:none}}
.grid2e{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:20px;align-items:start}
.legend{display:flex;gap:14px;flex-wrap:wrap;color:var(--ink-2);font-size:12.5px;margin-right:auto}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.legend i.dash{background:none;border-top:2px dashed var(--err);height:0;width:14px;border-radius:0;vertical-align:3px;opacity:.7}
.chart{display:grid;grid-template-columns:60px minmax(0,1fr);grid-template-rows:200px 26px;padding:18px 20px 10px 0}
.ch-y{position:relative}
.ch-y span{position:absolute;right:10px;transform:translateY(-50%);font-size:11.5px;color:var(--ink-3);white-space:nowrap}
.ch-plot{position:relative;border-left:1px solid var(--line);border-bottom:1px solid var(--line)}
.ch-plot svg{position:absolute;inset:0;width:100%;height:100%;overflow:visible}
.ch-plot path.s{fill:none;stroke-width:2;vector-effect:non-scaling-stroke;stroke-linejoin:round;stroke-linecap:round}
.ch-plot line.g{stroke:var(--line-2);stroke-width:1;vector-effect:non-scaling-stroke}
.ch-plot line.ref{stroke:var(--err);stroke-width:1.5;stroke-dasharray:5 5;vector-effect:non-scaling-stroke;opacity:.6}
.ch-x{grid-column:2;position:relative}
.ch-x span{position:absolute;top:7px;transform:translateX(-50%);font-size:11.5px;color:var(--ink-3);white-space:nowrap}
.ch-x span.first{transform:none}
.ch-x span.last{transform:translateX(-100%)}
.ch-cur{position:absolute;top:0;bottom:0;width:1px;background:var(--ink-3);display:none;pointer-events:none}
.ch-tip{position:absolute;top:8px;display:none;background:var(--card);border:1px solid var(--line);border-radius:10px;box-shadow:var(--pop);padding:8px 10px;font-size:12px;pointer-events:none;white-space:nowrap;z-index:5;margin:0 10px}
.ch-tip b{display:block;margin-bottom:4px;font-weight:600}
.ch-tip i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:6px}
.ch-empty{position:absolute;inset:0;display:grid;place-items:center;color:var(--ink-2);font-size:13px;text-align:center;padding:0 20px}
.fm-bar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--line-2)}
.fm-site{width:auto;min-width:170px}
.crumbs{display:flex;align-items:center;flex-wrap:wrap;gap:2px;flex:1;min-width:0;font-size:14px}
.crumbs button{border:0;background:none;color:var(--acc-ink);font:inherit;cursor:pointer;padding:4px 6px;border-radius:6px;display:inline-flex;align-items:center;gap:6px}
.crumbs button:hover{background:var(--line-2)}
.crumbs button:last-child{color:var(--ink);font-weight:600}
.crumbs .sep{color:var(--ink-3)}
.fm-tools{display:flex;gap:8px;flex-wrap:wrap}
.fm-tools label.btn{cursor:pointer}
.fm-selbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 18px;background:var(--acc-bg);color:var(--acc-ink);border-bottom:1px solid var(--line-2);font-size:13.5px;font-weight:600}
.fm-selbar[hidden]{display:none}
.fm-selbar .grow{flex:1}
.fm-drop{position:relative;min-height:240px}
.fm-drop.over{outline:2px dashed var(--acc);outline-offset:-8px;background:var(--hover)}
.fm-hint{display:none}
.fm-drop.over .fm-hint{display:grid;place-items:center;position:absolute;inset:0;font-weight:600;color:var(--acc-ink);pointer-events:none;background:rgba(18,164,166,.06)}
.fm-first{display:flex;align-items:center;gap:12px;min-width:0}
.fm-name{display:inline-flex;align-items:center;gap:10px;border:0;background:none;color:var(--ink);font:inherit;cursor:pointer;padding:0;text-align:left;min-width:0;max-width:100%}
.fm-name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-name:hover span{color:var(--acc-ink);text-decoration:underline}
svg.i.dir{color:#d99a2b}
svg.i.zip{color:var(--vio-ink)}
svg.i.code{color:var(--blue-ink)}
svg.i.file{color:var(--ink-3)}
.fm-ck{display:inline-flex;align-items:center}
.fm-ck input{width:16px;height:16px;margin:0;accent-color:var(--acc)}
.fm-list th:first-child{display:flex;align-items:center;gap:12px}
.fm-list tr.sel td{background:var(--acc-bg)}
.fm-menu{position:fixed;z-index:70;min-width:220px;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:6px}
.fm-menu[hidden]{display:none}
.fm-menu button{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;background:none;border-radius:8px;color:var(--ink);font:inherit;text-align:left;cursor:pointer}
.fm-menu button:hover{background:var(--line-2)}
.fm-menu .dan{color:var(--err)}
.fm-menu hr{border:0;border-top:1px solid var(--line-2);margin:6px 2px}
.ups{position:fixed;right:16px;bottom:16px;z-index:90;width:min(420px,calc(100vw - 32px));max-height:50vh;display:flex;flex-direction:column;background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--pop)}
.ups[hidden]{display:none}
.ups-h{display:flex;align-items:center;gap:10px;padding:10px 12px 10px 16px;border-bottom:1px solid var(--line-2)}
.ups-h span{flex:1;color:var(--ink-2);font-size:12.5px}
.ups-l{overflow:auto}
.up{padding:10px 16px;border-bottom:1px solid var(--line-2);font-size:13px}
.up:last-child{border-bottom:0}
.up .nm2{display:flex;justify-content:space-between;gap:10px}
.up .nm2 span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.up .nm2 span:last-child{color:var(--ink-2);white-space:nowrap}
.up .bar{height:5px;border-radius:3px;background:var(--line-2);margin-top:6px;overflow:hidden}
.up .bar i{display:block;height:100%;width:0;background:var(--acc);border-radius:3px;transition:width .2s}
.up.ok .bar i{background:#2ea36a}
.up.err .bar i{background:var(--err)}
.up.err .nm2 span:last-child{color:var(--err);white-space:normal;text-align:right}
dialog.fm-ed{width:min(1100px,100vw)}
.fm-ed .dlg-h p{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-ed textarea{flex:1;min-height:0;width:100%;border:0;resize:none;padding:16px 22px;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--card);color:var(--ink);tab-size:4;outline:0;white-space:pre;overflow:auto}
.fm-ed .dlg-f{align-items:center}
.fm-ed .dlg-f .mu{flex:1}
/* ---------- tema v1.5 ---------- */
body{font-size:14.5px}
h1,h2,h3,.brand,.stat .v,.hl .v{letter-spacing:-.015em}
.app{grid-template-columns:282px minmax(0,1fr)}
.side{top:12px;margin:12px 0 12px 12px;height:calc(100vh - 24px);border-radius:24px;padding:24px 14px 18px;gap:2px;overflow-y:auto}
.brand{padding:2px 12px 16px;font-size:18px}
.logo{border-radius:11px;background:var(--side-on)}
.nav-sec{padding:18px 14px 8px;font-size:12px;font-weight:600;color:#7f95a8}
.nav a{padding:11px 14px;border-radius:13px;color:#d3dee8;font-weight:600}
.nav a:hover{background:rgba(255,255,255,.05);color:#fff}
.nav a.on{background:var(--side-on);color:#fff}
.nav a.on svg{color:#fff}
.side-foot{display:block;margin-top:auto;border-top:0;padding:16px 14px 0;color:#7f95a8;font-size:12px}
.top{padding:24px 34px 6px 30px;gap:12px;align-items:center}
.crumb{font-size:12.5px;font-weight:600;color:var(--ink-2);margin-bottom:2px}
.top h1{font-size:26px;font-weight:750}
.top p{margin-top:4px}
.top-actions{gap:10px;flex-wrap:wrap;justify-content:flex-end}
.chip{display:inline-flex;align-items:center;gap:8px;height:44px;padding:0 18px;border-radius:999px;background:var(--card);box-shadow:0 1px 2px rgba(16,40,64,.05),0 4px 14px rgba(16,40,64,.05);border:0;color:var(--ink);font:inherit;font-weight:600;cursor:pointer;text-decoration:none;white-space:nowrap}
.chip:hover{color:var(--acc-ink)}
.chip svg.i{width:17px;height:17px}
.chip.sm{height:32px;padding:0 14px;font-size:13px;box-shadow:none;background:var(--line-2)}
.chip.ghost{background:transparent;box-shadow:none;color:var(--ink-2);font-weight:500;padding:0 4px;cursor:default}
.chip.prim{background:var(--acc);color:#fff}
.chip.prim:hover{background:var(--acc-2);color:#fff}
.chip.icon{width:44px;padding:0;justify-content:center}
.chip.soft{background:var(--acc-bg);color:var(--acc-ink);box-shadow:none}
.chip.soft:hover{filter:brightness(.97)}
details.me>summary{list-style:none;padding:0 14px 0 7px}
details.me>summary::-webkit-details-marker{display:none}
.av-me{width:32px;height:32px;border-radius:50%;background:var(--acc);color:#fff;display:grid;place-items:center;font-weight:700;font-size:13px;text-transform:uppercase}
svg.i.chev{width:15px;height:15px;color:var(--ink-3)}
.content{padding:16px 34px 40px 30px;gap:24px}
.card,.stat{border:0;border-radius:24px;box-shadow:0 1px 2px rgba(16,40,64,.04),0 10px 30px rgba(16,40,64,.05)}
.card-h{padding:24px 28px;border-bottom:1px solid var(--line-2)}
.card-h h2{font-size:17px;font-weight:700}
.card-h>div>p{margin:4px 0 0}
.card-b{padding:24px 28px}
.card-f{padding:16px 28px}
.stat{padding:20px 22px}
.tile{border-radius:14px}
.btn{height:42px;border-radius:12px}
.btn.sm{height:34px;border-radius:10px}
.in{height:46px;border-radius:12px;background:var(--field);border-color:var(--field-line)}
.in:focus{background:var(--card);border-color:var(--acc);box-shadow:0 0 0 4px var(--acc-bg)}
.list th{padding:14px 28px;font-size:12.5px}
.list td{padding:16px 28px}
.row-list .item{padding:15px 28px}
.lead{padding:16px 28px 0}
.exts{padding:18px 28px 24px}
.ext{border-radius:16px}
.pill{padding:4px 12px}
.pills a{padding:7px 15px;font-weight:600}
.pills a.on{background:var(--acc);border-color:var(--acc)}
dialog{border-radius:24px}
dialog.drawer{border-radius:24px 0 0 24px}
.dlg-h,.dlg-b,.dlg-f{padding-left:26px;padding-right:26px}
.dd-menu,.fm-menu{border-radius:16px}
.toast{border-radius:16px}
.ups{border-radius:20px}
.fm-bar,.fm-selbar{padding-left:28px;padding-right:28px}
.chart{padding:22px 28px 12px 0}
.ch-plot path.a{stroke:none;fill-opacity:.1}
.ch-plot path.dot{fill:none;stroke-width:7;stroke-linecap:round;vector-effect:non-scaling-stroke}
.hero{display:grid;grid-template-columns:minmax(0,2.3fr) minmax(0,1fr);gap:24px;align-items:stretch}
.hl{background:var(--hl);color:#fff;border-radius:24px;padding:28px 30px 0;display:flex;flex-direction:column;overflow:hidden;min-height:320px;box-shadow:0 10px 30px rgba(16,40,64,.12)}
.hl .k{font-weight:700;font-size:15px;color:rgba(255,255,255,.9)}
.hl .v{font-size:60px;font-weight:800;line-height:1.05;margin-top:12px}
.hl .s{color:rgba(255,255,255,.85);font-weight:600;font-size:14px;margin-top:8px}
.hl svg{display:block;margin:auto -30px 0;width:calc(100% + 60px);height:130px}
.bars .item{display:grid;grid-template-columns:minmax(170px,1.3fr) minmax(0,1.4fr) 64px 104px 40px;gap:16px;align-items:center}
.bars .mu{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bars .num{text-align:right;font-variant-numeric:tabular-nums}
.bars .bar{height:8px;border-radius:4px;background:var(--line-2);overflow:hidden}
.bars .bar i{display:block;height:100%;background:var(--acc);border-radius:4px}
.bars .pill{justify-self:start}
.brand{display:flex;align-items:center}
.brand-logo{display:block;height:46px;width:auto;max-width:100%}
.auth-side .brand-logo{height:58px}
.cn-search{width:260px;height:40px}
.cn-hot{color:var(--err)}
.p-me{background:var(--acc-bg);color:var(--acc-ink)}
.p-me::before{display:none}
.btn.danger-o{background:var(--card);color:var(--err);border:1px solid #e3b4af}
.btn.danger-o:hover{background:var(--err-bg)}
.cron-cmd{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:460px}
.cron-when{white-space:nowrap}
.cron-fields{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px}
.cron-fields .in{text-align:center;padding:0 6px}
.cron-human{padding:10px 14px;border-radius:12px;background:var(--acc-bg);color:var(--acc-ink);font-weight:600;font-size:13.5px}
.cron-human.bad{background:var(--err-bg);color:var(--err)}
.cron-ta{height:auto;min-height:84px;padding:10px 12px;resize:vertical;line-height:1.5}
.cron-help{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:-6px}
.cron-out{margin:0;padding:18px 26px;max-height:60vh;overflow:auto;font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;background:var(--hover)}
@media (max-width:900px){.cron-fields{grid-template-columns:repeat(3,minmax(0,1fr))}.cron-cmd{max-width:60vw}}
.bk-run .item{gap:16px}
.tabs{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.pager{display:flex;align-items:center;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.sn-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(380px,1fr));gap:20px;align-items:start}
.sn-dot{width:12px;height:12px;border-radius:50%;flex:none;margin-top:4px}
.sn-ok{background:var(--ok)}.sn-warn{background:var(--warn)}.sn-fail{background:var(--err);box-shadow:0 0 0 4px color-mix(in srgb,var(--err) 20%,transparent)}
.sn-av{padding:8px 24px 20px}
.sn-row{display:grid;grid-template-columns:260px 1fr 80px;gap:16px;align-items:center;padding:8px 0;border-bottom:1px solid var(--line)}
.sn-n{display:flex;flex-direction:column}.sn-pc{text-align:right}
.sn-days{display:grid;grid-template-columns:repeat(30,1fr);gap:3px}
.sn-days i{height:22px;border-radius:4px;background:var(--line)}.sn-days i.g{background:var(--ok)}.sn-days i.y{background:var(--warn)}.sn-days i.r{background:var(--err)}
.sn-chk{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:6px 18px}
@media (max-width:900px){.sn-row{grid-template-columns:1fr}}
.dlg-sec{margin:18px 0 6px;font-size:14px;padding-top:14px;border-top:1px solid var(--line)}
.infobox{background:color-mix(in srgb,var(--acc) 8%,var(--card));border:1px solid var(--line);border-radius:12px;padding:10px 12px;font-size:12.5px;line-height:1.6;margin:6px 0}
.pr-sum{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px;padding:18px 24px}
.pr-o{border:1px solid var(--line);border-radius:16px;padding:12px 14px}
.pr-o .nm{margin-bottom:8px;display:flex;align-items:center;justify-content:space-between;gap:8px;white-space:nowrap}
.pr-cmd{max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}
@media (min-width:901px){#pr table{table-layout:fixed;width:100%}
#pr th:nth-child(1){width:80px}#pr th:nth-child(2){width:180px}#pr th:nth-child(3){width:90px}#pr th:nth-child(4){width:110px}#pr th:nth-child(5){width:80px}#pr th:nth-child(7){width:130px}}
.pager .mu{margin-right:6px}
.cc-flag{font-size:18px;line-height:1;font-family:"Segoe UI Emoji","Apple Color Emoji","Noto Color Emoji",sans-serif}
.cbar{height:6px;border-radius:99px;background:var(--line);margin:6px 0 4px;overflow:hidden}
.cbar span{display:block;height:100%;background:var(--acc)}
.ovl-on{border:1px solid var(--err);background:color-mix(in srgb,var(--err) 8%,var(--card))}
.ovl-on b{color:var(--err)}
.term-wrap{position:relative;height:calc(100vh - 260px);min-height:420px;background:#000;border-radius:0 0 24px 24px;overflow:hidden}
.term-wrap iframe{display:none;width:100%;height:100%;border:0}
.term-wait{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:10px;color:#cbd5e1}
.grid3{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px}
@media (max-width:1100px){.grid3{grid-template-columns:1fr}}
.lg-url{display:inline-block;max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom}
.lg-ua{max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lg-raw{max-height:70vh;font-size:12px}
.lg-filters{display:flex;gap:8px;flex-wrap:wrap}
.lg-filters .in{height:38px;width:auto;min-width:120px}
.kv{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid var(--line-2)}
.kv span{color:var(--ink-2)}
.dd-menu a[aria-current]{background:var(--hover);font-weight:700}
details.dd.sys .dd-menu{min-width:230px}
details.dd>summary.chip.cur{box-shadow:inset 0 0 0 2px var(--acc);color:var(--acc)}
.fm-pre{display:flex;align-items:center;gap:6px;flex-wrap:nowrap;white-space:nowrap;flex:0 0 auto}
.fm-pre + .crumbs{margin-left:-6px}
.fm-pre a{display:inline-flex;align-items:center;gap:6px;color:var(--ink-2);text-decoration:none;font-weight:600}
.fm-pre a:hover{color:var(--acc)}
.fm-pre span{color:var(--ink-3)}
.fm-root a.who{text-decoration:none;color:inherit}
.fm-root a.who:hover .nm{color:var(--acc)}
.wm-card .item{gap:16px}
.tabs .chip{text-decoration:none}
.bar{height:8px;border-radius:99px;background:var(--hover);overflow:hidden;margin-bottom:4px}
.bar span{display:block;height:100%;background:var(--acc);border-radius:99px}
.bar span.hot{background:var(--err)}
.dnsrec td{vertical-align:top}
.dnsval{max-width:520px;word-break:break-all;font-size:12px;user-select:all;padding:6px 8px;border-radius:8px;background:var(--hover)}
.lnk{border:0;background:none;color:var(--ink-2);font:inherit;text-decoration:underline;cursor:pointer;padding:0;display:block;margin:0 auto}
.tfa{display:grid;grid-template-columns:auto 1fr;gap:24px;align-items:center}
.tfa-qr{background:#fff;border-radius:12px;padding:6px;line-height:0;min-width:180px;min-height:180px}
.tfa-qr svg{width:180px;height:180px}
.tfa-side{display:flex;flex-direction:column;gap:12px}
.tfa-key{padding:10px 12px;border-radius:10px;background:var(--hover);font-size:15px;letter-spacing:.05em;word-break:break-all}
@media (max-width:900px){.tfa{grid-template-columns:1fr}}
.links.dom{margin-bottom:4px}
.links.dom a{font-weight:600}
svg.i.lock{width:14px;height:14px;color:#2ea36a;margin-right:4px;vertical-align:-2px}
.mode-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
.mode{display:grid;grid-template-columns:auto 1fr;grid-template-rows:auto auto;gap:4px 14px;align-items:center;padding:18px;border:2px solid var(--line);border-radius:18px;cursor:pointer;color:var(--ink);font-weight:400}
.mode input{position:absolute;opacity:0;pointer-events:none}
.mode .tile{grid-row:1 / 3}
.mode b{font-size:16px}
.mode .mu{grid-column:2;font-size:13px}
.mode.on,.mode:has(input:checked){border-color:var(--acc);background:var(--acc-bg)}
@media (max-width:900px){.mode-grid{grid-template-columns:1fr}}
dialog{text-align:left}
.rm-grp{display:grid;gap:14px}
.rm-grp[hidden]{display:none}
.auth{background:var(--card)}
.auth-wrap{display:grid;grid-template-columns:1fr 1fr;min-height:100vh}
.auth-side{background-color:#13283a;background-image:linear-gradient(rgba(255,255,255,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px);background-size:48px 48px;color:#fff;padding:52px 56px;display:flex;flex-direction:column;justify-content:space-between;gap:40px}
.auth-side .brand{color:#fff;padding:0}
.auth-side .logo{background:#1f5f8b}
.auth-hero h1{margin:0;font-size:clamp(36px,3.6vw,56px);line-height:1.08;font-weight:800;letter-spacing:-.025em}
.auth-hero h1 span{color:#9db8cf}
.auth-hero p{margin:20px 0 0;max-width:460px;color:#c6d3de;font-size:17px;line-height:1.55}
.auth-foot{color:#8ea4b7;font-size:13px}
.auth-main{display:grid;place-items:center;padding:40px 28px;background:var(--card)}
.auth-form{width:min(380px,100%);display:flex;flex-direction:column;gap:18px}
.auth-form h2{margin:0;font-size:28px;font-weight:750;letter-spacing:-.02em}
.auth-form>p{margin:-10px 0 6px;color:var(--ink-2)}
.auth-form .fld{color:var(--ink);font-weight:600;font-size:14px}
.auth-form .btn{height:52px;border-radius:14px;font-size:15px;margin-top:4px}
.auth-form .err{padding:12px 14px;border-radius:12px;background:var(--err-bg);color:var(--err);font-size:13.5px}
@media (max-width:1180px){.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.grid2{grid-template-columns:1fr}.stats5{grid-template-columns:repeat(3,minmax(0,1fr))}.grid2e{grid-template-columns:1fr}}
@media (max-width:900px){
  .app{grid-template-columns:1fr}
  .side{position:fixed;left:0;top:0;bottom:0;height:auto;width:264px;z-index:60;transform:translateX(-100%);transition:transform .2s ease}
  body.nav-open .side{transform:none}
  body.nav-open .scrim{display:block;position:fixed;inset:0;background:rgba(8,14,20,.55);z-index:50}
  .burger{display:inline-grid}
  .top{padding:14px 16px 2px;gap:10px}
  .top h1{font-size:19px}
  .top p{display:none}
  .top-actions .btn .lbl{display:none}
  .top-actions .btn{width:38px;padding:0}
  .content{padding:12px 16px 28px;gap:16px}
  .stats{gap:12px}
  .stat{padding:12px;gap:10px;flex-direction:column;align-items:flex-start}
  .tile{width:36px;height:36px;border-radius:10px}
  .stat .v{font-size:20px}
  .fgrid{grid-template-columns:1fr}
  .in{font-size:16px}
  table.cards thead{display:none}
  table.cards,table.cards tbody,table.cards tr,table.cards td{display:block;width:100%}
  table.cards tr{position:relative;padding:12px 16px;border-bottom:1px solid var(--line-2)}
  table.cards tr:last-child{border-bottom:0}
  table.cards tbody tr:hover td{background:none}
  table.cards td{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:5px 0;border:0;text-align:right}
  table.cards td::before{content:attr(data-label);color:var(--ink-2);font-size:12.5px;text-align:left;flex:none}
  table.cards td.first{display:block;text-align:left;padding:0 44px 8px 0}
  table.cards td.first::before,table.cards td.act::before{content:none}
  table.cards td.act{position:absolute;top:12px;right:12px;width:auto;padding:0}
  table.cards .lim{justify-content:flex-end}
  .row-list .item{flex-wrap:wrap}
  .svc-acts{width:100%;justify-content:flex-start}
  .exts{grid-template-columns:1fr;padding:14px 16px}
  dialog.drawer{width:100vw;border-radius:0}
  .stats5{grid-template-columns:repeat(2,minmax(0,1fr))}
  .chart{grid-template-columns:44px minmax(0,1fr);grid-template-rows:160px 24px}
  .fm-site{width:100%}
  .crumbs{flex-basis:100%}
  .fm-tools{width:100%}
  .fm-tools .btn{flex:1}
  .fm-list td.first{padding-right:44px}
  .ups{right:8px;left:8px;bottom:8px;width:auto}
  .toasts{top:auto;bottom:16px;right:16px}
}
@media (max-width:420px){.stats{grid-template-columns:1fr 1fr}.stat .v small{display:block}}
@media (max-width:1180px){.hero{grid-template-columns:1fr}.hl{min-height:260px}}
@media (max-width:900px){
  .side{margin:0;top:0;height:100vh;border-radius:0 24px 24px 0}
  .top{padding:14px 16px 4px}
  .top .hide-m,.chip .lbl{display:none}
  .top{flex-wrap:wrap}
  .top-actions{order:3;width:100%;justify-content:flex-start}
  .ch-x span:nth-child(even){display:none}
  .hl{min-height:220px}
  .chip.prim,.chip{height:40px}
  .chip.prim{width:40px;padding:0;justify-content:center}
  details.me>summary{padding:0 4px}
  .content{padding:12px 16px 28px;gap:18px}
  .card-h,.card-b,.card-f,.row-list .item,.lead,.exts,.fm-bar,.fm-selbar{padding-left:18px;padding-right:18px}
  .chart{padding:16px 16px 10px 0}
  .hl{padding:22px 22px 0}
  .hl svg{margin:auto -22px 0;width:calc(100% + 44px)}
  .hl .v{font-size:46px}
  .bars .item{grid-template-columns:minmax(0,1fr) auto auto;gap:10px 12px}
  .bars .bar{grid-column:1 / -1;order:9}
  .bars .num{order:2}
  .auth-wrap{grid-template-columns:1fr}
  .auth-side{padding:28px 24px;gap:26px}
  .auth-hero h1{font-size:32px}
  .auth-hero p{font-size:15px}
  .auth-foot{display:none}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation-duration:2s!important}}
</style>
CSS;
}

function render_login(string $err, bool $two = false): void { ?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head('Entrar') ?></head>
<body class="auth">
<div class="auth-wrap">
  <section class="auth-side">
    <span class="brand"><?= brand_logo() ?></span>
    <div class="auth-hero">
      <h1>Gerir o servidor<br><span>e todos os sites.</span></h1>
      <p>Sites, bases de dados, ficheiros e serviços, a partir de um só painel.</p>
    </div>
    <div class="auth-foot">© <?= date('Y') ?> IDDigital Hosting · v<?= h(MP_VERSION) ?></div>
  </section>
  <section class="auth-main">
    <?php if ($two): ?>
    <form method="post" action="./" class="auth-form">
      <h2>Verificação em dois passos</h2>
      <p>Introduz o código de 6 dígitos da aplicação de autenticação.</p>
      <?php if ($err !== ''): ?><div class="err"><?= h($err) ?></div><?php endif; ?>
      <?= csrf_field() ?>
      <label class="fld">Código<input class="in mono" name="code" inputmode="numeric" autocomplete="one-time-code" required autofocus maxlength="14" placeholder="123456"></label>
      <button class="btn" type="submit">Confirmar</button>
      <p class="mu" style="margin:0;font-size:13px">Sem acesso à aplicação? Usa um dos códigos de recuperação (ex.: a1b2c3-d4e5f6).</p>
    </form>
    <form method="post" action="./" style="margin-top:-8px"><?= csrf_field() ?><input type="hidden" name="a" value="cancel2fa"><button class="lnk" type="submit">Voltar</button></form>
    <?php else: ?>
    <form method="post" action="./" class="auth-form">
      <h2>Iniciar sessão</h2>
      <p>Acede ao painel de alojamento.</p>
      <?php if ($err !== ''): ?><div class="err"><?= h($err) ?></div><?php endif; ?>
      <?= csrf_field() ?>
      <label class="fld">Utilizador<input class="in" name="user" autocomplete="username" required autofocus></label>
      <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="current-password" required></label>
      <button class="btn" type="submit">Entrar</button>
    </form>
    <?php endif; ?>
  </section>
</div>
</body>
</html>
<?php }

/* ---------- autenticação ---------- */
$auth  = jload(MP_AUTH);
$pages = [
    'resumo'   => ['Resumo', 'dash'],
    'recursos' => ['Recursos', 'cpu'],
    'sites'    => ['Sites', 'world'],
    'ficheiros'=> ['Ficheiros', 'folder'],
    'cron'     => ['Tarefas agendadas', 'clock'],
    'email'    => ['Email', 'mail'],
    'dns'      => ['DNS', 'dns'],
    'logs'     => ['Logs', 'logs'],
    'bd'       => ['Bases de dados', 'db'],
    'php'      => ['PHP', 'code'],
    'servicos' => ['Serviços', 'pulse'],
    'ligacoes' => ['Ligações', 'ban'],
    'backups'  => ['Backups', 'archive'],
    'auditoria'=> ['Auditoria', 'file'],
    'atualizacoes' => ['Atualizações', 'download'],
    'terminal' => ['Terminal', 'term'],
    'alertas'  => ['Alertas', 'bell'],
    'processos' => ['Processos', 'cpu'],
    'sentinela' => ['Sentinela', 'shield'],
    'definicoes' => ['Definições', 'sliders'],
    'conta'    => ['Conta', 'user'],
];
$pg   = qget('p');
$page = isset($pages[$pg]) ? $pg : 'resumo';

if (!empty($_SESSION['user']) && time() - (int)($_SESSION['seen'] ?? 0) > MP_IDLE) {
    $_SESSION = [];
    session_regenerate_id(true);
}

if (qget('stats') === 'live') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $d = @file_get_contents(MP_STATS . '/live.json');
    echo $d !== false ? $d : '{}';
    exit;
}

if (qget('stats') === 'conns') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $cj = jload(MP_STATS . '/conns.json') ?? [];
    $byc = [];
    foreach ((array)($cj['ips'] ?? []) as $i => $r) {
        $cc = geo_cc((string)($r['ip'] ?? '')); $cj['ips'][$i]['cc'] = $cc; $cj['ips'][$i]['fl'] = cc_flag($cc); $cj['ips'][$i]['cn'] = cc_name($cc);
        $k = $cc !== '' ? $cc : '--'; $byc[$k] = $byc[$k] ?? ['cc' => $cc, 'n' => 0, 'ips' => 0, 'fl' => cc_flag($cc), 'cn' => cc_name($cc)];
        $byc[$k]['n'] += (int)($r['n'] ?? 0); $byc[$k]['ips']++;
    }
    usort($byc, function ($a, $b) { return $b['n'] <=> $a['n']; });
    $cj['countries'] = array_values($byc);
    $cj['ovl'] = jload(MP_STATS . '/overload.json') ?? ['active' => false];
    echo json_encode($cj, JSON_UNESCAPED_UNICODE);
    exit;
}

if (qget('term') === 'reset') { // o terminal já terminou no servidor: esquecer a sessão e mostrar o botão Abrir
    if (!empty($_SESSION['user'])) { unset($_SESSION['term']); flash(true, 'O terminal anterior terminou. Abre um novo.'); }
    go('terminal');
}
if (qget('term') === 'view' || qget('term') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $tid = qget('id');
    if (!preg_match('/^\d{8}-\d{6}$/', $tid) || !is_file(MP_TERM_LOG . '/' . $tid . '.log')) { http_response_code(404); exit('Sessão não encontrada.'); }
    if (qget('term') === 'dl') {
        $ext = qget('f') === 'timing' ? 'timing' : 'log';
        $tf = MP_TERM_LOG . '/' . $tid . '.' . $ext;
        if (!is_file($tf)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
        header('Content-Type: text/plain; charset=utf-8');
        header('Content-Disposition: attachment; filename="terminal-' . $tid . '.' . $ext . '"');
        header('Content-Length: ' . (string)filesize($tf));
        readfile($tf); exit;
    }
    $raw = (string)@file_get_contents(MP_TERM_LOG . '/' . $tid . '.log', false, null, 0, 20971520);
    $txt = preg_replace('/\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]/', '', $raw) ?? $raw;
    $txt = preg_replace('/[^\x09\x0a\x20-\x7e\x80-\xff]/', '', str_replace("\r\n", "\n", $txt)) ?? $txt;
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><meta charset="utf-8"><title>Sessão ' . h($tid) . '</title><style>body{margin:0;background:#0f1720;color:#d6e2ee;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace}pre{margin:0;padding:20px;white-space:pre-wrap;word-break:break-word}</style><pre>' . h($txt) . '</pre>';
    exit;
}

if (qget('stats') === 'procs') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $memt = 0; $li = (array)(jload(MP_STATS . '/live.json') ?? []); $memt = (int)($li['mem']['total'] ?? 0);
    $rows = []; $sum = [];
    foreach (log_tail(MP_STATS . '/procs.tsv', 400) as $ln) {
        $p = explode("\t", $ln); if (count($p) < 8) continue;
        [$pid, $ppid, $cpu, $rss, $et, $usr, $comm, $args] = $p;
        [$t, $lab, $site] = proc_origin($usr, $args);
        $r = ['pid' => (int)$pid, 'cpu' => (float)$cpu, 'rss' => (int)$rss, 'mem' => $memt > 0 ? round((int)$rss * 100 / $memt, 1) : 0, 'et' => (int)$et,
              'user' => $usr, 'comm' => $comm, 'args' => $args, 't' => $t, 'o' => $lab, 'site' => $site, 'prot' => proc_protected_php((int)$pid, $comm, $args, $usr)];
        $rows[] = $r;
        $k = $t === 'site' ? 'site:' . $site : $t;
        $sum[$k] = $sum[$k] ?? ['k' => $k, 't' => $t, 'o' => $t === 'site' ? 'Site ' . $site : $lab, 'cpu' => 0, 'rss' => 0, 'n' => 0];
        $sum[$k]['cpu'] += (float)$cpu; $sum[$k]['rss'] += (int)$rss; $sum[$k]['n']++;
    }
    usort($sum, function ($a, $b) { return [$b['cpu'], $b['rss']] <=> [$a['cpu'], $a['rss']]; });
    echo json_encode(['ts' => (int)@file_get_contents(MP_STATS . '/procs.ts'), 'cpus' => (int)($li['cpus'] ?? 1), 'memt' => $memt, 'rows' => $rows, 'sum' => array_values($sum)], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

if (qget('logs') === 'json' || qget('logs') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $ls = qget('site');
    if (!preg_match('/^[a-z][a-z0-9-]{0,23}$/', $ls)) { http_response_code(400); exit; }
    $ld = MP_SITE_LOGS . '/' . $ls;
    if (qget('logs') === 'dl') {
        $lf = qget('f');
        if (!preg_match('/^(access|error|php-slow)\.log(-\d{8})?(\.\d+)?(\.gz)?$/', $lf) || !is_file($ld . '/' . $lf) || is_link($ld . '/' . $lf)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
        @set_time_limit(0); while (ob_get_level() > 0) ob_end_clean();
        header('Content-Type: ' . (substr($lf, -3) === '.gz' ? 'application/gzip' : 'text/plain; charset=utf-8'));
        header('Content-Length: ' . (string)filesize($ld . '/' . $lf));
        header('Content-Disposition: attachment; filename="' . $ls . '-' . $lf . '"');
        header('X-Accel-Buffering: no');
        readfile($ld . '/' . $lf); exit;
    }
    header('Content-Type: application/json; charset=utf-8');
    $lt = in_array(qget('t'), ['error', 'slow'], true) ? qget('t') : 'access'; $n = max(10, min(5000, (int)qget('n') ?: 500)); $q = mb_substr(qget('q'), 0, 200);
    if ($lt !== 'access') { echo json_encode(['lines' => log_tail($ld . '/' . ($lt === 'slow' ? 'php-slow' : 'error') . '.log', $n, $q)], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE); exit; }
    $st = qget('st'); $ipf = qget('ip'); $rows = [];
    foreach (log_tail($ld . '/access.log', $st === '' && $ipf === '' ? $n : 200000, $q) as $ln) {
        $p = log_parse($ln); if (!$p) continue;
        if ($st !== '' && (string)intdiv($p['s'], 100) !== $st) continue;
        if ($ipf !== '' && strpos($p['ip'], $ipf) !== 0) continue;
        $p['u'] = mb_substr($p['u'], 0, 500); $p['a'] = mb_substr($p['a'], 0, 200); unset($p['r']);
        $rows[] = $p;
    }
    echo json_encode(['rows' => array_slice($rows, -$n)], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

if (qget('bk') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $bs = qget('s'); $bid = qget('id'); $bf = qget('f');
    if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid)
        || !preg_match('/^(ficheiros\.tar\.gz|sistema\.tar\.gz|bd-[a-z][a-z0-9_]{0,31}\.sql\.gz)$/', $bf)) { http_response_code(400); exit('Pedido inválido.'); }
    $path = MP_BK . '/' . $bs . '/' . $bid . '/' . $bf;
    if (!is_file($path) || !is_readable($path)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
    @set_time_limit(0);
    while (ob_get_level() > 0) ob_end_clean();
    header('Content-Type: application/gzip');
    header('Content-Length: ' . (string)filesize($path));
    header('Content-Disposition: attachment; filename="' . trim($bs, '_') . '-' . $bid . '-' . $bf . '"');
    header('X-Accel-Buffering: no');
    readfile($path);
    exit;
}

if (qget('asset') === 'qr') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    header('Content-Type: application/javascript; charset=utf-8');
    header('Cache-Control: private, max-age=86400');
    readfile('/opt/minipainel/qrcode.js');
    exit;
}

if (qget('poll') === '1') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{"pending":0}'; exit; }
    echo json_encode(['pending' => job_collect()]);
    exit;
}

if (empty($_SESSION['user'])) {
    $err = '';
    $two = !empty($_SESSION['pre2fa']) && time() - (int)($_SESSION['pre2fa']['t'] ?? 0) < 300;
    if (!$two) unset($_SESSION['pre2fa']);
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
        $wait = rl_wait();
        if ($wait > 0) {
            $err = 'Demasiadas tentativas. Tenta novamente dentro de ' . (int)ceil($wait / 60) . ' min.';
        } elseif (!csrf_ok()) {
            $err = 'A sessão expirou. Tenta novamente.';
        } elseif ($two && post('a') === 'cancel2fa') {
            unset($_SESSION['pre2fa']); header('Location: ./'); exit;
        } elseif ($two) {
            $u = (string)$_SESSION['pre2fa']['u'];
            $code = post('code');
            $viaRec = false;
            $okc = $auth !== null && !empty($auth['totp']) && (totp_ok($auth, $code) || ($viaRec = recovery_use($auth, $code)));
            if ($okc) {
                rl_clear();
                unset($_SESSION['pre2fa']);
                session_regenerate_id(true);
                $_SESSION['user'] = $u; $_SESSION['seen'] = time();
                unset($_SESSION['csrf']);
                audit($viaRec ? 'Início de sessão com código de recuperação' : 'Início de sessão (2FA)', true, $u);
                if ($viaRec) flash(false, 'Entraste com um código de recuperação. Cada código só funciona uma vez: se já gastaste vários, gera novos desativando e voltando a ativar a verificação em dois passos (página Conta).');
                go('resumo');
            }
            rl_fail();
            usleep(random_int(300000, 800000));
            audit('Código de verificação em dois passos errado', false, $u);
            $err = 'Código inválido ou já utilizado.';
        } else {
            $u = post('user');
            $p = post_raw('pass');
            if ($auth !== null && hash_equals((string)($auth['user'] ?? ''), $u) && password_verify($p, (string)($auth['hash'] ?? ''))) {
                session_regenerate_id(true);
                if (!empty($auth['totp'])) {
                    $_SESSION['pre2fa'] = ['u' => $u, 't' => time()];
                    header('Location: ./'); exit;
                }
                rl_clear();
                $_SESSION['user'] = $u;
                $_SESSION['seen'] = time();
                unset($_SESSION['csrf']);
                audit('Início de sessão', true, $u);
                go('resumo');
            }
            rl_fail();
            usleep(random_int(300000, 800000));
            audit('Falha de início de sessão', false, $u);
            $err = 'Utilizador ou password incorretos.';
        }
    }
    render_login($err, $two);
    exit;
}
$_SESSION['seen'] = time();
$myIp = (string)($_SERVER['REMOTE_ADDR'] ?? '');
if ($myIp !== '' && (int)($_SESSION['ipmark'] ?? 0) < time() - 300) {
    $aif = MP_DATA . '/logs/admin-ips.json';
    $aid = jload($aif) ?? [];
    $aid[$myIp] = time();
    foreach ($aid as $k => $v) { if ((int)$v < time() - 7 * 86400) unset($aid[$k]); }
    @file_put_contents($aif, (string)json_encode($aid), LOCK_EX);
    $_SESSION['ipmark'] = time();
}

/* ---------- ações ---------- */
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    if (!csrf_ok()) { flash(false, 'Pedido inválido. Recarrega a página e tenta novamente.'); go($page); }
    $a    = post('a');
    $site = post('site');
    $php  = post('php');
    $db   = post('db');
    $back = [];
    $bad  = function (string $m) { flash(false, $m); };

    switch ($a) {
        case 'sair':
            audit('Fim de sessão');
            $_SESSION = [];
            session_destroy();
            header('Location: ./');
            exit;

        case 'refresh':
            job_submit('refresh', [], 'Atualizar estado');
            break;

        case 'site_add':
            $port = post('port');
            if (!valid_site($site)) { $bad('Nome inválido: usa minúsculas, números e "-", a começar por letra (máx. 24).'); $back = ['novo' => 'site']; break; }
            if ($port !== '' && !ctype_digit($port)) { $bad('A porta tem de ser um número.'); $back = ['novo' => 'site']; break; }
            if ($php !== '' && !preg_match(RX_PHP, $php)) { $bad('Versão de PHP inválida.'); $back = ['novo' => 'site']; break; }
            $args = [$site];
            if ($port !== '') array_push($args, '--port', $port);
            if ($php !== '') array_push($args, '--php', $php);
            foreach (LIMITS as $k => $L) {
                $v = post($k);
                if (!ctype_digit($v) || (int)$v < $L[1] || (int)$v > $L[2]) {
                    $bad($L[0] . ': indica um valor entre ' . $L[1] . ' e ' . $L[2] . ($L[3] !== '' ? ' ' . $L[3] : '') . '.');
                    $back = ['novo' => 'site'];
                    break 2;
                }
                array_push($args, $L[4], (string)(int)$v);
            }
            array_push($args, '--display-errors', post('display_errors') === '1' ? '1' : '0');
            $dl = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('domains')) ?? ''));
            if ($dl !== '') {
                foreach (explode(' ', $dl) as $dd) { if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $dd)) { $bad('Domínio inválido: ' . $dd); $back = ['novo' => 'site']; break 2; } }
                array_push($args, '--domains', $dl, '--ssl', in_array(post('ssl'), ['none', 'le', 'self'], true) ? post('ssl') : 'none');
            }
            job_submit('site-add', $args, 'Criar o site ' . $site);
            break;

        case 'site_limits':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $args = [$site];
            foreach (LIMITS as $k => $L) {
                $v = post($k);
                if (!ctype_digit($v) || (int)$v < $L[1] || (int)$v > $L[2]) {
                    $bad($L[0] . ': indica um valor entre ' . $L[1] . ' e ' . $L[2] . ($L[3] !== '' ? ' ' . $L[3] : '') . '.');
                    $back = ['limites' => $site];
                    break 2;
                }
                array_push($args, $L[4], (string)(int)$v);
            }
            array_push($args, '--display-errors', post('display_errors') === '1' ? '1' : '0');
            job_submit('site-limits', $args, 'Limites do site ' . $site);
            break;

        case 'site_del':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-del', post('keep') === '1' ? [$site, '--keep-files'] : [$site], 'Apagar o site ' . $site);
            break;

        case 'site_php':
            if (!valid_site($site) || !preg_match(RX_PHP, $php)) { $bad('Pedido inválido.'); break; }
            job_submit('site-php', [$site, $php], 'Mudar ' . $site . ' para PHP ' . $php);
            break;

        case 'site_on':
        case 'site_off':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit($a === 'site_on' ? 'site-enable' : 'site-disable', [$site], ($a === 'site_on' ? 'Ativar ' : 'Desativar ') . $site);
            break;

        case 'site_perm':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-fixperms', [$site], 'Corrigir permissões de ' . $site);
            break;

        case 'ext_add':
        case 'ext_del':
            $ext = post('ext');
            if (!preg_match(RX_PHP, $php) || !preg_match(RX_EXT, $ext)) { $bad('Pedido inválido.'); break; }
            job_submit($a === 'ext_add' ? 'ext-add' : 'ext-del', [$php, $ext], ($a === 'ext_add' ? 'Instalar ' : 'Remover ') . $ext . ' no PHP ' . $php);
            $back = ['v' => $php];
            break;

        case 'svc':
            $svc = post('svc'); $act = post('act');
            if (!preg_match(RX_SVC, $svc) || !in_array($act, ['reload', 'restart', 'start', 'stop'], true)) { $bad('Pedido inválido.'); break; }
            $names = ['reload' => 'Recarregar', 'restart' => 'Reiniciar', 'start' => 'Iniciar', 'stop' => 'Parar'];
            job_submit('service', [$svc, $act], $names[$act] . ' ' . $svc);
            break;

        case 'mail_enable':
            $mh = strtolower(post('host'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $mh)) { $bad('Nome do servidor de correio inválido.'); break; }
            job_submit('mail-enable', ['--host', $mh], 'Ativar o email em ' . $mh);
            break;

        case 'mail_dom_add':
        case 'mail_dom_del':
        case 'mail_dns_check':
            $md = strtolower(post('d'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $md)) { $bad('Domínio inválido.'); break; }
            $map = ['mail_dom_add' => ['mail-domain-add', 'Adicionar o domínio de email '], 'mail_dom_del' => ['mail-domain-del', 'Apagar o domínio de email '], 'mail_dns_check' => ['mail-dns-check', 'Verificar o DNS de ']];
            job_submit($map[$a][0], [$md], $map[$a][1] . $md);
            break;

        case 'mail_box_add':
            $mu = strtolower(post('user')); $md = strtolower(post('dom')); $em = $mu . '@' . $md; $pw = post_raw('pw'); $q = post('quota') !== '' ? post('quota') : '1024';
            if (!preg_match('/^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $em)) { $bad('Endereço inválido.'); break; }
            if ($pw !== '' && strlen($pw) < 10) { $bad('A password tem de ter pelo menos 10 caracteres.'); break; }
            if (!ctype_digit($q) || (int)$q < 10) { $bad('Quota inválida (mínimo 10 MB).'); break; }
            $args = [$em, '--quota', $q];
            if ($pw !== '') array_push($args, '--hash', crypt($pw, '$6$' . substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16) . '$'));
            job_submit('mail-box-add', $args, 'Criar a caixa de correio ' . $em);
            break;

        case 'mail_box_set':
            $em = post('email'); $pw = post_raw('pw'); $q = post('quota');
            if (!preg_match('/^[a-z0-9._+-]+@[a-z0-9.-]+$/', $em)) { $bad('Endereço inválido.'); break; }
            $args = [$em];
            if ($pw !== '') { if (strlen($pw) < 10) { $bad('A password tem de ter pelo menos 10 caracteres.'); break; } array_push($args, '--hash', crypt($pw, '$6$' . substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16) . '$')); }
            if ($q !== '') { if (!ctype_digit($q) || (int)$q < 10) { $bad('Quota inválida (mínimo 10 MB).'); break; } array_push($args, '--quota', $q); }
            if (count($args) === 1) { $bad('Nada para alterar.'); break; }
            job_submit('mail-box-set', $args, 'Alterar a caixa ' . $em);
            break;

        case 'mail_box_del':
            $em = post('email');
            if (!preg_match('/^[a-z0-9._+-]+@[a-z0-9.-]+$/', $em)) { $bad('Endereço inválido.'); break; }
            job_submit('mail-box-del', [$em], 'Apagar a caixa ' . $em);
            break;

        case 'mail_alias_set':
            $al = strtolower(post('alias')); $ds = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('dests')) ?? ''));
            if (!preg_match('/^([a-z0-9._+-]*)@[a-z0-9.-]+$/', $al)) { $bad('Endereço inválido.'); break; }
            foreach (array_filter(explode(' ', $ds)) as $x) { if (!filter_var($x, FILTER_VALIDATE_EMAIL)) { $bad('Destino inválido: ' . $x); break 2; } }
            job_submit('mail-alias-set', [$al, $ds], 'Encaminhamento ' . $al);
            break;

        case 'mail_alias_del':
            $al = post('alias');
            if (!preg_match('/^([a-z0-9._+-]*)@[a-z0-9.-]+$/', $al)) { $bad('Endereço inválido.'); break; }
            job_submit('mail-alias-del', [$al], 'Apagar o encaminhamento ' . $al);
            break;

        case 'mail_site':
            $op = post('op');
            if (!valid_site($site) || !in_array($op, ['limit', 'suspend', 'resume', 'purge'], true)) { $bad('Pedido inválido.'); break; }
            if ($op === 'limit') { $lm = post('limit'); if (!ctype_digit($lm) || strlen($lm) > 6) { $bad('Limite inválido.'); break; } job_submit('mail-site', [$site, '--limit', $lm], 'Limite de envio de ' . $site . ': ' . $lm . '/hora'); }
            else job_submit('mail-site', [$site, '--' . $op], ['suspend' => 'Suspender', 'resume' => 'Retomar', 'purge' => 'Apagar retidos do'][$op] . ' envio de email de ' . $site);
            $back = ['t' => 'envio'];
            break;

        case 'update_check':
            job_submit('update-check', [], 'Procurar atualizações do painel');
            break;
        case 'update_start':
            if (post('unsigned') === '1' && !reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            job_submit('update-start', post('unsigned') === '1' ? ['--allow-unsigned'] : [], 'Atualizar o painel' . (post('unsigned') === '1' ? ' (sem assinatura)' : ''));
            break;
        case 'update_token':
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            if (post('op') === 'clear') { job_submit('update-token', ['clear'], 'Remover o token do GitHub'); break; }
            $tk = trim(post_raw('token'));
            if (!preg_match('/^(github_pat_[A-Za-z0-9_]{20,255}|gh[pousr]_[A-Za-z0-9]{20,255})$/', $tk)) { $bad('Token inválido (começa por github_pat_ ou ghp_).'); break; }
            job_submit('update-token', ['set', $tk], 'Guardar o token do GitHub');
            break;

        case 'update_key':
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            if (post('op') === 'clear') { job_submit('update-key', ['clear'], 'Remover a chave das atualizações'); break; }
            $pem = trim(str_replace("\r", '', post_raw('pem')));
            if (!preg_match('/^-----BEGIN PUBLIC KEY-----\n[A-Za-z0-9+\/=\n]+\n-----END PUBLIC KEY-----$/', $pem) || strlen($pem) > 400) { $bad('Chave inválida: cola a chave pública completa (formato PEM).'); break; }
            job_submit('update-key', ['set', str_replace("\n", '\n', $pem)], 'Guardar a chave das atualizações');
            break;
        case 'update_rollback':
            $fn = post('file');
            if (!preg_match('/^\d{8}-\d{6}-v[0-9.]+\.tar\.gz$/', $fn)) { $bad('Cópia inválida.'); break; }
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            job_submit('update-rollback', [$fn], 'Repor a cópia ' . $fn);
            break;
        case 'os_check':
            job_submit('os-check', [], 'Procurar atualizações do sistema');
            break;
        case 'os_start':
            job_submit('os-start', post('op') === 'security' ? ['--security'] : [], post('op') === 'security' ? 'Instalar atualizações de segurança do sistema' : 'Instalar todas as atualizações do sistema');
            break;
        case 'os_auto':
            job_submit('os-auto', [post('op') === 'off' ? 'off' : 'on'], post('op') === 'off' ? 'Desligar atualizações automáticas' : 'Ativar atualizações de segurança automáticas');
            break;
        case 'reboot':
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            job_submit('reboot', [], 'Reiniciar o servidor');
            break;

        case 'site_ftp':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            if (post('off') === '1') { job_submit('site-ftp', [$site, '--off'], 'Desativar o acesso FTP/SFTP de ' . $site); break; }
            $pw = post_raw('pw');
            if ($pw !== '' && strlen($pw) < 10) { $bad('A password tem de ter pelo menos 10 caracteres.'); break; }
            $args = [$site];
            if ($pw !== '') array_push($args, '--hash', crypt($pw, '$6$' . substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16) . '$'));
            job_submit('site-ftp', $args, 'Acesso FTP/SFTP de ' . $site);
            break;

        case 'ftp_settings':
            $pi = post('pasv_ip');
            if ($pi !== '' && !filter_var($pi, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) { $bad('IP inválido.'); break; }
            job_submit('ftp-settings', ['--plain', post('plain') === '1' ? 'on' : 'off', '--pasv-ip', $pi === '' ? 'none' : $pi], 'Definições do FTP');
            break;

        case 'protect_settings':
            foreach (['ssh_fails', 'panel_fails', 'auth_fails'] as $k) { $v = post($k); if (!ctype_digit($v) || (int)$v < 3 || (int)$v > 100) { $bad('O número de falhas tem de estar entre 3 e 100.'); break 2; } }
            if (!ctype_digit(post('window')) || (int)post('window') < 1 || (int)post('window') > 1440) { $bad('A janela tem de estar entre 1 e 1440 minutos.'); break; }
            foreach (['ban1', 'ban2', 'ban3'] as $k) { if (!in_array(post($k), ['15m', '1h', '6h', '24h', '7d', '30d', 'perm'], true)) { $bad('Duração inválida.'); break 2; } }
            job_submit('protect-settings', ['--ssh', post('ssh') === 'off' ? 'off' : 'on', '--ssh-fails', post('ssh_fails'), '--panel-fails', post('panel_fails'), '--auth-fails', post('auth_fails'), '--window', post('window'), '--ban1', post('ban1'), '--ban2', post('ban2'), '--ban3', post('ban3')], 'Proteção contra força bruta');
            break;

        case 'pma_settings':
            foreach (['session' => [5, 1440], 'exec' => [30, 7200], 'upload' => [8, 4096]] as $k => $lim) {
                $v = post($k); if (!ctype_digit($v) || (int)$v < $lim[0] || (int)$v > $lim[1]) { $bad('Valor fora dos limites (' . $lim[0] . ' a ' . $lim[1] . ').'); break 2; }
            }
            job_submit('pma-settings', ['--session', post('session'), '--exec', post('exec'), '--upload', post('upload')], 'Tempos e limites do phpMyAdmin');
            break;

        case 'mail_list':
            $ll = post('l'); $lo = post('op'); $lv = strtolower(trim(post('v')));
            if (!in_array($ll, ['allow', 'deny'], true) || !in_array($lo, ['add', 'del'], true)) { $bad('Pedido inválido.'); break; }
            if (!filter_var($lv, FILTER_VALIDATE_EMAIL) && !filter_var($lv, FILTER_VALIDATE_IP) && !preg_match('/^@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $lv)) { $bad('Usa um email, @domínio ou IP.'); break; }
            job_submit('mail-list', [$ll, $lo, $lv], ($lo === 'add' ? ($ll === 'allow' ? 'Permitir ' : 'Bloquear ') : 'Remover da lista ') . $lv);
            $back = ['t' => 'spam'];
            break;

        case 'mail_queue':
            $op = post('op');
            if ($op === 'flush') job_submit('mail-queue', ['flush'], 'Reenviar a fila de correio');
            elseif ($op === 'all') job_submit('mail-queue', ['delete', 'all'], 'Esvaziar a fila de correio');
            elseif ($op === 'del' && preg_match('/^[0-9A-Za-z]{6,20}$/', post('id'))) job_submit('mail-queue', ['delete', post('id')], 'Apagar mensagem da fila');
            else $bad('Pedido inválido.');
            $back = ['t' => 'fila'];
            break;

        case 'mail_settings':
            $zs = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('dnsbl')) ?? ''));
            foreach (array_filter(explode(' ', $zs)) as $z) { if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $z)) { $bad('Lista negra inválida: ' . $z); break 2; } }
            foreach (['site_limit', 'box_limit', 'auth_fails'] as $k) { if (!ctype_digit(post($k)) || strlen(post($k)) > 5) { $bad('Valores inválidos.'); break 2; } }
            if ((int)post('auth_fails') < 3) { $bad('O bloqueio por falhas de login tem de ser 3 ou mais.'); break; }
            job_submit('mail-settings', ['--dnsbl', $zs === '' ? 'none' : $zs, '--site-limit', post('site_limit'), '--box-limit', post('box_limit'), '--auth-fails', post('auth_fails')], 'Definições do antispam');
            $back = ['t' => 'antispam'];
            break;

        case 'mail_av':
            job_submit('mail-av', [post('op') === 'off' ? 'off' : 'on'], post('op') === 'off' ? 'Desativar o antivírus' : 'Ativar o antivírus');
            $back = ['t' => 'antispam'];
            break;

        case 'site_perf':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $pc = post('cache'); $ppm = post('pm'); $pmc = post('maxch'); $psl = post('slow');
            if (!in_array($pc, ['0', '60', '300', '600', '1800', '3600'], true) || !in_array($ppm, ['ondemand', 'dynamic'], true) || !ctype_digit($pmc) || (int)$pmc < 2 || (int)$pmc > 200 || !in_array($psl, ['0', '1', '3', '5', '10'], true)) { $bad('Valores inválidos (máximo de processos entre 2 e 200).'); break; }
            $prm = post('redis_mb'); $psd = post('static_days');
            if (!in_array($prm, ['32', '64', '128', '256', '512', '1024'], true) || !in_array($psd, ['0', '7', '30', '365'], true)) { $bad('Valores inválidos.'); break; }
            job_submit('site-perf', [$site, '--cache', $pc, '--pm', $ppm, '--max-children', $pmc, '--slowlog', $psl, '--redis', post('redis') === 'on' ? 'on' : 'off', '--redis-mem', $prm,
                '--static-days', $psd, '--webp', post('webp') === 'off' ? 'off' : 'on', '--webp-auto', post('webp_auto') === '1' ? 'on' : 'off'], 'Desempenho de ' . $site);
            break;
        case 'site_webp':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-webp', [$site], 'Converter as imagens de ' . $site . ' em WebP');
            break;
        case 'net_tune':
            job_submit('net-tune', [post('on') === 'off' ? 'off' : 'on'], 'Afinação de rede');
            break;
        case 'brotli':
            job_submit('brotli', [post('on') === 'off' ? 'off' : 'on'], 'Compressão Brotli');
            break;
        case 'cache_purge':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('cache-purge', [$site], 'Limpar a cache de ' . $site);
            break;
        case 'opcache_settings':
            $om = post('mem'); $orv = post('reval');
            if (!in_array($om, ['auto', '128', '256', '512', '1024'], true) || !in_array($orv, ['0', '2', '60', '300'], true)) { $bad('Valores inválidos.'); break; }
            job_submit('opcache-settings', ['--memory', $om, '--revalidate', $orv], 'Configuração do OPcache');
            break;
        case 'opcache_reset':
            job_submit('opcache-reset', [], 'Limpar o OPcache');
            break;
        case 'db_tune':
            $bp = strtolower(post('bp')); $st = post('slow') === 'off' ? 'off' : 'on'; $stt = post('slow_t');
            if ($bp !== 'auto' && (!ctype_digit($bp) || (int)$bp < 128)) { $bad('Memória: auto ou um número igual ou superior a 128 (MB).'); break; }
            if (!ctype_digit($stt) || (int)$stt < 1 || (int)$stt > 99) { $bad('Tempo das consultas lentas entre 1 e 99 segundos.'); break; }
            job_submit('db-tune', ['--buffer', $bp, '--slow', $st, '--slow-time', $stt], 'Afinar o MariaDB');
            break;
        case 'db_slow_report':
            job_submit('db-slow-report', [], 'Atualizar as consultas lentas');
            break;

        case 'sentinel_run':
            job_submit('sentinel-run', [], 'Testar todos os serviços agora');
            break;
        case 'sentinel_settings':
            $all = array_filter(explode(' ', post('all')), function ($x) { return preg_match('/^[a-z0-9:._-]{2,80}$/', $x); });
            $on = array_filter((array)($_POST['on'] ?? []), function ($x) { return is_string($x) && preg_match('/^[a-z0-9:._-]{2,80}$/', $x); });
            $off = array_values(array_diff($all, $on));
            job_submit('sentinel-settings', ['--repair', post('repair') === 'off' ? 'off' : 'on', '--sites', post('sites') === 'off' ? 'off' : 'on', '--off', implode(' ', $off)], 'Configuração do sentinela');
            break;
        case 'proc_kill':
            $pid = post('pid');
            if (!ctype_digit($pid) || (int)$pid < 3) { $bad('Processo inválido.'); break; }
            job_submit('proc-kill', post('force') === '1' ? [$pid, '--force'] : [$pid], (post('force') === '1' ? 'Forçar o fim do processo ' : 'Terminar o processo ') . $pid);
            break;
        case 'proc_kill_site':
            if (!valid_site(post('site'))) { $bad('Site inválido.'); break; }
            job_submit('proc-kill-site', [post('site')], 'Terminar os processos do site ' . post('site'));
            break;

        case 'alerts_settings':
            $args = ['--sms', post('sms') === 'on' ? 'on' : 'off', '--email', post('email') === 'on' ? 'on' : 'off'];
            $tel = str_replace(' ', '', post('sms_to'));
            if ($tel !== '') { if (!preg_match('/^\+?[0-9]{9,15}(,\+?[0-9]{9,15})*$/', $tel)) { $bad('Número inválido (ex.: +351912345678).'); break; } array_push($args, '--sms-to', $tel); }
            if (post('sms_id') !== '') { if (!preg_match('/^[A-Za-z0-9_-]{4,80}$/', post('sms_id'))) { $bad('Token ID inválido.'); break; } array_push($args, '--sms-id', post('sms_id')); }
            if (post_raw('sms_secret') !== '') { if (!preg_match('/^[A-Za-z0-9_.+\/=-]{4,200}$/', post_raw('sms_secret'))) { $bad('Token secreto inválido.'); break; } array_push($args, '--sms-secret', post_raw('sms_secret')); }
            if (post('email_to') !== '') { if (!filter_var(post('email_to'), FILTER_VALIDATE_EMAIL)) { $bad('Email inválido.'); break; } array_push($args, '--email-to', post('email_to')); }
            foreach (['cpu' => [10, 100], 'cpu_min' => [1, 120], 'ram' => [10, 100], 'disk' => [10, 100], 'conn' => [10, 100], 'mail_pct' => [5, 500], 'mail_min' => [1, 999999]] as $k => $lim) {
                $v = post($k); if (!ctype_digit($v) || (int)$v < $lim[0] || (int)$v > $lim[1]) { $bad('Valor fora dos limites em ' . $k . ' (' . $lim[0] . ' a ' . $lim[1] . ').'); break 2; }
                array_push($args, '--' . str_replace('_', '-', $k), $v);
            }
            if (post('sms') === 'on' && $tel === '' && empty($state['alerts']['sms_to'])) { $bad('Indica o número para os SMS.'); break; }
            job_submit('alerts-settings', $args, 'Configuração dos alertas');
            break;
        case 'alerts_test':
            job_submit('alerts-test', [], 'Teste de alertas');
            break;

        case 'geo_block':
            $gc = strtoupper(post('cc')); $op = post('op') === 'del' ? 'del' : 'add';
            if (!preg_match('/^[A-Z]{2}$/', $gc)) { $bad('Escolhe um país.'); break; }
            job_submit('geo-block', [$op, $gc], ($op === 'add' ? 'Bloquear o país ' : 'Desbloquear o país ') . $gc);
            $back = ['t' => 'paises'];
            break;
        case 'geoip_update':
            job_submit('geoip-update', [], 'Atualizar a base de países');
            $back = ['t' => 'paises'];
            break;
        case 'overload_settings':
            $mx = strtolower(post('max')); $st = post('start'); $sp = post('stop'); $hc = strtoupper(post('home'));
            if ($mx !== 'auto' && (!ctype_digit($mx) || (int)$mx < 50)) { $bad('Capacidade: auto ou um número igual ou superior a 50.'); break; }
            if (!ctype_digit($st) || !ctype_digit($sp) || (int)$sp >= (int)$st || (int)$st > 99 || (int)$sp < 10) { $bad('Percentagens inválidas (a de saída tem de ser menor que a de entrada).'); break; }
            if (!preg_match('/^[A-Z]{2}$/', $hc)) { $bad('País inválido.'); break; }
            job_submit('overload-settings', [post('on') === 'off' ? '--off' : '--on', '--max', $mx, '--start', $st, '--stop', $sp, '--home', $hc], 'Limite de ligações');
            $back = ['t' => 'protecao'];
            break;

        case 'terminal_open':
            if (empty($auth['totp'])) { $bad('Ativa primeiro a verificação em dois passos (Conta).'); break; }
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            $tk = bin2hex(random_bytes(16));
            $_SESSION['term'] = ['t' => $tk, 'ts' => time()];
            job_submit('terminal-start', [$tk], 'Abrir o terminal (root)');
            break;
        case 'terminal_close':
            unset($_SESSION['term']);
            job_submit('terminal-stop', [], 'Fechar o terminal');
            break;

        case 'dns_enable':
            $re = '/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/';
            $n1 = strtolower(post('ns1')); $n2 = strtolower(post('ns2')); $ip = post('ip'); $hm = post('hm');
            if (!preg_match($re, $n1) || !preg_match($re, $n2) || $n1 === $n2) { $bad('Indica dois nameservers diferentes.'); break; }
            if ($ip !== '' && !filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) { $bad('IP inválido.'); break; }
            if ($hm !== '' && !filter_var($hm, FILTER_VALIDATE_EMAIL)) { $bad('Email inválido.'); break; }
            $args = ['--ns1', $n1, '--ns2', $n2]; if ($ip !== '') array_push($args, '--ip', $ip); if ($hm !== '') array_push($args, '--hostmaster', $hm);
            job_submit('dns-enable', $args, 'Ativar o DNS');
            break;
        case 'dns_zone_add':
        case 'dns_zone_del':
        case 'dns_sync':
        case 'dns_check':
            $zn = strtolower(post('zone'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $zn)) { $bad('Domínio inválido.'); break; }
            $map = ['dns_zone_add' => ['dns-zone-add', 'Adicionar a zona '], 'dns_zone_del' => ['dns-zone-del', 'Apagar a zona '], 'dns_sync' => ['dns-sync', 'Sincronizar a zona '], 'dns_check' => ['dns-check', 'Verificar a delegação de ']];
            job_submit($map[$a][0], [$zn], $map[$a][1] . $zn);
            if ($a !== 'dns_zone_del') $back = ['zone' => $a === 'dns_zone_add' ? '' : $zn];
            break;
        case 'dns_rec_add':
            $zn = strtolower(post('zone')); $rt = strtoupper(post('type'));
            if (!preg_match('/^[a-z0-9.-]+$/', $zn) || !in_array($rt, ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'SRV', 'CAA'], true)) { $bad('Pedido inválido.'); break; }
            $val = trim(str_replace(["\r", "\n"], ' ', post_raw('value')));
            if ($val === '' || strlen($val) > 2000) { $bad('Valor inválido.'); break; }
            $ttl = ctype_digit(post('ttl')) ? post('ttl') : '3600'; $pr = ctype_digit(post('prio')) ? post('prio') : '10';
            job_submit('dns-rec-add', [$zn, strtolower(post('name')), $rt, $val, '--ttl', $ttl, '--prio', $pr], 'Registo ' . $rt . ' em ' . $zn);
            $back = ['zone' => $zn];
            break;
        case 'dns_rec_del':
            $zn = strtolower(post('zone')); $rid = post('id');
            if (!preg_match('/^[a-z0-9.-]+$/', $zn) || !preg_match('/^[A-Za-z0-9]{6,16}$/', $rid)) { $bad('Pedido inválido.'); break; }
            job_submit('dns-rec-del', [$zn, $rid], 'Apagar registo de ' . $zn);
            $back = ['zone' => $zn];
            break;
        case 'logs_settings':
            $ld = post('days');
            if (!ctype_digit($ld) || (int)$ld < 7 || (int)$ld > 365) { $bad('Dias entre 7 e 365.'); break; }
            job_submit('logs-settings', ['--days', $ld], 'Guardar os logs durante ' . $ld . ' dias');
            break;

        case 'panel_allow':
            $ips = array_values(array_filter(preg_split('/[\s,;]+/', post_raw('ips')) ?: []));
            foreach ($ips as $ip) { if (!valid_net($ip)) { $bad('IP ou rede inválida: ' . $ip); break 2; } }
            if ($ips) {
                $inside = false;
                foreach ($ips as $ip) { if (ip_in($myIp, $ip)) { $inside = true; break; } }
                if (!$inside && $myIp !== '127.0.0.1' && $myIp !== '::1') { $bad('O teu IP atual (' . $myIp . ') não está na lista: ficarias sem acesso ao painel. Acrescenta-o.'); break; }
            }
            job_submit('panel-allow', [$ips ? implode(' ', $ips) : 'none'], 'IPs autorizados no painel: ' . ($ips ? implode(', ', $ips) : 'todos'));
            break;

        case 'ports_access':
            job_submit('ports-access', [post('pa') === 'lan' ? 'lan' : 'all'], 'Acesso pelas portas dos sites: ' . (post('pa') === 'lan' ? 'só rede local' : 'todos'));
            break;

        case 'acct_user':
            $nu = post('newuser');
            if (!preg_match('/^[a-z][a-z0-9._-]{2,31}$/', $nu)) { $bad('Nome inválido: 3 a 32 caracteres (minúsculas, números, ".", "_" e "-"), a começar por letra.'); break; }
            if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (job_submit('panel-user', [$nu], 'Mudar o utilizador do painel para ' . $nu)) $_SESSION['user'] = $nu;
            break;

        case 'totp_enable':
            $sec = (string)($_SESSION['totp_new'] ?? '');
            if ($sec === '' || totp_verify($sec, post('code')) === null) { $bad('Código inválido. Confirma que a hora do telemóvel está certa e tenta de novo.'); $back = ['tfa' => 'setup']; break; }
            unset($_SESSION['totp_new']);
            job_submit('panel-2fa', ['set', $sec], 'Ativar a verificação em dois passos');
            break;

        case 'totp_disable':
            if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (!totp_ok($auth, post('code')) && !recovery_use($auth, post('code'))) { $bad('Código inválido.'); break; }
            job_submit('panel-2fa', ['off'], 'Desativar a verificação em dois passos');
            break;

        case 'bk_key_show':
            if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            job_submit('bk-key', [], 'Mostrar a chave dos backups');
            break;

        case 'site_domains':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $dl = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('domains')) ?? ''));
            foreach (array_filter(explode(' ', $dl)) as $dd) { if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $dd)) { $bad('Domínio inválido: ' . $dd); break 2; } }
            $ssl = in_array(post('ssl'), ['none', 'le', 'self'], true) ? post('ssl') : 'none';
            $www = in_array(post('www'), ['keep', 'www', 'root'], true) ? post('www') : 'keep';
            job_submit('site-domains', [$site, '--set', $dl, '--ssl', $ssl, '--https', post('https') === '1' ? '1' : '0', '--www', $www], 'Domínios de ' . $site);
            break;

        case 'srv_mode':
            $md = post('mode') === 'internet' ? 'internet' : 'lan'; $em = post('email');
            if ($em !== '' && !filter_var($em, FILTER_VALIDATE_EMAIL)) { $bad('Email inválido.'); break; }
            job_submit('server-mode', [$md, '--email', $em === '' ? 'none' : $em], 'Modo do servidor');
            break;

        case 'panel_domain':
            $pd = strtolower(post('domain'));
            if ($pd !== '' && !preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $pd)) { $bad('Domínio inválido.'); break; }
            job_submit('panel-domain', [$pd === '' ? 'none' : $pd, '--ssl', post('ssl') === 'self' ? 'self' : 'le'], 'Domínio do painel');
            break;

        case 'bk_now':
            $tg = post('target'); $rm = post('remote');
            if ($tg !== 'all' && !preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $tg)) { $bad('Pedido inválido.'); break; }
            $args = $tg === 'all' ? [] : ['--site', $tg];
            if ($rm !== '' && preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rm)) array_push($args, '--remote', $rm);
            job_submit('backup-start', $args, 'Iniciar backup');
            break;

        case 'bk_restore':
            $bs = post('s'); $bid = post('id'); $what = post('what');
            if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid) || !in_array($what, ['all', 'files', 'db'], true)) { $bad('Pedido inválido.'); break; }
            if (post('ok') !== '1') { $bad('Confirma que compreendes que o conteúdo atual vai ser substituído.'); break; }
            job_submit('bk-restore', [$bs, $bid, '--what', $what], 'Repor backup de ' . ($bs === '_bd' ? 'bases de dados' : $bs));
            break;

        case 'bk_del':
            $bs = post('s'); $bid = post('id');
            if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid)) { $bad('Pedido inválido.'); break; }
            job_submit('bk-delete', [$bs, $bid], 'Apagar backup');
            break;

        case 'bk_conf':
            $tm = post('time'); $kd = post('daily'); $kw = post('weekly'); $km = post('monthly'); $rm = post('remote');
            if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $tm)) { $bad('Hora inválida.'); break; }
            foreach ([$kd, $kw, $km] as $v) { if (!ctype_digit($v) || (int)$v > 999) { $bad('Os valores de retenção têm de ser números entre 0 e 999.'); break 2; } }
            if ((int)$kd < 1) { $bad('Guarda pelo menos 1 backup diário.'); break; }
            if ($rm !== 'none' && !preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rm)) $rm = 'none';
            job_submit('bk-conf', [post('on') === 'on' ? '--on' : '--off', '--time', $tm, '--daily', $kd, '--weekly', $kw, '--monthly', $km, '--remote', $rm, '--encrypt', post('encrypt') === 'off' ? 'off' : 'on'], 'Agendamento dos backups');
            break;

        case 'bk_remote_add':
            $rn = post('name'); $rt = post('type');
            if (!preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rn) || !in_array($rt, ['sftp', 's3', 'rclone'], true)) { $bad('Nome ou tipo inválido.'); break; }
            $args = [$rn, $rt];
            if ($rt === 'sftp') {
                $port = post('port') !== '' ? post('port') : '22';
                if (!ctype_digit($port)) { $bad('Porta inválida.'); break; }
                array_push($args, '--host', post('host'), '--port', $port, '--user', post('user'), '--path', post('path_sftp'));
                if (post_raw('pass') !== '') array_push($args, '--pass', post_raw('pass'));
                if (trim(post_raw('key')) !== '') array_push($args, '--key', str_replace(["\r\n", "\r", "\n"], '\n', trim(post_raw('key'))));
            } elseif ($rt === 's3') {
                array_push($args, '--provider', post('provider'), '--endpoint', post('endpoint'), '--region', post('region'), '--access', post('access'), '--secret', post_raw('secret'), '--bucket', post('bucket'), '--path', post('path_s3'));
            } else {
                $cfg = str_replace(["\r\n", "\r"], "\n", trim(post_raw('config')));
                array_push($args, '--config', str_replace("\n", '\n', $cfg), '--path', post('path_rc'));
            }
            job_submit('bk-remote-add', $args, 'Adicionar destino ' . $rn);
            break;

        case 'bk_remote_test':
        case 'bk_remote_del':
            $rn = post('name');
            if (!preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rn)) { $bad('Destino inválido.'); break; }
            job_submit($a === 'bk_remote_test' ? 'bk-remote-test' : 'bk-remote-del', [$rn], ($a === 'bk_remote_test' ? 'Testar ' : 'Remover ') . $rn, );
            break;

        case 'db_link':
            $ls = post('site');
            if (!preg_match(RX_DB, $db) || ($ls !== 'none' && !valid_site($ls))) { $bad('Pedido inválido.'); break; }
            job_submit('db-link', [$db, $ls], 'Associar ' . $db);
            break;

        case 'cron_save':
            $cid = post('id'); $when = trim(preg_replace('/\s+/', ' ', post('when')) ?? ''); $cmdc = trim(str_replace(["\r", "\n"], ' ', post_raw('cmd')));
            $desc = substr(trim(str_replace(["\r", "\n", '|'], ' ', post_raw('desc'))), 0, 80);
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            if ($cid !== '' && !preg_match('/^[a-f0-9]{8}$/', $cid)) { $bad('Tarefa inválida.'); break; }
            if (!preg_match('/^(@(hourly|daily|weekly|monthly|yearly|annually)|(\S+ ){4}\S+)$/', $when)) { $bad('Periodicidade inválida.'); break; }
            if ($cmdc === '' || strlen($cmdc) > 2000) { $bad('O comando é obrigatório (até 2000 caracteres).'); break; }
            $args = $cid === '' ? [$site] : [$site, $cid];
            array_push($args, '--when', $when, '--cmd', $cmdc, '--label', $desc);
            job_submit($cid === '' ? 'cron-add' : 'cron-edit', $args, ($cid === '' ? 'Criar tarefa em ' : 'Atualizar tarefa de ') . $site);
            $back = $site !== '' ? ['site' => qget('site')] : [];
            break;

        case 'cron_run':
        case 'cron_on':
        case 'cron_off':
        case 'cron_del':
            $cid = post('id');
            if (!valid_site($site) || !preg_match('/^[a-f0-9]{8}$/', $cid)) { $bad('Pedido inválido.'); break; }
            $map = ['cron_run' => ['cron-run', 'Executar tarefa'], 'cron_on' => ['cron-on', 'Ativar tarefa'], 'cron_off' => ['cron-off', 'Pausar tarefa'], 'cron_del' => ['cron-del', 'Apagar tarefa']];
            job_submit($map[$a][0], [$site, $cid], $map[$a][1] . ' de ' . $site);
            $back = qget('site') !== '' ? ['site' => qget('site')] : [];
            break;

        case 'fw_block':
            $ip = post('ip'); $dur = post('dur');
            if (!valid_net($ip)) { $bad('IP ou rede inválida (ex.: 185.220.101.47 ou 45.148.10.0/24; redes de /8 a /32).'); break; }
            if (!in_array($dur, ['1h', '24h', '7d', 'perm'], true)) $dur = '24h';
            $why = substr(preg_replace('/[^\p{L}\p{N} .,:;()\/_-]/u', '', post('reason')) ?? '', 0, 80);
            job_submit('block', [$ip, '--for', $dur, '--reason', $why, '--protect', $myIp], 'Bloquear ' . $ip);
            break;

        case 'fw_unblock':
            $ip = post('ip');
            if (!valid_net($ip)) { $bad('IP inválido.'); break; }
            job_submit('unblock', [$ip], 'Desbloquear ' . $ip);
            break;

        case 'fw_allow_add':
        case 'fw_allow_del':
            $ip = post('ip');
            if (!valid_net($ip)) { $bad('IP ou rede inválida.'); break; }
            job_submit($a === 'fw_allow_add' ? 'allow-add' : 'allow-del', [$ip], ($a === 'fw_allow_add' ? 'Confiar em ' : 'Deixar de confiar em ') . $ip);
            break;

        case 'fw_auto':
            $lim = post('limit'); $dur = post('dur');
            if (!ctype_digit($lim) || (int)$lim < 10 || (int)$lim > 100000) { $bad('O limite tem de ser um número entre 10 e 100000.'); break; }
            if (!in_array($dur, ['600s', '1h', '24h', '7d'], true)) $dur = '1h';
            job_submit('fw-auto', [post('on') === 'on' ? 'on' : 'off', '--limit', (string)(int)$lim, '--duration', $dur], 'Bloqueio automático');
            break;

        case 'db_add':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Nome inválido: usa minúsculas, números e "_", a começar por letra (máx. 32).'); $back = ['novo' => 'bd']; break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); $back = ['novo' => 'bd']; break; }
            $dsite = post('site');
            $dargs = $pw !== '' ? [$db, $pw] : [$db];
            if ($dsite !== '' && valid_site($dsite)) array_push($dargs, '--site', $dsite);
            job_submit('db-add', $dargs, 'Criar a base de dados ' . $db);
            break;

        case 'db_del':
            if (!preg_match(RX_DB, $db)) { $bad('Base de dados inválida.'); break; }
            job_submit('db-del', [$db], 'Apagar a base de dados ' . $db);
            break;

        case 'db_admin_pw':
            job_submit('db-admin-passwd', [], 'Password da conta de administração');
            break;

        case 'pma_update':
            job_submit('pma-update', [], 'Atualizar o phpMyAdmin');
            break;

        case 'db_pass':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Base de dados inválida.'); break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); break; }
            job_submit('db-passwd', $pw !== '' ? [$db, $pw] : [$db], 'Password de ' . $db);
            break;

        case 'conta_pass':
            $cur = post_raw('atual'); $n1 = post_raw('nova'); $n2 = post_raw('repetir');
            if ($auth === null || !password_verify($cur, (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (strlen($n1) < 10) { $bad('A nova password tem de ter pelo menos 10 caracteres.'); break; }
            if ($n1 !== $n2) { $bad('As passwords novas não coincidem.'); break; }
            job_submit('panel-passwd-hash', [password_hash($n1, PASSWORD_BCRYPT)], 'Password do painel');
            break;

        default:
            $bad('Ação desconhecida.');
    }
    go($page, $back);
}

/* ---------- dados para a vista ---------- */
$pending = job_collect();
$state   = jload(MP_STATE) ?? [];
$sites   = is_array($state['sites'] ?? null) ? $state['sites'] : [];
$dbs     = is_array($state['databases'] ?? null) ? $state['databases'] : [];
$phps    = is_array($state['php'] ?? null) ? $state['php'] : [];
$svcs    = is_array($state['service_list'] ?? null) ? $state['service_list'] : [];
$sys     = is_array($state['system'] ?? null) ? $state['system'] : [];
$pma     = is_array($state['pma'] ?? null) ? $state['pma'] : [];
$dbAdmin = is_array($state['db_admin'] ?? null) ? $state['db_admin'] : [];
$pmaOn   = !empty($pma['installed']);
$srv     = is_array($state['server'] ?? null) ? $state['server'] : ['mode' => 'lan'];
$isNet   = ($srv['mode'] ?? 'lan') === 'internet';
/* Fim do suporte de segurança de cada versão de PHP (php.net/supported-versions) */
function php_support(string $v): array {
    $eol = ['8.2' => '2026-12-31', '8.3' => '2027-12-31', '8.4' => '2028-12-31', '8.5' => '2029-12-31'];
    if (!isset($eol[$v])) return version_compare($v, '8.2', '<') ? ['Sem suporte de segurança', 'p-err'] : ['Suportada', 'p-ok'];
    $t = strtotime($eol[$v]);
    if ($t < time()) return ['Sem suporte de segurança', 'p-err'];
    return ['Suporte até ' . date('d/m/Y', $t), $t - time() < 180 * 86400 ? 'p-warn' : 'p-ok'];
}
function site_main_url(array $s): string {
    $doms = trim((string)($s['domains'] ?? ''));
    if ($doms === '') return '';
    $d = explode(' ', $doms)[0];
    return (!empty($s['https_ok']) ? 'https://' : 'http://') . $d . '/';
}
$defPhp  = (string)($state['default_php'] ?? '');
$host    = host_only();
$flashes = is_array($_SESSION['flash'] ?? null) ? $_SESSION['flash'] : [];
unset($_SESSION['flash']);
$jobs    = is_array($_SESSION['jobs'] ?? null) ? $_SESSION['jobs'] : [];
$active  = count(array_filter($sites, function ($s) { return !empty($s['enabled']); }));
$bySite  = [];
foreach ($sites as $s) { $v = (string)($s['php'] ?? ''); $bySite[$v] = ($bySite[$v] ?? 0) + 1; }
$svcDown = count(array_filter($svcs, function ($s) { return empty($s['active']); }));

function php_options(array $phps, string $sel): string {
    $o = '';
    foreach ($phps as $p) {
        $v = (string)($p['version'] ?? '');
        $o .= '<option value="' . h($v) . '"' . ($v === $sel ? ' selected' : '') . '>PHP ' . h($v) . '</option>';
    }
    return $o;
}
function limit_fields(array $L): string {
    $o = '<div class="fgrid">';
    foreach (LIMITS as $k => $d) {
        $o .= '<label class="fld">' . h($d[0]) . ($d[3] !== '' ? ' (' . h($d[3]) . ')' : '')
            . '<input class="in" name="' . h($k) . '" inputmode="numeric" pattern="[0-9]{1,6}" required value="' . (int)$L[$k] . '">'
            . '<small>' . h($d[5]) . ', ' . (int)$d[1] . ' a ' . (int)$d[2] . '</small></label>';
    }
    $o .= '<label class="fld">Mostrar erros no ecrã<select class="in" name="display_errors">'
        . '<option value="0"' . ($L['display_errors'] ? '' : ' selected') . '>Não (produção)</option>'
        . '<option value="1"' . ($L['display_errors'] ? ' selected' : '') . '>Sim (desenvolvimento)</option>'
        . '</select><small>display_errors</small></label></div>';
    return $o;
}
function svc_actions(array $s, array $bySite): string {
    $id = (string)($s['id'] ?? ''); $on = !empty($s['active']); $panel = !empty($s['panel']);
    $btn = function (string $act, string $icon, string $label, string $confirm = '') use ($id) {
        return '<form method="post"' . ($confirm !== '' ? ' data-confirm="' . h($confirm) . '"' : '') . '>' . act_fields('svc', ['svc' => $id, 'act' => $act])
            . '<button class="btn sm sec" type="submit">' . ic($icon) . h($label) . '</button></form>';
    };
    $o = '';
    if ($id === 'nginx') {
        $o .= $btn('reload', 'reload', 'Recarregar');
        $o .= $btn('restart', 'power', 'Reiniciar', 'Reiniciar o nginx? Os sites e o painel ficam indisponíveis durante 1 a 2 segundos.');
    } elseif ($id === 'mariadb') {
        $o .= $on ? $btn('restart', 'power', 'Reiniciar', 'Reiniciar o MariaDB? Os sites perdem a ligação à base de dados durante alguns segundos.')
                  : $btn('start', 'play', 'Iniciar');
    } else {
        $n = (int)($bySite[(string)($s['version'] ?? '')] ?? 0);
        if ($on) {
            $o .= $btn('reload', 'reload', 'Recarregar');
            $o .= $btn('restart', 'power', 'Reiniciar', 'Reiniciar ' . ($s['name'] ?? '') . '? Os pedidos em curso são interrompidos.');
            if (!$panel) $o .= $btn('stop', 'stop', 'Parar', 'Parar ' . ($s['name'] ?? '') . '? ' . ($n > 0 ? $n . ' site(s) deixam de funcionar até voltares a iniciar.' : 'Nenhum site usa esta versão.'));
        } else {
            $o .= $btn('start', 'play', 'Iniciar');
        }
    }
    return '<div class="svc-acts">' . $o . '</div>';
}
function fmt_bytes(float $b, int $dec = 1): string {
    $u = ['B', 'KB', 'MB', 'GB', 'TB']; $i = 0;
    while ($b >= 1024 && $i < 4) { $b /= 1024; $i++; }
    return number_format($b, $i === 0 ? 0 : $dec, ',', ' ') . ' ' . $u[$i];
}
function fmt_bps(float $b): string {
    $u = ['b/s', 'Kb/s', 'Mb/s', 'Gb/s']; $i = 0;
    while ($b >= 1000 && $i < 3) { $b /= 1000; $i++; }
    return number_format($b, $i === 0 ? 0 : 1, ',', ' ') . ' ' . $u[$i];
}
function fmt_int(float $n): string { return number_format($n, 0, ',', ' '); }
function fmt_dec(float $n, int $d = 1): string { return number_format($n, $d, ',', ' '); }
function live_stats(): array {
    $l = jload(MP_STATS . '/live.json') ?? [];
    $l['fresh'] = isset($l['ts']) && time() - (int)$l['ts'] < 30;
    return $l;
}
function tz_off(array $live): int {
    if (!preg_match('/^([+-])(\d{2})(\d{2})$/', (string)($live['tz'] ?? ''), $m)) return 0;
    $s = (int)$m[2] * 3600 + (int)$m[3] * 60;
    return $m[1] === '-' ? -$s : $s;
}
/* Histórico: junta o ficheiro mais grosseiro com os mais finos para o período mais recente */
function hist_load(string $range): array {
    $cfg = [
        '24h' => [86400, [['hist-1m.csv', 60]]],
        '7d'  => [604800, [['hist-10m.csv', 600], ['hist-1m.csv', 60]]],
        '30d' => [2592000, [['hist-1h.csv', 3600], ['hist-10m.csv', 600], ['hist-1m.csv', 60]]],
    ];
    if (!isset($cfg[$range])) $range = '24h';
    $from = time() - $cfg[$range][0];
    $rows = []; $after = 0;
    foreach ($cfg[$range][1] as $fc) {
        $fh = @fopen(MP_STATS . '/' . $fc[0], 'r');
        if ($fh === false) continue;
        $last = $after;
        while (($line = fgets($fh)) !== false) {
            $c = explode(',', trim($line));
            if (count($c) < 8) continue;
            $t = (int)$c[0];
            if ($t < $from || $t < $after) continue;
            $rows[] = array_map('intval', $c);
            if ($t + $fc[1] > $last) $last = $t + $fc[1];
        }
        fclose($fh);
        $after = $last;
    }
    usort($rows, function ($a, $b) { return $a[0] <=> $b[0]; });
    return ['rows' => $rows, 'from' => $from, 'to' => time(), 'range' => $range, 'step' => $cfg[$range][1][0][1]];
}
function downsample(array $rows, int $max): array {
    $n = count($rows);
    if ($n <= $max) return $rows;
    $k = (int)ceil($n / $max); $out = [];
    for ($i = 0; $i < $n; $i += $k) {
        $chunk = array_slice($rows, $i, $k); $m = count($chunk); $avg = $chunk[0];
        for ($c = 1; $c < count($avg); $c++) { $s = 0; foreach ($chunk as $r) $s += $r[$c]; $avg[$c] = $s / $m; }
        $out[] = $avg;
    }
    return $out;
}
function nice_max(float $v): float {
    if ($v <= 0) return 1;
    $e = pow(10, floor(log10($v))); $f = $v / $e;
    $n = $f <= 1 ? 1 : ($f <= 2 ? 2 : ($f <= 2.5 ? 2.5 : ($f <= 5 ? 5 : 10)));
    return $n * $e;
}
function fmt_axis(float $v, string $fmt): string {
    if ($fmt === 'pct') return fmt_int($v) . '%';
    if ($fmt === 'bps') return fmt_bps($v);
    return fmt_dec($v, $v < 10 ? 1 : 0);
}
/* Gráfico de linhas em SVG (sem bibliotecas). $series: [[nome, cor, coluna, divisor]] */
/* Curva suave monótona (Fritsch-Carlson): passa por todos os pontos sem ultrapassá-los */
function smooth_path(array $p, float $lo, float $hi): string {
    $n = count($p);
    if ($n === 0) return '';
    $d = 'M' . $p[0][0] . ' ' . $p[0][1];
    if ($n === 1) return $d . 'h1';
    $dl = []; $m = [];
    for ($i = 0; $i < $n - 1; $i++) { $dx = $p[$i + 1][0] - $p[$i][0]; $dl[$i] = $dx != 0 ? ($p[$i + 1][1] - $p[$i][1]) / $dx : 0; }
    $m[0] = $dl[0]; $m[$n - 1] = $dl[$n - 2];
    for ($i = 1; $i < $n - 1; $i++) $m[$i] = ($dl[$i - 1] * $dl[$i] <= 0) ? 0 : ($dl[$i - 1] + $dl[$i]) / 2;
    for ($i = 0; $i < $n - 1; $i++) {
        if ($dl[$i] == 0) { $m[$i] = 0; $m[$i + 1] = 0; continue; }
        $a = $m[$i] / $dl[$i]; $b = $m[$i + 1] / $dl[$i]; $q = $a * $a + $b * $b;
        if ($q > 9) { $t = 3 / sqrt($q); $m[$i] = $t * $a * $dl[$i]; $m[$i + 1] = $t * $b * $dl[$i]; }
    }
    for ($i = 0; $i < $n - 1; $i++) {
        $h3 = ($p[$i + 1][0] - $p[$i][0]) / 3;
        $c1y = max($lo, min($hi, $p[$i][1] + $m[$i] * $h3));
        $c2y = max($lo, min($hi, $p[$i + 1][1] - $m[$i + 1] * $h3));
        $d .= 'C' . round($p[$i][0] + $h3, 1) . ' ' . round($c1y, 1) . ' ' . round($p[$i + 1][0] - $h3, 1) . ' ' . round($c2y, 1) . ' ' . $p[$i + 1][0] . ' ' . $p[$i + 1][1];
    }
    return $d;
}
function sparkline(array $v): string {
    $n = count($v);
    if ($n < 2) return '';
    $mx = max(1, max($v)); $pts = [];
    foreach (array_values($v) as $i => $x) $pts[] = [round($i * 1000 / ($n - 1), 1), round(112 - ($x / $mx) * 92, 1)];
    $line = smooth_path($pts, 0, 120);
    return '<svg viewBox="0 0 1000 120" preserveAspectRatio="none" aria-hidden="true"><path d="' . $line . 'L1000 120L0 120Z" style="fill:#fff;fill-opacity:.13;stroke:none"/>'
        . '<path d="' . $line . '" style="fill:none;stroke:#fff;stroke-opacity:.9;stroke-width:2.5" vector-effect="non-scaling-stroke"/></svg>';
}
/* Pedidos por hora (24 h) somando todos os sites, e totais por site */
function traffic_24h(array $sites): array {
    $now = time(); $from = $now - 86400;
    $hours = [];
    for ($t = intdiv($from, 3600) * 3600 + 3600; $t <= intdiv($now, 3600) * 3600; $t += 3600) $hours[$t] = 0;
    $per = [];
    foreach ($sites as $s) {
        $n = (string)($s['name'] ?? '');
        if (!valid_site($n)) continue;
        $per[$n] = [0, 0.0];
        $fh = @fopen(MP_STATS . '/traffic/' . $n . '.csv', 'r');
        if ($fh === false) continue;
        while (($l = fgets($fh)) !== false) {
            $c = explode(',', trim($l));
            if (count($c) < 3 || (int)$c[0] < $from - 3599) continue;
            $per[$n][0] += (int)$c[1]; $per[$n][1] += (float)$c[2];
            if (isset($hours[(int)$c[0]])) $hours[(int)$c[0]] += (int)$c[1];
        }
        fclose($fh);
    }
    return ['hours' => $hours, 'per' => $per];
}
function chart_html(array $H, array $series, string $fmt, ?float $ymax = null, ?float $ref = null, int $tz = 0): string {
    $rows = downsample($H['rows'], 480);
    $from = (int)$H['from']; $to = (int)$H['to']; $span = max(1, $to - $from);
    $vals = []; $mx = 0.0;
    foreach ($series as $si => $s) {
        $vals[$si] = [];
        foreach ($rows as $r) { $v = $r[$s[2]] / $s[3]; $vals[$si][] = $v; if ($v > $mx) $mx = $v; }
    }
    if ($ymax === null) $ymax = nice_max(max($mx, (float)($ref ?? 0)) * 1.15);
    $gap = max(180, (int)($H['step'] ?? 60) * 3) * max(1, (int)ceil(count($H['rows']) / 480));
    $svg = '';
    for ($k = 1; $k <= 3; $k++) { $y = 50 * $k; $svg .= '<line class="g" x1="0" x2="1000" y1="' . $y . '" y2="' . $y . '"/>'; }
    if ($ref !== null && $ref < $ymax) { $y = round(200 * (1 - $ref / $ymax), 1); $svg .= '<line class="ref" x1="0" x2="1000" y1="' . $y . '" y2="' . $y . '"/>'; }
    $dots = count($rows) <= 40;
    foreach ($series as $si => $s) {
        $segs = []; $cur = []; $prevT = null;
        foreach ($rows as $i => $r) {
            $pt = [round(($r[0] - $from) / $span * 1000, 1), round(200 * (1 - min($vals[$si][$i], $ymax) / $ymax), 1)];
            if ($prevT !== null && $r[0] - $prevT > $gap) { $segs[] = $cur; $cur = []; }
            $cur[] = $pt; $prevT = $r[0];
        }
        if ($cur) $segs[] = $cur;
        $col = 'stroke:' . $s[1];
        $line = ''; $area = ''; $dotp = '';
        foreach ($segs as $seg) {
            $p = smooth_path($seg, 0, 200);
            $line .= $p;
            if ($si === 0 && count($seg) > 1) $area .= $p . 'L' . $seg[count($seg) - 1][0] . ' 200L' . $seg[0][0] . ' 200Z';
            if ($dots) foreach ($seg as $pt) $dotp .= 'M' . $pt[0] . ' ' . $pt[1] . 'h0.01';
        }
        if ($area !== '') $svg .= '<path class="a" style="fill:' . h($s[1]) . '" d="' . $area . '"/>';
        if ($line !== '') $svg .= '<path class="s" style="' . h($col) . '" d="' . $line . '"/>';
        if ($dotp !== '') $svg .= '<path class="dot" style="' . h($col) . '" d="' . $dotp . '"/>';
    }
    $ylab = '';
    for ($k = 0; $k <= 4; $k++) $ylab .= '<span style="top:' . ($k * 25) . '%">' . h(fmt_axis($ymax * (4 - $k) / 4, $fmt)) . '</span>';
    $xlab = '';
    for ($k = 0; $k <= 6; $k++) {
        $t = (int)($from + $span * $k / 6) + $tz;
        $lab = $H['range'] === '24h' ? gmdate('H:i', $t) : gmdate('d/m', $t);
        $xlab .= '<span' . ($k === 0 ? ' class="first"' : ($k === 6 ? ' class="last"' : '')) . ' style="left:' . round($k * 100 / 6, 3) . '%">' . h($lab) . '</span>';
    }
    $data = ['from' => $from, 'to' => $to, 'tz' => $tz, 'fmt' => $fmt, 't' => array_map(function ($r) { return (int)$r[0]; }, $rows), 's' => []];
    foreach ($series as $si => $s) $data['s'][] = ['n' => $s[0], 'c' => $s[1], 'v' => array_map(function ($v) { return round($v, 2); }, $vals[$si])];
    $empty = count($rows) < 2 ? '<div class="ch-empty">Ainda sem dados suficientes para este período; é gravado um ponto por minuto.</div>' : '';
    return '<div class="chart" data-chart="' . h((string)json_encode($data)) . '"><div class="ch-y">' . $ylab . '</div>'
        . '<div class="ch-plot"><svg viewBox="0 0 1000 200" preserveAspectRatio="none" aria-hidden="true">' . $svg . '</svg>'
        . '<div class="ch-cur"></div><div class="ch-tip"></div>' . $empty . '</div><div class="ch-x">' . $xlab . '</div></div>';
}
function legend(array $series): string {
    $o = '<div class="legend">';
    foreach ($series as $s) $o .= '<span><i style="background:' . h($s[1]) . '"></i>' . h($s[0]) . '</span>';
    return $o . '</div>';
}

function svc_usage(array $s, array $bySite): string {
    $id = (string)($s['id'] ?? '');
    if ($id === 'nginx') return 'Servidor web dos sites e do painel';
    if ($id === 'mariadb') return 'Bases de dados (apenas localhost)';
    $n = (int)($bySite[(string)($s['version'] ?? '')] ?? 0);
    $t = $n === 0 ? 'Nenhum site' : ($n === 1 ? '1 site' : $n . ' sites');
    return !empty($s['panel']) ? $t . ' e o próprio painel' : $t;
}

$titles = [
    'resumo'   => $sys ? trim(($sys['hostname'] ?? '') . ' · ' . ($sys['ip'] ?? '') . ' · ' . ($sys['os'] ?? '') . ' · ativo há ' . fmt_uptime((int)($sys['uptime'] ?? 0)), ' ·') : 'Estado do servidor',
    'sites'    => 'Cada site tem a sua porta e fica acessível por IP ou localhost.',
    'bd'       => 'O utilizador tem o mesmo nome da base de dados. Servidor localhost, porta 3306.',
    'php'      => 'Versões instaladas e extensões de cada versão.',
    'servicos' => 'Estado dos serviços e ações de manutenção.',
    'conta'    => 'Acesso ao painel.',
    'recursos' => 'Utilização do servidor e de cada site, atualizada a cada 5 segundos.',
    'ficheiros'=> 'Ficheiros de todos os sites e das caixas de correio, cada um gerido com o seu próprio utilizador.',
    'ligacoes' => 'Ligações abertas a este servidor, bloqueio de IPs e bloqueio automático.',
    'cron'     => 'Tarefas agendadas (cron) de cada site, como no cPanel.',
    'backups'  => 'Backups dos sites e das bases de dados, locais e remotos.',
    'definicoes' => 'Modo do servidor, acesso pelas portas, IPs autorizados, proteção contra força bruta, phpMyAdmin, FTP, Let\'s Encrypt e domínio do painel.',
    'auditoria'=> 'Quem fez o quê, quando e de onde.',
    'atualizacoes' => 'Atualizações do painel (com assinatura e reposição automática) e do sistema operativo.',
    'sentinela' => 'Testa todos os serviços a cada minuto, repara o que falha e alerta por SMS e email.',
    'processos' => 'Processos que consomem CPU e memória, com a origem (site, email, base de dados, sistema) e a opção de os terminar.',
    'alertas'  => 'Alertas por SMS e email: CPU, RAM, disco, ligações e volume de email.',
    'terminal' => 'Terminal do servidor (root) no browser. Exige a verificação em dois passos; as sessões ficam gravadas.',
    'email'    => 'Caixas de correio, envio dos sites e antispam.',
    'dns'      => 'DNS autoritativo: zonas dos domínios alojados neste servidor.',
    'logs'     => 'Acessos e erros de cada site: servidor web, PHP e tarefas agendadas.',
];
$groups = ['Geral' => ['resumo', 'recursos'], 'Alojamento' => ['sites', 'ficheiros', 'logs', 'cron', 'email', 'dns', 'bd', 'php'], 'Sistema' => ['servicos', 'sentinela', 'processos', 'ligacoes', 'alertas', 'terminal', 'backups', 'auditoria', 'atualizacoes']];
$section = in_array($page, ['conta', 'definicoes'], true) ? 'Sistema' : 'Geral';
foreach ($groups as $gl => $keys) { if (in_array($page, $keys, true)) $section = $gl; }
$lvTop = live_stats();
$today = gmdate('d/m/Y', time() + tz_off($lvTop));
$openOnLoad = '';
if (qget('novo') === 'site') $openOnLoad = 'dlg-site-new';
elseif (qget('novo') === 'bd') $openOnLoad = 'dlg-db-new';
elseif (qget('limites') !== '' && valid_site(qget('limites'))) $openOnLoad = 'dlg-lim-' . qget('limites');
?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head($pages[$page][0]) ?></head>
<body data-pending="<?= (int)$pending ?>" data-autoopen="<?= h($openOnLoad) ?>">
<noscript><?php if ($pending > 0): ?><meta http-equiv="refresh" content="3"><?php endif; ?><div style="padding:10px 16px;background:#fdf1dc;color:#9a5b08">O painel precisa de JavaScript para as janelas e menus.</div></noscript>
<div class="app">
  <aside class="side" id="side">
    <a class="brand" href="?p=resumo" aria-label="IDDigital Hosting — Resumo"><?= brand_logo() ?></a>
    <nav class="nav">
      <?php foreach ($groups as $gl => $keys): if ($gl === 'Sistema') continue; ?>
        <div class="nav-sec"><?= h($gl) ?></div>
        <?php foreach ($keys as $k): $pd = $pages[$k]; ?>
          <a href="?p=<?= h($k) ?>"<?= $k === $page ? ' class="on" aria-current="page"' : '' ?>><?= ic($pd[1]) ?><?= h($pd[0]) ?></a>
          <?php if ($k === 'bd' && $pmaOn): ?><a href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('table') ?>phpMyAdmin<?= ic('ext', 'tail') ?></a><?php endif; ?>
        <?php endforeach; ?>
      <?php endforeach; ?>
    </nav>
    <div class="side-foot">IDDigital Hosting v<?= h(MP_VERSION) ?></div>
  </aside>
  <div class="scrim" data-nav-close></div>

  <div class="main">
    <header class="top">
      <button class="iconbtn burger" type="button" data-nav-open aria-label="Abrir menu"><?= ic('menu') ?></button>
      <div class="grow">
        <div class="crumb"><?= h($section) ?></div>
        <h1><?= h($pages[$page][0]) ?></h1>
        <p><?= h($titles[$page]) ?></p>
      </div>
      <div class="top-actions">
        <?php if ($page === 'sites' || $page === 'resumo'): ?>
          <button class="chip prim" type="button" data-open="dlg-site-new" aria-label="Novo site"><?= ic('plus') ?><span class="lbl">Novo site</span></button>
        <?php elseif ($page === 'bd'): ?>
          <button class="chip prim" type="button" data-open="dlg-db-new" aria-label="Nova base de dados"><?= ic('plus') ?><span class="lbl">Nova base de dados</span></button>
        <?php elseif ($page === 'cron' && $sites): ?>
          <button class="chip prim" type="button" data-cron-new aria-label="Nova tarefa"><?= ic('plus') ?><span class="lbl">Nova tarefa</span></button>
        <?php elseif ($page === 'backups'): ?>
          <button class="chip prim" type="button" data-open="dlg-bk-now" aria-label="Fazer backup agora"><?= ic('archive') ?><span class="lbl">Fazer backup</span></button>
        <?php elseif ($page === 'ligacoes'): ?>
          <button class="chip prim" type="button" data-open="dlg-block" aria-label="Bloquear IP"><?= ic('ban') ?><span class="lbl">Bloquear IP</span></button>
        <?php endif; ?>
        <form method="post" style="margin:0"><?= act_fields('refresh') ?><button class="chip" type="submit" title="Atualizar estado" aria-label="Atualizar estado"><?= ic('reload') ?><span class="lbl">Atualizar</span></button></form>
        <span class="chip sm hide-m">v<?= h(MP_VERSION) ?></span>
        <span class="chip ghost hide-m"><?= h($today) ?></span>
        <button class="chip icon" type="button" data-theme-toggle title="Mudar tema" aria-label="Mudar tema"><?= ic('moon') ?></button>
        <details class="dd sys">
          <summary class="chip<?= $section === 'Sistema' && !in_array($page, ['conta', 'definicoes'], true) ? ' cur' : '' ?>" aria-label="Sistema"><?= ic('server') ?><span class="lbl">Sistema</span><?= ic('chev', 'chev') ?></summary>
          <div class="dd-menu">
            <?php foreach ($groups['Sistema'] as $k): $pd = $pages[$k]; ?>
              <a href="?p=<?= h($k) ?>"<?= $k === $page ? ' aria-current="page"' : '' ?>><?= ic($pd[1]) ?><?= h($pd[0]) ?></a>
            <?php endforeach; ?>
          </div>
        </details>
        <details class="dd me">
          <summary class="chip" aria-label="Conta"><span class="av-me"><?= h(substr((string)$_SESSION['user'], 0, 1)) ?></span><span class="lbl"><?= h($_SESSION['user']) ?></span><?= ic('chev', 'chev') ?></summary>
          <div class="dd-menu">
            <a href="?p=conta"<?= $page === 'conta' ? ' aria-current="page"' : '' ?>><?= ic('user') ?>Conta e segurança</a>
            <a href="?p=definicoes"<?= $page === 'definicoes' ? ' aria-current="page"' : '' ?>><?= ic('sliders') ?>Definições</a>
            <hr>
            <form method="post"><?= act_fields('sair') ?><button type="submit"><?= ic('out') ?>Sair</button></form>
          </div>
        </details>
      </div>
    </header>

    <main class="content">
<?php if (!$state): ?>
      <div class="card"><div class="empty"><b>O estado do servidor ainda não está disponível</b>Carrega em atualizar, no canto superior direito, ou corre <span class="mono">mpanel state</span> no servidor para ver o erro.</div></div>
<?php endif; ?>

<?php if ($page === 'resumo'):
    $lv = live_stats();
    $disk = (int)round($lv['fresh'] ? (float)($lv['disk']['pct'] ?? 0) : (float)($sys['disk'] ?? 0));
    $ram  = (int)round($lv['fresh'] ? (float)($lv['mem']['pct'] ?? 0) : (float)($sys['ram'] ?? 0));
    $hot  = $disk >= 90 || $ram >= 90;
    $H24  = hist_load('24h');
    $tr   = traffic_24h($sites);
    $reqTot = 0; $byTot = 0.0;
    foreach ($tr['per'] as $pv) { $reqTot += $pv[0]; $byTot += $pv[1]; }
    $reqMax = 1;
    foreach ($tr['per'] as $pv) $reqMax = max($reqMax, $pv[0]);
    $sorted = $sites;
    usort($sorted, function ($x, $y) use ($tr) { return ($tr['per'][$y['name'] ?? ''][0] ?? 0) <=> ($tr['per'][$x['name'] ?? ''][0] ?? 0); }); ?>
      <div class="hero">
        <section class="card">
          <div class="card-h"><div><h2>Utilização do servidor</h2><p>CPU e memória nas últimas 24 horas</p></div><a class="chip sm soft" href="?p=recursos">Ver recursos</a></div>
          <?= chart_html($H24, [['CPU', 'var(--c1)', 1, 10], ['Memória', 'var(--c2)', 2, 10]], 'pct', 100, null, tz_off($lv)) ?>
        </section>
        <section class="hl">
          <div class="k">Pedidos nas últimas 24 horas</div>
          <div class="v"><?= h(fmt_int($reqTot)) ?></div>
          <div class="s"><?= h(fmt_bytes($byTot)) ?> transferidos · <?= $active ?> de <?= count($sites) ?> sites ativos</div>
          <?= sparkline(array_values($tr['hours'])) ?>
        </section>
      </div>

      <section class="stats">
        <div class="stat"><span class="tile t-acc"><?= ic('world') ?></span><div><div class="k">Sites ativos</div><div class="v"><?= $active ?> <small>de <?= count($sites) ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('db') ?></span><div><div class="k">Bases de dados</div><div class="v"><?= count($dbs) ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('code') ?></span><div><div class="k">Versões de PHP</div><div class="v"><?= count($phps) ?> <small><?= $defPhp !== '' ? 'predefinida ' . h($defPhp) : '' ?></small></div></div></div>
        <a class="stat<?= $hot ? ' hot' : '' ?>" href="?p=recursos"><span class="tile t-warn"><?= ic('cpu') ?></span><div><div class="k">Disco e memória<?= $hot ? ' · atenção' : '' ?></div><div class="v"><?= $disk ?>% <small>disco · <?= $ram ?>% RAM</small></div><div class="meter"><i class="<?= $disk >= 90 ? 'hi' : '' ?>" style="width:<?= max(0, min(100, $disk)) ?>%"></i></div></div></a>
      </section>

      <div class="grid2">
        <section class="card">
          <div class="card-h"><div><h2>Sites</h2><p>Pedidos nas últimas 24 horas</p></div><a class="chip sm soft" href="?p=sites">Ver todos</a></div>
          <?php if (!$sites): ?>
            <div class="empty"><b>Ainda não há sites</b>Cria o primeiro; fica logo acessível numa porta própria.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div>
          <?php else: ?>
          <div class="row-list bars">
            <?php foreach (array_slice($sorted, 0, 8) as $s): $n = (string)$s['name']; $port = (int)$s['port']; $on = !empty($s['enabled']); $rq = (int)($tr['per'][$n][0] ?? 0); ?>
              <div class="item">
                <div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu"><?php $mu = site_main_url($s); ?><?= $mu !== '' ? h(preg_replace('#^https?://|/$#', '', $mu)) . ' · ' : '' ?><span class="mono">:<?= $port ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div>
                <div class="bar"><i style="width:<?= round($rq * 100 / $reqMax, 1) ?>%"></i></div>
                <b class="num"><?= h(fmt_int($rq)) ?></b>
                <span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span>
                <?php if ($on): ?><a class="iconbtn" href="<?= h(site_main_url($s) !== '' ? site_main_url($s) : site_url($host, $port)) ?>" target="_blank" rel="noopener" title="Abrir" aria-label="Abrir <?= h($n) ?>"><?= ic('ext') ?></a><?php else: ?><span></span><?php endif; ?>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
        </section>

        <section class="card">
          <div class="card-h"><div><h2>Serviços</h2><p>Estado atual</p></div><?php if ($svcDown > 0): ?><span class="pill p-err"><?= $svcDown ?> parado<?= $svcDown === 1 ? '' : 's' ?></span><?php else: ?><a class="chip sm soft" href="?p=servicos">Gerir</a><?php endif; ?></div>
          <div class="row-list">
            <?php foreach ($svcs as $s): $on = !empty($s['active']); ?>
              <div class="item">
                <span class="pill <?= $on ? 'p-ok' : 'p-err' ?>"><?= $on ? 'Ativo' : 'Parado' ?></span>
                <div class="grow nm"><?= h($s['name'] ?? '') ?></div>
                <?php if (($s['id'] ?? '') === 'nginx' || ($s['id'] ?? '') === 'mariadb' || !$on): ?>
                  <?= svc_actions($s, $bySite) ?>
                <?php else: ?>
                  <form method="post" style="margin:0"><?= act_fields('svc', ['svc' => (string)$s['id'], 'act' => 'reload']) ?><button class="btn sm sec" type="submit"><?= ic('reload') ?>Recarregar</button></form>
                <?php endif; ?>
              </div>
            <?php endforeach; ?>
            <?php if (!$svcs): ?><div class="empty">Sem informação dos serviços.</div><?php endif; ?>
          </div>
        </section>
      </div>

<?php elseif ($page === 'sites'): ?>
      <section class="card">
        <?php if (!$sites): ?>
          <div class="empty"><b>Ainda não há sites</b>Cria o primeiro; fica logo acessível numa porta própria.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Site</th><th>Endereço</th><th>PHP</th><th>Limites</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($sites, 50); foreach ($pgList as $s):
                $n = (string)($s['name'] ?? ''); $port = (int)($s['port'] ?? 0); $on = !empty($s['enabled']); $L = site_limits($s);
                $url = site_url($host, $port); ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu mono"><?= h($s['root'] ?? '') ?></div></div></div></td>
              <td data-label="Endereço">
                <?php $mu = site_main_url($s); $nd = count(array_filter(explode(' ', (string)($s['domains'] ?? '')))); ?>
                <?php if ($mu !== ''): ?>
                <?php if (($s['ssl'] ?? 'none') !== 'none' && empty($s['https_ok'])): ?><div style="margin-bottom:4px"><button type="button" class="pill p-warn" data-open="dlg-dom-<?= h($n) ?>" style="border:0;cursor:pointer" title="O certificado não foi emitido (o domínio já aponta para este servidor?)">Sem certificado · pedir novamente</button></div><?php endif; ?>
                <div class="links dom"><?= !empty($s['https_ok']) ? ic('lock', 'lock') : '' ?><?php if ($on): ?><a href="<?= h($mu) ?>" target="_blank" rel="noopener"><?= h(preg_replace('#^https?://|/$#', '', $mu)) ?><?= ic('ext') ?></a><?php else: ?><span><?= h(preg_replace('#^https?://|/$#', '', $mu)) ?></span><?php endif; ?><?= $nd > 1 ? ' <span class="mu">+' . ($nd - 1) . '</span>' : '' ?></div>
                <?php endif; ?>
                <div class="links"><span class="port">:<?= $port ?></span>
                <?php if ($on): ?> <a href="<?= h($url) ?>" target="_blank" rel="noopener"><?= h(preg_replace('#^http://|/$#', '', $url)) ?><?= ic('ext') ?></a><?php endif; ?></div>
              </td>
              <td data-label="PHP"><?= h($s['php'] ?? '') ?></td>
              <td data-label="Limites"><div class="lim"><span><b><?= (int)$L['memory'] ?></b> MB</span><span>upload <b><?= (int)$L['upload'] ?></b> MB</span><span><b><?= (int)$L['exec'] ?></b> s</span></div></td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($on): ?><a href="<?= h($url) ?>" target="_blank" rel="noopener"><?= ic('ext') ?>Abrir site</a><?php endif; ?>
                    <a href="?p=ficheiros&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('folder') ?>Ficheiros</a>
                    <a href="?p=cron&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('clock') ?>Tarefas agendadas</a>
                    <a href="?p=logs&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('logs') ?>Logs</a>
                    <button type="button" data-open="dlg-dom-<?= h($n) ?>"><?= ic('world') ?>Domínios e SSL</button>
                    <button type="button" data-open="dlg-perf-<?= h($n) ?>"><?= ic('pulse') ?>Desempenho<?= !empty($s['perf']['cache']) ? ' <span class="pill p-ok" style="margin-left:auto">Cache</span>' : '' ?></button>
                    <button type="button" data-open="dlg-ftp-<?= h($n) ?>"><?= ic('upload') ?>Acesso FTP/SFTP<?= !empty($s['ftp']) ? ' <span class="pill p-ok" style="margin-left:auto">Ativo</span>' : '' ?></button>
                    <button type="button" data-open="dlg-lim-<?= h($n) ?>"><?= ic('sliders') ?>Limites</button>
                    <button type="button" data-open="dlg-php-<?= h($n) ?>"><?= ic('code') ?>Mudar versão de PHP</button>
                    <form method="post"><?= act_fields('site_perm', ['site' => $n]) ?><button type="submit"><?= ic('lock') ?>Corrigir permissões</button></form>
                    <form method="post"><?= act_fields($on ? 'site_off' : 'site_on', ['site' => $n]) ?><button type="submit"><?= ic('toggle') ?><?= $on ? 'Desativar' : 'Ativar' ?></button></form>
                    <hr>
                    <button type="button" class="dan" data-open="dlg-del-<?= h($n) ?>"><?= ic('trash') ?>Apagar</button>
                  </div>
                </details>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'sites') ?></div><?php endif; ?>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'recursos'):
    $live = live_stats();
    $tz = tz_off($live);
    $range = in_array(qget('r'), ['24h', '7d', '30d'], true) ? qget('r') : '24h';
    $H = hist_load($range);
    $sj = jload(MP_STATS . '/sites.json') ?? [];
    $sjs = is_array($sj['sites'] ?? null) ? $sj['sites'] : [];
    $ls = is_array($live['sites'] ?? null) ? $live['sites'] : [];
    $ncpu = max(1, (int)($live['cpus'] ?? ($sys['cpus'] ?? 1)));
    $mem = is_array($live['mem'] ?? null) ? $live['mem'] : [];
    $dsk = is_array($live['disk'] ?? null) ? $live['disk'] : [];
    $swp = is_array($live['swap'] ?? null) ? $live['swap'] : [];
    $load = is_array($live['load'] ?? null) ? $live['load'] : [0, 0, 0];
    $net = is_array($live['net'] ?? null) ? $live['net'] : [];
    $sCpu = [['CPU', 'var(--c1)', 1, 10], ['Memória', 'var(--c2)', 2, 10], ['Swap', 'var(--c3)', 3, 10]];
    $sNet = [['Receção', 'var(--c1)', 6, 1], ['Envio', 'var(--c2)', 7, 1]];
    $sLoad = [['Carga (1 min)', 'var(--c3)', 5, 100]];
    $pills = '<div class="pills">';
    foreach (['24h' => '24 h', '7d' => '7 dias', '30d' => '30 dias'] as $rk => $rl) $pills .= '<a class="' . ($rk === $range ? 'on' : '') . '" href="?p=recursos&amp;r=' . $rk . '">' . $rl . '</a>';
    $pills .= '</div>';
?>
      <?php if (!$live['fresh']): ?>
        <div class="card"><div class="empty"><b>O recolhedor de estatísticas não está a responder</b>No servidor: <span class="mono">systemctl status minipainel-stats</span></div></div>
      <?php endif; ?>
      <section class="stats stats5" data-live>
        <div class="stat"><span class="tile t-acc"><?= ic('cpu') ?></span><div><div class="k">CPU (<?= $ncpu ?> vCPU)</div><div class="v" data-l="cpu"><?= h(fmt_dec((float)($live['cpu'] ?? 0))) ?>%</div><div class="meter"><i data-lm="cpu" style="width:<?= min(100, (float)($live['cpu'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('server') ?></span><div><div class="k">Memória</div><div class="v"><span data-l="mem"><?= h(fmt_dec((float)($mem['pct'] ?? 0))) ?>%</span> <small data-l="mem-sub"><?= h(fmt_bytes((float)($mem['used'] ?? 0) * 1024) . ' / ' . fmt_bytes((float)($mem['total'] ?? 0) * 1024)) ?></small></div><div class="meter"><i data-lm="mem" style="width:<?= min(100, (float)($mem['pct'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('db') ?></span><div><div class="k">Disco /</div><div class="v"><span data-l="disk"><?= h(fmt_dec((float)($dsk['pct'] ?? 0))) ?>%</span> <small data-l="disk-sub"><?= h(fmt_bytes((float)($dsk['used'] ?? 0) * 1024) . ' / ' . fmt_bytes((float)($dsk['total'] ?? 0) * 1024)) ?></small></div><div class="meter"><i data-lm="disk" style="width:<?= min(100, (float)($dsk['pct'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('pulse') ?></span><div><div class="k">Carga</div><div class="v"><span data-l="load"><?= h(fmt_dec((float)($load[0] ?? 0), 2)) ?></span> <small data-l="load-sub">5 min <?= h(fmt_dec((float)($load[1] ?? 0), 2)) ?> · 15 min <?= h(fmt_dec((float)($load[2] ?? 0), 2)) ?></small></div><div class="mu" data-l="swap">Swap <?= h(fmt_dec((float)($swp['pct'] ?? 0))) ?>%</div></div></div>
        <div class="stat"><span class="tile t-acc"><?= ic('world') ?></span><div><div class="k">Rede</div><div class="v" data-l="net"><?= h(fmt_bps((float)($net['rx'] ?? 0) + (float)($net['tx'] ?? 0))) ?></div><div class="mu" data-l="net-sub">↓ <?= h(fmt_bps((float)($net['rx'] ?? 0))) ?> · ↑ <?= h(fmt_bps((float)($net['tx'] ?? 0))) ?></div></div></div>
      </section>

      <section class="card">
        <div class="card-h"><h2>CPU, memória e swap</h2><?= legend($sCpu) ?><?= $pills ?></div>
        <?= chart_html($H, $sCpu, 'pct', 100, null, $tz) ?>
      </section>

      <div class="grid2e">
        <section class="card">
          <div class="card-h"><h2>Rede</h2><?= legend($sNet) ?></div>
          <?= chart_html($H, $sNet, 'bps', null, null, $tz) ?>
        </section>
        <section class="card">
          <div class="card-h"><h2>Carga do sistema</h2><div class="legend"><span><i style="background:var(--c3)"></i>Carga (1 min)</span><span><i class="dash"></i><?= $ncpu ?> vCPU</span></div></div>
          <?= chart_html($H, $sLoad, 'load', null, (float)$ncpu, $tz) ?>
        </section>
      </div>

      <section class="card">
        <div class="card-h"><h2>Consumo por site</h2><p>CPU e RAM em tempo real; tráfego das últimas 24 horas.</p></div>
        <?php if (!$sites): ?>
          <div class="empty">Ainda não há sites.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Site</th><th class="r">CPU</th><th class="r">RAM</th><th class="r">Disco</th><th class="r">Pedidos (24 h)</th><th class="r">Tráfego (24 h)</th></tr></thead>
          <tbody>
          <?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); $L = $ls[$n] ?? []; $J = $sjs[$n] ?? []; ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div><div class="nm"><?= h($n) ?></div><div class="mu"><span class="mono">:<?= (int)($s['port'] ?? 0) ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div></td>
              <td class="r" data-label="CPU" data-ls="<?= h($n) ?>:cpu"><?= h(fmt_dec((float)($L['cpu'] ?? 0))) ?>%</td>
              <td class="r" data-label="RAM" data-ls="<?= h($n) ?>:rss"><?= h(fmt_bytes((float)($L['rss'] ?? 0) * 1024)) ?></td>
              <td class="r" data-label="Disco"><?= isset($J['disk']) && (int)($sj['disk_ts'] ?? 0) > 0 ? h(fmt_bytes((float)$J['disk'])) : '<span class="mu">a medir…</span>' ?></td>
              <td class="r" data-label="Pedidos (24 h)"><?= h(fmt_int((float)($J['req24'] ?? 0))) ?></td>
              <td class="r" data-label="Tráfego (24 h)"><?= h(fmt_bytes((float)($J['bytes24'] ?? 0))) ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">CPU em percentagem da capacidade total do servidor. A RAM é aproximada (inclui memória partilhada entre processos). O disco de cada site é medido de hora a hora; as bases de dados não estão incluídas.</div>
      </section>

<?php elseif ($page === 'ficheiros'):
    $names = [];
    foreach ($sites as $s) { $n = (string)($s['name'] ?? ''); if (valid_site($n)) $names[] = $n; }
    $mailOnFm = !empty($state['mail']['enabled']);
    $fmSite = in_array(qget('site'), $names, true) ? qget('site') : (($mailOnFm && qget('site') === '_email') ? '_email' : '');
    $fmArea = qget('area') === 'sites' ? 'sites' : '';
    $nDom = is_array($state['mail']['domains'] ?? null) ? count($state['mail']['domains']) : 0;
?>
      <?php if ($fmSite === ''): ?>
      <section class="card">
        <div class="card-h"><nav class="crumbs fm-pre" aria-label="Caminho"><a href="?p=ficheiros"><?= ic('home') ?>Ficheiros</a><?php if ($fmArea === 'sites'): ?><span>›</span><a href="?p=ficheiros&amp;area=sites">Sites</a><?php endif; ?></nav></div>
        <table class="list cards fm-root">
          <thead><tr><th>Nome</th><th>Conteúdo</th><th>Localização</th></tr></thead>
          <tbody>
          <?php if ($fmArea === ''): ?>
            <tr><td class="first" data-label="Nome"><a class="who" href="?p=ficheiros&amp;area=sites"><span class="av t-blue"><?= ic('folder') ?></span><span class="nm">Sites</span></a></td><td data-label="Conteúdo"><?= count($names) ?> site<?= count($names) === 1 ? '' : 's' ?></td><td class="mono mu" data-label="Localização">/srv/www</td></tr>
            <?php if ($mailOnFm): ?>
            <tr><td class="first" data-label="Nome"><a class="who" href="?p=ficheiros&amp;site=_email"><span class="av t-vio"><?= ic('mail') ?></span><span class="nm">Email</span></a></td><td data-label="Conteúdo"><?= $nDom ?> domínio<?= $nDom === 1 ? '' : 's' ?></td><td class="mono mu" data-label="Localização">/var/mail/vhosts</td></tr>
            <?php else: ?>
            <tr><td class="first" data-label="Nome"><span class="who"><span class="av t-vio"><?= ic('mail') ?></span><span class="nm mu">Email</span></span></td><td class="mu" data-label="Conteúdo">O email não está ativo · <a href="?p=email">Ativar</a></td><td class="mono mu" data-label="Localização">/var/mail/vhosts</td></tr>
            <?php endif; ?>
          <?php else: ?>
            <?php if (!$names): ?><tr><td colspan="3"><div class="empty"><b>Ainda não há sites</b><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div></td></tr><?php endif; ?>
            <?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); if (!valid_site($n)) continue; $mu = site_main_url($s); ?>
            <tr><td class="first" data-label="Nome"><a class="who" href="?p=ficheiros&amp;site=<?= h(rawurlencode($n)) ?>"><span class="av <?= tone($n) ?>"><?= ic('folder') ?></span><span class="nm"><?= h($n) ?></span></a></td><td data-label="Conteúdo" class="mu"><?= $mu !== '' ? h(preg_replace('#^https?://|/$#', '', $mu)) . ' · ' : '' ?>porta <?= (int)$s['port'] ?></td><td class="mono mu" data-label="Localização">/srv/www/<?= h($n) ?></td></tr>
            <?php endforeach; ?>
          <?php endif; ?>
          </tbody>
        </table>
        <div class="card-f mu">Cada pasta é aberta com o utilizador do respetivo site (ou do email), por isso os ficheiros criados ficam sempre com o dono certo. Os ficheiros do sistema não são acessíveis pelo painel.</div>
      </section>
      <?php else: ?>
      <section class="card fm" id="fm" data-site="<?= h($fmSite) ?>" data-label="<?= h($fmSite === '_email' ? 'Email' : $fmSite) ?>" data-noedit="<?= $fmSite === '_email' ? '1' : '0' ?>" data-dir="<?= h(qget('dir')) ?>">
        <div class="fm-bar">
          <nav class="crumbs fm-pre" aria-label="Raiz"><a href="?p=ficheiros"><?= ic('home') ?>Ficheiros</a><span>›</span><?php if ($fmSite !== '_email'): ?><a href="?p=ficheiros&amp;area=sites">Sites</a><span>›</span><?php endif; ?></nav>
          <nav class="crumbs" id="fm-crumbs" aria-label="Caminho"></nav>
          <div class="fm-tools">
            <button class="btn sm sec" type="button" data-fm="mkdir"><?= ic('folderplus') ?>Nova pasta</button>
            <?php if ($fmSite !== '_email'): ?><button class="btn sm sec" type="button" data-fm="newfile"><?= ic('file') ?>Novo ficheiro</button><?php endif; ?>
            <label class="btn sm sec"><?= ic('upload') ?>Enviar pasta<input type="file" id="fm-updir" webkitdirectory multiple hidden></label>
            <label class="btn sm"><?= ic('upload') ?>Enviar ficheiros<input type="file" id="fm-upfiles" multiple hidden></label>
          </div>
        </div>
        <div class="fm-selbar" id="fm-selbar" hidden>
          <span id="fm-selcount"></span><span class="grow"></span>
          <button class="btn sm sec" type="button" data-fm="move"><?= ic('move') ?>Mover</button>
          <button class="btn sm sec" type="button" data-fm="zip"><?= ic('zip') ?>Compactar</button>
          <button class="btn sm sec" type="button" data-fm="chmod"><?= ic('lock') ?>Permissões</button>
          <button class="btn sm dan" type="button" data-fm="delete"><?= ic('trash') ?>Apagar</button>
          <button class="btn sm sec" type="button" data-fm="clear">Limpar seleção</button>
        </div>
        <div class="fm-drop" id="fm-drop">
          <table class="list cards fm-list">
            <thead><tr><th><label class="fm-ck"><input type="checkbox" id="fm-all" aria-label="Selecionar tudo"></label> Nome</th><th class="r">Tamanho</th><th>Modificado</th><th>Permissões</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
            <tbody id="fm-rows"><tr><td colspan="5" class="empty">A carregar…</td></tr></tbody>
          </table>
          <div class="fm-hint">Larga aqui para enviar para esta pasta</div>
        </div>
        <div class="card-f mu" id="fm-foot"><?= $fmSite === '_email' ? 'Área Email: uma pasta por domínio e por caixa (formato Maildir). Podes ver, descarregar e apagar; as mensagens não se editam aqui para não danificar os índices do Dovecot.' : 'Arrasta ficheiros ou pastas para a lista para os enviar. Os envios são feitos por partes e retomam se a ligação falhar.' ?></div>
      </section>
      <div class="fm-menu" id="fm-menu" hidden></div>
      <div class="ups" id="fm-ups" hidden>
        <div class="ups-h"><b>Envios</b><span id="fm-ups-sum"></span><button class="iconbtn" type="button" id="fm-ups-close" aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="ups-l" id="fm-ups-list"></div>
      </div>
      <dialog id="fm-dlg">
        <form method="dialog">
          <div class="dlg-h"><h3 id="fm-dlg-t"></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b"><div id="fm-dlg-msg" class="mu"></div><input class="in" id="fm-dlg-in" autocomplete="off"></div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" id="fm-dlg-ok" value="ok">OK</button></div>
        </form>
      </dialog>
      <dialog class="drawer fm-ed" id="fm-ed" data-keep>
        <div class="dlg-h"><div style="min-width:0"><h3>Editar ficheiro</h3><p class="mono" id="fm-ed-t"></p></div><button class="iconbtn" type="button" id="fm-ed-x" aria-label="Fechar"><?= ic('x') ?></button></div>
        <textarea id="fm-ed-ta" spellcheck="false" autocapitalize="off" autocomplete="off" aria-label="Conteúdo do ficheiro"></textarea>
        <div class="dlg-f"><span class="mu" id="fm-ed-st"></span><button class="btn sec" type="button" id="fm-ed-close">Fechar</button><button class="btn" type="button" id="fm-ed-save">Gravar (Ctrl+S)</button></div>
      </dialog>
      <?php endif; ?>

<?php elseif ($page === 'bd'): ?>
      <?php $pg = is_array($state['perf'] ?? null) ? $state['perf'] : []; $slow = jload(MP_STATS . '/db-slow.json') ?? ['rows' => []]; ?>
      <div class="grid2e" style="align-items:stretch">
      <section class="card">
        <div class="card-h"><div><h2>Desempenho do MariaDB</h2><p>A memória para dados evita leituras ao disco. Por omissão o MariaDB usa só 128 MB.</p></div></div>
        <form method="post" class="card-b" data-confirm="Aplicar? O MariaDB é reiniciado (os sites ficam alguns segundos sem base de dados). Se não arrancar, a configuração anterior é reposta sozinha.">
          <?= act_fields('db_tune') ?>
          <div class="fgrid">
            <label class="fld">Memória para dados (MB)<input class="in" name="bp" value="<?= h((string)($pg['db_bp'] ?? 'auto')) ?>" placeholder="auto"><small>auto = <?= (int)($pg['db_bp_auto'] ?? 128) ?> MB (servidor com <?= number_format((int)($pg['ram_mb'] ?? 0) / 1024, 1, ',', '') ?> GB de RAM)</small></label>
            <label class="fld">Registar consultas lentas<select class="in" name="slow"><option value="on"<?= !empty($pg['db_slow']) ? ' selected' : '' ?>>Sim</option><option value="off"<?= empty($pg['db_slow']) ? ' selected' : '' ?>>Não</option></select></label>
            <label class="fld">Consulta lenta a partir de (s)<input class="in" name="slow_t" inputmode="numeric" value="<?= (int)($pg['db_slow_t'] ?? 2) ?>"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Aplicar</button></div>
        </form>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Consultas mais lentas</h2><p>Agrupadas por forma (os valores trocados por N), ordenadas pelo tempo total. Atualizado de hora a hora<?= !empty($slow['ts']) ? ' · última vez às ' . h(gmdate('H:i', (int)$slow['ts'] + tz_off(live_stats()))) : '' ?>.</p></div>
          <form method="post"><?= act_fields('db_slow_report') ?><button class="btn sm sec" type="submit">Atualizar</button></form></div>
        <?php if (empty($slow['rows'])): ?><div class="empty">Sem consultas lentas registadas<?= empty($pg['db_slow']) ? ' (o registo está desligado)' : '' ?>.</div>
        <?php else: ?><div class="row-list"><?php foreach (array_slice($slow['rows'], 0, 10) as $q): ?>
          <div class="item"><div class="grow"><div class="mono pr-cmd" title="<?= h((string)$q['query']) ?>" style="max-width:100%"><?= h((string)$q['query']) ?></div>
            <div class="mu"><?= (int)$q['count'] ?>× · média <?= h(str_replace('.', ',', (string)$q['avg'])) ?> s · total <?= h(str_replace('.', ',', (string)$q['total'])) ?> s · <?= h((string)$q['user']) ?></div></div></div>
        <?php endforeach; ?></div><?php endif; ?>
      </section>
      </div>
      <section class="card">
        <div class="row-list">
          <div class="item">
            <span class="av t-acc"><?= ic('table') ?></span>
            <div class="grow"><div class="nm">phpMyAdmin</div><div class="mu"><?= $pmaOn ? 'Versão ' . h($pma['version'] ?? '') . '. Só abre com sessão iniciada neste painel; o login é feito com um utilizador da base de dados.' : 'Não está instalado. Instala a versão oficial mais recente.' ?></div></div>
            <div class="svc-acts">
              <?php if ($pmaOn): ?><a class="btn sm" href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('ext') ?>Abrir phpMyAdmin</a><?php endif; ?>
              <form method="post"><?= act_fields('pma_update') ?><button class="btn sm sec" type="submit"><?= ic('reload') ?><?= $pmaOn ? 'Procurar atualização' : 'Instalar' ?></button></form>
            </div>
          </div>
          <div class="item">
            <span class="av t-warn"><?= ic('shield') ?></span>
            <div class="grow"><div class="nm mono"><?= h($dbAdmin['user'] ?? 'mpadmin') ?>@localhost</div><div class="mu">Conta de administração com acesso a todas as bases de dados. Só funciona a partir do próprio servidor, por exemplo no phpMyAdmin.</div></div>
            <div class="svc-acts">
              <form method="post" data-confirm="<?= !empty($dbAdmin['exists']) ? h('Gerar uma nova password para a conta de administração? A password atual deixa de funcionar.') : '' ?>"><?= act_fields('db_admin_pw') ?><button class="btn sm sec" type="submit"><?= ic('key') ?><?= !empty($dbAdmin['exists']) ? 'Gerar nova password' : 'Criar conta' ?></button></form>
            </div>
          </div>
        </div>
      </section>

      <section class="card">
        <?php if (!$dbs): ?>
          <div class="empty"><b>Ainda não há bases de dados</b>Cada base de dados é criada com um utilizador próprio.<br><button class="btn" type="button" data-open="dlg-db-new"><?= ic('plus') ?>Nova base de dados</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Base de dados</th><th>Utilizador</th><th>Site</th><th class="r">Tamanho</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($dbs, 50); foreach ($pgList as $d): $n = (string)($d['name'] ?? ''); ?>
            <tr>
              <td class="first" data-label="Base de dados"><div class="who"><span class="av t-blue"><?= ic('db') ?></span><div class="nm mono"><?= h($n) ?></div></div></td>
              <td class="mono" data-label="Utilizador"><?= h($n) ?>@localhost</td>
              <td data-label="Site"><?= ($d['site'] ?? '') !== '' ? '<span class="pill p-me">' . h($d['site']) . '</span>' : '<span class="mu">—</span>' ?></td>
              <td class="r" data-label="Tamanho"><?= h(number_format((float)($d['size_mb'] ?? 0), 2, ',', ' ')) ?> MB</td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($pmaOn): ?><a href="/phpmyadmin/index.php?route=/database/structure&amp;db=<?= h(rawurlencode($n)) ?>" target="_blank" rel="noopener"><?= ic('table') ?>Abrir no phpMyAdmin</a><?php endif; ?>
                    <button type="button" data-open="dlg-dblink-<?= h($n) ?>"><?= ic('world') ?>Associar a um site</button>
                    <button type="button" data-open="dlg-dbpw-<?= h($n) ?>"><?= ic('key') ?>Mudar password</button>
                    <hr>
                    <button type="button" class="dan" data-open="dlg-dbdel-<?= h($n) ?>"><?= ic('trash') ?>Apagar</button>
                  </div>
                </details>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'bases de dados') ?></div><?php endif; ?>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'php'):
    $selV = qget('v') !== '' ? qget('v') : $defPhp;
    $sel = null;
    foreach ($phps as $p) { if ((string)($p['version'] ?? '') === $selV) $sel = $p; }
    if ($sel === null && $phps) $sel = $phps[0];
    $sv = $sel !== null ? (string)($sel['version'] ?? '') : '';
?>
      <?php $pg = is_array($state['perf'] ?? null) ? $state['perf'] : []; ?>
      <section class="card">
        <div class="card-h"><div><h2>OPcache</h2><p>Guarda o código PHP já compilado em memória, em todas as versões. Depois de atualizar um site por FTP, as alterações aparecem no máximo ao fim do tempo de verificação (ou de imediato com "Limpar OPcache").</p></div>
          <form method="post"><?= act_fields('opcache_reset') ?><button class="btn sm sec" type="submit">Limpar OPcache</button></form></div>
        <form method="post" class="card-b" style="display:flex;gap:14px;align-items:flex-end;flex-wrap:wrap">
          <?= act_fields('opcache_settings') ?>
          <label class="fld" style="min-width:220px">Memória<select class="in" name="mem"><option value="auto"<?= ($pg['opc_mem'] ?? 'auto') === 'auto' ? ' selected' : '' ?>>Automática (<?= (int)($pg['opc_mem_auto'] ?? 128) ?> MB)</option><?php foreach ([128, 256, 512, 1024] as $mb): ?><option value="<?= $mb ?>"<?= (string)($pg['opc_mem'] ?? '') === (string)$mb ? ' selected' : '' ?>><?= $mb ?> MB</option><?php endforeach; ?></select></label>
          <label class="fld" style="min-width:260px">Verificar alterações aos ficheiros<select class="in" name="reval"><?php foreach (['0' => 'Em cada pedido (mais lento)', '2' => 'A cada 2 segundos', '60' => 'A cada minuto (recomendado)', '300' => 'A cada 5 minutos'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)($pg['opc_reval'] ?? 60) === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?></select></label>
          <button class="btn" type="submit">Guardar</button>
        </form>
      </section>
      <section class="card">
        <div class="card-h"><h2>Versões instaladas</h2><p>Para acrescentar versões, volta a correr o instalador com --php.</p></div>
        <?php if (!$phps): ?>
          <div class="empty">Sem informação sobre versões de PHP.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Versão</th><th>Serviço</th><th class="r">Sites</th><th class="r">Extensões opcionais</th><th>Predefinida</th></tr></thead>
          <tbody>
          <?php foreach ($phps as $p): $v = (string)($p['version'] ?? '');
                $ni = count(array_filter(is_array($p['extensions'] ?? null) ? $p['extensions'] : [], function ($e) { return !empty($e['installed']); })); ?>
            <tr>
              <td class="first" data-label="Versão"><div class="who"><span class="av t-vio"><?= ic('code') ?></span><div><a class="nm" href="?p=php&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a><?php $sup = php_support($v); ?><div><span class="pill <?= $sup[1] ?>"><?= h($sup[0]) ?></span></div></div></div></td>
              <td data-label="Serviço"><span class="pill <?= !empty($p['active']) ? 'p-ok' : 'p-err' ?>"><?= !empty($p['active']) ? 'A correr' : 'Parado' ?></span></td>
              <td class="r" data-label="Sites"><?= (int)($bySite[$v] ?? 0) ?></td>
              <td class="r" data-label="Extensões opcionais"><?= $ni ?></td>
              <td data-label="Predefinida"><?= $v === $defPhp ? 'Sim' : 'Não' ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

      <?php if ($sel !== null):
            $exts = is_array($sel['extensions'] ?? null) ? $sel['extensions'] : [];
            $mods = is_array($sel['modules'] ?? null) ? $sel['modules'] : []; ?>
      <section class="card">
        <div class="card-h">
          <h2>Extensões do PHP <?= h($sv) ?></h2>
          <div class="pills"><?php foreach ($phps as $p): $v = (string)($p['version'] ?? ''); ?><a class="<?= $v === $sv ? 'on' : '' ?>" href="?p=php&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a><?php endforeach; ?></div>
        </div>
        <?php $ns = (int)($bySite[$sv] ?? 0); ?>
        <p class="lead">Aplicam-se a todos os sites com PHP <?= h($sv) ?> (<?= $ns ?> site<?= $ns === 1 ? '' : 's' ?>). Instalar ou remover pode demorar alguns minutos.</p>
        <?php if (!$exts): ?>
          <div class="empty">Sem informação sobre extensões.</div>
        <?php else: ?>
        <div class="exts">
          <?php foreach ($exts as $e): $x = (string)($e['name'] ?? ''); $inst = !empty($e['installed']); ?>
            <div class="ext<?= $inst ? ' on' : '' ?>">
              <div class="d"><b><?= h($x) ?></b><span><?= h($e['desc'] ?? '') ?></span></div>
              <form method="post"<?= $inst ? ' data-confirm="' . h('Remover a extensão ' . $x . ' do PHP ' . $sv . '?') . '"' : '' ?>>
                <?= act_fields($inst ? 'ext_del' : 'ext_add', ['php' => $sv, 'ext' => $x]) ?>
                <?php if ($inst): ?><span class="pill p-ok">Instalada</span><?php endif; ?>
                <button class="btn sm sec" type="submit"><?= $inst ? 'Remover' : 'Instalar' ?></button>
              </form>
            </div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
        <?php if ($mods): ?>
          <div class="card-f"><div class="mu" style="margin-bottom:8px">Módulos carregados (<?= count($mods) ?>)</div><div class="chips"><?php foreach ($mods as $m): ?><span class="chip"><?= h($m) ?></span><?php endforeach; ?></div></div>
        <?php endif; ?>
      </section>
      <?php endif; ?>

<?php elseif ($page === 'ligacoes'):
    $cj = jload(MP_STATS . '/conns.json') ?? [];
    $fw = jload(MP_STATS . '/fw.json') ?? [];
    $fwAuto = is_array($fw['auto'] ?? null) ? $fw['auto'] : ['on' => false, 'limit' => 150, 'duration' => 3600];
    $fwBlocks = array_values(array_filter(is_array($fw['blocks'] ?? null) ? $fw['blocks'] : [], function ($b) { return (int)($b['exp'] ?? 0) === 0 || (int)$b['exp'] > time(); }));
    $fwAllow = is_array($fw['allow'] ?? null) ? $fw['allow'] : [];
    $portLabels = [];
    foreach ($sites as $s) $portLabels[(string)(int)($s['port'] ?? 0)] = (string)($s['name'] ?? '');
    $portLabels[(string)(int)($sys['panel_port'] ?? 2443)] = 'Painel';
    $portLabels += ['22' => 'SSH', '3306' => 'MariaDB', '80' => 'HTTP', '443' => 'HTTPS', '25' => 'SMTP', '587' => 'SMTP', '465' => 'SMTPS', '993' => 'IMAPS', '995' => 'POP3S', '21' => 'FTP', '53' => 'DNS', '2096' => 'Webmail'];
    $durs = ['600s' => '10 minutos', '1h' => '1 hora', '24h' => '24 horas', '7d' => '7 dias'];
    $curDur = (int)($fwAuto['duration'] ?? 3600);
    $tzl = tz_off(live_stats());
    $geo = is_array($state['geo'] ?? null) ? $state['geo'] : ['block' => [], 'home' => 'PT', 'countries' => [], 'updated' => 0, 'ovl' => ['on' => true, 'capacity' => 0, 'start' => 80, 'stop' => 60, 'max' => 'auto']];
    $ovl = jload(MP_STATS . '/overload.json') ?? ['active' => false];
    $ltab = in_array(qget('t'), ['ativas', 'paises', 'bloqueios', 'protecao'], true) ? qget('t') : 'ativas';
    $allCc = array_values(array_filter((array)($geo['countries'] ?? []), function ($c) { return preg_match('/^[A-Z]{2}$/', $c); }));
    usort($allCc, function ($a, $b) { return strcoll(cc_name($a), cc_name($b)); });
?>
      <?php if (empty($fw['nft'])): ?>
        <div class="card"><div class="empty"><b>A firewall do painel não está ativa</b>No servidor: <span class="mono">mpanel fw-restore</span> (requer o pacote nftables).</div></div>
      <?php endif; ?>
      <?php if (!empty($ovl['active'])): ?>
        <div class="card ovl-on"><div class="card-b"><b><?= ic('ban') ?> Modo de proteção ativo</b> desde <?= h(gmdate('H:i', (int)($ovl['since'] ?? time()) + $tzl)) ?>: <?= (int)($ovl['total'] ?? 0) ?> ligações para uma capacidade de <?= (int)($ovl['capacity'] ?? 0) ?>. Só são aceites ligações novas de <?= cc_flag((string)($ovl['home'] ?? 'PT')) ?> <?= h(cc_name((string)($ovl['home'] ?? 'PT'))) ?>, da rede local e dos IPs de confiança.</div></div>
      <?php endif; ?>
      <nav class="tabs" aria-label="Secções">
        <?php foreach (['ativas' => 'Ligações ativas', 'paises' => 'Países', 'bloqueios' => 'Bloqueios (' . count($fwBlocks) . ')', 'protecao' => 'Proteção e limites'] as $tk => $tl): ?>
          <a class="chip<?= $ltab === $tk ? ' prim' : '' ?>" href="?p=ligacoes&amp;t=<?= $tk ?>"><?= h($tl) ?></a>
        <?php endforeach; ?>
      </nav>

  <?php if ($ltab === 'ativas' || $ltab === 'paises'): ?>
      <section class="stats" id="cn-stats">
        <div class="stat"><span class="tile t-acc"><?= ic('pulse') ?></span><div><div class="k">Ligações abertas</div><div class="v"><span data-c="total"><?= (int)($cj['total'] ?? 0) ?></span> <small>/ <?= (int)($geo['ovl']['capacity'] ?? 0) ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('world') ?></span><div><div class="k">IPs distintos</div><div class="v" data-c="distinct"><?= (int)($cj['distinct'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('reload') ?></span><div><div class="k">Em espera (SYN)</div><div class="v" data-c="syn"><?= (int)($cj['syn'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile <?= !empty($ovl['active']) ? 't-warn' : 't-vio' ?>"><?= ic('ban') ?></span><div><div class="k">Proteção</div><div class="v" style="font-size:17px"><?= !empty($ovl['active']) ? 'Ativa' : (!empty($geo['ovl']['on']) ? 'Em vigilância' : 'Desligada') ?></div></div></div>
      </section>
  <?php endif; ?>

  <?php if ($ltab === 'ativas'): ?>
      <section class="card" id="cn" data-mode="ip" data-me="<?= h($myIp) ?>" data-limit="<?= (int)$fwAuto['limit'] ?>" data-auto="<?= !empty($fwAuto['on']) ? 1 : 0 ?>"
        data-labels="<?= h((string)json_encode($portLabels)) ?>" data-allow="<?= h((string)json_encode(array_values($fwAllow))) ?>">
        <div class="card-h">
          <div><h2>Ligações por IP</h2><p>Atualiza a cada 5 segundos. Só ligações a serviços deste servidor.</p></div>
          <input class="in cn-search" id="cn-q" type="search" placeholder="Procurar IP ou país…" aria-label="Procurar" autocomplete="off">
        </div>
        <table class="list cards">
          <thead><tr><th>IP de origem</th><th>País</th><th class="r">Ligações</th><th>Destino</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody id="cn-rows"><tr><td colspan="5" class="empty">A carregar…</td></tr></tbody>
        </table>
        <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span class="mu" id="cn-foot" style="flex:1"></span><nav class="pager" id="cn-pager"></nav></div>
      </section>

  <?php elseif ($ltab === 'paises'): ?>
      <div class="grid2e">
      <section class="card" id="cn" data-mode="cc" data-home="<?= h((string)$geo['home']) ?>" data-blocked="<?= h((string)json_encode(array_values((array)$geo['block']))) ?>">
        <div class="card-h"><div><h2>Origem das ligações agora</h2><p>Por país, a partir dos IPs com ligações abertas. Atualiza a cada 5 segundos.</p></div></div>
        <div id="cc-rows" class="row-list"><div class="empty">A carregar…</div></div>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Países bloqueados</h2><p>Ligações novas destes países são recusadas em todas as portas. As respostas às ligações feitas pelo próprio servidor continuam a passar.</p></div></div>
        <?php if (!$geo['block']): ?><div class="empty">Nenhum país bloqueado.</div>
        <?php else: ?><div class="row-list">
          <?php foreach ((array)$geo['block'] as $cc): ?><div class="item"><span class="cc-flag"><?= cc_flag((string)$cc) ?></span><div class="grow"><div class="nm"><?= h(cc_name((string)$cc)) ?></div><div class="mu mono"><?= h($cc) ?></div></div>
            <form method="post"><?= act_fields('geo_block', ['op' => 'del', 'cc' => (string)$cc]) ?><button class="btn sm sec" type="submit">Desbloquear</button></form></div><?php endforeach; ?>
        </div><?php endif; ?>
        <form method="post" class="card-b" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap" data-confirm="Bloquear este país? Visitantes, robôs de pesquisa e serviços desse país deixam de chegar aos sites e ao email.">
          <?= act_fields('geo_block', ['op' => 'add']) ?>
          <label class="fld" style="flex:1;min-width:220px">País<select class="in" name="cc" required><option value="">— escolher —</option>
            <?php foreach ($allCc as $cc): if ($cc === ($geo['home'] ?? 'PT') || in_array($cc, (array)$geo['block'], true)) continue; ?><option value="<?= h($cc) ?>"><?= cc_flag($cc) ?> <?= h(cc_name($cc)) ?></option><?php endforeach; ?>
          </select></label>
          <button class="btn dan" type="submit">Bloquear país</button>
        </form>
        <div class="card-f"><div class="warnbox">Cuidado: bloquear países pode impedir a renovação de certificados (o Let's Encrypt valida a partir de vários países, incluindo os EUA), os robôs de pesquisa (Google, Bing) e as notificações de pagamentos (MB Way, Stripe, PayPal…) vindas desses países.</div>
          <p class="mu" style="margin:10px 0 0;font-size:12px">Geolocalização por <a href="https://db-ip.com" target="_blank" rel="noopener">DB-IP</a> (CC BY 4.0) · base de <?= !empty($geo['updated']) ? h(gmdate('m/Y', (int)$geo['updated'])) : '—' ?>, atualizada todos os meses<?php if (empty($geo['updated'])): ?> · <form method="post" style="display:inline"><?= act_fields('geoip_update') ?><button class="lnk" type="submit" style="display:inline">descarregar agora</button></form><?php endif; ?></p></div>
      </section>
      </div>

  <?php elseif ($ltab === 'bloqueios'): [$bl, $bpg, $bpages, $btot] = paginate($fwBlocks, 50); ?>
      <section class="card">
        <div class="card-h"><div><h2>IPs e gamas bloqueados</h2><p>Bloqueados em todas as portas, incluindo SSH. Aceita um IP (185.220.101.47) ou uma gama (45.148.10.0/24).</p></div><button class="chip sm soft" type="button" data-open="dlg-block">Bloquear IP ou gama</button></div>
        <?php if (!$fwBlocks): ?>
          <div class="empty">Nenhum IP bloqueado.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>IP / gama</th><th>País</th><th>Origem</th><th>Motivo</th><th>Expira</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($bl as $b): $exp = (int)($b['exp'] ?? 0); $left = $exp - time(); $bip = (string)($b['ip'] ?? ''); $bcc = geo_cc(explode('/', $bip)[0]); ?>
            <tr>
              <td class="first" data-label="IP"><div class="nm mono"><?= h($bip) ?></div></td>
              <td data-label="País"><span class="cc-flag"><?= cc_flag($bcc) ?></span> <?= h(cc_name($bcc)) ?></td>
              <td data-label="Origem"><span class="pill <?= ($b['by'] ?? '') === 'auto' ? 'p-err' : 'p-off' ?>"><?= ($b['by'] ?? '') === 'auto' ? 'Automático' : 'Manual' ?></span></td>
              <td data-label="Motivo" class="mu"><?= h(($b['reason'] ?? '') !== '' ? $b['reason'] : '—') ?></td>
              <td data-label="Expira"><?= $exp === 0 ? 'Permanente' : 'em ' . h($left >= 86400 ? round($left / 86400) . ' d' : ($left >= 3600 ? round($left / 3600) . ' h' : max(1, (int)round($left / 60)) . ' min')) ?></td>
              <td class="act r"><form method="post" style="margin:0"><?= act_fields('fw_unblock', ['ip' => $bip]) ?><button class="btn sm sec" type="submit">Desbloquear</button></form></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <div class="card-f"><?= pager($bpg, $bpages, $btot, 'pg', 'bloqueios') ?></div>
        <?php endif; ?>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>IPs de confiança</h2><p>Nunca são bloqueados (nem por IP, nem por país, nem pelo modo de proteção).</p></div></div>
        <?php if ($fwAllow): ?>
        <div class="row-list">
          <?php foreach ($fwAllow as $a): ?>
            <div class="item"><span class="grow mono"><?= h($a) ?></span><form method="post" style="margin:0"><?= act_fields('fw_allow_del', ['ip' => (string)$a]) ?><button class="btn sm sec" type="submit">Remover</button></form></div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
        <form method="post" class="card-b" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap">
          <?= act_fields('fw_allow_add') ?>
          <label class="fld" style="flex:1;min-width:200px">IP ou gama<input class="in mono" name="ip" required placeholder="ex.: <?= h($myIp !== '' ? $myIp : '89.155.0.10') ?>" autocomplete="off"></label>
          <button class="btn sec" type="submit">Adicionar</button>
        </form>
      </section>

  <?php else: $go = (array)($geo['ovl'] ?? []); ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Limite de ligações</h2><p>Ao chegar ao limite, o servidor deixa de aceitar ligações novas de fora do seu país, mantendo sempre margem para os visitantes nacionais.</p></div>
          <span class="pill <?= !empty($ovl['active']) ? 'p-err' : (!empty($go['on']) ? 'p-ok' : 'p-off') ?>"><?= !empty($ovl['active']) ? 'Proteção ativa' : (!empty($go['on']) ? 'Em vigilância' : 'Desligado') ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('overload_settings') ?>
          <div class="fgrid">
            <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($go['on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($go['on']) ? ' selected' : '' ?>>Desligado</option></select></label>
            <label class="fld">País do servidor (sempre aceite)<select class="in" name="home"><?php foreach ($allCc ?: ['PT'] as $cc): ?><option value="<?= h($cc) ?>"<?= $cc === ($geo['home'] ?? 'PT') ? ' selected' : '' ?>><?= cc_flag($cc) ?> <?= h(cc_name($cc)) ?></option><?php endforeach; ?></select></label>
            <label class="fld">Capacidade (ligações simultâneas)<input class="in" name="max" value="<?= h((string)($go['max'] ?? 'auto')) ?>" placeholder="auto"><small>auto = calculada pelo nginx: <?= (int)($go['capacity'] ?? 0) ?></small></label>
            <div class="fgrid" style="grid-template-columns:1fr 1fr">
              <label class="fld">Entrada (%)<input class="in" name="start" inputmode="numeric" pattern="[0-9]{1,2}" value="<?= (int)($go['start'] ?? 80) ?>"></label>
              <label class="fld">Saída (%)<input class="in" name="stop" inputmode="numeric" pattern="[0-9]{1,2}" value="<?= (int)($go['stop'] ?? 60) ?>"></label>
            </div>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Agora: <?= (int)($ovl['total'] ?? ($cj['total'] ?? 0)) ?> ligações. No modo de proteção continuam sempre aceites: o país do servidor, a rede local, os IPs de confiança, os IPs de onde usaste o painel nos últimos 7 dias e o DNS. Sai do modo quando a carga fica abaixo do limite de saída durante 2 minutos. Cada mudança fica na auditoria.</div>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Bloqueio automático por IP</h2><p>Bloqueia IPs com demasiadas ligações abertas em simultâneo.</p></div><span class="pill <?= !empty($fwAuto['on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($fwAuto['on']) ? 'Ativo' : 'Desativado' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('fw_auto') ?>
          <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr))">
            <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($fwAuto['on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($fwAuto['on']) ? ' selected' : '' ?>>Desativado</option></select></label>
            <label class="fld">Limite por IP<input class="in" name="limit" inputmode="numeric" pattern="[0-9]{2,6}" required value="<?= (int)$fwAuto['limit'] ?>"></label>
            <label class="fld">Duração<select class="in" name="dur"><?php foreach ($durs as $dk => $dl): $ds = (int)fw_secs_php($dk); ?><option value="<?= h($dk) ?>"<?= $ds === $curDur ? ' selected' : '' ?>><?= h($dl) ?></option><?php endforeach; ?></select></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Nunca são bloqueados: este servidor, os IPs de confiança e os IPs de onde usaste o painel nos últimos 7 dias.</div>
      </section>
      </div>
  <?php endif; ?>

      <dialog id="dlg-block">
        <form method="post">
          <?= act_fields('fw_block') ?>
          <div class="dlg-h"><h3>Bloquear IP ou gama</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">IP ou gama<input class="in mono" name="ip" id="blk-ip" required placeholder="ex.: 185.220.101.47 ou 45.148.10.0/24" autocomplete="off"></label>
            <div class="fgrid">
              <label class="fld">Duração<select class="in" name="dur"><option value="1h">1 hora</option><option value="24h" selected>24 horas</option><option value="7d">7 dias</option><option value="perm">Permanente</option></select></label>
              <label class="fld">Motivo (opcional)<input class="in" name="reason" maxlength="80" autocomplete="off"></label>
            </div>
            <div class="warnbox">Fica bloqueado em todas as portas, incluindo SSH, e as ligações abertas são cortadas de imediato.</div>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Bloquear</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'cron'):
    $crons = is_array($state['crons'] ?? null) ? $state['crons'] : [];
    $cr = jload(MP_STATS . '/crons.json') ?? [];
    $runs = is_array($cr['runs'] ?? null) ? $cr['runs'] : [];
    $fSite = qget('site');
    if ($fSite !== '') $crons = array_values(array_filter($crons, function ($c) use ($fSite) { return ($c['site'] ?? '') === $fSite; }));
    $sitePorts = [];
    foreach ($sites as $s) $sitePorts[(string)$s['name']] = (int)$s['port'];
    $tzc = tz_off(live_stats());
?>
      <section class="card">
        <div class="card-h">
          <div><h2>Tarefas agendadas</h2><p>Cada tarefa corre com o utilizador do seu site. A saída fica guardada e não há sobreposição de execuções.</p></div>
          <?php if ($sites): ?>
          <form method="get" style="margin:0"><input type="hidden" name="p" value="cron">
            <select class="in" name="site" onchange="this.form.submit()" aria-label="Filtrar por site" style="height:40px;min-width:180px">
              <option value="">Todos os sites</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>"<?= $sn === $fSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
            </select>
          </form>
          <?php endif; ?>
        </div>
        <?php if (!$sites): ?>
          <div class="empty"><b>Ainda não há sites</b>As tarefas agendadas pertencem a um site.</div>
        <?php elseif (!$crons): ?>
          <div class="empty"><b>Sem tarefas agendadas<?= $fSite !== '' ? ' neste site' : '' ?></b>Cria uma tarefa para correr um script PHP, chamar um URL ou executar um comando.<br><button class="btn" type="button" data-cron-new><?= ic('plus') ?>Nova tarefa</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Tarefa</th><th>Quando</th><th>Última execução</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($crons, 50); foreach ($pgList as $c):
                $cid = (string)($c['id'] ?? ''); $cs = (string)($c['site'] ?? ''); $on = !empty($c['on']);
                $run = $runs[$cs . ':' . $cid] ?? null; $rc = $run['rc'] ?? null; ?>
            <tr>
              <td class="first" data-label="Tarefa">
                <div class="who"><span class="av <?= tone($cs) ?>"><?= ic('clock') ?></span><div style="min-width:0">
                  <div class="nm"><?= h(($c['desc'] ?? '') !== '' ? $c['desc'] : $cs) ?></div>
                  <div class="mu mono cron-cmd" title="<?= h($c['cmd'] ?? '') ?>"><?= h($c['cmd'] ?? '') ?></div>
                </div></div>
              </td>
              <td data-label="Quando" class="cron-when"><div><?= h(cron_human((string)($c['when'] ?? ''))) ?></div><div class="mu"><span class="mono"><?= h($c['when'] ?? '') ?></span> · <?= h($cs) ?></div></td>
              <td data-label="Última execução" class="cron-when">
                <?php if ($run === null): ?><span class="mu">Ainda não correu</span>
                <?php elseif ($rc === 'running'): ?><span class="pill p-me">A correr</span> <span class="mu"><?= h(ago((int)$run['start'], time())) ?></span>
                <?php else: ?><span class="pill <?= $rc === '0' ? 'p-ok' : 'p-err' ?>"><?= $rc === '0' ? 'Sucesso' : 'Erro ' . h($rc) ?></span> <span class="mu"><?= h(ago((int)$run['end'], time())) ?> · <?= max(0, (int)$run['end'] - (int)$run['start']) ?> s</span><?php endif; ?>
              </td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativa' : 'Em pausa' ?></span></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações da tarefa"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <form method="post"><?= act_fields('cron_run', ['site' => $cs, 'id' => $cid]) ?><button type="submit"><?= ic('play') ?>Executar agora</button></form>
                    <button type="button" data-open="dlg-cronlog-<?= h($cid) ?>"><?= ic('file') ?>Ver saída</button>
                    <button type="button" data-cron-edit="<?= h((string)json_encode(['site' => $cs, 'id' => $cid, 'when' => $c['when'] ?? '', 'cmd' => $c['cmd'] ?? '', 'desc' => $c['desc'] ?? ''])) ?>"><?= ic('edit') ?>Editar</button>
                    <form method="post"><?= act_fields($on ? 'cron_off' : 'cron_on', ['site' => $cs, 'id' => $cid]) ?><button type="submit"><?= ic('toggle') ?><?= $on ? 'Pôr em pausa' : 'Ativar' ?></button></form>
                    <hr>
                    <form method="post" data-confirm="Apagar esta tarefa agendada?"><?= act_fields('cron_del', ['site' => $cs, 'id' => $cid]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div>
                </details>
                <dialog id="dlg-cronlog-<?= h($cid) ?>" style="width:min(820px,calc(100vw - 24px))">
                  <div class="dlg-h"><div style="min-width:0"><h3>Saída da última execução</h3><p class="mono cron-cmd"><?= h($c['cmd'] ?? '') ?></p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <pre class="cron-out"><?= $run !== null && ($run['tail'] ?? '') !== '' ? h($run['tail']) : 'Ainda não há saída registada.' ?></pre>
                  <div class="dlg-f"><span class="mu" style="margin-right:auto">Registo completo: /srv/www/<?= h($cs) ?>/logs/cron-<?= h($cid) ?>.log</span><button class="btn sec" type="button" data-close>Fechar</button></div>
                </dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'tarefas') ?></div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">Dentro do comando, <span class="mono">php</span> usa a versão de PHP do site. O comando arranca na pasta public_html do site. A saída fica em logs/cron-&lt;id&gt;.log e o resultado é atualizado a cada minuto.</div>
      </section>

      <dialog class="drawer" id="dlg-cron" aria-labelledby="t-cron">
        <form method="post" id="cron-form">
          <?= act_fields('cron_save') ?>
          <input type="hidden" name="id" id="cron-id">
          <div class="dlg-h"><div><h3 id="t-cron">Nova tarefa agendada</h3><p>Como no cPanel: periodicidade e comando.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">Site<select class="in" name="site" id="cron-site">
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>" data-port="<?= (int)$s['port'] ?>"<?= $sn === $fSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
            </select></label>
            <label class="fld">Definições comuns<select class="in" id="cron-preset">
              <option value="">— escolher —</option>
              <option value="* * * * *">A cada minuto</option>
              <option value="*/5 * * * *">A cada 5 minutos</option>
              <option value="*/15 * * * *">A cada 15 minutos</option>
              <option value="*/30 * * * *">A cada 30 minutos</option>
              <option value="0 * * * *">De hora a hora</option>
              <option value="0 */6 * * *">A cada 6 horas</option>
              <option value="0 3 * * *">Uma vez por dia (03:00)</option>
              <option value="0 3 * * 0">Uma vez por semana (domingo, 03:00)</option>
              <option value="0 3 1 * *">Uma vez por mês (dia 1, 03:00)</option>
            </select></label>
            <div class="cron-fields">
              <label class="fld">Minuto<input class="in mono" id="cf-0" value="*/5" autocomplete="off"></label>
              <label class="fld">Hora<input class="in mono" id="cf-1" value="*" autocomplete="off"></label>
              <label class="fld">Dia<input class="in mono" id="cf-2" value="*" autocomplete="off"></label>
              <label class="fld">Mês<input class="in mono" id="cf-3" value="*" autocomplete="off"></label>
              <label class="fld">Semana<input class="in mono" id="cf-4" value="*" autocomplete="off"></label>
            </div>
            <div class="mu" style="margin-top:-8px;font-size:12px">Minuto 0–59 · hora 0–23 · dia 1–31 · mês 1–12 · dia da semana 0–6 (0 = domingo). Aceita *, listas (1,15), intervalos (8-20) e passos (*/10).</div>
            <input type="hidden" name="when" id="cron-when">
            <div class="cron-human" id="cron-human"></div>
            <label class="fld">Comando<textarea class="in mono cron-ta" name="cmd" id="cron-cmd" rows="3" required maxlength="2000" spellcheck="false" placeholder="php /srv/www/loja/public_html/cron.php"></textarea></label>
            <div class="cron-help">
              <span class="mu">Inserir:</span>
              <button class="chip sm" type="button" data-ins="php">Script PHP</button>
              <button class="chip sm" type="button" data-ins="url">Chamar URL do site</button>
              <button class="chip sm" type="button" data-ins="quiet">Sem saída</button>
            </div>
            <label class="fld">Descrição (opcional)<input class="in" name="desc" id="cron-desc" maxlength="80" placeholder="ex.: Cron do PrestaShop" autocomplete="off"></label>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit" id="cron-submit">Criar tarefa</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'backups'):
    $bk = jload(MP_STATS . '/backup.json') ?? [];
    $bkRun = jload(MP_STATS . '/backup-run.json');
    $bkConf = is_array($bk['conf'] ?? null) ? $bk['conf'] : ['enabled' => true, 'time' => '03:00', 'keep_daily' => 7, 'keep_weekly' => 4, 'keep_monthly' => 3, 'remote' => ''];
    $bkSets = is_array($bk['sets'] ?? null) ? $bk['sets'] : [];
    $bkRem = is_array($bk['remotes'] ?? null) ? $bk['remotes'] : [];
    $bkLast = is_array($bk['last'] ?? null) ? $bk['last'] : null;
    $tzb = tz_off(live_stats());
    $fSet = qget('set');
    if ($fSet !== '') $bkSets = array_values(array_filter($bkSets, function ($x) use ($fSet) { return ($x['site'] ?? '') === $fSet; }));
    $setName = function (string $s): string { return $s === '_bd' ? 'Bases de dados sem site' : ($s === '_sistema' ? 'Configuração do sistema' : $s); };
    $typeName = ['auto' => ['Automático', 'p-off'], 'manual' => ['Manual', 'p-me'], 'pre-restauro' => ['Antes de repor', 'p-err']];
    $next = '';
    if (!empty($bkConf['enabled'])) {
        [$hh, $mm] = array_map('intval', explode(':', (string)$bkConf['time'] . ':0'));
        $loc = time() + $tzb; $today = intdiv($loc, 86400) * 86400 + $hh * 3600 + $mm * 60;
        $next = gmdate('d/m H:i', $today > $loc ? $today : $today + 86400);
    }
?>
      <?php if ($bkRun): ?>
        <div class="card bk-run" data-bk-running><div class="row-list"><div class="item"><span class="spin"></span><div class="grow"><div class="nm">Backup em curso</div><div class="mu"><?= h($bkRun['step'] ?? '') ?> · desde há <?= max(1, (int)ceil((time() - (int)($bkRun['since'] ?? time())) / 60)) ?> min</div></div><span class="mu">A página atualiza sozinha.</span></div></div></div>
      <?php endif; ?>
<?php $btab = in_array(qget('t'), ['copias', 'config'], true) ? qget('t') : 'copias'; ?>
      <nav class="tabs" aria-label="Secções"><a class="chip<?= $btab === 'copias' ? ' prim' : '' ?>" href="?p=backups&amp;t=copias">Cópias</a><a class="chip<?= $btab === 'config' ? ' prim' : '' ?>" href="?p=backups&amp;t=config">Agendamento e destinos</a></nav>
<?php if ($btab === 'copias'): ?>
      <section class="stats">
        <div class="stat"><span class="tile <?= $bkLast && empty($bkLast['ok']) ? 't-warn' : 't-acc' ?>"><?= ic('archive') ?></span><div><div class="k">Último backup</div><div class="v"><?= $bkLast ? (empty($bkLast['ok']) ? 'Com erros' : 'Sucesso') : '—' ?> <small><?= $bkLast ? h(ago((int)$bkLast['ts'], time())) : 'ainda não houve' ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('clock') ?></span><div><div class="k">Próximo automático</div><div class="v"><?= $next !== '' ? h($next) : 'Desativado' ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('db') ?></span><div><div class="k">Espaço ocupado (local)</div><div class="v"><?= h(fmt_bytes((float)($bk['total'] ?? 0))) ?> <small><?= count($bk['sets'] ?? []) ?> backups</small></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('upload') ?></span><div><div class="k">Cópia remota</div><div class="v"><?= ($bkConf['remote'] ?? '') !== '' ? h($bkConf['remote']) : 'Só local' ?></div></div></div>
      </section>
      <?php if ($bkLast && empty($bkLast['ok'])): ?><div class="card"><div class="card-b" style="color:var(--err)"><?= h($bkLast['msg'] ?? '') ?></div></div><?php endif; ?>

      <section class="card">
        <div class="card-h">
          <div><h2>Backups guardados</h2><p>Cada backup de um site inclui os ficheiros, as bases de dados associadas e as tarefas agendadas.</p></div>
          <form method="get" style="margin:0"><input type="hidden" name="p" value="backups">
            <select class="in" name="set" onchange="this.form.submit()" aria-label="Filtrar" style="height:40px;min-width:200px">
              <option value="">Todos</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>"<?= $sn === $fSet ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
              <option value="_bd"<?= $fSet === '_bd' ? ' selected' : '' ?>>Bases de dados sem site</option>
              <option value="_sistema"<?= $fSet === '_sistema' ? ' selected' : '' ?>>Configuração do sistema</option>
            </select>
          </form>
        </div>
        <?php if (!$bkSets): ?>
          <div class="empty"><b>Ainda não há backups<?= $fSet !== '' ? ' deste conjunto' : '' ?></b>Faz o primeiro agora ou espera pelo backup automático.<br><button class="btn" type="button" data-open="dlg-bk-now"><?= ic('archive') ?>Fazer backup agora</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Conjunto</th><th>Data</th><th>Tipo</th><th>Conteúdo</th><th class="r">Tamanho</th><th>Remoto</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($bkSets, 30); foreach ($pgList as $i => $b): $bs = (string)($b['site'] ?? ''); $bid = (string)($b['id'] ?? ''); $tn = $typeName[$b['type'] ?? 'manual'] ?? ['Manual', 'p-me'];
                $dbl = is_array($b['dbs'] ?? null) ? $b['dbs'] : []; $did = 'bk' . $i; ?>
            <tr>
              <td class="first" data-label="Conjunto"><div class="who"><span class="av <?= $bs[0] === '_' ? 't-vio' : tone($bs) ?>"><?= $bs[0] === '_' ? ic($bs === '_bd' ? 'db' : 'server') : h(substr($bs, 0, 1)) ?></span><div class="nm"><?= h($setName($bs)) ?></div></div></td>
              <td data-label="Data"><?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzb)) ?></td>
              <td data-label="Tipo"><span class="pill <?= $tn[1] ?>"><?= $tn[0] ?></span></td>
              <td data-label="Conteúdo" class="mu"><?= h(implode(' + ', array_filter([!empty($b['files']) ? ($bs === '_sistema' ? 'Configuração' : 'Ficheiros') : '', $dbl ? count($dbl) . ' BD' : '']))) ?: '—' ?></td>
              <td class="r" data-label="Tamanho"><?= h(fmt_bytes((float)($b['size'] ?? 0))) ?></td>
              <td data-label="Remoto"><?= ($b['remote'] ?? '') !== '' ? '<span class="pill p-ok">' . h($b['remote']) . '</span>' : '<span class="mu">—</span>' ?></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações do backup"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($bs !== '_sistema'): ?><button type="button" data-open="dlg-rs-<?= $did ?>"><?= ic('reload') ?>Repor…</button><?php endif; ?>
                    <?php if (!empty($b['files'])): $ff = $bs === '_sistema' ? 'sistema.tar.gz' : 'ficheiros.tar.gz'; ?><a href="?bk=dl&amp;s=<?= h(rawurlencode($bs)) ?>&amp;id=<?= h($bid) ?>&amp;f=<?= $ff ?>"><?= ic('download') ?>Descarregar <?= $bs === '_sistema' ? 'configuração' : 'ficheiros' ?></a><?php endif; ?>
                    <?php foreach ($dbl as $d): ?><a href="?bk=dl&amp;s=<?= h(rawurlencode($bs)) ?>&amp;id=<?= h($bid) ?>&amp;f=bd-<?= h(rawurlencode((string)$d)) ?>.sql.gz"><?= ic('download') ?>Descarregar BD <?= h($d) ?></a><?php endforeach; ?>
                    <hr>
                    <form method="post" data-confirm="Apagar este backup (cópia local)?"><?= act_fields('bk_del', ['s' => $bs, 'id' => $bid]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div>
                </details>
                <?php if ($bs !== '_sistema'): ?>
                <dialog id="dlg-rs-<?= $did ?>">
                  <form method="post">
                    <?= act_fields('bk_restore', ['s' => $bs, 'id' => $bid]) ?>
                    <div class="dlg-h"><h3>Repor <?= h($setName($bs)) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                    <div class="dlg-b">
                      <p class="mu" style="margin:0">Backup de <?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzb)) ?>.</p>
                      <?php if ($bs !== '_bd'): ?>
                      <label class="chk"><input type="radio" name="what" value="all" checked> Tudo: ficheiros, bases de dados e tarefas agendadas</label>
                      <label class="chk"><input type="radio" name="what" value="files"> Só os ficheiros (public_html)</label>
                      <?php if ($dbl): ?><label class="chk"><input type="radio" name="what" value="db"> Só as bases de dados (<?= h(implode(', ', $dbl)) ?>)</label><?php endif; ?>
                      <?php else: ?><input type="hidden" name="what" value="db"><p style="margin:0">Repõe as bases de dados: <?= h(implode(', ', $dbl)) ?>.</p><?php endif; ?>
                      <div class="warnbox">O conteúdo atual é substituído. Antes de repor é feito automaticamente um backup do estado atual ("Antes de repor"), para poderes voltar atrás.</div>
                      <label class="chk"><input type="checkbox" name="ok" value="1" required> Compreendo que o conteúdo atual vai ser substituído</label>
                    </div>
                    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Repor backup</button></div>
                  </form>
                </dialog>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'backups') ?></div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">Local: /var/backups/minipainel. As bases de dados só entram no backup de um site se estiverem associadas a ele (página Bases de dados); as restantes vão para "Bases de dados sem site".</div>
      </section>

<?php endif; if ($btab === 'config'): ?>
      <div class="grid2e">
        <section class="card">
          <div class="card-h"><div><h2>Agendamento e retenção</h2><p>Backup automático diário de todos os sites e bases de dados.</p></div><span class="pill <?= !empty($bkConf['enabled']) ? 'p-ok' : 'p-off' ?>"><?= !empty($bkConf['enabled']) ? 'Ativo' : 'Desativado' ?></span></div>
          <form method="post" class="card-b">
            <?= act_fields('bk_conf') ?>
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($bkConf['enabled']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($bkConf['enabled']) ? ' selected' : '' ?>>Desativado</option></select></label>
              <label class="fld">Hora<input class="in" type="time" name="time" required value="<?= h($bkConf['time'] ?? '03:00') ?>"></label>
            </div>
            <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr));margin-top:14px">
              <label class="fld">Diários<input class="in" name="daily" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_daily'] ?>"></label>
              <label class="fld">Semanais<input class="in" name="weekly" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_weekly'] ?>"></label>
              <label class="fld">Mensais<input class="in" name="monthly" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_monthly'] ?>"></label>
            </div>
            <label class="fld" style="margin-top:14px">Cifrar as cópias remotas<select class="in" name="encrypt"><option value="on"<?= ($bkConf['encrypt'] ?? true) ? ' selected' : '' ?>>Sim (AES-256, recomendado)</option><option value="off"<?= ($bkConf['encrypt'] ?? true) ? '' : ' selected' ?>>Não</option></select><small>O destino remoto só vê ficheiros cifrados; a chave fica neste servidor</small></label>
            <label class="fld" style="margin-top:14px">Cópia remota<select class="in" name="remote"><option value="none">Só local</option><?php foreach ($bkRem as $r): ?><option value="<?= h($r['name']) ?>"<?= ($bkConf['remote'] ?? '') === $r['name'] ? ' selected' : '' ?>><?= h($r['name']) ?> (<?= h($r['type']) ?>)</option><?php endforeach; ?></select></label>
            <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
          </form>
          <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span class="mu" style="flex:1;min-width:220px">Guarda a <b>chave dos backups</b> fora deste servidor: é precisa para repor cópias remotas noutro servidor.</span><button class="btn sm sec" type="button" data-open="dlg-bk-key"><?= ic('key') ?>Mostrar chave</button></div>
          <dialog id="dlg-bk-key"><form method="post"><?= act_fields('bk_key_show') ?>
            <div class="dlg-h"><h3>Chave dos backups</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
            <div class="dlg-b"><label class="fld">Confirma com a password do painel<input class="in" type="password" name="atual" required autocomplete="current-password"></label><p class="mu" style="margin:0">A chave aparece numa notificação; copia-a para um gestor de passwords.</p></div>
            <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mostrar</button></div>
          </form></dialog>
          <div class="card-f mu">A retenção aplica-se ao local e ao remoto: por exemplo, 7 diários, 4 semanais e 3 mensais cobrem cerca de 3 meses. Os backups manuais ficam até os apagares. Se o disco passar de 90%, o backup é cancelado e o erro aparece aqui.</div>
        </section>

        <section class="card">
          <div class="card-h"><div><h2>Destinos remotos</h2><p>SFTP, S3 (Backblaze, Wasabi, MinIO, AWS…) ou qualquer destino do rclone.</p></div><button class="chip sm soft" type="button" data-open="dlg-bk-remote">Adicionar destino</button></div>
          <?php if (!$bkRem): ?>
            <div class="empty">Sem destinos remotos. Os backups ficam só neste servidor.</div>
          <?php else: ?>
          <div class="row-list">
            <?php foreach ($bkRem as $r): ?>
              <div class="item">
                <span class="av t-blue"><?= ic('upload') ?></span>
                <div class="grow"><div class="nm"><?= h($r['name']) ?> <span class="pill p-off"><?= h(strtoupper((string)$r['type'])) ?></span></div><div class="mu mono"><?= h($r['root']) ?>/<?= h($sys['hostname'] ?? 'servidor') ?>/…</div></div>
                <div class="svc-acts">
                  <form method="post"><?= act_fields('bk_remote_test', ['name' => (string)$r['name']]) ?><button class="btn sm sec" type="submit">Testar</button></form>
                  <form method="post" data-confirm="Remover o destino <?= h($r['name']) ?>? Os backups já enviados não são apagados."><?= act_fields('bk_remote_del', ['name' => (string)$r['name']]) ?><button class="btn sm sec" type="submit">Remover</button></form>
                </div>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
        </section>
      </div>

<?php endif; ?>
      <dialog id="dlg-bk-now">
        <form method="post">
          <?= act_fields('bk_now') ?>
          <div class="dlg-h"><h3>Fazer backup agora</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">O que guardar<select class="in" name="target">
              <option value="all">Tudo (todos os sites, bases de dados e configuração)</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>">Site <?= h($sn) ?></option><?php endforeach; ?>
              <option value="_bd">Bases de dados sem site</option>
              <option value="_sistema">Configuração do sistema</option>
            </select></label>
            <?php if ($bkRem): ?>
            <label class="fld">Enviar também para<select class="in" name="remote"><option value="">Não enviar (só local)</option><?php foreach ($bkRem as $r): ?><option value="<?= h($r['name']) ?>"<?= ($bkConf['remote'] ?? '') === $r['name'] ? ' selected' : '' ?>><?= h($r['name']) ?></option><?php endforeach; ?></select></label>
            <?php endif; ?>
            <p class="mu" style="margin:0">Corre em segundo plano; podes continuar a usar o painel. Os backups manuais não são apagados pela retenção.</p>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Iniciar backup</button></div>
        </form>
      </dialog>

      <dialog class="drawer" id="dlg-bk-remote">
        <form method="post" autocomplete="off">
          <?= act_fields('bk_remote_add') ?>
          <div class="dlg-h"><div><h3>Adicionar destino remoto</h3><p>As credenciais ficam só neste servidor (/etc/minipainel, acesso root).</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <div class="fgrid">
              <label class="fld">Nome<input class="in" name="name" required pattern="[a-z][a-z0-9\-]{1,23}" placeholder="ex.: storagebox"></label>
              <label class="fld">Tipo<select class="in" name="type" id="rm-type"><option value="sftp">SFTP</option><option value="s3">S3 compatível</option><option value="rclone">Outro (configuração rclone)</option></select></label>
            </div>
            <div data-rm="sftp" class="rm-grp">
              <div class="fgrid">
                <label class="fld">Servidor<input class="in" name="host" placeholder="backup.exemplo.pt"></label>
                <label class="fld">Porta<input class="in" name="port" value="22" inputmode="numeric"></label>
                <label class="fld">Utilizador<input class="in" name="user"></label>
                <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="new-password"><small>Ou usa uma chave privada abaixo</small></label>
              </div>
              <label class="fld">Chave privada (opcional)<textarea class="in mono cron-ta" name="key" rows="3" placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"></textarea></label>
              <label class="fld">Pasta no servidor<input class="in mono" name="path_sftp" value="backups"></label>
            </div>
            <div data-rm="s3" class="rm-grp" hidden>
              <div class="fgrid">
                <label class="fld">Fornecedor<select class="in" name="provider"><option value="Other">Outro / MinIO / Backblaze B2 (S3)</option><option value="Wasabi">Wasabi</option><option value="AWS">Amazon S3</option><option value="Cloudflare">Cloudflare R2</option><option value="DigitalOcean">DigitalOcean Spaces</option></select></label>
                <label class="fld">Região<input class="in" name="region" placeholder="eu-central-1"></label>
              </div>
              <label class="fld">Endpoint<input class="in mono" name="endpoint" placeholder="s3.eu-central-003.backblazeb2.com"><small>Vazio para Amazon S3</small></label>
              <div class="fgrid">
                <label class="fld">Chave de acesso<input class="in mono" name="access"></label>
                <label class="fld">Chave secreta<input class="in mono" type="password" name="secret" autocomplete="new-password"></label>
                <label class="fld">Bucket<input class="in mono" name="bucket"></label>
                <label class="fld">Prefixo (opcional)<input class="in mono" name="path_s3" placeholder="servidores"></label>
              </div>
            </div>
            <div data-rm="rclone" class="rm-grp" hidden>
              <label class="fld">Configuração rclone<textarea class="in mono cron-ta" name="config" rows="7" placeholder="[nome]&#10;type = drive&#10;scope = drive&#10;token = {...}"></textarea><small>Para Google Drive, OneDrive, Dropbox…: corre "rclone config" no teu PC e cola aqui a secção gerada. O nome entre [ ] tem de ser igual ao nome acima.</small></label>
              <label class="fld">Pasta no destino<input class="in mono" name="path_rc" value="iddigital-hosting"></label>
            </div>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'definicoes'):
    $srvMode = (string)($srv['mode'] ?? 'lan');
?>
<?php $dtab = in_array(qget('t'), ['servidor', 'seguranca', 'servicos'], true) ? qget('t') : 'servidor'; ?>
      <nav class="tabs" aria-label="Secções"><a class="chip<?= $dtab === 'servidor' ? ' prim' : '' ?>" href="?p=definicoes&amp;t=servidor">Servidor e domínio</a><a class="chip<?= $dtab === 'seguranca' ? ' prim' : '' ?>" href="?p=definicoes&amp;t=seguranca">Acesso e segurança</a><a class="chip<?= $dtab === 'servicos' ? ' prim' : '' ?>" href="?p=definicoes&amp;t=servicos">Serviços</a></nav>
<?php if ($dtab === 'servidor'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Modo do servidor</h2><p>Define como o painel apresenta os sites e o que propõe por omissão. Mudar de modo não altera os sites que já existem.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('srv_mode') ?>
          <div class="mode-grid">
            <label class="mode<?= $srvMode === 'lan' ? ' on' : '' ?>"><input type="radio" name="mode" value="lan"<?= $srvMode === 'lan' ? ' checked' : '' ?>>
              <span class="tile t-blue"><?= ic('server') ?></span>
              <b>LAN</b><span class="mu">Sites acessíveis por IP e porta (http://IP:8001). Ideal para redes internas, testes e desenvolvimento. Os domínios são opcionais e o SSL é autoassinado.</span></label>
            <label class="mode<?= $srvMode === 'internet' ? ' on' : '' ?>"><input type="radio" name="mode" value="internet"<?= $srvMode === 'internet' ? ' checked' : '' ?>>
              <span class="tile t-acc"><?= ic('world') ?></span>
              <b>Internet</b><span class="mu">Sites com domínio próprio nas portas 80/443 e certificado Let's Encrypt automático. Cada site continua também acessível pela porta.</span></label>
          </div>
          <div class="fgrid" style="margin-top:18px">
            <label class="fld">Email para o Let's Encrypt<input class="in" type="email" name="email" value="<?= h($srv['email'] ?? '') ?>" placeholder="ssl@iddigital.pt"><small>Recebe os avisos de expiração dos certificados (opcional)</small></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">No modo Internet, cada domínio tem de ter um registo DNS (A ou AAAA) a apontar para o IP público deste servidor, e as portas 80 e 443 têm de chegar a ele (se houver router ou firewall à frente, reencaminha essas portas).</div>
      </section>

<?php endif; if ($dtab === 'seguranca'): ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Acesso pelas portas dos sites</h2><p>As portas próprias (ex.: :8001) servem os sites em HTTP, sem SSL.</p></div><span class="pill <?= ($srv['ports_access'] ?? 'all') === 'lan' ? 'p-ok' : 'p-off' ?>"><?= ($srv['ports_access'] ?? 'all') === 'lan' ? 'Só rede local' : 'Todos' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('ports_access') ?>
          <label class="chk"><input type="radio" name="pa" value="all"<?= ($srv['ports_access'] ?? 'all') !== 'lan' ? ' checked' : '' ?>> Abertas a qualquer IP</label>
          <label class="chk" style="margin-top:8px"><input type="radio" name="pa" value="lan"<?= ($srv['ports_access'] ?? 'all') === 'lan' ? ' checked' : '' ?>> Só rede local (10.x, 172.16-31.x, 192.168.x) e IPs de confiança</label>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Recomendado no modo Internet: os sites ficam públicos só pelos domínios (80/443, com HTTPS). Os IPs de confiança definem-se na página Ligações.</div>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>IPs autorizados no painel</h2><p>Se preencheres, o painel (incluindo phpMyAdmin e ficheiros) só abre a partir destes IPs.</p></div><span class="pill <?= ($srv['panel_allow'] ?? '') !== '' ? 'p-ok' : 'p-off' ?>"><?= ($srv['panel_allow'] ?? '') !== '' ? 'Restrito' : 'Todos' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('panel_allow') ?>
          <label class="fld">IPs ou redes (um por linha)<textarea class="in mono cron-ta" name="ips" rows="4" placeholder="<?= h($myIp) ?>&#10;192.168.1.0/24"><?= h(str_replace(' ', "\n", (string)($srv['panel_allow'] ?? ''))) ?></textarea><small>O teu IP atual é <b class="mono"><?= h($myIp) ?></b> e tem de estar incluído. Vazio = qualquer IP.</small></label>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Se ficares sem acesso, na consola do servidor: <span class="mono">mpanel panel-allow none</span></div>
      </section>
      </div>

      <section class="card">
        <div class="card-h"><div><h2>Proteção contra força bruta</h2><p>Bloqueia na firewall os IPs com demasiadas passwords erradas. Os bloqueios aparecem e desbloqueiam-se na página Ligações.</p></div>
          <?php $pr = is_array($state['protect'] ?? null) ? $state['protect'] : ['ssh' => true, 'ssh_fails' => 5, 'panel_fails' => 10, 'auth_fails' => 10, 'window' => 10, 'ban1' => '1h', 'ban2' => '24h', 'ban3' => '7d', 'recent' => 0]; ?>
          <span class="pill p-ok"><?= (int)$pr['recent'] ?> bloqueio<?= (int)$pr['recent'] === 1 ? '' : 's' ?> nas últimas 24 h</span></div>
        <form method="post" class="card-b">
          <?= act_fields('protect_settings') ?>
          <div class="fgrid" style="grid-template-columns:repeat(4,minmax(0,1fr))">
            <label class="fld">SSH (falhas)<input class="in" name="ssh_fails" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pr['ssh_fails'] ?>"><small>Todas as contas, incluindo o root</small></label>
            <label class="fld">Painel (falhas)<input class="in" name="panel_fails" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pr['panel_fails'] ?>"><small>Password ou código 2FA errados</small></label>
            <label class="fld">Email, webmail e FTP (falhas)<input class="in" name="auth_fails" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pr['auth_fails'] ?>"></label>
            <label class="fld">Janela (minutos)<input class="in" name="window" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$pr['window'] ?>"><small>Período em que as falhas contam</small></label>
          </div>
          <?php $durs = ['15m' => '15 minutos', '1h' => '1 hora', '6h' => '6 horas', '24h' => '24 horas', '7d' => '7 dias', '30d' => '30 dias', 'perm' => 'Permanente']; $sel = function (string $cur, array $opts) use ($durs) { $o = ''; foreach ($opts as $k) $o .= '<option value="' . $k . '"' . ($cur === $k ? ' selected' : '') . '>' . $durs[$k] . '</option>'; return $o; }; ?>
          <div class="fgrid" style="grid-template-columns:repeat(4,minmax(0,1fr));margin-top:14px">
            <label class="fld">1.º bloqueio<select class="in" name="ban1"><?= $sel((string)$pr['ban1'], ['15m', '1h', '6h', '24h']) ?></select></label>
            <label class="fld">2.º bloqueio (30 dias)<select class="in" name="ban2"><?= $sel((string)$pr['ban2'], ['6h', '24h', '7d']) ?></select></label>
            <label class="fld">3.º e seguintes<select class="in" name="ban3"><?= $sel((string)$pr['ban3'], ['7d', '30d', 'perm']) ?></select></label>
            <label class="fld">Vigiar o SSH<select class="in" name="ssh"><option value="on"<?= !empty($pr['ssh']) ? ' selected' : '' ?>>Sim</option><option value="off"<?= empty($pr['ssh']) ? ' selected' : '' ?>>Não</option></select></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <form method="post" class="card-f" style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><?= act_fields('logs_settings') ?><span>Logs dos sites: guardar</span><input class="in" name="days" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)($state['log_days'] ?? 90) ?>" style="width:90px"><span>dias</span><button class="btn sm sec" type="submit">Guardar</button></form>
        <div class="card-f mu">Nunca são bloqueados o próprio servidor, os IPs de confiança (página Ligações) nem os IPs de onde usaste o painel nos últimos 7 dias. Quem volta a ser apanhado em 30 dias fica bloqueado mais tempo.</div>
      </section>

<?php endif; if ($dtab === 'servicos'): ?>
      <?php $pg2 = is_array($state['perf'] ?? null) ? $state['perf'] : []; ?>
      <section class="card">
        <div class="card-h"><div><h2>Rede e compressão</h2><p>Ajustes do servidor que tornam os sites mais rápidos para todos os visitantes.</p></div></div>
        <div class="row-list">
          <div class="item"><div class="grow"><div class="nm">Rede afinada (TCP BBR) <span class="pill <?= ($pg2['cc'] ?? '') === 'bbr' ? 'p-ok' : 'p-off' ?>"><?= h((string)($pg2['cc'] ?? '—')) ?></span></div><div class="mu">Controlo de congestionamento BBR e filas de ligação maiores: páginas mais rápidas sobretudo em redes móveis e visitantes distantes.</div></div>
            <form method="post"><?= act_fields('net_tune', ['on' => !empty($pg2['net']) ? 'off' : 'on']) ?><button class="btn sm <?= !empty($pg2['net']) ? 'sec' : '' ?>" type="submit"><?= !empty($pg2['net']) ? 'Desligar' : 'Ligar' ?></button></form></div>
          <div class="item"><div class="grow"><div class="nm">Compressão Brotli <span class="pill <?= !empty($pg2['brotli']) ? 'p-ok' : 'p-off' ?>"><?= !empty($pg2['brotli']) ? 'Ligada' : 'Desligada' ?></span></div><div class="mu">HTML, CSS e JS cerca de 15–20% mais pequenos do que com gzip (que continua ativo para os browsers sem Brotli).<?= empty($pg2['brotli_ok']) && empty($pg2['brotli']) ? ' O módulo é instalado ao ligar.' : '' ?></div></div>
            <form method="post"><?= act_fields('brotli', ['on' => !empty($pg2['brotli']) ? 'off' : 'on']) ?><button class="btn sm <?= !empty($pg2['brotli']) ? 'sec' : '' ?>" type="submit"><?= !empty($pg2['brotli']) ? 'Desligar' : 'Ligar' ?></button></form></div>
        </div>
      </section>

      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>phpMyAdmin</h2><p>Tempos e limites. Aumenta-os para importar ou exportar bases de dados grandes.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('pma_settings') ?>
          <?php $ps = is_array($state['pma_settings'] ?? null) ? $state['pma_settings'] : ['session' => 120, 'exec' => 600, 'upload' => 512]; ?>
          <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr))">
            <label class="fld">Sessão (minutos)<input class="in" name="session" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$ps['session'] ?>"><small>Sem atividade até pedir login (5 a 1440)</small></label>
            <label class="fld">Tempo por operação (s)<input class="in" name="exec" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$ps['exec'] ?>"><small>Importações e consultas longas (30 a 7200)</small></label>
            <label class="fld">Importação máxima (MB)<input class="in" name="upload" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$ps['upload'] ?>"><small>Tamanho do ficheiro (8 a 4096)</small></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>FTP</h2><p>Acesso por FTPS (porta 21) e SFTP (porta 22). As contas ativam-se em Sites → ⋮ → Acesso FTP/SFTP.</p></div><span class="pill <?= !empty($state['ftp']['installed']) ? 'p-ok' : 'p-off' ?>"><?= !empty($state['ftp']['installed']) ? 'Instalado' : 'Ainda não usado' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('ftp_settings') ?>
          <label class="fld">IP público para o modo passivo<input class="in mono" name="pasv_ip" value="<?= h($state['ftp']['pasv_ip'] ?? '') ?>" placeholder="vazio = o próprio servidor"><small>Preenche se o servidor estiver atrás de um router com NAT (reencaminha a porta 21 e as portas 30000-30100)</small></label>
          <label class="chk" style="margin-top:12px"><input type="checkbox" name="plain" value="1"<?= !empty($state['ftp']['plain']) ? ' checked' : '' ?>> Permitir também FTP sem cifra (não recomendado: a password circula em claro)</label>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>
      </div>

<?php endif; if ($dtab === 'servidor'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Domínio do painel</h2><p>Acesso ao painel por um nome, por exemplo hosting.iddigital.pt, com certificado válido.</p></div>
          <?php if (($srv['panel_domain'] ?? '') !== ''): ?><span class="pill p-ok"><?= h($srv['panel_domain']) ?></span><?php endif; ?></div>
        <form method="post" class="card-b">
          <?= act_fields('panel_domain') ?>
          <div class="fgrid">
            <label class="fld">Domínio<input class="in mono" name="domain" value="<?= h($srv['panel_domain'] ?? '') ?>" placeholder="hosting.iddigital.pt" autocomplete="off"><small>Vazio = sem domínio (o painel fica só na porta <?= (int)($sys['panel_port'] ?? 2443) ?>)</small></label>
            <label class="fld">Certificado<select class="in" name="ssl"><option value="le"<?= ($srv['panel_ssl'] ?? 'le') === 'le' ? ' selected' : '' ?>>Let's Encrypt</option><option value="self"<?= ($srv['panel_ssl'] ?? '') === 'self' ? ' selected' : '' ?>>Autoassinado (LAN)</option></select></label>
          </div>
          <?php if (!empty($srv['panel_ssl_exp'])): ?><p class="mu" style="margin:12px 0 0">Certificado válido até <?= h(gmdate('d/m/Y', (int)$srv['panel_ssl_exp'] + tz_off(live_stats()))) ?>; é renovado automaticamente.</p><?php endif; ?>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>

<?php endif; ?>
<?php elseif ($page === 'email'):
    $ml = is_array($state['mail'] ?? null) ? $state['mail'] : ['enabled' => false];
    $mOn = !empty($ml['enabled']);
    $tab = in_array(qget('t'), ['caixas', 'envio', 'fila', 'spam', 'antispam'], true) ? qget('t') : 'caixas';
    $mHist = is_array($ml['history'] ?? null) ? $ml['history'] : [];
    $mLists = is_array($ml['lists'] ?? null) ? $ml['lists'] : [];
    $mHost = (string)($ml['host'] ?? '');
    $mDomains = is_array($ml['domains'] ?? null) ? $ml['domains'] : [];
    $mBoxes = is_array($ml['boxes'] ?? null) ? $ml['boxes'] : [];
    $mAliases = is_array($ml['aliases'] ?? null) ? $ml['aliases'] : [];
    $mSites = is_array($ml['sites'] ?? null) ? $ml['sites'] : [];
    $mQueue = is_array($ml['queue'] ?? null) ? $ml['queue'] : [];
    $chk = function ($v): string { return $v === null ? '<span class="pill p-off">?</span>' : (!empty($v['ok']) ? '<span class="pill p-ok">OK</span>' : '<span class="pill p-err">Falta</span>'); };
?>
<?php if (!$mOn): ?>
      <section class="card">
        <div class="card-h"><div><h2>Ativar o email</h2><p>Caixas de correio (IMAP/POP3/SMTP), envio do mail() dos sites e antispam.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('mail_enable') ?>
          <div class="fgrid">
            <label class="fld">Nome do servidor de correio<input class="in mono" name="host" required placeholder="mail.iddigital.pt" autocomplete="off"><small>Tem de ter um registo A a apontar para este servidor; é o nome que os clientes de email usam</small></label>
          </div>
          <?php if (!$isNet): ?><div class="warnbox" style="margin-top:14px">O servidor está em modo LAN. O email funciona para testes internos, mas para receber e entregar email na internet muda para o modo Internet (Definições).</div><?php endif; ?>
          <div class="warnbox" style="margin-top:14px">Antes de ativar, confirma com o fornecedor do servidor que a <b>porta 25 de saída</b> está desbloqueada e pede o <b>PTR (DNS inverso)</b> do IP para o nome acima. Sem isto, o email enviado vai para o spam ou é recusado.</div>
          <div style="margin-top:16px"><button class="btn" type="submit">Instalar e ativar o email</button> <span class="mu">Instala Postfix, Dovecot, Rspamd, Redis e Unbound (alguns minutos).</span></div>
        </form>
      </section>
<?php else: ?>
      <nav class="tabs" aria-label="Secções do email">
        <?php foreach (['caixas' => 'Domínios e caixas', 'envio' => 'Envio dos sites', 'fila' => 'Fila (' . count($mQueue) . ')', 'spam' => 'Spam e listas', 'antispam' => 'Antispam'] as $tk => $tl): ?>
          <a class="chip<?= $tab === $tk ? ' prim' : '' ?>" href="?p=email&amp;t=<?= $tk ?>"><?= h($tl) ?></a>
        <?php endforeach; ?>
        <span class="mu" style="margin-left:auto">Servidor: <b class="mono"><?= h($mHost) ?></b> <?= !empty($ml['services_ok']) ? '<span class="pill p-ok">Serviços OK</span>' : '<span class="pill p-err">Serviço parado</span>' ?></span>
      </nav>

  <?php if ($tab === 'caixas'): ?>
      <section class="card wm-card"><div class="row-list"><div class="item">
        <span class="tile t-acc"><?= ic('mail') ?></span>
        <div class="grow"><div class="nm">Webmail</div><div class="mu">Os utilizadores entram com o endereço e a password da caixa. Em Definições → Respostas automáticas configuram férias/ausência; em Filtros, regras próprias.</div></div>
        <a class="btn" href="<?= h($ml['webmail'] ?? '#') ?>" target="_blank" rel="noopener"><?= ic('ext') ?><?= h(preg_replace('#^https://#', '', (string)($ml['webmail'] ?? ''))) ?></a>
      </div></div></section>

      <section class="card">
        <div class="card-h"><div><h2>Domínios de email</h2><p>Cada domínio tem a sua chave DKIM. Cria os registos DNS e usa "Verificar".</p></div><button class="chip sm soft" type="button" data-open="dlg-md-new">Adicionar domínio</button></div>
        <?php if (!$mDomains): ?><div class="empty"><b>Ainda não há domínios</b>Adiciona o primeiro domínio para criar caixas de correio.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Domínio</th><th>Caixas</th><th>MX</th><th>SPF</th><th>DKIM</th><th>DMARC</th><th>PTR</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mDomains as $i => $md): $dn = (string)$md['name']; $dd = is_array($md['dns'] ?? null) ? $md['dns'] : null; ?>
            <tr>
              <td class="first" data-label="Domínio"><div class="who"><span class="av <?= tone($dn) ?>"><?= ic('mail') ?></span><div class="nm"><?= h($dn) ?></div></div></td>
              <td data-label="Caixas"><?= (int)$md['boxes'] ?></td>
              <td data-label="MX"><?= $chk($dd['mx'] ?? null) ?></td><td data-label="SPF"><?= $chk($dd['spf'] ?? null) ?></td><td data-label="DKIM"><?= $chk($dd['dkim'] ?? null) ?></td>
              <td data-label="DMARC"><?= $chk($dd['dmarc'] ?? null) ?></td><td data-label="PTR"><?= $chk($dd['ptr'] ?? null) ?></td>
              <td class="act r">
                <details class="dd"><summary class="iconbtn" aria-label="Ações de <?= h($dn) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <button type="button" data-open="dlg-md-dns-<?= $i ?>"><?= ic('world') ?>Registos DNS</button>
                    <form method="post"><?= act_fields('mail_dns_check', ['d' => $dn]) ?><button type="submit"><?= ic('reload') ?>Verificar DNS</button></form>
                    <hr>
                    <form method="post" data-confirm="Apagar o domínio <?= h($dn) ?> com TODAS as caixas de correio e mensagens? Não é possível desfazer."><?= act_fields('mail_dom_del', ['d' => $dn]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div></details>
                <dialog id="dlg-md-dns-<?= $i ?>" style="width:min(980px,calc(100vw - 24px))">
                  <div class="dlg-h"><div><h3>Registos DNS de <?= h($dn) ?></h3><p>Cria estes registos na zona DNS do domínio.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <div class="dlg-b">
                    <?php $ip = (string)($dd['ip'] ?? ''); $recs = [
                        ['MX', $dn, '10 ' . $mHost, $dd['mx'] ?? null],
                        ['TXT', $dn, 'v=spf1 mx a:' . $mHost . ' ~all', $dd['spf'] ?? null],
                        ['TXT', 'mp._domainkey.' . $dn, (string)($md['dkim'] ?? ''), $dd['dkim'] ?? null],
                        ['TXT', '_dmarc.' . $dn, 'v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@' . $dn, $dd['dmarc'] ?? null],
                        ['A', $mHost, $ip !== '' ? $ip : 'IP público do servidor', $dd['a'] ?? null],
                        ['PTR', $ip !== '' ? $ip : 'IP do servidor', $mHost . ' (pedir ao fornecedor)', $dd['ptr'] ?? null]]; ?>
                    <table class="list dnsrec"><thead><tr><th>Tipo</th><th>Nome</th><th>Valor</th><th>Estado</th></tr></thead><tbody>
                    <?php foreach ($recs as $r): ?><tr><td class="mono"><?= h($r[0]) ?></td><td class="mono"><?= h($r[1]) ?></td><td><div class="dnsval mono"><?= h($r[2]) ?></div></td><td><?= $chk($r[3]) ?></td></tr><?php endforeach; ?>
                    </tbody></table>
                    <?php if ($dd !== null): ?><p class="mu" style="margin:0">Última verificação: <?= h(ago((int)($dd['checked'] ?? 0), time())) ?>. As alterações de DNS podem demorar algumas horas a propagar.</p><?php endif; ?>
                  </div>
                  <div class="dlg-f"><form method="post"><?= act_fields('mail_dns_check', ['d' => $dn]) ?><button class="btn" type="submit">Verificar agora</button></form><button class="btn sec" type="button" data-close>Fechar</button></div>
                </dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Caixas de correio</h2><p>IMAP <span class="mono"><?= h($mHost) ?>:993</span> · POP3 <span class="mono">:995</span> · SMTP <span class="mono">:465</span> (SSL) ou <span class="mono">:587</span> (STARTTLS) · utilizador = endereço completo</p></div><?php if ($mDomains): ?><button class="chip sm soft" type="button" data-open="dlg-mb-new">Nova caixa</button><?php endif; ?></div>
        <?php if (!$mBoxes): ?><div class="empty">Ainda não há caixas de correio.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Endereço</th><th>Ocupação</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mBoxes as $i => $b): $em = (string)$b['email']; $q = max(1, (int)$b['quota']); $u = (int)$b['used']; $pc = min(100, (int)round($u * 100 / $q)); ?>
            <tr>
              <td class="first" data-label="Endereço"><div class="who"><span class="av <?= tone($em) ?>"><?= h(strtoupper(substr($em, 0, 1))) ?></span><div class="nm"><?= h($em) ?></div></div></td>
              <td data-label="Ocupação" style="min-width:220px"><div class="bar"><span style="width:<?= $pc ?>%"<?= $pc >= 90 ? ' class="hot"' : '' ?>></span></div><div class="mu"><?= $u ?> MB de <?= $q ?> MB</div></td>
              <td class="act r">
                <details class="dd"><summary class="iconbtn" aria-label="Ações de <?= h($em) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <button type="button" data-open="dlg-mb-<?= $i ?>"><?= ic('key') ?>Password e quota</button>
                    <hr>
                    <form method="post" data-confirm="Apagar a caixa <?= h($em) ?> e todas as mensagens?"><?= act_fields('mail_box_del', ['email' => $em]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div></details>
                <dialog id="dlg-mb-<?= $i ?>"><form method="post"><?= act_fields('mail_box_set', ['email' => $em]) ?>
                  <div class="dlg-h"><h3><?= h($em) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <div class="dlg-b"><div class="fgrid">
                    <label class="fld">Nova password<input class="in" type="password" name="pw" minlength="10" autocomplete="new-password"><small>Vazio = não altera</small></label>
                    <label class="fld">Quota (MB)<input class="in" name="quota" inputmode="numeric" pattern="[0-9]{2,7}" value="<?= $q ?>"></label>
                  </div></div>
                  <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
                </form></dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Encaminhamentos e aliases</h2><p>Endereços que reencaminham para outras caixas (internas ou externas). Usa <span class="mono">@dominio.pt</span> para receber todos os endereços.</p></div><?php if ($mDomains): ?><button class="chip sm soft" type="button" data-open="dlg-ma-new">Novo encaminhamento</button><?php endif; ?></div>
        <?php if (!$mAliases): ?><div class="empty">Sem encaminhamentos.</div>
        <?php else: ?>
        <div class="row-list">
          <?php foreach ($mAliases as $a): ?>
            <div class="item"><span class="av t-vio"><?= ic('mail') ?></span><div class="grow"><div class="nm mono"><?= h($a['alias']) ?></div><div class="mu">→ <?= h(implode(', ', (array)$a['dests'])) ?></div></div>
              <form method="post" data-confirm="Apagar o encaminhamento <?= h($a['alias']) ?>?"><?= act_fields('mail_alias_del', ['alias' => (string)$a['alias']]) ?><button class="btn sm sec" type="submit">Apagar</button></form></div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
      </section>

      <dialog id="dlg-md-new"><form method="post"><?= act_fields('mail_dom_add') ?>
        <div class="dlg-h"><h3>Adicionar domínio de email</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><label class="fld">Domínio<input class="in mono" name="d" required placeholder="iddigital.pt" autocomplete="off"><small>É gerada uma chave DKIM; depois cria os registos DNS indicados</small></label></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
      </form></dialog>
      <dialog class="drawer" id="dlg-mb-new"><form method="post" autocomplete="off"><?= act_fields('mail_box_add') ?>
        <div class="dlg-h"><div><h3>Nova caixa de correio</h3><p>O utilizador para os clientes de email é o endereço completo.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b">
          <div class="fgrid">
            <label class="fld">Nome<input class="in mono" name="user" required pattern="[a-z0-9]([a-z0-9._+\-]{0,62}[a-z0-9])?" placeholder="geral"></label>
            <label class="fld">Domínio<select class="in" name="dom"><?php foreach ($mDomains as $md): ?><option value="<?= h($md['name']) ?>">@<?= h($md['name']) ?></option><?php endforeach; ?></select></label>
            <label class="fld">Password<input class="in" type="password" name="pw" minlength="10" autocomplete="new-password"><small>Vazio = gerada e mostrada no fim</small></label>
            <label class="fld">Quota (MB)<input class="in" name="quota" inputmode="numeric" pattern="[0-9]{2,7}" value="1024"></label>
          </div>
        </div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar caixa</button></div>
      </form></dialog>
      <dialog id="dlg-ma-new"><form method="post"><?= act_fields('mail_alias_set') ?>
        <div class="dlg-h"><h3>Novo encaminhamento</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b">
          <label class="fld">Endereço<input class="in mono" name="alias" required placeholder="info@iddigital.pt ou @iddigital.pt"></label>
          <label class="fld">Encaminhar para<textarea class="in mono cron-ta" name="dests" rows="3" required placeholder="geral@iddigital.pt&#10;outro@gmail.com"></textarea><small>Um por linha (até 20)</small></label>
        </div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
      </form></dialog>

  <?php elseif ($tab === 'envio'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Envio de email pelos sites</h2><p>O mail() do PHP de cada site passa por uma fila do painel: limite por hora, análise antispam e DKIM antes de sair. Se um site for comprometido e começar a enviar spam, o envio dele é suspenso automaticamente sem afetar os outros.</p></div></div>
        <table class="list cards">
          <thead><tr><th>Site</th><th class="r">Última hora</th><th class="r">24 h</th><th class="r">Limite/hora</th><th class="r">Retidos</th><th class="r">Rejeitados (spam)</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mSites as $i => $ms): $sn = (string)$ms['site']; $lim = $ms['limit'] ?? null; ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($sn) ?>"><?= h(substr($sn, 0, 1)) ?></span><div class="nm"><?= h($sn) ?></div></div></td>
              <td class="r" data-label="Última hora"><?= (int)$ms['sent_1h'] ?></td>
              <td class="r" data-label="24 h"><?= (int)$ms['sent_24h'] ?></td>
              <td class="r" data-label="Limite/hora"><?= $lim === null ? (int)($ml['site_limit'] ?? 100) . ' <span class="mu">(geral)</span>' : (int)$lim ?></td>
              <td class="r" data-label="Retidos"><?= (int)$ms['held'] ?></td>
              <td class="r" data-label="Rejeitados"><?= (int)$ms['rejected'] > 0 ? '<b style="color:var(--err)">' . (int)$ms['rejected'] . '</b>' : '0' ?></td>
              <td data-label="Estado"><?= !empty($ms['suspended']) ? '<span class="pill p-err">Suspenso</span><div class="mu">' . h($ms['why'] ?? '') . '</div>' : '<span class="pill p-ok">Ativo</span>' ?></td>
              <td class="act r">
                <details class="dd"><summary class="iconbtn" aria-label="Ações de <?= h($sn) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <button type="button" data-open="dlg-msl-<?= $i ?>"><?= ic('sliders') ?>Mudar limite</button>
                    <?php if (!empty($ms['suspended'])): ?><form method="post"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'resume']) ?><button type="submit"><?= ic('play') ?>Retomar envio</button></form>
                    <?php else: ?><form method="post"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'suspend']) ?><button type="submit"><?= ic('ban') ?>Suspender envio</button></form><?php endif; ?>
                    <hr>
                    <form method="post" data-confirm="Apagar as mensagens retidas e rejeitadas de <?= h($sn) ?>?"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'purge']) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar retidos</button></form>
                  </div></details>
                <dialog id="dlg-msl-<?= $i ?>"><form method="post"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'limit']) ?>
                  <div class="dlg-h"><h3>Limite de envio de <?= h($sn) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <div class="dlg-b"><label class="fld">Emails por hora<input class="in" name="limit" inputmode="numeric" pattern="[0-9]{1,6}" value="<?= (int)($lim ?? ($ml['site_limit'] ?? 100)) ?>"><small>Acima do limite as mensagens ficam retidas e saem na hora seguinte</small></label></div>
                  <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
                </form></dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <div class="card-f mu">Os sites não podem usar a porta 25 nem o sendmail diretamente (bloqueado na firewall e no Postfix). O remetente só é aceite se for de um domínio do próprio site; caso contrário é usado <span class="mono">&lt;site&gt;@<?= h($mHost) ?></span>. Ao fim de 5 mensagens com spam numa hora, o envio do site é suspenso.</div>
      </section>

  <?php elseif ($tab === 'spam'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Mensagens rejeitadas ou marcadas como spam</h2><p>Últimas mensagens que o antispam recusou (rejeitada) ou entregou na pasta Lixo (spam). Se for um falso positivo, permite o remetente ou o domínio.</p></div></div>
        <?php if (!$mHist): ?><div class="empty">Sem mensagens rejeitadas ou marcadas como spam recentemente.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Data</th><th>Remetente</th><th>Destinatário</th><th>Assunto</th><th class="r">Pontos</th><th>Resultado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mHist as $i => $hm): $fr = strtolower(trim((string)preg_replace('/^.*<|>.*$/', '', (string)($hm['from'] ?? '')))); ?>
            <tr>
              <td class="first" data-label="Data"><span class="mono"><?= h(gmdate('d/m H:i', (int)($hm['t'] ?? 0) + tz_off(live_stats()))) ?></span></td>
              <td class="mono" data-label="Remetente"><?= h($fr) ?><div class="mu"><?= h($hm['ip'] ?? '') ?></div></td>
              <td class="mono" data-label="Destinatário"><?= h($hm['to'] ?? '') ?></td>
              <td data-label="Assunto" style="max-width:280px"><?= h(mb_strimwidth((string)($hm['subject'] ?? ''), 0, 80, '…')) ?><div class="mu mono" style="font-size:11px"><?= h(implode(' ', (array)($hm['symbols'] ?? []))) ?></div></td>
              <td class="r" data-label="Pontos"><?= h(number_format((float)($hm['score'] ?? 0), 1, ',', '')) ?></td>
              <td data-label="Resultado"><?= ($hm['action'] ?? '') === 'reject' ? '<span class="pill p-err">Rejeitada</span>' : '<span class="pill p-warn">Lixo</span>' ?></td>
              <td class="act r">
                <?php if (filter_var($fr, FILTER_VALIDATE_EMAIL)): ?>
                <details class="dd"><summary class="iconbtn" aria-label="Ações"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <form method="post"><?= act_fields('mail_list', ['l' => 'allow', 'op' => 'add', 'v' => $fr]) ?><button type="submit"><?= ic('check') ?>Permitir este remetente</button></form>
                    <form method="post"><?= act_fields('mail_list', ['l' => 'allow', 'op' => 'add', 'v' => '@' . substr($fr, strpos($fr, '@') + 1)]) ?><button type="submit"><?= ic('check') ?>Permitir o domínio @<?= h(substr($fr, strpos($fr, '@') + 1)) ?></button></form>
                    <hr>
                    <form method="post"><?= act_fields('mail_list', ['l' => 'deny', 'op' => 'add', 'v' => $fr]) ?><button type="submit" class="dan"><?= ic('ban') ?>Bloquear este remetente</button></form>
                  </div></details>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">As mensagens rejeitadas não chegam a ser aceites (o remetente recebe o aviso de erro); as marcadas como spam vão para a pasta Lixo de cada caixa. Quando um utilizador move uma mensagem para o Lixo, ou a tira de lá, o antispam aprende com isso.</div>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Listas de remetentes</h2><p>Permitidos passam sempre o antispam; bloqueados são sempre rejeitados. Aceita endereços, @domínios e IPs.</p></div></div>
        <form method="post" class="card-b" style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end">
          <?= act_fields('mail_list', ['op' => 'add']) ?>
          <label class="fld" style="flex:1;min-width:240px">Endereço, @domínio ou IP<input class="in mono" name="v" required placeholder="faturas@fornecedor.pt, @fornecedor.pt ou 203.0.113.5"></label>
          <label class="fld">Lista<select class="in" name="l"><option value="allow">Permitir</option><option value="deny">Bloquear</option></select></label>
          <button class="btn" type="submit" style="height:44px">Adicionar</button>
        </form>
        <?php if ($mLists): ?>
        <div class="row-list">
          <?php foreach ($mLists as $li): ?>
            <div class="item"><span class="pill <?= $li['list'] === 'allow' ? 'p-ok' : 'p-err' ?>"><?= $li['list'] === 'allow' ? 'Permitido' : 'Bloqueado' ?></span><div class="grow mono"><?= h($li['value']) ?></div>
              <form method="post"><?= act_fields('mail_list', ['l' => (string)$li['list'], 'op' => 'del', 'v' => (string)$li['value']]) ?><button class="btn sm sec" type="submit">Remover</button></form></div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
      </section>

  <?php elseif ($tab === 'fila'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Fila de correio</h2><p>Mensagens que o Postfix ainda não conseguiu entregar (servidor de destino indisponível, recusa temporária…).</p></div>
          <div style="display:flex;gap:8px"><form method="post"><?= act_fields('mail_queue', ['op' => 'flush']) ?><button class="btn sm sec" type="submit">Reenviar tudo</button></form>
          <?php if ($mQueue): ?><form method="post" data-confirm="Apagar todas as mensagens da fila?"><?= act_fields('mail_queue', ['op' => 'all']) ?><button class="btn sm dan" type="submit">Esvaziar</button></form><?php endif; ?></div></div>
        <?php if (!$mQueue): ?><div class="empty">A fila está vazia.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Remetente</th><th>Destinatário</th><th>Motivo</th><th>Há</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mQueue as $qm): ?>
            <tr>
              <td class="first mono" data-label="Remetente"><?= h($qm['from'] ?? '') ?></td>
              <td class="mono" data-label="Destinatário"><?= h($qm['to'] ?? '') ?></td>
              <td data-label="Motivo" class="mu" style="max-width:420px"><?= h($qm['why'] ?? '') ?></td>
              <td data-label="Há"><?= h(ago((int)($qm['t'] ?? time()), time())) ?></td>
              <td class="act r"><form method="post"><?= act_fields('mail_queue', ['op' => 'del', 'id' => (string)($qm['id'] ?? '')]) ?><button class="btn sm sec" type="submit">Apagar</button></form></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

  <?php else: ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Antispam</h2><p>Postscreen + Rspamd: SPF, DKIM, DMARC, reputação, greylisting e listas negras.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('mail_settings') ?>
          <label class="fld">Listas negras próprias (DNSBL)<textarea class="in mono cron-ta" name="dnsbl" rows="3" placeholder="dnsbl.3rhost.pt"><?= h(str_replace(' ', "\n", (string)($ml['dnsbl'] ?? ''))) ?></textarea><small>Uma zona por linha. Juntam-se à Spamhaus ZEN, Barracuda, SpamCop e PSBL.</small></label>
          <div class="fgrid" style="margin-top:14px">
            <label class="fld">Limite por site (emails/hora)<input class="in" name="site_limit" inputmode="numeric" pattern="[0-9]{1,5}" value="<?= (int)($ml['site_limit'] ?? 100) ?>"></label>
            <label class="fld">Limite por caixa (emails/hora)<input class="in" name="box_limit" inputmode="numeric" pattern="[0-9]{1,5}" value="<?= (int)($ml['box_limit'] ?? 200) ?>"></label>
            <label class="fld">Bloquear IP após falhas de login (10 min)<input class="in" name="auth_fails" inputmode="numeric" pattern="[0-9]{1,5}" value="<?= (int)($ml['auth_fails'] ?? 10) ?>"><small>O IP fica bloqueado 1 hora em todas as portas</small></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">As listas negras são consultadas através de um resolver DNS próprio (Unbound), porque a Spamhaus não responde a resolvers públicos.</div>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Antivírus</h2><p>ClamAV analisa os anexos de todo o email que entra e sai.</p></div><span class="pill <?= !empty($ml['clamav']) ? 'p-ok' : 'p-off' ?>"><?= !empty($ml['clamav']) ? 'Ativo' : 'Desativado' ?></span></div>
        <form method="post" class="card-b"<?= empty($ml['clamav']) ? '' : ' data-confirm="Desativar o antivírus?"' ?>>
          <?= act_fields('mail_av', ['op' => !empty($ml['clamav']) ? 'off' : 'on']) ?>
          <button class="btn<?= !empty($ml['clamav']) ? ' sec' : '' ?>" type="submit"><?= !empty($ml['clamav']) ? 'Desativar' : 'Ativar antivírus' ?></button>
        </form>
        <div class="card-f mu">Usa cerca de 1,2 GB de RAM. Confirma na página Recursos que o servidor tem memória livre suficiente.</div>
      </section>
      </div>
  <?php endif; ?>
<?php endif; ?>

<?php elseif ($page === 'atualizacoes'):
    $up = jload(MP_STATS . '/update.json') ?? [];
    $upLast = jload(MP_STATS . '/update-last.json');
    $osu = jload(MP_STATS . '/os-updates.json') ?? [];
    $upRun = jload(MP_STATS . '/update-run.json');
    $snaps = is_array($state['updates']['snaps'] ?? null) ? $state['updates']['snaps'] : [];
    $hasKey = !empty($up['key']);
    $pk = is_array($osu['packages'] ?? null) ? $osu['packages'] : [];
?>
      <?php if ($upRun): ?>
        <div class="card bk-run" data-bk-running><div class="row-list"><div class="item"><span class="spin"></span><div class="grow"><div class="nm"><?= ($upRun['kind'] ?? '') === 'sistema' ? 'Atualização do sistema em curso' : 'Atualização do painel em curso' ?></div><div class="mu"><?= h($upRun['step'] ?? '') ?> · há <?= max(1, (int)ceil((time() - (int)($upRun['since'] ?? time())) / 60)) ?> min</div></div><span class="mu">A página atualiza sozinha. O painel pode ficar indisponível alguns segundos.</span></div></div></div>
      <?php elseif ($upLast && (int)($upLast['ts'] ?? 0) > time() - 86400): ?>
        <div class="card"><div class="card-b" style="color:<?= !empty($upLast['ok']) ? 'var(--ok)' : 'var(--err)' ?>"><b><?= !empty($upLast['ok']) ? 'Concluído' : 'Falhou' ?>:</b> <?= h($upLast['msg'] ?? '') ?> <span class="mu">(<?= h(ago((int)$upLast['ts'], time())) ?>)</span></div></div>
      <?php endif; ?>

<?php $utab = in_array(qget('t'), ['painel', 'sistema'], true) ? qget('t') : 'painel'; ?>
      <nav class="tabs" aria-label="Secções"><a class="chip<?= $utab === 'painel' ? ' prim' : '' ?>" href="?p=atualizacoes&amp;t=painel">Painel</a><a class="chip<?= $utab === 'sistema' ? ' prim' : '' ?>" href="?p=atualizacoes&amp;t=sistema">Sistema operativo</a></nav>
<?php if ($utab === 'painel'): ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Painel</h2><p>Versão do IDDigital Hosting e atualizações publicadas no GitHub.</p></div>
          <?php if (!empty($up['newer'])): ?><span class="pill p-warn">Versão nova disponível</span><?php elseif (!empty($up['latest'])): ?><span class="pill p-ok">Atualizado</span><?php endif; ?></div>
        <div class="card-b">
          <div class="kv"><span>Instalada</span><b>v<?= h(MP_VERSION) ?></b></div>
          <div class="kv"><span>Publicada</span><b><?= !empty($up['latest']) ? 'v' . h($up['latest']) . (!empty($up['date']) ? ' <span class="mu">(' . h($up['date']) . ')</span>' : '') : '—' ?></b></div>
          <div class="kv"><span>Verificação</span><b><?= $hasKey ? '<span class="pill p-ok">Assinatura obrigatória</span>' : '<span class="pill p-err">Sem chave de assinatura</span>' ?></b></div>
          <div class="kv"><span>Última procura</span><b><?= !empty($up['checked']) ? h(ago((int)$up['checked'], time())) : 'nunca' ?></b></div>
          <?php if (!empty($up['error'])): ?><p style="color:var(--err);margin:12px 0 0"><?= h($up['error']) ?></p><?php endif; ?>
          <?php if (!empty($up['newer']) && ($up['notes'] ?? '') !== ''): ?><div class="fsec">Novidades da v<?= h($up['latest']) ?></div><pre class="cron-out" style="padding:12px 14px;border-radius:12px;max-height:220px"><?= h($up['notes']) ?></pre><?php endif; ?>
          <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:16px">
            <form method="post"><?= act_fields('update_check') ?><button class="btn sec" type="submit"><?= ic('reload') ?>Procurar atualizações</button></form>
            <?php if (!empty($up['newer'])): ?>
            <form method="post" data-confirm="Atualizar o painel para a v<?= h($up['latest']) ?>? É guardada uma cópia da versão atual e, se algo falhar, é reposta automaticamente."><?= act_fields('update_start') ?>
              <?php if (!$hasKey): ?><label class="chk" style="margin-bottom:8px"><input type="checkbox" name="unsigned" value="1" required> Instalar sem assinatura<?= !empty($up['sha256']) ? ' (SHA-256 <span class="mono">' . h(substr((string)$up['sha256'], 0, 16)) . '…</span>)' : '' ?>: confirmo que publiquei esta versão</label><div class="fgrid" style="margin-bottom:10px"><?= reauth_fields($auth) ?></div><?php endif; ?>
              <button class="btn" type="submit"><?= ic('download') ?>Atualizar para v<?= h($up['latest']) ?></button></form>
            <?php endif; ?>
          </div>
        </div>
        <div class="card-f mu">Antes de atualizar: verifica a assinatura e o SHA-256, guarda uma cópia do painel e da configuração e, depois, confirma que o painel responde. Se não responder, repõe a versão anterior sozinho. Os sites, bases de dados, email e backups não são tocados.</div>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Repositório no GitHub</h2><p>De onde vêm as atualizações. Com um token só de leitura, o repositório pode ficar sempre privado.</p></div>
          <span class="pill <?= !empty($up['token']) ? 'p-ok' : 'p-off' ?>"><?= !empty($up['token']) ? 'Token configurado' : 'Sem token (repositório público)' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('update_token', ['op' => 'set']) ?>
          <label class="fld">Token do GitHub (só leitura)<input class="in mono" type="password" name="token" required autocomplete="off" placeholder="github_pat_…"><small>GitHub → Settings → Developer settings → Fine-grained tokens: só este repositório, permissão "Contents: Read-only". Fica guardado só para o root.</small></label>
          <div class="fgrid" style="margin-top:12px"><?= reauth_fields($auth) ?></div>
          <div style="display:flex;gap:8px;margin-top:14px"><button class="btn" type="submit"><?= !empty($up['token']) ? 'Substituir token' : 'Guardar token' ?></button></div>
        </form>
        <?php if (!empty($up['token'])): ?><form method="post" class="card-f" data-confirm="Remover o token? Se o repositório for privado, deixa de ser possível procurar atualizações."><?= act_fields('update_token', ['op' => 'clear']) ?><div class="fgrid" style="margin-bottom:10px"><?= reauth_fields($auth) ?></div><button class="btn sm sec" type="submit">Remover token</button></form><?php endif; ?>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Chave de assinatura</h2><p>Chave pública Ed25519 com que as versões são assinadas. Só são instaladas versões assinadas pela chave privada correspondente.</p></div><span class="pill <?= $hasKey ? 'p-ok' : 'p-err' ?>"><?= $hasKey ? 'Configurada' : 'Em falta' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('update_key', ['op' => 'set']) ?>
          <label class="fld">Chave pública (PEM)<textarea class="in mono cron-ta" name="pem" rows="4" required placeholder="-----BEGIN PUBLIC KEY-----&#10;MCowBQYDK2VwAyEA…&#10;-----END PUBLIC KEY-----"></textarea><small>Gerada no teu computador com <span class="mono">release.sh keygen</span>; a chave privada nunca vem para o servidor</small></label>
          <div class="fgrid" style="margin-top:14px"><?= reauth_fields($auth) ?></div>
          <div style="display:flex;gap:8px;margin-top:14px"><button class="btn" type="submit"><?= $hasKey ? 'Substituir chave' : 'Guardar chave' ?></button></div>
        </form>
        <?php if ($hasKey): ?><form method="post" class="card-f" data-confirm="Remover a chave? As atualizações deixam de ser verificadas."><?= act_fields('update_key', ['op' => 'clear']) ?><div class="fgrid" style="margin-bottom:10px"><?= reauth_fields($auth) ?></div><button class="btn sm sec" type="submit">Remover chave</button></form><?php endif; ?>
      </section>
      </div>

<?php endif; if ($utab === 'sistema'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Sistema operativo</h2><p>Pacotes do sistema (nginx, PHP, MariaDB, email…) instalados pelo <?= h(($sys['os'] ?? '') !== '' ? $sys['os'] : 'sistema') ?>.</p></div>
          <div style="display:flex;gap:8px;align-items:center">
            <?php if (!empty($osu['reboot'])): ?><span class="pill p-warn">Precisa de reiniciar</span><?php endif; ?>
            <span class="pill <?= !empty($osu['auto']) ? 'p-ok' : 'p-off' ?>">Automáticas: <?= !empty($osu['auto']) ? 'segurança' : 'desligadas' ?></span>
          </div></div>
        <section class="stats" style="padding:0 26px">
          <div class="stat"><span class="tile t-blue"><?= ic('download') ?></span><div><div class="k">Disponíveis</div><div class="v"><?= isset($osu['total']) ? (int)$osu['total'] : '—' ?></div></div></div>
          <div class="stat"><span class="tile <?= !empty($osu['security']) ? 't-warn' : 't-acc' ?>"><?= ic('lock') ?></span><div><div class="k">De segurança</div><div class="v"><?= isset($osu['security']) ? (int)$osu['security'] : '—' ?></div></div></div>
          <div class="stat"><span class="tile t-vio"><?= ic('clock') ?></span><div><div class="k">Última procura</div><div class="v" style="font-size:16px"><?= !empty($osu['checked']) ? h(ago((int)$osu['checked'], time())) : 'nunca' ?></div></div></div>
        </section>
        <div class="card-b" style="display:flex;gap:8px;flex-wrap:wrap">
          <form method="post"><?= act_fields('os_check') ?><button class="btn sec" type="submit"><?= ic('reload') ?>Procurar</button></form>
          <?php if (!empty($osu['security'])): ?><form method="post" data-confirm="Instalar as atualizações de segurança do sistema?"><?= act_fields('os_start', ['op' => 'security']) ?><button class="btn" type="submit">Instalar as de segurança (<?= (int)$osu['security'] ?>)</button></form><?php endif; ?>
          <?php if (!empty($osu['total'])): ?><form method="post" data-confirm="Instalar todas as atualizações do sistema? Os serviços podem reiniciar por breves segundos."><?= act_fields('os_start', ['op' => 'all']) ?><button class="btn sec" type="submit">Instalar todas (<?= (int)$osu['total'] ?>)</button></form><?php endif; ?>
          <form method="post"><?= act_fields('os_auto', ['op' => !empty($osu['auto']) ? 'off' : 'on']) ?><button class="btn sec" type="submit"><?= !empty($osu['auto']) ? 'Desligar automáticas' : 'Ativar atualizações de segurança automáticas' ?></button></form>
          <?php if (!empty($osu['reboot'])): ?><button class="btn dan" type="button" data-open="dlg-reboot"><?= ic('reload') ?>Reiniciar o servidor</button><?php endif; ?>
        </div>
        <?php if ($pk): ?>
        <table class="list cards">
          <thead><tr><th>Pacote</th><th>Versão nova</th><th>Tipo</th></tr></thead>
          <tbody>
          <?php foreach (array_slice($pk, 0, 60) as $p): ?>
            <tr><td class="first mono" data-label="Pacote"><?= h($p['name'] ?? '') ?></td><td class="mono mu" data-label="Versão"><?= h($p['version'] ?? '') ?></td><td data-label="Tipo"><?= !empty($p['security']) ? '<span class="pill p-warn">Segurança</span>' : '<span class="pill p-off">Normal</span>' ?></td></tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if (count($pk) > 60): ?><div class="card-f mu">E mais <?= count($pk) - 60 ?> pacotes.</div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">As atualizações automáticas instalam só as de segurança e nunca reiniciam o servidor sozinhas. A procura é feita todos os dias de madrugada.</div>
      </section>

      <?php if ($snaps): ?>
<?php endif; if ($utab === 'painel'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Cópias anteriores do painel</h2><p>Guardadas antes de cada atualização (painel, configuração e serviços). Repor volta a pôr essa versão do painel.</p></div></div>
        <div class="row-list">
          <?php foreach ($snaps as $sn): $fn = (string)$sn['file']; ?>
            <div class="item"><span class="av t-vio"><?= ic('archive') ?></span><div class="grow"><div class="nm mono"><?= h($fn) ?></div><div class="mu"><?= h(fmt_bytes((float)$sn['size'])) ?></div></div>
              <button class="btn sm sec" type="button" data-open="dlg-rb-<?= md5($fn) ?>">Repor</button></div>
              <dialog id="dlg-rb-<?= md5($fn) ?>"><form method="post"><?= act_fields('update_rollback', ['file' => $fn]) ?>
                <div class="dlg-h"><h3>Repor <?= h($fn) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                <div class="dlg-b"><p style="margin:0">O painel e a configuração voltam ao estado dessa cópia. A conta de acesso (password e 2FA) não é alterada.</p><?= reauth_fields($auth) ?></div>
                <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Repor</button></div>
              </form></dialog>
          <?php endforeach; ?>
        </div>
      </section>
      <?php endif; ?>

<?php endif; ?>
      <dialog id="dlg-reboot"><form method="post"><?= act_fields('reboot') ?>
        <div class="dlg-h"><h3>Reiniciar o servidor</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><p style="margin:0">O servidor reinicia dentro de 1 minuto. Os sites, o email e o painel ficam indisponíveis durante o arranque (normalmente 1 a 2 minutos).</p>
          <?= reauth_fields($auth) ?></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Reiniciar</button></div>
      </form></dialog>

<?php elseif ($page === 'logs'):
    $names = [];
    foreach ($sites as $s) { $sn0 = (string)($s['name'] ?? ''); if (valid_site($sn0)) $names[] = $sn0; }
    $lgSite = in_array(qget('site'), $names, true) ? qget('site') : ($names[0] ?? '');
    $lgT = in_array(qget('t'), ['access', 'error', 'php', 'slow', 'cron'], true) ? qget('t') : 'access';
    $lgDir = MP_SITE_LOGS . '/' . $lgSite;
    $lgSum = ($lgSite !== '' && $lgT === 'access') ? log_summary($lgDir . '/access.log') : null;
    $lgFiles = [];
    if ($lgSite !== '' && in_array($lgT, ['access', 'error', 'slow'], true)) {
        foreach ((array)glob($lgDir . '/' . ($lgT === 'slow' ? 'php-slow' : $lgT) . '.log*') as $lf) { if (is_file((string)$lf)) $lgFiles[] = ['n' => basename((string)$lf), 's' => (int)filesize((string)$lf), 'm' => (int)filemtime((string)$lf)]; }
        usort($lgFiles, function ($a, $b) { return $b['m'] <=> $a['m']; });
    }
    $crons = is_array($state['crons'] ?? null) ? array_values(array_filter($state['crons'], function ($c) use ($lgSite) { return ($c['site'] ?? '') === $lgSite; })) : [];
?>
<?php if (!$names): ?>
      <section class="card"><div class="empty"><b>Ainda não há sites</b>Os logs aparecem aqui depois de criares o primeiro site.</div></section>
<?php else: ?>
      <nav class="tabs" aria-label="Site">
        <select class="in" onchange="location.href='?p=logs&amp;t=<?= $lgT ?>&amp;site='+encodeURIComponent(this.value)" aria-label="Site" style="height:40px;min-width:200px;width:auto">
          <?php foreach ($names as $sn): ?><option value="<?= h($sn) ?>"<?= $sn === $lgSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
        </select>
        <?php foreach (['access' => 'Acessos', 'error' => 'Erros do servidor', 'php' => 'Erros do PHP', 'slow' => 'PHP lento', 'cron' => 'Tarefas agendadas'] as $tk => $tl): ?>
          <a class="chip<?= $lgT === $tk ? ' prim' : '' ?>" href="?p=logs&amp;site=<?= h(rawurlencode($lgSite)) ?>&amp;t=<?= $tk ?>"><?= $tl ?></a>
        <?php endforeach; ?>
        <label class="chk" style="margin-left:auto"><input type="checkbox" id="lg-live"> Ao vivo</label>
      </nav>

  <?php if ($lgSum !== null): ?>
      <section class="stats">
        <div class="stat"><span class="tile t-blue"><?= ic('world') ?></span><div><div class="k">Pedidos (24 h)</div><div class="v"><?= number_format($lgSum['total'], 0, ',', ' ') ?> <small><?= h(fmt_bytes((float)$lgSum['bytes'])) ?></small></div></div></div>
        <div class="stat"><span class="tile t-acc"><?= ic('check') ?></span><div><div class="k">Sucesso (2xx / 3xx)</div><div class="v"><?= $lgSum['c']['2'] ?> <small>/ <?= $lgSum['c']['3'] ?></small></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('ban') ?></span><div><div class="k">Erros 4xx / 5xx</div><div class="v"><?= $lgSum['c']['4'] ?> <small>/ <b style="color:<?= $lgSum['c']['5'] > 0 ? 'var(--err)' : 'inherit' ?>"><?= $lgSum['c']['5'] ?></b></small></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('clock') ?></span><div><div class="k">Tempo médio (páginas)</div><div class="v"><?= $lgSum['rtn'] ? (int)round($lgSum['rts'] * 1000 / $lgSum['rtn']) . ' <small>ms</small>' : '—' ?></div></div></div>
        <?php $ch = $lgSum['cache']; $cht = array_sum($ch); if ($cht): ?><div class="stat"><span class="tile t-acc"><?= ic('pulse') ?></span><div><div class="k">Cache de página</div><div class="v"><?= (int)round(($ch['HIT'] ?? 0) * 100 / $cht) ?>% <small>servido da cache · <?= $lgSum['total'] ? round($lgSum['bots'] * 100 / $lgSum['total']) : 0 ?>% robôs</small></div></div></div><?php endif; ?>
      </section>
      <div class="grid3">
        <?php foreach (['e5xx' => ['Erros 5xx (servidor/PHP)', 'Sem erros 5xx nas últimas 24 h.'], 'e404' => ['Páginas não encontradas (404)', 'Sem 404 nas últimas 24 h.']] as $k => $lbl): ?>
        <section class="card"><div class="card-h"><h2><?= $lbl[0] ?></h2></div>
          <?php if (!$lgSum[$k]): ?><div class="empty"><?= $lbl[1] ?></div><?php else: ?><div class="row-list">
          <?php foreach ($lgSum[$k] as $u => $cnt): ?><div class="item"><div class="grow mono lg-url" title="<?= h($u) ?>"><?= h($u) ?></div><b><?= (int)$cnt ?></b></div><?php endforeach; ?></div><?php endif; ?>
        </section>
        <?php endforeach; ?>
        <section class="card"><div class="card-h"><h2>Páginas mais lentas</h2></div>
          <?php if (!$lgSum['slow']): ?><div class="empty">Sem dados de tempo ainda (o registo de tempos começa com esta versão).</div><?php else: ?><div class="row-list">
          <?php foreach ($lgSum['slow'] as $u => $v): ?><div class="item"><div class="grow mono lg-url" title="<?= h($u) ?>"><?= h($u) ?></div><span class="mu"><?= (int)$v[0] ?>×</span><b style="<?= $v[1] / $v[0] >= 1 ? 'color:var(--err)' : '' ?>"><?= (int)round($v[1] * 1000 / $v[0]) ?> ms</b></div><?php endforeach; ?></div><?php endif; ?>
        </section>
        <section class="card"><div class="card-h"><h2>IPs mais ativos</h2></div>
          <?php if (!$lgSum['ips']): ?><div class="empty">Sem pedidos nas últimas 24 h.</div><?php else: ?><div class="row-list">
          <?php foreach ($lgSum['ips'] as $ip => $cnt): ?><div class="item"><div class="grow mono"><?= h($ip) ?></div><b><?= (int)$cnt ?></b>
            <form method="post" data-confirm="Bloquear <?= h($ip) ?> durante 24 horas?"><?= act_fields('fw_block', ['ip' => (string)$ip, 'dur' => '24h', 'reason' => 'Bloqueado a partir dos logs de ' . $lgSite]) ?><button class="btn sm sec" type="submit">Bloquear</button></form></div><?php endforeach; ?></div><?php endif; ?>
        </section>
      </div>
  <?php endif; ?>

      <section class="card" id="lg" data-site="<?= h($lgSite) ?>" data-t="<?= $lgT ?>">
        <div class="card-h"><div><h2><?= ['access' => 'Acessos', 'error' => 'Erros do servidor (nginx)', 'php' => 'Erros do PHP', 'slow' => 'Scripts PHP lentos (ficheiro e função em curso)', 'cron' => 'Saída das tarefas agendadas'][$lgT] ?></h2><p class="mono"><?= h(['access' => MP_SITE_LOGS . "/$lgSite/access.log", 'error' => MP_SITE_LOGS . "/$lgSite/error.log", 'php' => "/srv/www/$lgSite/logs/php-error.log", 'slow' => MP_SITE_LOGS . "/$lgSite/php-slow.log (Sites → ⋮ → Desempenho)", 'cron' => "/srv/www/$lgSite/logs/cron-<id>.log"][$lgT]) ?></p></div>
          <div class="lg-filters">
            <?php if ($lgT === 'access'): ?>
            <select class="in" id="lg-st" aria-label="Código"><option value="">Todos os códigos</option><option value="2">2xx</option><option value="3">3xx</option><option value="4">4xx</option><option value="5">5xx</option></select>
            <input class="in mono" id="lg-ip" placeholder="IP" aria-label="IP">
            <?php elseif ($lgT === 'cron'): ?>
            <select class="in" id="lg-cron" aria-label="Tarefa"><?php foreach ($crons as $c): ?><option value="<?= h($c['id']) ?>"><?= h(($c['desc'] ?? '') !== '' ? $c['desc'] : $c['cmd']) ?></option><?php endforeach; ?><?php if (!$crons): ?><option value="">Sem tarefas</option><?php endif; ?></select>
            <?php endif; ?>
            <input class="in" id="lg-q" type="search" placeholder="Procurar texto…" aria-label="Procurar">
            <select class="in" id="lg-n" aria-label="Linhas"><option>200</option><option selected>500</option><option>2000</option></select>
          </div></div>
        <div id="lg-body"><div class="empty">A carregar…</div></div>
        <div class="card-f" style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">
          <span class="mu" style="flex:1">Guardados durante <?= (int)($state['log_days'] ?? 90) ?> dias, rodados todos os dias e comprimidos.</span>
          <?php foreach (array_slice($lgFiles, 0, 8) as $lf): ?><a class="chip sm" href="?logs=dl&amp;site=<?= h(rawurlencode($lgSite)) ?>&amp;f=<?= h(rawurlencode($lf['n'])) ?>"><?= ic('download') ?><?= h($lf['n']) ?> <span class="mu"><?= h(fmt_bytes((float)$lf['s'])) ?></span></a><?php endforeach; ?>
          <?php if (count($lgFiles) > 8): ?><span class="mu">e mais <?= count($lgFiles) - 8 ?> ficheiros</span><?php endif; ?>
        </div>
      </section>
<?php endif; ?>

<?php elseif ($page === 'dns'):
    $dn = is_array($state['dns'] ?? null) ? $state['dns'] : ['enabled' => false];
    $dzs = is_array($dn['zones'] ?? null) ? $dn['zones'] : [];
    $dz = null; foreach ($dzs as $z) { if (($z['name'] ?? '') === qget('zone')) $dz = $z; }
?>
<?php if (empty($dn['enabled'])): ?>
      <section class="card">
        <div class="card-h"><div><h2>Ativar o DNS</h2><p>O servidor passa a responder pelo DNS dos domínios que indicares (NSD, só autoritativo: nunca faz resolução para terceiros).</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('dns_enable') ?>
          <div class="fgrid">
            <label class="fld">Nameserver 1<input class="in mono" name="ns1" required placeholder="ns1.host.iddigital.pt" autocomplete="off"></label>
            <label class="fld">Nameserver 2<input class="in mono" name="ns2" required placeholder="ns2.host.iddigital.pt" autocomplete="off"></label>
            <label class="fld">IP público do servidor<input class="in mono" name="ip" placeholder="vazio = detetar automaticamente" autocomplete="off"></label>
            <label class="fld">Email do responsável (SOA)<input class="in" type="email" name="hm" value="<?= h($srv['email'] ?? '') ?>" placeholder="dns@iddigital.pt"></label>
          </div>
          <div class="warnbox" style="margin-top:14px">Os dois nameservers vão apontar para este mesmo servidor: cumpre o mínimo exigido pelo .pt, mas não há redundância. Se o servidor parar, os domínios deixam de resolver (incluindo o email).</div>
          <div style="margin-top:16px"><button class="btn" type="submit">Instalar e ativar o DNS</button></div>
        </form>
      </section>
<?php else: ?>
      <section class="card">
        <div class="card-h"><div><h2>Servidor DNS</h2><p><span class="mono"><?= h($dn['ns1']) ?></span> e <span class="mono"><?= h($dn['ns2']) ?></span> → <span class="mono"><?= h($dn['ip']) ?></span><?= !empty($dn['ip6']) ? ' · <span class="mono">' . h($dn['ip6']) . '</span>' : '' ?></p></div>
          <span class="pill <?= !empty($dn['active']) ? 'p-ok' : 'p-err' ?>"><?= !empty($dn['active']) ? 'A correr' : 'Parado' ?></span></div>
        <div class="card-b mu">Para usar estes nameservers num domínio: (1) cria os registos A de <span class="mono"><?= h($dn['ns1']) ?></span> e <span class="mono"><?= h($dn['ns2']) ?></span> com o IP <span class="mono"><?= h($dn['ip']) ?></span> na zona onde esses nomes estão (ou como "glue records" no registador); (2) adiciona aqui a zona do domínio; (3) no registador, aponta os nameservers do domínio para os dois nomes acima.</div>
      </section>

      <?php if ($dz === null): ?>
      <section class="card">
        <div class="card-h"><div><h2>Zonas</h2><p>Os registos dos sites, do email e dos nameservers são criados e atualizados automaticamente.</p></div><button class="chip sm soft" type="button" data-open="dlg-dz-new">Adicionar zona</button></div>
        <?php if (!$dzs): ?><div class="empty"><b>Ainda não há zonas</b>Adiciona o primeiro domínio.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Domínio</th><th class="r">Registos</th><th>Série</th><th>Delegação</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($dzs as $z): $ck = is_array($z['check'] ?? null) ? $z['check'] : null; ?>
            <tr>
              <td class="first" data-label="Domínio"><a class="who" href="?p=dns&amp;zone=<?= h(rawurlencode($z['name'])) ?>" style="text-decoration:none;color:inherit"><span class="av <?= tone($z['name']) ?>"><?= ic('world') ?></span><span class="nm"><?= h($z['name']) ?></span></a></td>
              <td class="r" data-label="Registos"><?= count((array)$z['records']) + 3 ?></td>
              <td class="mono" data-label="Série"><?= h((string)$z['serial']) ?></td>
              <td data-label="Delegação"><?= $ck === null ? '<span class="pill p-off">Por verificar</span>' : (!empty($ck['delegated']) ? '<span class="pill p-ok">Aponta para aqui</span>' : '<span class="pill p-warn">Ainda não aponta</span>') ?></td>
              <td class="act r"><a class="btn sm sec" href="?p=dns&amp;zone=<?= h(rawurlencode($z['name'])) ?>">Gerir</a></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>
      <dialog id="dlg-dz-new"><form method="post"><?= act_fields('dns_zone_add') ?>
        <div class="dlg-h"><h3>Adicionar zona</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><label class="fld">Domínio<input class="in mono" name="zone" required placeholder="dominio.pt" autocomplete="off"><small>São criados os registos do domínio e do www, dos sites e do email que usem este domínio, e um CAA para o Let's Encrypt</small></label></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
      </form></dialog>

      <?php else: $ck = is_array($dz['check'] ?? null) ? $dz['check'] : null; ?>
      <section class="card">
        <div class="card-h"><div><nav class="crumbs fm-pre"><a href="?p=dns"><?= ic('home') ?>Zonas</a><span>›</span><b><?= h($dz['name']) ?></b></nav>
            <p style="margin-top:6px">Série <span class="mono"><?= h((string)$dz['serial']) ?></span> · <?= $ck === null ? 'delegação por verificar' : (!empty($ck['delegated']) ? 'a delegação aponta para este servidor' : 'a delegação ainda não aponta para aqui (encontrado: ' . h(trim((string)$ck['found']) ?: 'nada') . ')') ?></p></div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <form method="post"><?= act_fields('dns_check', ['zone' => (string)$dz['name']]) ?><button class="btn sm sec" type="submit">Verificar delegação</button></form>
            <form method="post"><?= act_fields('dns_sync', ['zone' => (string)$dz['name']]) ?><button class="btn sm sec" type="submit">Sincronizar</button></form>
            <button class="btn sm" type="button" data-open="dlg-dr-new">Novo registo</button>
          </div></div>
        <table class="list cards dnsrec">
          <thead><tr><th>Nome</th><th>Tipo</th><th>Valor</th><th class="r">TTL</th><th>Origem</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
            <tr><td class="first mono" data-label="Nome">@</td><td data-label="Tipo"><span class="pill p-off">NS</span></td><td class="mono" data-label="Valor"><?= h($dn['ns1']) ?>. · <?= h($dn['ns2']) ?>.</td><td class="r">3600</td><td><span class="mu">Servidor</span></td><td></td></tr>
            <?php $recs = (array)$dz['records']; usort($recs, function ($a, $b) { return [$a['name'] === '@' ? '' : $a['name'], $a['type']] <=> [$b['name'] === '@' ? '' : $b['name'], $b['type']]; }); [$pgList, $pgN, $pgPages, $pgTot] = paginate($recs, 100); foreach ($pgList as $r): ?>
            <tr>
              <td class="first mono" data-label="Nome"><?= h($r['name']) ?></td>
              <td data-label="Tipo"><span class="pill p-me"><?= h($r['type']) ?></span></td>
              <td data-label="Valor"><div class="dnsval mono"><?= (in_array($r['type'], ['MX', 'SRV'], true) ? (int)$r['prio'] . ' ' : '') . h($r['value']) ?></div></td>
              <td class="r" data-label="TTL"><?= (int)$r['ttl'] ?></td>
              <td data-label="Origem"><?= !empty($r['auto']) ? '<span class="pill p-ok">Automático</span>' : '<span class="mu">Manual</span>' ?></td>
              <td class="act r"><?php if (empty($r['auto'])): ?><form method="post" data-confirm="Apagar este registo?"><?= act_fields('dns_rec_del', ['zone' => (string)$dz['name'], 'id' => (string)$r['id']]) ?><button class="btn sm sec" type="submit">Apagar</button></form><?php endif; ?></td>
            </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'registos') ?></div><?php endif; ?>
        <form method="post" class="card-f" data-confirm="Apagar a zona <?= h($dz['name']) ?>? O domínio deixa de resolver neste servidor."><?= act_fields('dns_zone_del', ['zone' => (string)$dz['name']]) ?><span class="mu" style="margin-right:12px">Os registos automáticos atualizam-se sozinhos quando mudas sites ou email; os manuais mantêm-se.</span><button class="btn sm dan" type="submit">Apagar zona</button></form>
      </section>
      <dialog id="dlg-dr-new"><form method="post"><?= act_fields('dns_rec_add', ['zone' => (string)$dz['name']]) ?>
        <div class="dlg-h"><h3>Novo registo em <?= h($dz['name']) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b">
          <div class="fgrid">
            <label class="fld">Nome<input class="in mono" name="name" required placeholder="@ ou www ou loja" autocomplete="off"><small>@ = o próprio domínio</small></label>
            <label class="fld">Tipo<select class="in" name="type"><?php foreach (['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'SRV', 'CAA'] as $t): ?><option><?= $t ?></option><?php endforeach; ?></select></label>
          </div>
          <label class="fld">Valor<input class="in mono" name="value" required autocomplete="off" placeholder="91.209.16.24 · destino.dominio.pt · v=spf1 …"></label>
          <div class="fgrid">
            <label class="fld">TTL (segundos)<input class="in" name="ttl" inputmode="numeric" value="3600"></label>
            <label class="fld">Prioridade (MX/SRV)<input class="in" name="prio" inputmode="numeric" value="10"></label>
          </div>
        </div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
      </form></dialog>
      <?php endif; ?>
<?php endif; ?>

<?php elseif ($page === 'terminal'):
    $tOn = !empty($auth['totp']);
    $tSes = (is_array($_SESSION['term'] ?? null) && time() - (int)$_SESSION['term']['ts'] < 14400) ? (string)$_SESSION['term']['t'] : '';
    $recs = [];
    foreach ((array)glob(MP_TERM_LOG . '/*.log') as $rf) {
        $rid = basename((string)$rf, '.log'); if (!preg_match('/^\d{8}-\d{6}$/', $rid)) continue;
        $recs[] = ['id' => $rid, 's' => (int)@filesize((string)$rf), 'm' => (int)@filemtime((string)$rf)];
    }
    usort($recs, function ($a, $b) { return strcmp($b['id'], $a['id']); });
    $tz = tz_off(live_stats());
?>
<?php if (!$tOn): ?>
      <section class="card"><div class="empty"><b>O terminal exige a verificação em dois passos</b>Por segurança, o terminal (root) só fica disponível com o 2FA ativo.<br><a class="btn" href="?p=conta&amp;tfa=setup">Ativar a verificação em dois passos</a></div></section>
<?php elseif ($tSes === ''): ?>
      <section class="card">
        <div class="card-h"><div><h2>Abrir terminal</h2><p>Terminal do servidor como <b>root</b>, no browser. A sessão é gravada e fecha ao fim de 15 minutos sem atividade.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('terminal_open') ?>
          <div class="fgrid"><?= reauth_fields($auth) ?></div>
          <div style="margin-top:16px"><button class="btn" type="submit"><?= ic('code') ?>Abrir terminal</button></div>
        </form>
        <div class="card-f mu">Tudo o que aparecer no ecrã fica gravado durante 90 dias (as passwords escritas não aparecem no ecrã e por isso não ficam gravadas). A abertura fica também no registo de auditoria.</div>
      </section>
<?php else: ?>
      <section class="card term-card">
        <div class="card-h"><div><h2>Terminal (root)</h2><p>Sessão gravada · fecha com <span class="mono">exit</span> ou ao fim de 15 min sem atividade</p></div>
          <form method="post"><?= act_fields('terminal_close') ?><button class="btn sm dan" type="submit">Fechar terminal</button></form></div>
        <div class="term-wrap"><div class="term-wait" id="term-wait"><span class="spin"></span> A iniciar o terminal…</div><iframe id="term" title="Terminal" data-src="/terminal/<?= h($tSes) ?>/"></iframe></div>
      </section>
<?php endif; ?>
      <section class="card">
        <div class="card-h"><div><h2>Sessões gravadas</h2><p>Guardadas durante 90 dias em <span class="mono"><?= h(MP_TERM_LOG) ?></span>. O ficheiro de tempos permite rever a sessão com <span class="mono">scriptreplay</span>.</p></div></div>
        <?php if (!$recs): ?><div class="empty">Ainda não há sessões gravadas.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Início</th><th class="r">Tamanho</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach (array_slice($recs, 0, 100) as $r): $dt = DateTime::createFromFormat('Ymd-His', $r['id'], new DateTimeZone('UTC')); ?>
            <tr><td class="first mono" data-label="Início"><?= h($dt ? gmdate('d/m/Y H:i:s', $dt->getTimestamp() + $tz) : $r['id']) ?></td><td class="r" data-label="Tamanho"><?= h(fmt_bytes((float)$r['s'])) ?></td>
              <td class="act r"><a class="btn sm sec" href="?term=view&amp;id=<?= h($r['id']) ?>" target="_blank" rel="noopener">Ver</a> <a class="btn sm sec" href="?term=dl&amp;id=<?= h($r['id']) ?>">Descarregar</a> <a class="btn sm sec" href="?term=dl&amp;f=timing&amp;id=<?= h($r['id']) ?>" title="Para rever com: scriptreplay -t sessão.timing sessão.log">Tempos</a></td></tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'alertas'):
    $al = is_array($state['alerts'] ?? null) ? $state['alerts'] : [];
    $atab = in_array(qget('t'), ['config', 'historico', 'email'], true) ? qget('t') : 'config';
    $tza = tz_off(live_stats());
?>
      <nav class="tabs" aria-label="Secções">
        <?php foreach (['config' => 'Configuração', 'historico' => 'Histórico', 'email' => 'Volume de email'] as $tk => $tl): ?>
          <a class="chip<?= $atab === $tk ? ' prim' : '' ?>" href="?p=alertas&amp;t=<?= $tk ?>"><?= $tl ?></a>
        <?php endforeach; ?>
      </nav>
  <?php if ($atab === 'config'): ?>
      <form method="post">
      <?= act_fields('alerts_settings') ?>
      <div class="grid2e" style="align-items:stretch">
        <section class="card">
          <div class="card-h"><div><h2>SMS (bulksms.com)</h2><p>Credenciais em bulksms.com → Settings → API Tokens. Um alerta por problema, um aviso quando volta ao normal e um lembrete a cada 6 horas se continuar.</p></div><span class="pill <?= !empty($al['sms_on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($al['sms_on']) ? 'Ativo' : 'Desligado' ?></span></div>
          <div class="card-b">
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="sms"><option value="on"<?= !empty($al['sms_on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($al['sms_on']) ? ' selected' : '' ?>>Desligado</option></select></label>
              <label class="fld">Números<input class="in mono" name="sms_to" value="<?= h((string)($al['sms_to'] ?? '')) ?>" placeholder="+351912345678"><small>Formato internacional; vários separados por vírgulas</small></label>
              <label class="fld">Token ID<input class="in mono" name="sms_id" value="<?= h((string)($al['sms_id'] ?? '')) ?>" autocomplete="off"></label>
              <label class="fld">Token secreto<input class="in mono" type="password" name="sms_secret" autocomplete="new-password" placeholder="<?= !empty($al['sms_secret']) ? '•••••••• (guardado)' : '' ?>"><small><?= !empty($al['sms_secret']) ? 'Vazio = manter o atual' : 'Fica guardado só no servidor' ?></small></label>
            </div>
          </div>
        </section>
        <section class="card">
          <div class="card-h"><div><h2>Email</h2><p>Enviado pelo servidor de email deste servidor<?= empty($al['mail_on']) ? ' (o email não está ativo: ativa-o na página Email para usar este canal)' : '' ?>.</p></div><span class="pill <?= !empty($al['email_on']) && !empty($al['mail_on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($al['email_on']) && !empty($al['mail_on']) ? 'Ativo' : 'Desligado' ?></span></div>
          <div class="card-b">
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="email"><option value="on"<?= !empty($al['email_on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($al['email_on']) ? ' selected' : '' ?>>Desligado</option></select></label>
              <label class="fld">Enviar para<input class="in" type="email" name="email_to" value="<?= h((string)($al['email_to'] ?? '')) ?>" placeholder="alertas@iddigital.pt"></label>
            </div>
          </div>
        </section>
      </div>
      <section class="card">
        <div class="card-h"><div><h2>Limites</h2><p>Quando um limite é ultrapassado é enviado um alerta pelos canais ativos.</p></div></div>
        <div class="card-b">
          <div class="fgrid" style="grid-template-columns:repeat(4,minmax(0,1fr))">
            <label class="fld">CPU (%)<input class="in" name="cpu" inputmode="numeric" value="<?= (int)($al['cpu'] ?? 90) ?>"></label>
            <label class="fld">Durante (minutos)<input class="in" name="cpu_min" inputmode="numeric" value="<?= (int)($al['cpu_min'] ?? 5) ?>"></label>
            <label class="fld">RAM (%, durante 5 min)<input class="in" name="ram" inputmode="numeric" value="<?= (int)($al['ram'] ?? 90) ?>"></label>
            <label class="fld">Disco (%)<input class="in" name="disk" inputmode="numeric" value="<?= (int)($al['disk'] ?? 90) ?>"></label>
            <label class="fld">Ligações (% da capacidade)<input class="in" name="conn" inputmode="numeric" value="<?= (int)($al['conn'] ?? 70) ?>"></label>
            <label class="fld">Email acima do normal (%)<input class="in" name="mail_pct" inputmode="numeric" value="<?= (int)($al['mail_pct'] ?? 20) ?>"></label>
            <label class="fld">Mínimo (mensagens/hora)<input class="in" name="mail_min" inputmode="numeric" value="<?= (int)($al['mail_min'] ?? 50) ?>"><small>Evita alertas com volumes pequenos</small></label>
            <div class="fld" style="justify-content:flex-end"><span class="mu">O modo de proteção de ligações envia sempre alerta ao ativar e desativar.</span></div>
          </div>
          <div style="display:flex;gap:10px;margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </div>
      </section>
      </form>
      <form method="post" class="card" style="padding:18px 24px;display:flex;align-items:center;gap:14px;flex-wrap:wrap"><?= act_fields('alerts_test') ?><span class="grow mu">Depois de guardar, confirma que as mensagens chegam.</span><button class="btn sec" type="submit">Enviar mensagem de teste</button></form>

  <?php elseif ($atab === 'historico'):
      $hist = [];
      foreach (array_reverse(log_tail(MP_STATS . '/alerts.log', 2000)) as $ln) { $j = json_decode($ln, true); if (is_array($j)) $hist[] = $j; }
      [$hl, $hpg, $hpages, $htot] = paginate($hist, 50);
      $chan = function (string $v): string { return $v === 'ok' ? '<span class="pill p-ok">Enviado</span>' : ($v === 'falhou' ? '<span class="pill p-err">Falhou</span>' : '<span class="mu">—</span>'); };
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Histórico de alertas</h2><p>Últimos 2000 alertas.</p></div></div>
        <?php if (!$hist): ?><div class="empty">Ainda não houve alertas.</div><?php else: ?>
        <table class="list cards">
          <thead><tr><th>Data</th><th>Alerta</th><th>SMS</th><th>Email</th></tr></thead>
          <tbody><?php foreach ($hl as $a): ?>
            <tr><td class="first mono" data-label="Data"><?= h(gmdate('d/m/Y H:i', (int)$a['ts'] + $tza)) ?></td>
              <td data-label="Alerta"><span class="pill <?= ($a['level'] ?? '') === 'crit' ? 'p-err' : (($a['level'] ?? '') === 'ok' ? 'p-ok' : 'p-warn') ?>" style="margin-right:6px"><?= ($a['level'] ?? '') === 'crit' ? 'Alerta' : (($a['level'] ?? '') === 'ok' ? 'Resolvido' : 'Aviso') ?></span><?= h((string)($a['msg'] ?? '')) ?></td>
              <td data-label="SMS"><?= $chan((string)($a['sms'] ?? '')) ?></td><td data-label="Email"><?= $chan((string)($a['email'] ?? '')) ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <div class="card-f"><?= pager($hpg, $hpages, $htot, 'pg', 'alertas') ?></div>
        <?php endif; ?>
      </section>

  <?php else:
      $rows = [];
      foreach (log_tail(MP_STATS . '/mail-vol.csv', 1500) as $ln) { $p = explode(',', $ln); if (count($p) === 3 && ctype_digit($p[0])) $rows[] = [(int)$p[0], (int)$p[1], (int)$p[2]]; }
      $first = (int)($al['learn_start'] ?? 0); $days = (int)($al['learn_days'] ?? 0); $ready = $first > 0 && $days >= 30;
      $norm = [];
      foreach ($rows as $r) { if ($r[0] < time() - 30 * 86400) continue; $hd = intdiv($r[0] % 86400, 3600); $norm[$hd][0] = ($norm[$hd][0] ?? 0) + $r[1]; $norm[$hd][1] = ($norm[$hd][1] ?? 0) + $r[2]; $norm[$hd][2] = ($norm[$hd][2] ?? 0) + 1; }
      $last = array_slice(array_reverse($rows), 0, 24);
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Aprendizagem do volume de email</h2><p>Durante 30 dias o servidor só regista o email que entra e sai, hora a hora, para saber o que é normal. Depois disso, cada hora acima do normal em mais de <?= (int)($al['mail_pct'] ?? 20) ?>% (e com pelo menos <?= (int)($al['mail_min'] ?? 50) ?> mensagens a mais) dispara um alerta por SMS e email.</p></div>
          <span class="pill <?= $ready ? 'p-ok' : 'p-warn' ?>"><?= $ready ? 'A vigiar' : ($first ? 'A aprender: dia ' . min(30, $days + 1) . ' de 30' : 'À espera do primeiro registo') ?></span></div>
        <?php if (!$ready): ?><div class="card-b"><div class="cbar" style="height:10px"><span style="width:<?= (int)min(100, $days * 100 / 30) ?>%"></span></div><p class="mu" style="margin:8px 0 0"><?= empty($al['mail_on']) ? 'O email deste servidor não está ativo; o registo começa quando for ativado.' : 'Faltam ' . max(0, 30 - $days) . ' dias para os alertas de volume ficarem ativos.' ?></p></div><?php endif; ?>
        <?php if ($last): ?>
        <table class="list cards">
          <thead><tr><th>Hora</th><th class="r">Recebidos</th><th class="r">Normal</th><th class="r">Enviados</th><th class="r">Normal</th></tr></thead>
          <tbody><?php foreach ($last as $r): $hd = intdiv($r[0] % 86400, 3600); $n = $norm[$hd] ?? [0, 0, 1]; $ni = $n[0] / max(1, $n[2]); $no = $n[1] / max(1, $n[2]);
            $hiI = $ready && $r[1] > $ni * (1 + ($al['mail_pct'] ?? 20) / 100) && $r[1] - $ni >= ($al['mail_min'] ?? 50); $hiO = $ready && $r[2] > $no * (1 + ($al['mail_pct'] ?? 20) / 100) && $r[2] - $no >= ($al['mail_min'] ?? 50); ?>
            <tr><td class="first mono" data-label="Hora"><?= h(gmdate('d/m H:00', $r[0] + $tza)) ?></td>
              <td class="r" data-label="Recebidos"><b style="<?= $hiI ? 'color:var(--err)' : '' ?>"><?= $r[1] ?></b></td><td class="r mu" data-label="Normal"><?= $ready ? (int)round($ni) : '—' ?></td>
              <td class="r" data-label="Enviados"><b style="<?= $hiO ? 'color:var(--err)' : '' ?>"><?= $r[2] ?></b></td><td class="r mu" data-label="Normal"><?= $ready ? (int)round($no) : '—' ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <?php endif; ?>
      </section>
  <?php endif; ?>

<?php elseif ($page === 'processos'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Quem está a consumir recursos</h2><p>CPU e memória por origem: cada site, email, base de dados, servidor web, painel e sistema. Atualiza a cada 10 segundos.</p></div></div>
        <div id="pr-sum" class="pr-sum"><div class="empty">A carregar…</div></div>
      </section>
      <section class="card" id="pr">
        <div class="card-h"><div><h2>Processos</h2><p>CPU atual (100% = um núcleo inteiro). Os processos essenciais do servidor e do painel não podem ser terminados aqui.</p></div>
          <div class="lg-filters">
            <select class="in" id="pr-f" aria-label="Origem"><option value="">Todas as origens</option><option value="site">Sites</option><option value="email">Email</option><option value="bd">Base de dados</option><option value="web">Servidor web</option><option value="painel">Painel</option><option value="sistema">Sistema</option></select>
            <input class="in" id="pr-q" type="search" placeholder="Procurar…" title="Comando, utilizador, PID ou site" aria-label="Procurar" style="min-width:220px">
          </div></div>
        <table class="list cards">
          <thead><tr><th>PID</th><th>Origem</th><th class="r">CPU</th><th class="r">Memória</th><th>Há</th><th>Comando</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody id="pr-rows"><tr><td colspan="7" class="empty">A carregar…</td></tr></tbody>
        </table>
        <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span class="mu" id="pr-foot" style="flex:1"></span><nav class="pager" id="pr-pager"></nav></div>
      </section>
      <dialog id="dlg-kill"><form method="post"><?= act_fields('proc_kill') ?><input type="hidden" name="pid" id="kill-pid">
        <div class="dlg-h"><h3>Terminar processo <span id="kill-t" class="mono"></span></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><p class="mono" id="kill-cmd" style="margin:0;word-break:break-all"></p>
          <label class="chk"><input type="checkbox" name="force" value="1"> Forçar (SIGKILL: termina de imediato, sem deixar o processo arrumar; usa só se não terminar normalmente)</label>
          <div id="kill-site"></div></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Terminar</button></div>
      </form></dialog>
      <form method="post" id="kill-site-f" style="display:none" data-confirm=""><?= act_fields('proc_kill_site') ?><input type="hidden" name="site" id="kill-site-n"></form>

<?php elseif ($page === 'sentinela'):
    $sn = jload(MP_STATS . '/sentinel.json') ?? [];
    $snR = is_array($sn['results'] ?? null) ? $sn['results'] : [];
    $snst = jload(MP_STATS . '/sentinel-state.json') ?? [];
    $stab = in_array(qget('t'), ['estado', 'incidentes', 'disponibilidade', 'config'], true) ? qget('t') : 'estado';
    $tzs = tz_off(live_stats());
    $cnt = ['ok' => 0, 'warn' => 0, 'fail' => 0]; foreach ($snR as $r) $cnt[$r['status']] = ($cnt[$r['status']] ?? 0) + 1;
    $snAge = time() - (int)($sn['ts'] ?? 0);
    $snOff = (string)($state['sentinel']['off'] ?? '');
?>
      <nav class="tabs" aria-label="Secções">
        <?php foreach (['estado' => 'Estado', 'incidentes' => 'Incidentes', 'disponibilidade' => 'Disponibilidade', 'config' => 'Configuração'] as $tk => $tl): ?><a class="chip<?= $stab === $tk ? ' prim' : '' ?>" href="?p=sentinela&amp;t=<?= $tk ?>"><?= $tl ?></a><?php endforeach; ?>
        <form method="post" style="margin-left:auto"><?= act_fields('sentinel_run') ?><button class="btn sm sec" type="submit"><?= ic('reload') ?>Testar agora</button></form>
      </nav>
  <?php if ($stab === 'estado'): ?>
      <section class="stats">
        <div class="stat"><span class="tile t-acc"><?= ic('check') ?></span><div><div class="k">Testes OK</div><div class="v"><?= $cnt['ok'] ?></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('bell') ?></span><div><div class="k">Avisos</div><div class="v"><?= $cnt['warn'] ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('ban') ?></span><div><div class="k">Falhas</div><div class="v" style="<?= $cnt['fail'] ? 'color:var(--err)' : '' ?>"><?= $cnt['fail'] ?></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('clock') ?></span><div><div class="k">Último teste</div><div class="v" style="font-size:17px"><?= empty($sn['ts']) ? 'Nunca' : ($snAge < 120 ? 'há ' . $snAge . ' s' : '<span style="color:var(--err)">há ' . (int)round($snAge / 60) . ' min</span>') ?></div></div></div>
      </section>
      <?php if (!$snR): ?><section class="card"><div class="empty"><b>O sentinela ainda não correu</b>Corre sozinho a cada minuto. Usa "Testar agora" para o primeiro teste.</div></section><?php endif; ?>
      <?php $groups = []; foreach ($snR as $r) $groups[$r['group']][] = $r;
        $order = ['Serviços', 'Sites', 'Email', 'DNS', 'Certificados', 'Sistema', 'Painel']; $opos = function ($g) use ($order) { $i = array_search($g, $order, true); return $i === false ? 99 : $i; }; uksort($groups, function ($a, $b) use ($opos) { return $opos($a) <=> $opos($b); }); ?>
      <div class="sn-grid">
      <?php foreach ($groups as $g => $rs): $bad = count(array_filter($rs, function ($r) { return $r['status'] !== 'ok'; })); ?>
        <section class="card">
          <div class="card-h"><div><h2><?= h($g) ?></h2></div><span class="pill <?= $bad ? 'p-err' : 'p-ok' ?>"><?= $bad ? $bad . ' com problemas' : 'Tudo OK' ?></span></div>
          <div class="row-list">
          <?php usort($rs, function ($a, $b) { $w = ['fail' => 0, 'warn' => 1, 'ok' => 2]; return [$w[$a['status']] ?? 3, $a['name']] <=> [$w[$b['status']] ?? 3, $b['name']]; }); foreach ($rs as $r): $since = (int)($snst[$r['id']]['since'] ?? 0); ?>
            <div class="item"><span class="sn-dot sn-<?= h($r['status']) ?>" aria-hidden="true"></span>
              <div class="grow"><div class="nm"><?= h($r['name']) ?><?= !empty($r['repaired']) ? ' <span class="pill p-me">reparado</span>' : '' ?></div><div class="mu"><?= h($r['msg']) ?><?= $r['status'] !== 'ok' && $since ? ' · desde ' . h(gmdate('d/m H:i', $since + $tzs)) : '' ?></div></div></div>
          <?php endforeach; ?>
          </div>
        </section>
      <?php endforeach; ?>
      </div>
      <?php if ($snR): ?><p class="mu" style="margin:0">Teste completo em <?= (int)($sn['took'] ?? 0) ?> s · reparação automática <?= !empty($sn['repair']) ? 'ativa (até 3 vezes por hora por serviço)' : 'desligada' ?>.</p><?php endif; ?>

  <?php elseif ($stab === 'incidentes'):
      $incs = []; foreach (array_reverse(log_tail(MP_STATS . '/sentinel-incidents.log', 5000)) as $ln) { $j = json_decode($ln, true); if (is_array($j)) $incs[] = $j; }
      foreach ($snst as $id => $s0) { if (($s0['status'] ?? 'ok') !== 'ok') { $nm = $id; foreach ($snR as $r) if ($r['id'] === $id) $nm = $r['name']; array_unshift($incs, ['id' => $id, 'name' => $nm, 'start' => (int)$s0['since'], 'end' => 0, 'msg' => (string)$s0['msg'], 'repaired' => false]); } }
      [$il, $ipg, $ipages, $itot] = paginate($incs, 50);
      $dur = function (int $s): string { return $s >= 86400 ? round($s / 86400, 1) . ' d' : ($s >= 3600 ? round($s / 3600, 1) . ' h' : max(1, (int)round($s / 60)) . ' min'); };
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Incidentes</h2><p>Cada falha detetada: quando começou, quanto durou e se foi reparada automaticamente.</p></div></div>
        <?php if (!$incs): ?><div class="empty">Sem incidentes registados.</div><?php else: ?>
        <table class="list cards">
          <thead><tr><th>Início</th><th>Teste</th><th>O que aconteceu</th><th>Duração</th><th>Resultado</th></tr></thead>
          <tbody><?php foreach ($il as $i): ?>
            <tr><td class="first mono" data-label="Início"><?= h(gmdate('d/m/Y H:i', (int)$i['start'] + $tzs)) ?></td><td data-label="Teste"><b><?= h((string)$i['name']) ?></b></td><td class="mu" data-label="O que aconteceu"><?= h((string)$i['msg']) ?></td>
              <td data-label="Duração"><?= empty($i['end']) ? '<span class="pill p-err">a decorrer · ' . h($dur(time() - (int)$i['start'])) . '</span>' : h(!empty($i['repaired']) ? '—' : $dur((int)$i['end'] - (int)$i['start'])) ?></td>
              <td data-label="Resultado"><?= empty($i['end']) ? '<span class="pill p-err">Em falha</span>' : (!empty($i['repaired']) ? '<span class="pill p-me">Reparado sozinho</span>' : '<span class="pill p-ok">Resolvido</span>') ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <div class="card-f"><?= pager($ipg, $ipages, $itot, 'pg', 'incidentes') ?></div>
        <?php endif; ?>
      </section>

  <?php elseif ($stab === 'disponibilidade'):
      $av = jload(MP_STATS . '/sentinel-avail.json') ?? []; $names0 = []; foreach ($snR as $r) $names0[$r['id']] = [$r['name'], $r['group']];
      $days = []; for ($d = 29; $d >= 0; $d--) $days[] = gmdate('Ymd', time() - $d * 86400);
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Disponibilidade nos últimos 30 dias</h2><p>Percentagem de testes sem falha, por dia. Os avisos contam como disponível.</p></div></div>
        <?php if (!$av): ?><div class="empty">Ainda sem dados.</div><?php else: ?>
        <div class="sn-av">
        <?php ksort($av); foreach ($av as $id => $byDay): if (!isset($names0[$id])) continue; $ok = 0; $tot = 0; foreach ($byDay as $c) { $ok += (int)$c[0]; $tot += (int)$c[1]; } $pc = $tot ? $ok * 100 / $tot : 100; ?>
          <div class="sn-row"><div class="sn-n"><b><?= h($names0[$id][0]) ?></b><span class="mu"><?= h($names0[$id][1]) ?></span></div>
            <div class="sn-days"><?php foreach ($days as $d): $c = $byDay[$d] ?? null; $p = $c && $c[1] ? $c[0] * 100 / $c[1] : null; ?><i class="<?= $p === null ? 'n' : ($p >= 99.9 ? 'g' : ($p >= 98 ? 'y' : 'r')) ?>" title="<?= h(substr($d, 6, 2) . '/' . substr($d, 4, 2)) ?>: <?= $p === null ? 'sem dados' : number_format($p, 2, ',', '') . '%' ?>"></i><?php endforeach; ?></div>
            <b class="sn-pc" style="<?= $pc < 99 ? 'color:var(--err)' : '' ?>"><?= number_format($pc, 2, ',', '') ?>%</b></div>
        <?php endforeach; ?>
        </div><?php endif; ?>
      </section>

  <?php else: $scfg = (array)($state['sentinel'] ?? []); ?>
      <section class="card">
        <div class="card-h"><div><h2>Configuração do sentinela</h2><p>Testa todos os serviços a cada minuto. As falhas e as reparações são enviadas pelos canais de Alertas (SMS e email).</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('sentinel_settings') ?>
          <div class="fgrid">
            <label class="fld">Reparação automática<select class="in" name="repair"><option value="on"<?= !isset($scfg['repair']) || !empty($scfg['repair']) ? ' selected' : '' ?>>Ativa: reinicia o serviço em falha (até 3 vezes por hora)</option><option value="off"<?= isset($scfg['repair']) && empty($scfg['repair']) ? ' selected' : '' ?>>Desligada: só alerta</option></select></label>
            <label class="fld">Testar a página inicial dos sites<select class="in" name="sites"><option value="on"<?= !isset($scfg['sites']) || !empty($scfg['sites']) ? ' selected' : '' ?>>Sim (deteta erros 5xx da aplicação)</option><option value="off"<?= isset($scfg['sites']) && empty($scfg['sites']) ? ' selected' : '' ?>>Não (só o PHP de cada site)</option></select></label>
          </div>
          <?php if ($snR): ?><p class="mu" style="margin:16px 0 8px">Testes ativos (desmarca os que não queres que sejam feitos):</p>
          <div class="sn-chk"><?php foreach ($snR as $r): ?><label class="chk"><input type="checkbox" name="on[]" value="<?= h($r['id']) ?>"<?= strpos(' ' . $snOff . ' ', ' ' . $r['id'] . ' ') === false ? ' checked' : '' ?>> <?= h($r['group'] . ': ' . $r['name']) ?></label><?php endforeach; ?>
            <?php foreach (array_filter(explode(' ', $snOff)) as $oid): ?><label class="chk"><input type="checkbox" name="on[]" value="<?= h($oid) ?>"> <?= h($oid) ?> <span class="mu">(desligado)</span></label><?php endforeach; ?></div>
          <input type="hidden" name="all" value="<?= h(implode(' ', array_unique(array_merge(array_column($snR, 'id'), array_filter(explode(' ', $snOff)))))) ?>"><?php endif; ?>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>
  <?php endif; ?>

<?php elseif ($page === 'auditoria'):
    $alog = [];
    $af = MP_DATA . '/logs/audit.log';
    if (is_file($af)) {
        $sz = (int)filesize($af); $fh = @fopen($af, 'r');
        if ($fh) { if ($sz > 2000000) fseek($fh, $sz - 2000000); $buf = (string)stream_get_contents($fh); fclose($fh);
            foreach (array_slice(array_reverse(array_filter(explode("\n", $buf))), 0, 1000) as $ln) { $j = json_decode($ln, true); if (is_array($j)) $alog[] = $j; } }
    }
    $tza = tz_off(live_stats());
?>
      <section class="card">
        <div class="card-h"><div><h2>Registo de auditoria</h2><p>Inícios de sessão e todas as ações feitas no painel, com data, utilizador e IP.</p></div>
          <input class="in cn-search" id="au-q" type="search" placeholder="Filtrar (ação, IP, utilizador)…" aria-label="Filtrar registo" autocomplete="off"></div>
        <?php if (!$alog): ?>
          <div class="empty">Ainda não há registos.</div>
        <?php else: ?>
        <table class="list cards" id="au-t">
          <thead><tr><th>Data</th><th>Utilizador</th><th>IP</th><th>Ação</th><th>Resultado</th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($alog, 100); foreach ($pgList as $e): ?>
            <tr>
              <td class="first" data-label="Data"><span class="mono"><?= h(gmdate('d/m/Y H:i:s', (int)($e['ts'] ?? 0) + $tza)) ?></span></td>
              <td data-label="Utilizador"><?= h($e['user'] ?? '') ?></td>
              <td data-label="IP" class="mono"><?= h($e['ip'] ?? '') ?></td>
              <td data-label="Ação"><?= h($e['action'] ?? '') ?></td>
              <td data-label="Resultado"><span class="pill <?= !empty($e['ok']) ? 'p-ok' : 'p-err' ?>"><?= !empty($e['ok']) ? 'OK' : 'Falhou' ?></span></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'registos') ?></div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">Mostra os últimos 1000 registos. O ficheiro completo está em /var/lib/minipainel/logs/audit.log e é rodado semanalmente (8 semanas).</div>
      </section>

<?php elseif ($page === 'servicos'): ?>
      <section class="card">
        <?php if (!$svcs): ?>
          <div class="empty">Sem informação dos serviços.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Serviço</th><th>Estado</th><th>Utilização</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($svcs as $s): $on = !empty($s['active']); ?>
            <tr>
              <td class="first" data-label="Serviço"><div class="who"><span class="av <?= $on ? 't-acc' : 't-warn' ?>"><?= ic(($s['id'] ?? '') === 'mariadb' ? 'db' : ((($s['id'] ?? '') === 'nginx') ? 'world' : 'code')) ?></span><div><div class="nm"><?= h($s['name'] ?? '') ?></div><div class="mu mono"><?= h($s['unit'] ?? '') ?></div></div></div></td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-err' ?>"><?= $on ? 'Ativo' : 'Parado' ?></span></td>
              <td data-label="Utilização" class="mu"><?= h(svc_usage($s, $bySite)) ?></td>
              <td data-label="Ações"><?= svc_actions($s, $bySite) ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">Recarregar aplica configurações sem cortar ligações. Antes de cada ação a configuração é testada; se tiver erros, nada é alterado. Os serviços arrancam sozinhos quando o servidor reinicia.</div>
      </section>

<?php else:
    $has2fa = !empty($auth['totp']);
    $tfaNew = '';
    if (!$has2fa && qget('tfa') === 'setup') {
        if (empty($_SESSION['totp_new'])) $_SESSION['totp_new'] = b32_encode(random_bytes(20));
        $tfaNew = (string)$_SESSION['totp_new'];
    }
?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Utilizador</h2><p>Nome usado para iniciar sessão no painel.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('acct_user') ?>
          <div class="fgrid">
            <label class="fld">Novo nome de utilizador<input class="in" name="newuser" required pattern="[a-z][a-z0-9._\-]{2,31}" value="<?= h($_SESSION['user']) ?>" autocomplete="off"><small>3 a 32 caracteres; evita nomes óbvios como admin</small></label>
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Mudar nome</button></div>
        </form>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Verificação em dois passos</h2><p>Pede um código de uma aplicação (Google Authenticator, Microsoft Authenticator, 1Password, Bitwarden…) depois da password.</p></div><span class="pill <?= $has2fa ? 'p-ok' : 'p-off' ?>"><?= $has2fa ? 'Ativa' : 'Desativada' ?></span></div>
        <?php if ($has2fa): ?>
        <form method="post" class="card-b">
          <?= act_fields('totp_disable') ?>
          <div class="fgrid">
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
            <label class="fld">Código atual<input class="in mono" name="code" required inputmode="numeric" autocomplete="one-time-code" maxlength="14"></label>
          </div>
          <div style="margin-top:16px"><button class="btn dan" type="submit">Desativar</button></div>
        </form>
        <?php elseif ($tfaNew !== ''): $uri = 'otpauth://totp/' . rawurlencode('IDDigital Hosting:' . $_SESSION['user'] . '@' . ($sys['hostname'] ?? 'servidor')) . '?secret=' . $tfaNew . '&issuer=' . rawurlencode('IDDigital Hosting') . '&digits=6&period=30'; ?>
        <form method="post" class="card-b tfa">
          <?= act_fields('totp_enable') ?>
          <div class="tfa-qr" id="tfa-qr" data-uri="<?= h($uri) ?>"></div>
          <div class="tfa-side">
            <p style="margin:0">1. Lê o código QR com a aplicação, ou introduz a chave manualmente:</p>
            <div class="mono tfa-key"><?= h(trim(chunk_split($tfaNew, 4, ' '))) ?></div>
            <label class="fld">2. Código de 6 dígitos mostrado na aplicação<input class="in mono" name="code" required inputmode="numeric" autocomplete="one-time-code" maxlength="6" autofocus></label>
            <div style="display:flex;gap:8px"><button class="btn" type="submit">Ativar</button><a class="btn sec" href="?p=conta">Cancelar</a></div>
          </div>
        </form>
        <?php else: ?>
        <div class="card-b"><a class="btn" href="?p=conta&amp;tfa=setup">Ativar verificação em dois passos</a></div>
        <?php endif; ?>
        <div class="card-f mu">Ao ativar recebes 8 códigos de recuperação. Se perderes o telemóvel e os códigos, desativa na consola do servidor: <span class="mono">mpanel panel-2fa off</span></div>
      </section>
      </div>

      <section class="card" style="max-width:none">
        <div class="card-h"><h2>Password do painel</h2><p>Utilizador: <?= h($_SESSION['user']) ?></p></div>
        <form method="post" class="card-b">
          <?= act_fields('conta_pass') ?>
          <div class="fgrid" style="grid-template-columns:repeat(auto-fit,minmax(220px,1fr))">
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
            <label class="fld">Nova password<input class="in" type="password" name="nova" required minlength="10" autocomplete="new-password"><small>Mínimo 10 caracteres</small></label>
            <label class="fld">Repetir nova password<input class="in" type="password" name="repetir" required minlength="10" autocomplete="new-password"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Alterar password</button></div>
        </form>
        <div class="card-f mu">No servidor também podes usar <span class="mono">mpanel passwd</span>.</div>
      </section>
<?php endif; ?>
    </main>
  </div>
</div>

<!-- Novo site -->
<dialog class="drawer" id="dlg-site-new" aria-labelledby="t-site-new">
  <form method="post">
    <?= act_fields('site_add') ?>
    <div class="dlg-h"><div><h3 id="t-site-new">Novo site</h3><p>Fica acessível em http://IP:porta e http://localhost:porta.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Nome<input class="in" name="site" required maxlength="24" pattern="[a-z][a-z0-9\-]{0,23}" placeholder="loja" autocomplete="off"><small>Minúsculas, números e "-", a começar por letra</small></label>
      <div class="fgrid">
        <label class="fld">Porta<input class="in" name="port" inputmode="numeric" pattern="[0-9]{1,5}" placeholder="automática" autocomplete="off"><small>Vazio = próxima livre a partir de 8001</small></label>
        <label class="fld">Versão de PHP<select class="in" name="php"><?= php_options($phps, $defPhp) ?></select></label>
      </div>
      <div class="fsec">Domínio<?= $isNet ? '' : ' (opcional)' ?></div>
      <div class="fgrid">
        <label class="fld">Domínios<input class="in mono" name="domains" placeholder="loja.pt www.loja.pt" autocomplete="off"><small>Separados por espaço; vazio = só por porta</small></label>
        <label class="fld">Certificado SSL<select class="in" name="ssl"><option value="le"<?= $isNet ? ' selected' : '' ?>>Let's Encrypt</option><option value="self">Autoassinado</option><option value="none"<?= $isNet ? '' : ' selected' ?>>Sem SSL</option></select></label>
      </div>
      <div class="fsec">Limites do PHP</div>
      <?= limit_fields(LIMIT_DEFAULTS + ['display_errors' => false]) ?>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar site</button></div>
  </form>
</dialog>

<!-- Nova base de dados -->
<dialog class="drawer" id="dlg-db-new" aria-labelledby="t-db-new">
  <form method="post">
    <?= act_fields('db_add') ?>
    <div class="dlg-h"><div><h3 id="t-db-new">Nova base de dados</h3><p>O utilizador é criado com o mesmo nome.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Nome<input class="in mono" name="db" required maxlength="32" pattern="[a-z][a-z0-9_]{0,31}" placeholder="loja_db" autocomplete="off"><small>Minúsculas, números e "_", a começar por letra</small></label>
      <label class="fld">Password<input class="in" name="pw" type="password" maxlength="64" autocomplete="new-password"><small>Vazio = gerada automaticamente e mostrada no fim</small></label>
      <label class="fld">Site associado<select class="in" name="site"><option value="">Nenhum</option><?php foreach ($sites as $ss): $ssn = (string)$ss['name']; ?><option value="<?= h($ssn) ?>"><?= h($ssn) ?></option><?php endforeach; ?></select><small>Entra nos backups do site e é reposta com ele</small></label>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar base de dados</button></div>
  </form>
</dialog>

<?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); if (!valid_site($n)) continue; $L = site_limits($s); ?>
<dialog class="drawer" id="dlg-perf-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_perf', ['site' => $n]) ?>
    <?php $pf = is_array($s['perf'] ?? null) ? $s['perf'] : ['cache' => 0, 'pm' => 'ondemand', 'maxch' => 10, 'slow' => 5]; ?>
    <div class="dlg-h"><div><h3>Desempenho de <?= h($n) ?></h3><p>Cache de página, processos PHP e registo de scripts lentos.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Cache de página<select class="in" name="cache">
        <?php foreach (['0' => 'Desligada', '60' => '1 minuto', '300' => '5 minutos', '600' => '10 minutos', '1800' => '30 minutos', '3600' => '1 hora'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)$pf['cache'] === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?>
      </select><small>As páginas ficam guardadas e são servidas sem executar o PHP. Nunca entram em cache: sessões iniciadas, carrinhos, checkout, áreas de cliente e de administração, formulários (POST).</small></label>
      <div class="fgrid">
        <label class="fld">Processos PHP<select class="in" name="pm"><option value="ondemand"<?= $pf['pm'] !== 'dynamic' ? ' selected' : '' ?>>A pedido (poupa memória)</option><option value="dynamic"<?= $pf['pm'] === 'dynamic' ? ' selected' : '' ?>>Sempre prontos (mais rápido)</option></select><small>"Sempre prontos" evita o atraso da primeira visita depois de uma pausa</small></label>
        <label class="fld">Máximo de processos<input class="in" name="maxch" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pf['maxch'] ?>"><small>Visitas atendidas em simultâneo (cada processo usa até ao limite de memória do site)</small></label>
      </div>
      <label class="fld">Registar scripts lentos<select class="in" name="slow">
        <?php foreach (['0' => 'Não registar', '1' => 'Acima de 1 segundo', '3' => 'Acima de 3 segundos', '5' => 'Acima de 5 segundos', '10' => 'Acima de 10 segundos'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)$pf['slow'] === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?>
      </select><small>Mostra o ficheiro e a função que estava a correr quando o pedido demorou (Logs → PHP lento)</small></label>
      <h4 class="dlg-sec">Redis (cache de objetos)</h4>
      <div class="fgrid">
        <label class="fld">Redis do site<select class="in" name="redis"><option value="off"<?= empty($pf['redis']) ? ' selected' : '' ?>>Desligado</option><option value="on"<?= !empty($pf['redis']) ? ' selected' : '' ?>>Ligado</option></select></label>
        <label class="fld">Memória<select class="in" name="redis_mb"><?php foreach ([32, 64, 128, 256, 512, 1024] as $mb): ?><option value="<?= $mb ?>"<?= (int)($pf['redis_mb'] ?? 128) === $mb ? ' selected' : '' ?>><?= $mb ?> MB</option><?php endforeach; ?></select></label>
      </div>
      <?php if (!empty($pf['redis'])): ?><div class="infobox"><b>Ligação:</b> socket <span class="mono"><?= h((string)$pf['sock']) ?></span> (sem password; só este site lhe chega).<br>
        <b>WordPress</b> (plugin "Redis Object Cache"), no <span class="mono">wp-config.php</span>:<br><span class="mono">define('WP_REDIS_SCHEME', 'unix');<br>define('WP_REDIS_PATH', '<?= h((string)$pf['sock']) ?>');</span><br>
        <b>PrestaShop / OpenCart / outros:</b> no módulo ou na configuração de cache, Redis com o caminho da socket acima.</div><?php else: ?><small class="mu">Guarda em memória as consultas repetidas da aplicação (WordPress, WooCommerce, PrestaShop…). Cada site tem o seu Redis, isolado dos outros.</small><?php endif; ?>
      <h4 class="dlg-sec">Ficheiros estáticos</h4>
      <div class="fgrid">
        <label class="fld">Cache no browser<select class="in" name="static_days"><?php foreach (['0' => 'Desligada', '7' => '7 dias', '30' => '30 dias', '365' => '1 ano'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)($pf['static_days'] ?? 30) === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?></select><small>Imagens, CSS, JS e fontes não voltam a ser descarregados por quem regressa ao site</small></label>
        <label class="fld">WebP automático<select class="in" name="webp"><option value="on"<?= !empty($pf['webp']) ? ' selected' : '' ?>>Sim</option><option value="off"<?= empty($pf['webp']) ? ' selected' : '' ?>>Não</option></select><small>Se existir imagem.jpg.webp, é entregue aos browsers que o suportam</small></label>
      </div>
      <label class="chk"><input type="checkbox" name="webp_auto" value="1"<?= !empty($pf['webp_auto']) ? ' checked' : '' ?>> Converter as imagens novas em WebP todas as noites</label>
    </div>
    <div class="dlg-f">
      <div style="margin-right:auto;display:flex;gap:8px;flex-wrap:wrap"><?php if ((int)$pf['cache'] > 0): ?><button class="btn sec" type="submit" form="cache-purge-<?= h($n) ?>">Limpar cache</button><?php endif; ?><button class="btn sec" type="submit" form="webp-now-<?= h($n) ?>" title="Converte todas as imagens JPG e PNG do site (pode demorar)">Converter imagens</button></div>
      <button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button>
    </div>
  </form>
</dialog>
<form method="post" id="cache-purge-<?= h($n) ?>" style="display:none"><?= act_fields('cache_purge', ['site' => $n]) ?></form>
<form method="post" id="webp-now-<?= h($n) ?>" style="display:none"><?= act_fields('site_webp', ['site' => $n]) ?></form>
<dialog class="drawer" id="dlg-ftp-<?= h($n) ?>">
  <form method="post" autocomplete="off">
    <?= act_fields('site_ftp', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Acesso FTP/SFTP de <?= h($n) ?></h3><p>Uma conta com acesso à pasta do site; a mesma password serve para FTPS e SFTP.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <div class="kv"><span>Estado</span><b><?= !empty($s['ftp']) ? '<span class="pill p-ok">Ativo</span>' : '<span class="pill p-off">Desativado</span>' ?></b></div>
      <div class="kv"><span>Servidor</span><b class="mono"><?= h($host) ?></b></div>
      <div class="kv"><span>FTPS (porta 21, TLS explícito)</span><b class="mono"><?= h($n) ?></b></div>
      <div class="kv"><span>SFTP (porta 22)</span><b class="mono">mp_<?= h($n) ?></b></div>
      <label class="fld" style="margin-top:6px"><?= !empty($s['ftp']) ? 'Nova password' : 'Password' ?><input class="in" type="password" name="pw" minlength="10" autocomplete="new-password"><small>Vazio = gerada e mostrada no fim</small></label>
      <p class="mu" style="margin:0">Ao entrar, a conta fica limitada à pasta <span class="mono">/srv/www/<?= h($n) ?></span> (public_html, logs, tmp). Os ficheiros enviados ficam com o dono do site. Ao fim de várias passwords erradas, o IP é bloqueado.</p>
    </div>
    <div class="dlg-f">
      <?php if (!empty($s['ftp'])): ?><button class="btn sec dan" type="submit" form="ftp-off-<?= h($n) ?>" style="margin-right:auto">Desativar</button><?php endif; ?>
      <button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit"><?= !empty($s['ftp']) ? 'Mudar password' : 'Ativar acesso' ?></button>
    </div>
  </form>
</dialog>
<form method="post" id="ftp-off-<?= h($n) ?>" data-confirm="Desativar o acesso FTP/SFTP de <?= h($n) ?>?" style="display:none"><?= act_fields('site_ftp', ['site' => $n, 'off' => '1']) ?></form>
<dialog class="drawer" id="dlg-dom-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_domains', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Domínios e SSL de <?= h($n) ?></h3><p>O site continua acessível pela porta <?= (int)($s['port'] ?? 0) ?>.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Domínios<textarea class="in mono cron-ta" name="domains" rows="4" placeholder="loja.pt&#10;www.loja.pt" spellcheck="false"><?= h(str_replace(' ', "\n", (string)($s['domains'] ?? ''))) ?></textarea><small>Um por linha. Cada domínio tem de apontar (DNS) para este servidor.</small></label>
      <div class="fgrid">
        <label class="fld">Certificado SSL<select class="in" name="ssl"><?php $cs = (string)($s['ssl'] ?? 'none'); ?><option value="le"<?= $cs === 'le' ? ' selected' : '' ?>>Let's Encrypt</option><option value="self"<?= $cs === 'self' ? ' selected' : '' ?>>Autoassinado (LAN)</option><option value="none"<?= $cs === 'none' ? ' selected' : '' ?>>Sem SSL</option></select></label>
        <label class="fld">Endereço principal<select class="in" name="www"><?php $cw = (string)($s['www'] ?? 'keep'); ?><option value="keep"<?= $cw === 'keep' ? ' selected' : '' ?>>Aceitar todos como estão</option><option value="root"<?= $cw === 'root' ? ' selected' : '' ?>>Redirecionar para sem www</option><option value="www"<?= $cw === 'www' ? ' selected' : '' ?>>Redirecionar para com www</option></select></label>
      </div>
      <label class="chk"><input type="checkbox" name="https" value="1"<?= ($s['https'] ?? '1') !== '0' ? ' checked' : '' ?>> Redirecionar HTTP para HTTPS (quando houver certificado)</label>
      <?php if (!empty($s['ssl_exp'])): ?><div class="mu">Certificado <?= ($s['ssl'] ?? '') === 'le' ? "Let's Encrypt" : 'autoassinado' ?> válido até <?= h(gmdate('d/m/Y', (int)$s['ssl_exp'])) ?><?= ($s['ssl'] ?? '') === 'le' ? '; é renovado automaticamente.' : '.' ?></div><?php endif; ?>
      <div class="warnbox">Lojas como PrestaShop, WooCommerce e OpenCart guardam o endereço na própria base de dados: depois de associares um domínio, atualiza-o também nas definições da loja.</div>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
  </form>
</dialog>
<dialog class="drawer" id="dlg-lim-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_limits', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Limites de <?= h($n) ?></h3><p>Aplicados ao PHP-FPM e ao nginx deste site.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <?= limit_fields($L) ?>
      <div class="mu">O upload máximo também define o tamanho máximo de pedido no nginx (client_max_body_size). Se a configuração falhar, os valores anteriores são repostos.</div>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar limites</button></div>
  </form>
</dialog>
<dialog id="dlg-php-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_php', ['site' => $n]) ?>
    <div class="dlg-h"><h3>Versão de PHP de <?= h($n) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Versão<select class="in" name="php"><?= php_options($phps, (string)($s['php'] ?? '')) ?></select><small>A troca é feita sem interromper o site.</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mudar versão</button></div>
  </form>
</dialog>
<dialog id="dlg-del-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_del', ['site' => $n]) ?>
    <div class="dlg-h"><h3>Apagar o site <?= h($n) ?>?</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <div class="warnbox">O site deixa de estar acessível na porta <?= (int)($s['port'] ?? 0) ?>, e o utilizador de sistema e a configuração são removidos. As bases de dados não são apagadas.</div>
      <label class="chk"><input type="checkbox" name="keep" value="1"> Manter os ficheiros em <?= h('/srv/www/' . $n) ?></label>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Apagar site</button></div>
  </form>
</dialog>
<?php endforeach; ?>

<?php foreach ($dbs as $d): $n = (string)($d['name'] ?? ''); if (!preg_match(RX_DB, $n)) continue; ?>
<dialog id="dlg-dblink-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_link', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Associar <?= h($n) ?> a um site</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Site<select class="in" name="site"><option value="none">Nenhum</option><?php foreach ($sites as $ss): $ssn = (string)$ss['name']; ?><option value="<?= h($ssn) ?>"<?= ($d['site'] ?? '') === $ssn ? ' selected' : '' ?>><?= h($ssn) ?></option><?php endforeach; ?></select><small>A base de dados passa a entrar nos backups do site e é reposta com ele.</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
  </form>
</dialog>
<dialog id="dlg-dbpw-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_pass', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Nova password para <?= h($n) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Password<input class="in" name="pw" type="password" maxlength="64" autocomplete="new-password"><small>Vazio = gerada automaticamente e mostrada no fim</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mudar password</button></div>
  </form>
</dialog>
<dialog id="dlg-dbdel-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_del', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Apagar a base de dados <?= h($n) ?>?</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><div class="warnbox">A base de dados e o utilizador <?= h($n) ?>@localhost são apagados. Esta ação não pode ser anulada.</div></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Apagar base de dados</button></div>
  </form>
</dialog>
<?php endforeach; ?>

<div class="toasts" aria-live="polite">
  <?php foreach ($jobs as $j): ?>
    <div class="toast pending"><span class="ti"><span class="spin"></span></span><div class="msg"><?= h(($j['label'] ?? 'Tarefa') . '…') ?></div></div>
  <?php endforeach; ?>
  <?php foreach ($flashes as $f): $sticky = !empty($f[2]); $m = (string)$f[1]; ?>
    <div class="toast <?= $f[0] ? 'ok' : 'err' ?>"<?= $sticky ? '' : ' data-auto' ?>>
      <span class="ti"><?= ic($f[0] ? 'check' : 'alert') ?></span>
      <div class="msg<?= strpos($m, "\n") !== false ? ' mono' : '' ?>"><?= h($m) ?></div>
      <button type="button" data-dismiss aria-label="Fechar"><?= ic('x') ?></button>
    </div>
  <?php endforeach; ?>
</div>

<script>
(function () {
  var $ = function (s, c) { return (c || document).querySelectorAll(s); };
  function openDlg(id) { var d = document.getElementById(id); if (d && d.showModal && !d.open) { closeMenus(); d.showModal(); var f = d.querySelector('input:not([type=hidden]),select'); if (f) f.focus(); } }
  function closeMenus(except) { $('details.dd[open]').forEach(function (x) { if (x !== except) x.removeAttribute('open'); }); }
  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-open]');
    if (t) { e.preventDefault(); openDlg(t.getAttribute('data-open')); return; }
    var c = e.target.closest('[data-close]');
    if (c) { var d = c.closest('dialog'); if (d) d.close(); return; }
    if (e.target.closest('[data-dismiss]')) { e.target.closest('.toast').remove(); return; }
    if (e.target.closest('[data-nav-open]')) { document.body.classList.add('nav-open'); return; }
    if (e.target.closest('[data-nav-close]')) { document.body.classList.remove('nav-open'); return; }
    if (e.target.closest('[data-theme-toggle]')) {
      var n = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', n);
      try { localStorage.setItem('mp-theme', n); } catch (x) {}
      return;
    }
    if (!e.target.closest('details.dd')) closeMenus();
  });
  $('details.dd').forEach(function (d) { d.addEventListener('toggle', function () { if (d.open) closeMenus(d); }); });
  $('dialog').forEach(function (d) { d.addEventListener('click', function (e) { if (e.target === d && !d.hasAttribute('data-keep')) d.close(); }); });
  document.addEventListener('submit', function (e) {
    var f = e.target, m = f.getAttribute('data-confirm');
    if ((f.getAttribute('method') || '').toLowerCase() === 'dialog') return;
    if (m && !window.confirm(m)) { e.preventDefault(); return; }
    setTimeout(function () { $('button', f).forEach(function (b) { b.disabled = true; }); }, 0);
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeMenus(); document.body.classList.remove('nav-open'); } });
  $('.toast[data-auto]').forEach(function (t) { setTimeout(function () { t.remove(); }, 6000); });
  var o = document.body.getAttribute('data-autoopen');
  if (o) openDlg(o);
  if (parseInt(document.body.getAttribute('data-pending'), 10) > 0) {
    var poll = function () {
      fetch('?poll=1', { credentials: 'same-origin', cache: 'no-store' })
        .then(function (r) { if (r.status === 401) return { pending: 0 }; return r.json(); })
        .then(function (d) { if (d.pending > 0) setTimeout(poll, 1000); else location.replace(location.pathname + location.search.replace(/[?&](novo|limites)=[^&]*/g, '')); })
        .catch(function () { setTimeout(poll, 1500); });
    };
    setTimeout(poll, 700);
  }
})();
</script>
<?php if ($page === 'conta' && !empty($_SESSION['totp_new']) && qget('tfa') === 'setup'): ?>
<script src="?asset=qr"></script>
<script>
(function () { var el = document.getElementById('tfa-qr'); if (!el || typeof qrcode !== 'function') return;
  var q = qrcode(0, 'M'); q.addData(el.getAttribute('data-uri')); q.make(); el.innerHTML = q.createSvgTag(5, 4); })();
</script>
<?php endif; ?>
<?php if ($page === 'auditoria'): ?>
<script>
(function () { var q = document.getElementById('au-q'); if (!q) return;
  q.addEventListener('input', function () { var f = q.value.toLowerCase();
    document.querySelectorAll('#au-t tbody tr').forEach(function (tr) { tr.style.display = !f || tr.textContent.toLowerCase().indexOf(f) !== -1 ? '' : 'none'; }); }); })();
</script>
<?php endif; ?>
<?php if ($page === 'logs'): ?>
<script>
(function () {
  var box = document.getElementById('lg'); if (!box) return;
  var site = box.getAttribute('data-site'), t = box.getAttribute('data-t'), body = document.getElementById('lg-body');
  var $ = function (id) { return document.getElementById(id); };
  function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function pill(s) { var c = s >= 500 ? 'p-err' : (s >= 400 ? 'p-warn' : (s >= 300 ? 'p-off' : 'p-ok')); return '<span class="pill ' + c + '">' + s + '</span>'; }
  function fdate(t) { var d = new Date(t * 1000), p = function (n) { return (n < 10 ? '0' : '') + n; }; return p(d.getDate()) + '/' + p(d.getMonth() + 1) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()); }
  function raw(lines) {
    if (!lines.length) { body.innerHTML = '<div class="empty">Sem linhas' + ($('lg-q').value ? ' com esse texto' : '') + '.</div>'; return; }
    body.innerHTML = '<pre class="cron-out lg-raw">' + lines.slice().reverse().map(esc).join('\n') + '</pre>';
  }
  function load() {
    var n = $('lg-n').value, q = $('lg-q').value.trim(), url;
    if (t === 'access' || t === 'error' || t === 'slow') {
      url = '?logs=json&site=' + encodeURIComponent(site) + '&t=' + t + '&n=' + n + '&q=' + encodeURIComponent(q);
      if (t === 'access') url += '&st=' + encodeURIComponent($('lg-st').value) + '&ip=' + encodeURIComponent($('lg-ip').value.trim());
      fetch(url, { credentials: 'same-origin' }).then(function (r) { return r.json(); }).then(function (d) {
        if (t !== 'access') return raw(d.lines || []);
        var rows = d.rows || [];
        if (!rows.length) { body.innerHTML = '<div class="empty">Sem pedidos com estes filtros.</div>'; return; }
        body.innerHTML = '<table class="list cards lg-tab"><thead><tr><th>Data</th><th>IP</th><th>Pedido</th><th>Código</th><th class="r">Tempo</th><th class="r">Tamanho</th><th>Navegador</th></tr></thead><tbody>' +
          rows.slice().reverse().map(function (r) { return '<tr><td class="first mono" data-label="Data">' + fdate(r.t) + '</td><td class="mono" data-label="IP">' + esc(r.ip) + '</td><td data-label="Pedido"><span class="mu">' + esc(r.m) + '</span> <span class="mono lg-url" title="' + esc(r.u) + '">' + esc(r.u) + '</span></td><td data-label="Código">' + pill(r.s) + (r.cs ? ' <span class="mu" title="Cache">' + esc(r.cs) + '</span>' : '') + '</td><td class="r" data-label="Tempo">' + (r.rt === null || r.rt === undefined ? '—' : '<span' + (r.rt >= 1 ? ' style="color:var(--err)"' : '') + '>' + Math.round(r.rt * 1000) + ' ms</span>') + '</td><td class="r" data-label="Tamanho">' + (r.b > 1024 ? Math.round(r.b / 1024) + ' KB' : r.b + ' B') + '</td><td class="mu lg-ua" title="' + esc(r.a) + '">' + esc(r.a) + '</td></tr>'; }).join('') + '</tbody></table>';
      }).catch(function () { body.innerHTML = '<div class="empty">Não foi possível ler o log.</div>'; });
    } else {
      var f = t === 'php' ? 'php-error.log' : ('cron-' + (($('lg-cron') || {}).value || 'x') + '.log');
      fetch('/ficheiros/' + encodeURIComponent(site) + '/?a=tail&p=' + encodeURIComponent('logs/' + f) + '&n=' + n + '&q=' + encodeURIComponent(q), { credentials: 'same-origin', headers: { 'X-MP-Request': '1' } })
        .then(function (r) { return r.json(); }).then(function (d) { raw(d.lines || []); })
        .catch(function () { body.innerHTML = '<div class="empty">Não foi possível ler o log.</div>'; });
    }
  }
  var tm = null;
  ['lg-n', 'lg-st', 'lg-cron'].forEach(function (id) { if ($(id)) $(id).addEventListener('change', load); });
  ['lg-q', 'lg-ip'].forEach(function (id) { if ($(id)) $(id).addEventListener('input', function () { clearTimeout(tm); tm = setTimeout(load, 400); }); });
  var live = null; $('lg-live').addEventListener('change', function (e) { if (e.target.checked) live = setInterval(load, 5000); else clearInterval(live); });
  load();
})();
</script>
<?php endif; ?>
<?php if ($page === 'processos'): ?>
<script>
(function () {
  var data = {}, page = 1, PER = 50, f = document.getElementById('pr-f'), q = document.getElementById('pr-q');
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function mb(kb) { return kb >= 1048576 ? (kb / 1048576).toFixed(1).replace('.', ',') + ' GB' : Math.round(kb / 1024) + ' MB'; }
  function ago(s) { return s >= 86400 ? Math.floor(s / 86400) + ' d' : s >= 3600 ? Math.floor(s / 3600) + ' h' : s >= 60 ? Math.floor(s / 60) + ' min' : s + ' s'; }
  var tone = { site: 'p-me', email: 'p-warn', bd: 'p-ok', web: 'p-off', painel: 'p-off', sistema: 'p-off' };
  function render() {
    var sum = data.sum || [], cpus = data.cpus || 1, memt = data.memt || 1, h = '';
    sum.slice(0, 12).forEach(function (s) {
      var c = Math.min(100, s.cpu / cpus), m = Math.min(100, s.rss * 100 / memt);
      h += '<div class="pr-o"><div class="nm"><span class="pill ' + (tone[s.t] || 'p-off') + '">' + esc(s.o) + '</span><span class="mu">' + s.n + ' proc.</span></div>' +
        '<div class="mu">CPU ' + c.toFixed(1).replace('.', ',') + '%</div><div class="cbar"><span style="width:' + c + '%"></span></div>' +
        '<div class="mu">RAM ' + mb(s.rss) + ' (' + m.toFixed(1).replace('.', ',') + '%)</div><div class="cbar"><span style="width:' + m + '%;background:var(--warn)"></span></div></div>';
    });
    document.getElementById('pr-sum').innerHTML = h || '<div class="empty">Sem dados (o recolhedor está a correr?).</div>';
    var rows = data.rows || [], fv = f.value, qv = (q.value || '').trim().toLowerCase();
    if (fv) rows = rows.filter(function (r) { return r.t === fv; });
    if (qv) rows = rows.filter(function (r) { return (r.args + ' ' + r.user + ' ' + r.pid + ' ' + r.o).toLowerCase().indexOf(qv) !== -1; });
    var pages = Math.max(1, Math.ceil(rows.length / PER)); if (page > pages) page = pages; h = '';
    rows.slice((page - 1) * PER, page * PER).forEach(function (r) {
      h += '<tr><td class="first mono" data-label="PID">' + r.pid + '</td><td data-label="Origem"><span class="pill ' + (tone[r.t] || 'p-off') + '">' + esc(r.o) + '</span><div class="mu">' + esc(r.user) + '</div></td>' +
        '<td class="r" data-label="CPU"><b' + (r.cpu >= 50 ? ' style="color:var(--err)"' : '') + '>' + r.cpu.toFixed(1).replace('.', ',') + '%</b></td>' +
        '<td class="r" data-label="Memória">' + mb(r.rss) + '<div class="mu">' + String(r.mem).replace('.', ',') + '%</div></td><td class="mu" data-label="Há" style="white-space:nowrap">' + ago(r.et) + '</td>' +
        '<td data-label="Comando"><div class="mono pr-cmd" title="' + esc(r.args) + '">' + esc(r.args) + '</div></td>' +
        '<td class="act r">' + (r.prot ? '<span class="mu">essencial</span>' : '<button class="btn sm danger-o" type="button" data-kill="' + r.pid + '">Terminar</button>') + '</td></tr>';
    });
    document.getElementById('pr-rows').innerHTML = h || '<tr><td colspan="7" class="empty">Nenhum processo com estes filtros.</td></tr>';
    var pg = ''; if (pages > 1) { pg += '<span class="mu">' + rows.length + ' processos</span>'; for (var i = 1; i <= pages; i++) if (i === 1 || i === pages || Math.abs(i - page) <= 2) pg += '<button type="button" class="chip sm' + (i === page ? ' prim' : '') + '" data-pg="' + i + '">' + i + '</button>'; }
    document.getElementById('pr-pager').innerHTML = pg;
    document.getElementById('pr-foot').textContent = data.ts ? 'Última leitura às ' + new Date(data.ts * 1000).toLocaleTimeString('pt-PT') + ' · ' + (data.rows || []).length + ' processos com mais consumo' : '';
  }
  document.addEventListener('click', function (e) {
    var p = e.target.closest('[data-pg]'); if (p) { page = +p.getAttribute('data-pg'); render(); return; }
    var k = e.target.closest('[data-kill]'); if (!k) return;
    var pid = +k.getAttribute('data-kill'), r = (data.rows || []).filter(function (x) { return x.pid === pid; })[0]; if (!r) return;
    document.getElementById('kill-pid').value = pid; document.getElementById('kill-t').textContent = pid;
    document.getElementById('kill-cmd').textContent = r.user + ': ' + r.args;
    document.getElementById('kill-site').innerHTML = r.site ? '<p class="mu" style="margin:6px 0 0">É do site <b>' + esc(r.site) + '</b>. <button class="lnk" type="button" data-killsite="' + esc(r.site) + '">Terminar todos os processos deste site</button></p>' : '';
    document.getElementById('dlg-kill').showModal();
  });
  document.addEventListener('click', function (e) {
    var s = e.target.closest('[data-killsite]'); if (!s) return;
    var fm = document.getElementById('kill-site-f'); document.getElementById('kill-site-n').value = s.getAttribute('data-killsite');
    fm.setAttribute('data-confirm', 'Terminar todos os processos do site ' + s.getAttribute('data-killsite') + '? O PHP do site volta a arrancar no próximo pedido.');
    document.getElementById('dlg-kill').close(); fm.requestSubmit();
  });
  f.addEventListener('change', function () { page = 1; render(); }); q.addEventListener('input', function () { page = 1; render(); });
  function poll() {
    fetch('?stats=procs', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) { if (d) { data = d; render(); } }).catch(function () {}).then(function () { setTimeout(poll, 10000); });
  }
  poll();
})();
</script>
<?php endif; ?>
<?php if ($page === 'terminal'): ?>
<script>
(function () { var f = document.getElementById('term'); if (!f) return; var w = document.getElementById('term-wait'), src = f.getAttribute('data-src'), n = 0;
  function tick() { fetch(src, { credentials: 'same-origin', cache: 'no-store' }).then(function (r) {
      if (r.ok) { f.src = src; w.style.display = 'none'; f.style.display = 'block'; return; }
      // sem resposta durante 15 s: o terminal desta sessão já terminou (página recarregada, exit ou inatividade)
      if (++n >= 15) { location.href = '?term=reset'; return; } setTimeout(tick, 1000); })
    .catch(function () { if (++n >= 15) { location.href = '?term=reset'; return; } setTimeout(tick, 1000); }); }
  tick(); })();
</script>
<?php endif; ?>
<?php if ($page === 'atualizacoes'): ?>
<script>
(function () { function tick() { if (document.querySelector('dialog[open]')) setTimeout(tick, 5000); else location.reload(); }
  if (document.querySelector('[data-bk-running]')) setTimeout(tick, 5000); })();
</script>
<?php endif; ?>
<?php if ($page === 'backups'): ?>
<script>
(function () {
  var t = document.getElementById('rm-type');
  if (t) {
    var sw = function () { document.querySelectorAll('.rm-grp').forEach(function (g) { g.hidden = g.getAttribute('data-rm') !== t.value; }); };
    t.addEventListener('change', sw); sw();
  }
  function tick() { if (document.querySelector("dialog[open]")) setTimeout(tick, 5000); else location.reload(); }
  if (document.querySelector("[data-bk-running]")) setTimeout(tick, 5000);
})();
</script>
<?php endif; ?>
<?php if ($page === 'cron'): ?>
<script>
(function () {
  var dlg = document.getElementById('dlg-cron'); if (!dlg) return;
  var F = [0, 1, 2, 3, 4].map(function (i) { return document.getElementById('cf-' + i); });
  var human = document.getElementById('cron-human'), when = document.getElementById('cron-when'), cmd = document.getElementById('cron-cmd');
  var site = document.getElementById('cron-site');
  var days = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
  function two(n) { return (n < 10 ? '0' : '') + n; }
  function desc(p) {
    var mi = p[0], ho = p[1], dm = p[2], mo = p[3], dw = p[4], n = /^\d+$/, m;
    var hm = function () { return two(+ho) + ':' + two(+mi); };
    if (dm === '*' && mo === '*' && dw === '*') {
      if (mi === '*' && ho === '*') return 'A cada minuto';
      if ((m = /^\*\/(\d+)$/.exec(mi)) && ho === '*') return 'A cada ' + m[1] + ' minutos';
      if (n.test(mi) && ho === '*') return 'De hora a hora, ao minuto ' + (+mi);
      if (n.test(mi) && (m = /^\*\/(\d+)$/.exec(ho))) return 'A cada ' + m[1] + ' horas, ao minuto ' + (+mi);
      if (n.test(mi) && n.test(ho)) return 'Todos os dias às ' + hm();
    }
    if (n.test(mi) && n.test(ho) && dm === '*' && mo === '*') {
      if (/^[0-7]$/.test(dw)) return 'À ' + days[+dw] + ' às ' + hm();
      if (dw === '1-5') return 'Dias úteis às ' + hm();
    }
    if (n.test(mi) && n.test(ho) && n.test(dm) && mo === '*' && dw === '*') return 'No dia ' + (+dm) + ' de cada mês às ' + hm();
    return 'Expressão personalizada';
  }
  function sync() {
    var p = F.map(function (f) { return f.value.trim() || '*'; });
    var ok = p.every(function (x) { return /^(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(\/[0-9]+)?(,(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(\/[0-9]+)?)*$/.test(x); });
    when.value = p.join(' ');
    human.textContent = ok ? desc(p) + '  ·  ' + when.value : 'Expressão inválida';
    human.classList.toggle('bad', !ok);
  }
  F.forEach(function (f) { f.addEventListener('input', sync); });
  document.getElementById('cron-preset').addEventListener('change', function (e) {
    if (!e.target.value) return; e.target.value.split(' ').forEach(function (v, i) { F[i].value = v; }); sync();
  });
  function ins(t) { var s = cmd.selectionStart, v = cmd.value; cmd.value = v.slice(0, s) + t + v.slice(cmd.selectionEnd); cmd.focus(); cmd.selectionStart = cmd.selectionEnd = s + t.length; }
  document.querySelector('.cron-help').addEventListener('click', function (e) {
    var b = e.target.closest('[data-ins]'); if (!b) return;
    var sn = site.value, port = site.options[site.selectedIndex].getAttribute('data-port');
    var k = b.getAttribute('data-ins');
    if (k === 'php') ins('php /srv/www/' + sn + '/public_html/');
    else if (k === 'url') ins('curl -fsS -m 300 "http://127.0.0.1' + (port === '80' ? '' : ':' + port) + '/"');
    else ins(' >/dev/null 2>&1');
  });
  function open(d) {
    document.getElementById('t-cron').textContent = d ? 'Editar tarefa agendada' : 'Nova tarefa agendada';
    document.getElementById('cron-submit').textContent = d ? 'Guardar alterações' : 'Criar tarefa';
    document.getElementById('cron-id').value = d ? d.id : '';
    if (d) { site.value = d.site; cmd.value = d.cmd; document.getElementById('cron-desc').value = d.desc || ''; var w = d.when.split(/\s+/); if (w.length === 5) w.forEach(function (v, i) { F[i].value = v; }); }
    else { cmd.value = ''; document.getElementById('cron-desc').value = ''; ['*/5', '*', '*', '*', '*'].forEach(function (v, i) { F[i].value = v; }); }
    site.disabled = !!d;
    document.getElementById('cron-preset').value = ''; sync(); dlg.showModal(); cmd.focus();
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-cron-new]'); if (b) { e.preventDefault(); open(null); return; }
    b = e.target.closest('[data-cron-edit]'); if (b) { e.preventDefault(); open(JSON.parse(b.getAttribute('data-cron-edit'))); }
  });
  document.getElementById('cron-form').addEventListener('submit', function (e) {
    sync(); if (human.classList.contains('bad')) { e.preventDefault(); return; }
    if (cmd.value.indexOf('\n') !== -1) cmd.value = cmd.value.replace(/[\r\n]+/g, ' ');
    site.disabled = false;
  });
  sync();
})();
</script>
<?php endif; ?>
<?php if ($page === 'ligacoes'): ?>
<script>
(function () {
  var box = document.getElementById('cn'); if (!box) return;
  var mode = box.getAttribute('data-mode');
  var L = JSON.parse(box.getAttribute('data-labels') || '{}'), allow = JSON.parse(box.getAttribute('data-allow') || '[]');
  var me = box.getAttribute('data-me'), lim = +box.getAttribute('data-limit') || 0, auto = box.getAttribute('data-auto') === '1';
  var home = box.getAttribute('data-home') || '', blocked = JSON.parse(box.getAttribute('data-blocked') || '[]');
  var data = {}, q = document.getElementById('cn-q'), page = 1, PER = 50;
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function lab(p) { return L[p] ? L[p] + ' :' + p : ':' + p; }
  function stats() {
    document.querySelectorAll('[data-c]').forEach(function (e) { var k = e.getAttribute('data-c'); if (data[k] !== undefined) e.textContent = data[k]; });
  }
  function renderIp() {
    var rows = (data.ips || []), f = (q.value || '').trim().toLowerCase(), h = '';
    if (f) rows = rows.filter(function (r) { return r.ip.indexOf(f) !== -1 || (r.cn || '').toLowerCase().indexOf(f) !== -1 || (r.cc || '').toLowerCase() === f; });
    var pages = Math.max(1, Math.ceil(rows.length / PER)); if (page > pages) page = pages;
    rows.slice((page - 1) * PER, page * PER).forEach(function (r) {
      var ports = Object.keys(r.ports || {}).sort(function (a, b) { return r.ports[b] - r.ports[a]; }).map(function (p) { return esc(lab(p)) + ' (' + r.ports[p] + ')'; }).join(' · ');
      var isMe = r.ip === me, ok = allow.indexOf(r.ip) !== -1, hot = lim && r.n >= lim * 0.8;
      var act = isMe ? '<span class="mu">protegido</span>' : ok ? '<span class="mu">confiança</span>' : '<button class="btn sm danger-o" type="button" data-block="' + esc(r.ip) + '">Bloquear</button>';
      h += '<tr><td class="first" data-label="IP"><span class="nm mono">' + esc(r.ip) + '</span>' + (isMe ? ' <span class="pill p-me">tu</span>' : '') + (r.syn ? '<div class="mu">' + r.syn + ' em espera (SYN)</div>' : '') + '</td>' +
        '<td data-label="País"><span class="cc-flag">' + esc(r.fl || '') + '</span> ' + esc(r.cn || '') + '</td>' +
        '<td class="r" data-label="Ligações"><b class="' + (hot ? 'cn-hot' : '') + '">' + r.n + '</b></td><td class="mu" data-label="Destino">' + ports + '</td><td class="act r">' + act + '</td></tr>';
    });
    if (!h) h = '<tr><td colspan="5" class="empty">' + (f ? 'Nada corresponde à pesquisa.' : 'Sem ligações abertas de momento.') + '</td></tr>';
    document.getElementById('cn-rows').innerHTML = h;
    var pg = ''; if (pages > 1) { pg += '<span class="mu">' + rows.length + ' IPs</span>'; for (var i = 1; i <= pages; i++) if (i === 1 || i === pages || Math.abs(i - page) <= 2) pg += '<button type="button" class="chip sm' + (i === page ? ' prim' : '') + '" data-pg="' + i + '">' + i + '</button>'; }
    document.getElementById('cn-pager').innerHTML = pg;
    var t = data.ts ? new Date(data.ts * 1000) : null;
    document.getElementById('cn-foot').textContent = (auto ? 'Bloqueio automático acima de ' + lim + ' ligações por IP. ' : '') + (t ? 'Última leitura às ' + t.toLocaleTimeString('pt-PT') + '.' : '');
  }
  function renderCc() {
    var rows = data.countries || [], tot = rows.reduce(function (a, r) { return a + r.n; }, 0) || 1, h = '';
    rows.slice(0, 40).forEach(function (r) {
      var pc = Math.round(r.n * 100 / tot), canBlock = r.cc && r.cc !== home && blocked.indexOf(r.cc) === -1;
      h += '<div class="item"><span class="cc-flag">' + esc(r.fl) + '</span><div class="grow"><div class="nm">' + esc(r.cn) + (r.cc === home ? ' <span class="pill p-ok">país do servidor</span>' : '') + '</div>' +
        '<div class="cbar"><span style="width:' + pc + '%"></span></div><div class="mu">' + r.n + ' ligações · ' + r.ips + ' IPs · ' + pc + '%</div></div>' +
        (canBlock ? '<button class="btn sm danger-o" type="button" data-cc="' + esc(r.cc) + '">Bloquear</button>' : '') + '</div>';
    });
    document.getElementById('cc-rows').innerHTML = h || '<div class="empty">Sem ligações abertas de momento.</div>';
  }
  function render() { stats(); if (mode === 'cc') renderCc(); else renderIp(); }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-block]');
    if (b) { document.getElementById('blk-ip').value = b.getAttribute('data-block'); document.getElementById('dlg-block').showModal(); return; }
    var p = e.target.closest('[data-pg]'); if (p) { page = +p.getAttribute('data-pg'); renderIp(); return; }
    var c = e.target.closest('[data-cc]');
    if (c) { var sel = document.querySelector('select[name=cc]'); if (sel) { sel.value = c.getAttribute('data-cc'); sel.form.requestSubmit(); } }
  });
  if (q) q.addEventListener('input', function () { page = 1; renderIp(); });
  function poll() {
    fetch('?stats=conns', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) { if (d && d.ts) { data = d; render(); } })
      .catch(function () {}).then(function () { setTimeout(poll, 5000); });
  }
  poll();
})();
</script>
<?php endif; ?>
<?php if ($page === 'recursos' || $page === 'resumo'): ?>
<script>
(function () {
  function dec(v, d) { return Number(v || 0).toFixed(d === undefined ? 1 : d).replace('.', ','); }
  function bytes(b) { var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0; b = Number(b || 0); while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i ? b.toFixed(1).replace('.', ',') : Math.round(b)) + ' ' + u[i]; }
  function bps(b) { var u = ['b/s', 'Kb/s', 'Mb/s', 'Gb/s'], i = 0; b = Number(b || 0); while (b >= 1000 && i < 3) { b /= 1000; i++; } return (i ? b.toFixed(1).replace('.', ',') : Math.round(b)) + ' ' + u[i]; }
  function fmt(v, f) { return f === 'pct' ? dec(v) + '%' : f === 'bps' ? bps(v) : dec(v, 2); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function set(k, t) { document.querySelectorAll('[data-l="' + k + '"]').forEach(function (e) { e.textContent = t; }); }
  function bar(k, v) { document.querySelectorAll('[data-lm="' + k + '"]').forEach(function (e) { e.style.width = Math.max(0, Math.min(100, v)) + '%'; e.classList.toggle('hi', v >= 90); }); }
  function upd() {
    fetch('?stats=live', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) {
        if (!d || !d.ts) return;
        set('cpu', dec(d.cpu) + '%'); bar('cpu', d.cpu);
        set('mem', dec(d.mem.pct) + '%'); set('mem-sub', bytes(d.mem.used * 1024) + ' / ' + bytes(d.mem.total * 1024)); bar('mem', d.mem.pct);
        set('disk', dec(d.disk.pct) + '%'); set('disk-sub', bytes(d.disk.used * 1024) + ' / ' + bytes(d.disk.total * 1024)); bar('disk', d.disk.pct);
        set('load', dec(d.load[0], 2)); set('load-sub', '5 min ' + dec(d.load[1], 2) + ' · 15 min ' + dec(d.load[2], 2));
        set('swap', 'Swap ' + dec(d.swap.pct) + '%');
        set('net', bps(d.net.rx + d.net.tx)); set('net-sub', '↓ ' + bps(d.net.rx) + ' · ↑ ' + bps(d.net.tx));
        document.querySelectorAll('[data-ls]').forEach(function (e) {
          var p = e.getAttribute('data-ls').split(':'), s = (d.sites || {})[p[0]] || { cpu: 0, rss: 0 };
          e.textContent = p[1] === 'cpu' ? dec(s.cpu) + '%' : bytes(s.rss * 1024);
        });
      })
      .catch(function () {})
      .then(function () { setTimeout(upd, 5000); });
  }
  if (document.querySelector('[data-live]')) setTimeout(upd, 5000);

  document.querySelectorAll('.chart').forEach(function (c) {
    var d; try { d = JSON.parse(c.getAttribute('data-chart')); } catch (e) { return; }
    if (!d.t || d.t.length < 2) return;
    var plot = c.querySelector('.ch-plot'), cur = c.querySelector('.ch-cur'), tip = c.querySelector('.ch-tip');
    function two(n) { return (n < 10 ? '0' : '') + n; }
    plot.addEventListener('mousemove', function (e) {
      var r = plot.getBoundingClientRect(), t = d.from + (d.to - d.from) * ((e.clientX - r.left) / r.width);
      var lo = 0, hi = d.t.length - 1;
      while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (d.t[mid] < t) lo = mid; else hi = mid; }
      var i = Math.abs(d.t[lo] - t) <= Math.abs(d.t[hi] - t) ? lo : hi;
      var x = (d.t[i] - d.from) / (d.to - d.from) * 100;
      cur.style.left = x + '%'; cur.style.display = 'block';
      var dt = new Date((d.t[i] + d.tz) * 1000);
      var lab = two(dt.getUTCDate()) + '/' + two(dt.getUTCMonth() + 1) + ' ' + two(dt.getUTCHours()) + ':' + two(dt.getUTCMinutes());
      tip.innerHTML = '<b>' + lab + '</b>' + d.s.map(function (s) { return '<div><i style="background:' + esc(s.c) + '"></i>' + esc(s.n) + ': ' + fmt(s.v[i], d.fmt) + '</div>'; }).join('');
      tip.style.display = 'block';
      if (x > 60) { tip.style.left = ''; tip.style.right = (100 - x) + '%'; } else { tip.style.right = ''; tip.style.left = x + '%'; }
    });
    plot.addEventListener('mouseleave', function () { cur.style.display = 'none'; tip.style.display = 'none'; });
  });
})();
</script>
<?php endif; ?>
<?php if ($page === 'ficheiros' && !empty($fmSite)): ?>
<script>
(function () {
  var root = document.getElementById('fm'); if (!root) return;
  var IC = <?= json_encode(['dir' => ic('folder', 'dir'), 'zip' => ic('zip', 'zip'), 'code' => ic('code', 'code'), 'file' => ic('file', 'file'), 'up' => ic('up', 'file'), 'dots' => ic('dots'), 'home' => ic('home'), 'open' => ic('folder'), 'dl' => ic('download'), 'edit' => ic('edit'), 'ren' => ic('edit'), 'move' => ic('move'), 'zipb' => ic('zip'), 'perm' => ic('lock'), 'del' => ic('trash'), 'x' => ic('x')], JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) ?>;
  var $ = function (id) { return document.getElementById(id); };
  var st = { site: root.getAttribute('data-site'), path: '', items: [], sel: {} };
  var NOEDIT = root.getAttribute('data-noedit') === '1', LABEL = root.getAttribute('data-label') || st.site;
  var EDIT = /(\.(php|phtml|inc|html?|css|scss|js|mjs|json|txt|md|xml|svg|ini|conf|env|log|csv|sql|ya?ml|twig|tpl|sh|py|htaccess|htpasswd|user\.ini)|^\.[a-z]+)$/i;
  var ARCH = /\.(zip|tar|tgz|tar\.gz|tar\.bz2)$/i;
  var CH = 8 * 1024 * 1024;

  function base(site) { return '/ficheiros/' + encodeURIComponent(site || st.site) + '/'; }
  function join(a, b) { return a ? (b ? a + '/' + b : a) : b; }
  function enc(s) { return encodeURIComponent(s); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function bytes(b) { if (b === null || b === undefined) return '—'; var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0; b = Number(b); while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i ? b.toFixed(1).replace('.', ',') : b) + ' ' + u[i]; }
  function two(n) { return (n < 10 ? '0' : '') + n; }
  function when(t) { var d = new Date(t * 1000); return two(d.getDate()) + '/' + two(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + two(d.getHours()) + ':' + two(d.getMinutes()); }
  function toast(ok, msg) {
    var box = document.querySelector('.toasts'); if (!box) return;
    var t = document.createElement('div'); t.className = 'toast ' + (ok ? 'ok' : 'err');
    t.innerHTML = '<span class="ti">' + (ok ? '✓' : '!') + '</span><div class="msg"></div><button type="button" data-dismiss aria-label="Fechar">' + IC.x + '</button>';
    t.querySelector('.msg').textContent = msg; box.appendChild(t);
    if (ok) setTimeout(function () { t.remove(); }, 5000);
  }
  function api(a, data, q, site) {
    var init = { credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, cache: 'no-store' };
    if (data instanceof FormData) { init.method = 'POST'; init.body = data; }
    else if (data) { init.method = 'POST'; init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(data); }
    return fetch(base(site) + '?a=' + a + (q ? '&' + q : ''), init).then(function (r) {
      if (r.redirected && r.url.indexOf('/ficheiros/') === -1) { location.reload(); throw new Error('A sessão expirou.'); }
      return r.json().catch(function () { throw new Error('Resposta inválida do servidor (' + r.status + ').'); })
        .then(function (j) { j._s = r.status; return j; });
    });
  }
  function must(j) { if (!j.ok) { var e = new Error(j.error || 'Falhou.'); e.j = j; throw e; } return j; }
  function fail(e) { toast(false, e.message || String(e)); }

  /* ---------- diálogo ---------- */
  function ask(title, msg, value, okLabel, danger) {
    var d = $('fm-dlg'), inp = $('fm-dlg-in'), ok = $('fm-dlg-ok');
    $('fm-dlg-t').textContent = title; $('fm-dlg-msg').textContent = msg || '';
    $('fm-dlg-msg').hidden = !msg;
    inp.hidden = value === null; inp.value = value === null ? '' : value;
    ok.textContent = okLabel || 'OK'; ok.className = 'btn' + (danger ? ' dan' : '');
    d.returnValue = ''; d.showModal();
    if (value !== null) { inp.focus(); var dot = inp.value.lastIndexOf('.'); inp.setSelectionRange(0, dot > 0 ? dot : inp.value.length); } else ok.focus();
    return new Promise(function (res) {
      d.addEventListener('close', function h() { d.removeEventListener('close', h); res(d.returnValue === 'ok' ? (value === null ? true : inp.value.trim()) : null); });
    });
  }

  /* ---------- listagem ---------- */
  function setUrl() { var u = '?p=ficheiros&site=' + enc(st.site) + (st.path ? '&dir=' + enc(st.path) : ''); history.replaceState(null, '', u); }
  function load(path) {
    if (path !== undefined) { st.path = path; st.sel = {}; }
    return api('list', null, 'p=' + enc(st.path)).then(must).then(function (j) {
      st.items = j.items; render(j.free);
    }).catch(function (e) {
      if (st.path) { toast(false, e.message); st.path = ''; return load(); }
      $('fm-rows').innerHTML = '<tr><td colspan="5" class="empty"></td></tr>';
      $('fm-rows').querySelector('td').textContent = e.message;
    }).then(setUrl);
  }
  function kind(it) { return it.d ? 'dir' : ARCH.test(it.n) ? 'zip' : EDIT.test(it.n) ? 'code' : 'file'; }
  function render(free) {
    var tb = $('fm-rows'), h = '';
    if (st.path) h += '<tr data-up="1"><td class="first" colspan="5"><button type="button" class="fm-name" data-act="up">' + IC.up + '<span>.. (pasta acima)</span></button></td></tr>';
    st.items.forEach(function (it, i) {
      h += '<tr data-i="' + i + '"' + (st.sel[it.n] ? ' class="sel"' : '') + '>' +
        '<td class="first" data-label="Nome"><div class="fm-first"><label class="fm-ck"><input type="checkbox"' + (st.sel[it.n] ? ' checked' : '') + ' aria-label="Selecionar ' + esc(it.n) + '"></label>' +
        '<button type="button" class="fm-name" data-act="open">' + IC[kind(it)] + '<span>' + esc(it.n) + (it.l ? ' ↪' : '') + '</span></button></div></td>' +
        '<td class="r mu" data-label="Tamanho">' + (it.d ? '—' : bytes(it.s)) + '</td>' +
        '<td class="mu" data-label="Modificado">' + when(it.m) + '</td>' +
        '<td class="mono mu" data-label="Permissões">' + esc(it.p.replace(/^0(?=\d{3}$)/, '')) + '</td>' +
        '<td class="act r"><button type="button" class="iconbtn" data-act="menu" aria-label="Ações de ' + esc(it.n) + '">' + IC.dots + '</button></td></tr>';
    });
    if (!st.items.length) h += '<tr><td colspan="5" class="empty">Pasta vazia. Arrasta ficheiros para aqui ou usa “Enviar ficheiros”.</td></tr>';
    tb.innerHTML = h;
    crumbs(); selbar();
    var nd = st.items.filter(function (i) { return i.d; }).length;
    $('fm-foot').textContent = nd + ' pasta(s), ' + (st.items.length - nd) + ' ficheiro(s)' + (free ? ' · ' + bytes(free) + ' livres no disco' : '') + ' · arrasta ficheiros ou pastas para a lista para os enviar';
  }
  function crumbs() {
    var c = $('fm-crumbs'), parts = st.path ? st.path.split('/') : [], h = '<button type="button" data-path="">' + esc(LABEL) + '</button>';
    parts.forEach(function (p, i) { h += '<span class="sep">/</span><button type="button" data-path="' + esc(parts.slice(0, i + 1).join('/')) + '">' + esc(p) + '</button>'; });
    c.innerHTML = h;
  }
  function selected() { return Object.keys(st.sel); }
  function selbar() {
    var n = selected().length;
    $('fm-selbar').hidden = n === 0;
    $('fm-selcount').textContent = n === 1 ? '1 item selecionado' : n + ' itens selecionados';
    $('fm-all').checked = n > 0 && n === st.items.length;
  }

  /* ---------- ações ---------- */
  function done(msg) { return function (j) { must(j); if (msg) toast(true, typeof msg === 'function' ? msg(j) : msg); return load(); }; }
  function download(it) {
    var a = document.createElement('a'); a.href = base() + '?a=dl&p=' + enc(join(st.path, it.n)); a.download = it.n;
    document.body.appendChild(a); a.click(); a.remove();
  }
  function open(it) {
    if (it.d) return load(join(st.path, it.n));
    if (!NOEDIT && (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n) && it.n.indexOf('.') === -1)) return edit(join(st.path, it.n));
    download(it);
  }
  function act(name, items) {
    var p = st.path;
    if (name === 'mkdir' || name === 'newfile') {
      return ask(name === 'mkdir' ? 'Nova pasta' : 'Novo ficheiro', 'Em /' + p, '', 'Criar').then(function (v) {
        if (!v) return;
        return api(name, { p: p, name: v }).then(must).then(function () {
          return load().then(function () { if (name === 'newfile') edit(join(p, v)); });
        });
      }).catch(fail);
    }
    if (!items.length) return;
    var one = items.length === 1 ? items[0] : null;
    var label = one ? '“' + one + '”' : items.length + ' itens';
    if (name === 'rename') {
      return ask('Mudar o nome', null, one, 'Mudar nome').then(function (v) { if (!v || v === one) return; return api('rename', { p: p, from: one, to: v }).then(done('Nome alterado.')); }).catch(fail);
    }
    if (name === 'move') {
      return ask('Mover ' + label, 'Pasta de destino, a partir da raiz do site (ex.: public_html/img). Vazio = raiz do site.', p, 'Mover').then(function (v) {
        if (v === null) return; return api('move', { p: p, items: items, to: v }).then(done('Movido para /' + v + '.'));
      }).catch(fail);
    }
    if (name === 'zip') {
      return ask('Compactar ' + label, 'Nome do ficheiro ZIP, criado nesta pasta.', (one || 'arquivo') + '.zip', 'Compactar').then(function (v) {
        if (!v) return; toast(true, 'A compactar…'); return api('zip', { p: p, items: items, name: v }).then(done(function (j) { return 'Criado ' + j.name + ' (' + j.count + ' ficheiros).'; }));
      }).catch(fail);
    }
    if (name === 'chmod') {
      var cur = one ? (st.items.filter(function (i) { return i.n === one; })[0] || {}).p : '';
      return ask('Permissões de ' + label, 'Em octal, por exemplo 640 para ficheiros e 2750 para pastas.', (cur || '640').replace(/^0(?=\d{3}$)/, ''), 'Aplicar').then(function (v) {
        if (!v) return; return api('chmod', { p: p, items: items, mode: v }).then(done('Permissões alteradas.'));
      }).catch(fail);
    }
    if (name === 'delete') {
      return ask('Apagar ' + label + '?', 'As pastas são apagadas com todo o conteúdo. Esta ação não pode ser anulada.', null, 'Apagar', true).then(function (ok) {
        if (!ok) return; return api('delete', { p: p, items: items }).then(done(items.length === 1 ? 'Apagado.' : items.length + ' itens apagados.'));
      }).catch(fail);
    }
    if (name === 'extract' || name === 'extractto') {
      var into = name === 'extractto' ? ask('Extrair para uma pasta', 'Nome da pasta a criar nesta localização.', one.replace(ARCH, ''), 'Extrair') : Promise.resolve('');
      return into.then(function (v) {
        if (v === null) return; toast(true, 'A extrair ' + one + '…');
        return api('extract', { p: join(p, one), into: v }).then(done(function (j) { return j.count + ' ficheiro(s) extraído(s)' + (j.skipped ? '; ' + j.skipped + ' ignorado(s) por segurança' : '') + '.'; }));
      }).catch(fail);
    }
  }

  /* ---------- menu de cada item ---------- */
  var menu = $('fm-menu');
  function hideMenu() { menu.hidden = true; }
  function showMenu(it, btn) {
    var o = [];
    if (it.d) o.push(['open', IC.open, 'Abrir']); else o.push(['dl', IC.dl, 'Descarregar']);
    if (!NOEDIT && !it.d && (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n))) o.push(['edit', IC.edit, 'Editar']);
    if (ARCH.test(it.n)) { o.push(['extract', IC.zipb, 'Extrair aqui']); o.push(['extractto', IC.zipb, 'Extrair para pasta…']); }
    o.push(['rename', IC.ren, 'Mudar o nome'], ['move', IC.move, 'Mover…'], ['zip', IC.zipb, 'Compactar em ZIP'], ['chmod', IC.perm, 'Permissões'], ['-'], ['delete', IC.del, 'Apagar']);
    menu.innerHTML = o.map(function (x) { return x[0] === '-' ? '<hr>' : '<button type="button" data-m="' + x[0] + '"' + (x[0] === 'delete' ? ' class="dan"' : '') + '>' + x[1] + x[2] + '</button>'; }).join('');
    menu.hidden = false;
    var r = btn.getBoundingClientRect(), mh = menu.offsetHeight, mw = menu.offsetWidth;
    menu.style.left = Math.max(8, Math.min(window.innerWidth - mw - 8, r.right - mw)) + 'px';
    menu.style.top = (r.bottom + mh + 8 > window.innerHeight ? Math.max(8, r.top - mh - 6) : r.bottom + 6) + 'px';
    menu.onclick = function (e) {
      var b = e.target.closest('[data-m]'); if (!b) return; hideMenu();
      var m = b.getAttribute('data-m');
      if (m === 'open') load(join(st.path, it.n));
      else if (m === 'dl') download(it);
      else if (m === 'edit') edit(join(st.path, it.n));
      else act(m, [it.n]);
    };
  }
  document.addEventListener('click', function (e) { if (!menu.hidden && !e.target.closest('#fm-menu') && !e.target.closest('[data-act="menu"]')) hideMenu(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hideMenu(); });
  window.addEventListener('scroll', hideMenu, true);

  $('fm-rows').addEventListener('click', function (e) {
    var tr = e.target.closest('tr'); if (!tr) return;
    if (tr.getAttribute('data-up')) { var parts = st.path.split('/'); parts.pop(); load(parts.join('/')); return; }
    var it = st.items[+tr.getAttribute('data-i')]; if (!it) return;
    var b = e.target.closest('[data-act]');
    if (b && b.getAttribute('data-act') === 'open') open(it);
    else if (b && b.getAttribute('data-act') === 'menu') { e.stopPropagation(); if (!menu.hidden) hideMenu(); else showMenu(it, b); }
  });
  $('fm-rows').addEventListener('change', function (e) {
    var tr = e.target.closest('tr'); var it = tr && st.items[+tr.getAttribute('data-i')]; if (!it) return;
    if (e.target.checked) st.sel[it.n] = 1; else delete st.sel[it.n];
    tr.classList.toggle('sel', e.target.checked); selbar();
  });
  $('fm-all').addEventListener('change', function (e) { st.sel = {}; if (e.target.checked) st.items.forEach(function (i) { st.sel[i.n] = 1; }); render(); });
  $('fm-crumbs').addEventListener('click', function (e) { var b = e.target.closest('[data-path]'); if (b) load(b.getAttribute('data-path')); });
  if ($('fm-site')) $('fm-site').addEventListener('change', function (e) { st.site = e.target.value; load(''); });
  root.addEventListener('click', function (e) {
    var b = e.target.closest('[data-fm]'); if (!b) return;
    var n = b.getAttribute('data-fm');
    if (n === 'clear') { st.sel = {}; render(); return; }
    act(n, n === 'mkdir' || n === 'newfile' ? [] : selected());
  });

  /* ---------- editor ---------- */
  var ed = { path: null, dirty: false }, ta = $('fm-ed-ta'), edDlg = $('fm-ed');
  function edStatus(t) { $('fm-ed-st').textContent = t; }
  function edit(rel) {
    api('get', null, 'p=' + enc(rel)).then(must).then(function (j) {
      ed.path = rel; ed.dirty = false; ta.value = j.content; $('fm-ed-t').textContent = '/' + rel; edStatus('');
      edDlg.showModal(); ta.focus(); ta.setSelectionRange(0, 0); ta.scrollTop = 0;
    }).catch(fail);
  }
  function save() {
    if (!ed.path) return;
    edStatus('A gravar…');
    api('save', { p: ed.path, content: ta.value }).then(must).then(function () {
      ed.dirty = false; var d = new Date(); edStatus('Gravado às ' + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds()));
      load();
    }).catch(function (e) { edStatus(''); fail(e); });
  }
  function edClose() { if (ed.dirty && !window.confirm('Há alterações por gravar. Fechar sem gravar?')) return; ed.dirty = false; edDlg.close(); }
  ta.addEventListener('input', function () { if (!ed.dirty) { ed.dirty = true; edStatus('Alterações por gravar'); } });
  ta.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
    else if (e.key === 'Tab' && !e.shiftKey) { e.preventDefault(); ta.setRangeText('\t', ta.selectionStart, ta.selectionEnd, 'end'); ta.dispatchEvent(new Event('input')); }
  });
  $('fm-ed-save').addEventListener('click', save);
  $('fm-ed-close').addEventListener('click', edClose);
  $('fm-ed-x').addEventListener('click', edClose);
  edDlg.addEventListener('cancel', function (e) { e.preventDefault(); edClose(); });
  window.addEventListener('beforeunload', function (e) { if (ed.dirty || busy) { e.preventDefault(); e.returnValue = ''; } });

  /* ---------- envios por partes, com retoma ---------- */
  var Q = [], busy = false;
  function hash(s) { var h1 = 0x811c9dc5, h2 = 0x01000193; for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); h1 = Math.imul(h1 ^ c, 16777619) >>> 0; h2 = Math.imul(h2 ^ c, 2246822519) >>> 0; } return ('0000000' + h1.toString(16)).slice(-8) + ('0000000' + h2.toString(16)).slice(-8); }
  function upsSummary() {
    var n = Q.length, ok = Q.filter(function (j) { return j.state === 'ok'; }).length, er = Q.filter(function (j) { return j.state === 'err'; }).length;
    $('fm-ups-sum').textContent = ok + ' de ' + n + ' concluído(s)' + (er ? ', ' + er + ' com erro' : '');
  }
  function upRow(job) {
    var d = document.createElement('div'); d.className = 'up';
    d.innerHTML = '<div class="nm2"><span></span><span>em espera</span></div><div class="bar"><i></i></div>';
    d.querySelector('span').textContent = job.rel; $('fm-ups-list').appendChild(d); return d;
  }
  function upSet(job, pct, txt, cls) {
    job.ui.querySelector('i').style.width = pct + '%';
    job.ui.querySelector('.nm2 span:last-child').textContent = txt;
    if (cls) job.ui.className = 'up ' + cls;
  }
  function enqueue(list) {
    if (!list.length) return;
    var p = st.path, site = st.site, names = {};
    st.items.forEach(function (i) { names[i.n] = 1; });
    var clash = list.filter(function (f) { return names[f.rel.split('/')[0]]; }).length;
    var go = clash ? ask('Substituir ficheiros?', clash + ' ficheiro(s) ou pasta(s) com o mesmo nome já existem nesta pasta. Os ficheiros existentes serão substituídos.', null, 'Substituir', true) : Promise.resolve(true);
    go.then(function (ok) {
      if (!ok) return;
      list.forEach(function (f) {
        var job = { f: f.file, rel: f.rel, dir: p, site: site, ow: !!clash, tries: 0, state: 'wait' };
        job.id = 'u' + hash(site + '|' + p + '|' + f.rel + '|' + f.file.size + '|' + f.file.lastModified);
        job.ui = upRow(job); Q.push(job);
      });
      $('fm-ups').hidden = false; upsSummary(); pump();
    });
  }
  function pump() {
    if (busy) return;
    var job = Q.filter(function (j) { return j.state === 'wait'; })[0];
    if (!job) { upsSummary(); if (job === undefined) load(); return; }
    busy = true; job.state = 'run';
    run(job).then(function () { busy = false; upsSummary(); pump(); });
  }
  function run(job) {
    var b = base(job.site);
    function send(off) {
      var fd = new FormData();
      fd.append('id', job.id); fd.append('p', job.dir); fd.append('name', job.rel);
      fd.append('offset', off); fd.append('total', job.f.size);
      if (job.ow) fd.append('overwrite', '1');
      fd.append('chunk', job.f.slice(off, Math.min(off + CH, job.f.size)), 'chunk');
      return fetch(b + '?a=upload', { method: 'POST', credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, body: fd })
        .then(function (r) { if (r.redirected) { location.reload(); throw new Error('A sessão expirou.'); } return r.json().then(function (j) { return { s: r.status, j: j }; }); });
    }
    function loop(off) {
      upSet(job, job.f.size ? Math.floor(off * 100 / job.f.size) : 0, bytes(off) + ' de ' + bytes(job.f.size));
      return send(off).then(function (res) {
        var j = res.j;
        if (j.ok && j.done) { job.state = 'ok'; upSet(job, 100, 'concluído', 'ok'); return; }
        if (j.ok) { job.tries = 0; return loop(j.size); }
        if (j.exists) { var e = new Error(j.error); e.fatal = true; throw e; }
        if (res.s === 409 && typeof j.size === 'number') return loop(j.size);
        throw new Error(j.error || 'Falha no envio.');
      });
    }
    return fetch(b + '?a=upstat&id=' + job.id, { credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, cache: 'no-store' })
      .then(function (r) { return r.json(); }).then(function (j) { return loop(j.size || 0); })
      .catch(function (e) {
        job.tries++;
        if (!e.fatal && job.tries <= 6) {
          upSet(job, 0, 'a retomar (' + job.tries + ')…');
          return new Promise(function (r) { setTimeout(r, 1500 * job.tries); }).then(function () { return run(job); });
        }
        job.state = 'err'; upSet(job, 100, e.message || 'erro', 'err');
      });
  }
  $('fm-ups-close').addEventListener('click', function () {
    if (busy && !window.confirm('Há envios em curso. Esconder o painel de envios? Os envios continuam.')) return;
    if (!busy) { Q = Q.filter(function (j) { return j.state === 'wait' || j.state === 'run'; }); $('fm-ups-list').innerHTML = ''; }
    $('fm-ups').hidden = true;
  });
  function fromInput(input) {
    var list = Array.prototype.map.call(input.files, function (f) { return { file: f, rel: f.webkitRelativePath || f.name }; });
    input.value = ''; enqueue(list);
  }
  $('fm-upfiles').addEventListener('change', function (e) { fromInput(e.target); });
  $('fm-updir').addEventListener('change', function (e) { fromInput(e.target); });

  var drop = $('fm-drop'), depth = 0;
  function walk(en, pre) {
    if (en.isFile) return new Promise(function (res) { en.file(function (f) { res([{ file: f, rel: pre + f.name }]); }, function () { res([]); }); });
    if (!en.isDirectory) return Promise.resolve([]);
    var rd = en.createReader(), all = [];
    return new Promise(function (res) {
      (function next() {
        rd.readEntries(function (list) {
          if (!list.length) {
            Promise.all(all.map(function (c) { return walk(c, pre + en.name + '/'); })).then(function (a) { res([].concat.apply([], a)); });
          } else { all = all.concat(Array.prototype.slice.call(list)); next(); }
        }, function () { res([]); });
      })();
    });
  }
  drop.addEventListener('dragenter', function (e) { if (e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') >= 0) { depth++; drop.classList.add('over'); } });
  drop.addEventListener('dragover', function (e) { e.preventDefault(); });
  drop.addEventListener('dragleave', function () { if (--depth <= 0) { depth = 0; drop.classList.remove('over'); } });
  drop.addEventListener('drop', function (e) {
    e.preventDefault(); depth = 0; drop.classList.remove('over');
    var dt = e.dataTransfer, items = dt.items;
    if (items && items.length && items[0].webkitGetAsEntry) {
      var entries = [];
      for (var i = 0; i < items.length; i++) { var en = items[i].webkitGetAsEntry(); if (en) entries.push(en); }
      Promise.all(entries.map(function (en) { return walk(en, ''); })).then(function (a) { enqueue([].concat.apply([], a)); });
    } else {
      enqueue(Array.prototype.map.call(dt.files, function (f) { return { file: f, rel: f.name }; }));
    }
  });

  load(root.getAttribute('data-dir') || '');
})();
</script>
<?php endif; ?>
</body>
</html>
MPPANEL
chown -R root:root /opt/minipainel/public
chmod 644 /opt/minipainel/public/index.php
# qrcode-generator (c) Kazuhiko Arase, licença MIT — usado para o código QR do 2FA
cat > /opt/minipainel/qrcode.js <<'MPQR'
//---------------------------------------------------------------------
//
// QR Code Generator for JavaScript
//
// Copyright (c) 2009 Kazuhiko Arase
//
// URL: http://www.d-project.com/
//
// Licensed under the MIT license:
//  http://www.opensource.org/licenses/mit-license.php
//
// The word 'QR Code' is registered trademark of
// DENSO WAVE INCORPORATED
//  http://www.denso-wave.com/qrcode/faqpatent-e.html
//
//---------------------------------------------------------------------

var qrcode = function() {

  //---------------------------------------------------------------------
  // qrcode
  //---------------------------------------------------------------------

  /**
   * qrcode
   * @param typeNumber 1 to 40
   * @param errorCorrectionLevel 'L','M','Q','H'
   */
  var qrcode = function(typeNumber, errorCorrectionLevel) {

    var PAD0 = 0xEC;
    var PAD1 = 0x11;

    var _typeNumber = typeNumber;
    var _errorCorrectionLevel = QRErrorCorrectionLevel[errorCorrectionLevel];
    var _modules = null;
    var _moduleCount = 0;
    var _dataCache = null;
    var _dataList = [];

    var _this = {};

    var makeImpl = function(test, maskPattern) {

      _moduleCount = _typeNumber * 4 + 17;
      _modules = function(moduleCount) {
        var modules = new Array(moduleCount);
        for (var row = 0; row < moduleCount; row += 1) {
          modules[row] = new Array(moduleCount);
          for (var col = 0; col < moduleCount; col += 1) {
            modules[row][col] = null;
          }
        }
        return modules;
      }(_moduleCount);

      setupPositionProbePattern(0, 0);
      setupPositionProbePattern(_moduleCount - 7, 0);
      setupPositionProbePattern(0, _moduleCount - 7);
      setupPositionAdjustPattern();
      setupTimingPattern();
      setupTypeInfo(test, maskPattern);

      if (_typeNumber >= 7) {
        setupTypeNumber(test);
      }

      if (_dataCache == null) {
        _dataCache = createData(_typeNumber, _errorCorrectionLevel, _dataList);
      }

      mapData(_dataCache, maskPattern);
    };

    var setupPositionProbePattern = function(row, col) {

      for (var r = -1; r <= 7; r += 1) {

        if (row + r <= -1 || _moduleCount <= row + r) continue;

        for (var c = -1; c <= 7; c += 1) {

          if (col + c <= -1 || _moduleCount <= col + c) continue;

          if ( (0 <= r && r <= 6 && (c == 0 || c == 6) )
              || (0 <= c && c <= 6 && (r == 0 || r == 6) )
              || (2 <= r && r <= 4 && 2 <= c && c <= 4) ) {
            _modules[row + r][col + c] = true;
          } else {
            _modules[row + r][col + c] = false;
          }
        }
      }
    };

    var getBestMaskPattern = function() {

      var minLostPoint = 0;
      var pattern = 0;

      for (var i = 0; i < 8; i += 1) {

        makeImpl(true, i);

        var lostPoint = QRUtil.getLostPoint(_this);

        if (i == 0 || minLostPoint > lostPoint) {
          minLostPoint = lostPoint;
          pattern = i;
        }
      }

      return pattern;
    };

    var setupTimingPattern = function() {

      for (var r = 8; r < _moduleCount - 8; r += 1) {
        if (_modules[r][6] != null) {
          continue;
        }
        _modules[r][6] = (r % 2 == 0);
      }

      for (var c = 8; c < _moduleCount - 8; c += 1) {
        if (_modules[6][c] != null) {
          continue;
        }
        _modules[6][c] = (c % 2 == 0);
      }
    };

    var setupPositionAdjustPattern = function() {

      var pos = QRUtil.getPatternPosition(_typeNumber);

      for (var i = 0; i < pos.length; i += 1) {

        for (var j = 0; j < pos.length; j += 1) {

          var row = pos[i];
          var col = pos[j];

          if (_modules[row][col] != null) {
            continue;
          }

          for (var r = -2; r <= 2; r += 1) {

            for (var c = -2; c <= 2; c += 1) {

              if (r == -2 || r == 2 || c == -2 || c == 2
                  || (r == 0 && c == 0) ) {
                _modules[row + r][col + c] = true;
              } else {
                _modules[row + r][col + c] = false;
              }
            }
          }
        }
      }
    };

    var setupTypeNumber = function(test) {

      var bits = QRUtil.getBCHTypeNumber(_typeNumber);

      for (var i = 0; i < 18; i += 1) {
        var mod = (!test && ( (bits >> i) & 1) == 1);
        _modules[Math.floor(i / 3)][i % 3 + _moduleCount - 8 - 3] = mod;
      }

      for (var i = 0; i < 18; i += 1) {
        var mod = (!test && ( (bits >> i) & 1) == 1);
        _modules[i % 3 + _moduleCount - 8 - 3][Math.floor(i / 3)] = mod;
      }
    };

    var setupTypeInfo = function(test, maskPattern) {

      var data = (_errorCorrectionLevel << 3) | maskPattern;
      var bits = QRUtil.getBCHTypeInfo(data);

      // vertical
      for (var i = 0; i < 15; i += 1) {

        var mod = (!test && ( (bits >> i) & 1) == 1);

        if (i < 6) {
          _modules[i][8] = mod;
        } else if (i < 8) {
          _modules[i + 1][8] = mod;
        } else {
          _modules[_moduleCount - 15 + i][8] = mod;
        }
      }

      // horizontal
      for (var i = 0; i < 15; i += 1) {

        var mod = (!test && ( (bits >> i) & 1) == 1);

        if (i < 8) {
          _modules[8][_moduleCount - i - 1] = mod;
        } else if (i < 9) {
          _modules[8][15 - i - 1 + 1] = mod;
        } else {
          _modules[8][15 - i - 1] = mod;
        }
      }

      // fixed module
      _modules[_moduleCount - 8][8] = (!test);
    };

    var mapData = function(data, maskPattern) {

      var inc = -1;
      var row = _moduleCount - 1;
      var bitIndex = 7;
      var byteIndex = 0;
      var maskFunc = QRUtil.getMaskFunction(maskPattern);

      for (var col = _moduleCount - 1; col > 0; col -= 2) {

        if (col == 6) col -= 1;

        while (true) {

          for (var c = 0; c < 2; c += 1) {

            if (_modules[row][col - c] == null) {

              var dark = false;

              if (byteIndex < data.length) {
                dark = ( ( (data[byteIndex] >>> bitIndex) & 1) == 1);
              }

              var mask = maskFunc(row, col - c);

              if (mask) {
                dark = !dark;
              }

              _modules[row][col - c] = dark;
              bitIndex -= 1;

              if (bitIndex == -1) {
                byteIndex += 1;
                bitIndex = 7;
              }
            }
          }

          row += inc;

          if (row < 0 || _moduleCount <= row) {
            row -= inc;
            inc = -inc;
            break;
          }
        }
      }
    };

    var createBytes = function(buffer, rsBlocks) {

      var offset = 0;

      var maxDcCount = 0;
      var maxEcCount = 0;

      var dcdata = new Array(rsBlocks.length);
      var ecdata = new Array(rsBlocks.length);

      for (var r = 0; r < rsBlocks.length; r += 1) {

        var dcCount = rsBlocks[r].dataCount;
        var ecCount = rsBlocks[r].totalCount - dcCount;

        maxDcCount = Math.max(maxDcCount, dcCount);
        maxEcCount = Math.max(maxEcCount, ecCount);

        dcdata[r] = new Array(dcCount);

        for (var i = 0; i < dcdata[r].length; i += 1) {
          dcdata[r][i] = 0xff & buffer.getBuffer()[i + offset];
        }
        offset += dcCount;

        var rsPoly = QRUtil.getErrorCorrectPolynomial(ecCount);
        var rawPoly = qrPolynomial(dcdata[r], rsPoly.getLength() - 1);

        var modPoly = rawPoly.mod(rsPoly);
        ecdata[r] = new Array(rsPoly.getLength() - 1);
        for (var i = 0; i < ecdata[r].length; i += 1) {
          var modIndex = i + modPoly.getLength() - ecdata[r].length;
          ecdata[r][i] = (modIndex >= 0)? modPoly.getAt(modIndex) : 0;
        }
      }

      var totalCodeCount = 0;
      for (var i = 0; i < rsBlocks.length; i += 1) {
        totalCodeCount += rsBlocks[i].totalCount;
      }

      var data = new Array(totalCodeCount);
      var index = 0;

      for (var i = 0; i < maxDcCount; i += 1) {
        for (var r = 0; r < rsBlocks.length; r += 1) {
          if (i < dcdata[r].length) {
            data[index] = dcdata[r][i];
            index += 1;
          }
        }
      }

      for (var i = 0; i < maxEcCount; i += 1) {
        for (var r = 0; r < rsBlocks.length; r += 1) {
          if (i < ecdata[r].length) {
            data[index] = ecdata[r][i];
            index += 1;
          }
        }
      }

      return data;
    };

    var createData = function(typeNumber, errorCorrectionLevel, dataList) {

      var rsBlocks = QRRSBlock.getRSBlocks(typeNumber, errorCorrectionLevel);

      var buffer = qrBitBuffer();

      for (var i = 0; i < dataList.length; i += 1) {
        var data = dataList[i];
        buffer.put(data.getMode(), 4);
        buffer.put(data.getLength(), QRUtil.getLengthInBits(data.getMode(), typeNumber) );
        data.write(buffer);
      }

      // calc num max data.
      var totalDataCount = 0;
      for (var i = 0; i < rsBlocks.length; i += 1) {
        totalDataCount += rsBlocks[i].dataCount;
      }

      if (buffer.getLengthInBits() > totalDataCount * 8) {
        throw 'code length overflow. ('
          + buffer.getLengthInBits()
          + '>'
          + totalDataCount * 8
          + ')';
      }

      // end code
      if (buffer.getLengthInBits() + 4 <= totalDataCount * 8) {
        buffer.put(0, 4);
      }

      // padding
      while (buffer.getLengthInBits() % 8 != 0) {
        buffer.putBit(false);
      }

      // padding
      while (true) {

        if (buffer.getLengthInBits() >= totalDataCount * 8) {
          break;
        }
        buffer.put(PAD0, 8);

        if (buffer.getLengthInBits() >= totalDataCount * 8) {
          break;
        }
        buffer.put(PAD1, 8);
      }

      return createBytes(buffer, rsBlocks);
    };

    _this.addData = function(data, mode) {

      mode = mode || 'Byte';

      var newData = null;

      switch(mode) {
      case 'Numeric' :
        newData = qrNumber(data);
        break;
      case 'Alphanumeric' :
        newData = qrAlphaNum(data);
        break;
      case 'Byte' :
        newData = qr8BitByte(data);
        break;
      case 'Kanji' :
        newData = qrKanji(data);
        break;
      default :
        throw 'mode:' + mode;
      }

      _dataList.push(newData);
      _dataCache = null;
    };

    _this.isDark = function(row, col) {
      if (row < 0 || _moduleCount <= row || col < 0 || _moduleCount <= col) {
        throw row + ',' + col;
      }
      return _modules[row][col];
    };

    _this.getModuleCount = function() {
      return _moduleCount;
    };

    _this.make = function() {
      if (_typeNumber < 1) {
        var typeNumber = 1;

        for (; typeNumber < 40; typeNumber++) {
          var rsBlocks = QRRSBlock.getRSBlocks(typeNumber, _errorCorrectionLevel);
          var buffer = qrBitBuffer();

          for (var i = 0; i < _dataList.length; i++) {
            var data = _dataList[i];
            buffer.put(data.getMode(), 4);
            buffer.put(data.getLength(), QRUtil.getLengthInBits(data.getMode(), typeNumber) );
            data.write(buffer);
          }

          var totalDataCount = 0;
          for (var i = 0; i < rsBlocks.length; i++) {
            totalDataCount += rsBlocks[i].dataCount;
          }

          if (buffer.getLengthInBits() <= totalDataCount * 8) {
            break;
          }
        }

        _typeNumber = typeNumber;
      }

      makeImpl(false, getBestMaskPattern() );
    };

    _this.createTableTag = function(cellSize, margin) {

      cellSize = cellSize || 2;
      margin = (typeof margin == 'undefined')? cellSize * 4 : margin;

      var qrHtml = '';

      qrHtml += '<table style="';
      qrHtml += ' border-width: 0px; border-style: none;';
      qrHtml += ' border-collapse: collapse;';
      qrHtml += ' padding: 0px; margin: ' + margin + 'px;';
      qrHtml += '">';
      qrHtml += '<tbody>';

      for (var r = 0; r < _this.getModuleCount(); r += 1) {

        qrHtml += '<tr>';

        for (var c = 0; c < _this.getModuleCount(); c += 1) {
          qrHtml += '<td style="';
          qrHtml += ' border-width: 0px; border-style: none;';
          qrHtml += ' border-collapse: collapse;';
          qrHtml += ' padding: 0px; margin: 0px;';
          qrHtml += ' width: ' + cellSize + 'px;';
          qrHtml += ' height: ' + cellSize + 'px;';
          qrHtml += ' background-color: ';
          qrHtml += _this.isDark(r, c)? '#000000' : '#ffffff';
          qrHtml += ';';
          qrHtml += '"/>';
        }

        qrHtml += '</tr>';
      }

      qrHtml += '</tbody>';
      qrHtml += '</table>';

      return qrHtml;
    };

    _this.createSvgTag = function(cellSize, margin, alt, title) {

      var opts = {};
      if (typeof arguments[0] == 'object') {
        // Called by options.
        opts = arguments[0];
        // overwrite cellSize and margin.
        cellSize = opts.cellSize;
        margin = opts.margin;
        alt = opts.alt;
        title = opts.title;
      }

      cellSize = cellSize || 2;
      margin = (typeof margin == 'undefined')? cellSize * 4 : margin;

      // Compose alt property surrogate
      alt = (typeof alt === 'string') ? {text: alt} : alt || {};
      alt.text = alt.text || null;
      alt.id = (alt.text) ? alt.id || 'qrcode-description' : null;

      // Compose title property surrogate
      title = (typeof title === 'string') ? {text: title} : title || {};
      title.text = title.text || null;
      title.id = (title.text) ? title.id || 'qrcode-title' : null;

      var size = _this.getModuleCount() * cellSize + margin * 2;
      var c, mc, r, mr, qrSvg='', rect;

      rect = 'l' + cellSize + ',0 0,' + cellSize +
        ' -' + cellSize + ',0 0,-' + cellSize + 'z ';

      qrSvg += '<svg version="1.1" xmlns="http://www.w3.org/2000/svg"';
      qrSvg += !opts.scalable ? ' width="' + size + 'px" height="' + size + 'px"' : '';
      qrSvg += ' viewBox="0 0 ' + size + ' ' + size + '" ';
      qrSvg += ' preserveAspectRatio="xMinYMin meet"';
      qrSvg += (title.text || alt.text) ? ' role="img" aria-labelledby="' +
          escapeXml([title.id, alt.id].join(' ').trim() ) + '"' : '';
      qrSvg += '>';
      qrSvg += (title.text) ? '<title id="' + escapeXml(title.id) + '">' +
          escapeXml(title.text) + '</title>' : '';
      qrSvg += (alt.text) ? '<description id="' + escapeXml(alt.id) + '">' +
          escapeXml(alt.text) + '</description>' : '';
      qrSvg += '<rect width="100%" height="100%" fill="white" cx="0" cy="0"/>';
      qrSvg += '<path d="';

      for (r = 0; r < _this.getModuleCount(); r += 1) {
        mr = r * cellSize + margin;
        for (c = 0; c < _this.getModuleCount(); c += 1) {
          if (_this.isDark(r, c) ) {
            mc = c*cellSize+margin;
            qrSvg += 'M' + mc + ',' + mr + rect;
          }
        }
      }

      qrSvg += '" stroke="transparent" fill="black"/>';
      qrSvg += '</svg>';

      return qrSvg;
    };

    _this.createDataURL = function(cellSize, margin) {

      cellSize = cellSize || 2;
      margin = (typeof margin == 'undefined')? cellSize * 4 : margin;

      var size = _this.getModuleCount() * cellSize + margin * 2;
      var min = margin;
      var max = size - margin;

      return createDataURL(size, size, function(x, y) {
        if (min <= x && x < max && min <= y && y < max) {
          var c = Math.floor( (x - min) / cellSize);
          var r = Math.floor( (y - min) / cellSize);
          return _this.isDark(r, c)? 0 : 1;
        } else {
          return 1;
        }
      } );
    };

    _this.createImgTag = function(cellSize, margin, alt) {

      cellSize = cellSize || 2;
      margin = (typeof margin == 'undefined')? cellSize * 4 : margin;

      var size = _this.getModuleCount() * cellSize + margin * 2;

      var img = '';
      img += '<img';
      img += '\u0020src="';
      img += _this.createDataURL(cellSize, margin);
      img += '"';
      img += '\u0020width="';
      img += size;
      img += '"';
      img += '\u0020height="';
      img += size;
      img += '"';
      if (alt) {
        img += '\u0020alt="';
        img += escapeXml(alt);
        img += '"';
      }
      img += '/>';

      return img;
    };

    var escapeXml = function(s) {
      var escaped = '';
      for (var i = 0; i < s.length; i += 1) {
        var c = s.charAt(i);
        switch(c) {
        case '<': escaped += '&lt;'; break;
        case '>': escaped += '&gt;'; break;
        case '&': escaped += '&amp;'; break;
        case '"': escaped += '&quot;'; break;
        default : escaped += c; break;
        }
      }
      return escaped;
    };

    var _createHalfASCII = function(margin) {
      var cellSize = 1;
      margin = (typeof margin == 'undefined')? cellSize * 2 : margin;

      var size = _this.getModuleCount() * cellSize + margin * 2;
      var min = margin;
      var max = size - margin;

      var y, x, r1, r2, p;

      var blocks = {
        '██': '█',
        '█ ': '▀',
        ' █': '▄',
        '  ': ' '
      };

      var blocksLastLineNoMargin = {
        '██': '▀',
        '█ ': '▀',
        ' █': ' ',
        '  ': ' '
      };

      var ascii = '';
      for (y = 0; y < size; y += 2) {
        r1 = Math.floor((y - min) / cellSize);
        r2 = Math.floor((y + 1 - min) / cellSize);
        for (x = 0; x < size; x += 1) {
          p = '█';

          if (min <= x && x < max && min <= y && y < max && _this.isDark(r1, Math.floor((x - min) / cellSize))) {
            p = ' ';
          }

          if (min <= x && x < max && min <= y+1 && y+1 < max && _this.isDark(r2, Math.floor((x - min) / cellSize))) {
            p += ' ';
          }
          else {
            p += '█';
          }

          // Output 2 characters per pixel, to create full square. 1 character per pixels gives only half width of square.
          ascii += (margin < 1 && y+1 >= max) ? blocksLastLineNoMargin[p] : blocks[p];
        }

        ascii += '\n';
      }

      if (size % 2 && margin > 0) {
        return ascii.substring(0, ascii.length - size - 1) + Array(size+1).join('▀');
      }

      return ascii.substring(0, ascii.length-1);
    };

    _this.createASCII = function(cellSize, margin) {
      cellSize = cellSize || 1;

      if (cellSize < 2) {
        return _createHalfASCII(margin);
      }

      cellSize -= 1;
      margin = (typeof margin == 'undefined')? cellSize * 2 : margin;

      var size = _this.getModuleCount() * cellSize + margin * 2;
      var min = margin;
      var max = size - margin;

      var y, x, r, p;

      var white = Array(cellSize+1).join('██');
      var black = Array(cellSize+1).join('  ');

      var ascii = '';
      var line = '';
      for (y = 0; y < size; y += 1) {
        r = Math.floor( (y - min) / cellSize);
        line = '';
        for (x = 0; x < size; x += 1) {
          p = 1;

          if (min <= x && x < max && min <= y && y < max && _this.isDark(r, Math.floor((x - min) / cellSize))) {
            p = 0;
          }

          // Output 2 characters per pixel, to create full square. 1 character per pixels gives only half width of square.
          line += p ? white : black;
        }

        for (r = 0; r < cellSize; r += 1) {
          ascii += line + '\n';
        }
      }

      return ascii.substring(0, ascii.length-1);
    };

    _this.renderTo2dContext = function(context, cellSize) {
      cellSize = cellSize || 2;
      var length = _this.getModuleCount();
      for (var row = 0; row < length; row++) {
        for (var col = 0; col < length; col++) {
          context.fillStyle = _this.isDark(row, col) ? 'black' : 'white';
          context.fillRect(col * cellSize, row * cellSize, cellSize, cellSize);
        }
      }
    }

    return _this;
  };

  //---------------------------------------------------------------------
  // qrcode.stringToBytes
  //---------------------------------------------------------------------

  qrcode.stringToBytesFuncs = {
    'default' : function(s) {
      var bytes = [];
      for (var i = 0; i < s.length; i += 1) {
        var c = s.charCodeAt(i);
        bytes.push(c & 0xff);
      }
      return bytes;
    }
  };

  qrcode.stringToBytes = qrcode.stringToBytesFuncs['default'];

  //---------------------------------------------------------------------
  // qrcode.createStringToBytes
  //---------------------------------------------------------------------

  /**
   * @param unicodeData base64 string of byte array.
   * [16bit Unicode],[16bit Bytes], ...
   * @param numChars
   */
  qrcode.createStringToBytes = function(unicodeData, numChars) {

    // create conversion map.

    var unicodeMap = function() {

      var bin = base64DecodeInputStream(unicodeData);
      var read = function() {
        var b = bin.read();
        if (b == -1) throw 'eof';
        return b;
      };

      var count = 0;
      var unicodeMap = {};
      while (true) {
        var b0 = bin.read();
        if (b0 == -1) break;
        var b1 = read();
        var b2 = read();
        var b3 = read();
        var k = String.fromCharCode( (b0 << 8) | b1);
        var v = (b2 << 8) | b3;
        unicodeMap[k] = v;
        count += 1;
      }
      if (count != numChars) {
        throw count + ' != ' + numChars;
      }

      return unicodeMap;
    }();

    var unknownChar = '?'.charCodeAt(0);

    return function(s) {
      var bytes = [];
      for (var i = 0; i < s.length; i += 1) {
        var c = s.charCodeAt(i);
        if (c < 128) {
          bytes.push(c);
        } else {
          var b = unicodeMap[s.charAt(i)];
          if (typeof b == 'number') {
            if ( (b & 0xff) == b) {
              // 1byte
              bytes.push(b);
            } else {
              // 2bytes
              bytes.push(b >>> 8);
              bytes.push(b & 0xff);
            }
          } else {
            bytes.push(unknownChar);
          }
        }
      }
      return bytes;
    };
  };

  //---------------------------------------------------------------------
  // QRMode
  //---------------------------------------------------------------------

  var QRMode = {
    MODE_NUMBER :    1 << 0,
    MODE_ALPHA_NUM : 1 << 1,
    MODE_8BIT_BYTE : 1 << 2,
    MODE_KANJI :     1 << 3
  };

  //---------------------------------------------------------------------
  // QRErrorCorrectionLevel
  //---------------------------------------------------------------------

  var QRErrorCorrectionLevel = {
    L : 1,
    M : 0,
    Q : 3,
    H : 2
  };

  //---------------------------------------------------------------------
  // QRMaskPattern
  //---------------------------------------------------------------------

  var QRMaskPattern = {
    PATTERN000 : 0,
    PATTERN001 : 1,
    PATTERN010 : 2,
    PATTERN011 : 3,
    PATTERN100 : 4,
    PATTERN101 : 5,
    PATTERN110 : 6,
    PATTERN111 : 7
  };

  //---------------------------------------------------------------------
  // QRUtil
  //---------------------------------------------------------------------

  var QRUtil = function() {

    var PATTERN_POSITION_TABLE = [
      [],
      [6, 18],
      [6, 22],
      [6, 26],
      [6, 30],
      [6, 34],
      [6, 22, 38],
      [6, 24, 42],
      [6, 26, 46],
      [6, 28, 50],
      [6, 30, 54],
      [6, 32, 58],
      [6, 34, 62],
      [6, 26, 46, 66],
      [6, 26, 48, 70],
      [6, 26, 50, 74],
      [6, 30, 54, 78],
      [6, 30, 56, 82],
      [6, 30, 58, 86],
      [6, 34, 62, 90],
      [6, 28, 50, 72, 94],
      [6, 26, 50, 74, 98],
      [6, 30, 54, 78, 102],
      [6, 28, 54, 80, 106],
      [6, 32, 58, 84, 110],
      [6, 30, 58, 86, 114],
      [6, 34, 62, 90, 118],
      [6, 26, 50, 74, 98, 122],
      [6, 30, 54, 78, 102, 126],
      [6, 26, 52, 78, 104, 130],
      [6, 30, 56, 82, 108, 134],
      [6, 34, 60, 86, 112, 138],
      [6, 30, 58, 86, 114, 142],
      [6, 34, 62, 90, 118, 146],
      [6, 30, 54, 78, 102, 126, 150],
      [6, 24, 50, 76, 102, 128, 154],
      [6, 28, 54, 80, 106, 132, 158],
      [6, 32, 58, 84, 110, 136, 162],
      [6, 26, 54, 82, 110, 138, 166],
      [6, 30, 58, 86, 114, 142, 170]
    ];
    var G15 = (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | (1 << 0);
    var G18 = (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 5) | (1 << 2) | (1 << 0);
    var G15_MASK = (1 << 14) | (1 << 12) | (1 << 10) | (1 << 4) | (1 << 1);

    var _this = {};

    var getBCHDigit = function(data) {
      var digit = 0;
      while (data != 0) {
        digit += 1;
        data >>>= 1;
      }
      return digit;
    };

    _this.getBCHTypeInfo = function(data) {
      var d = data << 10;
      while (getBCHDigit(d) - getBCHDigit(G15) >= 0) {
        d ^= (G15 << (getBCHDigit(d) - getBCHDigit(G15) ) );
      }
      return ( (data << 10) | d) ^ G15_MASK;
    };

    _this.getBCHTypeNumber = function(data) {
      var d = data << 12;
      while (getBCHDigit(d) - getBCHDigit(G18) >= 0) {
        d ^= (G18 << (getBCHDigit(d) - getBCHDigit(G18) ) );
      }
      return (data << 12) | d;
    };

    _this.getPatternPosition = function(typeNumber) {
      return PATTERN_POSITION_TABLE[typeNumber - 1];
    };

    _this.getMaskFunction = function(maskPattern) {

      switch (maskPattern) {

      case QRMaskPattern.PATTERN000 :
        return function(i, j) { return (i + j) % 2 == 0; };
      case QRMaskPattern.PATTERN001 :
        return function(i, j) { return i % 2 == 0; };
      case QRMaskPattern.PATTERN010 :
        return function(i, j) { return j % 3 == 0; };
      case QRMaskPattern.PATTERN011 :
        return function(i, j) { return (i + j) % 3 == 0; };
      case QRMaskPattern.PATTERN100 :
        return function(i, j) { return (Math.floor(i / 2) + Math.floor(j / 3) ) % 2 == 0; };
      case QRMaskPattern.PATTERN101 :
        return function(i, j) { return (i * j) % 2 + (i * j) % 3 == 0; };
      case QRMaskPattern.PATTERN110 :
        return function(i, j) { return ( (i * j) % 2 + (i * j) % 3) % 2 == 0; };
      case QRMaskPattern.PATTERN111 :
        return function(i, j) { return ( (i * j) % 3 + (i + j) % 2) % 2 == 0; };

      default :
        throw 'bad maskPattern:' + maskPattern;
      }
    };

    _this.getErrorCorrectPolynomial = function(errorCorrectLength) {
      var a = qrPolynomial([1], 0);
      for (var i = 0; i < errorCorrectLength; i += 1) {
        a = a.multiply(qrPolynomial([1, QRMath.gexp(i)], 0) );
      }
      return a;
    };

    _this.getLengthInBits = function(mode, type) {

      if (1 <= type && type < 10) {

        // 1 - 9

        switch(mode) {
        case QRMode.MODE_NUMBER    : return 10;
        case QRMode.MODE_ALPHA_NUM : return 9;
        case QRMode.MODE_8BIT_BYTE : return 8;
        case QRMode.MODE_KANJI     : return 8;
        default :
          throw 'mode:' + mode;
        }

      } else if (type < 27) {

        // 10 - 26

        switch(mode) {
        case QRMode.MODE_NUMBER    : return 12;
        case QRMode.MODE_ALPHA_NUM : return 11;
        case QRMode.MODE_8BIT_BYTE : return 16;
        case QRMode.MODE_KANJI     : return 10;
        default :
          throw 'mode:' + mode;
        }

      } else if (type < 41) {

        // 27 - 40

        switch(mode) {
        case QRMode.MODE_NUMBER    : return 14;
        case QRMode.MODE_ALPHA_NUM : return 13;
        case QRMode.MODE_8BIT_BYTE : return 16;
        case QRMode.MODE_KANJI     : return 12;
        default :
          throw 'mode:' + mode;
        }

      } else {
        throw 'type:' + type;
      }
    };

    _this.getLostPoint = function(qrcode) {

      var moduleCount = qrcode.getModuleCount();

      var lostPoint = 0;

      // LEVEL1

      for (var row = 0; row < moduleCount; row += 1) {
        for (var col = 0; col < moduleCount; col += 1) {

          var sameCount = 0;
          var dark = qrcode.isDark(row, col);

          for (var r = -1; r <= 1; r += 1) {

            if (row + r < 0 || moduleCount <= row + r) {
              continue;
            }

            for (var c = -1; c <= 1; c += 1) {

              if (col + c < 0 || moduleCount <= col + c) {
                continue;
              }

              if (r == 0 && c == 0) {
                continue;
              }

              if (dark == qrcode.isDark(row + r, col + c) ) {
                sameCount += 1;
              }
            }
          }

          if (sameCount > 5) {
            lostPoint += (3 + sameCount - 5);
          }
        }
      };

      // LEVEL2

      for (var row = 0; row < moduleCount - 1; row += 1) {
        for (var col = 0; col < moduleCount - 1; col += 1) {
          var count = 0;
          if (qrcode.isDark(row, col) ) count += 1;
          if (qrcode.isDark(row + 1, col) ) count += 1;
          if (qrcode.isDark(row, col + 1) ) count += 1;
          if (qrcode.isDark(row + 1, col + 1) ) count += 1;
          if (count == 0 || count == 4) {
            lostPoint += 3;
          }
        }
      }

      // LEVEL3

      for (var row = 0; row < moduleCount; row += 1) {
        for (var col = 0; col < moduleCount - 6; col += 1) {
          if (qrcode.isDark(row, col)
              && !qrcode.isDark(row, col + 1)
              &&  qrcode.isDark(row, col + 2)
              &&  qrcode.isDark(row, col + 3)
              &&  qrcode.isDark(row, col + 4)
              && !qrcode.isDark(row, col + 5)
              &&  qrcode.isDark(row, col + 6) ) {
            lostPoint += 40;
          }
        }
      }

      for (var col = 0; col < moduleCount; col += 1) {
        for (var row = 0; row < moduleCount - 6; row += 1) {
          if (qrcode.isDark(row, col)
              && !qrcode.isDark(row + 1, col)
              &&  qrcode.isDark(row + 2, col)
              &&  qrcode.isDark(row + 3, col)
              &&  qrcode.isDark(row + 4, col)
              && !qrcode.isDark(row + 5, col)
              &&  qrcode.isDark(row + 6, col) ) {
            lostPoint += 40;
          }
        }
      }

      // LEVEL4

      var darkCount = 0;

      for (var col = 0; col < moduleCount; col += 1) {
        for (var row = 0; row < moduleCount; row += 1) {
          if (qrcode.isDark(row, col) ) {
            darkCount += 1;
          }
        }
      }

      var ratio = Math.abs(100 * darkCount / moduleCount / moduleCount - 50) / 5;
      lostPoint += ratio * 10;

      return lostPoint;
    };

    return _this;
  }();

  //---------------------------------------------------------------------
  // QRMath
  //---------------------------------------------------------------------

  var QRMath = function() {

    var EXP_TABLE = new Array(256);
    var LOG_TABLE = new Array(256);

    // initialize tables
    for (var i = 0; i < 8; i += 1) {
      EXP_TABLE[i] = 1 << i;
    }
    for (var i = 8; i < 256; i += 1) {
      EXP_TABLE[i] = EXP_TABLE[i - 4]
        ^ EXP_TABLE[i - 5]
        ^ EXP_TABLE[i - 6]
        ^ EXP_TABLE[i - 8];
    }
    for (var i = 0; i < 255; i += 1) {
      LOG_TABLE[EXP_TABLE[i] ] = i;
    }

    var _this = {};

    _this.glog = function(n) {

      if (n < 1) {
        throw 'glog(' + n + ')';
      }

      return LOG_TABLE[n];
    };

    _this.gexp = function(n) {

      while (n < 0) {
        n += 255;
      }

      while (n >= 256) {
        n -= 255;
      }

      return EXP_TABLE[n];
    };

    return _this;
  }();

  //---------------------------------------------------------------------
  // qrPolynomial
  //---------------------------------------------------------------------

  function qrPolynomial(num, shift) {

    if (typeof num.length == 'undefined') {
      throw num.length + '/' + shift;
    }

    var _num = function() {
      var offset = 0;
      while (offset < num.length && num[offset] == 0) {
        offset += 1;
      }
      var _num = new Array(num.length - offset + shift);
      for (var i = 0; i < num.length - offset; i += 1) {
        _num[i] = num[i + offset];
      }
      return _num;
    }();

    var _this = {};

    _this.getAt = function(index) {
      return _num[index];
    };

    _this.getLength = function() {
      return _num.length;
    };

    _this.multiply = function(e) {

      var num = new Array(_this.getLength() + e.getLength() - 1);

      for (var i = 0; i < _this.getLength(); i += 1) {
        for (var j = 0; j < e.getLength(); j += 1) {
          num[i + j] ^= QRMath.gexp(QRMath.glog(_this.getAt(i) ) + QRMath.glog(e.getAt(j) ) );
        }
      }

      return qrPolynomial(num, 0);
    };

    _this.mod = function(e) {

      if (_this.getLength() - e.getLength() < 0) {
        return _this;
      }

      var ratio = QRMath.glog(_this.getAt(0) ) - QRMath.glog(e.getAt(0) );

      var num = new Array(_this.getLength() );
      for (var i = 0; i < _this.getLength(); i += 1) {
        num[i] = _this.getAt(i);
      }

      for (var i = 0; i < e.getLength(); i += 1) {
        num[i] ^= QRMath.gexp(QRMath.glog(e.getAt(i) ) + ratio);
      }

      // recursive call
      return qrPolynomial(num, 0).mod(e);
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // QRRSBlock
  //---------------------------------------------------------------------

  var QRRSBlock = function() {

    var RS_BLOCK_TABLE = [

      // L
      // M
      // Q
      // H

      // 1
      [1, 26, 19],
      [1, 26, 16],
      [1, 26, 13],
      [1, 26, 9],

      // 2
      [1, 44, 34],
      [1, 44, 28],
      [1, 44, 22],
      [1, 44, 16],

      // 3
      [1, 70, 55],
      [1, 70, 44],
      [2, 35, 17],
      [2, 35, 13],

      // 4
      [1, 100, 80],
      [2, 50, 32],
      [2, 50, 24],
      [4, 25, 9],

      // 5
      [1, 134, 108],
      [2, 67, 43],
      [2, 33, 15, 2, 34, 16],
      [2, 33, 11, 2, 34, 12],

      // 6
      [2, 86, 68],
      [4, 43, 27],
      [4, 43, 19],
      [4, 43, 15],

      // 7
      [2, 98, 78],
      [4, 49, 31],
      [2, 32, 14, 4, 33, 15],
      [4, 39, 13, 1, 40, 14],

      // 8
      [2, 121, 97],
      [2, 60, 38, 2, 61, 39],
      [4, 40, 18, 2, 41, 19],
      [4, 40, 14, 2, 41, 15],

      // 9
      [2, 146, 116],
      [3, 58, 36, 2, 59, 37],
      [4, 36, 16, 4, 37, 17],
      [4, 36, 12, 4, 37, 13],

      // 10
      [2, 86, 68, 2, 87, 69],
      [4, 69, 43, 1, 70, 44],
      [6, 43, 19, 2, 44, 20],
      [6, 43, 15, 2, 44, 16],

      // 11
      [4, 101, 81],
      [1, 80, 50, 4, 81, 51],
      [4, 50, 22, 4, 51, 23],
      [3, 36, 12, 8, 37, 13],

      // 12
      [2, 116, 92, 2, 117, 93],
      [6, 58, 36, 2, 59, 37],
      [4, 46, 20, 6, 47, 21],
      [7, 42, 14, 4, 43, 15],

      // 13
      [4, 133, 107],
      [8, 59, 37, 1, 60, 38],
      [8, 44, 20, 4, 45, 21],
      [12, 33, 11, 4, 34, 12],

      // 14
      [3, 145, 115, 1, 146, 116],
      [4, 64, 40, 5, 65, 41],
      [11, 36, 16, 5, 37, 17],
      [11, 36, 12, 5, 37, 13],

      // 15
      [5, 109, 87, 1, 110, 88],
      [5, 65, 41, 5, 66, 42],
      [5, 54, 24, 7, 55, 25],
      [11, 36, 12, 7, 37, 13],

      // 16
      [5, 122, 98, 1, 123, 99],
      [7, 73, 45, 3, 74, 46],
      [15, 43, 19, 2, 44, 20],
      [3, 45, 15, 13, 46, 16],

      // 17
      [1, 135, 107, 5, 136, 108],
      [10, 74, 46, 1, 75, 47],
      [1, 50, 22, 15, 51, 23],
      [2, 42, 14, 17, 43, 15],

      // 18
      [5, 150, 120, 1, 151, 121],
      [9, 69, 43, 4, 70, 44],
      [17, 50, 22, 1, 51, 23],
      [2, 42, 14, 19, 43, 15],

      // 19
      [3, 141, 113, 4, 142, 114],
      [3, 70, 44, 11, 71, 45],
      [17, 47, 21, 4, 48, 22],
      [9, 39, 13, 16, 40, 14],

      // 20
      [3, 135, 107, 5, 136, 108],
      [3, 67, 41, 13, 68, 42],
      [15, 54, 24, 5, 55, 25],
      [15, 43, 15, 10, 44, 16],

      // 21
      [4, 144, 116, 4, 145, 117],
      [17, 68, 42],
      [17, 50, 22, 6, 51, 23],
      [19, 46, 16, 6, 47, 17],

      // 22
      [2, 139, 111, 7, 140, 112],
      [17, 74, 46],
      [7, 54, 24, 16, 55, 25],
      [34, 37, 13],

      // 23
      [4, 151, 121, 5, 152, 122],
      [4, 75, 47, 14, 76, 48],
      [11, 54, 24, 14, 55, 25],
      [16, 45, 15, 14, 46, 16],

      // 24
      [6, 147, 117, 4, 148, 118],
      [6, 73, 45, 14, 74, 46],
      [11, 54, 24, 16, 55, 25],
      [30, 46, 16, 2, 47, 17],

      // 25
      [8, 132, 106, 4, 133, 107],
      [8, 75, 47, 13, 76, 48],
      [7, 54, 24, 22, 55, 25],
      [22, 45, 15, 13, 46, 16],

      // 26
      [10, 142, 114, 2, 143, 115],
      [19, 74, 46, 4, 75, 47],
      [28, 50, 22, 6, 51, 23],
      [33, 46, 16, 4, 47, 17],

      // 27
      [8, 152, 122, 4, 153, 123],
      [22, 73, 45, 3, 74, 46],
      [8, 53, 23, 26, 54, 24],
      [12, 45, 15, 28, 46, 16],

      // 28
      [3, 147, 117, 10, 148, 118],
      [3, 73, 45, 23, 74, 46],
      [4, 54, 24, 31, 55, 25],
      [11, 45, 15, 31, 46, 16],

      // 29
      [7, 146, 116, 7, 147, 117],
      [21, 73, 45, 7, 74, 46],
      [1, 53, 23, 37, 54, 24],
      [19, 45, 15, 26, 46, 16],

      // 30
      [5, 145, 115, 10, 146, 116],
      [19, 75, 47, 10, 76, 48],
      [15, 54, 24, 25, 55, 25],
      [23, 45, 15, 25, 46, 16],

      // 31
      [13, 145, 115, 3, 146, 116],
      [2, 74, 46, 29, 75, 47],
      [42, 54, 24, 1, 55, 25],
      [23, 45, 15, 28, 46, 16],

      // 32
      [17, 145, 115],
      [10, 74, 46, 23, 75, 47],
      [10, 54, 24, 35, 55, 25],
      [19, 45, 15, 35, 46, 16],

      // 33
      [17, 145, 115, 1, 146, 116],
      [14, 74, 46, 21, 75, 47],
      [29, 54, 24, 19, 55, 25],
      [11, 45, 15, 46, 46, 16],

      // 34
      [13, 145, 115, 6, 146, 116],
      [14, 74, 46, 23, 75, 47],
      [44, 54, 24, 7, 55, 25],
      [59, 46, 16, 1, 47, 17],

      // 35
      [12, 151, 121, 7, 152, 122],
      [12, 75, 47, 26, 76, 48],
      [39, 54, 24, 14, 55, 25],
      [22, 45, 15, 41, 46, 16],

      // 36
      [6, 151, 121, 14, 152, 122],
      [6, 75, 47, 34, 76, 48],
      [46, 54, 24, 10, 55, 25],
      [2, 45, 15, 64, 46, 16],

      // 37
      [17, 152, 122, 4, 153, 123],
      [29, 74, 46, 14, 75, 47],
      [49, 54, 24, 10, 55, 25],
      [24, 45, 15, 46, 46, 16],

      // 38
      [4, 152, 122, 18, 153, 123],
      [13, 74, 46, 32, 75, 47],
      [48, 54, 24, 14, 55, 25],
      [42, 45, 15, 32, 46, 16],

      // 39
      [20, 147, 117, 4, 148, 118],
      [40, 75, 47, 7, 76, 48],
      [43, 54, 24, 22, 55, 25],
      [10, 45, 15, 67, 46, 16],

      // 40
      [19, 148, 118, 6, 149, 119],
      [18, 75, 47, 31, 76, 48],
      [34, 54, 24, 34, 55, 25],
      [20, 45, 15, 61, 46, 16]
    ];

    var qrRSBlock = function(totalCount, dataCount) {
      var _this = {};
      _this.totalCount = totalCount;
      _this.dataCount = dataCount;
      return _this;
    };

    var _this = {};

    var getRsBlockTable = function(typeNumber, errorCorrectionLevel) {

      switch(errorCorrectionLevel) {
      case QRErrorCorrectionLevel.L :
        return RS_BLOCK_TABLE[(typeNumber - 1) * 4 + 0];
      case QRErrorCorrectionLevel.M :
        return RS_BLOCK_TABLE[(typeNumber - 1) * 4 + 1];
      case QRErrorCorrectionLevel.Q :
        return RS_BLOCK_TABLE[(typeNumber - 1) * 4 + 2];
      case QRErrorCorrectionLevel.H :
        return RS_BLOCK_TABLE[(typeNumber - 1) * 4 + 3];
      default :
        return undefined;
      }
    };

    _this.getRSBlocks = function(typeNumber, errorCorrectionLevel) {

      var rsBlock = getRsBlockTable(typeNumber, errorCorrectionLevel);

      if (typeof rsBlock == 'undefined') {
        throw 'bad rs block @ typeNumber:' + typeNumber +
            '/errorCorrectionLevel:' + errorCorrectionLevel;
      }

      var length = rsBlock.length / 3;

      var list = [];

      for (var i = 0; i < length; i += 1) {

        var count = rsBlock[i * 3 + 0];
        var totalCount = rsBlock[i * 3 + 1];
        var dataCount = rsBlock[i * 3 + 2];

        for (var j = 0; j < count; j += 1) {
          list.push(qrRSBlock(totalCount, dataCount) );
        }
      }

      return list;
    };

    return _this;
  }();

  //---------------------------------------------------------------------
  // qrBitBuffer
  //---------------------------------------------------------------------

  var qrBitBuffer = function() {

    var _buffer = [];
    var _length = 0;

    var _this = {};

    _this.getBuffer = function() {
      return _buffer;
    };

    _this.getAt = function(index) {
      var bufIndex = Math.floor(index / 8);
      return ( (_buffer[bufIndex] >>> (7 - index % 8) ) & 1) == 1;
    };

    _this.put = function(num, length) {
      for (var i = 0; i < length; i += 1) {
        _this.putBit( ( (num >>> (length - i - 1) ) & 1) == 1);
      }
    };

    _this.getLengthInBits = function() {
      return _length;
    };

    _this.putBit = function(bit) {

      var bufIndex = Math.floor(_length / 8);
      if (_buffer.length <= bufIndex) {
        _buffer.push(0);
      }

      if (bit) {
        _buffer[bufIndex] |= (0x80 >>> (_length % 8) );
      }

      _length += 1;
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // qrNumber
  //---------------------------------------------------------------------

  var qrNumber = function(data) {

    var _mode = QRMode.MODE_NUMBER;
    var _data = data;

    var _this = {};

    _this.getMode = function() {
      return _mode;
    };

    _this.getLength = function(buffer) {
      return _data.length;
    };

    _this.write = function(buffer) {

      var data = _data;

      var i = 0;

      while (i + 2 < data.length) {
        buffer.put(strToNum(data.substring(i, i + 3) ), 10);
        i += 3;
      }

      if (i < data.length) {
        if (data.length - i == 1) {
          buffer.put(strToNum(data.substring(i, i + 1) ), 4);
        } else if (data.length - i == 2) {
          buffer.put(strToNum(data.substring(i, i + 2) ), 7);
        }
      }
    };

    var strToNum = function(s) {
      var num = 0;
      for (var i = 0; i < s.length; i += 1) {
        num = num * 10 + chatToNum(s.charAt(i) );
      }
      return num;
    };

    var chatToNum = function(c) {
      if ('0' <= c && c <= '9') {
        return c.charCodeAt(0) - '0'.charCodeAt(0);
      }
      throw 'illegal char :' + c;
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // qrAlphaNum
  //---------------------------------------------------------------------

  var qrAlphaNum = function(data) {

    var _mode = QRMode.MODE_ALPHA_NUM;
    var _data = data;

    var _this = {};

    _this.getMode = function() {
      return _mode;
    };

    _this.getLength = function(buffer) {
      return _data.length;
    };

    _this.write = function(buffer) {

      var s = _data;

      var i = 0;

      while (i + 1 < s.length) {
        buffer.put(
          getCode(s.charAt(i) ) * 45 +
          getCode(s.charAt(i + 1) ), 11);
        i += 2;
      }

      if (i < s.length) {
        buffer.put(getCode(s.charAt(i) ), 6);
      }
    };

    var getCode = function(c) {

      if ('0' <= c && c <= '9') {
        return c.charCodeAt(0) - '0'.charCodeAt(0);
      } else if ('A' <= c && c <= 'Z') {
        return c.charCodeAt(0) - 'A'.charCodeAt(0) + 10;
      } else {
        switch (c) {
        case ' ' : return 36;
        case '$' : return 37;
        case '%' : return 38;
        case '*' : return 39;
        case '+' : return 40;
        case '-' : return 41;
        case '.' : return 42;
        case '/' : return 43;
        case ':' : return 44;
        default :
          throw 'illegal char :' + c;
        }
      }
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // qr8BitByte
  //---------------------------------------------------------------------

  var qr8BitByte = function(data) {

    var _mode = QRMode.MODE_8BIT_BYTE;
    var _data = data;
    var _bytes = qrcode.stringToBytes(data);

    var _this = {};

    _this.getMode = function() {
      return _mode;
    };

    _this.getLength = function(buffer) {
      return _bytes.length;
    };

    _this.write = function(buffer) {
      for (var i = 0; i < _bytes.length; i += 1) {
        buffer.put(_bytes[i], 8);
      }
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // qrKanji
  //---------------------------------------------------------------------

  var qrKanji = function(data) {

    var _mode = QRMode.MODE_KANJI;
    var _data = data;

    var stringToBytes = qrcode.stringToBytesFuncs['SJIS'];
    if (!stringToBytes) {
      throw 'sjis not supported.';
    }
    !function(c, code) {
      // self test for sjis support.
      var test = stringToBytes(c);
      if (test.length != 2 || ( (test[0] << 8) | test[1]) != code) {
        throw 'sjis not supported.';
      }
    }('\u53cb', 0x9746);

    var _bytes = stringToBytes(data);

    var _this = {};

    _this.getMode = function() {
      return _mode;
    };

    _this.getLength = function(buffer) {
      return ~~(_bytes.length / 2);
    };

    _this.write = function(buffer) {

      var data = _bytes;

      var i = 0;

      while (i + 1 < data.length) {

        var c = ( (0xff & data[i]) << 8) | (0xff & data[i + 1]);

        if (0x8140 <= c && c <= 0x9FFC) {
          c -= 0x8140;
        } else if (0xE040 <= c && c <= 0xEBBF) {
          c -= 0xC140;
        } else {
          throw 'illegal char at ' + (i + 1) + '/' + c;
        }

        c = ( (c >>> 8) & 0xff) * 0xC0 + (c & 0xff);

        buffer.put(c, 13);

        i += 2;
      }

      if (i < data.length) {
        throw 'illegal char at ' + (i + 1);
      }
    };

    return _this;
  };

  //=====================================================================
  // GIF Support etc.
  //

  //---------------------------------------------------------------------
  // byteArrayOutputStream
  //---------------------------------------------------------------------

  var byteArrayOutputStream = function() {

    var _bytes = [];

    var _this = {};

    _this.writeByte = function(b) {
      _bytes.push(b & 0xff);
    };

    _this.writeShort = function(i) {
      _this.writeByte(i);
      _this.writeByte(i >>> 8);
    };

    _this.writeBytes = function(b, off, len) {
      off = off || 0;
      len = len || b.length;
      for (var i = 0; i < len; i += 1) {
        _this.writeByte(b[i + off]);
      }
    };

    _this.writeString = function(s) {
      for (var i = 0; i < s.length; i += 1) {
        _this.writeByte(s.charCodeAt(i) );
      }
    };

    _this.toByteArray = function() {
      return _bytes;
    };

    _this.toString = function() {
      var s = '';
      s += '[';
      for (var i = 0; i < _bytes.length; i += 1) {
        if (i > 0) {
          s += ',';
        }
        s += _bytes[i];
      }
      s += ']';
      return s;
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // base64EncodeOutputStream
  //---------------------------------------------------------------------

  var base64EncodeOutputStream = function() {

    var _buffer = 0;
    var _buflen = 0;
    var _length = 0;
    var _base64 = '';

    var _this = {};

    var writeEncoded = function(b) {
      _base64 += String.fromCharCode(encode(b & 0x3f) );
    };

    var encode = function(n) {
      if (n < 0) {
        // error.
      } else if (n < 26) {
        return 0x41 + n;
      } else if (n < 52) {
        return 0x61 + (n - 26);
      } else if (n < 62) {
        return 0x30 + (n - 52);
      } else if (n == 62) {
        return 0x2b;
      } else if (n == 63) {
        return 0x2f;
      }
      throw 'n:' + n;
    };

    _this.writeByte = function(n) {

      _buffer = (_buffer << 8) | (n & 0xff);
      _buflen += 8;
      _length += 1;

      while (_buflen >= 6) {
        writeEncoded(_buffer >>> (_buflen - 6) );
        _buflen -= 6;
      }
    };

    _this.flush = function() {

      if (_buflen > 0) {
        writeEncoded(_buffer << (6 - _buflen) );
        _buffer = 0;
        _buflen = 0;
      }

      if (_length % 3 != 0) {
        // padding
        var padlen = 3 - _length % 3;
        for (var i = 0; i < padlen; i += 1) {
          _base64 += '=';
        }
      }
    };

    _this.toString = function() {
      return _base64;
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // base64DecodeInputStream
  //---------------------------------------------------------------------

  var base64DecodeInputStream = function(str) {

    var _str = str;
    var _pos = 0;
    var _buffer = 0;
    var _buflen = 0;

    var _this = {};

    _this.read = function() {

      while (_buflen < 8) {

        if (_pos >= _str.length) {
          if (_buflen == 0) {
            return -1;
          }
          throw 'unexpected end of file./' + _buflen;
        }

        var c = _str.charAt(_pos);
        _pos += 1;

        if (c == '=') {
          _buflen = 0;
          return -1;
        } else if (c.match(/^\s$/) ) {
          // ignore if whitespace.
          continue;
        }

        _buffer = (_buffer << 6) | decode(c.charCodeAt(0) );
        _buflen += 6;
      }

      var n = (_buffer >>> (_buflen - 8) ) & 0xff;
      _buflen -= 8;
      return n;
    };

    var decode = function(c) {
      if (0x41 <= c && c <= 0x5a) {
        return c - 0x41;
      } else if (0x61 <= c && c <= 0x7a) {
        return c - 0x61 + 26;
      } else if (0x30 <= c && c <= 0x39) {
        return c - 0x30 + 52;
      } else if (c == 0x2b) {
        return 62;
      } else if (c == 0x2f) {
        return 63;
      } else {
        throw 'c:' + c;
      }
    };

    return _this;
  };

  //---------------------------------------------------------------------
  // gifImage (B/W)
  //---------------------------------------------------------------------

  var gifImage = function(width, height) {

    var _width = width;
    var _height = height;
    var _data = new Array(width * height);

    var _this = {};

    _this.setPixel = function(x, y, pixel) {
      _data[y * _width + x] = pixel;
    };

    _this.write = function(out) {

      //---------------------------------
      // GIF Signature

      out.writeString('GIF87a');

      //---------------------------------
      // Screen Descriptor

      out.writeShort(_width);
      out.writeShort(_height);

      out.writeByte(0x80); // 2bit
      out.writeByte(0);
      out.writeByte(0);

      //---------------------------------
      // Global Color Map

      // black
      out.writeByte(0x00);
      out.writeByte(0x00);
      out.writeByte(0x00);

      // white
      out.writeByte(0xff);
      out.writeByte(0xff);
      out.writeByte(0xff);

      //---------------------------------
      // Image Descriptor

      out.writeString(',');
      out.writeShort(0);
      out.writeShort(0);
      out.writeShort(_width);
      out.writeShort(_height);
      out.writeByte(0);

      //---------------------------------
      // Local Color Map

      //---------------------------------
      // Raster Data

      var lzwMinCodeSize = 2;
      var raster = getLZWRaster(lzwMinCodeSize);

      out.writeByte(lzwMinCodeSize);

      var offset = 0;

      while (raster.length - offset > 255) {
        out.writeByte(255);
        out.writeBytes(raster, offset, 255);
        offset += 255;
      }

      out.writeByte(raster.length - offset);
      out.writeBytes(raster, offset, raster.length - offset);
      out.writeByte(0x00);

      //---------------------------------
      // GIF Terminator
      out.writeString(';');
    };

    var bitOutputStream = function(out) {

      var _out = out;
      var _bitLength = 0;
      var _bitBuffer = 0;

      var _this = {};

      _this.write = function(data, length) {

        if ( (data >>> length) != 0) {
          throw 'length over';
        }

        while (_bitLength + length >= 8) {
          _out.writeByte(0xff & ( (data << _bitLength) | _bitBuffer) );
          length -= (8 - _bitLength);
          data >>>= (8 - _bitLength);
          _bitBuffer = 0;
          _bitLength = 0;
        }

        _bitBuffer = (data << _bitLength) | _bitBuffer;
        _bitLength = _bitLength + length;
      };

      _this.flush = function() {
        if (_bitLength > 0) {
          _out.writeByte(_bitBuffer);
        }
      };

      return _this;
    };

    var getLZWRaster = function(lzwMinCodeSize) {

      var clearCode = 1 << lzwMinCodeSize;
      var endCode = (1 << lzwMinCodeSize) + 1;
      var bitLength = lzwMinCodeSize + 1;

      // Setup LZWTable
      var table = lzwTable();

      for (var i = 0; i < clearCode; i += 1) {
        table.add(String.fromCharCode(i) );
      }
      table.add(String.fromCharCode(clearCode) );
      table.add(String.fromCharCode(endCode) );

      var byteOut = byteArrayOutputStream();
      var bitOut = bitOutputStream(byteOut);

      // clear code
      bitOut.write(clearCode, bitLength);

      var dataIndex = 0;

      var s = String.fromCharCode(_data[dataIndex]);
      dataIndex += 1;

      while (dataIndex < _data.length) {

        var c = String.fromCharCode(_data[dataIndex]);
        dataIndex += 1;

        if (table.contains(s + c) ) {

          s = s + c;

        } else {

          bitOut.write(table.indexOf(s), bitLength);

          if (table.size() < 0xfff) {

            if (table.size() == (1 << bitLength) ) {
              bitLength += 1;
            }

            table.add(s + c);
          }

          s = c;
        }
      }

      bitOut.write(table.indexOf(s), bitLength);

      // end code
      bitOut.write(endCode, bitLength);

      bitOut.flush();

      return byteOut.toByteArray();
    };

    var lzwTable = function() {

      var _map = {};
      var _size = 0;

      var _this = {};

      _this.add = function(key) {
        if (_this.contains(key) ) {
          throw 'dup key:' + key;
        }
        _map[key] = _size;
        _size += 1;
      };

      _this.size = function() {
        return _size;
      };

      _this.indexOf = function(key) {
        return _map[key];
      };

      _this.contains = function(key) {
        return typeof _map[key] != 'undefined';
      };

      return _this;
    };

    return _this;
  };

  var createDataURL = function(width, height, getPixel) {
    var gif = gifImage(width, height);
    for (var y = 0; y < height; y += 1) {
      for (var x = 0; x < width; x += 1) {
        gif.setPixel(x, y, getPixel(x, y) );
      }
    }

    var b = byteArrayOutputStream();
    gif.write(b);

    var base64 = base64EncodeOutputStream();
    var bytes = b.toByteArray();
    for (var i = 0; i < bytes.length; i += 1) {
      base64.writeByte(bytes[i]);
    }
    base64.flush();

    return 'data:image/gif;base64,' + base64;
  };

  //---------------------------------------------------------------------
  // returns qrcode function.

  return qrcode;
}();

// multibyte support
!function() {

  qrcode.stringToBytesFuncs['UTF-8'] = function(s) {
    // http://stackoverflow.com/questions/18729405/how-to-convert-utf8-string-to-byte-array
    function toUTF8Array(str) {
      var utf8 = [];
      for (var i=0; i < str.length; i++) {
        var charcode = str.charCodeAt(i);
        if (charcode < 0x80) utf8.push(charcode);
        else if (charcode < 0x800) {
          utf8.push(0xc0 | (charcode >> 6),
              0x80 | (charcode & 0x3f));
        }
        else if (charcode < 0xd800 || charcode >= 0xe000) {
          utf8.push(0xe0 | (charcode >> 12),
              0x80 | ((charcode>>6) & 0x3f),
              0x80 | (charcode & 0x3f));
        }
        // surrogate pair
        else {
          i++;
          // UTF-16 encodes 0x10000-0x10FFFF by
          // subtracting 0x10000 and splitting the
          // 20 bits of 0x0-0xFFFFF into two halves
          charcode = 0x10000 + (((charcode & 0x3ff)<<10)
            | (str.charCodeAt(i) & 0x3ff));
          utf8.push(0xf0 | (charcode >>18),
              0x80 | ((charcode>>12) & 0x3f),
              0x80 | ((charcode>>6) & 0x3f),
              0x80 | (charcode & 0x3f));
        }
      }
      return utf8;
    }
    return toUTF8Array(s);
  };

}();

(function (factory) {
  if (typeof define === 'function' && define.amd) {
      define([], factory);
  } else if (typeof exports === 'object') {
      module.exports = factory();
  }
}(function () {
    return qrcode;
}));
MPQR
chmod 644 /opt/minipainel/qrcode.js

say "A instalar o gestor de ficheiros..."
install -d -o root -g root -m 755 /opt/minipainel/files
cat > /opt/minipainel/files/index.php <<'MPFILES'
<?php
/**
 * IDDigital Hosting v2.12.1 — gestor de ficheiros (API)
 * Corre num pool PHP-FPM próprio de cada site, como o utilizador do site (mp_<site>),
 * preso à pasta /srv/www/<site> por open_basedir. O acesso é protegido pela sessão
 * do painel (auth_request no nginx) e os pedidos de escrita exigem o cabeçalho
 * X-MP-Request, que um formulário de outro site não consegue enviar.
 */
declare(strict_types=1);

const FM_MAX_EDIT = 2097152;   // 2 MB
const FM_ESSENTIAL = ['public_html', 'logs', 'tmp'];

header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; sandbox");

function fm_json(array $d, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($d, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function fm_fail(int $code, string $m, array $extra = []): void { fm_json(['ok' => false, 'error' => $m] + $extra, $code); }

$site = (string)($_SERVER['MP_FM_SITE'] ?? '');
if ($site === '_email') {
    // área Email: todas as caixas de correio (corre como vmail); as mensagens não se editam aqui
    $ROOT = realpath('/var/mail/vhosts');
    $TMP = '/var/lib/minipainel-mailfm';
    $NOEDIT = true;
} else {
    if (!preg_match('/^[a-z][a-z0-9-]{0,23}$/', $site)) fm_fail(400, 'Site inválido.');
    $ROOT = realpath('/srv/www/' . $site);
    $TMP = $ROOT === false ? '' : $ROOT . '/tmp';
    $NOEDIT = false;
}
if ($ROOT === false || !is_dir($ROOT)) fm_fail(404, 'A pasta não foi encontrada.');
umask(0027);

/* ---------- caminhos ---------- */
function fm_rel(string $p): string {
    $p = str_replace('\\', '/', $p);
    if (strpos($p, "\0") !== false) fm_fail(400, 'Caminho inválido.');
    $out = [];
    foreach (explode('/', $p) as $seg) {
        if ($seg === '' || $seg === '.') continue;
        if ($seg === '..') fm_fail(400, 'Caminho inválido.');
        if (strlen($seg) > 255) fm_fail(400, 'Nome demasiado longo.');
        $out[] = $seg;
    }
    return implode('/', $out);
}
function fm_join(string $a, string $b): string { return $a === '' ? $b : ($b === '' ? $a : $a . '/' . $b); }
function fm_inside(string $real): bool { global $ROOT; return $real === $ROOT || strpos($real, $ROOT . '/') === 0; }
/* Caminho existente, seguindo ligações simbólicas (para ler e listar) */
function fm_abs(string $rel): string {
    global $ROOT;
    $real = realpath($rel === '' ? $ROOT : $ROOT . '/' . $rel);
    if ($real === false) fm_fail(404, 'Não encontrado: /' . $rel);
    if (!fm_inside($real)) fm_fail(403, 'Fora da pasta do site.');
    return $real;
}
/* Entrada a alterar (não segue a ligação final: apagar uma ligação apaga só a ligação) */
function fm_entry(string $rel, bool $mustExist = true): string {
    global $ROOT;
    if ($rel === '') fm_fail(400, 'Operação não permitida na raiz do site.');
    $parent = realpath(dirname($ROOT . '/' . $rel));
    if ($parent === false || !fm_inside($parent)) fm_fail(403, 'Fora da pasta do site.');
    $abs = $parent . '/' . basename($rel);
    if ($mustExist && !file_exists($abs) && !is_link($abs)) fm_fail(404, 'Não encontrado: /' . $rel);
    return $abs;
}
function fm_name(string $n): string {
    $n = trim($n);
    if ($n === '' || $n === '.' || $n === '..' || strpos($n, '/') !== false || strpos($n, '\\') !== false || strpos($n, "\0") !== false || strlen($n) > 255) {
        fm_fail(400, 'Nome inválido.');
    }
    return $n;
}
function fm_fix(string $abs): void {
    if (is_link($abs)) return;
    @chmod($abs, is_dir($abs) ? 02750 : 0640);
}
function fm_mkdirs(string $abs): void {
    if (is_dir($abs)) return;
    fm_mkdirs(dirname($abs));
    if (!@mkdir($abs) && !is_dir($abs)) fm_fail(500, 'Não foi possível criar a pasta ' . basename($abs) . '.');
    fm_fix($abs);
}
function fm_rrm(string $p): bool {
    if (is_link($p) || !is_dir($p)) return @unlink($p);
    $ok = true;
    foreach ((array)@scandir($p) as $e) {
        if ($e === '.' || $e === '..' || $e === false) continue;
        $ok = fm_rrm($p . '/' . $e) && $ok;
    }
    return @rmdir($p) && $ok;
}
function fm_essential(string $rel): bool { return strpos($rel, '/') === false && in_array($rel, FM_ESSENTIAL, true); }

/* ---------- entrada ---------- */
$a = (string)($_GET['a'] ?? '');
$method = (string)($_SERVER['REQUEST_METHOD'] ?? 'GET');
$in = [];
if ($method === 'POST') {
    if ((string)($_SERVER['HTTP_X_MP_REQUEST'] ?? '') !== '1') fm_fail(403, 'Pedido recusado.');
    $in = $_POST;
    if (stripos((string)($_SERVER['CONTENT_TYPE'] ?? ''), 'application/json') === 0) {
        $j = json_decode((string)file_get_contents('php://input'), true);
        $in = is_array($j) ? $j : [];
    }
}
function in_s(array $in, string $k): string { $v = $in[$k] ?? ''; return is_string($v) || is_int($v) ? (string)$v : ''; }
function in_list(array $in, string $k): array { $v = $in[$k] ?? []; return is_array($v) ? array_values(array_filter($v, 'is_string')) : []; }
function q(string $k): string { $v = $_GET[$k] ?? ''; return is_string($v) ? $v : ''; }

$readOnly = ['list', 'get', 'dl', 'upstat', 'logs', 'tail'];
if ($method !== 'POST' && !in_array($a, $readOnly, true)) fm_fail(405, 'Método não permitido.');

switch ($a) {

case 'list':
    $rel = fm_rel(q('p'));
    $dir = fm_abs($rel);
    if (!is_dir($dir)) fm_fail(400, 'Não é uma pasta.');
    $dh = @opendir($dir);
    if ($dh === false) fm_fail(403, 'Sem permissão para ler esta pasta.');
    $items = [];
    while (($e = readdir($dh)) !== false) {
        if ($e === '.' || $e === '..') continue;
        $f = $dir . '/' . $e;
        $st = @lstat($f);
        if ($st === false) continue;
        $link = is_link($f);
        $isDir = is_dir($f);
        $items[] = [
            'n' => $e, 'd' => $isDir, 'l' => $link,
            's' => $isDir ? null : ($link ? @filesize($f) : $st['size']),
            'm' => $st['mtime'], 'p' => sprintf('%04o', $st['mode'] & 07777),
        ];
    }
    closedir($dh);
    usort($items, function ($x, $y) { return $x['d'] === $y['d'] ? strnatcasecmp($x['n'], $y['n']) : ($x['d'] ? -1 : 1); });
    $free = @disk_free_space($dir);
    fm_json(['ok' => true, 'path' => $rel, 'items' => $items, 'free' => $free === false ? null : $free]);

case 'get':
    if ($NOEDIT) fm_fail(403, 'Na área Email as mensagens não se editam aqui (podes descarregá-las).');
    $f = fm_abs(fm_rel(q('p')));
    if (!is_file($f)) fm_fail(400, 'Não é um ficheiro.');
    if ((int)filesize($f) > FM_MAX_EDIT) fm_fail(413, 'O ficheiro tem mais de 2 MB; descarrega-o para editar.');
    $c = @file_get_contents($f);
    if ($c === false) fm_fail(403, 'Sem permissão para ler o ficheiro.');
    if (strpos($c, "\0") !== false || !preg_match('//u', $c)) fm_fail(415, 'É um ficheiro binário ou não está em UTF-8; não pode ser editado aqui.');
    fm_json(['ok' => true, 'content' => $c, 'm' => filemtime($f)]);

case 'dl':
    $f = fm_abs(fm_rel(q('p')));
    if (!is_file($f) || !is_readable($f)) fm_fail(404, 'Ficheiro não encontrado.');
    @set_time_limit(0);
    while (ob_get_level() > 0) ob_end_clean();
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . (string)filesize($f));
    header("Content-Disposition: attachment; filename*=UTF-8''" . rawurlencode(basename($f)));
    readfile($f);
    exit;

case 'logs':
    // lista os logs da pasta logs do site (atuais e rodados)
    if ($NOEDIT) fm_fail(400, 'Pedido inválido.');
    $out = [];
    foreach ((array)glob($ROOT . '/logs/*') as $lf) {
        $b = basename((string)$lf);
        if (!is_file((string)$lf) || is_link((string)$lf) || !preg_match('/^[A-Za-z0-9._-]+\.log([.-][0-9A-Za-z.-]+)?$/', $b)) continue;
        $out[] = ['n' => $b, 's' => (int)filesize((string)$lf), 'm' => (int)filemtime((string)$lf)];
    }
    usort($out, function ($a, $b) { return $b['m'] <=> $a['m']; });
    fm_json(['ok' => true, 'items' => $out]);

case 'tail':
    // últimas linhas de um log da pasta logs (sem seguir ligações simbólicas)
    if ($NOEDIT) fm_fail(400, 'Pedido inválido.');
    $b = basename(q('p'));
    if (!preg_match('/^[A-Za-z0-9._-]+\.log$/', $b)) fm_fail(400, 'Ficheiro inválido.');
    $lf = $ROOT . '/logs/' . $b;
    if (!is_file($lf) || is_link($lf)) fm_json(['ok' => true, 'lines' => [], 'size' => 0]);
    $max = max(10, min(5000, (int)q('n') ?: 500)); $grep = (string)q('q');
    $fh = @fopen($lf, 'r'); if (!$fh) fm_fail(403, 'Sem permissão para ler o log.');
    $size = (int)filesize($lf); $chunk = 65536; $pos = $size; $buf = ''; $lines = [];
    while ($pos > 0 && count($lines) < $max && $size - $pos < 33554432) {
        $rd = min($chunk, $pos); $pos -= $rd; fseek($fh, $pos); $buf = (string)fread($fh, $rd) . $buf;
        $parts = explode("\n", $buf); $buf = $pos > 0 ? (string)array_shift($parts) : '';
        $sel = [];
        foreach ($parts as $ln) { if ($ln === '') continue; if ($grep !== '' && stripos($ln, $grep) === false) continue; $sel[] = mb_substr($ln, 0, 2000); }
        $lines = array_merge($sel, $lines);
    }
    if ($buf !== '' && ($grep === '' || stripos($buf, $grep) !== false)) array_unshift($lines, $buf);
    fclose($fh);
    fm_json(['ok' => true, 'lines' => array_slice($lines, -$max), 'size' => $size]);

case 'upstat':
    $id = q('id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $part = $TMP . '/.mp-up-' . $id . '.part';
    fm_json(['ok' => true, 'size' => is_file($part) ? filesize($part) : 0]);

case 'mkdir':
case 'newfile':
    $dir = fm_abs(fm_rel(in_s($in, 'p')));
    if (!is_dir($dir)) fm_fail(400, 'A pasta de destino não existe.');
    $t = $dir . '/' . fm_name(in_s($in, 'name'));
    if (file_exists($t) || is_link($t)) fm_fail(409, 'Já existe um ficheiro ou pasta com esse nome.');
    $ok = $a === 'mkdir' ? @mkdir($t) : (@file_put_contents($t, '') !== false);
    if (!$ok) fm_fail(500, 'Não foi possível criar.');
    fm_fix($t);
    fm_json(['ok' => true]);

case 'rename':
    $p = fm_rel(in_s($in, 'p'));
    $from = fm_name(in_s($in, 'from'));
    $to = fm_name(in_s($in, 'to'));
    if (fm_essential(fm_join($p, $from))) fm_fail(403, 'Esta pasta é essencial para o site e não pode mudar de nome.');
    $src = fm_entry(fm_join($p, $from));
    $dst = fm_entry(fm_join($p, $to), false);
    if (file_exists($dst) || is_link($dst)) fm_fail(409, 'Já existe um ficheiro ou pasta com esse nome.');
    if (!@rename($src, $dst)) fm_fail(500, 'Não foi possível mudar o nome.');
    fm_json(['ok' => true]);

case 'move':
    $p = fm_rel(in_s($in, 'p'));
    $destRel = fm_rel(in_s($in, 'to'));
    $dest = fm_abs($destRel);
    if (!is_dir($dest)) fm_fail(400, 'O destino não é uma pasta.');
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $rel = fm_join($p, fm_name($it));
        if (fm_essential($rel)) { $errors[] = $it . ': pasta essencial'; continue; }
        $src = fm_entry($rel);
        $real = realpath($src);
        if ($real !== false && is_dir($src) && !is_link($src) && ($dest === $real || strpos($dest . '/', $real . '/') === 0)) { $errors[] = $it . ': não pode ir para dentro de si própria'; continue; }
        $t = $dest . '/' . basename($src);
        if (file_exists($t) || is_link($t)) { $errors[] = $it . ': já existe no destino'; continue; }
        if (!@rename($src, $t)) $errors[] = $it . ': falhou';
    }
    if ($errors) fm_fail(409, "Alguns itens não foram movidos:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'delete':
    $p = fm_rel(in_s($in, 'p'));
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $rel = fm_join($p, fm_name($it));
        if (fm_essential($rel)) { $errors[] = $it . ': pasta essencial do site'; continue; }
        if (!fm_rrm(fm_entry($rel))) $errors[] = $it;
    }
    if ($errors) fm_fail(409, "Não foi possível apagar:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'save':
    if ($NOEDIT) fm_fail(403, 'Na área Email as mensagens não se editam aqui.');
    $rel = fm_rel(in_s($in, 'p'));
    $f = fm_entry($rel, false);
    $content = in_s($in, 'content');
    if (strlen($content) > FM_MAX_EDIT) fm_fail(413, 'O conteúdo tem mais de 2 MB.');
    if (is_dir($f)) fm_fail(400, 'É uma pasta.');
    $new = !file_exists($f);
    if (@file_put_contents($f, $content, LOCK_EX) === false) fm_fail(500, 'Não foi possível gravar o ficheiro.');
    if ($new) fm_fix($f);
    clearstatcache(true, $f);
    fm_json(['ok' => true, 'm' => filemtime($f)]);

case 'chmod':
    $p = fm_rel(in_s($in, 'p'));
    $mode = in_s($in, 'mode');
    if (!preg_match('/^[0-7]{3,4}$/', $mode)) fm_fail(400, 'Permissões inválidas (ex.: 640 ou 2750).');
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $f = fm_entry(fm_join($p, fm_name($it)));
        if (is_link($f)) continue;
        if (!@chmod($f, octdec($mode))) $errors[] = $it;
    }
    if ($errors) fm_fail(409, "Não foi possível alterar:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'extract':
    @set_time_limit(0);
    $rel = fm_rel(in_s($in, 'p'));
    $arch = fm_abs($rel);
    if (!is_file($arch)) fm_fail(400, 'Não é um ficheiro.');
    $dest = dirname($arch);
    $sub = trim(in_s($in, 'into'));
    if ($sub !== '') { $dest .= '/' . fm_name($sub); fm_mkdirs($dest); }
    $lower = strtolower($arch);
    $count = 0; $skipped = 0;
    $safeTarget = function (string $name) use ($dest, &$skipped): ?string {
        $name = str_replace('\\', '/', $name);
        $parts = [];
        foreach (explode('/', $name) as $seg) {
            if ($seg === '' || $seg === '.') continue;
            if ($seg === '..' || strpos($seg, "\0") !== false) { $skipped++; return null; }
            $parts[] = $seg;
        }
        return $parts ? $dest . '/' . implode('/', $parts) : null;
    };
    if (substr($lower, -4) === '.zip') {
        if (!class_exists('ZipArchive')) fm_fail(500, 'A extensão zip do PHP não está disponível.');
        $z = new ZipArchive();
        if ($z->open($arch) !== true) fm_fail(400, 'Não foi possível abrir o ZIP.');
        for ($i = 0; $i < $z->numFiles; $i++) {
            $name = (string)$z->getNameIndex($i);
            $t = $safeTarget($name);
            if ($t === null) continue;
            if (substr($name, -1) === '/') { fm_mkdirs($t); continue; }
            fm_mkdirs(dirname($t));
            if (is_link($t)) @unlink($t);
            $src = $z->getStream($name);
            $dst = @fopen($t, 'wb');
            if ($src === false || $dst === false) { $skipped++; continue; }
            stream_copy_to_stream($src, $dst);
            fclose($src); fclose($dst);
            fm_fix($t);
            $count++;
        }
        $z->close();
    } elseif (preg_match('/\.(tar\.gz|tgz|tar\.bz2|tar)$/', $lower)) {
        if (!class_exists('PharData')) fm_fail(500, 'A extensão phar do PHP não está disponível.');
        try {
            $ph = new PharData($arch);
            $prefix = 'phar://' . $arch . '/';
            foreach (new RecursiveIteratorIterator($ph, RecursiveIteratorIterator::SELF_FIRST) as $entry) {
                $path = (string)$entry->getPathname();
                if (strpos($path, $prefix) !== 0) { $skipped++; continue; }
                $t = $safeTarget(substr($path, strlen($prefix)));
                if ($t === null) continue;
                if ($entry->isDir()) { fm_mkdirs($t); continue; }
                fm_mkdirs(dirname($t));
                if (is_link($t)) @unlink($t);
                if (!@copy($path, $t)) { $skipped++; continue; }
                fm_fix($t);
                $count++;
            }
        } catch (Throwable $e) {
            fm_fail(400, 'Não foi possível ler o arquivo: ' . $e->getMessage());
        }
    } else {
        fm_fail(400, 'Formato não suportado. Usa .zip, .tar, .tar.gz, .tgz ou .tar.bz2.');
    }
    fm_json(['ok' => true, 'count' => $count, 'skipped' => $skipped]);

case 'zip':
    @set_time_limit(0);
    if (!class_exists('ZipArchive')) fm_fail(500, 'A extensão zip do PHP não está disponível.');
    $p = fm_rel(in_s($in, 'p'));
    $dir = fm_abs($p);
    $name = fm_name(in_s($in, 'name'));
    if (strtolower(substr($name, -4)) !== '.zip') $name .= '.zip';
    $target = $dir . '/' . $name;
    if (file_exists($target)) fm_fail(409, 'Já existe um ficheiro com esse nome.');
    $z = new ZipArchive();
    if ($z->open($target, ZipArchive::CREATE) !== true) fm_fail(500, 'Não foi possível criar o ZIP.');
    $added = 0;
    $addPath = function (string $abs, string $local) use (&$addPath, $z, $target, &$added) {
        if ($abs === $target) return;
        if (is_link($abs)) return;
        if (is_dir($abs)) {
            $z->addEmptyDir($local);
            foreach ((array)@scandir($abs) as $e) {
                if ($e === '.' || $e === '..' || $e === false) continue;
                $addPath($abs . '/' . $e, $local . '/' . $e);
            }
        } elseif (is_readable($abs)) {
            $z->addFile($abs, $local);
            $added++;
        }
    };
    foreach (in_list($in, 'items') as $it) {
        $it = fm_name($it);
        $addPath(fm_entry(fm_join($p, $it)), $it);
    }
    if (!$z->close()) fm_fail(500, 'Falha ao gravar o ZIP.');
    fm_fix($target);
    fm_json(['ok' => true, 'name' => $name, 'count' => $added]);

case 'upload':
    @set_time_limit(0);
    $id = in_s($in, 'id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $offset = (int)in_s($in, 'offset');
    $total = (int)in_s($in, 'total');
    if ($offset < 0 || $total < 0) fm_fail(400, 'Valores inválidos.');
    $dir = fm_abs(fm_rel(in_s($in, 'p')));
    if (!is_dir($dir)) fm_fail(400, 'A pasta de destino não existe.');
    $relName = fm_rel(in_s($in, 'name'));
    if ($relName === '') fm_fail(400, 'Nome inválido.');
    foreach (explode('/', $relName) as $seg) fm_name($seg);
    $part = $TMP . '/.mp-up-' . $id . '.part';
    if (!is_dir($TMP)) fm_fail(500, 'A pasta temporária não existe.');
    // limpa envios abandonados há mais de um dia
    if (mt_rand(1, 20) === 1) foreach ((array)glob($TMP . '/.mp-up-*.part') as $old) { if (is_string($old) && filemtime($old) < time() - 86400) @unlink($old); }
    clearstatcache(true, $part);
    $have = is_file($part) ? (int)filesize($part) : 0;
    if ($offset !== $have) fm_fail(409, 'Fora de sequência.', ['size' => $have]);
    $chunk = $_FILES['chunk'] ?? null;
    if ($total > 0) {
        if (!is_array($chunk) || (int)($chunk['error'] ?? 1) !== UPLOAD_ERR_OK) fm_fail(400, 'A parte do ficheiro não chegou ao servidor.');
        $src = @fopen((string)$chunk['tmp_name'], 'rb');
        $dst = @fopen($part, 'ab');
        if ($src === false || $dst === false) fm_fail(500, 'Não foi possível gravar a parte do ficheiro.');
        stream_copy_to_stream($src, $dst);
        fclose($src); fclose($dst);
        clearstatcache(true, $part);
        $have = (int)filesize($part);
    } elseif (!is_file($part)) {
        @touch($part);
    }
    if ($have > $total) { @unlink($part); fm_fail(409, 'O tamanho recebido não confere; recomeça o envio.', ['size' => 0]); }
    if ($have < $total) fm_json(['ok' => true, 'size' => $have, 'done' => false]);
    $target = $dir . '/' . $relName;
    fm_mkdirs(dirname($target));
    if (file_exists($target) || is_link($target)) {
        if (in_s($in, 'overwrite') !== '1' || is_dir($target)) { @unlink($part); fm_fail(409, 'Já existe: ' . $relName, ['exists' => true]); }
        @unlink($target);
    }
    if (!@rename($part, $target)) fm_fail(500, 'Não foi possível concluir o envio.');
    fm_fix($target);
    fm_json(['ok' => true, 'size' => $have, 'done' => true]);

default:
    fm_fail(400, 'Ação desconhecida.');
}
MPFILES
chown root:root /opt/minipainel/files/index.php
chmod 644 /opt/minipainel/files/index.php

# ----------------------------------------------------------------------------
# 7. CLI (mpanel) — também usado pelo worker da fila
# ----------------------------------------------------------------------------
say "A instalar o CLI mpanel..."
cat > /usr/local/sbin/mpanel <<'MPCLI'
#!/usr/bin/env bash
# =============================================================================
#  mpanel — IDDigital Hosting CLI v2.12.1
# =============================================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # o cron só tem /usr/bin:/bin (sem nft, postqueue, sysctl…)

MP_VERSION="2.12.1"
CONF=/etc/minipainel/minipainel.conf
[ -r "$CONF" ] || { echo "ERRO: configuração em falta ($CONF)." >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

SITES_DIR=/etc/minipainel/sites
NGX_SITES=/etc/nginx/minipainel/sites
WWW_ROOT=/srv/www
DATA=/var/lib/minipainel
QUEUE=$DATA/queue
RESULTS=$DATA/results
STATE=$DATA/state.json
AUTH=$DATA/auth.json
LOCK=/run/minipainel.lock
PMA_DIR=/opt/minipainel/phpmyadmin
PMA_USER=minipainel-pma
PMA_CONF=/etc/minipainel/pma-config.inc.php
DB_ADMIN=mpadmin

die(){  echo "ERRO: $*" >&2; exit 1; }
warn(){ echo "AVISO: $*" >&2; }

# ---------- validação ----------
valid_site(){ local re='^[a-z][a-z0-9-]{0,23}$'; [[ "$1" =~ $re ]] && [[ "$1" != *- ]]; }
valid_db(){   local re='^[a-z][a-z0-9_]{0,31}$'; [[ "$1" =~ $re ]]; }
valid_pass(){ local re='^[A-Za-z0-9._@%+=:,!#*-]{8,64}$'; [[ "$1" =~ $re ]]; }
valid_port(){ local re='^[0-9]{1,5}$'; [[ "$1" =~ $re ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
gen_pass(){ openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }
port_reserved(){ case " 22 25 53 110 143 443 465 587 993 995 3306 $PANEL_PORT " in *" $1 "*) return 0 ;; esac; return 1; }
port_listening(){ [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]; }
wait_listen(){ local i; for i in $(seq 1 25); do port_listening "$1" && return 0; sleep 0.2; done; return 1; }

# ---------- PHP ----------
php_vv(){ echo "${1/./}"; }
php_pool_dir(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/pool.d"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.d"; fi; }
php_service(){  if [ "$OS_FAMILY" = debian ]; then echo "php$1-fpm"; else echo "php$(php_vv "$1")-php-fpm"; fi; }
php_fpm_bin(){  if [ "$OS_FAMILY" = debian ]; then echo "/usr/sbin/php-fpm$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/sbin/php-fpm"; fi; }
php_fpm_conf(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/php-fpm.conf"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.conf"; fi; }
php_cli(){      if [ "$OS_FAMILY" = debian ]; then echo "/usr/bin/php$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/bin/php"; fi; }
php_run_dir(){  if [ "$OS_FAMILY" = debian ]; then echo "/run/php"; else echo "/var/opt/remi/php$(php_vv "$1")/run/php-fpm"; fi; }
php_sock(){ echo "$(php_run_dir "$1")/mp-$2.sock"; }
php_installed(){
  local d v
  if [ "$OS_FAMILY" = debian ]; then
    for d in /etc/php/*/fpm/pool.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/php/}"; v="${v%%/*}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  else
    for d in /etc/opt/remi/php*/php-fpm.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/opt/remi/php}"; v="${v%%/*}"; v="${v:0:1}.${v:1}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  fi | sort -V
}
php_is_installed(){ local v; for v in $(php_installed); do [ "$v" = "$1" ] && return 0; done; return 1; }

# ---------- SELinux / firewall ----------
selinux_on(){ command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; }
se_port_add(){
  # 0 = etiqueta adicionada pelo MiniPainel
  selinux_on || return 1
  semanage port -a -t http_port_t -p tcp "$1" >/dev/null 2>&1 && return 0
  semanage port -m -t http_port_t -p tcp "$1" >/dev/null 2>&1 && return 0
  return 1
}
se_port_del(){ selinux_on || return 0; semanage port -d -p tcp "$1" >/dev/null 2>&1; return 0; }
se_restore(){ if selinux_on; then restorecon -R "$1" >/dev/null 2>&1; fi; return 0; }
fw_open(){
  # 0 = porta aberta agora pelo MiniPainel (não estava aberta)
  local p=$1
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd -q --query-port="$p/tcp" 2>/dev/null && return 1
    firewall-cmd -q --permanent --add-port="$p/tcp" >/dev/null 2>&1 && firewall-cmd -q --add-port="$p/tcp" >/dev/null 2>&1 && return 0
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
    [[ "$(ufw status 2>/dev/null)" == *"$p/tcp"* ]] && return 1
    ufw allow "$p/tcp" >/dev/null 2>&1 && return 0
  fi
  return 1
}
fw_close(){
  local p=$1
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd -q --permanent --remove-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd -q --remove-port="$p/tcp" >/dev/null 2>&1
  elif command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$p/tcp" >/dev/null 2>&1
  fi
  return 0
}

# ---------- aplicar configurações ----------
apply_nginx(){
  local out
  if ! out=$(nginx -t 2>&1); then echo "$out" >&2; return 1; fi
  systemctl reload-or-restart nginx >/dev/null 2>&1 || { echo "Falha ao recarregar o nginx." >&2; return 1; }
  return 0
}
apply_php(){
  local v=$1 out
  if ! out=$("$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" 2>&1); then echo "$out" >&2; return 1; fi
  systemctl reload-or-restart "$(php_service "$v")" >/dev/null 2>&1 || { echo "Falha ao recarregar PHP-FPM $v." >&2; return 1; }
  return 0
}

# ---------- registo de sites ----------
site_conf(){ echo "$SITES_DIR/$1.conf"; }
site_exists(){ [ -f "$(site_conf "$1")" ]; }
site_get(){ grep -m1 "^$2=" "$(site_conf "$1")" 2>/dev/null | cut -d= -f2-; }
site_set(){
  local f; f=$(site_conf "$1")
  if grep -q "^$2=" "$f"; then sed -i "s|^$2=.*|$2=$3|" "$f"; else echo "$2=$3" >> "$f"; fi
}
site_names(){ local f; for f in "$SITES_DIR"/*.conf; do [ -f "$f" ] && basename "$f" .conf; done; return 0; }
port_owner(){ local n; for n in $(site_names); do if [ "$(site_get "$n" PORT)" = "$1" ]; then echo "$n"; return 0; fi; done; return 1; }
next_port(){
  local p=${SITE_PORT_START:-8001}
  while port_owner "$p" >/dev/null || port_listening "$p" || port_reserved "$p"; do p=$((p+1)); done
  echo "$p"
}
ngx_file(){ if [ "$(site_get "$1" ENABLED)" = 0 ]; then echo "$NGX_SITES/$1.conf.disabled"; else echo "$NGX_SITES/$1.conf"; fi; }

# ---------- limites por site (valores guardados em /etc/minipainel/sites/<site>.conf) ----------
lim_default(){ case "$1" in MEM) echo 256 ;; UPLOAD) echo 128 ;; EXEC|INPUT_TIME) echo 120 ;; INPUT_VARS) echo 5000 ;; DISPLAY_ERRORS) echo 0 ;; esac; }
lim_range(){ case "$1" in MEM) echo "32 8192" ;; UPLOAD) echo "1 8192" ;; EXEC|INPUT_TIME) echo "5 3600" ;; INPUT_VARS) echo "100 100000" ;; DISPLAY_ERRORS) echo "0 1" ;; esac; }
lim_opt_key(){ case "$1" in --memory) echo MEM ;; --upload) echo UPLOAD ;; --exec) echo EXEC ;; --input-time) echo INPUT_TIME ;; --input-vars) echo INPUT_VARS ;; --display-errors) echo DISPLAY_ERRORS ;; esac; }
lim_get(){ local v; v=$(site_get "$1" "$2"); [ -n "$v" ] || v=$(lim_default "$2"); echo "$v"; }
lim_check(){ local lo hi; read -r lo hi <<<"$(lim_range "$1")"; [ "$2" -ge "$lo" ] && [ "$2" -le "$hi" ]; }

perf_pool_pm(){ # site -> linhas do gestor de processos
  local mc pm; mc=$(site_get "$1" MAXCH); [[ "$mc" =~ ^[0-9]+$ ]] || mc=10; pm=$(site_get "$1" PM)
  if [ "$pm" = dynamic ]; then
    local sp=$(( mc < 4 ? mc : 4 ))
    printf 'pm = dynamic\npm.max_children = %s\npm.start_servers = %s\npm.min_spare_servers = 1\npm.max_spare_servers = %s' "$mc" "$(( sp > 1 ? 2 : 1 ))" "$sp"
  else printf 'pm = ondemand\npm.max_children = %s\npm.process_idle_timeout = 10s' "$mc"; fi
}
perf_pool_slow(){ # site -> registo de scripts lentos (numa pasta do root, nunca na pasta do site)
  local sl; sl=$(site_get "$1" SLOW); [[ "$sl" =~ ^[0-9]+$ ]] || sl=5
  if [ "$sl" -gt 0 ]; then printf 'request_slowlog_timeout = %ss\nslowlog = %s/%s/php-slow.log' "$sl" "$SITE_LOGS" "$1"; fi
}
write_pool(){
  local n=$1 v=$2 f
  f="$(php_pool_dir "$v")/mp-$n.conf"
  cat > "$f" <<EOF
; MiniPainel — site $n (gerido pelo mpanel; não editar à mão)
[mp-$n]
user = mp_$n
group = mp_$n
listen = $(php_sock "$v" "$n")
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
$(perf_pool_pm "$n")
pm.max_requests = 500
$(perf_pool_slow "$n")
chdir = /
php_admin_value[open_basedir] = $WWW_ROOT/$n/
php_admin_value[upload_tmp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[sys_temp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[session.save_path] = $WWW_ROOT/$n/tmp
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[error_log] = $WWW_ROOT/$n/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[expose_php] = off
php_admin_value[sendmail_path] = /usr/local/sbin/mp-sendmail $n
php_admin_flag[mail.add_x_header] = on
php_value[memory_limit] = $(lim_get "$n" MEM)M
php_value[upload_max_filesize] = $(lim_get "$n" UPLOAD)M
php_value[post_max_size] = $(lim_get "$n" UPLOAD)M
php_value[max_execution_time] = $(lim_get "$n" EXEC)
php_value[max_input_time] = $(lim_get "$n" INPUT_TIME)
php_value[max_input_vars] = $(lim_get "$n" INPUT_VARS)
php_flag[display_errors] = $([ "$(lim_get "$n" DISPLAY_ERRORS)" = 1 ] && echo on || echo off)
EOF
  chmod 644 "$f"
}

write_nginx(){
  local n=$1 p=$2 v=$3 dest=$4 l6="" up rt inc dflt=""
  inc="$NGX_INC/mp-$n.inc"
  install -d -m 755 "$NGX_INC"
  logs_dir_site "$n"
  perf_ngx_write
  [ "$p" = 80 ] && dflt=" default_server"
  if [ "${IPV6:-0}" = 1 ]; then l6="    listen [::]:$p$dflt;"; fi
  up=$(lim_get "$n" UPLOAD)
  rt=$(( $(lim_get "$n" EXEC) + 30 )); [ "$rt" -lt 300 ] && rt=300
  cat > "$inc" <<EOF
# IDDigital Hosting — conteúdo do site $n (gerido pelo mpanel; não editar à mão)
    root $WWW_ROOT/$n/public_html;
    index index.php index.html index.htm;
    client_max_body_size ${up}M;
    access_log $SITE_LOGS/$n/access.log mpcombined;
    error_log  $SITE_LOGS/$n/error.log;

    location ~ /\.(?!well-known) { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
$(perf_static_loc "$n")

    location ~ [^/]\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        if (!-f \$document_root\$fastcgi_script_name) { return 404; }
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass unix:$(php_sock "$v" "$n");
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout ${rt}s;
$(perf_ngx_cache "$n")
    }
EOF
  chmod 644 "$inc"
  {
    printf '# IDDigital Hosting — site %s (gerido pelo mpanel; não editar à mão)\n# acesso por porta (LAN)\nserver {\n    listen %s%s;\n%s\n    server_name _;\n    include %s;\n    include %s;\n}\n' "$n" "$p" "$dflt" "$l6" "$PORTS_ALLOW_INC" "$inc"
    domain_servers "mp-$n" "$inc" "$(site_get "$n" DOMAINS)" "$(site_get "$n" SSL)" "$(site_get "$n" HTTPS)" "$(site_get "$n" WWW)"
  } > "$dest"
  chmod 644 "$dest"
}

# O nginx pertence ao grupo de cada site (mp_<site>): lê os ficheiros do site,
# enquanto os sites continuam isolados entre si.
web_join(){
  local g="mp_$1"
  getent group "$g" >/dev/null 2>&1 || return 0
  id -nG "$WEB_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g" && return 0
  gpasswd -a "$WEB_USER" "$g" >/dev/null 2>&1 || usermod -aG "$g" "$WEB_USER" >/dev/null 2>&1
  return 0
}

# ---------- gestor de ficheiros: pool por site, como mp_<site>, na versão de PHP do painel ----------
fm_pool_file(){ echo "$(php_pool_dir "$PANEL_PHP")/mp-fm-$1.conf"; }
write_fm_pool(){
  local n=$1 f
  f=$(fm_pool_file "$n")
  cat > "$f" <<EOF
; MiniPainel — gestor de ficheiros do site $n (corre como mp_$n; gerido pelo mpanel)
[mp-fm-$n]
user = mp_$n
group = mp_$n
listen = $(php_run_dir "$PANEL_PHP")/mp-fm-$n.sock
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
request_terminate_timeout = 0
php_admin_value[open_basedir] = $WWW_ROOT/$n/:/opt/minipainel/files/
php_admin_value[upload_tmp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[sys_temp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 72M
php_admin_value[memory_limit] = 256M
php_value[max_execution_time] = 900
php_admin_value[max_input_time] = 900
php_admin_value[error_log] = $WWW_ROOT/$n/logs/ficheiros-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF
  chmod 644 "$f"
}

cmd_fm_sync(){
  local n v f
  for v in $(php_installed); do
    [ "$v" = "$PANEL_PHP" ] && continue
    for f in "$(php_pool_dir "$v")"/mp-fm-*.conf; do
      [ -f "$f" ] || continue
      rm -f "$f"; apply_php "$v" >/dev/null 2>&1
    done
  done
  for n in $(site_names); do
    id "mp_$n" >/dev/null 2>&1 || continue
    web_join "$n"
    write_fm_pool "$n"
  done
  for f in "$(php_pool_dir "$PANEL_PHP")"/mp-fm-*.conf; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .conf); n=${n#mp-fm-}
    [ "$n" = _email ] && continue
    site_exists "$n" || rm -f "$f"
  done
  mail_on && write_fm_pool_email
  apply_php "$PANEL_PHP" || die "Configuração do PHP-FPM $PANEL_PHP inválida depois de configurar o gestor de ficheiros."
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  echo "Gestor de ficheiros configurado para $(site_names | wc -l) site(s)."
  return 0
}

cmd_stats(){
  local f=/var/lib/minipainel/stats/live.json
  [ -s "$f" ] || die "Ainda não há dados. Verifica: systemctl status minipainel-stats"
  jq -r '"CPU \(.cpu)%   Memória \(.mem.pct)%   Swap \(.swap.pct)%   Disco \(.disk.pct)%",
         "Carga \(.load | map(tostring) | join(" "))   Rede ↓ \(.net.rx / 1000000 * 100 | floor / 100) Mb/s   ↑ \(.net.tx / 1000000 * 100 | floor / 100) Mb/s",
         (.sites | to_entries[] | "  \(.key): CPU \(.value.cpu)%   RAM \(.value.rss / 1024 | floor) MB")' "$f"
  return 0
}

site_rollback(){
  local n=$1 v=$2 p=$3 se=$4
  rm -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" "$(php_pool_dir "$v")/mp-$n.conf" "$SITES_DIR/$n.conf" "$(fm_pool_file "$n")"
  apply_nginx >/dev/null 2>&1
  apply_php "$v" >/dev/null 2>&1
  if [ "$PANEL_PHP" != "$v" ]; then apply_php "$PANEL_PHP" >/dev/null 2>&1; fi
  sleep 1
  pkill -u "mp_$n" >/dev/null 2>&1
  userdel "mp_$n" >/dev/null 2>&1
  if getent group "mp_$n" >/dev/null 2>&1; then groupdel "mp_$n" >/dev/null 2>&1; fi
  rm -rf "${WWW_ROOT:?}/${n:?}"
  if [ "$se" = 1 ]; then se_port_del "$p"; fi
  return 0
}

# ---------- comandos: sites ----------
cmd_site_list(){
  local n
  printf '%-24s %-6s %-5s %-11s %s\n' SITE PORTA PHP ESTADO PASTA
  for n in $(site_names); do
    printf '%-24s %-6s %-5s %-11s %s\n' "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" \
      "$([ "$(site_get "$n" ENABLED)" = 1 ] && echo ativo || echo desativado)" "$WWW_ROOT/$n/public_html"
  done
  return 0
}

cmd_site_add(){
  local n="${1:-}" port="" v="$DEFAULT_PHP" key val lo hi re='^[0-9]{1,6}$' adoms="" assl=none
  local -A lims=()
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 || shift ;;
      --php)  v="${2:-}";    shift 2 || shift ;;
      --domains) adoms="${2:-}"; shift 2 || shift ;;
      --ssl) assl="${2:-}"; shift 2 || shift ;;
      --memory|--upload|--exec|--input-time|--input-vars|--display-errors)
        key=$(lim_opt_key "$1"); val="${2:-}"; shift 2 || shift
        [[ "$val" =~ $re ]] || die "Valor inválido para $key: '$val'"
        if ! lim_check "$key" "$val"; then read -r lo hi <<<"$(lim_range "$key")"; die "$key tem de estar entre $lo e $hi."; fi
        lims[$key]=$val ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  valid_site "$n" || die "Nome inválido. Usa minúsculas, números e '-', a começar por letra (máx. 24)."
  site_exists "$n" && die "O site '$n' já existe."
  id "mp_$n" >/dev/null 2>&1 && die "O utilizador de sistema mp_$n já existe."
  [ -e "$WWW_ROOT/$n" ] && die "A pasta $WWW_ROOT/$n já existe (ficheiros mantidos de um site apagado?)."
  php_is_installed "$v" || die "PHP $v não está instalado. Disponíveis: $(php_installed | tr '\n' ' ')"
  if [ -n "$port" ]; then
    valid_port "$port" || die "Porta inválida: $port"
    port_reserved "$port" && die "A porta $port está reservada."
    port_owner "$port" >/dev/null && die "A porta $port já é usada pelo site '$(port_owner "$port")'."
    port_listening "$port" && die "A porta $port já está em uso por outro serviço."
  else
    port=$(next_port)
  fi

  local u="mp_$n" d="$WWW_ROOT/$n" se=0 fw=0
  useradd -r -U -M -d "$d" -s "$NOLOGIN" -c "MiniPainel site $n" "$u" || die "Não foi possível criar o utilizador $u."
  web_join "$n"
  install -d -o "$u" -g "$u" -m 2750 "$d" "$d/public_html"
  install -d -o "$u" -g "$u" -m 700 "$d/logs" "$d/tmp"
  cat > "$d/public_html/index.html" <<EOF
<!doctype html>
<html lang="pt-PT"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$n</title>
<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;font:16px/1.5 system-ui,sans-serif;background:#eaeef2;color:#16222e}div{text-align:center;padding:24px}h1{margin:0 0 8px}p{margin:0;color:#4a5a6a}</style></head>
<body><div><h1>$n</h1><p>Site ativo com PHP $v. Substitui este ficheiro em $d/public_html.</p></div></body></html>
EOF
  chown "$u:$u" "$d/public_html/index.html"
  chmod 640 "$d/public_html/index.html"

  cat > "$SITES_DIR/$n.conf" <<EOF
NAME=$n
PORT=$port
PHP=$v
ENABLED=1
SE_PORT=0
FW_PORT=0
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
  chmod 600 "$SITES_DIR/$n.conf"
  for key in "${!lims[@]}"; do site_set "$n" "$key" "${lims[$key]}"; done

  write_pool "$n" "$v"
  write_fm_pool "$n"
  write_nginx "$n" "$port" "$v" "$NGX_SITES/$n.conf"
  se_restore "$d"
  if se_port_add "$port"; then se=1; fi
  site_set "$n" SE_PORT "$se"

  if ! apply_php "$v" || { [ "$PANEL_PHP" != "$v" ] && ! apply_php "$PANEL_PHP"; }; then
    site_rollback "$n" "$v" "$port" "$se"
    die "Configuração PHP-FPM inválida; nada foi alterado."
  fi
  if ! apply_nginx || ! wait_listen "$port"; then
    site_rollback "$n" "$v" "$port" "$se"
    die "O nginx não conseguiu servir na porta $port; nada foi alterado."
  fi
  if fw_open "$port"; then fw=1; fi
  site_set "$n" FW_PORT "$fw"

  echo "Site '$n' criado na porta $port com PHP $v."
  echo "Pasta: $d/public_html"
  mail_on && mail_site_spool "$n"
  logs_rotate_conf
  if [ -n "$adoms" ]; then ( cmd_site_domains "$n" --set "$adoms" --ssl "$assl" ) 2>&1 || true; fi
  return 0
}

cmd_site_del(){
  local n="${1:-}" keep=0
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--keep-files" ] && keep=1
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local v p se fw
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); se=$(site_get "$n" SE_PORT); fw=$(site_get "$n" FW_PORT)

  [ "$(site_get "$n" FTP)" = 1 ] && cmd_site_ftp "$n" --off >/dev/null 2>&1
  rm -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" "$NGX_INC/mp-$n.inc"
  le_delete "mp-$n"
  ngx_default_sync
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  rm -f "$(php_pool_dir "$v")/mp-$n.conf" "$(fm_pool_file "$n")"
  apply_php "$v" || warn "Verifica o PHP-FPM $v."
  if [ "$PANEL_PHP" != "$v" ]; then apply_php "$PANEL_PHP" || warn "Verifica o PHP-FPM $PANEL_PHP."; fi
  rm -f "/var/lib/minipainel/stats/traffic/$n.csv" "/var/lib/minipainel/stats/traffic/$n.pos"
  rm -rf "/etc/cron.d/minipainel-$n" "${CRON_DIR:?}/$n" "$CRON_DIR/$n.json"; touch /etc/cron.d 2>/dev/null
  rm -rf "${SITE_LOGS:?}/$n" "${CACHE_ROOT:?}/$n"; logs_rotate_conf
  [ "$(site_get "$n" REDIS)" = 1 ] && rds_disable "$n"
  rm -rf "${MSPOOL:?}/$n" "${MLIB:?}/rejected/$n" "$MLIB/rejected/$n.log" "$MLIB/sent/$n"
  if [ -s "$DBMAP" ]; then jq --arg s "$n" 'with_entries(select(.value != $s))' "$DBMAP" > "$DBMAP.tmp" && mv -f "$DBMAP.tmp" "$DBMAP"; fi
  sleep 1
  pkill -u "mp_$n" >/dev/null 2>&1
  userdel "mp_$n" >/dev/null 2>&1 || warn "Não foi possível remover o utilizador mp_$n."
  if getent group "mp_$n" >/dev/null 2>&1; then groupdel "mp_$n" >/dev/null 2>&1; fi

  if [ "$keep" = 1 ]; then
    chown -R root:root "$WWW_ROOT/$n" 2>/dev/null
  else
    rm -rf "${WWW_ROOT:?}/${n:?}"
  fi
  if [ "$se" = 1 ]; then se_port_del "$p"; fi
  if [ "$fw" = 1 ]; then fw_close "$p"; fi
  rm -f "$SITES_DIR/$n.conf"

  if [ "$keep" = 1 ]; then echo "Site '$n' apagado. Ficheiros mantidos em $WWW_ROOT/$n."; else echo "Site '$n' apagado."; fi
  return 0
}

cmd_site_php(){
  local n="${1:-}" nv="${2:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  php_is_installed "$nv" || die "PHP $nv não está instalado."
  local ov p dest
  ov=$(site_get "$n" PHP); p=$(site_get "$n" PORT); dest=$(ngx_file "$n")
  [ "$ov" = "$nv" ] && die "O site '$n' já usa PHP $nv."

  write_pool "$n" "$nv"
  if ! apply_php "$nv"; then
    rm -f "$(php_pool_dir "$nv")/mp-$n.conf"; apply_php "$nv" >/dev/null 2>&1
    die "Falha ao configurar PHP $nv; nada foi alterado."
  fi
  write_nginx "$n" "$p" "$nv" "$dest"
  if ! apply_nginx; then
    write_nginx "$n" "$p" "$ov" "$dest"; apply_nginx >/dev/null 2>&1
    rm -f "$(php_pool_dir "$nv")/mp-$n.conf"; apply_php "$nv" >/dev/null 2>&1
    die "Falha ao aplicar no nginx; nada foi alterado."
  fi
  rm -f "$(php_pool_dir "$ov")/mp-$n.conf"
  apply_php "$ov" || warn "Verifica o PHP-FPM $ov."
  site_set "$n" PHP "$nv"
  if [ "$(site_get "$n" REDIS)" = 1 ]; then php_has_ext "$nv" redis || { pkg_install_soft "$(php_ext_pkg "$nv" redis)"; apply_php "$nv" >/dev/null 2>&1; }; fi
  cron_write_site "$n"
  echo "Site '$n' passou de PHP $ov para PHP $nv."
  return 0
}

cmd_site_toggle(){
  local n="${1:-}" want="$2"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local cur p; cur=$(site_get "$n" ENABLED); p=$(site_get "$n" PORT)
  if [ "$want" = 1 ]; then
    [ "$cur" = 1 ] && die "O site '$n' já está ativo."
    port_listening "$p" && die "A porta $p está agora ocupada por outro serviço."
    mv -f "$NGX_SITES/$n.conf.disabled" "$NGX_SITES/$n.conf" || die "Configuração nginx do site em falta."
    site_set "$n" ENABLED 1; ngx_default_sync
    if ! apply_nginx || ! wait_listen "$p"; then
      mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled"; apply_nginx >/dev/null 2>&1
      die "O nginx não conseguiu servir na porta $p; o site continua desativado."
    fi
    site_set "$n" ENABLED 1
    echo "Site '$n' ativado."
  else
    [ "$cur" = 0 ] && die "O site '$n' já está desativado."
    mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" || die "Configuração nginx do site em falta."
    site_set "$n" ENABLED 0; ngx_default_sync
    if ! apply_nginx; then
      mv -f "$NGX_SITES/$n.conf.disabled" "$NGX_SITES/$n.conf"; apply_nginx >/dev/null 2>&1
      die "Falha ao desativar; o site continua ativo."
    fi
    site_set "$n" ENABLED 0
    echo "Site '$n' desativado."
  fi
  return 0
}

cmd_site_fixperms(){
  local n="${1:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local d="$WWW_ROOT/$n/public_html" u="mp_$n"
  [ -d "$d" ] || die "Pasta em falta: $d"
  web_join "$n"
  chown "$u:$u" "$WWW_ROOT/$n"; chmod 2750 "$WWW_ROOT/$n"
  chown -R "$u:$u" "$d"
  runuser -u "$u" -- find "$d" -type d -exec chmod 2750 {} +
  runuser -u "$u" -- find "$d" -type f -exec chmod 640 {} +
  se_restore "$d"
  apply_nginx >/dev/null 2>&1
  echo "Permissões corrigidas em $d (dono e grupo $u; o nginx lê através do grupo do site)."
  return 0
}

show_limits(){
  local n=$1
  printf 'Limites do site %s\n' "$n"
  printf '  memory_limit          %s MB\n' "$(lim_get "$n" MEM)"
  printf '  upload / post máximo  %s MB\n' "$(lim_get "$n" UPLOAD)"
  printf '  max_execution_time    %s s\n'  "$(lim_get "$n" EXEC)"
  printf '  max_input_time        %s s\n'  "$(lim_get "$n" INPUT_TIME)"
  printf '  max_input_vars        %s\n'    "$(lim_get "$n" INPUT_VARS)"
  printf '  display_errors        %s\n'    "$([ "$(lim_get "$n" DISPLAY_ERRORS)" = 1 ] && echo on || echo off)"
}

cmd_site_limits(){
  local n="${1:-}"
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  if [ $# -eq 0 ]; then show_limits "$n"; return 0; fi

  local -A nv=()
  local key val re='^[0-9]{1,6}$' lo hi
  while [ $# -gt 0 ]; do
    case "$1" in
      --memory)         key=MEM ;;
      --upload)         key=UPLOAD ;;
      --exec)           key=EXEC ;;
      --input-time)     key=INPUT_TIME ;;
      --input-vars)     key=INPUT_VARS ;;
      --display-errors) key=DISPLAY_ERRORS ;;
      *) die "Opção desconhecida: $1" ;;
    esac
    val="${2:-}"
    shift 2 2>/dev/null || shift
    [[ "$val" =~ $re ]] || die "Valor inválido para $key: '$val'"
    if ! lim_check "$key" "$val"; then read -r lo hi <<<"$(lim_range "$key")"; die "$key tem de estar entre $lo e $hi."; fi
    nv[$key]=$val
  done

  local f bak v p dest
  f=$(site_conf "$n"); bak="$f.bak"
  cp -p "$f" "$bak" || die "Não foi possível guardar uma cópia da configuração do site."
  for key in "${!nv[@]}"; do site_set "$n" "$key" "${nv[$key]}"; done
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); dest=$(ngx_file "$n")
  write_pool "$n" "$v"
  write_nginx "$n" "$p" "$v" "$dest"
  if ! apply_php "$v" || ! apply_nginx; then
    mv -f "$bak" "$f"
    write_pool "$n" "$v"; write_nginx "$n" "$p" "$v" "$dest"
    apply_php "$v" >/dev/null 2>&1; apply_nginx >/dev/null 2>&1
    die "Não foi possível aplicar os limites; foram repostos os anteriores."
  fi
  rm -f "$bak"
  echo "Limites do site '$n' atualizados."
  show_limits "$n"
  return 0
}

# ---------- comandos: bases de dados ----------
db_q(){ mysql -uroot -N -B -e "$1"; }
db_exec(){ printf '%s\n' "$1" | mysql -uroot -N -B; }
db_exists(){ [ "$(db_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$1'" 2>/dev/null)" = 1 ]; }
dbuser_exists(){ local c; c=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$1'" 2>/dev/null); [ -n "$c" ] && [ "$c" != 0 ]; }
db_reserved(){ case " mysql information_schema performance_schema sys mpadmin " in *" $1 "*) return 0 ;; esac; return 1; }
db_sizes(){
  db_q "SELECT s.schema_name, ROUND(COALESCE(SUM(t.data_length+t.index_length),0)/1048576,2)
        FROM information_schema.schemata s
        LEFT JOIN information_schema.tables t ON t.table_schema=s.schema_name
        WHERE s.schema_name NOT IN ('mysql','information_schema','performance_schema','sys')
        GROUP BY s.schema_name ORDER BY s.schema_name" 2>/dev/null
}

cmd_db_list(){
  local n s
  printf '%-34s %s\n' "BASE DE DADOS" "TAMANHO (MB)"
  while IFS=$'\t' read -r n s; do [ -n "$n" ] && printf '%-34s %s\n' "$n" "$s"; done < <(db_sizes)
  return 0
}

cmd_db_add(){
  local n="${1:-}" pw="" dsite=""
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --site) dsite="${2:-}"; shift 2 || shift ;;
      *) pw="$1"; shift ;;
    esac
  done
  if [ -n "$dsite" ]; then valid_site "$dsite" && site_exists "$dsite" || die "O site '$dsite' não existe."; fi
  valid_db "$n" || die "Nome inválido. Usa minúsculas, números e '_', a começar por letra (máx. 32)."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" && die "A base de dados '$n' já existe."
  dbuser_exists "$n" && die "O utilizador MariaDB '$n' já existe."
  if [ -z "$pw" ]; then pw=$(gen_pass 20)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  local ng="${n//_/\\_}"
  if ! db_exec "CREATE DATABASE \`$n\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$n'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$n'@'localhost';
FLUSH PRIVILEGES;"; then
    db_exec "DROP DATABASE IF EXISTS \`$n\`; DROP USER IF EXISTS '$n'@'localhost';" >/dev/null 2>&1
    die "Falha ao criar a base de dados '$n'."
  fi
  [ -n "$dsite" ] && dbmap_set "$n" "$dsite"
  printf 'Base de dados criada.\nServidor:      localhost (porta 3306)\nBase de dados: %s\nUtilizador:    %s\nPassword:      %s\n' "$n" "$n" "$pw"
  [ -n "$dsite" ] && echo "Associada ao site $dsite."
  return 0
}

cmd_db_del(){
  local n="${1:-}"
  valid_db "$n" || die "Nome inválido."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" || die "A base de dados '$n' não existe."
  db_exec "DROP DATABASE \`$n\`; DROP USER IF EXISTS '$n'@'localhost'; FLUSH PRIVILEGES;" || die "Falha ao apagar '$n'."
  dbmap_set "$n" ""
  echo "Base de dados '$n' e utilizador '$n' apagados."
  return 0
}

cmd_db_passwd(){
  local n="${1:-}" pw="${2:-}"
  valid_db "$n" || die "Nome inválido."
  dbuser_exists "$n" || die "O utilizador MariaDB '$n' não existe."
  if [ -z "$pw" ]; then pw=$(gen_pass 20)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  db_exec "ALTER USER '$n'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || die "Falha ao alterar a password."
  printf 'Password alterada.\nUtilizador: %s\nPassword:   %s\n' "$n" "$pw"
  return 0
}

# ---------- extensões PHP opcionais (por versão) ----------
# nome|sufixo Debian/Ubuntu (php<ver>-X)|sufixos Remi, alternativas separadas por vírgula (php<vv>-X)|descrição
ext_catalog(){
  cat <<'EOF'
apcu|apcu|php-pecl-apcu|Cache de dados em memória (APCu)
gmp|gmp|php-gmp|Aritmética de precisão arbitrária
igbinary|igbinary|php-pecl-igbinary|Serialização binária rápida
imagick|imagick|php-pecl-imagick-im7,php-pecl-imagick|Tratamento de imagens com ImageMagick
imap|imap|php-imap,php-pecl-imap|Acesso a caixas de correio IMAP
ldap|ldap|php-ldap|Autenticação LDAP e Active Directory
memcached|memcached|php-pecl-memcached|Cliente Memcached
mongodb|mongodb|php-pecl-mongodb|Cliente MongoDB
pgsql|pgsql|php-pgsql|Ligação a PostgreSQL
redis|redis|php-pecl-redis6,php-pecl-redis5|Cliente Redis
ssh2|ssh2|php-pecl-ssh2|Ligações SSH e SFTP
tidy|tidy|php-tidy|Limpeza e correção de HTML
xdebug|xdebug|php-pecl-xdebug3,php-pecl-xdebug|Depuração; só para desenvolvimento (torna o PHP mais lento)
yaml|yaml|php-pecl-yaml|Leitura e escrita de YAML
EOF
}
ext_known(){ local re='^[a-z0-9_]{2,20}$'; [[ "$1" =~ $re ]] && [ -n "$(ext_catalog | grep -m1 "^$1|")" ]; }
ext_pkgs(){
  local line en deb remi ed a
  line=$(ext_catalog | grep -m1 "^$1|")
  [ -n "$line" ] || return 1
  IFS='|' read -r en deb remi ed <<<"$line"
  if [ "$OS_FAMILY" = debian ]; then
    echo "php$2-$deb"
  else
    local IFS=,
    for a in $remi; do echo "php$(php_vv "$2")-$a"; done
  fi
}
PKG_CACHE=""
pkg_cache_load(){
  if [ "$OS_FAMILY" = debian ]; then
    PKG_CACHE=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | awk '$2=="installed"{print $1}')
  else
    PKG_CACHE=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null)
  fi
}
pkg_has(){ [[ $'\n'"$PKG_CACHE"$'\n' == *$'\n'"$1"$'\n'* ]]; }
ext_installed_pkg(){ local c; for c in $(ext_pkgs "$1" "$2"); do if pkg_has "$c"; then echo "$c"; return 0; fi; done; return 1; }
sys_pkg_install(){
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends "$1" && return 0
    apt-get -o DPkg::Lock::Timeout=180 update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends "$1"
  else
    dnf install -y -q "$1"
  fi
}
sys_pkg_remove(){
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 remove -y -q "$1"
  else
    dnf remove -y -q "$1"
  fi
}

cmd_ext_list(){
  local v="${1:-}" vs x en d
  if [ -n "$v" ]; then php_is_installed "$v" || die "PHP $v não está instalado."; vs="$v"; else vs=$(php_installed); fi
  pkg_cache_load
  for v in $vs; do
    echo "PHP $v"
    while IFS='|' read -r en _ _ d; do
      if ext_installed_pkg "$en" "$v" >/dev/null; then x=instalada; else x=-; fi
      printf '  %-11s %-10s %s\n' "$en" "$x" "$d"
    done < <(ext_catalog)
  done
  return 0
}

cmd_ext_add(){
  local v="${1:-}" x="${2:-}" p out okp=""
  php_is_installed "$v" || die "PHP $v não está instalado."
  ext_known "$x" || die "Extensão desconhecida: $x (usa 'mpanel ext-list')."
  pkg_cache_load
  ext_installed_pkg "$x" "$v" >/dev/null && die "A extensão $x já está instalada no PHP $v."
  for p in $(ext_pkgs "$x" "$v"); do
    if out=$(sys_pkg_install "$p" 2>&1); then okp=$p; break; fi
  done
  if [ -z "$okp" ]; then
    echo "$out" | tail -n 4 >&2
    die "Não foi possível instalar $x para o PHP $v (pacote indisponível nesta distribuição?)."
  fi
  apply_php "$v" || die "A extensão foi instalada, mas o PHP-FPM $v não recarregou. Verifica: $(php_fpm_bin "$v") -t"
  echo "Extensão $x instalada no PHP $v ($okp)."
  return 0
}

cmd_ext_del(){
  local v="${1:-}" x="${2:-}" p others out
  php_is_installed "$v" || die "PHP $v não está instalado."
  ext_known "$x" || die "Extensão desconhecida: $x"
  pkg_cache_load
  p=$(ext_installed_pkg "$x" "$v") || die "A extensão $x não está instalada no PHP $v."
  if [ "$OS_FAMILY" = debian ]; then
    others=$(apt-get -s remove "$p" 2>/dev/null | awk -v p="$p" '/^Remv /{ if ($2 != p) printf "%s ", $2 }')
  else
    others=$(rpm -e --test "$p" 2>&1 | awk '/is needed by/{ printf "%s ", $NF }')
  fi
  if [ -n "${others// /}" ]; then
    die "Remover $x também removeria: $others. Remove primeiro essas extensões ou mantém $x."
  fi
  out=$(sys_pkg_remove "$p" 2>&1) || { echo "$out" | tail -n 4 >&2; die "Não foi possível remover $x do PHP $v."; }
  apply_php "$v" || die "A extensão foi removida, mas o PHP-FPM $v não recarregou. Verifica: $(php_fpm_bin "$v") -t"
  echo "Extensão $x removida do PHP $v."
  return 0
}

# ---------- phpMyAdmin e conta de administração ----------
pma_version(){ if [ -f "$PMA_DIR/.mp-version" ]; then cat "$PMA_DIR/.mp-version"; fi; }
pma_write_config(){
  if [ ! -s "$PMA_CONF" ]; then
    cat > "$PMA_CONF" <<EOF
<?php
/* MiniPainel — configuração do phpMyAdmin (copiada para $PMA_DIR em cada atualização) */
declare(strict_types=1);
\$cfg['blowfish_secret'] = '$(gen_pass 32)';
\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = false;
\$cfg['TempDir'] = '/var/lib/minipainel-pma/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['VersionCheck'] = false;
\$cfg['SendErrorReports'] = 'never';
\$cfg['LoginCookieValidity'] = 7200;
\$cfg['DefaultLang'] = 'pt';
EOF
  fi
  chown root:"$PMA_USER" "$PMA_CONF"
  chmod 640 "$PMA_CONF"
}

# Garante que o config.inc.php existe e é legível pelo pool do phpMyAdmin
pma_fix_config(){
  [ -d "$PMA_DIR" ] || return 0
  pma_write_config
  pma_settings_apply
  se_restore "$PMA_DIR/config.inc.php"
}

cmd_pma_update(){
  local force=0 latest cur tmp url want got
  [ "${1:-}" = "--force" ] && force=1
  id "$PMA_USER" >/dev/null 2>&1 || die "Utilizador $PMA_USER em falta; volta a correr o instalador."
  latest=$(curl -fsSL --max-time 30 https://www.phpmyadmin.net/home_page/version.txt 2>/dev/null | head -n1 | tr -d '\r')
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Não foi possível obter a versão do phpMyAdmin (sem acesso a phpmyadmin.net?)."
  cur=$(pma_version)
  if [ "$cur" = "$latest" ] && [ "$force" = 0 ]; then
    pma_fix_config
    echo "O phpMyAdmin já está na versão mais recente ($cur)."
    return 0
  fi
  tmp=$(mktemp -d /var/tmp/mp-pma.XXXXXX) || die "Não foi possível criar pasta temporária."
  url="https://files.phpmyadmin.net/phpMyAdmin/$latest/phpMyAdmin-$latest-all-languages.tar.gz"
  if ! curl -fsSL --max-time 600 -o "$tmp/pma.tgz" "$url" || ! curl -fsSL --max-time 30 -o "$tmp/pma.sha256" "$url.sha256"; then
    rm -rf "$tmp"; die "Falha no download do phpMyAdmin $latest."
  fi
  want=$(awk '{print $1; exit}' "$tmp/pma.sha256")
  got=$(sha256sum "$tmp/pma.tgz" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then rm -rf "$tmp"; die "O SHA-256 do phpMyAdmin $latest não confere; nada foi alterado."; fi
  mkdir "$tmp/x"
  if ! tar xzf "$tmp/pma.tgz" -C "$tmp/x" --strip-components=1 || [ ! -f "$tmp/x/index.php" ]; then
    rm -rf "$tmp"; die "O pacote do phpMyAdmin não é válido; nada foi alterado."
  fi
  rm -rf "$tmp/x/setup" "$tmp/x/examples" "$tmp/x/test"
  pma_write_config
  cp -p "$PMA_CONF" "$tmp/x/config.inc.php"
  echo "$latest" > "$tmp/x/.mp-version"
  chown -R root:root "$tmp/x"
  find "$tmp/x" -type d -exec chmod 755 {} +
  find "$tmp/x" -type f -exec chmod 644 {} +
  chown root:"$PMA_USER" "$tmp/x/config.inc.php"; chmod 640 "$tmp/x/config.inc.php"
  rm -rf "$PMA_DIR.new" "$PMA_DIR.old"
  mv "$tmp/x" "$PMA_DIR.new" || { rm -rf "$tmp" "$PMA_DIR.new"; die "Falha ao copiar o phpMyAdmin."; }
  if [ -d "$PMA_DIR" ]; then mv "$PMA_DIR" "$PMA_DIR.old"; fi
  if ! mv "$PMA_DIR.new" "$PMA_DIR"; then
    if [ -d "$PMA_DIR.old" ]; then mv "$PMA_DIR.old" "$PMA_DIR"; fi
    rm -rf "$tmp" "$PMA_DIR.new"; die "Falha ao instalar o phpMyAdmin; a versão anterior foi reposta."
  fi
  se_restore "$PMA_DIR"
  rm -rf "$PMA_DIR.old" "$tmp"
  if [ -n "$cur" ]; then echo "phpMyAdmin atualizado de $cur para $latest."; else echo "phpMyAdmin $latest instalado."; fi
  return 0
}

cmd_db_admin_passwd(){
  local pw="${1:-}"
  if [ -z "$pw" ]; then pw=$(gen_pass 24)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  if dbuser_exists "$DB_ADMIN"; then
    db_exec "ALTER USER '$DB_ADMIN'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || die "Falha ao alterar a password de $DB_ADMIN."
    echo "Password da conta de administração alterada."
  else
    db_exec "CREATE USER '$DB_ADMIN'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON *.* TO '$DB_ADMIN'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;" || { db_exec "DROP USER IF EXISTS '$DB_ADMIN'@'localhost';" >/dev/null 2>&1; die "Falha ao criar a conta $DB_ADMIN."; }
    echo "Conta de administração criada (acesso a todas as bases de dados, só a partir de localhost)."
  fi
  printf 'Utilizador: %s\nPassword: %s\n' "$DB_ADMIN" "$pw"
  return 0
}

# ---------- comandos: sistema ----------
cmd_php_list(){
  local v n c
  printf '%-8s %-10s %-6s %s\n' VERSAO ESTADO SITES ""
  for v in $(php_installed); do
    c=0
    for n in $(site_names); do [ "$(site_get "$n" PHP)" = "$v" ] && c=$((c+1)); done
    printf '%-8s %-10s %-6s %s\n' "$v" "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)" "$c" \
      "$([ "$v" = "$DEFAULT_PHP" ] && echo '(predefinida)')"
  done
  return 0
}

cmd_status(){
  local v
  printf '%-26s %s\n' nginx "$(systemctl is-active nginx 2>/dev/null)"
  printf '%-26s %s\n' mariadb "$(systemctl is-active mariadb 2>/dev/null)"
  for v in $(php_installed); do
    printf '%-26s %s\n' "$(php_service "$v")" "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)"
  done
  printf '%-26s %s\n' minipainel-worker.path "$(systemctl is-active minipainel-worker.path 2>/dev/null)"
  echo
  echo "Painel: https://<IP-do-servidor>:$PANEL_PORT   PHP predefinido: $DEFAULT_PHP   Sites: $(site_names | wc -l)"
  return 0
}

cmd_service(){
  local id="${1:-}" act="${2:-}" unit name v="" out label
  case "$act" in
    reload) label=recarregado ;; restart) label=reiniciado ;; start) label=iniciado ;; stop) label=parado ;;
    *) die "Ação inválida: usa reload, restart, start ou stop." ;;
  esac
  case "$id" in
    nginx)   unit=nginx;   name=nginx ;;
    mariadb) unit=mariadb; name=MariaDB ;;
    php-*)   v="${id#php-}"; php_is_installed "$v" || die "PHP $v não está instalado."
             unit=$(php_service "$v"); name="PHP-FPM $v" ;;
    postfix|dovecot|rspamd|unbound) mail_on || die "O email não está ativo."; unit=$id; name=$id ;;
    redis) mail_on || die "O email não está ativo."; unit=$(mail_svc_redis); name=Redis ;;
    clamav) [ "$(mail_get CLAMAV 0)" = 1 ] || die "O antivírus não está ativo."; unit=clamav-daemon; systemctl list-unit-files clamd@.service >/dev/null 2>&1 && [ "$OS_FAMILY" != debian ] && unit=clamd@scan; name=ClamAV ;;
    *) die "Serviço desconhecido: $id (nginx, mariadb ou php-X.Y)." ;;
  esac
  if [ "$act" = stop ]; then
    [ "$id" = nginx ] && die "Parar o nginx deixaria o painel inacessível. Usa restart."
    [ "$id" = mariadb ] && die "Parar o MariaDB deixaria todos os sites sem base de dados. Usa restart."
    [ "$v" = "$PANEL_PHP" ] && die "O PHP $v é usado pelo próprio painel e não pode ser parado."
  fi
  [ "$id" = mariadb ] && [ "$act" = reload ] && die "O MariaDB não suporta recarregar. Usa restart."
  if [ "$act" = reload ] && ! systemctl is-active --quiet "$unit"; then die "$name não está a correr. Usa start."; fi
  if [ "$act" != stop ]; then
    if [ "$id" = nginx ]; then
      out=$(nginx -t 2>&1) || { echo "$out" >&2; die "Configuração do nginx inválida; nada foi feito."; }
    elif [ -n "$v" ]; then
      out=$("$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" 2>&1) || { echo "$out" >&2; die "Configuração do PHP-FPM $v inválida; nada foi feito."; }
    fi
  fi
  systemctl "$act" "$unit" >/dev/null 2>&1 || die "Falha ao executar '$act' em $unit (ver: journalctl -u $unit -n 30)."
  if [ "$act" != stop ]; then
    sleep 1
    systemctl is-active --quiet "$unit" || die "$name não ficou ativo (ver: journalctl -u $unit -n 30)."
  fi
  echo "$name $label."
  [ "$act" = stop ] && echo "Volta a arrancar automaticamente no próximo reinício do servidor."
  return 0
}

# ---------- firewall: ligações e bloqueio de IPs (nftables, tabela própria) ----------
FW_BLOCKS=/etc/minipainel/blocks.list   # ip|expira (epoch, 0 = permanente)|criado|origem|motivo
FW_ALLOW=/etc/minipainel/allow.list     # um IP ou rede por linha
FW_CONF=/etc/minipainel/firewall.conf   # AUTO, LIMIT, DURATION
FW_STATE=$DATA/stats/fw.json
FW_ADMIN=$DATA/logs/admin-ips.json      # IPs de onde o painel foi usado (escrito pelo painel)

fw_has_nft(){ command -v nft >/dev/null 2>&1; }
fw_ip_valid(){
  local re4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
  local re6='^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$'
  if [[ "$1" =~ $re4 ]]; then
    local o x; IFS=. read -ra o <<<"${1%%/*}"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
  fi
  [[ "$1" =~ $re6 ]]
}
fw_fam(){ if [[ "$1" == *:* ]]; then echo 6; else echo 4; fi; }
fw_prefix(){ if [[ "$1" == */* ]]; then echo "${1#*/}"; elif [[ "$1" == *:* ]]; then echo 128; else echo 32; fi; }
ip2int(){ local a b c d; IFS=. read -r a b c d <<<"${1%%/*}"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
in_cidr4(){ # ip cidr
  local bits mask; bits=$(fw_prefix "$2")
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$1") & mask )) -eq $(( $(ip2int "$2") & mask )) ]
}
fw_overlap(){ # a b — verdadeiro se uma rede contém a outra (IPv6: só igualdade exata)
  local a=$1 b=$2
  [ "$(fw_fam "$a")" = "$(fw_fam "$b")" ] || return 1
  if [ "$(fw_fam "$a")" = 4 ]; then in_cidr4 "${a%%/*}" "$b" || in_cidr4 "${b%%/*}" "$a"; return; fi
  [ "${a%%/*}" = "${b%%/*}" ]
}
fw_protected_list(){
  echo 127.0.0.1; echo ::1
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$'
  [ -f "$FW_ALLOW" ] && grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}'
  if [ -s "$FW_ADMIN" ]; then
    jq -r --argjson lim $(( EPOCHSECONDS - 7 * 86400 )) 'to_entries[] | select(.value > $lim) | .key' "$FW_ADMIN" 2>/dev/null
  fi
  return 0
}
fw_conf_get(){ local v; v=$(grep -m1 "^$1=" "$FW_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
fw_secs(){
  local re='^[0-9]{1,7}[smhd]?$'
  case "$1" in perm|permanente|0) echo 0; return 0 ;; esac
  [[ "$1" =~ $re ]] || return 1
  case "$1" in
    *s) echo "${1%s}" ;; *m) echo $(( ${1%m} * 60 )) ;; *h) echo $(( ${1%h} * 3600 )) ;; *d) echo $(( ${1%d} * 86400 )) ;; *) echo "$1" ;;
  esac
}
fw_init(){
  fw_has_nft || die "O nftables (nft) não está instalado."
  nft list table inet minipainel >/dev/null 2>&1 && return 0
  nft -f - <<'NFT' || die "Não foi possível criar a tabela nftables do painel."
table inet minipainel {
  set block4 { type ipv4_addr; flags interval, timeout; }
  set block6 { type ipv6_addr; flags interval, timeout; }
  set trust4 { type ipv4_addr; flags interval; }
  set trust6 { type ipv6_addr; flags interval; }
  set geo4 { type ipv4_addr; flags interval; }
  set geo6 { type ipv6_addr; flags interval; }
  set home4 { type ipv4_addr; flags interval; }
  set home6 { type ipv6_addr; flags interval; }
  chain ovl {
  }
  chain input {
    type filter hook input priority -10; policy accept;
    ip saddr @block4 drop
    ip6 saddr @block6 drop
    ip saddr @trust4 accept
    ip6 saddr @trust6 accept
    ct state new ip saddr @geo4 counter drop
    ct state new ip6 saddr @geo6 counter drop
    ct state new jump ovl
  }
}
NFT
}
fw_nft_add(){ # ip segundos
  local set el="$1"
  set="block$(fw_fam "$1")"
  [ "$2" -gt 0 ] && el="$1 timeout ${2}s"
  nft delete element inet minipainel "$set" "{ $1 }" >/dev/null 2>&1
  nft add element inet minipainel "$set" "{ $el }"
}
fw_nft_del(){ nft delete element inet minipainel "block$(fw_fam "$1")" "{ $1 }" >/dev/null 2>&1; return 0; }
fw_list_set(){ # reescreve a lista sem a linha do IP indicado e sem expirados
  local skip=$1 tmp="$FW_BLOCKS.tmp"
  [ -f "$FW_BLOCKS" ] || : > "$FW_BLOCKS"
  awk -F'|' -v s="$skip" -v now="$EPOCHSECONDS" '$1 != s && ($2 == 0 || $2 > now)' "$FW_BLOCKS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$FW_BLOCKS"
}
fw_write_state(){
  local blocks allow nftok=false
  fw_has_nft && nft list table inet minipainel >/dev/null 2>&1 && nftok=true
  blocks=$( [ -f "$FW_BLOCKS" ] && awk -F'|' -v now="$EPOCHSECONDS" '$2 == 0 || $2 > now' "$FW_BLOCKS" | while IFS='|' read -r ip ex cr by rs; do
      jq -cn --arg ip "$ip" --arg ex "$ex" --arg cr "$cr" --arg by "$by" --arg rs "$rs" '{ip:$ip, exp:($ex|tonumber), created:($cr|tonumber), by:$by, reason:$rs}'
    done | jq -cs '.')
  allow=$( [ -f "$FW_ALLOW" ] && grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}' | jq -R . | jq -cs '.')
  jq -n --argjson b "${blocks:-[]}" --argjson a "${allow:-[]}" --argjson nft "$nftok" \
    --arg on "$(fw_conf_get AUTO 0)" --arg lim "$(fw_conf_get LIMIT 150)" --arg dur "$(fw_conf_get DURATION 3600)" \
    '{nft:$nft, auto:{on:($on=="1"), limit:($lim|tonumber), duration:($dur|tonumber)}, blocks:$b, allow:$a}' > "$FW_STATE.tmp" \
    && chown root:"$PANEL_SYSUSER" "$FW_STATE.tmp" && chmod 640 "$FW_STATE.tmp" && mv -f "$FW_STATE.tmp" "$FW_STATE"
  return 0
}

cmd_block(){
  local ip="${1:-}" dur="24h" reason="" by="manual" extra="" secs exp p
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) dur="${2:-}"; shift 2 || shift ;;
      --reason) reason="${2:-}"; shift 2 || shift ;;
      --by) by="${2:-}"; shift 2 || shift ;;
      --protect) extra="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  if [ "$(fw_fam "$ip")" = 4 ] && [ "$(fw_prefix "$ip")" -lt 8 ]; then die "Rede demasiado grande (mínimo /8)."; fi
  if [ "$(fw_fam "$ip")" = 6 ] && [ "$(fw_prefix "$ip")" -lt 32 ]; then die "Rede demasiado grande (mínimo /32)."; fi
  case "$by" in manual|auto) ;; *) by=manual ;; esac
  secs=$(fw_secs "$dur") || die "Duração inválida: $dur (ex.: 3600s, 1h, 24h, 7d ou perm)."
  reason=$(printf '%s' "$reason" | tr -d '|\r\n' | cut -c1-80)
  p=$( { fw_protected_list; if [ -n "$extra" ] && fw_ip_valid "$extra"; then echo "$extra"; fi; } | sort -u | while read -r q; do
         if [ -n "$q" ] && fw_ip_valid "$q" && fw_overlap "$ip" "$q"; then echo "$q"; break; fi
       done )
  [ -z "$p" ] || die "Não é possível bloquear $ip: abrange $p, que está protegido (este servidor, IP de confiança ou IP de onde usas o painel)."
  fw_init
  fw_nft_add "$ip" "$secs" || die "O nftables recusou o bloqueio de $ip."
  exp=0; [ "$secs" -gt 0 ] && exp=$(( EPOCHSECONDS + secs ))
  fw_list_set "$ip"
  echo "$ip|$exp|$EPOCHSECONDS|$by|$reason" >> "$FW_BLOCKS"
  ss -K dst "$ip" >/dev/null 2>&1
  fw_write_state
  if [ "$secs" -gt 0 ]; then echo "$ip bloqueado até $(date -d "@$exp" '+%d/%m/%Y %H:%M'). Ligações abertas cortadas."
  else echo "$ip bloqueado permanentemente. Ligações abertas cortadas."; fi
  return 0
}
cmd_unblock(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  fw_has_nft && fw_nft_del "$ip"
  fw_list_set "$ip"
  fw_write_state
  echo "$ip desbloqueado."
  return 0
}
cmd_block_list(){
  printf '%-40s %-17s %-8s %s\n' "IP / REDE" "EXPIRA" "ORIGEM" "MOTIVO"
  [ -f "$FW_BLOCKS" ] && awk -F'|' -v now="$EPOCHSECONDS" '$2 == 0 || $2 > now' "$FW_BLOCKS" | while IFS='|' read -r ip ex cr by rs; do
    printf '%-40s %-17s %-8s %s\n' "$ip" "$([ "$ex" = 0 ] && echo permanente || date -d "@$ex" '+%d/%m/%Y %H:%M')" "$by" "$rs"
  done
  return 0
}
cmd_allow_add(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  touch "$FW_ALLOW"; chmod 600 "$FW_ALLOW"
  grep -qxF "$ip" "$FW_ALLOW" || echo "$ip" >> "$FW_ALLOW"
  if [ "$(srv_get PORTS_ACCESS all)" = lan ]; then ports_allow_write; apply_nginx >/dev/null 2>&1; fi
  if [ -f "$FW_BLOCKS" ] && cut -d'|' -f1 "$FW_BLOCKS" | grep -qxF "$ip"; then fw_has_nft && fw_nft_del "$ip"; fw_list_set "$ip"; fi
  fw_write_state
  echo "$ip adicionado aos IPs de confiança (nunca é bloqueado)."
  return 0
}
cmd_allow_del(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  if [ -f "$FW_ALLOW" ]; then grep -vxF "$ip" "$FW_ALLOW" > "$FW_ALLOW.tmp"; mv -f "$FW_ALLOW.tmp" "$FW_ALLOW"; fi
  [ -f "$FW_ALLOW" ] && grep -qxF "$ip" "$FW_ALLOW" && die "Não foi possível remover $ip."
  chmod 600 "$FW_ALLOW" 2>/dev/null
  if [ "$(srv_get PORTS_ACCESS all)" = lan ]; then ports_allow_write; apply_nginx >/dev/null 2>&1; fi
  fw_write_state
  echo "$ip removido dos IPs de confiança."
  return 0
}
cmd_fw_auto(){
  local on="${1:-}" lim dur secs re='^[0-9]{1,6}$'
  case "$on" in on|1) on=1 ;; off|0) on=0 ;; *) die "Usa: mpanel fw-auto on|off [--limit N] [--duration 1h]" ;; esac
  shift
  lim=$(fw_conf_get LIMIT 150); dur=$(fw_conf_get DURATION 3600)
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) lim="${2:-}"; shift 2 || shift ;;
      --duration) dur="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$lim" =~ $re ]] && [ "$lim" -ge 10 ] || die "O limite tem de ser um número igual ou superior a 10."
  secs=$(fw_secs "$dur") || die "Duração inválida: $dur"
  [ "$secs" -gt 0 ] || die "O bloqueio automático tem de ter duração (não pode ser permanente)."
  printf 'AUTO=%s\nLIMIT=%s\nDURATION=%s\n' "$on" "$lim" "$secs" > "$FW_CONF"; chmod 644 "$FW_CONF"
  fw_write_state
  if [ "$on" = 1 ]; then echo "Bloqueio automático ativo: IPs com mais de $lim ligações abertas ficam bloqueados durante $(( secs / 60 )) min."
  else echo "Bloqueio automático desativado."; fi
  return 0
}
cmd_fw_restore(){
  local ip ex cr by rs left
  fw_has_nft || { warn "O nftables não está instalado."; return 0; }
  nft delete table inet minipainel >/dev/null 2>&1
  fw_init
  fw_list_set ""
  [ -f "$FW_BLOCKS" ] && while IFS='|' read -r ip ex cr by rs; do
    left=0; [ "$ex" != 0 ] && left=$(( ex - EPOCHSECONDS ))
    [ "$ex" != 0 ] && [ "$left" -le 0 ] && continue
    fw_nft_add "$ip" "$left" >/dev/null 2>&1 || warn "Não foi possível repor o bloqueio de $ip."
  done < "$FW_BLOCKS"
  fw_write_state
  mail_fw_apply
  geo_apply
  echo "Bloqueios repostos: $( [ -f "$FW_BLOCKS" ] && wc -l < "$FW_BLOCKS" || echo 0)."
  return 0
}
cmd_conn_list(){
  local f=$DATA/stats/conns.json ip="${1:-}"
  [ -s "$f" ] || die "Ainda não há dados. Verifica: systemctl status minipainel-stats"
  if [ -n "$ip" ]; then
    jq -r --arg ip "$ip" '.ips[] | select(.ip == $ip) | "\(.ip): \(.n) ligações (\(.syn) em espera)", (.ports | to_entries[] | "  porta \(.key): \(.value)")' "$f"
  else
    jq -r '"Ligações abertas: \(.total)   IPs distintos: \(.distinct)   Em espera (SYN): \(.syn)", (.ips[:30][] | "  \(.n)\t\(.ip)\t" + (.ports | to_entries | map("\(.key)(\(.value))") | join(" ")))' "$f"
  fi
  return 0
}

# ---------- tarefas agendadas (cron) por site, como o utilizador do site ----------
CRON_DIR=/etc/minipainel/cron          # <site>.json (definições) e <site>/<id>.sh (comandos)
cron_json(){ echo "$CRON_DIR/$1.json"; }
cron_valid_when(){
  local w="$1" f re='^(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(/[0-9]+)?(,(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(/[0-9]+)?)*$'
  case "$w" in @hourly|@daily|@weekly|@monthly|@yearly|@annually) return 0 ;; esac
  local -a parts; read -ra parts <<<"$w"
  [ ${#parts[@]} -eq 5 ] || return 1
  for f in "${parts[@]}"; do [[ "$f" =~ $re ]] || return 1; done
  return 0
}
cron_valid_cmd(){ [ -n "$1" ] && [ ${#1} -le 2000 ] && [[ "$1" != *$'\n'* ]] && [[ "$1" != *$'\r'* ]]; }
cron_load(){ local f; f=$(cron_json "$1"); if [ -s "$f" ]; then cat "$f"; else echo '[]'; fi; }
cron_save(){ # site json
  local f; f=$(cron_json "$1")
  install -d -m 755 "$CRON_DIR"
  printf '%s\n' "$2" | jq '.' > "$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}
cron_write_site(){ # gera /etc/cron.d/minipainel-<site>, os scripts e o php da versão do site
  local n=$1 u="mp_$1" j sd cf v id
  sd="$CRON_DIR/$n"; cf="/etc/cron.d/minipainel-$n"
  id "$u" >/dev/null 2>&1 || return 0
  j=$(cron_load "$n")
  install -d -o root -g "$u" -m 750 "$sd" "$sd/bin"
  v=$(site_get "$n" PHP)
  [ -n "$v" ] && ln -sfn "$(php_cli "$v")" "$sd/bin/php"
  find "$sd" -maxdepth 1 -name '*.sh' -type f | while read -r f; do
    id=$(basename "$f" .sh)
    [ "$(printf '%s' "$j" | jq --arg id "$id" 'map(select(.id == $id)) | length')" = 0 ] && rm -f "$f"
  done
  printf '%s' "$j" | jq -c '.[]' | while read -r row; do
    id=$(jq -r '.id' <<<"$row")
    { printf '#!/bin/sh\n# IDDigital Hosting — tarefa %s do site %s (gerido pelo painel)\n' "$id" "$n"; jq -r '.cmd' <<<"$row"; } > "$sd/$id.sh"
    chown root:"$u" "$sd/$id.sh"; chmod 750 "$sd/$id.sh"
  done
  if [ "$(printf '%s' "$j" | jq 'map(select(.on)) | length')" = 0 ]; then
    rm -f "$cf"
  else
    {
      printf '# IDDigital Hosting — tarefas agendadas do site %s (gerado pelo painel; não editar à mão)\n' "$n"
      printf 'SHELL=/bin/sh\nPATH=/usr/local/bin:/usr/bin:/bin\nMAILTO=""\n'
      printf '%s' "$j" | jq -r --arg u "$u" --arg n "$n" '.[] | select(.on) | "\(.when) \($u) /usr/local/sbin/mpanel-cron \($n) \(.id)"'
    } > "$cf.tmp" && chmod 644 "$cf.tmp" && mv -f "$cf.tmp" "$cf"
  fi
  touch /etc/cron.d 2>/dev/null
  return 0
}
cron_need(){ valid_site "$1" && site_exists "$1" || die "O site '$1' não existe."; }
cron_need_id(){ local re='^[a-f0-9]{8}$'; [[ "$2" =~ $re ]] || die "Identificador inválido: $2"
  [ "$(cron_load "$1" | jq --arg id "$2" 'map(select(.id == $id)) | length')" = 1 ] || die "A tarefa $2 não existe no site $1."; }

cmd_cron_list(){
  local n f
  printf '%-10s %-12s %-6s %-20s %s\n' ID SITE ESTADO QUANDO COMANDO
  for n in $(site_names); do
    [ -z "${1:-}" ] || [ "$1" = "$n" ] || continue
    cron_load "$n" | jq -r --arg n "$n" '.[] | [.id, $n, (if .on then "ativa" else "pausa" end), .when, .cmd] | @tsv' |
      while IFS=$'\t' read -r i s e w c; do printf '%-10s %-12s %-6s %-20s %s\n' "$i" "$s" "$e" "$w" "$c"; done
  done
  return 0
}
cron_parse(){ # define WHEN CMD LABEL ON a partir das opções
  while [ $# -gt 0 ]; do
    case "$1" in
      --when) WHEN="${2:-}"; shift 2 || shift ;;
      --cmd) CMD="${2:-}"; shift 2 || shift ;;
      --label) LABEL="${2:-}"; shift 2 || shift ;;
      --off) ON=false; shift ;;
      --on) ON=true; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}
cmd_cron_add(){
  local n="${1:-}" id j WHEN="" CMD="" LABEL="" ON=true
  [ $# -gt 0 ] && shift
  cron_need "$n"; cron_parse "$@"
  cron_valid_when "$WHEN" || die "Periodicidade inválida: '$WHEN' (5 campos: minuto hora dia mês dia-da-semana)."
  cron_valid_cmd "$CMD" || die "Comando inválido (obrigatório, numa só linha, até 2000 caracteres)."
  LABEL=$(printf '%s' "$LABEL" | tr -d '\r\n' | cut -c1-80)
  id=$(openssl rand -hex 4)
  j=$(cron_load "$n" | jq --arg id "$id" --arg w "$WHEN" --arg c "$CMD" --arg d "$LABEL" --argjson on "$ON" --arg t "$EPOCHSECONDS" \
      '. + [{id:$id, when:$w, cmd:$c, desc:$d, on:$on, created:($t|tonumber)}]')
  cron_save "$n" "$j"; cron_write_site "$n"
  echo "Tarefa $id criada no site $n ($WHEN)."
  return 0
}
cmd_cron_edit(){
  local n="${1:-}" id="${2:-}" j cur WHEN CMD LABEL ON
  cron_need "$n"; cron_need_id "$n" "$id"; shift 2
  cur=$(cron_load "$n" | jq -c --arg id "$id" '.[] | select(.id == $id)')
  WHEN=$(jq -r '.when' <<<"$cur"); CMD=$(jq -r '.cmd' <<<"$cur"); LABEL=$(jq -r '.desc' <<<"$cur"); ON=$(jq -r '.on' <<<"$cur")
  cron_parse "$@"
  cron_valid_when "$WHEN" || die "Periodicidade inválida: '$WHEN'."
  cron_valid_cmd "$CMD" || die "Comando inválido (obrigatório, numa só linha, até 2000 caracteres)."
  LABEL=$(printf '%s' "$LABEL" | tr -d '\r\n' | cut -c1-80)
  j=$(cron_load "$n" | jq --arg id "$id" --arg w "$WHEN" --arg c "$CMD" --arg d "$LABEL" --argjson on "$ON" \
      'map(if .id == $id then .when = $w | .cmd = $c | .desc = $d | .on = $on else . end)')
  cron_save "$n" "$j"; cron_write_site "$n"
  echo "Tarefa $id atualizada."
  return 0
}
cmd_cron_toggle(){
  local n="${1:-}" id="${2:-}" on=$3 j
  cron_need "$n"; cron_need_id "$n" "$id"
  j=$(cron_load "$n" | jq --arg id "$id" --argjson on "$on" 'map(if .id == $id then .on = $on else . end)')
  cron_save "$n" "$j"; cron_write_site "$n"
  if [ "$on" = true ]; then echo "Tarefa $id ativada."; else echo "Tarefa $id em pausa."; fi
  return 0
}
cmd_cron_del(){
  local n="${1:-}" id="${2:-}" j
  cron_need "$n"; cron_need_id "$n" "$id"
  j=$(cron_load "$n" | jq --arg id "$id" 'map(select(.id != $id))')
  cron_save "$n" "$j"; cron_write_site "$n"
  rm -f "$WWW_ROOT/$n/logs/cron-$id.log" "$WWW_ROOT/$n/logs/cron-$id.status" "$WWW_ROOT/$n/tmp/.cron-$id.lock"
  echo "Tarefa $id apagada."
  return 0
}
cmd_cron_run(){
  local n="${1:-}" id="${2:-}" st i s1 out
  cron_need "$n"; cron_need_id "$n" "$id"
  cron_write_site "$n"
  st="$WWW_ROOT/$n/logs/cron-$id.status"
  s1=$(runuser -u "mp_$n" -- cat "$st" 2>/dev/null)
  setsid runuser -u "mp_$n" -- /usr/local/sbin/mpanel-cron "$n" "$id" >/dev/null 2>&1 < /dev/null 9>&- &
  for i in $(seq 1 40); do
    sleep 0.5
    out=$(runuser -u "mp_$n" -- cat "$st" 2>/dev/null)
    if [ -n "$out" ] && [ "$out" != "$s1" ] && [[ "$out" != *running* ]]; then
      echo "Tarefa $id executada; terminou com código ${out##* }."
      echo "Últimas linhas:"; runuser -u "mp_$n" -- tail -n 12 "$WWW_ROOT/$n/logs/cron-$id.log" 2>/dev/null | grep -v '^=== '
      return 0
    fi
  done
  echo "Tarefa $id iniciada; ainda está a correr. O resultado aparece no painel dentro de um minuto."
  return 0
}
cmd_cron_sync(){
  local n f
  install -d -m 755 "$CRON_DIR"
  for n in $(site_names); do cron_write_site "$n"; done
  for f in /etc/cron.d/minipainel-*; do
    [ -f "$f" ] || continue
    n=${f#/etc/cron.d/minipainel-}; site_exists "$n" || rm -f "$f"
  done
  echo "Tarefas agendadas sincronizadas."
  return 0
}
cron_state_json(){ # todas as tarefas, para o painel
  local n
  for n in $(site_names); do cron_load "$n" | jq -c --arg n "$n" '.[] | . + {site:$n}'; done | jq -cs '.'
}

# ---------- associação de bases de dados a sites ----------
DBMAP=/etc/minipainel/dbmap.json
dbmap_load(){ if [ -s "$DBMAP" ]; then cat "$DBMAP"; else echo '{}'; fi; }
dbmap_set(){ # db site|""
  local j; j=$(dbmap_load | jq --arg d "$1" --arg s "$2" 'if $s == "" then del(.[$d]) else .[$d] = $s end')
  printf '%s\n' "$j" > "$DBMAP.tmp" && chmod 600 "$DBMAP.tmp" && mv -f "$DBMAP.tmp" "$DBMAP"
}
dbs_of_site(){ dbmap_load | jq -r --arg s "$1" 'to_entries[] | select(.value == $s) | .key'; }
cmd_db_link(){
  local d="${1:-}" s="${2:-}"
  valid_db "$d" && db_exists "$d" || die "A base de dados '$d' não existe."
  if [ "$s" = none ] || [ -z "$s" ]; then dbmap_set "$d" ""; echo "Base de dados $d já não está associada a nenhum site."; return 0; fi
  valid_site "$s" && site_exists "$s" || die "O site '$s' não existe."
  dbmap_set "$d" "$s"
  echo "Base de dados $d associada ao site $s (entra nos backups do site)."
  return 0
}

# ---------- backups (local + destinos remotos via rclone) ----------
BK_DIR=/var/backups/minipainel
BK_CONF=/etc/minipainel/backup.conf
BK_RCLONE=/etc/minipainel/rclone.conf
BK_REMOTES=/etc/minipainel/backup-remotes.json   # [{name,type,root}]
BK_STATE=$DATA/stats/backup.json
BK_LOCK=/run/minipainel-backup.lock
bk_conf(){ local v; v=$(grep -m1 "^$1=" "$BK_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
bk_remotes(){ if [ -s "$BK_REMOTES" ]; then cat "$BK_REMOTES"; else echo '[]'; fi; }
bk_rc(){ rclone --config "$BK_RCLONE" "$@"; }
# Tipos aceites na configuração colada (destinos remotos reais). sftp e s3 só pelo formulário.
BK_RAW_TYPES=" drive onedrive dropbox b2 webdav ftp pcloud box mega swift azureblob azurefiles gcs koofr opendrive yandex jottacloud sharefile seafile hidrive putio storj protondrive mailru premiumizeme quatrix sugarsync zoho filefabric "
bk_section(){ awk -v n="[$1]" '$0 == n { f = 1; next } /^\[/ { f = 0 } f' "$BK_RCLONE" 2>/dev/null; }
bk_cfg_check(){ # $1 = texto da secção (sem o cabeçalho); $2 = form|raw. Imprime o motivo se for inseguro.
  local txt=$1 how=$2 type k v line
  type=$(printf '%s\n' "$txt" | awk -F= '/^[[:space:]]*type[[:space:]]*=/ { v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }')
  [ -n "$type" ] || { echo "falta o tipo (type = ...)"; return 1; }
  if [ "$how" = raw ]; then
    [[ "$BK_RAW_TYPES" == *" $type "* ]] || { echo "o tipo '$type' não é permitido aqui (usa o formulário para SFTP e S3)"; return 1; }
  else
    case "$type" in sftp|s3) ;; *) [[ "$BK_RAW_TYPES" == *" $type "* ]] || { echo "o tipo '$type' não é permitido"; return 1; } ;; esac
  fi
  while IFS= read -r line; do
    case "$line" in ''|'#'*|';'*) continue ;; esac
    [[ "$line" == *=* ]] || { echo "linha inválida: $line"; return 1; }
    k=${line%%=*}; k=${k//[[:space:]]/}; v=${line#*=}; v=${v#"${v%%[![:space:]]*}"}
    case "$k" in
      ssh|remote|upstreams) echo "a opção '$k' não é permitida"; return 1 ;;
      key_file) [ "$how" = form ] && [[ "$v" == /etc/minipainel/rclone-keys/*.key ]] && [[ "$v" != *..* ]] || { echo "a opção '$k' não é permitida"; return 1; } ;;
      *_file|*_path|*file) echo "a opção '$k' não é permitida (lê ficheiros locais)"; return 1 ;;
    esac
  done <<<"$txt"
  return 0
}
bk_remote_ok(){ # nome -> 0 se o destino estiver configurado de forma segura
  local why; why=$(bk_cfg_check "$(bk_section "$1")" form) && return 0
  echo "O destino '$1' tem uma configuração não permitida ($why). Remove-o e volta a criá-lo." >&2
  return 1
}
BK_KEY=/etc/minipainel/backup.key
bk_key_ensure(){ if [ ! -s "$BK_KEY" ]; then ( umask 077; openssl rand -hex 32 > "$BK_KEY" ); fi; chmod 600 "$BK_KEY"; }
# HMAC-SHA256 do manifesto (a chave nunca passa na linha de comandos)
bk_hmac(){ "$(php_cli "$PANEL_PHP")" -r 'echo hash_hmac("sha256", (string)file_get_contents($argv[1]), trim((string)file_get_contents($argv[2])));' "$1" "$BK_KEY" 2>/dev/null; }
bk_sign(){ bk_key_ensure; bk_hmac "$1/manifest.json" > "$1/manifest.sig"; chown root:"$PANEL_SYSUSER" "$1/manifest.sig"; chmod 640 "$1/manifest.sig"; }
# 0 = assinatura e ficheiros válidos; 1 = alterado; 2 = backup antigo sem assinatura
bk_verify(){
  local dir=$1 f rel listed
  [ -f "$dir/manifest.sig" ] || return 2
  [ -s "$BK_KEY" ] || return 1
  [ "$(cat "$dir/manifest.sig")" = "$(bk_hmac "$dir/manifest.json")" ] || return 1
  jq -e '.sums | type == "object"' "$dir/manifest.json" >/dev/null 2>&1 || return 1
  ( cd "$dir" && jq -r '.sums | to_entries[] | "\(.value)  \(.key)"' manifest.json | sha256sum -c --quiet --strict >/dev/null 2>&1 ) || return 1
  listed=$(jq -r '.sums | keys[]' "$dir/manifest.json")
  while IFS= read -r f; do
    rel=${f#"$dir"/}
    case "$rel" in manifest.json|manifest.sig) continue ;; esac
    printf '%s\n' "$listed" | grep -qxF "$rel" || return 1
  done < <(find "$dir" -type f)
  return 0
}
cmd_bk_key(){ bk_key_ensure; echo "Chave dos backups (guarda-a fora do servidor; é precisa para repor backups remotos noutro servidor):"; cat "$BK_KEY"; return 0; }
cmd_bk_key_set(){ local k="${1:-}" re='^[0-9a-f]{64}$'; [[ "$k" =~ $re ]] || die "Chave inválida (64 caracteres hexadecimais)."; ( umask 077; echo "$k" > "$BK_KEY" ); echo "Chave dos backups definida."; return 0; }
bk_remote_root(){ bk_remotes | jq -r --arg n "$1" '.[] | select(.name == $n) | .root'; }
bk_host(){ hostname -s 2>/dev/null || echo servidor; }
bk_gz(){ if command -v pigz >/dev/null 2>&1; then echo "pigz -6"; else echo "gzip -6"; fi; }
bk_status(){ # running: texto do passo ou vazio
  local f=$DATA/stats/backup-run.json
  if [ -n "${1:-}" ]; then jq -n --arg s "$1" --arg t "$EPOCHSECONDS" '{step:$s, since:($t|tonumber)}' > "$f.tmp" && chown root:"$PANEL_SYSUSER" "$f.tmp" && chmod 640 "$f.tmp" && mv -f "$f.tmp" "$f"
  else rm -f "$f"; fi
}
bk_write_state(){
  local sets total
  sets=$(find "$BK_DIR" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | while read -r m; do jq -c '.' "$m" 2>/dev/null; done | jq -cs 'sort_by(-.created)')
  total=$(du -sb "$BK_DIR" 2>/dev/null | awk '{print $1}')
  jq -n --argjson sets "${sets:-[]}" --argjson rem "$(bk_remotes)" --arg total "${total:-0}" \
     --arg en "$(bk_conf ENABLED 1)" --arg time "$(bk_conf TIME 03:00)" --arg kd "$(bk_conf KEEP_DAILY 7)" --arg kw "$(bk_conf KEEP_WEEKLY 4)" \
     --arg km "$(bk_conf KEEP_MONTHLY 3)" --arg r "$(bk_conf REMOTE '')" --argjson last "$(cat "$DATA/stats/backup-last.json" 2>/dev/null || echo null)" \
     --arg ec "$(bk_conf ENCRYPT 1)" \
     '{conf:{enabled:($en=="1"), time:$time, keep_daily:($kd|tonumber), keep_weekly:($kw|tonumber), keep_monthly:($km|tonumber), remote:$r, encrypt:($ec=="1")},
       remotes:$rem, sets:$sets, total:($total|tonumber), last:$last}' > "$BK_STATE.tmp" \
    && chown root:"$PANEL_SYSUSER" "$BK_STATE.tmp" && chmod 640 "$BK_STATE.tmp" && mv -f "$BK_STATE.tmp" "$BK_STATE"
  return 0
}
bk_cron_apply(){
  local t h m
  t=$(bk_conf TIME 03:00); h=$((10#${t%%:*})); m=$((10#${t##*:}))
  if [ "$(bk_conf ENABLED 1)" = 1 ]; then
    printf '# IDDigital Hosting — backups automáticos (gerado pelo painel)\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nMAILTO=""\n%d %d * * * root /usr/local/sbin/mpanel backup-run --auto >/dev/null 2>&1\n' "$m" "$h" > /etc/cron.d/minipainel-backup
    chmod 644 /etc/cron.d/minipainel-backup
  else
    rm -f /etc/cron.d/minipainel-backup
  fi
  touch /etc/cron.d 2>/dev/null
  return 0
}

# Cria um conjunto: $1 = site | _bd | _sistema ; $2 = auto|manual|pre-restauro ; imprime o id
bk_make(){
  local s=$1 type=$2 id dir gz d u files=false dbs="[]" size rc
  id=$(date '+%Y%m%d-%H%M%S'); dir="$BK_DIR/$s/$id"
  [ -e "$dir" ] && { sleep 1; id=$(date '+%Y%m%d-%H%M%S'); dir="$BK_DIR/$s/$id"; }
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$BK_DIR" "$BK_DIR/$s"
  install -d -m 700 "$dir.part"
  gz=$(bk_gz)
  if [ "$s" = _sistema ]; then
    bk_status "Configuração do sistema"
    tar -C / -czf "$dir.part/sistema.tar.gz" --ignore-failed-read etc/minipainel etc/nginx/minipainel etc/cron.d var/lib/minipainel/auth.json 2>/dev/null
    files=true
  elif [ "$s" != _bd ]; then
    bk_status "Ficheiros de $s"
    tar -C "$WWW_ROOT" --exclude="$s/tmp" -I "$gz" -cpf "$dir.part/ficheiros.tar.gz" "$s"; rc=$?
    [ "$rc" -le 1 ] || { rm -rf "$dir.part"; echo "ERRO: falhou a cópia dos ficheiros de $s (tar $rc)." >&2; return 1; }
    install -d -m 700 "$dir.part/config"
    cp -p "$SITES_DIR/$s.conf" "$dir.part/config/site.conf" 2>/dev/null
    cp -p "$CRON_DIR/$s.json" "$dir.part/config/cron.json" 2>/dev/null
    files=true
  fi
  local list=""
  if [ "$s" = _bd ]; then
    list=$(db_sizes | awk '{print $1}' | while read -r d; do [ -n "$d" ] && [ "$d" != "$DB_ADMIN" ] && [ -z "$(dbmap_load | jq -r --arg d "$d" '.[$d] // empty')" ] && echo "$d"; done)
  elif [ "$s" != _sistema ]; then
    list=$(dbs_of_site "$s")
  fi
  for d in $list; do
    db_exists "$d" || continue
    bk_status "Base de dados $d"
    mysqldump -uroot --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 "$d" 2>"$dir.part/.err" | $gz > "$dir.part/bd-$d.sql.gz"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "ERRO: falhou a cópia da base de dados $d: $(head -c 300 "$dir.part/.err")" >&2; rm -rf "$dir.part"; return 1; fi
    u=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$d' AND Host='localhost'" 2>/dev/null)
    if [ "$u" = 1 ]; then
      { db_q "SHOW CREATE USER '$d'@'localhost'" 2>/dev/null | sed 's/$/;/'; db_q "SHOW GRANTS FOR '$d'@'localhost'" 2>/dev/null | sed 's/$/;/'; } > "$dir.part/bd-$d.user.sql"
    fi
    dbs=$(jq -c --arg d "$d" '. + [$d]' <<<"$dbs")
  done
  rm -f "$dir.part/.err"
  size=$(du -sb "$dir.part" | awk '{print $1}')
  local sums
  sums=$(cd "$dir.part" && find . -type f -printf '%P\n' | sort | while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"; done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -cs 'add // {}')
  jq -n --arg s "$s" --arg id "$id" --arg t "$type" --arg c "$EPOCHSECONDS" --arg sz "$size" --argjson f "$files" --argjson dbs "$dbs" \
        --arg v "$MP_VERSION" --arg php "$( [ -f "$SITES_DIR/$s.conf" ] && site_get "$s" PHP)" \
        --argjson sums "$sums" \
        '{site:$s, id:$id, type:$t, created:($c|tonumber), size:($sz|tonumber), files:$f, dbs:$dbs, version:$v, php:$php, remote:"", sums:$sums}' > "$dir.part/manifest.json"
  bk_sign "$dir.part"
  chown -R root:"$PANEL_SYSUSER" "$dir.part"; find "$dir.part" -type f -exec chmod 640 {} +; chmod 750 "$dir.part"; [ -d "$dir.part/config" ] && chmod 750 "$dir.part/config"
  mv "$dir.part" "$dir"
  echo "$id"
}
bk_upload(){ # site id remote
  local s=$1 id=$2 r=$3 root
  bk_remote_ok "$r" || return 1
  root=$(bk_remote_root "$r"); [ -n "$root" ] || { echo "Destino remoto '$r' não existe." >&2; return 1; }
  local src="$BK_DIR/$s/$id" stage="" enc=false rc
  if [ "$(bk_conf ENCRYPT 1)" = 1 ]; then
    bk_status "Cifra de $s"
    stage=$(mktemp -d /var/tmp/mp-bkup.XXXXXX)
    bk_encrypt_dir "$src" "$stage" || { rm -rf "$stage"; echo "Falhou a cifra do backup." >&2; return 1; }
    src=$stage; enc=true
  fi
  bk_status "Envio de $s para $r"
  bk_rc copy "$src" "$r:$root/$(bk_host)/$s/$id" --transfers 2 2>&1 | tail -n 3 >&2
  rc=${PIPESTATUS[0]}
  [ -n "$stage" ] && rm -rf "$stage"
  [ "$rc" -eq 0 ] || return 1
  jq --arg r "$r" --argjson e "$enc" '.remote = $r | .remote_enc = $e' "$BK_DIR/$s/$id/manifest.json" > "$BK_DIR/$s/$id/manifest.tmp" && mv -f "$BK_DIR/$s/$id/manifest.tmp" "$BK_DIR/$s/$id/manifest.json"
  chown root:"$PANEL_SYSUSER" "$BK_DIR/$s/$id/manifest.json"; chmod 640 "$BK_DIR/$s/$id/manifest.json"
  [ -f "$BK_DIR/$s/$id/manifest.sig" ] && bk_sign "$BK_DIR/$s/$id"
}
# Retenção avô-pai-filho: lê ids (AAAAMMDD-HHMMSS) no stdin e imprime os que devem ser apagados
bk_gfs(){
  local kd kw km
  kd=$(bk_conf KEEP_DAILY 7); kw=$(bk_conf KEEP_WEEKLY 4); km=$(bk_conf KEEP_MONTHLY 3)
  sort -r | while read -r id; do
    [ -n "$id" ] || continue
    echo "$id $(date -d "${id:0:8}" '+%G%V' 2>/dev/null || echo 0)"
  done | awk -v kd="$kd" -v kw="$kw" -v km="$km" '
    { id = $1; day = substr(id, 1, 8); wk = $2; mo = substr(id, 1, 6); keep = 0
      if (!(day in D) && nd < kd) { D[day] = 1; nd++; keep = 1 }
      if (!(wk in W) && nw < kw) { W[wk] = 1; nw++; keep = 1 }
      if (!(mo in M) && nm < km) { M[mo] = 1; nm++; keep = 1 }
      if (!keep) print id }'
}
bk_prune_local(){ # site
  local s=$1 id
  [ -d "$BK_DIR/$s" ] || return 0
  for id in $(for m in "$BK_DIR/$s"/*/manifest.json; do [ -f "$m" ] && jq -r 'select(.type == "auto") | .id' "$m"; done | bk_gfs); do
    rm -rf "${BK_DIR:?}/$s/$id"
  done
  find "$BK_DIR/$s" -maxdepth 1 -name '*.part' -mmin +720 -exec rm -rf {} + 2>/dev/null
}
bk_prune_remote(){ # site remote
  local s=$1 r=$2 root id
  bk_remote_ok "$r" 2>/dev/null || return 0
  root=$(bk_remote_root "$r"); [ -n "$root" ] || return 0
  for id in $(bk_rc lsf --dirs-only "$r:$root/$(bk_host)/$s" 2>/dev/null | tr -d '/' | grep -E '^[0-9]{8}-[0-9]{6}$' | bk_gfs); do
    bk_rc purge "$r:$root/$(bk_host)/$s/$id" >/dev/null 2>&1
  done
}

cmd_backup_run(){
  local auto=0 only="" remote="" s id ok=0 fail=0 msgs="" t0 used r
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto=1; shift ;;
      --site) only="${2:-}"; shift 2 || shift ;;
      --remote) remote="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  exec 8>"$BK_LOCK"; flock -n 8 || die "Já está a decorrer um backup."
  used=$(df -P "$(dirname "$BK_DIR")" | awk 'NR==2{gsub("%","",$5); print $5}')
  if [ "${used:-0}" -ge 90 ]; then
    jq -n --arg t "$EPOCHSECONDS" '{ts:($t|tonumber), ok:false, msg:"Backup cancelado: o disco está acima de 90% de ocupação.", duration:0}' > "$DATA/stats/backup-last.json"
    bk_write_state; die "Backup cancelado: o disco está acima de 90% de ocupação."
  fi
  [ "$auto" = 1 ] && remote=$(bk_conf REMOTE '')
  t0=$EPOCHSECONDS
  local targets
  if [ -n "$only" ]; then
    case "$only" in _bd|_sistema) ;; *) valid_site "$only" && site_exists "$only" || die "O site '$only' não existe." ;; esac
    targets=$only
  else
    targets="$(site_names) _bd _sistema"
  fi
  local errf; errf=$(mktemp)
  for s in $targets; do
    : > "$errf"
    if id=$(bk_make "$s" "$([ "$auto" = 1 ] && echo auto || echo manual)" 2>"$errf"); then
      ok=$((ok + 1))
      if [ -n "$remote" ]; then
        bk_upload "$s" "$id" "$remote" 2>>"$errf" || { fail=$((fail + 1)); msgs+="$s: falhou o envio para $remote ($(tail -n 1 "$errf" | head -c 200)). "; }
      fi
      if [ "$auto" = 1 ]; then bk_prune_local "$s"; [ -n "$remote" ] && bk_prune_remote "$s" "$remote"; fi
    else
      fail=$((fail + 1)); msgs+="$s: $(tr '\n' ' ' < "$errf" | head -c 300) "
    fi
  done
  rm -f "$errf"
  bk_status ""
  jq -n --arg t "$EPOCHSECONDS" --arg d "$(( EPOCHSECONDS - t0 ))" --argjson ok "$([ "$fail" = 0 ] && echo true || echo false)" \
        --arg m "$( [ "$fail" = 0 ] && echo "$ok conjunto(s) guardado(s)${remote:+ e enviados para $remote}." || echo "$ok guardado(s), $fail com erro. $msgs")" \
        '{ts:($t|tonumber), ok:$ok, msg:$m, duration:($d|tonumber)}' > "$DATA/stats/backup-last.json"
  chown root:"$PANEL_SYSUSER" "$DATA/stats/backup-last.json"; chmod 640 "$DATA/stats/backup-last.json"
  bk_write_state
  if [ "$fail" = 0 ]; then echo "Backup concluído: $ok conjunto(s) em $(( EPOCHSECONDS - t0 ))s${remote:+, enviados para $remote}."; return 0; fi
  echo "Backup com erros: $msgs" >&2; return 1
}
cmd_backup_start(){ # lança em segundo plano (usado pelo painel)
  [ -n "$(flock -n "$BK_LOCK" true 2>&1 || echo busy)" ] && die "Já está a decorrer um backup."
  setsid /usr/local/sbin/mpanel backup-run "$@" >/dev/null 2>&1 < /dev/null 9>&- &
  echo "Backup iniciado em segundo plano. O progresso aparece na página Backups."
  return 0
}
bk_need_set(){ # site id -> garante cópia local (vai buscar ao destino remoto se for preciso)
  local s=$1 id=$2 re='^[0-9]{8}-[0-9]{6}$' r root
  [[ "$id" =~ $re ]] || die "Identificador de backup inválido: $id"
  case "$s" in _bd|_sistema) ;; *) valid_site "$s" || die "Site inválido: $s" ;; esac
  BK_FETCHED=0
  [ -f "$BK_DIR/$s/$id/manifest.json" ] && return 0
  r=$(bk_conf REMOTE ''); [ -n "$r" ] || die "O backup $id de $s não existe localmente."
  bk_remote_ok "$r" || die "Destino remoto recusado por razões de segurança."
  root=$(bk_remote_root "$r")
  BK_FETCHED=1
  bk_rc copy "$r:$root/$(bk_host)/$s/$id" "$BK_DIR/$s/$id" >/dev/null 2>&1 && [ -f "$BK_DIR/$s/$id/manifest.json" ] || die "O backup $id de $s não existe localmente nem em $r."
  bk_decrypt_dir "$BK_DIR/$s/$id" || { rm -rf "${BK_DIR:?}/$s/$id"; die "Não foi possível decifrar o backup: a chave dos backups deste servidor não é a mesma que o cifrou (usa 'mpanel bk-key-set')."; }
  chown -R root:"$PANEL_SYSUSER" "$BK_DIR/$s/$id"
}
cmd_bk_restore(){
  local s="${1:-}" id="${2:-}" what=all dir m d f uexists tmp pre="" created=0 port php noverify=0 vr newpw="" BK_FETCHED=0
  [ $# -ge 2 ] && shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --what) what="${2:-all}"; shift 2 || shift ;;
      --no-verify) noverify=1; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  case "$what" in all|files|db) ;; *) die "Use --what all|files|db" ;; esac
  [ "$s" = _sistema ] && die "A configuração do sistema não é reposta pelo painel; extrai sistema.tar.gz manualmente se precisares."
  bk_need_set "$s" "$id"
  dir="$BK_DIR/$s/$id"; m="$dir/manifest.json"
  bk_verify "$dir"; vr=$?
  if [ "$vr" = 1 ] && [ "$noverify" = 0 ]; then
    [ "$BK_FETCHED" = 1 ] && rm -rf "${dir:?}"
    die "Restauro recusado: a assinatura do backup não é válida ou os ficheiros foram alterados. Se vem de outro servidor, define primeiro a chave com 'mpanel bk-key-set'."
  fi
  if [ "$vr" = 2 ] && [ "$BK_FETCHED" = 1 ] && [ "$noverify" = 0 ]; then
    rm -rf "${dir:?}"; die "Restauro recusado: o backup remoto não tem assinatura (é anterior à v1.9.1). Para o repor mesmo assim, usa no servidor: mpanel bk-restore $s $id --no-verify"
  fi
  if [ "$s" != _bd ]; then
    if ! site_exists "$s"; then
      [ "$what" = db ] && die "O site $s não existe; repõe tudo (--what all) para o recriar."
      port=$(grep -m1 '^PORT=' "$dir/config/site.conf" 2>/dev/null | cut -d= -f2); php=$(jq -r '.php' "$m")
      php_is_installed "$php" || php=$DEFAULT_PHP
      if port_owner "$port" >/dev/null || port_listening "$port"; then port=""; fi
      ( cmd_site_add "$s" ${port:+--port "$port"} --php "$php" ) >/dev/null || die "Não foi possível recriar o site $s."
      created=1
      grep -E '^(MEM|UPLOAD|EXEC|INPUT_TIME|INPUT_VARS|DISPLAY_ERRORS)=' "$dir/config/site.conf" 2>/dev/null | while IFS='=' read -r k v; do site_set "$s" "$k" "$v"; done
      write_pool "$s" "$(site_get "$s" PHP)"; write_nginx "$s" "$(site_get "$s" PORT)" "$(site_get "$s" PHP)" "$(ngx_file "$s")"
      apply_php "$(site_get "$s" PHP)" >/dev/null 2>&1; apply_nginx >/dev/null 2>&1
    else
      pre=$(bk_make "$s" pre-restauro 2>/dev/null) || die "Não foi possível criar a cópia de segurança antes de repor; nada foi alterado."
    fi
  else
    pre=$(bk_make _bd pre-restauro 2>/dev/null) || die "Não foi possível criar a cópia de segurança antes de repor; nada foi alterado."
  fi
  if [ "$what" != db ] && [ "$s" != _bd ]; then
    tmp="$WWW_ROOT/.restauro-$s-$$"; install -d -m 700 "$tmp"
    tar -C "$tmp" --no-same-owner -xzpf "$dir/ficheiros.tar.gz" "$s/public_html" || { rm -rf "$tmp"; die "Falhou a extração dos ficheiros."; }
    find "$tmp" -type f -perm /6000 -exec chmod ug-s {} + 2>/dev/null
    [ -d "$tmp/$s/public_html" ] || { rm -rf "$tmp"; die "O backup não contém public_html."; }
    mv "$WWW_ROOT/$s/public_html" "$WWW_ROOT/$s/.public_html.antes-$id" && mv "$tmp/$s/public_html" "$WWW_ROOT/$s/public_html" || {
      [ -d "$WWW_ROOT/$s/.public_html.antes-$id" ] && mv "$WWW_ROOT/$s/.public_html.antes-$id" "$WWW_ROOT/$s/public_html"; rm -rf "$tmp"; die "Falhou a substituição dos ficheiros; nada foi alterado."; }
    chown -R "mp_$s:mp_$s" "$WWW_ROOT/$s/public_html"; chmod 2750 "$WWW_ROOT/$s/public_html"
    se_restore "$WWW_ROOT/$s/public_html"
    rm -rf "$tmp" "$WWW_ROOT/$s/.public_html.antes-$id"
    if [ "$what" = all ] && [ -f "$dir/config/cron.json" ]; then cp "$dir/config/cron.json" "$CRON_DIR/$s.json"; chmod 600 "$CRON_DIR/$s.json"; cron_write_site "$s"; fi
  fi
  if [ "$what" != files ]; then
    for f in "$dir"/bd-*.sql.gz; do
      [ -f "$f" ] || continue
      d=${f##*/bd-}; d=${d%.sql.gz}; valid_db "$d" || continue
      db_exec "DROP DATABASE IF EXISTS \`$d\`; CREATE DATABASE \`$d\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || die "Falhou a recriação da base de dados $d."
      gzip -dc "$f" | mysql -uroot "$d" || die "Falhou a importação de $d${pre:+ (o estado anterior está no backup $pre)}."
      uexists=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$d' AND Host='localhost'" 2>/dev/null)
      if [ "$uexists" = 0 ]; then
        # recria só o utilizador da própria base de dados, com o hash da password original (nunca executa o SQL do backup)
        local hsh ng="${d//_/\\_}"
        hsh=$( [ -f "$dir/bd-$d.user.sql" ] && grep -m1 -oE "IDENTIFIED BY PASSWORD '\*[0-9A-F]{40}'" "$dir/bd-$d.user.sql" | grep -oE '\*[0-9A-F]{40}')
        if [ -n "$hsh" ]; then
          db_exec "CREATE USER '$d'@'localhost' IDENTIFIED BY PASSWORD '$hsh'; GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$d'@'localhost'; FLUSH PRIVILEGES;" || warn "Não foi possível recriar o utilizador $d."
        else
          local pw; pw=$(gen_pass 20)
          db_exec "CREATE USER '$d'@'localhost' IDENTIFIED BY '$pw'; GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$d'@'localhost'; FLUSH PRIVILEGES;" && newpw+=" $d: $pw"
        fi
      fi
      [ "$s" != _bd ] && dbmap_set "$d" "$s"
    done
  fi
  bk_write_state
  echo "Backup $id de $s reposto ($what).${pre:+ O estado anterior ficou guardado no backup $pre.}$([ "$created" = 1 ] && echo " O site foi recriado.")"
  [ "$vr" = 2 ] && echo "Aviso: backup antigo, sem assinatura (anterior à v1.9.1)."
  [ -n "$newpw" ] && echo "Utilizadores recriados com password nova (atualiza a configuração do site):$newpw"
  return 0
}
cmd_bk_delete(){
  local s="${1:-}" id="${2:-}" re='^[0-9]{8}-[0-9]{6}$'
  [[ "$id" =~ $re ]] || die "Identificador inválido."
  case "$s" in _bd|_sistema) ;; *) valid_site "$s" || die "Site inválido." ;; esac
  [ -d "$BK_DIR/$s/$id" ] || die "O backup $id de $s não existe."
  rm -rf "${BK_DIR:?}/$s/$id"; bk_write_state
  echo "Backup $id de $s apagado (cópia local)."
  return 0
}
cmd_bk_conf(){
  local en tm kd kw km r ec re_t='^([01][0-9]|2[0-3]):[0-5][0-9]$' re_n='^[0-9]{1,3}$'
  en=$(bk_conf ENABLED 1); tm=$(bk_conf TIME 03:00); kd=$(bk_conf KEEP_DAILY 7); kw=$(bk_conf KEEP_WEEKLY 4); km=$(bk_conf KEEP_MONTHLY 3); r=$(bk_conf REMOTE ''); ec=$(bk_conf ENCRYPT 1)
  while [ $# -gt 0 ]; do
    case "$1" in
      --on) en=1; shift ;; --off) en=0; shift ;;
      --time) tm="${2:-}"; shift 2 || shift ;;
      --daily) kd="${2:-}"; shift 2 || shift ;;
      --weekly) kw="${2:-}"; shift 2 || shift ;;
      --monthly) km="${2:-}"; shift 2 || shift ;;
      --remote) r="${2:-}"; shift 2 || shift ;;
      --encrypt) case "${2:-}" in on|1) ec=1 ;; off|0) ec=0 ;; *) die "--encrypt on|off" ;; esac; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$tm" =~ $re_t ]] || die "Hora inválida: $tm (HH:MM)."
  for v in "$kd" "$kw" "$km"; do [[ "$v" =~ $re_n ]] || die "Retenção inválida: $v"; done
  [ "$kd" -ge 1 ] || die "Guarda pelo menos 1 backup diário."
  [ "$r" = none ] && r=""
  [ -z "$r" ] || [ -n "$(bk_remote_root "$r")" ] || die "O destino remoto '$r' não existe."
  printf 'ENABLED=%s\nTIME=%s\nKEEP_DAILY=%s\nKEEP_WEEKLY=%s\nKEEP_MONTHLY=%s\nREMOTE=%s\nENCRYPT=%s\n' "$en" "$tm" "$kd" "$kw" "$km" "$r" "$ec" > "$BK_CONF"; chmod 600 "$BK_CONF"
  bk_cron_apply; bk_write_state
  if [ "$en" = 1 ]; then echo "Backups automáticos todos os dias às $tm (guarda $kd diários, $kw semanais e $km mensais)${r:+, com cópia em $r}."
  else echo "Backups automáticos desativados."; fi
  return 0
}
cmd_bk_remote_add(){ # nome tipo opções...
  local n="${1:-}" t="${2:-}" root="" host="" port=22 user="" pass="" key="" prov=Other ep="" reg="" ak="" sk="" bucket="" raw="" re='^[a-z][a-z0-9-]{1,23}$'
  [ $# -ge 2 ] && shift 2
  [[ "$n" =~ $re ]] || die "Nome inválido (minúsculas, números e '-', 2 a 24 caracteres)."
  command -v rclone >/dev/null 2>&1 || die "O rclone não está instalado."
  [ -z "$(bk_remote_root "$n")" ] || die "Já existe um destino chamado $n."
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host="${2:-}"; shift 2 || shift ;; --port) port="${2:-}"; shift 2 || shift ;;
      --user) user="${2:-}"; shift 2 || shift ;; --pass) pass="${2:-}"; shift 2 || shift ;;
      --key) key="${2:-}"; shift 2 || shift ;; --path) root="${2:-}"; shift 2 || shift ;;
      --provider) prov="${2:-}"; shift 2 || shift ;; --endpoint) ep="${2:-}"; shift 2 || shift ;;
      --region) reg="${2:-}"; shift 2 || shift ;; --access) ak="${2:-}"; shift 2 || shift ;;
      --secret) sk="${2:-}"; shift 2 || shift ;; --bucket) bucket="${2:-}"; shift 2 || shift ;;
      --config) raw="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  touch "$BK_RCLONE"; chmod 600 "$BK_RCLONE"
  case "$t" in
    sftp)
      [ -n "$host" ] && [ -n "$user" ] || die "Indica o servidor e o utilizador."
      [ -n "$pass" ] || [ -n "$key" ] || die "Indica a password ou a chave privada."
      [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "Porta inválida."
      [[ "$host$user" != *[$'\n\r ']* ]] || die "Servidor ou utilizador inválido."
      {
        printf '\n[%s]\ntype = sftp\nhost = %s\nuser = %s\nport = %s\nshell_type = unix\n' "$n" "$host" "$user" "$port"
        [ -n "$pass" ] && printf 'pass = %s\n' "$(printf '%s' "$pass" | rclone obscure -)"
        if [ -n "$key" ]; then install -d -m 700 /etc/minipainel/rclone-keys; printf '%s\n' "$key" | sed 's/\\n/\n/g' > "/etc/minipainel/rclone-keys/$n.key"; chmod 600 "/etc/minipainel/rclone-keys/$n.key"; printf 'key_file = /etc/minipainel/rclone-keys/%s.key\n' "$n"; fi
      } >> "$BK_RCLONE"
      root=${root:-backups} ;;
    s3)
      [ -n "$ak" ] && [ -n "$sk" ] && [ -n "$bucket" ] || die "Indica a chave de acesso, a chave secreta e o bucket."
      [[ "$prov$ak$sk$ep$reg" != *[$'\n\r']* ]] || die "Valores inválidos."
      {
        printf '\n[%s]\ntype = s3\nprovider = %s\naccess_key_id = %s\nsecret_access_key = %s\nno_check_bucket = true\n' "$n" "$prov" "$ak" "$sk"
        [ -n "$ep" ] && printf 'endpoint = %s\n' "$ep"
        [ -n "$reg" ] && printf 'region = %s\n' "$reg"
      } >> "$BK_RCLONE"
      root="$bucket${root:+/$root}" ;;
    rclone)
      [ -n "$raw" ] || die "Cola a secção de configuração do rclone."
      raw=$(printf '%s' "$raw" | sed 's/\\n/\n/g' | sed 's/[[:space:]]*$//')
      [ "$(printf '%s\n' "$raw" | grep -c '^\[')" = 1 ] && [ "$(printf '%s\n' "$raw" | sed -n '1{/^\[/p}')" = "[$n]" ] || die "A configuração tem de ter uma só secção, a começar por [$n]."
      local why; why=$(bk_cfg_check "$(printf '%s\n' "$raw" | sed '1d')" raw) || die "Configuração recusada: $why."
      grep -q "^\[$n\]$" "$BK_RCLONE" && die "Já existe [$n] na configuração do rclone."
      printf '\n%s\n' "$raw" >> "$BK_RCLONE"
      root=${root:-iddigital-hosting} ;;
    *) die "Tipo inválido: usa sftp, s3 ou rclone." ;;
  esac
  jq --arg n "$n" --arg t "$t" --arg r "$root" '. + [{name:$n, type:$t, root:$r}]' <<<"$(bk_remotes)" > "$BK_REMOTES.tmp" && chmod 600 "$BK_REMOTES.tmp" && mv -f "$BK_REMOTES.tmp" "$BK_REMOTES"
  bk_write_state
  echo "Destino $n ($t) adicionado. Usa 'Testar' para confirmar o acesso."
  return 0
}
cmd_bk_remote_test(){
  local n="${1:-}" root f
  root=$(bk_remote_root "$n"); [ -n "$root" ] || die "O destino $n não existe."
  bk_remote_ok "$n" || die "Destino recusado por razões de segurança."
  local errf; errf=$(mktemp)
  f="teste-$(bk_host)-$EPOCHSECONDS.txt"
  echo "IDDigital Hosting: teste de escrita" | bk_rc rcat "$n:$root/$f" 2>"$errf" || { head -c 400 "$errf" >&2; rm -f "$errf"; die "Não foi possível escrever em $n:$root."; }
  bk_rc deletefile "$n:$root/$f" >/dev/null 2>&1; rm -f "$errf"
  echo "Destino $n acessível: escrita e remoção em $root funcionaram."
  return 0
}
cmd_bk_remote_del(){
  local n="${1:-}"
  [ -n "$(bk_remote_root "$n")" ] || die "O destino $n não existe."
  bk_rc config delete "$n" >/dev/null 2>&1; rm -f "/etc/minipainel/rclone-keys/$n.key"
  jq --arg n "$n" 'map(select(.name != $n))' <<<"$(bk_remotes)" > "$BK_REMOTES.tmp" && chmod 600 "$BK_REMOTES.tmp" && mv -f "$BK_REMOTES.tmp" "$BK_REMOTES"
  [ "$(bk_conf REMOTE '')" = "$n" ] && sed -i 's/^REMOTE=.*/REMOTE=/' "$BK_CONF"
  bk_write_state
  echo "Destino $n removido (os backups já enviados para lá não foram apagados)."
  return 0
}
cmd_bk_init(){
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$BK_DIR"; bk_key_ensure; bk_cron_apply; bk_write_state
  local r; for r in $(bk_remotes | jq -r '.[].name'); do bk_remote_ok "$r" || true; done
  echo "Backups configurados."; return 0
}
cmd_bk_list(){
  local s="${1:-}"
  printf '%-12s %-16s %-13s %-10s %-8s %s\n' SITE ID TIPO TAMANHO REMOTO "BASES DE DADOS"
  find "$BK_DIR" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | while read -r m; do jq -r '[.site, .id, .type, (.size|tostring), (if .remote == "" then "-" else .remote end), (.dbs | join(","))] | @tsv' "$m"; done |
    sort -k2,2r | while IFS=$'\t' read -r a b c d e f; do [ -z "$s" ] || [ "$s" = "$a" ] || continue; printf '%-12s %-16s %-13s %-10s %-8s %s\n' "$a" "$b" "$c" "$(numfmt --to=iec "$d" 2>/dev/null || echo "$d")" "$e" "$f"; done
  return 0
}

# ---------- modo do servidor, domínios e SSL ----------
SRV_CONF=/etc/minipainel/server.conf     # MODE=lan|internet, EMAIL, PANEL_DOMAIN, PANEL_SSL
ACME_ROOT=/var/www/minipainel-acme
NGX_INC=/etc/nginx/minipainel/inc
NGX_CONFD=/etc/nginx/minipainel/conf.d
SELF_SSL=/etc/minipainel/ssl/sites
srv_get(){ local v; v=$(grep -m1 "^$1=" "$SRV_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
srv_set(){
  touch "$SRV_CONF"; chmod 600 "$SRV_CONF"
  if grep -q "^$1=" "$SRV_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$SRV_CONF"; else echo "$1=$2" >> "$SRV_CONF"; fi
}
valid_domain(){ local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'; [ ${#1} -le 253 ] && [[ "$1" =~ $re ]]; }
domain_owner(){ # imprime o site (ou "painel") que usa o domínio
  local d=$1 n
  [ "$(srv_get PANEL_DOMAIN '')" = "$d" ] && { echo painel; return 0; }
  for n in $(site_names); do [[ " $(site_get "$n" DOMAINS) " == *" $d "* ]] && { echo "$n"; return 0; }; done
  return 1
}
cert_files(){ # nome -> "crt key" se existir certificado
  local n=$1
  if [ -s "/etc/letsencrypt/live/$n/fullchain.pem" ]; then echo "/etc/letsencrypt/live/$n/fullchain.pem /etc/letsencrypt/live/$n/privkey.pem"; return 0; fi
  if [ -s "$SELF_SSL/$n.crt" ]; then echo "$SELF_SSL/$n.crt $SELF_SSL/$n.key"; return 0; fi
  return 1
}
cert_expiry(){ local c; c=$(cert_files "$1") || return 0; openssl x509 -enddate -noout -in "${c%% *}" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null; }
self_issue(){ # nome domínios...
  local n=$1 san="" d; shift
  for d in "$@"; do san+="${san:+,}DNS:$d"; done
  install -d -m 700 "$SELF_SSL"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 -keyout "$SELF_SSL/$n.key" -out "$SELF_SSL/$n.crt" \
    -subj "/CN=$1" -addext "subjectAltName=$san" >/dev/null 2>&1 || return 1
  chmod 600 "$SELF_SSL/$n.key"
}
le_issue(){ # nome domínios... (valida primeiro no ambiente de testes do Let's Encrypt)
  local n=$1 d out em; shift
  command -v certbot >/dev/null 2>&1 || { echo "O certbot não está instalado." >&2; return 1; }
  local args=(certonly --webroot -w "$ACME_ROOT" --cert-name "$n" --non-interactive --agree-tos --keep-until-expiring --expand --deploy-hook "systemctl reload nginx")
  em=$(srv_get EMAIL ''); if [ -n "$em" ]; then args+=(-m "$em"); else args+=(--register-unsafely-without-email); fi
  [ -n "${MP_ACME_SERVER:-}" ] && args+=(--server "$MP_ACME_SERVER")
  for d in "$@"; do args+=(-d "$d"); done
  install -d -m 755 "$ACME_ROOT"
  if [ -z "${MP_ACME_SERVER:-}" ]; then
    out=$(certbot "${args[@]}" --dry-run 2>&1) || { echo "O Let's Encrypt não conseguiu validar os domínios:"; echo "$out" | grep -E 'Domain:|Type:|Detail:|Hint:|Error' | head -n 8; return 1; } >&2
  fi
  out=$(certbot "${args[@]}" 2>&1) || { echo "Falhou o pedido do certificado:"; echo "$out" | grep -E 'Domain:|Type:|Detail:|Hint:|Error|too many' | head -n 8; return 1; } >&2
  return 0
}
le_delete(){ command -v certbot >/dev/null 2>&1 && certbot delete --cert-name "$1" --non-interactive >/dev/null 2>&1; rm -f "$SELF_SSL/$1.crt" "$SELF_SSL/$1.key"; return 0; }
acme_loc(){ printf '    location ^~ /.well-known/acme-challenge/ { root %s; default_type text/plain; }\n' "$ACME_ROOT"; }
canon_redirect(){ # domínios www -> linha de redirecionamento ou vazio
  local doms=$1 mode=$2 first canon d
  [ "$mode" = keep ] || [ -z "$doms" ] && return 0
  first=${doms%% *}; first=${first#www.}
  if [ "$mode" = www ]; then canon="www.$first"; else canon="$first"; fi
  for d in $doms; do [ "$d" = "$canon" ] && { printf '    if ($host != "%s") { return 301 $scheme://%s$request_uri; }\n' "$canon" "$canon"; return 0; }; done
  return 0
}
# Servidores HTTP/HTTPS de um conjunto de domínios: nome include domínios ssl(none|le|self) https www
domain_servers(){
  local n=$1 inc=$2 doms=$3 ssl=$4 https=$5 www=$6 l6="" l6s="" crt key cf
  [ -n "$doms" ] || return 0
  [ "${IPV6:-0}" = 1 ] && { l6="    listen [::]:80;"; l6s="    listen [::]:443 ssl http2;"; }
  cf=""; [ "$ssl" != none ] && cf=$(cert_files "$n")
  printf '\n# domínios: %s\nserver {\n    listen 80;\n%s\n    server_name %s;\n' "$doms" "$l6" "$doms"
  acme_loc
  if [ -n "$cf" ] && [ "$https" = 1 ]; then
    printf '    location / { return 301 https://$host$request_uri; }\n}\n'
  else
    canon_redirect "$doms" "$www"
    printf '    include %s;\n}\n' "$inc"
  fi
  if [ -n "$cf" ]; then
    crt=${cf%% *}; key=${cf##* }
    printf '\nserver {\n    listen 443 ssl http2;\n%s\n    server_name %s;\n    ssl_certificate     %s;\n    ssl_certificate_key %s;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:MPSSL:1m;\n' "$l6s" "$doms" "$crt" "$key"
    canon_redirect "$doms" "$www"
    printf '    include %s;\n}\n' "$inc"
  fi
}
# Servidor por omissão nas portas 80/443 quando há domínios (pedidos com nomes desconhecidos são recusados)
ngx_default_sync(){
  local any=0 p80=0 n l6="" l6s=""
  install -d -m 755 "$NGX_CONFD" "$ACME_ROOT"
  [ -n "$(srv_get PANEL_DOMAIN '')" ] && any=1
  for n in $(site_names); do
    [ -n "$(site_get "$n" DOMAINS)" ] && any=1
    [ "$(site_get "$n" PORT)" = 80 ] && [ "$(site_get "$n" ENABLED)" = 1 ] && p80=1
  done
  [ "${IPV6:-0}" = 1 ] && { l6="    listen [::]:80 default_server;"; l6s="    listen [::]:443 ssl http2 default_server;"; }
  if [ "$any" = 0 ]; then rm -f "$NGX_CONFD/default.conf"; return 0; fi
  {
    echo "# IDDigital Hosting — servidor por omissão (gerado pelo painel)"
    if [ "$p80" = 0 ]; then printf 'server {\n    listen 80 default_server;\n%s\n    server_name _;\n' "$l6"; acme_loc; printf '    location / { return 444; }\n}\n'; fi
    printf 'server {\n    listen 443 ssl http2 default_server;\n%s\n    server_name _;\n    ssl_certificate     /etc/minipainel/ssl/panel.crt;\n    ssl_certificate_key /etc/minipainel/ssl/panel.key;\n    return 444;\n}\n' "$l6s"
  } > "$NGX_CONFD/default.conf"
  chmod 644 "$NGX_CONFD/default.conf"
}
ports_web_open(){ local p; for p in 80 443; do fw_open "$p" >/dev/null 2>&1; done; return 0; }

# Domínio do painel (porta 443), com o mesmo conteúdo do painel na porta própria
panel_domain_write(){
  local d ssl cf l6="" l6s=""
  d=$(srv_get PANEL_DOMAIN ''); ssl=$(srv_get PANEL_SSL le)
  if [ -z "$d" ]; then rm -f "$NGX_CONFD/panel-domain.conf"; return 0; fi
  [ "${IPV6:-0}" = 1 ] && { l6="    listen [::]:80;"; l6s="    listen [::]:443 ssl http2;"; }
  cf=$(cert_files mp-painel) || cf="/etc/minipainel/ssl/panel.crt /etc/minipainel/ssl/panel.key"
  {
    printf '# IDDigital Hosting — painel em %s (gerado pelo painel)\nserver {\n    listen 80;\n%s\n    server_name %s;\n' "$d" "$l6" "$d"
    acme_loc
    printf '    location / { return 301 https://$host$request_uri; }\n}\n'
    printf 'server {\n    listen 443 ssl http2;\n%s\n    server_name %s;\n    ssl_certificate     %s;\n    ssl_certificate_key %s;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:MPSSL:1m;\n    include /etc/nginx/minipainel/panel.inc;\n}\n' "$l6s" "$d" "${cf%% *}" "${cf##* }"
  } > "$NGX_CONFD/panel-domain.conf"
  chmod 644 "$NGX_CONFD/panel-domain.conf"
}

cmd_server_mode(){
  local m="${1:-}" em=""
  [ $# -gt 0 ] && shift
  case "$m" in lan|internet) ;; *) die "Usa: mpanel server-mode lan|internet [--email endereço]" ;; esac
  while [ $# -gt 0 ]; do case "$1" in --email) em="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  local re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  if [ -n "$em" ]; then [ "$em" = none ] && em="" || [[ "$em" =~ $re ]] || die "Email inválido: $em"; srv_set EMAIL "$em"; fi
  srv_set MODE "$m"
  [ "$m" = internet ] && ports_web_open
  echo "Modo do servidor: $([ "$m" = lan ] && echo 'LAN (sites por porta)' || echo 'Internet (sites com domínio e SSL)')."
  return 0
}
cmd_site_domains(){
  local n="${1:-}" doms ssl https www d o old_doms old_ssl old_https old_www f bak msg=""
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  old_doms=$(site_get "$n" DOMAINS); old_ssl=$(site_get "$n" SSL); old_https=$(site_get "$n" HTTPS); old_www=$(site_get "$n" WWW)
  doms=$old_doms; ssl=${old_ssl:-none}; https=${old_https:-1}; www=${old_www:-keep}
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) doms="${2:-}"; shift 2 || shift ;;
      --ssl) ssl="${2:-}"; shift 2 || shift ;;
      --https) https="${2:-}"; shift 2 || shift ;;
      --www) www="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  doms=$(printf '%s' "$doms" | tr 'A-Z,;' 'a-z  ' | tr -s ' \n\t' ' ' | sed 's/^ //; s/ $//')
  case "$ssl" in none|le|self) ;; *) die "SSL inválido: usa none, le ou self." ;; esac
  case "$https" in 0|1) ;; *) die "--https tem de ser 0 ou 1." ;; esac
  case "$www" in keep|www|root) ;; *) die "--www tem de ser keep, www ou root." ;; esac
  local cnt=0 seen=" "
  for d in $doms; do
    valid_domain "$d" || die "Domínio inválido: $d"
    [[ "$seen" == *" $d "* ]] && die "Domínio repetido: $d"; seen+="$d "
    o=$(domain_owner "$d") && [ "$o" != "$n" ] && die "O domínio $d já está em uso ($o)."
    cnt=$((cnt + 1))
  done
  [ "$cnt" -le 30 ] || die "Máximo de 30 domínios por site."
  [ -z "$doms" ] && ssl=none
  f=$(site_conf "$n"); bak="$f.bak"; cp -p "$f" "$bak"
  site_set "$n" DOMAINS "$doms"; site_set "$n" SSL "$ssl"; site_set "$n" HTTPS "$https"; site_set "$n" WWW "$www"
  # 1) configuração sem o certificado novo (permite a validação HTTP do Let's Encrypt)
  write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"
  ngx_default_sync
  if ! apply_nginx; then
    mv -f "$bak" "$f"; write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"; ngx_default_sync; apply_nginx >/dev/null 2>&1
    die "Configuração do nginx inválida; nada foi alterado."
  fi
  rm -f "$bak"
  [ -n "$doms" ] && ports_web_open
  # 2) certificado
  if [ "$ssl" = le ]; then
    local errf; errf=$(mktemp)
    # shellcheck disable=SC2086
    if le_issue "mp-$n" $doms 2>"$errf"; then msg="Certificado Let's Encrypt emitido."
    else msg="Os domínios ficaram ativos em HTTP, mas o certificado não foi emitido.
$(cat "$errf")
Confirma que os domínios apontam para este servidor e que as portas 80 e 443 estão acessíveis da Internet."; fi
    rm -f "$errf"
  elif [ "$ssl" = self ]; then
    # shellcheck disable=SC2086
    self_issue "mp-$n" $doms && msg="Certificado autoassinado criado (o browser vai mostrar um aviso)."
  else
    [ -z "$doms" ] && le_delete "mp-$n"
  fi
  # 3) configuração final com HTTPS
  write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  dns_autosync
  if [ -z "$doms" ]; then echo "Site $n sem domínios (só por porta)."; else echo "Domínios de $n: $doms."; fi
  [ -n "$msg" ] && echo "$msg"
  return 0
}
cmd_panel_domain(){
  local d="${1:-}" ssl=le msg=""
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--ssl" ] && ssl="${2:-le}"
  case "$ssl" in le|self) ;; *) die "--ssl tem de ser le ou self." ;; esac
  if [ "$d" = none ] || [ -z "$d" ]; then
    srv_set PANEL_DOMAIN ""; panel_domain_write; ngx_default_sync; apply_nginx || warn "Verifica o nginx."
    le_delete mp-painel; echo "O painel deixou de ter domínio próprio (continua na porta $PANEL_PORT)."; return 0
  fi
  d=$(printf '%s' "$d" | tr 'A-Z' 'a-z')
  valid_domain "$d" || die "Domínio inválido: $d"
  local o; o=$(domain_owner "$d") && [ "$o" != painel ] && die "O domínio $d já está em uso pelo site $o."
  srv_set PANEL_DOMAIN "$d"; srv_set PANEL_SSL "$ssl"
  panel_domain_write; ngx_default_sync
  apply_nginx || { srv_set PANEL_DOMAIN ""; panel_domain_write; ngx_default_sync; apply_nginx >/dev/null 2>&1; die "Configuração do nginx inválida; nada foi alterado."; }
  ports_web_open
  if [ "$ssl" = le ]; then
    local errf; errf=$(mktemp)
    if le_issue mp-painel "$d" 2>"$errf"; then msg="Certificado Let's Encrypt emitido."
    else msg="O painel ficou em https://$d com um certificado autoassinado, porque o Let's Encrypt falhou:
$(cat "$errf")"; fi
    rm -f "$errf"
  else
    self_issue mp-painel "$d"; msg="Certificado autoassinado criado."
  fi
  panel_domain_write; apply_nginx || warn "Verifica o nginx."
  echo "Painel disponível em https://$d (e continua em https://IP:$PANEL_PORT)."
  echo "$msg"
  return 0
}
cmd_ssl_renew(){ command -v certbot >/dev/null 2>&1 || die "O certbot não está instalado."; certbot renew --non-interactive --deploy-hook "systemctl reload nginx" 2>&1 | grep -E 'renew|success|fail|skip|No renewals' | tail -n 6; return 0; }

cmd_ngx_sync(){ # regenera a configuração nginx de todos os sites, do servidor por omissão e do domínio do painel
  local n
  install -d -m 755 "$NGX_INC" "$NGX_CONFD" "$ACME_ROOT"
  panel_allow_write; ports_allow_write
  for n in $(site_names); do logs_migrate_site "$n"; write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"; done
  logs_rotate_conf
  ngx_default_sync; panel_domain_write
  apply_nginx || die "Configuração do nginx inválida depois de regenerar (nginx -t)."
  echo "Configuração nginx regenerada."
  return 0
}

# ---------- segurança do painel e das portas dos sites ----------
PANEL_ALLOW_INC=/etc/nginx/minipainel/panel-allow.inc
PORTS_ALLOW_INC=/etc/nginx/minipainel/ports-allow.inc
audit_cli(){ # regista ações feitas diretamente na consola
  [ -t 0 ] || return 0
  logger -t minipainel-audit -p authpriv.notice "consola root: $1" 2>/dev/null
  jq -cn --arg t "$EPOCHSECONDS" --arg a "$1" '{ts:($t|tonumber), ip:"consola", user:"root", action:$a, ok:true}' >> "$DATA/logs/audit.log" 2>/dev/null
  chown "$PANEL_SYSUSER:$PANEL_SYSUSER" "$DATA/logs/audit.log" 2>/dev/null; return 0
}
auth_update(){ # filtro jq aplicado ao auth.json
  local base='{}'; [ -s "$AUTH" ] && base=$(cat "$AUTH")
  jq "$@" <<<"$base" > "$AUTH.tmp" || { rm -f "$AUTH.tmp"; return 1; }
  chown root:"$PANEL_SYSUSER" "$AUTH.tmp"; chmod 640 "$AUTH.tmp"; mv -f "$AUTH.tmp" "$AUTH"
}
panel_allow_write(){
  local l ip; l=$(srv_get PANEL_ALLOW '')
  {
    echo "# IDDigital Hosting — IPs autorizados a abrir o painel (gerado pelo painel)"
    if [ -n "$l" ]; then
      printf '    allow 127.0.0.1;\n    allow ::1;\n'
      for ip in $l; do printf '    allow %s;\n' "$ip"; done
      printf '    deny all;\n'
    fi
  } > "$PANEL_ALLOW_INC"
  chmod 644 "$PANEL_ALLOW_INC"
}
ports_allow_write(){
  local ip
  {
    echo "# IDDigital Hosting — acesso pelas portas dos sites (gerado pelo painel)"
    if [ "$(srv_get PORTS_ACCESS all)" = lan ]; then
      for ip in 127.0.0.0/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10; do printf '    allow %s;\n' "$ip"; done
      if [ -f "$FW_ALLOW" ]; then grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}' | while read -r ip; do fw_ip_valid "$ip" && printf '    allow %s;\n' "$ip"; done; fi
      printf '    deny all;\n'
    fi
  } > "$PORTS_ALLOW_INC"
  chmod 644 "$PORTS_ALLOW_INC"
}
cmd_panel_allow(){
  local l="$*" ip
  [ "$l" = none ] && l=""
  l=$(printf '%s' "$l" | tr ',;\n' '   ' | xargs)
  for ip in $l; do fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"; done
  srv_set PANEL_ALLOW "$l"; panel_allow_write
  apply_nginx || { srv_set PANEL_ALLOW ""; panel_allow_write; apply_nginx >/dev/null 2>&1; die "Configuração do nginx inválida; o painel continua aberto a todos."; }
  audit_cli "IPs autorizados no painel: ${l:-todos}"
  if [ -n "$l" ]; then echo "O painel só abre a partir de: $l (e do próprio servidor). Para anular na consola: mpanel panel-allow none"
  else echo "O painel abre a partir de qualquer IP."; fi
  return 0
}
cmd_ports_access(){
  local m="${1:-}"
  case "$m" in all|lan) ;; *) die "Usa: mpanel ports-access all|lan" ;; esac
  srv_set PORTS_ACCESS "$m"; ports_allow_write
  apply_nginx || die "Configuração do nginx inválida (nginx -t)."
  if [ "$m" = lan ]; then echo "As portas dos sites só respondem à rede local e aos IPs de confiança. Os domínios (80/443) continuam públicos."
  else echo "As portas dos sites respondem a qualquer IP."; fi
  return 0
}
cmd_panel_user(){
  local u="${1:-}" re='^[a-z][a-z0-9._-]{2,31}$'
  [[ "$u" =~ $re ]] || die "Nome inválido: 3 a 32 caracteres (minúsculas, números, '.', '_' e '-'), a começar por letra."
  auth_update --arg u "$u" '.user = $u' || die "Falha ao gravar."
  sed -i "s/^PANEL_USER=.*/PANEL_USER=$u/" "$CONF"
  audit_cli "Utilizador do painel alterado para $u"
  echo "O utilizador do painel passa a ser '$u'. Usa-o no próximo início de sessão."
  return 0
}
cmd_panel_2fa(){
  local a="${1:-}" sec="${2:-}" re='^[A-Z2-7]{16,64}$' codes="" hashes="[]" c i
  case "$a" in
    set)
      [[ "$sec" =~ $re ]] || die "Segredo inválido."
      for i in 1 2 3 4 5 6 7 8; do
        c="$(openssl rand -hex 3)-$(openssl rand -hex 3)"; codes+="$c "
        hashes=$(jq -c --arg h "$(printf '%s' "$c" | sha256sum | awk '{print $1}')" '. + [$h]' <<<"$hashes")
      done
      auth_update --arg s "$sec" --argjson r "$hashes" '.totp = $s | .recovery = $r' || die "Falha ao gravar."
      rm -f "$DATA/logs/2fa-used.json"
      audit_cli "Verificação em dois passos ativada"
      echo "Verificação em dois passos ativada."
      echo "Códigos de recuperação (guarda-os em local seguro; cada um só funciona uma vez):"
      for c in $codes; do echo "  $c"; done
      ;;
    off)
      auth_update 'del(.totp, .recovery)' || die "Falha ao gravar."
      rm -f "$DATA/logs/2fa-used.json"
      audit_cli "Verificação em dois passos desativada"
      echo "Verificação em dois passos desativada."
      ;;
    *) die "Usa: mpanel panel-2fa off (para desativar na consola)" ;;
  esac
  return 0
}

# ---------- cifra das cópias remotas dos backups ----------
bk_enc_pass(){ # ficheiro temporário com a frase de cifra (derivada da chave dos backups)
  local f; f=$(mktemp /run/mp-bkenc.XXXXXX); chmod 600 "$f"
  bk_key_ensure
  printf 'enc:%s' "$(tr -d '[:space:]' < "$BK_KEY")" | sha256sum | awk '{print $1}' > "$f"
  echo "$f"
}
bk_encrypt_dir(){ # origem destino
  local src=$1 dst=$2 pf rel
  pf=$(bk_enc_pass)
  while IFS= read -r rel; do
    mkdir -p "$dst/$(dirname "$rel")"
    case "$rel" in
      manifest.json|manifest.sig) cp -p "$src/$rel" "$dst/$rel" ;;
      *) openssl enc -aes-256-ctr -pbkdf2 -iter 100000 -salt -pass "file:$pf" -in "$src/$rel" -out "$dst/$rel.enc" || { rm -f "$pf"; return 1; } ;;
    esac
  done < <(cd "$src" && find . -type f -printf '%P\n')
  : > "$dst/ENCRYPTED"
  rm -f "$pf"
}
bk_decrypt_dir(){ # pasta (decifra no lugar)
  local dir=$1 pf f
  [ -f "$dir/ENCRYPTED" ] || return 0
  pf=$(bk_enc_pass)
  while IFS= read -r f; do
    openssl enc -d -aes-256-ctr -pbkdf2 -iter 100000 -pass "file:$pf" -in "$f" -out "${f%.enc}" 2>/dev/null || { rm -f "$pf"; return 1; }
    rm -f "$f"
  done < <(find "$dir" -type f -name '*.enc')
  rm -f "$pf" "$dir/ENCRYPTED"
}

# =============================== EMAIL ======================================
MAIL_CONF=/etc/minipainel/mail.conf
MAIL_DATA=/etc/minipainel/mail/data.json      # {domains:{}, boxes:{}, aliases:{}}
VMAIL=/var/mail/vhosts
PF_MP=/etc/postfix/mp
DV_USERS=/etc/dovecot/mp-users
MSPOOL=/var/spool/mp-mail                      # envio dos sites (escrito pelos sites)
MLIB=/var/lib/minipainel/mail                  # contadores, retidos e rejeitados (só root)
RSPAMD_LOCAL=/etc/rspamd/local.d
DKIM_DIR=/var/lib/rspamd/dkim
mail_get(){ local v; v=$(grep -m1 "^$1=" "$MAIL_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
mail_set(){
  install -d -m 755 /etc/minipainel; touch "$MAIL_CONF"; chmod 600 "$MAIL_CONF"
  if grep -q "^$1=" "$MAIL_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$MAIL_CONF"; else echo "$1=$2" >> "$MAIL_CONF"; fi
}
mail_on(){ [ "$(mail_get ENABLED 0)" = 1 ]; }
conf_lock(){ # ficheiros de configuração sem segredos mas com informação útil a um atacante: só root
  local f; for f in /etc/minipainel/minipainel.conf /etc/minipainel/server.conf /etc/minipainel/mail.conf /etc/minipainel/ftp.conf \
    /etc/minipainel/pma.conf /etc/minipainel/firewall.conf /etc/minipainel/update.conf /etc/minipainel/backup-remotes.json; do [ -f "$f" ] && chmod 600 "$f"; done
  if [ "$(mail_get ENABLED 0)" = 1 ]; then : > /etc/minipainel/mail-enabled; chmod 644 /etc/minipainel/mail-enabled; else rm -f /etc/minipainel/mail-enabled; fi
  return 0
}
mail_need(){ mail_on || die "O email não está ativo. Ativa-o na página Email ou com: mpanel mail-enable --host mail.dominio.pt"; }
mail_data(){ if [ -s "$MAIL_DATA" ]; then cat "$MAIL_DATA"; else echo '{"domains":{},"boxes":{},"aliases":{}}'; fi; }
mail_data_save(){
  install -d -m 700 "$(dirname "$MAIL_DATA")"
  printf '%s\n' "$1" | jq '.' > "$MAIL_DATA.tmp" && chmod 600 "$MAIL_DATA.tmp" && mv -f "$MAIL_DATA.tmp" "$MAIL_DATA"
}
valid_email(){ local re='^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'; [[ "$1" =~ $re ]]; }
valid_mailhash(){ local re='^\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$'; [[ "$1" =~ $re ]]; }
mail_hash_stdin(){ "$(php_cli "$PANEL_PHP")" -r 'echo crypt(rtrim(stream_get_contents(STDIN), "\n"), "\$6\$" . substr(strtr(base64_encode(random_bytes(12)), "+", "."), 0, 16) . "\$");'; }
mail_svc_redis(){ if systemctl list-unit-files redis-server.service >/dev/null 2>&1 && systemctl list-unit-files redis-server.service | grep -q redis-server; then echo redis-server; else echo redis; fi; }
mail_cert(){ cert_files mp-mail || echo "/etc/minipainel/ssl/panel.crt /etc/minipainel/ssl/panel.key"; }

# --- recursivo DNS local (as listas negras não respondem a resolvers públicos) ---
mail_resolver_setup(){
  install -d -m 755 /etc/unbound/unbound.conf.d
  cat > /etc/unbound/unbound.conf.d/minipainel.conf <<'EOF'
# IDDigital Hosting — resolver local para o antispam (listas negras)
server:
    interface: 127.0.0.1
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    prefetch: yes
EOF
  if [ -d /etc/unbound/unbound.conf.d ] && ! grep -q 'unbound.conf.d' /etc/unbound/unbound.conf 2>/dev/null; then
    echo 'include: "/etc/unbound/unbound.conf.d/*.conf"' >> /etc/unbound/unbound.conf
  fi
  if [ ! -s /var/lib/unbound/root.key ]; then
    install -d -m 755 /var/lib/unbound
    command -v unbound-anchor >/dev/null 2>&1 && timeout 30 unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1
    [ -s /var/lib/unbound/root.key ] || cp /usr/share/dns/root.key /var/lib/unbound/root.key 2>/dev/null
    chown unbound:unbound /var/lib/unbound /var/lib/unbound/root.key 2>/dev/null
  fi
  systemctl enable --now unbound >/dev/null 2>&1; systemctl restart unbound >/dev/null 2>&1
  # só muda o resolver do sistema se o unbound estiver mesmo a responder
  if ! mail_unbound_ok; then
    warn "O Unbound não está a responder em 127.0.0.1; o resolver do sistema não foi alterado (as listas negras podem não funcionar)."
    return 0
  fi
  if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    install -d -m 755 /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=127.0.0.1\nDomains=~.\n' > /etc/systemd/resolved.conf.d/minipainel.conf
    systemctl restart systemd-resolved >/dev/null 2>&1
  else
    if [ -d /etc/NetworkManager/conf.d ]; then printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-minipainel-dns.conf; systemctl reload NetworkManager >/dev/null 2>&1; fi
    [ -f /etc/resolv.conf.minipainel ] || cp -pL /etc/resolv.conf /etc/resolv.conf.minipainel 2>/dev/null
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    printf '# IDDigital Hosting — resolver local (unbound); original em /etc/resolv.conf.minipainel\nnameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf
  fi
}

mail_unbound_ok(){ local i; for i in 1 2 3 4 5 6; do dig +short +time=2 +tries=1 @127.0.0.1 . NS 2>/dev/null | grep -q . && return 0; sleep 1; done; return 1; }
mail_dnsbl_sites(){ # para o postscreen
  local own s out="zen.spamhaus.org=127.0.0.[2..11]*3, b.barracudacentral.org=127.0.0.2*2, bl.spamcop.net*1, psbl.surriel.com*1"
  own=$(mail_get DNSBL "dnsbl.3rhost.pt")
  for s in $own; do out+=", $s*3"; done
  echo "$out"
}
mail_postfix_config(){
  local h c ip6=all cf kf
  h=$(mail_get HOST); c=$(mail_cert); cf=${c%% *}; kf=${c##* }
  [ "${IPV6:-0}" = 1 ] || ip6=ipv4
  install -d -m 755 "$PF_MP"
  [ -s /etc/postfix/main.cf ] || printf '# IDDigital Hosting — Postfix (gerido pelo painel com postconf)\n' > /etc/postfix/main.cf
  printf '/^mp_/ x\n' > "$PF_MP/site_users"
  postconf -e "myhostname = $h" "myorigin = \$myhostname" "mydestination = \$myhostname, localhost" "mynetworks = 127.0.0.0/8 [::1]/128" \
    "inet_interfaces = all" "inet_protocols = $ip6" "smtpd_banner = \$myhostname ESMTP" "biff = no" "append_dot_mydomain = no" \
    "virtual_mailbox_domains = texthash:$PF_MP/vdomains" "virtual_mailbox_maps = texthash:$PF_MP/vmailbox" \
    "virtual_alias_maps = texthash:$PF_MP/valias" "virtual_transport = lmtp:unix:private/dovecot-lmtp" \
    "smtpd_sasl_type = dovecot" "smtpd_sasl_path = private/auth" "smtpd_sasl_auth_enable = no" \
    "smtpd_sender_login_maps = texthash:$PF_MP/sender_login" \
    "smtpd_tls_cert_file = $cf" "smtpd_tls_key_file = $kf" "smtpd_tls_security_level = may" "smtpd_tls_auth_only = yes" \
    "smtpd_tls_protocols = >=TLSv1.2" "smtpd_tls_mandatory_protocols = >=TLSv1.2" "smtp_tls_security_level = may" "smtp_tls_protocols = >=TLSv1.2" \
    "smtpd_helo_required = yes" "disable_vrfy_command = yes" "strict_rfc821_envelopes = yes" \
    "smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname" \
    "smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain" \
    "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination" \
    "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_non_fqdn_recipient, reject_unknown_recipient_domain" \
    "milter_protocol = 6" "milter_default_action = accept" "milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}" \
    "smtpd_milters = inet:127.0.0.1:11332" "non_smtpd_milters = inet:127.0.0.1:11332" \
    "message_size_limit = 52428800" "mailbox_size_limit = 0" "recipient_delimiter = +" \
    "authorized_submit_users = !regexp:$PF_MP/site_users, static:anyone" \
    "postscreen_access_list = permit_mynetworks" "postscreen_dnsbl_sites = $(mail_dnsbl_sites)" \
    "postscreen_dnsbl_threshold = 3" "postscreen_dnsbl_action = enforce" "postscreen_greet_action = enforce" \
    "postscreen_pipelining_enable = no" "postscreen_non_smtp_command_enable = no" "postscreen_bare_newline_enable = no" \
    "smtpd_client_connection_rate_limit = 30" "smtpd_client_message_rate_limit = 100" "anvil_rate_time_unit = 60s" \
    "smtpd_client_auth_rate_limit = 10" "compatibility_level = 3.6"
  postconf -M "smtp/inet=smtp inet n - n - 1 postscreen" \
              "smtpd/pass=smtpd pass - - n - - smtpd" \
              "dnsblog/unix=dnsblog unix - - n - 0 dnsblog" \
              "tlsproxy/unix=tlsproxy unix - - n - 0 tlsproxy" \
              "submission/inet=submission inet n - n - - smtpd" \
              "smtps/inet=smtps inet n - n - - smtpd"
  local svc
  for svc in submission smtps; do
    postconf -P "$svc/inet/syslog_name=postfix/$svc" "$svc/inet/smtpd_sasl_auth_enable=yes" \
      "$svc/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject" \
      "$svc/inet/smtpd_sender_restrictions=reject_sender_login_mismatch,permit_sasl_authenticated,reject" \
      "$svc/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject" \
      "$svc/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject" \
      "$svc/inet/milter_macro_daemon_name=ORIGINATING"
  done
  postconf -P "submission/inet/smtpd_tls_security_level=encrypt" "smtps/inet/smtpd_tls_wrappermode=yes"
}
mail_dovecot_config(){
  local h c vu vg
  h=$(mail_get HOST); c=$(mail_cert); vu=$(id -u vmail); vg=$(id -g vmail)
  sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null
  install -d -m 755 /etc/dovecot/sieve
  cat > /etc/dovecot/sieve/mp-spam.sieve <<'EOF'
require ["fileinto", "mailbox"];
if anyof (header :contains "X-Spam" "Yes", header :contains "X-Spam-Status" "Yes") { fileinto :create "Junk"; stop; }
EOF
  cat > /etc/dovecot/conf.d/99-minipainel.conf <<EOF
# IDDigital Hosting — caixas de correio virtuais (gerado pelo painel; não editar à mão)
protocols = imap pop3 lmtp sieve
listen = *$([ "${IPV6:-0}" = 1 ] && echo ', ::')
ssl = required
ssl_cert = <${c%% *}
ssl_key = <${c##* }
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
disable_plaintext_auth = yes
auth_mechanisms = plain login
auth_verbose = yes
auth_failure_delay = 3 secs
mail_location = maildir:~/Maildir
mail_privileged_group = vmail
first_valid_uid = $vu
last_valid_uid = $vu
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%Lu $DV_USERS
}
userdb {
  driver = passwd-file
  args = username_format=%Lu $DV_USERS
  default_fields = uid=$vu gid=$vg home=$VMAIL/%Ld/%Ln
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
protocol lmtp {
  mail_plugins = \$mail_plugins quota sieve
  postmaster_address = postmaster@$h
}
protocol imap {
  mail_plugins = \$mail_plugins quota imap_quota
}
protocol pop3 {
  mail_plugins = \$mail_plugins quota
}
namespace inbox {
  mailbox Drafts {
    auto = subscribe
    special_use = \\Drafts
  }
  mailbox Junk {
    auto = subscribe
    special_use = \\Junk
  }
  mailbox Trash {
    auto = subscribe
    special_use = \\Trash
  }
  mailbox Sent {
    auto = subscribe
    special_use = \\Sent
  }
}
plugin {
  quota = maildir:Quota
  quota_rule = *:storage=1G
  quota_exceeded_message = A caixa de correio está cheia.
  sieve = file:~/sieve;active=~/.dovecot.sieve
  sieve_before = /etc/dovecot/sieve/mp-spam.sieve
}
EOF
  sievec /etc/dovecot/sieve/mp-spam.sieve >/dev/null 2>&1
  touch "$DV_USERS"; chown root:dovecot "$DV_USERS"; chmod 640 "$DV_USERS"
}
mail_rspamd_config(){
  install -d -m 755 "$RSPAMD_LOCAL"
  install -d -o _rspamd -g _rspamd -m 750 "$DKIM_DIR" 2>/dev/null || install -d -o rspamd -g rspamd -m 750 "$DKIM_DIR"
  printf 'bind_socket = "127.0.0.1:11332";\nmilter = yes;\ntimeout = 120s;\nupstream "local" {\n  default = yes;\n  self_scan = yes;\n}\n' > "$RSPAMD_LOCAL/worker-proxy.inc"
  printf 'bind_socket = "127.0.0.1:11333";\n' > "$RSPAMD_LOCAL/worker-normal.inc"
  if mail_unbound_ok; then printf 'dns {\n  nameserver = ["127.0.0.1:53:10"];\n}\nlocal_addrs = "127.0.0.0/8, ::1";\n' > "$RSPAMD_LOCAL/options.inc"
  else printf 'local_addrs = "127.0.0.0/8, ::1";\n' > "$RSPAMD_LOCAL/options.inc"; fi
  mail_secrets
  printf 'reject = 15;\nadd_header = 6;\ngreylist = 4;\n' > "$RSPAMD_LOCAL/actions.conf"
  printf 'enabled = true;\n' > "$RSPAMD_LOCAL/greylist.conf"
  printf 'path = "%s/$domain.$selector.key";\nselector = "mp";\nallow_username_mismatch = true;\nsign_local = true;\nsign_authenticated = true;\nuse_domain = "header";\nallow_hdrfrom_mismatch = false;\n' "$DKIM_DIR" > "$RSPAMD_LOCAL/dkim_signing.conf"
  cp "$RSPAMD_LOCAL/dkim_signing.conf" "$RSPAMD_LOCAL/arc.conf"
  printf 'use = ["x-spamd-bar", "x-spam-level", "x-spam-status", "authentication-results"];\nauthenticated_headers = ["authentication-results"];\n' > "$RSPAMD_LOCAL/milter_headers.conf"
  printf 'rates {\n  user = {\n    bucket = {\n      burst = 100;\n      rate = "%s / 1h";\n    }\n  }\n}\n' "$(mail_get BOX_LIMIT 200)" > "$RSPAMD_LOCAL/ratelimit.conf"
  {
    printf 'rbls {\n'
    local n=0 z
    for z in $(mail_get DNSBL "dnsbl.3rhost.pt"); do
      n=$((n + 1))
      printf '  mp_own_%s {\n    rbl = "%s";\n    ipv6 = false;\n    received = false;\n    symbol = "MP_OWN_DNSBL_%s";\n    description = "Lista negra própria (%s)";\n  }\n' "$n" "$z" "$n" "$z"
    done
    printf '}\n'
  } > "$RSPAMD_LOCAL/rbl.conf"
  {
    printf 'symbols {\n'
    local i
    for i in $(seq 1 "$(mail_get DNSBL "dnsbl.3rhost.pt" | wc -w)"); do printf '  "MP_OWN_DNSBL_%s" {\n    weight = 7.0;\n  }\n' "$i"; done
    printf '}\n'
  } > "$RSPAMD_LOCAL/rbl_group.conf"
  if [ "$(mail_get CLAMAV 0)" = 1 ]; then
    local sock=/run/clamav/clamd.ctl; [ -S /run/clamd.scan/clamd.sock ] && sock=/run/clamd.scan/clamd.sock
    printf 'clamav {\n  action = "reject";\n  message = "Vírus detetado: ${VIRUS}";\n  type = "clamav";\n  servers = "%s";\n  symbol = "CLAM_VIRUS";\n  scan_mime_parts = true;\n  max_size = 26214400;\n}\n' "$sock" > "$RSPAMD_LOCAL/antivirus.conf"
  else
    rm -f "$RSPAMD_LOCAL/antivirus.conf"
  fi
}
# Bloqueia a porta 25 de saída para tudo exceto o root e o Postfix: um site comprometido não envia spam diretamente.
mail_rspamd_user(){ if id _rspamd >/dev/null 2>&1; then echo _rspamd; else echo rspamd; fi; }
mail_fw_apply(){
  fw_has_nft || return 0
  nft delete table inet minipainel_mail >/dev/null 2>&1
  mail_on || return 0
  local pu ru vu du
  pu=$(id -u postfix 2>/dev/null) || return 0
  ru=$(id -u "$(mail_rspamd_user)" 2>/dev/null) || ru=$pu
  vu=$(id -u vmail 2>/dev/null) || vu=$pu
  du=$(id -u redis 2>/dev/null) || du=$ru
  # porta 25: só o root e o Postfix (um site comprometido não envia spam diretamente)
  # Redis e Rspamd: só os serviços de email lhes chegam (os sites não leem o histórico nem mexem no antispam)
  nft -f - <<EOF
table inet minipainel_mail {
  chain output {
    type filter hook output priority 0; policy accept;
    tcp dport 25 meta skuid != { 0, $pu } counter reject with tcp reset
    tcp dport 6379 meta skuid != { 0, $ru, $du } counter reject with tcp reset
    tcp dport { 11332, 11333, 11334 } meta skuid != { 0, $pu, $ru, $vu } counter reject with tcp reset
  }
}
EOF
}
# passwords do Redis e do controlador do Rspamd (segunda barreira, além da firewall local)
mail_secrets(){
  local rp cp rc g
  [ -s /etc/minipainel/redis.pw ] || ( umask 077; openssl rand -hex 24 > /etc/minipainel/redis.pw )
  [ -s /etc/minipainel/rspamd-controller.pw ] || ( umask 077; openssl rand -hex 24 > /etc/minipainel/rspamd-controller.pw )
  rp=$(cat /etc/minipainel/redis.pw); cp=$(cat /etc/minipainel/rspamd-controller.pw)
  for rc in /etc/redis/redis.conf /etc/redis.conf; do
    [ -f "$rc" ] || continue
    if grep -qE '^\s*requirepass\s' "$rc"; then sed -i -E "s|^\s*requirepass\s.*|requirepass $rp|" "$rc"; else echo "requirepass $rp" >> "$rc"; fi
    break
  done
  g=$(id -gn "$(mail_rspamd_user)" 2>/dev/null || echo root)
  printf 'servers = "127.0.0.1";\npassword = "%s";\n' "$rp" > "$RSPAMD_LOCAL/redis.conf"
  printf 'bind_socket = "127.0.0.1:11334";\npassword = "%s";\nenable_password = "%s";\nsecure_ip = "127.0.0.2";\n' "$cp" "$cp" > "$RSPAMD_LOCAL/worker-controller.inc"
  chown root:"$g" "$RSPAMD_LOCAL/redis.conf" "$RSPAMD_LOCAL/worker-controller.inc"; chmod 640 "$RSPAMD_LOCAL/redis.conf" "$RSPAMD_LOCAL/worker-controller.inc"
  # cabeçalho com a password para quem fala com o controlador (aprendizagem como vmail; estado como root)
  printf 'Password: %s\n' "$cp" > /etc/minipainel/rspamd-controller.hdr
  chown root:vmail /etc/minipainel/rspamd-controller.hdr 2>/dev/null; chmod 640 /etc/minipainel/rspamd-controller.hdr
}
mail_apply(){ # gera os mapas do Postfix e os utilizadores do Dovecot a partir de data.json
  local j; j=$(mail_data)
  install -d -m 755 "$PF_MP"
  jq -r '.domains | keys[] | "\(.) OK"' <<<"$j" > "$PF_MP/vdomains"
  jq -r '.boxes | keys[] | "\(.) OK"' <<<"$j" > "$PF_MP/vmailbox"
  jq -r '.aliases | to_entries[] | "\(.key) \(.value | join(","))"' <<<"$j" > "$PF_MP/valias"
  {
    jq -r '.boxes | keys[] | "\(.) \(.)"' <<<"$j"
    jq -r '(.boxes | keys) as $b | .aliases | to_entries[] | . as $a | ($a.value | map(select(. as $d | $b | index($d)))) as $own | select($own | length > 0) | "\($a.key) \($own | join(","))"' <<<"$j"
  } > "$PF_MP/sender_login"
  chmod 644 "$PF_MP"/vdomains "$PF_MP"/vmailbox "$PF_MP"/valias "$PF_MP"/sender_login
  jq -r '.boxes | to_entries[] | "\(.key):{SHA512-CRYPT}\(.value.hash)::::::userdb_quota_rule=*:storage=\(.value.quota)M"' <<<"$j" > "$DV_USERS.tmp"
  chown root:dovecot "$DV_USERS.tmp"; chmod 640 "$DV_USERS.tmp"; mv -f "$DV_USERS.tmp" "$DV_USERS"
  postfix reload >/dev/null 2>&1 || systemctl reload postfix >/dev/null 2>&1
  return 0
}
# --- ativação ---
cmd_mail_enable(){
  local h="" re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'
  while [ $# -gt 0 ]; do case "$1" in --host) h="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  h=$(printf '%s' "${h:-$(mail_get HOST)}" | tr 'A-Z' 'a-z')
  [[ "$h" =~ $re ]] || die "Indica o nome do servidor de correio (ex.: mail.iddigital.pt) com --host."
  echo "A instalar Postfix, Dovecot, Rspamd, Redis e Unbound (pode demorar alguns minutos)..."
  if [ "$OS_FAMILY" = debian ]; then
    echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
    echo "postfix postfix/mailname string $h" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q postfix dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-managesieved \
      rspamd redis-server unbound bind9-dnsutils >/dev/null 2>&1 || die "Falhou a instalação dos pacotes de email."
  else
    if [ ! -f /etc/yum.repos.d/rspamd.repo ]; then
      local elv; elv=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
      curl -fsSL "https://rspamd.com/rpm-stable/centos-$elv/rspamd.repo" -o /etc/yum.repos.d/rspamd.repo && rpm --import https://rspamd.com/rpm-stable/gpg.key || die "Não foi possível adicionar o repositório do Rspamd."
    fi
    dnf install -y -q postfix dovecot dovecot-pigeonhole rspamd redis unbound bind-utils >/dev/null 2>&1 || die "Falhou a instalação dos pacotes de email."
  fi
  id vmail >/dev/null 2>&1 || useradd -r -U -d "$VMAIL" -s "$(command -v nologin || echo /sbin/nologin)" -c "IDDigital Hosting mail" vmail
  install -d -o vmail -g vmail -m 750 "$VMAIL"
  install -d -m 711 "$MSPOOL"; install -d -m 700 "$MLIB" "$MLIB/held" "$MLIB/rejected" "$MLIB/sent"
  mail_set ENABLED 1; mail_set HOST "$h"; conf_lock
  [ -n "$(mail_get DNSBL)" ] || mail_set DNSBL "dnsbl.3rhost.pt"
  [ -n "$(mail_get SITE_LIMIT)" ] || mail_set SITE_LIMIT 100
  [ -n "$(mail_get BOX_LIMIT)" ] || mail_set BOX_LIMIT 200
  [ -n "$(mail_get AUTH_FAILS)" ] || mail_set AUTH_FAILS 10
  [ -n "$(mail_get CLAMAV)" ] || mail_set CLAMAV 0
  [ -s "$MAIL_DATA" ] || mail_data_save '{"domains":{},"boxes":{},"aliases":{}}'
  echo "A configurar o resolver DNS local (unbound)..."; mail_resolver_setup
  mail_host_web; local errf; errf=$(mktemp)
  if [ "$(srv_get MODE lan)" = internet ]; then
    le_issue mp-mail "$h" 2>"$errf" || { self_issue mp-mail "$h"; echo "Aviso: certificado Let's Encrypt para $h falhou; ficou um autoassinado. $(head -c 300 "$errf")"; }
  else
    cert_files mp-mail >/dev/null || self_issue mp-mail "$h"
  fi
  rm -f "$errf"
  mail_postfix_config; mail_dovecot_config; mail_rspamd_config; mail_learning_config; mail_lists_config; mail_apply
  local s; for s in $(mail_svc_redis) unbound rspamd dovecot postfix; do systemctl enable "$s" >/dev/null 2>&1; systemctl restart "$s" >/dev/null 2>&1 || warn "O serviço $s não arrancou."; done
  for s in 25 465 587 993 995 143 110; do fw_open "$s" >/dev/null 2>&1; done
  mail_fw_apply
  echo "A instalar o webmail (Roundcube)..."; mail_webmail_setup
  write_fm_pool_email
  # o mail() do PHP dos sites passa a ir para a fila controlada do painel
  for s in $(site_names); do mail_site_spool "$s"; write_pool "$s" "$(site_get "$s" PHP)"; done
  for s in $(php_installed); do apply_php "$s" >/dev/null 2>&1; done
  echo "Email ativo em $h. Webmail: https://$h:$WM_PORT. Próximo passo: adiciona um domínio de email e cria os registos DNS indicados."
  return 0
}
mail_host_web(){ # porta 80 para a validação do certificado do servidor de correio
  local h; h=$(mail_get HOST)
  [ -n "$h" ] || { rm -f "$NGX_CONFD/mail-host.conf"; return 0; }
  install -d -m 755 "$NGX_CONFD"
  { printf '# IDDigital Hosting — validação do certificado de %s\nserver {\n    listen 80;\n    server_name %s;\n' "$h" "$h"; acme_loc; printf '    location / { return 444; }\n}\n'; } > "$NGX_CONFD/mail-host.conf"
  ngx_default_sync; apply_nginx >/dev/null 2>&1
}
mail_site_spool(){ local s=$1; id "mp_$s" >/dev/null 2>&1 || return 0; install -d -m 711 "$MSPOOL"; install -d -o "mp_$s" -g "mp_$s" -m 700 "$MSPOOL/$s" "$MSPOOL/$s/tmp" "$MSPOOL/$s/new"; }

# --- domínios, caixas e aliases ---
cmd_mail_domain_add(){
  local d="${1:-}" j
  mail_need; valid_domain "$d" || die "Domínio inválido: $d"
  j=$(mail_data); [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = false ] || die "O domínio $d já existe."
  install -d -o vmail -g vmail -m 750 "$VMAIL/$d"
  if [ ! -s "$DKIM_DIR/$d.mp.key" ]; then
    rspamadm dkim_keygen -s mp -b 2048 -d "$d" -k "$DKIM_DIR/$d.mp.key" > "$DKIM_DIR/$d.mp.txt" 2>/dev/null || die "Não foi possível gerar a chave DKIM."
    chown "$(stat -c %U "$DKIM_DIR")":"$(stat -c %G "$DKIM_DIR")" "$DKIM_DIR/$d.mp.key" "$DKIM_DIR/$d.mp.txt"; chmod 640 "$DKIM_DIR/$d.mp.key"
  fi
  j=$(jq --arg d "$d" --arg t "$EPOCHSECONDS" '.domains[$d] = {created:($t|tonumber)}' <<<"$j")
  mail_data_save "$j"; mail_apply
  dns_autosync
  echo "Domínio de email $d adicionado com DKIM. $(dns_on && [ -f "$DNS_DIR/$d.json" ] && echo 'Os registos foram criados na zona DNS deste servidor.' || echo 'Cria os registos DNS indicados na página Email.')"
  return 0
}
cmd_mail_domain_del(){
  local d="${1:-}" j
  mail_need; j=$(mail_data)
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = true ] || die "O domínio $d não existe."
  j=$(jq --arg d "$d" '.domains |= del(.[$d]) | .boxes |= with_entries(select(.key | endswith("@" + $d) | not)) | .aliases |= with_entries(select(.key | endswith("@" + $d) | not))' <<<"$j")
  mail_data_save "$j"; mail_apply
  rm -rf "${VMAIL:?}/$d" "$DKIM_DIR/$d.mp.key" "$DKIM_DIR/$d.mp.txt"
  dns_autosync
  echo "Domínio $d apagado, com as caixas de correio e os aliases."
  return 0
}
mail_box_args(){ # --hash H | --password P, --quota N
  BHASH=""; BQUOTA=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hash) BHASH="${2:-}"; shift 2 || shift ;;
      --password) BHASH=$(printf '%s' "${2:-}" | mail_hash_stdin); [ ${#2} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."; shift 2 || shift ;;
      --quota) BQUOTA="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [ -z "$BHASH" ] || valid_mailhash "$BHASH" || die "Hash de password inválido."
  [ -z "$BQUOTA" ] || { [[ "$BQUOTA" =~ ^[0-9]{1,7}$ ]] && [ "$BQUOTA" -ge 10 ]; } || die "Quota inválida (MB, mínimo 10)."
}
cmd_mail_box_add(){
  local e="${1:-}" d j BHASH BQUOTA gen=""
  [ $# -gt 0 ] && shift
  mail_need; e=$(printf '%s' "$e" | tr 'A-Z' 'a-z'); valid_email "$e" || die "Endereço inválido: $e"
  mail_box_args "$@"; d=${e#*@}
  j=$(mail_data)
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = true ] || die "O domínio $d não está configurado no email."
  [ "$(jq --arg e "$e" '(.boxes | has($e)) or (.aliases | has($e))' <<<"$j")" = false ] || die "O endereço $e já existe."
  if [ -z "$BHASH" ]; then gen=$(gen_pass 16); BHASH=$(printf '%s' "$gen" | mail_hash_stdin); fi
  j=$(jq --arg e "$e" --arg h "$BHASH" --argjson q "${BQUOTA:-1024}" --arg t "$EPOCHSECONDS" '.boxes[$e] = {hash:$h, quota:$q, created:($t|tonumber)}' <<<"$j")
  mail_data_save "$j"; mail_apply
  echo "Caixa de correio $e criada (quota ${BQUOTA:-1024} MB)."
  [ -n "$gen" ] && echo "Password: $gen"
  mail_client_info "$e"
  return 0
}
mail_client_info(){ local h; h=$(mail_get HOST); echo "Configuração: IMAP $h:993 (SSL) · POP3 $h:995 (SSL) · SMTP $h:465 (SSL) ou 587 (STARTTLS) · utilizador: $1"; }
cmd_mail_box_set(){
  local e="${1:-}" j BHASH BQUOTA
  [ $# -gt 0 ] && shift
  mail_need; j=$(mail_data)
  [ "$(jq --arg e "$e" '.boxes | has($e)' <<<"$j")" = true ] || die "A caixa $e não existe."
  mail_box_args "$@"
  [ -n "$BHASH" ] && j=$(jq --arg e "$e" --arg h "$BHASH" '.boxes[$e].hash = $h' <<<"$j")
  [ -n "$BQUOTA" ] && j=$(jq --arg e "$e" --argjson q "$BQUOTA" '.boxes[$e].quota = $q' <<<"$j")
  mail_data_save "$j"; mail_apply
  echo "Caixa $e atualizada.$([ -n "$BHASH" ] && echo " Password alterada.")$([ -n "$BQUOTA" ] && echo " Quota: $BQUOTA MB.")"
  return 0
}
cmd_mail_box_del(){
  local e="${1:-}" j u d
  mail_need; j=$(mail_data)
  [ "$(jq --arg e "$e" '.boxes | has($e)' <<<"$j")" = true ] || die "A caixa $e não existe."
  j=$(jq --arg e "$e" '.boxes |= del(.[$e]) | .aliases |= (map_values(map(select(. != $e))) | with_entries(select(.value | length > 0)))' <<<"$j")
  mail_data_save "$j"; mail_apply
  u=${e%@*}; d=${e#*@}
  [[ "$u" =~ ^[a-z0-9._+-]+$ ]] && rm -rf "${VMAIL:?}/$d/$u"
  echo "Caixa de correio $e apagada."
  return 0
}
cmd_mail_alias_set(){
  local a="${1:-}" dests="${2:-}" j d x list="[]"
  mail_need; a=$(printf '%s' "$a" | tr 'A-Z' 'a-z')
  valid_email "$a" || [[ "$a" =~ ^@([a-z0-9-]+\.)+[a-z]{2,}$ ]] || die "Alias inválido: $a (usa nome@dominio ou @dominio para receber tudo)."
  d=${a#*@}; j=$(mail_data)
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = true ] || die "O domínio $d não está configurado no email."
  [ "$(jq --arg a "$a" '.boxes | has($a)' <<<"$j")" = false ] || die "$a já é uma caixa de correio."
  for x in $(printf '%s' "$dests" | tr 'A-Z,;' 'a-z  '); do
    valid_email "$x" || die "Destino inválido: $x"
    list=$(jq -c --arg x "$x" '. + [$x] | unique' <<<"$list")
  done
  [ "$(jq 'length' <<<"$list")" -gt 0 ] || die "Indica pelo menos um destino."
  [ "$(jq 'length' <<<"$list")" -le 20 ] || die "Máximo de 20 destinos."
  j=$(jq --arg a "$a" --argjson l "$list" '.aliases[$a] = $l' <<<"$j")
  mail_data_save "$j"; mail_apply
  echo "Encaminhamento $a → $(jq -r 'join(", ")' <<<"$list")."
  return 0
}
cmd_mail_alias_del(){
  local a="${1:-}" j; mail_need; j=$(mail_data)
  [ "$(jq --arg a "$a" '.aliases | has($a)' <<<"$j")" = true ] || die "O alias $a não existe."
  mail_data_save "$(jq --arg a "$a" '.aliases |= del(.[$a])' <<<"$j")"; mail_apply
  echo "Alias $a apagado."; return 0
}

# --- definições do antispam e antivírus ---
cmd_mail_settings(){
  local re_n='^[0-9]{1,5}$' z
  mail_need
  while [ $# -gt 0 ]; do
    case "$1" in
      --dnsbl) z="${2:-}"; [ "$z" = none ] && z=""; for x in $z; do valid_domain "$x" || die "Lista negra inválida: $x"; done; mail_set DNSBL "$z"; shift 2 || shift ;;
      --site-limit) [[ "${2:-}" =~ $re_n ]] || die "Limite inválido."; mail_set SITE_LIMIT "$2"; shift 2 || shift ;;
      --box-limit) [[ "${2:-}" =~ $re_n ]] || die "Limite inválido."; mail_set BOX_LIMIT "$2"; shift 2 || shift ;;
      --auth-fails) [[ "${2:-}" =~ $re_n ]] && [ "$2" -ge 3 ] || die "Valor inválido (mínimo 3)."; mail_set AUTH_FAILS "$2"
                    if [ -f "$PROT_CONF" ]; then sed -i "s/^AUTH_FAILS=.*/AUTH_FAILS=$2/" "$PROT_CONF"; fi; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  postconf -e "postscreen_dnsbl_sites = $(mail_dnsbl_sites)"; mail_rspamd_config
  postfix reload >/dev/null 2>&1; systemctl reload rspamd >/dev/null 2>&1 || systemctl restart rspamd >/dev/null 2>&1
  echo "Definições do antispam guardadas."; return 0
}
cmd_mail_av(){
  local a="${1:-}"; mail_need
  case "$a" in
    on)
      echo "A instalar o ClamAV (cerca de 1,2 GB de RAM quando ativo)..."
      if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q clamav-daemon clamav-freshclam >/dev/null 2>&1 || die "Falhou a instalação do ClamAV."
        systemctl enable --now clamav-freshclam clamav-daemon >/dev/null 2>&1
      else dnf install -y -q clamav clamd clamav-update >/dev/null 2>&1 || die "Falhou a instalação do ClamAV."
        sed -i 's/^#\?LocalSocket .*/LocalSocket \/run\/clamd.scan\/clamd.sock/' /etc/clamd.d/scan.conf; sed -i 's/^Example/#Example/' /etc/clamd.d/scan.conf /etc/freshclam.conf
        freshclam >/dev/null 2>&1; systemctl enable --now clamd@scan >/dev/null 2>&1
      fi
      mail_set CLAMAV 1 ;;
    off) mail_set CLAMAV 0
      systemctl disable --now clamav-daemon clamd@scan >/dev/null 2>&1 ;;
    *) die "Usa: mpanel mail-av on|off" ;;
  esac
  mail_rspamd_config; systemctl restart rspamd >/dev/null 2>&1
  echo "Antivírus $([ "$a" = on ] && echo 'ativado (as primeiras assinaturas podem demorar alguns minutos a descarregar)' || echo desativado)."
  return 0
}

# --- registos DNS e verificação ---
mail_public_ip(){ local ip; ip=$(mail_get PUBLIC_IP); [ -n "$ip" ] || ip=$(curl -s4 -m 6 https://api.ipify.org 2>/dev/null); [[ "$ip" =~ ^[0-9.]+$ ]] && echo "$ip"; }
mail_dkim_value(){ tr -d '\n\t' < "$DKIM_DIR/$1.mp.txt" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"\n' | tr -s ' ' | sed 's/^ //'; }
cmd_mail_dns_check(){
  local d="${1:-}" h ip mx spf dk dm ptr a out
  mail_need; [ "$(mail_data | jq --arg d "$d" '.domains | has($d)')" = true ] || die "O domínio $d não existe."
  h=$(mail_get HOST); ip=$(mail_public_ip)
  mx=$(dig +short MX "$d" | awk '{print $2}' | sed 's/\.$//' | tr '\n' ' ')
  spf=$(dig +short TXT "$d" | tr -d '"' | grep -i '^v=spf1' | head -1)
  dk=$(dig +short TXT "mp._domainkey.$d" | tr -d '" \n')
  dm=$(dig +short TXT "_dmarc.$d" | tr -d '"' | head -1)
  a=$(dig +short A "$h" | tail -1)
  ptr=$( [ -n "$ip" ] && dig +short -x "$ip" | sed 's/\.$//' | head -1)
  out=$(jq -n --arg d "$d" --arg h "$h" --arg ip "$ip" --arg mx "$mx" --arg spf "$spf" --arg dk "$dk" --arg dkx "$(mail_dkim_value "$d" | tr -d ' ')" \
    --arg dm "$dm" --arg a "$a" --arg ptr "$ptr" --arg t "$EPOCHSECONDS" \
    '{checked:($t|tonumber), ip:$ip,
      mx:{ok:($mx | split(" ") | index($h) != null), found:$mx},
      a:{ok:($ip != "" and $a == $ip), found:$a},
      spf:{ok:($spf != "" and (($spf | test(" mx( |$)")) or ($spf | contains("a:" + $h)) or ($ip != "" and ($spf | contains("ip4:" + $ip))))), found:$spf},
      dkim:{ok:($dk != "" and $dk == $dkx), found:(if $dk == "" then "" else "publicado" end)},
      dmarc:{ok:($dm | test("^v=DMARC1")), found:$dm},
      ptr:{ok:($ptr == $h), found:$ptr}}')
  local f=$DATA/stats/mail-dns.json
  jq --arg d "$d" --argjson o "$out" '.[$d] = $o' "$( [ -s "$f" ] && echo "$f" || { echo '{}' > "$f"; echo "$f"; })" > "$f.tmp" && mv -f "$f.tmp" "$f"
  chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"
  local bad; bad=$(jq -r 'to_entries | map(select(.value | type == "object" and has("ok") and (.ok | not)) | .key) | join(", ")' <<<"$out")
  if [ -z "$bad" ]; then echo "DNS de $d: tudo correto."; else echo "DNS de $d: falta corrigir $bad. Vê os valores na página Email."; fi
  return 0
}
# --- envio dos sites: fila controlada, limites e suspensão automática ---
mail_site_sent(){ # site segundos -> n.º de envios nesse período
  local f="$MLIB/sent/$1" since=$(( EPOCHSECONDS - $2 ))
  [ -f "$f" ] || { echo 0; return; }
  awk -v s="$since" '$1 >= s' "$f" | wc -l
}
mail_site_rej(){ local f="$MLIB/rejected/$1.log" since=$(( EPOCHSECONDS - $2 )); [ -f "$f" ] || { echo 0; return; }; awk -v s="$since" '$1 >= s' "$f" | wc -l; }
mail_site_from_ok(){ # site from -> 0 se o remetente pertence ao site (domínios do site)
  local s=$1 f=$2 d; d=${f#*@}
  valid_email "$f" || return 1
  [[ " $(site_get "$s" DOMAINS) " == *" $d "* ]] && return 0
  [[ " $(site_get "$s" DOMAINS) " == *" www.$d "* ]] && return 0
  return 1
}
mail_hdrs(){ awk 'BEGIN{h=""} /^\r?$/{exit} /^[ \t]/{h=h" "$0; next} {if(h!="")print h; h=$0} END{if(h!="")print h}' "$1"; }  # cabeçalhos, com linhas dobradas juntas
mail_count_rcpt(){ # destinatários em To/Cc/Bcc (e Resent-*)
  mail_hdrs "$1" | grep -iE '^(resent-)?(to|cc|bcc):' | sed -E 's/^[^:]*://' | grep -oE '[A-Za-z0-9._%+=-]+@[A-Za-z0-9.-]+' | sort -fu | wc -l
}
mail_fix_from(){ # msg site remetente: o From: tem de ser de um domínio do site; senão passa a ser o remetente validado
  local f=$1 s=$2 env=$3 hf addr d disp tmp
  hf=$(mail_hdrs "$f" | grep -im1 '^from:' | sed -E 's/^[^:]*:[ \t]*//')
  addr=$(printf '%s' "$hf" | grep -oE '[A-Za-z0-9._%+=-]+@[A-Za-z0-9.-]+' | head -1 | tr 'A-Z' 'a-z'); d=${addr#*@}
  if [ -n "$addr" ] && { [[ " $(site_get "$s" DOMAINS) " == *" $d "* ]] || [[ " $(site_get "$s" DOMAINS) " == *" www.$d "* ]]; }; then return 0; fi
  disp=$(printf '%s' "$hf" | sed -nE 's/^"?([^"<]*[^" <])"?[ \t]*<.*/\1/p' | tr -d '\r\n' | cut -c1-80)
  tmp=$(mktemp /var/tmp/mp-msg.XXXXXX)
  awk -v nf="From: ${disp:+\"$disp\" }<$env>" -v rt="$addr" '
    BEGIN{inh=1; skip=0; hasrt=0}
    inh && /^\r?$/ { if (!hasrt && rt != "") print "Reply-To: " rt; inh=0; print; next }
    inh && /^[ \t]/ { if (skip) next; print; next }
    inh { skip=0; if (tolower($0) ~ /^from:/) { print nf; skip=1; next } if (tolower($0) ~ /^reply-to:/) hasrt=1; print; next }
    { print }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
cmd_mail_spool(){
  mail_on || return 0
  exec 7>/run/minipainel-mailspool.lock; flock -n 7 || return 0
  local s u lim sent f base from msg res act sc rej susp nheld
  for s in $(site_names); do
    [ -d "$MSPOOL/$s/new" ] || continue
    u="mp_$s"; id "$u" >/dev/null 2>&1 || continue
    susp=$(site_get "$s" MAIL_SUSP); lim=$(site_get "$s" MAIL_LIMIT); lim=${lim:-$(mail_get SITE_LIMIT 100)}
    sent=$(mail_site_sent "$s" 3600)
    for f in $(cd "$MSPOOL/$s/new" && ls -1 -- *.eml 2>/dev/null | sort | head -n 200); do
      [ "$susp" = 1 ] && break
      [ "$sent" -ge "$lim" ] && break
      base=${f%.eml}
      msg=$(mktemp /var/tmp/mp-msg.XXXXXX)
      runuser -u "$u" -- head -c 31457280 "$MSPOOL/$s/new/$f" > "$msg" 2>/dev/null
      from=$(runuser -u "$u" -- head -c 300 "$MSPOOL/$s/new/$base.from" 2>/dev/null | head -n 1 | tr -d '\r <>')
      mail_site_from_ok "$s" "$from" || from="$s@$(mail_get HOST)"
      local nr maxr; maxr=$(mail_get MAX_RCPT 50)
      nr=$(mail_count_rcpt "$msg")
      mail_fix_from "$msg" "$s" "$from"
      res=$(rspamc -h 127.0.0.1:11333 --json -u "site-$s" -i 127.0.0.1 -F "$from" < "$msg" 2>/dev/null)
      act=$(jq -r '.action // "no action"' <<<"$res" 2>/dev/null); sc=$(jq -r '.score // 0' <<<"$res" 2>/dev/null)
      if [ "$nr" -gt "$maxr" ] || [ "$nr" -eq 0 ]; then act=reject; sc="rcpt:$nr"; fi
      if [ "$nr" -le "$maxr" ] && [ "$sent" -gt 0 ] && [ $(( sent + nr )) -gt "$lim" ] && [ "$act" != reject ]; then rm -f "$msg"; break; fi
      if [ "$act" = reject ]; then
        install -d -m 700 "$MLIB/rejected/$s"; mv -f "$msg" "$MLIB/rejected/$s/$base.eml"
        echo "$EPOCHSECONDS $sc" >> "$MLIB/rejected/$s.log"
        rej=$(mail_site_rej "$s" 3600)
        if [ "$rej" -ge "$(mail_get SPAM_SUSPEND 5)" ]; then
          site_set "$s" MAIL_SUSP 1; site_set "$s" MAIL_SUSP_WHY "spam detetado ($rej mensagens rejeitadas na última hora)"; susp=1
          jq -cn --arg t "$EPOCHSECONDS" --arg a "Envio de email do site $s suspenso automaticamente: $rej mensagens com spam na última hora" '{ts:($t|tonumber), ip:"servidor", user:"automático", action:$a, ok:false}' >> "$DATA/logs/audit.log"
        fi
      else
        { printf 'X-MP-Site: %s\n' "$s"; cat "$msg"; } | /usr/sbin/sendmail -t -i -f "$from" && { local k; for (( k = 0; k < nr; k++ )); do echo "$EPOCHSECONDS"; done >> "$MLIB/sent/$s"; sent=$(( sent + nr )); }
        rm -f "$msg"
      fi
      runuser -u "$u" -- rm -f "$MSPOOL/$s/new/$f" "$MSPOOL/$s/new/$base.from"
    done
    # guarda só as últimas 24 h dos contadores
    for f in "$MLIB/sent/$s" "$MLIB/rejected/$s.log"; do [ -f "$f" ] && awk -v s="$(( EPOCHSECONDS - 86400 ))" '$1 >= s' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"; done
  done
  return 0
}
cmd_mail_site(){ # site --limit N | --suspend | --resume | --purge
  local s="${1:-}" re='^[0-9]{1,6}$'
  [ $# -gt 0 ] && shift
  valid_site "$s" && site_exists "$s" || die "O site '$s' não existe."
  case "${1:-}" in
    --limit) [[ "${2:-}" =~ $re ]] || die "Limite inválido."; site_set "$s" MAIL_LIMIT "$2"; echo "Limite de envio de $s: $2 emails por hora." ;;
    --suspend) site_set "$s" MAIL_SUSP 1; site_set "$s" MAIL_SUSP_WHY "suspenso manualmente"; echo "Envio de email do site $s suspenso (as mensagens ficam retidas)." ;;
    --resume) site_set "$s" MAIL_SUSP 0; site_set "$s" MAIL_SUSP_WHY ""; rm -f "$MLIB/rejected/$s.log"; echo "Envio de email do site $s retomado." ;;
    --purge) find "$MSPOOL/$s/new" -type f -delete 2>/dev/null; rm -rf "${MLIB:?}/rejected/$s"; echo "Mensagens retidas e rejeitadas de $s apagadas." ;;
    *) die "Usa: mpanel mail-site <site> --limit N | --suspend | --resume | --purge" ;;
  esac
  return 0
}
cmd_mail_queue(){ # list | flush | delete <id>|all
  mail_need
  case "${1:-list}" in
    list) postqueue -j 2>/dev/null | jq -r '[.queue_id, .queue_name, .sender, (.recipients | map(.address) | join(",")), ((.recipients[0].delay_reason // "") | .[0:80])] | @tsv' ;;
    flush) postqueue -f; echo "Fila reenviada." ;;
    delete) local q="${2:-}" re='^[0-9A-Za-z]{6,20}$'
      if [ "$q" = all ]; then postsuper -d ALL >/dev/null 2>&1; echo "Fila de correio esvaziada."
      else [[ "$q" =~ $re ]] || die "Identificador inválido."; postsuper -d "$q" >/dev/null 2>&1 && echo "Mensagem $q apagada da fila."; fi ;;
    *) die "Usa: mpanel mail-queue list|flush|delete <id>|all" ;;
  esac
  return 0
}
mail_state_json(){
  if ! mail_on; then echo '{"enabled":false}'; return 0; fi
  local j dns q s sites="[]" used
  j=$(mail_data)
  dns=$(cat "$DATA/stats/mail-dns.json" 2>/dev/null || echo '{}')
  q=$(postqueue -j 2>/dev/null | jq -cs 'map({id:.queue_id, q:.queue_name, from:.sender, to:(.recipients | map(.address) | join(", ")), why:((.recipients[0].delay_reason // "") | .[0:160]), t:.arrival_time, size:.message_size}) | .[0:200]' 2>/dev/null)
  for s in $(site_names); do
    sites=$(jq -c --arg s "$s" --arg h1 "$(mail_site_sent "$s" 3600)" --arg h24 "$(mail_site_sent "$s" 86400)" \
      --arg held "$(find "$MSPOOL/$s/new" -name '*.eml' 2>/dev/null | wc -l)" --arg rej "$(find "$MLIB/rejected/$s" -name '*.eml' 2>/dev/null | wc -l)" \
      --arg su "$(site_get "$s" MAIL_SUSP)" --arg why "$(site_get "$s" MAIL_SUSP_WHY)" --arg lim "$(site_get "$s" MAIL_LIMIT)" \
      '. + [{site:$s, sent_1h:($h1|tonumber), sent_24h:($h24|tonumber), held:($held|tonumber), rejected:($rej|tonumber), suspended:($su=="1"), why:$why, limit:(if $lim == "" then null else ($lim|tonumber) end)}]' <<<"$sites")
  done
  local dk; dk=$(jq -r '.domains | keys[]' <<<"$j" | while read -r d; do printf '%s\t%s\n' "$d" "$(mail_dkim_value "$d")"; done | jq -R 'split("\t") | {(.[0]): (.[1] // "")}' | jq -cs 'add // {}')
  used=$(jq -r '.boxes | keys[]' <<<"$j" | while read -r e; do printf '%s\t%s\n' "$e" "$(du -sm "$VMAIL/${e#*@}/${e%@*}" 2>/dev/null | awk '{print $1}')"; done | jq -R 'split("\t") | {(.[0]): ((.[1] // "0") | tonumber? // 0)}' | jq -cs 'add // {}')
  local lists hist
  lists=$(mail_lists_json 2>/dev/null); hist=$(mail_history_json 2>/dev/null)
  dns=$(jv mail.dns "$dns" '{}'); q=$(jv mail.queue "$q" '[]'); sites=$(jv mail.sites "$sites" '[]'); used=$(jv mail.used "$used" '{}'); dk=$(jv mail.dkim "$dk" '{}')
  lists=$(jv mail.lists "$lists" '[]'); hist=$(jv mail.history "$hist" '[]')
  jq -n --argjson j "$j" --argjson dns "$dns" --argjson q "$q" --argjson sites "$sites" --argjson used "$used" --argjson dk "$dk" \
    --arg h "$(mail_get HOST)" --arg dnsbl "$(mail_get DNSBL)" --arg sl "$(mail_get SITE_LIMIT 100)" --arg bl "$(mail_get BOX_LIMIT 200)" \
    --arg af "$(mail_get AUTH_FAILS 10)" --arg av "$(mail_get CLAMAV 0)" --arg exp "$(cert_expiry mp-mail)" \
    --arg wmp "$WM_PORT" --argjson lists "$lists" --argjson hist "$hist" \
    --arg st "$(for x in postfix dovecot rspamd; do systemctl is-active "$x" 2>/dev/null; done | grep -c '^active$')" \
    '{enabled:true, host:$h, dnsbl:$dnsbl, site_limit:($sl|tonumber), box_limit:($bl|tonumber), auth_fails:($af|tonumber), clamav:($av=="1"),
      cert_exp:(if $exp == "" then null else ($exp|tonumber) end), services_ok:($st == "3"),
      domains:[$j.domains | keys[] | . as $d | {name:$d, boxes:([$j.boxes | keys[] | select(endswith("@" + $d))] | length), dns:($dns[$d] // null), dkim:(($dk // {})[$d] // "")}],
      boxes:[$j.boxes | to_entries[] | {email:.key, quota:.value.quota, used:($used[.key] // 0)}],
      aliases:[$j.aliases | to_entries[] | {alias:.key, dests:.value}],
      sites:$sites, queue:$q, webmail:("https://" + $h + ":" + $wmp), lists:$lists, history:$hist}'
}
cmd_mail_dns_info(){ # registos a criar para um domínio
  local d="${1:-}" h ip; mail_need
  h=$(mail_get HOST); ip=$(mail_public_ip)
  printf '%s\tMX\t10 %s\n' "$d" "$h"
  printf '%s\tTXT\tv=spf1 mx a:%s ~all\n' "$d" "$h"
  printf 'mp._domainkey.%s\tTXT\t%s\n' "$d" "$(mail_dkim_value "$d")"
  printf '_dmarc.%s\tTXT\tv=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@%s\n' "$d" "$d"
  printf '%s\tA\t%s\n' "$h" "${ip:-<IP público>}"
  printf '%s\tPTR\t%s (pedir ao fornecedor do servidor)\n' "${ip:-<IP público>}" "$h"
}

# --- gestor de ficheiros da área Email (corre como vmail; só /var/mail/vhosts) ---
MAILFM_TMP=/var/lib/minipainel-mailfm
write_fm_pool_email(){
  local f; f=$(fm_pool_file _email)
  install -d -o vmail -g vmail -m 700 "$MAILFM_TMP"
  cat > "$f" <<EOF
; IDDigital Hosting — gestor de ficheiros da área Email (corre como vmail; gerido pelo mpanel)
[mp-fm-_email]
user = vmail
group = vmail
listen = $(php_run_dir "$PANEL_PHP")/mp-fm-_email.sock
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
request_terminate_timeout = 0
php_admin_value[open_basedir] = $VMAIL/:$MAILFM_TMP/:/opt/minipainel/files/
php_admin_value[upload_tmp_dir] = $MAILFM_TMP
php_admin_value[sys_temp_dir] = $MAILFM_TMP
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 72M
php_admin_value[memory_limit] = 256M
php_value[max_execution_time] = 900
php_admin_value[max_input_time] = 900
php_admin_value[error_log] = $MAILFM_TMP/ficheiros-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF
  chmod 644 "$f"
}

# --- webmail (Roundcube do repositório da distribuição: atualizações de segurança automáticas) ---
WM_DATA=/var/lib/minipainel-webmail
WM_PORT=2096
wm_paths(){ # define WM_ROOT (raiz pública), WM_CONF (config.inc.php) e WM_SQL
  if [ -d /var/lib/roundcube/public_html ]; then WM_ROOT=/var/lib/roundcube/public_html; WM_CONF=/etc/roundcube/config.inc.php; WM_SQL=/usr/share/roundcube/SQL
  else WM_ROOT=/usr/share/roundcubemail; WM_CONF=/etc/roundcubemail/config.inc.php; WM_SQL=/usr/share/roundcubemail/SQL; fi
  [ -d "$WM_SQL" ] || WM_SQL=/var/lib/roundcube/SQL
}
mail_webmail_setup(){
  local key ip6="" c
  if [ "$OS_FAMILY" = debian ]; then
    echo "roundcube-core roundcube/dbconfig-install boolean false" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends roundcube-core roundcube-sqlite3 roundcube-plugins sqlite3 >/dev/null 2>&1 || { warn "Falhou a instalação do Roundcube."; return 1; }
  else
    dnf install -y -q roundcubemail sqlite >/dev/null 2>&1 || { warn "Falhou a instalação do Roundcube."; return 1; }
  fi
  wm_paths
  id mp-webmail >/dev/null 2>&1 || useradd -r -U -d "$WM_DATA" -s "$(command -v nologin || echo /sbin/nologin)" -c "IDDigital Hosting webmail" mp-webmail
  install -d -o mp-webmail -g mp-webmail -m 750 "$WM_DATA" "$WM_DATA/temp" "$WM_DATA/logs"
  [ -s /etc/minipainel/webmail.key ] || ( umask 077; openssl rand -base64 18 | tr -d '\n=' | cut -c1-24 > /etc/minipainel/webmail.key )
  key=$(cat /etc/minipainel/webmail.key)
  cat > "$WM_CONF" <<EOF
<?php
// IDDigital Hosting — configuração do webmail (gerada pelo painel; não editar à mão)
\$config = [];
\$config['db_dsnw'] = 'sqlite:///$WM_DATA/roundcube.db?mode=0640';
\$config['imap_host'] = 'ssl://127.0.0.1:993';
\$config['smtp_host'] = 'tls://127.0.0.1:587';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['managesieve_host'] = 'tls://127.0.0.1';
\$config['managesieve_port'] = 4190;
\$config['managesieve_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['managesieve_vacation'] = 1;
\$config['markasjunk_learning_driver'] = null;
\$config['product_name'] = 'IDDigital Webmail';
\$config['support_url'] = '';
\$config['des_key'] = '$key';
\$config['plugins'] = ['archive', 'zipdownload', 'managesieve', 'markasjunk'];
\$config['language'] = 'pt_PT';
\$config['skin'] = 'elastic';
\$config['temp_dir'] = '$WM_DATA/temp/';
\$config['log_dir'] = '$WM_DATA/logs/';
\$config['log_driver'] = 'file';
\$config['log_logins'] = true;
\$config['login_rate_limit'] = 3;
\$config['enable_installer'] = false;
\$config['ip_check'] = true;
\$config['use_https'] = true;
\$config['session_lifetime'] = 30;
\$config['max_message_size'] = '25M';
\$config['username_domain_forced'] = false;
\$config['login_lc'] = 2;
\$config['junk_mbox'] = 'Junk';
\$config['create_default_folders'] = true;
EOF
  chown root:mp-webmail "$WM_CONF"; chmod 640 "$WM_CONF"
  if [ ! -s "$WM_DATA/roundcube.db" ]; then
    sqlite3 "$WM_DATA/roundcube.db" < "$WM_SQL/sqlite.initial.sql" >/dev/null 2>&1 || warn "Não foi possível criar a base de dados do webmail."
  else
    runuser -u mp-webmail -- php "$(dirname "$WM_SQL")/bin/updatedb.sh" --package=roundcube --dir="$WM_SQL" >/dev/null 2>&1
  fi
  chown mp-webmail:mp-webmail "$WM_DATA/roundcube.db"; chmod 640 "$WM_DATA/roundcube.db"
  # PHP-FPM próprio (utilizador sem acesso aos sites)
  cat > "$(php_pool_dir "$PANEL_PHP")/mp-webmail.conf" <<EOF
; IDDigital Hosting — webmail (corre como mp-webmail; gerido pelo mpanel)
[mp-webmail]
user = mp-webmail
group = mp-webmail
listen = $(php_run_dir "$PANEL_PHP")/mp-webmail.sock
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
php_admin_value[upload_max_filesize] = 25M
php_admin_value[post_max_size] = 30M
php_admin_value[memory_limit] = 256M
php_admin_value[session.gc_maxlifetime] = 21600
php_admin_value[upload_tmp_dir] = $WM_DATA/temp
php_admin_value[sys_temp_dir] = $WM_DATA/temp
php_admin_value[error_log] = $WM_DATA/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_flag[expose_php] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF
  apply_php "$PANEL_PHP" >/dev/null 2>&1 || warn "Verifica o PHP-FPM $PANEL_PHP."
  c=$(mail_cert)
  [ "${IPV6:-0}" = 1 ] && ip6="    listen [::]:$WM_PORT ssl http2;"
  cat > "$NGX_CONFD/webmail.conf" <<EOF
# IDDigital Hosting — webmail (Roundcube) em https://$(mail_get HOST):$WM_PORT
server {
    listen $WM_PORT ssl http2;
$ip6
    server_name _;
    ssl_certificate     ${c%% *};
    ssl_certificate_key ${c##* };
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:MPSSL:1m;
    error_page 497 =301 https://\$host:\$server_port\$request_uri;
    root $WM_ROOT;
    index index.php;
    client_max_body_size 30M;
    access_log /var/log/nginx/webmail.access.log;
    error_log  /var/log/nginx/webmail.error.log;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy same-origin always;
    location ~ ^/(config|temp|logs|SQL|bin|installer|vendor|program/(include|lib|localization|steps))(/|\$) { deny all; }
    location ~ /\\. { deny all; }
    location ~ \\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\\.php)(/.*)\$;
        if (!-f \$document_root\$fastcgi_script_name) { return 404; }
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:$(php_run_dir "$PANEL_PHP")/mp-webmail.sock;
        fastcgi_read_timeout 300s;
    }
}
EOF
  chmod 644 "$NGX_CONFD/webmail.conf"
  fw_open "$WM_PORT" >/dev/null 2>&1
  apply_nginx >/dev/null 2>&1 || warn "Verifica o nginx (nginx -t)."
  return 0
}

# --- o Bayes aprende quando o utilizador move mensagens para o Lixo ou para fora dele ---
mail_learning_config(){
  install -d -m 755 /etc/dovecot/sieve
  printf '#!/bin/sh\nexec curl -s -m 30 -H @/etc/minipainel/rspamd-controller.hdr --data-binary @- http://127.0.0.1:11334/learnspam >/dev/null\n' > /etc/dovecot/sieve/mp-learn-spam.sh
  printf '#!/bin/sh\nexec curl -s -m 30 -H @/etc/minipainel/rspamd-controller.hdr --data-binary @- http://127.0.0.1:11334/learnham >/dev/null\n' > /etc/dovecot/sieve/mp-learn-ham.sh
  chmod 755 /etc/dovecot/sieve/mp-learn-spam.sh /etc/dovecot/sieve/mp-learn-ham.sh
  printf 'require ["vnd.dovecot.pipe", "copy", "imapsieve"];\npipe :copy "mp-learn-spam.sh";\n' > /etc/dovecot/sieve/mp-learn-spam.sieve
  printf 'require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];\nif environment :matches "imap.mailbox" "*" { set "mailbox" "${1}"; }\nif string "${mailbox}" "Trash" { stop; }\npipe :copy "mp-learn-ham.sh";\n' > /etc/dovecot/sieve/mp-learn-ham.sieve
  cat > /etc/dovecot/conf.d/99-minipainel-learn.conf <<'EOF'
# IDDigital Hosting — aprendizagem do antispam (mover para/de Lixo treina o Bayes do Rspamd)
protocol imap {
  mail_plugins = $mail_plugins imap_sieve
}
plugin {
  sieve_plugins = sieve_imapsieve sieve_extprograms
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
  sieve_pipe_bin_dir = /etc/dovecot/sieve
  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY APPEND
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/mp-learn-spam.sieve
  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/mp-learn-ham.sieve
}
EOF
  sievec /etc/dovecot/sieve/mp-learn-spam.sieve >/dev/null 2>&1; sievec /etc/dovecot/sieve/mp-learn-ham.sieve >/dev/null 2>&1
  printf 'autolearn = true;\nmin_learns = 50;\n' > "$RSPAMD_LOCAL/classifier-bayes.conf"
}

# --- listas de remetentes (permitir / bloquear) ---
MAIL_LISTS=/etc/rspamd/local.d
mail_lists_config(){
  local t
  for t in allow-from allow-domain allow-ip deny-from deny-domain deny-ip; do [ -f "$MAIL_LISTS/mp-$t.map" ] || : > "$MAIL_LISTS/mp-$t.map"; done
  cat > "$RSPAMD_LOCAL/multimap.conf" <<EOF
MP_ALLOW_FROM { type = "from"; filter = "email:addr"; map = "$MAIL_LISTS/mp-allow-from.map"; score = -20.0; description = "Remetente permitido no painel"; }
MP_ALLOW_DOMAIN { type = "from"; filter = "email:domain"; map = "$MAIL_LISTS/mp-allow-domain.map"; score = -20.0; description = "Domínio permitido no painel"; }
MP_ALLOW_IP { type = "ip"; map = "$MAIL_LISTS/mp-allow-ip.map"; score = -20.0; description = "IP permitido no painel"; }
MP_DENY_FROM { type = "from"; filter = "email:addr"; map = "$MAIL_LISTS/mp-deny-from.map"; score = 20.0; description = "Remetente bloqueado no painel"; }
MP_DENY_DOMAIN { type = "from"; filter = "email:domain"; map = "$MAIL_LISTS/mp-deny-domain.map"; score = 20.0; description = "Domínio bloqueado no painel"; }
MP_DENY_IP { type = "ip"; map = "$MAIL_LISTS/mp-deny-ip.map"; score = 20.0; description = "IP bloqueado no painel"; }
EOF
}
cmd_mail_list(){ # allow|deny add|del <email | @dominio | IP>
  local l="${1:-}" op="${2:-}" v t f
  mail_need
  v=$(printf '%s' "${3:-}" | tr 'A-Z' 'a-z')
  case "$l" in allow|deny) ;; *) die "Usa: mpanel mail-list allow|deny add|del <email|@domínio|IP>" ;; esac
  if valid_email "$v"; then t=from
  elif [[ "$v" == @* ]] && valid_domain "${v#@}"; then t=domain; v=${v#@}
  elif fw_ip_valid "$v"; then t=ip
  else die "Valor inválido: usa um email, @domínio ou um IP."; fi
  f="$MAIL_LISTS/mp-$l-$t.map"; touch "$f"
  case "$op" in
    add) grep -qxF "$v" "$f" || echo "$v" >> "$f"; echo "$([ "$l" = allow ] && echo Permitido || echo Bloqueado): $([ "$t" = domain ] && echo "@")$v" ;;
    del) grep -vxF "$v" "$f" > "$f.tmp"; mv -f "$f.tmp" "$f"; echo "Removido da lista: $([ "$t" = domain ] && echo "@")$v" ;;
    *) die "Usa add ou del." ;;
  esac
  chmod 644 "$f"
  return 0
}
mail_lists_json(){
  local l t
  for l in allow deny; do for t in from domain ip; do
    [ -s "$MAIL_LISTS/mp-$l-$t.map" ] && sed "s/^/$l $t /" "$MAIL_LISTS/mp-$l-$t.map"
  done; done | jq -R 'split(" ") | {list:.[0], type:.[1], value:(if .[1] == "domain" then "@" + .[2] else .[2] end)}' | jq -cs '.'
}
mail_history_json(){ # últimas mensagens rejeitadas ou marcadas como spam (histórico do Rspamd)
  local r; r=$(curl -s -m 5 -H @/etc/minipainel/rspamd-controller.hdr http://127.0.0.1:11334/history 2>/dev/null)
  jq -e . >/dev/null 2>&1 <<<"$r" || { echo '[]'; return 0; }
  printf '%s' "$r" | jq -c '[(.rows // [])[] | select(.action == "reject" or .action == "add header" or .action == "rewrite subject") |
    {t:.unix_time, action:.action, score:((.score // 0) * 10 | floor / 10), from:(.sender_mime // .sender_smtp // ""), to:((.rcpt_mime // .rcpt_smtp // []) | if type == "array" then join(", ") else . end),
     subject:(.subject // ""), ip:(.ip // ""), symbols:([(.symbols // {}) | to_entries[] | select((.value.score // 0) >= 1) | .key] | .[0:8])}] | .[0:150]' 2>/dev/null || echo '[]'
}

# ============================ ATUALIZAÇÕES ===================================
UPD_CONF=/etc/minipainel/update.conf          # URL=, KEY (chave pública em update.pub)
UPD_PUB=/etc/minipainel/update.pub
UPD_DIR=/var/lib/minipainel/update
UPD_SNAP=/var/backups/minipainel/_atualizacoes
UPD_STATE=$DATA/stats/update.json
OSU_STATE=$DATA/stats/os-updates.json
UPD_RUN=$DATA/stats/update-run.json
upd_url(){ local v; v=$(grep -m1 '^URL=' "$UPD_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-https://raw.githubusercontent.com/naoavr/painel-alojamento-nao/main}"; }
UPD_TOKEN=/etc/minipainel/update.token
upd_get(){ # url ficheiro [segundos] -> código HTTP (token do GitHub lido de um descritor, nunca na linha de comandos)
  local u=$1 out=$2 t=${3:-60} tok=""
  [ -s "$UPD_TOKEN" ] && tok=$(cat "$UPD_TOKEN")
  if [ -n "$tok" ] && [[ "$u" == https://raw.githubusercontent.com/* || "$u" == https://api.github.com/* ]]; then
    curl -sSL -m "$t" -o "$out" -w '%{http_code}' -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") "$u" 2>/dev/null
  else
    curl -sSL -m "$t" -o "$out" -w '%{http_code}' "$u" 2>/dev/null
  fi
}
upd_err(){ # código -> explicação
  case "$1" in
    401|403) echo "o GitHub recusou o acesso (token inválido, expirado ou sem permissão de leitura do conteúdo)" ;;
    404) if [ -s "$UPD_TOKEN" ]; then echo "ficheiro não encontrado (o token tem acesso a este repositório?)"; else echo "ficheiro não encontrado (se o repositório for privado, configura o token do GitHub em Atualizações)"; fi ;;
    000) echo "sem ligação ao GitHub" ;;
    *) echo "erro HTTP $1" ;;
  esac
}
cmd_update_token(){ # set <token> | clear
  case "${1:-}" in
    set) local t="${2:-}"; [[ "$t" =~ ^(github_pat_[A-Za-z0-9_]{20,255}|gh[pousr]_[A-Za-z0-9]{20,255})$ ]] || die "Token inválido (começa por github_pat_ ou ghp_)."
         ( umask 077; printf '%s\n' "$t" > "$UPD_TOKEN" ); chmod 600 "$UPD_TOKEN"
         local tmp c; tmp=$(mktemp); c=$(upd_get "$(upd_url)/install.sh" "$tmp" 30); rm -f "$tmp"
         if [ "$c" = 200 ]; then echo "Token guardado: o repositório está acessível."; else echo "Token guardado, mas o teste falhou: $(upd_err "$c")."; fi ;;
    clear) rm -f "$UPD_TOKEN"; echo "Token do GitHub removido." ;;
    *) die "Usa: mpanel update-token set <token> | clear" ;;
  esac
  return 0
}
upd_status(){ # passo em curso (texto) ou vazio para terminar
  if [ -n "${1:-}" ]; then jq -n --arg s "$1" --arg k "${2:-painel}" --arg t "$EPOCHSECONDS" '{step:$s, kind:$k, since:($t|tonumber)}' > "$UPD_RUN.tmp" && chown root:"$PANEL_SYSUSER" "$UPD_RUN.tmp" && chmod 640 "$UPD_RUN.tmp" && mv -f "$UPD_RUN.tmp" "$UPD_RUN"
  else rm -f "$UPD_RUN"; fi
}
upd_save(){ # ficheiro json
  printf '%s\n' "$2" > "$1.tmp" && chown root:"$PANEL_SYSUSER" "$1.tmp" && chmod 640 "$1.tmp" && mv -f "$1.tmp" "$1"
}
upd_newer(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }   # $2 é mais recente que $1
upd_verify(){ # pasta -> 0 assinatura válida; 2 sem chave configurada; 1 falha
  local d=$1 sum
  sum=$(sha256sum "$d/install.sh" | awk '{print $1}')
  if [ -s "$d/version.json" ]; then [ "$sum" = "$(jq -r '.sha256 // ""' "$d/version.json" 2>/dev/null)" ] || return 1; fi
  [ -s "$UPD_PUB" ] || return 2
  [ -s "$d/install.sh.sig" ] || return 1
  base64 -d "$d/install.sh.sig" > "$d/sig.bin" 2>/dev/null || return 1
  openssl pkeyutl -verify -pubin -inkey "$UPD_PUB" -rawin -in "$d/install.sh" -sigfile "$d/sig.bin" >/dev/null 2>&1 || return 1
  return 0
}
cmd_update_check(){
  local u j="" latest notes signed=false tmp c sum="" src=version.json
  u=$(upd_url); tmp=$(mktemp)
  c=$(upd_get "$u/version.json" "$tmp" 20)
  if [ "$c" = 200 ] && jq -e '.version' "$tmp" >/dev/null 2>&1; then j=$(cat "$tmp")
  else
    # sem version.json: lê a versão do próprio instalador
    c=$(upd_get "$u/install.sh" "$tmp" 120)
    if [ "$c" = 200 ] && latest=$(grep -m1 -oE '^MP_VERSION="[0-9]+(\.[0-9]+)+"' "$tmp" | cut -d'"' -f2) && [ -n "$latest" ]; then
      sum=$(sha256sum "$tmp" | awk '{print $1}'); src=install.sh
      j=$(jq -n --arg v "$latest" --arg s "$sum" --arg n "$(grep -m1 -E '^# NOTAS:' "$tmp" | sed 's/^# NOTAS:[[:space:]]*//')" '{version:$v, sha256:$s, notes:$n, date:""}')
    fi
  fi
  rm -f "$tmp"
  if [ -z "$j" ]; then
    upd_save "$UPD_STATE" "$(jq -n --arg c "$MP_VERSION" --arg t "$EPOCHSECONDS" --arg e "Não foi possível obter a versão publicada em $u: $(upd_err "$c")." --argjson k "$([ -s "$UPD_PUB" ] && echo true || echo false)" --argjson tk "$([ -s "$UPD_TOKEN" ] && echo true || echo false)" \
      '{current:$c, latest:null, checked:($t|tonumber), error:$e, key:$k, token:$tk}')"
    die "Não foi possível obter a versão publicada em $u: $(upd_err "$c")."
  fi
  latest=$(jq -r '.version' <<<"$j"); notes=$(jq -r '.notes // ""' <<<"$j"); sum=$(jq -r '.sha256 // ""' <<<"$j")
  [ -s "$UPD_PUB" ] && signed=true
  upd_save "$UPD_STATE" "$(jq -n --arg c "$MP_VERSION" --arg l "$latest" --arg n "$notes" --arg d "$(jq -r '.date // ""' <<<"$j")" --arg t "$EPOCHSECONDS" --argjson k "$signed" \
     --argjson tk "$([ -s "$UPD_TOKEN" ] && echo true || echo false)" --arg sh "$sum" --arg src "$src" \
     --argjson nw "$(upd_newer "$MP_VERSION" "$latest" && echo true || echo false)" \
     '{current:$c, latest:$l, notes:$n, date:$d, checked:($t|tonumber), newer:$nw, key:$k, token:$tk, sha256:$sh, source:$src, error:null}')"
  if upd_newer "$MP_VERSION" "$latest"; then echo "Há uma versão nova: $latest (instalada: $MP_VERSION)."; else echo "O painel está atualizado ($MP_VERSION)."; fi
  return 0
}
upd_snapshot(){ # cópia do painel antes de atualizar -> imprime o caminho
  local ts f
  ts=$(date '+%Y%m%d-%H%M%S'); install -d -m 700 "$UPD_SNAP"; f="$UPD_SNAP/$ts-v$MP_VERSION.tar.gz"
  local items=(etc/minipainel opt/minipainel usr/local/sbin/mpanel usr/local/sbin/mpanel-stats usr/local/sbin/mpanel-cron usr/local/sbin/mp-sendmail
    etc/nginx/minipainel etc/nginx/nginx.conf) x
  for x in /etc/php/*/fpm/pool.d /etc/opt/remi/*/php-fpm.d /etc/php-fpm.d /etc/systemd/system/minipainel-*; do [ -e "$x" ] && items+=("${x#/}"); done
  tar -C / -czf "$f" --ignore-failed-read "${items[@]}" 2>/dev/null
  chmod 600 "$f"; echo "$f"
}
upd_restore(){ # ficheiro (a conta de acesso e o 2FA nunca são repostos a partir de uma cópia)
  tar -C / -xzpf "$1" --exclude=var/lib/minipainel/auth.json --exclude=etc/minipainel/update.pub || return 1
  systemctl daemon-reload >/dev/null 2>&1
  local v; for v in $(php_installed); do systemctl restart "$(php_service "$v")" >/dev/null 2>&1; done
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  systemctl restart minipainel-stats.service minipainel-worker.path >/dev/null 2>&1
  return 0
}
upd_health(){ # o painel responde depois da atualização?
  local c i
  nginx -t >/dev/null 2>&1 || return 1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    c=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "https://127.0.0.1:$PANEL_PORT/" 2>/dev/null)
    [ "$c" = 200 ] && return 0; sleep 2
  done
  return 1
}
upd_finish(){ # ok msg
  local f=$DATA/stats/update-last.json
  upd_save "$f" "$(jq -n --arg t "$EPOCHSECONDS" --argjson ok "$1" --arg m "$2" '{ts:($t|tonumber), ok:$ok, msg:$m}')"
  jq -cn --arg t "$EPOCHSECONDS" --arg a "$2" --argjson ok "$1" '{ts:($t|tonumber), ip:"servidor", user:"atualização", action:$a, ok:$ok}' >> "$DATA/logs/audit.log" 2>/dev/null
  upd_status ""
}
# Corre noutra unidade do systemd: o instalador reinicia serviços do painel e não pode matar este processo.
# Corre a partir de uma cópia: o instalador substitui o próprio mpanel durante a atualização.
upd_spawn(){ # comando...
  local cp=/run/minipainel-upd.sh
  install -m 700 /usr/local/sbin/mpanel "$cp"
  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemd-run --quiet --collect --unit="minipainel-upd-$EPOCHSECONDS" /bin/bash "$cp" "$@" >/dev/null 2>&1
  else
    setsid /bin/bash "$cp" "$@" >/dev/null 2>&1 < /dev/null 9>&- &
  fi
}
cmd_update_start(){ [ -f "$UPD_RUN" ] && die "Já está a decorrer uma atualização."; upd_status "A preparar" painel; upd_spawn update-run "$@"; echo "Atualização iniciada. O progresso aparece na página Atualizações."; return 0; }
cmd_update_run(){
  local u d v rc snap log allow_unsigned=0
  [ "${1:-}" = "--allow-unsigned" ] && allow_unsigned=1
  exec 6>/run/minipainel-update.lock; flock -n 6 || die "Já está a decorrer uma atualização."
  u=$(upd_url); d="$UPD_DIR/novo"; rm -rf "$d"; install -d -m 700 "$d"
  upd_status "A descarregar a versão nova" painel
  local c; c=$(upd_get "$u/install.sh" "$d/install.sh" 300)
  [ "$c" = 200 ] || { rm -f "$d/install.sh"; upd_finish false "Atualização falhou: não foi possível descarregar o instalador de $u ($(upd_err "$c"))."; die "Falhou o download."; }
  [ "$(upd_get "$u/version.json" "$d/version.json" 60)" = 200 ] && jq -e . "$d/version.json" >/dev/null 2>&1 || rm -f "$d/version.json"
  [ "$(upd_get "$u/install.sh.sig" "$d/install.sh.sig" 60)" = 200 ] || rm -f "$d/install.sh.sig"
  v=$(jq -r '.version // ""' "$d/version.json" 2>/dev/null); [ -n "$v" ] || v=$(grep -m1 -oE '^MP_VERSION="[0-9]+(\.[0-9]+)+"' "$d/install.sh" | cut -d'"' -f2)
  [ -n "$v" ] || { upd_finish false "Atualização recusada: o ficheiro descarregado não parece ser o instalador do painel."; die "Instalador inválido."; }
  upd_status "A verificar a assinatura" painel
  upd_verify "$d"; rc=$?
  if [ "$rc" = 1 ]; then upd_finish false "Atualização para $v recusada: o ficheiro não corresponde ao version.json ou a assinatura é inválida."; die "Verificação falhou."; fi
  if [ "$rc" = 2 ] && [ "$allow_unsigned" = 0 ]; then upd_finish false "Atualização para $v recusada: não está configurada a chave pública das atualizações (ou confirma a instalação sem assinatura)."; die "Sem chave de assinatura."; fi
  bash -n "$d/install.sh" || { upd_finish false "Atualização para $v recusada: o instalador tem erros de sintaxe."; die "Instalador inválido."; }
  upd_status "A guardar uma cópia da versão atual ($MP_VERSION)" painel
  snap=$(upd_snapshot)
  upd_status "A instalar a versão $v" painel
  log="$UPD_DIR/instalacao-$v-$(date +%Y%m%d-%H%M%S).log"
  if bash "$d/install.sh" --panel-port "$PANEL_PORT" > "$log" 2>&1 && upd_health; then
    cp "$d/install.sh" "$UPD_DIR/install-$v.sh"
    upd_finish true "Painel atualizado de $MP_VERSION para $v."
    /usr/local/sbin/mpanel update-check >/dev/null 2>&1
    return 0
  fi
  upd_status "A instalação falhou; a repor a versão $MP_VERSION" painel
  upd_restore "$snap"
  if upd_health; then upd_finish false "A atualização para $v falhou e foi reposta a versão $MP_VERSION. Registo: $log"
  else upd_finish false "A atualização para $v falhou e a reposição automática não pôs o painel a responder. Na consola: tar -C / -xzpf $snap ; registo: $log"; fi
  return 1
}
cmd_update_rollback(){
  local f="${1:-}"
  [ -n "$f" ] || f=$(ls -1t "$UPD_SNAP"/*.tar.gz 2>/dev/null | head -1)
  case "$f" in "$UPD_SNAP"/*.tar.gz) ;; *) f="$UPD_SNAP/$f" ;; esac
  [ -f "$f" ] && [[ "$(basename "$f")" =~ ^[0-9]{8}-[0-9]{6}-v[0-9.]+\.tar\.gz$ ]] || die "Cópia não encontrada: $1"
  upd_restore "$f" || die "Falhou a reposição."
  jq -cn --arg t "$EPOCHSECONDS" --arg a "Reposta a cópia $(basename "$f")" '{ts:($t|tonumber), ip:"servidor", user:"atualização", action:$a, ok:true}' >> "$DATA/logs/audit.log"
  echo "Reposta a cópia $(basename "$f"). Atualiza a página do painel."
  return 0
}
cmd_update_key(){ # set <PEM em base64 numa linha> | clear
  case "${1:-}" in
    set) local pem tmp; tmp=$(mktemp); printf '%s' "${2:-}" | sed 's/\\n/\n/g' > "$tmp"
      grep -q 'BEGIN PUBLIC KEY' "$tmp" && openssl pkey -pubin -in "$tmp" -noout >/dev/null 2>&1 || { rm -f "$tmp"; die "Chave pública inválida (formato PEM, Ed25519)."; }
      [ "$(openssl pkey -pubin -in "$tmp" -noout -text 2>/dev/null | head -1 | grep -ci ed25519)" = 1 ] || { rm -f "$tmp"; die "A chave tem de ser Ed25519."; }
      install -m 644 "$tmp" "$UPD_PUB"; rm -f "$tmp"; echo "Chave pública das atualizações guardada." ;;
    clear) rm -f "$UPD_PUB"; echo "Chave pública das atualizações removida." ;;
    *) die "Usa: mpanel update-key set \"<PEM>\" | clear" ;;
  esac
  [ -f "$UPD_STATE" ] && upd_save "$UPD_STATE" "$(jq --argjson k "$([ -s "$UPD_PUB" ] && echo true || echo false)" '.key = $k' "$UPD_STATE")"
  return 0
}
upd_snaps_json(){ ls -1t "$UPD_SNAP"/*.tar.gz 2>/dev/null | head -n 10 | while read -r f; do printf '%s\t%s\n' "$(basename "$f")" "$(stat -c %s "$f")"; done | jq -R 'split("\t") | {file:.[0], size:(.[1]|tonumber)}' | jq -cs '.'; }

# --- atualizações do sistema operativo ---
cmd_os_check(){
  local list sec total reboot=false auto=false
  upd_status "A procurar atualizações do sistema" sistema
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    list=$(apt list --upgradable 2>/dev/null | awk -F'[/ ]' 'NR>1 && $1 != "" {sec = ($2 ~ /security/) ? "1" : "0"; print $1 "\t" $3 "\t" sec}')
    [ -f /var/run/reboot-required ] && reboot=true
    [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && auto=true
  else
    local secl; secl=$(dnf -q updateinfo list --security 2>/dev/null | awk '{print $3}' | sed -E 's/-[0-9][^-]*-[^-]*$//' | sort -u)
    list=$(dnf -q check-update 2>/dev/null | awk 'NF==3 && $1 ~ /\./ {n=$1; sub(/\.[^.]+$/, "", n); print n "\t" $2}' | while IFS=$'\t' read -r n v; do printf '%s\t%s\t%s\n' "$n" "$v" "$(grep -qxF "$n" <<<"$secl" && echo 1 || echo 0)"; done)
    command -v needs-restarting >/dev/null 2>&1 && { needs-restarting -r >/dev/null 2>&1 || reboot=true; }
    systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1 && auto=true
  fi
  total=$(printf '%s' "$list" | grep -c . ); sec=$(printf '%s\n' "$list" | awk -F'\t' '$3 == "1"' | grep -c .)
  upd_save "$OSU_STATE" "$(printf '%s\n' "$list" | grep . | jq -R 'split("\t") | {name:.[0], version:.[1], security:(.[2] == "1")}' | jq -cs \
     --arg t "$EPOCHSECONDS" --argjson r "$reboot" --argjson a "$auto" '{checked:($t|tonumber), total:length, security:(map(select(.security)) | length), reboot:$r, auto:$a, packages:(sort_by(if .security then 0 else 1 end) | .[0:300])}')"
  upd_status ""
  echo "$total atualizações do sistema disponíveis ($sec de segurança).$([ "$reboot" = true ] && echo " O servidor precisa de ser reiniciado.")"
  return 0
}
cmd_os_start(){ [ -f "$UPD_RUN" ] && die "Já está a decorrer uma atualização."; upd_status "A preparar" sistema; upd_spawn os-run "$@"; echo "Atualização do sistema iniciada em segundo plano."; return 0; }
cmd_os_run(){
  local only_sec=0 rc log
  [ "${1:-}" = "--security" ] && only_sec=1
  exec 6>/run/minipainel-update.lock; flock -n 6 || die "Já está a decorrer uma atualização."
  log="$UPD_DIR/sistema-$(date +%Y%m%d-%H%M%S).log"; install -d -m 700 "$UPD_DIR"
  upd_status "A instalar atualizações do sistema$([ "$only_sec" = 1 ] && echo ' (segurança)')" sistema
  if [ "$OS_FAMILY" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    local opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    if [ "$only_sec" = 1 ]; then
      local pk; pk=$(apt list --upgradable 2>/dev/null | awk -F'/' 'NR>1 && $2 ~ /security/ {print $1}')
      if [ -n "$pk" ]; then apt-get install "${opts[@]}" --only-upgrade $pk > "$log" 2>&1; rc=$?; else rc=0; echo "Sem atualizações de segurança." > "$log"; fi
    else apt-get upgrade "${opts[@]}" > "$log" 2>&1; rc=$?; fi
  else
    if [ "$only_sec" = 1 ]; then dnf -y upgrade --security > "$log" 2>&1; rc=$?; else dnf -y upgrade > "$log" 2>&1; rc=$?; fi
  fi
  # os serviços do painel continuam ativos?
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  local v; for v in $(php_installed); do systemctl is-active "$(php_service "$v")" >/dev/null 2>&1 || systemctl restart "$(php_service "$v")" >/dev/null 2>&1; done
  if [ "$rc" = 0 ]; then upd_finish true "Atualizações do sistema instaladas$([ "$only_sec" = 1 ] && echo ' (segurança)')."
  else upd_finish false "As atualizações do sistema terminaram com erro (código $rc). Registo: $log"; fi
  cmd_os_check >/dev/null 2>&1
  return 0
}
cmd_os_auto(){
  case "${1:-}" in
    on)
      if [ "$OS_FAMILY" = debian ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades >/dev/null 2>&1 || die "Falhou a instalação do unattended-upgrades."
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades
        printf '// IDDigital Hosting — só atualizações de segurança, sem reiniciar sozinho\nUnattended-Upgrade::Automatic-Reboot "false";\nUnattended-Upgrade::Remove-Unused-Dependencies "true";\nDpkg::Options { "--force-confdef"; "--force-confold"; };\n' > /etc/apt/apt.conf.d/52minipainel-unattended
        systemctl enable --now unattended-upgrades >/dev/null 2>&1
      else
        dnf install -y -q dnf-automatic >/dev/null 2>&1 || die "Falhou a instalação do dnf-automatic."
        sed -i 's/^upgrade_type *=.*/upgrade_type = security/; s/^apply_updates *=.*/apply_updates = yes/' /etc/dnf/automatic.conf
        systemctl enable --now dnf-automatic.timer >/dev/null 2>&1
      fi
      echo "Atualizações de segurança automáticas ativadas (o servidor não é reiniciado sozinho)." ;;
    off)
      if [ "$OS_FAMILY" = debian ]; then printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
      else systemctl disable --now dnf-automatic.timer >/dev/null 2>&1; fi
      echo "Atualizações automáticas desativadas." ;;
    *) die "Usa: mpanel os-auto on|off" ;;
  esac
  [ -f "$OSU_STATE" ] && upd_save "$OSU_STATE" "$(jq --argjson a "$([ "$1" = on ] && echo true || echo false)" '.auto = $a' "$OSU_STATE")"
  return 0
}
cmd_reboot(){ echo "O servidor vai reiniciar dentro de 1 minuto."; jq -cn --arg t "$EPOCHSECONDS" '{ts:($t|tonumber), ip:"servidor", user:"sistema", action:"Reinício do servidor pedido", ok:true}' >> "$DATA/logs/audit.log"; shutdown -r +1 "Reinício pedido no IDDigital Hosting" >/dev/null 2>&1 || ( sleep 60; reboot ) >/dev/null 2>&1 & return 0; }

write_auth(){ # mantém a verificação em dois passos ao mudar a password
  auth_update --arg u "$1" --arg h "$2" '.user = $u | .hash = $h'
}

cmd_passwd(){
  local p1 p2 rnd=0 h
  if [ "${1:-}" = "--random" ]; then
    rnd=1; p1=$(gen_pass 16)
  else
    [ -t 0 ] || die "Sem terminal interativo; usa 'mpanel passwd --random'."
    read -rsp "Nova password do painel: " p1; echo
    read -rsp "Repetir: " p2; echo
    [ "$p1" = "$p2" ] || die "As passwords não coincidem."
    [ ${#p1} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."
  fi
  h=$(printf '%s' "$p1" | "$(php_cli "$PANEL_PHP")" -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT);')
  [[ "$h" == '$2y$'* ]] || die "Falha ao gerar o hash da password."
  write_auth "$PANEL_USER" "$h" || die "Falha ao gravar a password."
  echo "Password do painel alterada (utilizador: $PANEL_USER)."
  if [ "$rnd" = 1 ]; then echo "Nova password: $p1"; fi
  return 0
}

cmd_panel_hash(){
  local h="${1:-}" re='^\$2y\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
  [[ "$h" =~ $re ]] || die "Hash inválido."
  write_auth "$PANEL_USER" "$h" || die "Falha ao gravar a password."
  echo "Password do painel alterada."
  return 0
}

# Valida um valor JSON do estado; se for inválido usa o valor por omissão e regista qual foi (para diagnóstico).
jv(){ # nome valor omissão
  if [ -n "$2" ] && jq . >/dev/null 2>&1 <<<"$2"; then printf '%s' "$2"; return 0; fi
  printf '%s %s: valor inválido: %s\n' "$(date '+%F %T')" "$1" "$(printf '%s' "$2" | head -c 300 | tr '\n' ' ')" >> "$DATA/logs/state-errors.log" 2>/dev/null
  echo "AVISO: estado do painel: o campo '$1' estava inválido e foi ignorado (detalhes em $DATA/logs/state-errors.log)." >&2
  printf '%s' "$3"
}
# ============================ FTP / FTPS / SFTP ==============================
FTP_CONF=/etc/minipainel/ftp.conf          # PLAIN=0|1, PASV_IP=, PASV=30000:30100
PF_PASSWD=/etc/pure-ftpd/pureftpd.passwd
PF_PDB=/etc/pure-ftpd/pureftpd.pdb
SFTP_ROOT=/srv/sftp
ftp_get(){ local v; v=$(grep -m1 "^$1=" "$FTP_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
ftp_set(){ touch "$FTP_CONF"; chmod 600 "$FTP_CONF"; if grep -q "^$1=" "$FTP_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$FTP_CONF"; else echo "$1=$2" >> "$FTP_CONF"; fi; }
ftp_svc(){ systemctl list-unit-files pure-ftpd.service >/dev/null 2>&1 && echo pure-ftpd || echo pure-ftpd; }
ssh_svc(){ if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh.service'; then echo ssh; else echo sshd; fi; }
ftp_installed(){ command -v pure-pw >/dev/null 2>&1; }
pf_set(){ # opção valor (Debian: um ficheiro por opção; EL: pure-ftpd.conf)
  if [ -d /etc/pure-ftpd/conf ]; then printf '%s\n' "$2" > "/etc/pure-ftpd/conf/$1"
  else
    local f=/etc/pure-ftpd/pure-ftpd.conf
    if grep -qE "^#?\s*$1\s" "$f"; then sed -i -E "s|^#?\s*$1\s.*|$1 $2|" "$f"; else echo "$1 $2" >> "$f"; fi
  fi
}
ftp_cert(){ # certificado para o FTPS (o do servidor de correio, do domínio do painel ou o autoassinado)
  local c pem
  c=$(cert_files mp-mail 2>/dev/null || cert_files mp-painel 2>/dev/null || echo "/etc/minipainel/ssl/panel.crt /etc/minipainel/ssl/panel.key")
  if [ -d /etc/pure-ftpd/conf ]; then pem=/etc/ssl/private/pure-ftpd.pem; else pem=/etc/pki/pure-ftpd/pure-ftpd.pem; install -d -m 700 /etc/pki/pure-ftpd; fi
  cat "${c##* }" "${c%% *}" > "$pem.tmp" && chmod 600 "$pem.tmp" && mv -f "$pem.tmp" "$pem"
}
ftp_fw(){
  local r; r=$(ftp_get PASV 30000:30100)
  fw_open 21 >/dev/null 2>&1
  if systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd -q --permanent --add-port="${r/:/-}/tcp" >/dev/null 2>&1; firewall-cmd -q --add-port="${r/:/-}/tcp" >/dev/null 2>&1
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then ufw allow "$r/tcp" >/dev/null 2>&1; fi
  return 0
}
ftp_config(){ # (re)aplica a configuração do Pure-FTPd e do SFTP
  local r ip
  r=$(ftp_get PASV 30000:30100); ip=$(ftp_get PASV_IP)
  pf_set ChrootEveryone yes; pf_set NoAnonymous yes; pf_set PureDB "$PF_PDB"; pf_set MinUID 100
  pf_set PassivePortRange "${r/:/ }"; pf_set DontResolve yes; pf_set MaxClientsPerIP 8; pf_set MaxClientsNumber 50
  if [ -d /etc/pure-ftpd/conf ]; then pf_set Umask "137 027"; else pf_set Umask "137:027"; fi
  pf_set ProhibitDotFilesWrite no; pf_set ProhibitDotFilesRead no
  pf_set TLS "$([ "$(ftp_get PLAIN 0)" = 1 ] && echo 1 || echo 2)"
  if [ -n "$ip" ]; then pf_set ForcePassiveIP "$ip"; else
    if [ -d /etc/pure-ftpd/conf ]; then rm -f /etc/pure-ftpd/conf/ForcePassiveIP; else sed -i -E 's|^ForcePassiveIP .*|# ForcePassiveIP|' /etc/pure-ftpd/pure-ftpd.conf; fi
  fi
  if [ -d /etc/pure-ftpd/auth ]; then
    rm -f /etc/pure-ftpd/auth/*unix /etc/pure-ftpd/auth/*pam /etc/pure-ftpd/auth/*PAM /etc/pure-ftpd/auth/*Unix 2>/dev/null
    ln -sfn ../conf/PureDB /etc/pure-ftpd/auth/50pure
    pf_set UnixAuthentication no; pf_set PAMAuthentication no
  else
    sed -i -E 's|^#?\s*PAMAuthentication\s.*|PAMAuthentication no|; s|^#?\s*UnixAuthentication\s.*|UnixAuthentication no|' /etc/pure-ftpd/pure-ftpd.conf
  fi
  ftp_cert
  touch "$PF_PASSWD"; chmod 600 "$PF_PASSWD"; pure-pw mkdb "$PF_PDB" -f "$PF_PASSWD" >/dev/null 2>&1
  # SFTP: utilizadores do grupo mp-sftp ficam fechados na pasta do site e só podem transferir ficheiros
  getent group mp-sftp >/dev/null 2>&1 || groupadd -r mp-sftp
  install -d -o root -g root -m 755 "$SFTP_ROOT"
  install -d -m 755 /etc/ssh/sshd_config.d
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  cat > /etc/ssh/sshd_config.d/10-minipainel-sftp.conf <<'EOF'
# IDDigital Hosting — SFTP dos sites (gerado pelo painel; não editar à mão)
Match Group mp-sftp
    ChrootDirectory /srv/sftp/%u
    ForceCommand internal-sftp -d /site -u 0027
    PasswordAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
Match all
EOF
  chmod 644 /etc/ssh/sshd_config.d/10-minipainel-sftp.conf
  if sshd -t 2>/dev/null; then systemctl reload "$(ssh_svc)" >/dev/null 2>&1
  else rm -f /etc/ssh/sshd_config.d/10-minipainel-sftp.conf; warn "A configuração do SSH ficou inválida; o SFTP não foi ativado."; fi
  systemctl enable "$(ftp_svc)" >/dev/null 2>&1; systemctl restart "$(ftp_svc)" >/dev/null 2>&1
  ftp_fw
}
ftp_install(){
  ftp_installed && return 0
  echo "A instalar o Pure-FTPd..."
  if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q pure-ftpd >/dev/null 2>&1
  else dnf install -y -q pure-ftpd >/dev/null 2>&1; fi
  ftp_installed || die "Falhou a instalação do Pure-FTPd."
  [ -f "$FTP_CONF" ] || printf 'PLAIN=0\nPASV=30000:30100\nPASV_IP=\n' > "$FTP_CONF"
  ftp_config
}
ftp_bind(){ # site on|off — a pasta do site aparece dentro da prisão do SFTP
  local n=$1 u="mp_$1" d="$SFTP_ROOT/mp_$1"
  if [ "$2" = on ]; then
    install -d -o root -g root -m 755 "$d" "$d/site"
    grep -q " $d/site " /etc/fstab || echo "$WWW_ROOT/$n $d/site none bind,nofail 0 0 # minipainel-sftp" >> /etc/fstab
    mountpoint -q "$d/site" || mount --bind "$WWW_ROOT/$n" "$d/site"
    usermod -aG mp-sftp "$u" >/dev/null 2>&1
  else
    gpasswd -d "$u" mp-sftp >/dev/null 2>&1
    mountpoint -q "$d/site" && umount "$d/site"
    sed -i "\\| $d/site |d" /etc/fstab
    [ -d "$d/site" ] && rmdir "$d/site" 2>/dev/null; [ -d "$d" ] && rmdir "$d" 2>/dev/null
  fi
  return 0
}
cmd_site_ftp(){ # site --hash H | --password P | --off
  local n="${1:-}" h="" pw="" off=0 u uid gid
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  while [ $# -gt 0 ]; do
    case "$1" in
      --hash) h="${2:-}"; shift 2 || shift ;;
      --password) pw="${2:-}"; shift 2 || shift ;;
      --off) off=1; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  u="mp_$n"
  if [ "$off" = 1 ]; then
    [ -f "$PF_PASSWD" ] && { grep -v "^$n:" "$PF_PASSWD" > "$PF_PASSWD.tmp"; mv -f "$PF_PASSWD.tmp" "$PF_PASSWD"; chmod 600 "$PF_PASSWD"; pure-pw mkdb "$PF_PDB" -f "$PF_PASSWD" >/dev/null 2>&1; }
    ftp_bind "$n" off
    usermod -p '!' "$u" >/dev/null 2>&1
    site_set "$n" FTP 0
    echo "Acesso FTP/SFTP do site $n desativado."
    return 0
  fi
  if [ -n "$pw" ]; then [ ${#pw} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."; h=$(printf '%s' "$pw" | mail_hash_stdin); fi
  local gen=""
  if [ -z "$h" ]; then gen=$(gen_pass 16); h=$(printf '%s' "$gen" | mail_hash_stdin); fi
  valid_mailhash "$h" || die "Hash de password inválido."
  ftp_install
  uid=$(id -u "$u"); gid=$(id -g "$u")
  touch "$PF_PASSWD"
  { grep -v "^$n:" "$PF_PASSWD"; printf '%s:%s:%s:%s::%s/./::::::::::::\n' "$n" "$h" "$uid" "$gid" "$WWW_ROOT/$n"; } > "$PF_PASSWD.tmp"
  mv -f "$PF_PASSWD.tmp" "$PF_PASSWD"; chmod 600 "$PF_PASSWD"
  pure-pw mkdb "$PF_PDB" -f "$PF_PASSWD" >/dev/null 2>&1 || die "Não foi possível atualizar a base de utilizadores do FTP."
  printf '%s:%s\n' "$u" "$h" | chpasswd -e >/dev/null 2>&1 || die "Não foi possível definir a password do SFTP."
  ftp_bind "$n" on
  site_set "$n" FTP 1
  local host; host=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "Acesso ao site $n ativo."
  echo "FTPS: servidor $host, porta 21, utilizador $n (FTP com TLS explícito$([ "$(ftp_get PLAIN 0)" = 1 ] && echo '; FTP simples também permitido'))."
  echo "SFTP: servidor $host, porta 22, utilizador $u."
  [ -n "$gen" ] && echo "Password: $gen"
  return 0
}
cmd_ftp_settings(){
  local re_ip='^[0-9.]+$'
  while [ $# -gt 0 ]; do
    case "$1" in
      --plain) case "${2:-}" in on) ftp_set PLAIN 1 ;; off) ftp_set PLAIN 0 ;; *) die "--plain on|off" ;; esac; shift 2 || shift ;;
      --pasv-ip) [ "${2:-}" = none ] && ftp_set PASV_IP "" || { [[ "${2:-}" =~ $re_ip ]] && fw_ip_valid "$2" || die "IP inválido."; ftp_set PASV_IP "$2"; }; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  ftp_installed && ftp_config
  echo "Definições do FTP guardadas."
  return 0
}

# ============================ phpMyAdmin: tempos e limites ===================
PMA_SET=/etc/minipainel/pma.conf
pma_get(){ local v; v=$(grep -m1 "^$1=" "$PMA_SET" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
pma_settings_apply(){ # aplica pma.conf ao config.inc.php, ao pool PHP e ao nginx
  local s e u pool
  s=$(pma_get SESSION 120); e=$(pma_get EXEC 600); u=$(pma_get UPLOAD 512)
  if [ -d "$PMA_DIR" ] && [ -f "$PMA_CONF" ]; then
    { cat "$PMA_CONF"; printf "\n// IDDigital Hosting — Definições → phpMyAdmin\n\$cfg['LoginCookieValidity'] = %d;\n\$cfg['ExecTimeLimit'] = %d;\n" $(( s * 60 )) "$e"; } > "$PMA_DIR/config.inc.php"
    chown root:"$PMA_USER" "$PMA_DIR/config.inc.php"; chmod 640 "$PMA_DIR/config.inc.php"
  fi
  pool=$(php_pool_dir "$PANEL_PHP")/minipainel-pma.conf
  if [ -f "$pool" ]; then
    sed -i -E "s|^php_admin_value\[upload_max_filesize\] = .*|php_admin_value[upload_max_filesize] = ${u}M|; s|^php_admin_value\[post_max_size\] = .*|php_admin_value[post_max_size] = ${u}M|;
               s|^php_admin_value\[max_execution_time\] = .*|php_admin_value[max_execution_time] = $e|; s|^php_admin_value\[max_input_time\] = .*|php_admin_value[max_input_time] = $e|;
               s|^php_admin_value\[session.gc_maxlifetime\] = .*|php_admin_value[session.gc_maxlifetime] = $(( s * 60 ))|; s|^request_terminate_timeout = .*|request_terminate_timeout = $(( e + 60 ))s|" "$pool"
    apply_php "$PANEL_PHP" >/dev/null 2>&1
  fi
  if [ -f /etc/nginx/minipainel/panel.inc ]; then
    sed -i -E "/location \^~ \/phpmyadmin\//,/^    \}/{s|client_max_body_size [0-9]+M;|client_max_body_size ${u}M;|; s|fastcgi_read_timeout [0-9]+s;|fastcgi_read_timeout $(( e + 60 ))s;|}" /etc/nginx/minipainel/panel.inc
    apply_nginx >/dev/null 2>&1
  fi
}
cmd_pma_settings(){
  local s e u re='^[0-9]{1,5}$'
  s=$(pma_get SESSION 120); e=$(pma_get EXEC 600); u=$(pma_get UPLOAD 512)
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) s="${2:-}"; shift 2 || shift ;;
      --exec) e="${2:-}"; shift 2 || shift ;;
      --upload) u="${2:-}"; shift 2 || shift ;;
      --apply) shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$s" =~ $re ]] && [ "$s" -ge 5 ] && [ "$s" -le 1440 ] || die "Sessão: entre 5 e 1440 minutos."
  [[ "$e" =~ $re ]] && [ "$e" -ge 30 ] && [ "$e" -le 7200 ] || die "Tempo por operação: entre 30 e 7200 segundos."
  [[ "$u" =~ $re ]] && [ "$u" -ge 8 ] && [ "$u" -le 4096 ] || die "Importação: entre 8 e 4096 MB."
  printf 'SESSION=%s\nEXEC=%s\nUPLOAD=%s\n' "$s" "$e" "$u" > "$PMA_SET"; chmod 600 "$PMA_SET"
  pma_settings_apply
  echo "phpMyAdmin: sessão de $s min, operações até $e s, importações até $u MB."
  return 0
}

# ============================ PROTEÇÃO CONTRA FORÇA BRUTA ====================
PROT_CONF=/etc/minipainel/protect.conf
pget(){ local v; v=$(grep -m1 "^$1=" "$PROT_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
cmd_protect_settings(){
  local ssh sshf panf authf win b1 b2 b3 re='^[0-9]{1,4}$' rd='^([0-9]{1,4}[mhd]|perm)$'
  ssh=$(pget SSH 1); sshf=$(pget SSH_FAILS 5); panf=$(pget PANEL_FAILS 10); authf=$(pget AUTH_FAILS "$(mail_get AUTH_FAILS 10)")
  win=$(pget WINDOW 10); b1=$(pget BAN1 1h); b2=$(pget BAN2 24h); b3=$(pget BAN3 7d)
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh) case "${2:-}" in on) ssh=1 ;; off) ssh=0 ;; *) die "--ssh on|off" ;; esac; shift 2 || shift ;;
      --ssh-fails) sshf="${2:-}"; shift 2 || shift ;;
      --panel-fails) panf="${2:-}"; shift 2 || shift ;;
      --auth-fails) authf="${2:-}"; shift 2 || shift ;;
      --window) win="${2:-}"; shift 2 || shift ;;
      --ban1) b1="${2:-}"; shift 2 || shift ;;
      --ban2) b2="${2:-}"; shift 2 || shift ;;
      --ban3) b3="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  for v in "$sshf" "$panf" "$authf"; do [[ "$v" =~ $re ]] && [ "$v" -ge 3 ] && [ "$v" -le 100 ] || die "Número de falhas entre 3 e 100."; done
  [[ "$win" =~ $re ]] && [ "$win" -ge 1 ] && [ "$win" -le 1440 ] || die "Janela entre 1 e 1440 minutos."
  for v in "$b1" "$b2" "$b3"; do [[ "$v" =~ $rd ]] || die "Duração inválida: $v (ex.: 15m, 1h, 24h, 7d ou perm)."; done
  printf 'SSH=%s\nSSH_FAILS=%s\nPANEL_FAILS=%s\nAUTH_FAILS=%s\nWINDOW=%s\nBAN1=%s\nBAN2=%s\nBAN3=%s\n' "$ssh" "$sshf" "$panf" "$authf" "$win" "$b1" "$b2" "$b3" > "$PROT_CONF"
  chmod 600 "$PROT_CONF"
  mail_on && mail_set AUTH_FAILS "$authf"
  echo "Proteção: SSH $([ "$ssh" = 1 ] && echo "ativa ($sshf falhas)" || echo desligada), painel $panf falhas, email/FTP $authf falhas, em $win min; bloqueio $b1, reincidentes $b2, a partir da 3.ª vez $b3."
  return 0
}

# ============================ DNS AUTORITATIVO (NSD) =========================
DNS_CONF=/etc/minipainel/dns.conf           # ENABLED, NS1, NS2, IP, IP6, HOSTMASTER
DNS_DIR=/etc/minipainel/dns                 # <zona>.json
NSD_ZONES=/etc/nsd/zones
dns_get(){ local v; v=$(grep -m1 "^$1=" "$DNS_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
dns_set(){ touch "$DNS_CONF"; chmod 600 "$DNS_CONF"; if grep -q "^$1=" "$DNS_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$DNS_CONF"; else echo "$1=$2" >> "$DNS_CONF"; fi; }
dns_on(){ [ "$(dns_get ENABLED 0)" = 1 ]; }
dns_need(){ dns_on || die "O DNS não está ativo. Ativa-o na página DNS ou com: mpanel dns-enable --ns1 ns1.dominio.pt --ns2 ns2.dominio.pt"; }
dns_zone_json(){ echo "$DNS_DIR/$1.json"; }
dns_load(){ local f; f=$(dns_zone_json "$1"); if [ -s "$f" ]; then cat "$f"; else echo '{"serial":0,"records":[]}'; fi; }
dns_save(){ install -d -m 700 "$DNS_DIR"; printf '%s\n' "$2" | jq '.' > "$(dns_zone_json "$1").tmp" && chmod 600 "$(dns_zone_json "$1").tmp" && mv -f "$(dns_zone_json "$1").tmp" "$(dns_zone_json "$1")"; }
dns_zones(){ ls -1 "$DNS_DIR"/*.json 2>/dev/null | sed 's|.*/||; s|\.json$||' | sort; }
dns_fqdn(){ case "$1" in *.) echo "$1" ;; *.*) echo "$1." ;; *) echo "$1" ;; esac; }   # valores com domínio completo levam ponto final
dns_serial(){ local old=$1 d; d=$(date +%Y%m%d); if [ "${old:0:8}" = "$d" ]; then echo $(( old + 1 )); else echo "${d}01"; fi; }
dns_ips(){ ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
dns_txt_quote(){ # divide em pedaços de 255 caracteres entre aspas
  local v=$1 out="" chunk
  v=${v//\\/\\\\}; v=${v//\"/\\\"}
  while [ -n "$v" ]; do chunk=${v:0:250}; v=${v:250}; out+="\"$chunk\" "; done
  echo "${out% }"
}
dns_write_zone(){ # gera o ficheiro de zona, verifica-o e só então o ativa
  local z=$1 j f tmp ns1 ns2 hm serial
  j=$(dns_load "$z"); f="$NSD_ZONES/$z.zone"; tmp=$(mktemp)
  ns1=$(dns_get NS1); ns2=$(dns_get NS2); hm=$(dns_get HOSTMASTER "hostmaster.$z"); hm=${hm/@/.}
  serial=$(jq -r '.serial' <<<"$j")
  {
    printf '; IDDigital Hosting — zona %s (gerada pelo painel; não editar à mão)\n$ORIGIN %s.\n$TTL 3600\n' "$z" "$z"
    printf '@ IN SOA %s %s ( %s 10800 3600 1209600 3600 )\n' "$(dns_fqdn "$ns1")" "$(dns_fqdn "$hm")" "$serial"
    printf '@ IN NS %s\n@ IN NS %s\n' "$(dns_fqdn "$ns1")" "$(dns_fqdn "$ns2")"
    jq -r '.records[] | [.name, (.ttl|tostring), .type, (.prio // 0 | tostring), .value] | @tsv' <<<"$j" | while IFS=$'\t' read -r n t ty pr v; do
      case "$ty" in
        TXT) printf '%s %s IN TXT %s\n' "$n" "$t" "$(dns_txt_quote "$v")" ;;
        MX) printf '%s %s IN MX %s %s\n' "$n" "$t" "$pr" "$(dns_fqdn "$v")" ;;
        SRV) printf '%s %s IN SRV %s %s %s %s\n' "$n" "$t" "$pr" "${v%% *}" "$(echo "$v" | awk '{print $2}')" "$(dns_fqdn "${v##* }")" ;;
        CNAME|NS) printf '%s %s IN %s %s\n' "$n" "$t" "$ty" "$(dns_fqdn "$v")" ;;
        CAA) printf '%s %s IN CAA %s\n' "$n" "$t" "$v" ;;
        *) printf '%s %s IN %s %s\n' "$n" "$t" "$ty" "$v" ;;
      esac
    done
  } > "$tmp"
  local errf; errf=$(mktemp)
  if ! nsd-checkzone "$z" "$tmp" >"$errf" 2>&1; then
    local e; e=$(tail -n 3 "$errf" | tr '\n' ' '); rm -f "$tmp" "$errf"
    echo "Zona $z inválida: $e" >&2; return 1
  fi
  rm -f "$errf"
  install -d -o root -g nsd -m 750 "$NSD_ZONES"
  install -o root -g nsd -m 640 "$tmp" "$f"; rm -f "$tmp"
  return 0
}
dns_apply(){ # lista de zonas do NSD e recarga
  local z
  local before after
  before=$(md5sum /etc/nsd/minipainel-zones.conf 2>/dev/null | awk '{print $1}')
  { echo "# IDDigital Hosting — zonas (gerado pelo painel)"; for z in $(dns_zones); do printf 'zone:\n    name: "%s"\n    zonefile: "%s/%s.zone"\n' "$z" "$NSD_ZONES" "$z"; done; } > /etc/nsd/minipainel-zones.conf
  chmod 644 /etc/nsd/minipainel-zones.conf
  after=$(md5sum /etc/nsd/minipainel-zones.conf | awk '{print $1}')
  nsd-checkconf /etc/nsd/nsd.conf >/dev/null 2>&1 || { echo "Configuração do NSD inválida." >&2; return 1; }
  if [ "$before" != "$after" ]; then
    # zonas acrescentadas ou retiradas: o NSD só as lê ao arrancar (corte inferior a 1 segundo)
    systemctl restart nsd >/dev/null 2>&1 || { pkill -x nsd; sleep 1; nsd -c /etc/nsd/nsd.conf >/dev/null 2>&1; }
  else
    systemctl reload nsd >/dev/null 2>&1 || pkill -HUP -x nsd 2>/dev/null
  fi
  return 0
}
dns_bump(){ # zona json -> grava com serial novo, gera e ativa (repõe o anterior se falhar)
  local z=$1 j=$2 old
  old=$(dns_load "$z")
  j=$(jq --argjson s "$(dns_serial "$(jq -r '.serial' <<<"$old")")" '.serial = $s' <<<"$j")
  dns_save "$z" "$j"
  if ! dns_write_zone "$z"; then dns_save "$z" "$old"; return 1; fi
  dns_apply
}
dns_auto_records(){ # registos automáticos da zona: sites, email e nameservers que pertencem a ela
  local z=$1 ip ip6 n d rel recs="[]" h
  ip=$(dns_get IP); ip6=$(dns_get IP6)
  add(){ recs=$(jq -c --arg n "$1" --arg t "$2" --arg v "$3" --argjson p "${4:-0}" '. + [{name:$n, type:$t, value:$v, ttl:3600, prio:$p, auto:true}]' <<<"$recs"); }
  rel(){ if [ "$1" = "$z" ]; then echo "@"; else echo "${1%."$z"}"; fi; }
  add "@" A "$ip"; [ -n "$ip6" ] && add "@" AAAA "$ip6"
  add "www" A "$ip"; [ -n "$ip6" ] && add "www" AAAA "$ip6"
  for h in "$(dns_get NS1)" "$(dns_get NS2)"; do case "$h" in *."$z") add "$(rel "$h")" A "$ip" ;; esac; done
  for n in $(site_names); do for d in $(site_get "$n" DOMAINS); do
    case "$d" in "$z"|"www.$z") ;; *."$z") add "$(rel "$d")" A "$ip" ;; esac
  done; done
  if mail_on; then
    h=$(mail_get HOST)
    case "$h" in *."$z") add "$(rel "$h")" A "$ip" ;; esac
    if [ "$(mail_data | jq --arg d "$z" '.domains | has($d)')" = true ]; then
      add "@" MX "$h" 10
      add "@" TXT "v=spf1 mx a:$h ~all"
      [ -n "$(mail_dkim_value "$z")" ] && add "mp._domainkey" TXT "$(mail_dkim_value "$z")"
      add "_dmarc" TXT "v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@$z"
    fi
  fi
  add "@" CAA '0 issue "letsencrypt.org"'
  jq -c 'unique_by([.name, .type, .value])' <<<"$recs"
}
dns_sync_zone(){ # substitui os registos automáticos pelos atuais (mantém os manuais)
  local z=$1 j auto
  j=$(dns_load "$z"); auto=$(dns_auto_records "$z")
  j=$(jq --argjson a "$auto" '.records = ([.records[] | select(.auto != true)] + ($a | to_entries | map(.value + {id: ("auto" + (.key | tostring))})))' <<<"$j")
  dns_bump "$z" "$j"
}
dns_autosync(){ # chamado quando muda um site ou o email: atualiza as zonas afetadas
  dns_on || return 0
  local z; for z in $(dns_zones); do dns_sync_zone "$z" >/dev/null 2>&1; done
  return 0
}

cmd_dns_enable(){
  local ns1="" ns2="" ip="" ip6="" hm="" a re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'
  while [ $# -gt 0 ]; do
    case "$1" in
      --ns1) ns1="${2:-}"; shift 2 || shift ;; --ns2) ns2="${2:-}"; shift 2 || shift ;;
      --ip) ip="${2:-}"; shift 2 || shift ;; --ip6) ip6="${2:-}"; shift 2 || shift ;;
      --hostmaster) hm="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  ns1=${ns1:-$(dns_get NS1)}; ns2=${ns2:-$(dns_get NS2)}
  [[ "$ns1" =~ $re ]] && [[ "$ns2" =~ $re ]] && [ "$ns1" != "$ns2" ] || die "Indica dois nameservers diferentes (ex.: --ns1 ns1.host.iddigital.pt --ns2 ns2.host.iddigital.pt)."
  ip=${ip:-$(dns_get IP)}; [ -n "$ip" ] || ip=$(curl -s4 -m 6 https://api.ipify.org 2>/dev/null)
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Indica o IP público do servidor com --ip."
  [ -z "$ip6" ] || fw_ip_valid "$ip6" || die "IPv6 inválido."
  hm=${hm:-$(dns_get HOSTMASTER "$(srv_get EMAIL '')")}; [ -n "$hm" ] || hm="hostmaster@${ns1#*.}"
  if ! command -v nsd >/dev/null 2>&1; then
    echo "A instalar o NSD..."
    if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q nsd >/dev/null 2>&1; else dnf install -y -q nsd >/dev/null 2>&1; fi
    command -v nsd >/dev/null 2>&1 || die "Falhou a instalação do NSD."
  fi
  dns_set ENABLED 1; dns_set NS1 "$ns1"; dns_set NS2 "$ns2"; dns_set IP "$ip"; dns_set IP6 "$ip6"; dns_set HOSTMASTER "$hm"
  install -d -m 700 "$DNS_DIR"; install -d -o root -g nsd -m 750 "$NSD_ZONES"
  [ -f /etc/nsd/nsd.conf.minipainel-orig ] || cp -p /etc/nsd/nsd.conf /etc/nsd/nsd.conf.minipainel-orig 2>/dev/null
  {
    echo "# IDDigital Hosting — servidor DNS autoritativo (gerado pelo painel; não editar à mão)"
    echo "# Só responde pelas zonas do painel; nunca faz resolução recursiva."
    echo "server:"
    for a in $(dns_ips); do echo "    ip-address: $a"; done
    echo "    hide-version: yes"
    echo "    refuse-any: yes"
    echo "    verbosity: 1"
    echo "    round-robin: no"
    echo "remote-control:"
    echo "    control-enable: no"
    echo 'include: "/etc/nsd/minipainel-zones.conf"'
  } > /etc/nsd/nsd.conf
  chmod 644 /etc/nsd/nsd.conf
  touch /etc/nsd/minipainel-zones.conf
  local z; for z in $(dns_zones); do dns_write_zone "$z" || warn "Zona $z com erros."; done
  dns_apply || die "Não foi possível ativar o NSD."
  systemctl enable --now nsd >/dev/null 2>&1; systemctl restart nsd >/dev/null 2>&1
  fw_open 53 >/dev/null 2>&1
  if systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd -q --permanent --add-service=dns; firewall-cmd -q --add-service=dns
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then ufw allow 53 >/dev/null 2>&1; fi
  echo "DNS ativo: $ns1 e $ns2 → $ip."
  echo "No registador do domínio de $ns1 cria os registos de cola (glue): $ns1 e $ns2 com o IP $ip."
  return 0
}
dns_valid_rec(){ # nome tipo valor prioridade
  local n=$1 t=$2 v=$3 re_n='^(@|\*|(\*\.)?[a-z0-9_]([a-z0-9_-]{0,62})(\.[a-z0-9_]([a-z0-9_-]{0,62}))*)$'
  [[ "$n" =~ $re_n ]] || { echo "Nome inválido: $n (usa @ para o domínio, ou o nome sem o domínio, ex.: www)"; return 1; }
  [ ${#v} -le 2000 ] && [[ "$v" != *[$'\n\r']* ]] || { echo "Valor inválido."; return 1; }
  case "$t" in
    A) [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "IPv4 inválido."; return 1; } ;;
    AAAA) [[ "$v" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$v" == *:* ]] || { echo "IPv6 inválido."; return 1; } ;;
    CNAME|NS|MX) [[ "$v" =~ ^([a-z0-9_]([a-z0-9_-]{0,62})\.)*[a-z0-9_]([a-z0-9_-]{0,62})\.?$ ]] || { echo "Destino inválido: $v"; return 1; } ;;
    TXT) [ -n "$v" ] || { echo "O texto não pode ficar vazio."; return 1; } ;;
    SRV) [[ "$v" =~ ^[0-9]{1,5}\ [0-9]{1,5}\ [a-z0-9._-]+\.?$ ]] || { echo "SRV: usa 'peso porta destino' (ex.: 5 5060 sip.dominio.pt)."; return 1; } ;;
    CAA) [[ "$v" =~ ^[0-9]{1,3}\ (issue|issuewild|iodef)\ \"[^\"]*\"$ ]] || { echo "CAA: usa ex. 0 issue \"letsencrypt.org\""; return 1; } ;;
    *) echo "Tipo não suportado: $t (A, AAAA, CNAME, MX, TXT, NS, SRV, CAA)"; return 1 ;;
  esac
  [ "$t" = CNAME ] && [ "$n" = "@" ] && { echo "Não é possível um CNAME no próprio domínio (@)."; return 1; }
  return 0
}
cmd_dns_zone_add(){
  local z="${1:-}"; dns_need; z=$(printf '%s' "$z" | tr 'A-Z' 'a-z')
  valid_domain "$z" || die "Domínio inválido: $z"
  [ -f "$(dns_zone_json "$z")" ] && die "A zona $z já existe."
  dns_save "$z" '{"serial":0,"records":[]}'
  dns_sync_zone "$z" || { rm -f "$(dns_zone_json "$z")"; die "Não foi possível criar a zona."; }
  echo "Zona $z criada com os registos automáticos (sites, email e nameservers). No registador, aponta os nameservers para $(dns_get NS1) e $(dns_get NS2)."
  return 0
}
cmd_dns_zone_del(){
  local z="${1:-}"; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  rm -f "$(dns_zone_json "$z")" "$NSD_ZONES/$z.zone"; dns_apply
  echo "Zona $z apagada."; return 0
}
cmd_dns_rec_add(){ # zona nome tipo valor [--ttl N] [--prio N]
  local z="${1:-}" n="${2:-}" t="${3:-}" v="${4:-}" ttl=3600 pr=10 j why
  dns_need; [ $# -ge 4 ] && shift 4
  while [ $# -gt 0 ]; do case "$1" in --ttl) ttl="${2:-}"; shift 2 || shift ;; --prio) pr="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  n=$(printf '%s' "$n" | tr 'A-Z' 'a-z'); n=${n%."$z"}; n=${n%.}; [ "$n" = "$z" ] && n="@"; [ -n "$n" ] || n="@"
  t=$(printf '%s' "$t" | tr 'a-z' 'A-Z')
  [[ "$ttl" =~ ^[0-9]{2,6}$ ]] || die "TTL inválido."; [[ "$pr" =~ ^[0-9]{1,5}$ ]] || die "Prioridade inválida."
  why=$(dns_valid_rec "$n" "$t" "$v") || die "$why"
  j=$(dns_load "$z" | jq --arg n "$n" --arg t "$t" --arg v "$v" --argjson ttl "$ttl" --argjson p "$pr" --arg id "$(openssl rand -hex 6)" \
      '.records += [{id:$id, name:$n, type:$t, value:$v, ttl:$ttl, prio:$p, auto:false}]')
  dns_bump "$z" "$j" || die "Registo recusado pelo verificador de zonas; nada foi alterado."
  echo "Registo $n $t $v acrescentado a $z."; return 0
}
cmd_dns_rec_del(){
  local z="${1:-}" id="${2:-}" j; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  [[ "$id" =~ ^[A-Za-z0-9]{6,16}$ ]] || die "Identificador inválido."
  [ "$(dns_load "$z" | jq --arg id "$id" '[.records[] | select(.id == $id and .auto != true)] | length')" = 1 ] || die "Registo não encontrado (os automáticos atualizam-se com 'Sincronizar')."
  j=$(dns_load "$z" | jq --arg id "$id" '.records |= map(select(.id != $id))')
  dns_bump "$z" "$j" || die "Não foi possível atualizar a zona."
  echo "Registo apagado de $z."; return 0
}
cmd_dns_sync(){ local z="${1:-all}"; dns_need
  if [ "$z" = all ]; then dns_autosync; echo "Zonas sincronizadas."; return 0; fi
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  dns_sync_zone "$z" || die "Falhou."; echo "Zona $z sincronizada com os sites e o email."; return 0; }
cmd_dns_check(){ # a delegação no registador já aponta para este servidor?
  local z="${1:-}" got ours r f=$DATA/stats/dns-check.json
  dns_need; [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  got=$(dig +short NS "$z" @8.8.8.8 2>/dev/null | sed 's/\.$//' | sort | tr '\n' ' ')
  ours=$(printf '%s\n%s\n' "$(dns_get NS1)" "$(dns_get NS2)" | sort | tr '\n' ' ')
  r=$(dig +short SOA "$z" @"$(dns_get IP)" 2>/dev/null | awk '{print $3}')
  [ -s "$f" ] || echo '{}' > "$f"
  jq --arg z "$z" --arg g "$got" --argjson ok "$([ "$got" = "$ours" ] && echo true || echo false)" --arg r "$r" --arg t "$EPOCHSECONDS" \
    '.[$z] = {checked:($t|tonumber), delegated:$ok, found:$g, serial_public:$r}' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"
  if [ "$got" = "$ours" ]; then echo "Delegação de $z correta: os nameservers apontam para este servidor."
  else echo "A delegação de $z ainda não aponta para este servidor (encontrado: ${got:-nada}). Altera os nameservers no registador para $(dns_get NS1) e $(dns_get NS2)."; fi
  return 0
}
dns_state_json(){
  dns_on || { echo '{"enabled":false}'; return 0; }
  local z zs="[]" chk; chk=$(cat "$DATA/stats/dns-check.json" 2>/dev/null || echo '{}'); jq -e . >/dev/null 2>&1 <<<"$chk" || chk='{}'
  for z in $(dns_zones); do zs=$(jq -c --arg z "$z" --argjson d "$(dns_load "$z")" --argjson c "$chk" '. + [{name:$z, serial:$d.serial, records:$d.records, check:($c[$z] // null)}]' <<<"$zs"); done
  jq -n --arg ns1 "$(dns_get NS1)" --arg ns2 "$(dns_get NS2)" --arg ip "$(dns_get IP)" --arg ip6 "$(dns_get IP6)" --argjson zs "$zs" \
    --arg act "$(systemctl is-active nsd 2>/dev/null)" '{enabled:true, ns1:$ns1, ns2:$ns2, ip:$ip, ip6:$ip6, active:($act == "active"), zones:$zs}'
}
# ============================ LOGS DOS SITES =================================
SITE_LOGS=/var/log/minipainel/sites          # access.log e error.log do nginx (lidos pelo painel)
logs_days(){ local d; d=$(srv_get LOG_DAYS 90); [[ "$d" =~ ^[0-9]{1,3}$ ]] || d=90; echo "$d"; }
logs_dir_site(){ install -d -o root -g "$PANEL_SYSUSER" -m 750 "$SITE_LOGS" "$SITE_LOGS/$1"; }
logs_migrate_site(){ # move os logs antigos do nginx (/var/log/nginx/mp-<site>.*) para a pasta nova
  local n=$1 t; logs_dir_site "$n"
  for t in access error; do
    if [ -f "/var/log/nginx/mp-$n.$t.log" ] && [ ! -e "$SITE_LOGS/$n/$t.log" ]; then mv -f "/var/log/nginx/mp-$n.$t.log" "$SITE_LOGS/$n/$t.log"; fi
    for f in /var/log/nginx/mp-"$n".$t.log.*; do [ -f "$f" ] && mv -f "$f" "$SITE_LOGS/$n/$t.log${f##*.log}"; done
  done
}
logs_rotate_conf(){ # rotação diária; os logs dentro da pasta do site são rodados com o utilizador do site
  local d n; d=$(logs_days)
  {
    echo "# IDDigital Hosting — rotação dos logs dos sites (gerado pelo painel; guarda $d dias)"
    printf '%s/*/access.log %s/*/error.log %s/*/php-slow.log {\n    daily\n    rotate %s\n    maxage %s\n    missingok\n    notifempty\n    compress\n    delaycompress\n    dateext\n    sharedscripts\n    postrotate\n        [ -s /run/nginx.pid ] && kill -USR1 "$(cat /run/nginx.pid)" 2>/dev/null || true\n    endscript\n}\n' "$SITE_LOGS" "$SITE_LOGS" "$SITE_LOGS" "$d" "$d"
    for n in $(site_names); do
      printf '%s/%s/logs/*.log {\n    su mp_%s mp_%s\n    daily\n    rotate %s\n    maxage %s\n    missingok\n    notifempty\n    compress\n    delaycompress\n    dateext\n    copytruncate\n}\n' "$WWW_ROOT" "$n" "$n" "$n" "$d" "$d"
    done
  } > /etc/logrotate.d/minipainel-sites
  chmod 644 /etc/logrotate.d/minipainel-sites
  # a rotação genérica antiga deixa de tocar nas pastas dos sites
  [ -f /etc/logrotate.d/minipainel ] && sed -i 's|^/srv/www/\*/logs/\*\.log ||' /etc/logrotate.d/minipainel
  return 0
}
cmd_logs_settings(){
  local d=""
  while [ $# -gt 0 ]; do case "$1" in --days) d="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  [[ "$d" =~ ^[0-9]{1,3}$ ]] && [ "$d" -ge 7 ] && [ "$d" -le 365 ] || die "Dias entre 7 e 365."
  srv_set LOG_DAYS "$d"; logs_rotate_conf
  echo "Os logs dos sites passam a ser guardados durante $d dias."; return 0
}

# ============================ TERMINAL (ttyd, root, só com 2FA) ==============
TERM_RUN=/run/minipainel-term
TERM_LOG=/var/log/minipainel/terminal
TTYD_VER=1.7.7
TTYD_SHA_X86=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
TTYD_SHA_ARM=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
term_bin(){ if command -v ttyd >/dev/null 2>&1; then command -v ttyd; else echo /usr/local/lib/minipainel/ttyd; fi; }
term_install(){
  [ -x "$(term_bin)" ] && return 0
  if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q ttyd >/dev/null 2>&1; else dnf install -y -q ttyd >/dev/null 2>&1; fi
  [ -x "$(term_bin)" ] && return 0
  # sem pacote na distribuição: binário oficial com versão e SHA-256 fixados
  local arch sha url tmp; arch=$(uname -m)
  case "$arch" in x86_64) sha=$TTYD_SHA_X86 ;; aarch64) sha=$TTYD_SHA_ARM ;; *) die "Arquitetura $arch sem ttyd disponível." ;; esac
  url="https://github.com/tsl0922/ttyd/releases/download/$TTYD_VER/ttyd.$arch"; tmp=$(mktemp)
  curl -fsSL -m 120 -o "$tmp" "$url" || { rm -f "$tmp"; die "Não foi possível descarregar o ttyd."; }
  [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$sha" ] || { rm -f "$tmp"; die "O ttyd descarregado não corresponde ao SHA-256 esperado; instalação recusada."; }
  install -d -m 755 /usr/local/lib/minipainel; install -m 755 "$tmp" /usr/local/lib/minipainel/ttyd; rm -f "$tmp"
}
term_2fa_on(){ jq -e '(.totp // "") != ""' "$AUTH" >/dev/null 2>&1; }
cmd_terminal_start(){
  local tok="${1:-}" re='^[a-f0-9]{32}$' bin w=() id i
  [[ "$tok" =~ $re ]] || die "Pedido inválido."
  term_2fa_on || die "O terminal só pode ser usado com a verificação em dois passos ativa (Conta)."
  term_install; bin=$(term_bin)
  cmd_terminal_stop >/dev/null 2>&1
  install -d -o root -g "$WEB_GROUP" -m 2750 "$TERM_RUN"
  install -d -o root -g "$PANEL_SYSUSER" -m 2750 "$TERM_LOG"
  "$bin" --help 2>&1 | grep -q -- '--writable' && w=(-W)
  id=$(date '+%Y%m%d-%H%M%S')
  local args=(-i "$TERM_RUN/term.sock" -b "/terminal/$tok" -o -O "${w[@]}" -t fontSize=14 -t disableLeaveAlert=true -t "titleFixed=Terminal — $(hostname -s)" /usr/local/sbin/mpanel-term "$id")
  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemd-run --quiet --collect --unit=minipainel-term --property=RuntimeMaxSec=14400 --property=UMask=0007 "$bin" "${args[@]}" >/dev/null 2>&1 || die "Não foi possível arrancar o terminal."
  else
    ( umask 007; setsid bash -c 'echo $$ > "$0"; exec timeout 4h "$@"' "$TERM_RUN/ttyd.pid" "$bin" "${args[@]}" >/dev/null 2>&1 < /dev/null 9>&- & )
  fi
  for i in $(seq 1 30); do [ -S "$TERM_RUN/term.sock" ] && break; sleep 0.2; done
  [ -S "$TERM_RUN/term.sock" ] || die "O terminal não arrancou."
  chgrp "$WEB_GROUP" "$TERM_RUN/term.sock" 2>/dev/null; chmod 660 "$TERM_RUN/term.sock" 2>/dev/null
  logger -t minipainel-audit -p authpriv.notice "terminal root aberto pelo painel (sessão $id)" 2>/dev/null
  echo "Terminal pronto (sessão $id; fecha ao fim de 15 min sem atividade)."
  return 0
}
cmd_terminal_stop(){
  systemctl stop minipainel-term >/dev/null 2>&1
  local pg; pg=$(cat "$TERM_RUN/ttyd.pid" 2>/dev/null)
  if [[ "$pg" =~ ^[0-9]+$ ]]; then kill -TERM -- "-$pg" >/dev/null 2>&1; sleep 0.3; kill -KILL -- "-$pg" >/dev/null 2>&1; fi
  rm -f "$TERM_RUN/term.sock" "$TERM_RUN/ttyd.pid"
  echo "Terminal fechado."; return 0
}

# ============================ PAÍSES E LIMITE DE LIGAÇÕES ====================
GEO_DIR=/var/lib/minipainel/geoip
geo_cc_valid(){ [[ "$1" =~ ^[A-Z]{2}$ ]] && [ -f "$GEO_DIR/cc/$1.v4" ] || [ -f "$GEO_DIR/cc/$1.v6" ]; }
cmd_geoip_update(){
  local m tmp ok=0
  tmp=$(mktemp); install -d -o root -g "$PANEL_SYSUSER" -m 750 "$GEO_DIR"
  for m in "$(date +%Y-%m)" "$(date -d '-1 month' +%Y-%m)"; do
    curl -fsSL -m 300 -o "$tmp" "https://download.db-ip.com/free/dbip-country-lite-$m.csv.gz" && gzip -t "$tmp" 2>/dev/null && [ "$(stat -c %s "$tmp")" -gt 1000000 ] && { ok=1; break; }
  done
  [ "$ok" = 1 ] || { rm -f "$tmp"; die "Não foi possível descarregar a base de geolocalização (DB-IP)."; }
  "$(php_cli "$PANEL_PHP")" /usr/local/lib/minipainel/geoip-build.php "$tmp" "$GEO_DIR" || { rm -f "$tmp"; die "Falhou a construção da base de geolocalização."; }
  rm -f "$tmp"
  chown -R root:"$PANEL_SYSUSER" "$GEO_DIR"; find "$GEO_DIR" -type d -exec chmod 750 {} +; find "$GEO_DIR" -type f -exec chmod 640 {} +
  date +%s > "$GEO_DIR/updated"
  geo_apply
  echo "Base de geolocalização atualizada (DB-IP Lite, $(date +%Y-%m))."
  return 0
}
geo_elems(){ # ficheiro(s) de gamas -> linhas "add element"
  local set=$1; shift
  cat "$@" 2>/dev/null | grep -v '^$' | awk -v s="$set" 'BEGIN{n=0} { if (n % 2000 == 0) { if (n) print " }"; printf "add element inet minipainel %s {", s } else printf ","; printf " %s", $0; n++ } END { if (n) print " }" }'
}
geo_apply(){ # carrega países bloqueados, país da casa e IPs de confiança na firewall
  fw_has_nft || return 0
  nft list table inet minipainel >/dev/null 2>&1 || return 0
  nft list set inet minipainel geo4 >/dev/null 2>&1 || return 0
  local f c home; f=$(mktemp); home=$(srv_get HOME_CC PT)
  {
    for c in geo4 geo6 home4 home6; do echo "flush set inet minipainel $c"; done
    local files4=() files6=()
    for c in $(srv_get GEO_BLOCK ''); do files4+=("$GEO_DIR/cc/$c.v4"); files6+=("$GEO_DIR/cc/$c.v6"); done
    [ ${#files4[@]} -gt 0 ] && geo_elems geo4 "${files4[@]}" && geo_elems geo6 "${files6[@]}"
    geo_elems home4 "$GEO_DIR/cc/$home.v4"; geo_elems home6 "$GEO_DIR/cc/$home.v6"
  } > "$f"
  nft -f "$f" 2>/dev/null || warn "Não foi possível carregar os países na firewall."
  rm -f "$f"; trust_apply
  return 0
}
trust_apply(){ # IPs que nunca são bloqueados (servidor, confiança, admin dos últimos 7 dias)
  nft list set inet minipainel trust4 >/dev/null 2>&1 || return 0
  local ip f; f=$(mktemp)
  { echo "flush set inet minipainel trust4"; echo "flush set inet minipainel trust6"
    for ip in $(fw_protected_list | sort -u); do
      if [[ "$ip" == *:* ]]; then echo "add element inet minipainel trust6 { $ip }"; elif [[ "$ip" =~ ^[0-9./]+$ ]]; then echo "add element inet minipainel trust4 { $ip }"; fi
    done; } > "$f"
  nft -f "$f" 2>/dev/null; rm -f "$f"; return 0
}
cmd_geo_block(){ # add|del CC
  local op="${1:-}" c; c=$(printf '%s' "${2:-}" | tr 'a-z' 'A-Z'); local cur
  geo_cc_valid "$c" || die "País desconhecido: $c (código de 2 letras, ex.: CN). Se a base ainda não existir: mpanel geoip-update"
  [ "$c" = "$(srv_get HOME_CC PT)" ] && [ "$op" = add ] && die "Não é possível bloquear o país do próprio servidor ($c)."
  cur=" $(srv_get GEO_BLOCK '') "
  case "$op" in
    add) [[ "$cur" == *" $c "* ]] || cur+="$c " ;;
    del) cur=${cur// $c / } ;;
    *) die "Usa: mpanel geo-block add|del <país>" ;;
  esac
  srv_set GEO_BLOCK "$(echo $cur | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  geo_apply
  echo "$([ "$op" = add ] && echo "País $c bloqueado (ligações novas)." || echo "País $c desbloqueado.")"
  return 0
}
cmd_overload_settings(){
  local on mx st sp home re='^[0-9]{1,7}$'
  on=$(srv_get OVL 1); mx=$(srv_get OVL_MAX auto); st=$(srv_get OVL_ON 80); sp=$(srv_get OVL_OFF 60); home=$(srv_get HOME_CC PT)
  while [ $# -gt 0 ]; do
    case "$1" in
      --on) on=1; shift ;; --off) on=0; shift ;;
      --max) mx="${2:-}"; shift 2 || shift ;; --start) st="${2:-}"; shift 2 || shift ;; --stop) sp="${2:-}"; shift 2 || shift ;;
      --home) home=$(printf '%s' "${2:-}" | tr 'a-z' 'A-Z'); shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [ "$mx" = auto ] || { [[ "$mx" =~ $re ]] && [ "$mx" -ge 50 ]; } || die "Capacidade inválida (auto ou um número ≥ 50)."
  [[ "$st" =~ ^[0-9]{1,2}$ ]] && [[ "$sp" =~ ^[0-9]{1,2}$ ]] && [ "$st" -ge 5 ] && [ "$sp" -ge 1 ] && [ "$sp" -lt "$st" ] || die "Os limites são percentagens, e o de saída tem de ser menor que o de entrada."
  geo_cc_valid "$home" || [ ! -d "$GEO_DIR/cc" ] || die "País desconhecido: $home"
  [[ " $(srv_get GEO_BLOCK '') " == *" $home "* ]] && die "O país $home está bloqueado; desbloqueia-o primeiro."
  srv_set OVL "$on"; srv_set OVL_MAX "$mx"; srv_set OVL_ON "$st"; srv_set OVL_OFF "$sp"; srv_set HOME_CC "$home"
  geo_apply
  echo "Proteção por limite de ligações: $([ "$on" = 1 ] && echo "ativa (entra aos $st%, sai abaixo de $sp%; capacidade $mx; mantém sempre $home)" || echo desligada)."
  return 0
}
ovl_capacity(){ # ligações simultâneas que o servidor aguenta (nginx)
  local mx wp wc; mx=$(srv_get OVL_MAX auto)
  if [ "$mx" != auto ]; then echo "$mx"; return; fi
  wp=$(grep -m1 -E '^\s*worker_processes' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')
  [[ "$wp" =~ ^[0-9]+$ ]] || wp=$(nproc 2>/dev/null || echo 1)
  wc=$(grep -m1 -E '^\s*worker_connections' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';'); [[ "$wc" =~ ^[0-9]+$ ]] || wc=768
  echo $(( wp * wc ))
}
geo_state_json(){
  local upd n; upd=$(cat "$GEO_DIR/updated" 2>/dev/null || echo 0); n=$(ls "$GEO_DIR/cc" 2>/dev/null | sed 's/\..*//' | sort -u | tr '\n' ' ')
  jq -n --arg b "$(srv_get GEO_BLOCK '')" --arg h "$(srv_get HOME_CC PT)" --arg u "$upd" --arg l "$n" --arg on "$(srv_get OVL 1)" --arg mx "$(srv_get OVL_MAX auto)" \
     --arg cap "$(ovl_capacity)" --arg st "$(srv_get OVL_ON 80)" --arg sp "$(srv_get OVL_OFF 60)" \
     '{block:($b | split(" ") | map(select(. != ""))), home:$h, updated:($u|tonumber), countries:($l | split(" ") | map(select(. != ""))),
       ovl:{on:($on == "1"), max:$mx, capacity:($cap|tonumber), start:($st|tonumber), stop:($sp|tonumber)}}'
}

# ============================ ALERTAS (SMS bulksms.com e email) ==============
ALERT_CONF=/etc/minipainel/alerts.conf
ALERT_LOG=$DATA/stats/alerts.log
aget(){ local v; v=$(grep -m1 "^$1=" "$ALERT_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
aset(){ touch "$ALERT_CONF"; chmod 600 "$ALERT_CONF"; if grep -q "^$1=" "$ALERT_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$ALERT_CONF"; else echo "$1=$2" >> "$ALERT_CONF"; fi; }
sms_send(){ # texto -> 0 enviado
  local id sec to body tmp code
  id=$(aget SMS_ID); sec=$(aget SMS_SECRET); to=$(aget SMS_TO)
  [ -n "$id" ] && [ -n "$sec" ] && [ -n "$to" ] || return 2
  body=$(printf '%s' "$1" | cut -c1-450)
  tmp=$(mktemp); chmod 600 "$tmp"
  jq -n --arg t "$to" --arg b "$body" '{to: ($t | split(",") | map(gsub("\\s"; ""))), body: $b, encoding: "UNICODE"}' > "$tmp"
  # credenciais lidas de um descritor (nunca na linha de comandos)
  code=$(curl -sS -m 25 -o /dev/null -w '%{http_code}' -K <(printf 'user = "%s:%s"\n' "$id" "$sec") \
        -H 'Content-Type: application/json' --data-binary @"$tmp" "${MP_BULKSMS_URL:-https://api.bulksms.com/v1/messages}" 2>/dev/null)
  rm -f "$tmp"
  [ "$code" = 201 ] || [ "$code" = 200 ]
}
alert_mail_send(){ # assunto texto -> 0 enviado
  local to from; to=$(aget EMAIL_TO)
  [ -n "$to" ] && mail_on || return 2
  from="alertas@$(mail_get HOST)"
  { printf 'From: IDDigital Hosting <%s>\nTo: %s\nSubject: =?UTF-8?B?%s?=\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\nX-MP-Alert: 1\n\n' \
      "$from" "$to" "$(printf '%s' "$1" | base64 -w0)"
    printf '%s\n\n-- \nServidor %s (%s)\n' "$2" "$(hostname -f 2>/dev/null || hostname)" "$(date '+%d/%m/%Y %H:%M')"; } | /usr/sbin/sendmail -t -i -f "$from"
}
cmd_alert_send(){ # "texto" [--level crit|warn|ok] [--key chave]
  local msg="${1:-}" lvl=warn key=manual s="off" e="off" host
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do case "$1" in --level) lvl="${2:-warn}"; shift 2 || shift ;; --key) key="${2:-manual}"; shift 2 || shift ;; *) shift ;; esac; done
  [ -n "$msg" ] || die "Indica o texto do alerta."
  host=$(hostname -s)
  if [ "$(aget SMS_ON 0)" = 1 ]; then if sms_send "[$host] $msg"; then s=ok; else s=falhou; fi; fi
  if [ "$(aget EMAIL_ON 0)" = 1 ]; then if alert_mail_send "[$host] $(printf '%s' "$msg" | cut -c1-80)" "$msg"; then e=ok; else e=falhou; fi; fi
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$DATA/stats"
  jq -cn --arg m "$msg" --arg l "$lvl" --arg k "$key" --arg s "$s" --arg e "$e" --argjson t "$EPOCHSECONDS" '{ts:$t, key:$k, level:$l, msg:$m, sms:$s, email:$e}' >> "$ALERT_LOG"
  chown root:"$PANEL_SYSUSER" "$ALERT_LOG"; chmod 640 "$ALERT_LOG"
  tail -n 2000 "$ALERT_LOG" > "$ALERT_LOG.tmp" && mv -f "$ALERT_LOG.tmp" "$ALERT_LOG"; chown root:"$PANEL_SYSUSER" "$ALERT_LOG"; chmod 640 "$ALERT_LOG"
  echo "Alerta registado (SMS: $s; email: $e)."
  return 0
}
cmd_alerts_settings(){
  local k v re_n='^[0-9]{1,3}$' re_tel='^\+?[0-9]{9,15}(,\+?[0-9]{9,15})*$'
  while [ $# -gt 0 ]; do
    k=$1; v="${2:-}"
    case "$k" in
      --sms) case "$v" in on) aset SMS_ON 1 ;; off) aset SMS_ON 0 ;; *) die "--sms on|off" ;; esac ;;
      --email) case "$v" in on) aset EMAIL_ON 1 ;; off) aset EMAIL_ON 0 ;; *) die "--email on|off" ;; esac ;;
      --sms-id) [[ "$v" =~ ^[A-Za-z0-9_-]{4,80}$ ]] || die "Token ID inválido."; aset SMS_ID "$v" ;;
      --sms-secret) [[ "$v" =~ ^[A-Za-z0-9_.+/=-]{4,200}$ ]] || die "Token secreto inválido."; aset SMS_SECRET "$v" ;;
      --sms-to) v=${v// /}; [[ "$v" =~ $re_tel ]] || die "Número inválido (formato internacional, ex.: +351912345678; vários separados por vírgulas)."; aset SMS_TO "$v" ;;
      --email-to) [[ "$v" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] || die "Email inválido."; aset EMAIL_TO "$v" ;;
      --cpu|--ram|--disk|--conn) [[ "$v" =~ $re_n ]] && [ "$v" -ge 10 ] && [ "$v" -le 100 ] || die "$k: percentagem entre 10 e 100."; aset "$(printf '%s' "${k#--}" | tr a-z A-Z)" "$v" ;;
      --cpu-min) [[ "$v" =~ $re_n ]] && [ "$v" -ge 1 ] && [ "$v" -le 120 ] || die "Minutos entre 1 e 120."; aset CPU_MIN "$v" ;;
      --mail-pct) [[ "$v" =~ $re_n ]] && [ "$v" -ge 5 ] && [ "$v" -le 500 ] || die "Percentagem entre 5 e 500."; aset MAIL_PCT "$v" ;;
      --mail-min) [[ "$v" =~ ^[0-9]{1,6}$ ]] && [ "$v" -ge 1 ] || die "Mínimo inválido."; aset MAIL_MIN "$v" ;;
      *) die "Opção desconhecida: $k" ;;
    esac
    shift 2 || shift
  done
  echo "Alertas guardados."; return 0
}
cmd_alerts_test(){
  [ "$(aget SMS_ON 0)" = 1 ] || [ "$(aget EMAIL_ON 0)" = 1 ] || die "Ativa primeiro o SMS ou o email."
  cmd_alert_send "Teste de alertas do IDDigital Hosting: se recebeste esta mensagem, os alertas estão a funcionar." --level ok --key teste
}
alerts_state_json(){
  local first n=0
  first=$(head -n1 "$DATA/stats/mail-vol.csv" 2>/dev/null | cut -d, -f1); [[ "$first" =~ ^[0-9]+$ ]] || first=0
  [ "$first" -gt 0 ] && n=$(( (EPOCHSECONDS - first) / 86400 ))
  jq -n --arg so "$(aget SMS_ON 0)" --arg sid "$(aget SMS_ID)" --arg ss "$([ -n "$(aget SMS_SECRET)" ] && echo 1 || echo 0)" --arg st "$(aget SMS_TO)" \
     --arg eo "$(aget EMAIL_ON 0)" --arg et "$(aget EMAIL_TO "$(srv_get EMAIL '')")" --arg mo "$(mail_on && echo 1 || echo 0)" \
     --arg cpu "$(aget CPU 90)" --arg cm "$(aget CPU_MIN 5)" --arg ram "$(aget RAM 90)" --arg disk "$(aget DISK 90)" --arg conn "$(aget CONN 70)" \
     --arg mp "$(aget MAIL_PCT 20)" --arg mm "$(aget MAIL_MIN 50)" --arg f "$first" --arg n "$n" \
     '{sms_on:($so=="1"), sms_id:$sid, sms_secret:($ss=="1"), sms_to:$st, email_on:($eo=="1"), email_to:$et, mail_on:($mo=="1"),
       cpu:($cpu|tonumber), cpu_min:($cm|tonumber), ram:($ram|tonumber), disk:($disk|tonumber), conn:($conn|tonumber),
       mail_pct:($mp|tonumber), mail_min:($mm|tonumber), learn_start:($f|tonumber), learn_days:($n|tonumber)}'
}

# ============================ PROCESSOS ======================================
proc_protected(){ # pid -> 0 se não pode ser terminado pelo painel
  local p=$1 comm args usr
  [ "$p" -le 2 ] && return 0
  [ -d "/proc/$p" ] || return 1
  comm=$(cat "/proc/$p/comm" 2>/dev/null); args=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null); usr=$(stat -c %U "/proc/$p" 2>/dev/null)
  [ -z "$args" ] && return 0                                    # threads do kernel
  [ "$p" = "$$" ] || [ "$p" = "$PPID" ] && return 0
  case "$comm" in systemd|systemd-*|init|dbus-daemon|dbus-broker|agetty|cron|crond|rsyslogd|journald|udevd|polkitd|mariadbd|mysqld|master|containerd|dockerd) return 0 ;; esac
  case "$args" in
    "nginx: master"*|"php-fpm: master"*|"php-fpm: pool minipainel"*|"sshd: /usr/sbin/sshd"*|"/usr/sbin/sshd"*|*mpanel-stats*|*"mpanel worker"*|"/usr/sbin/dovecot"*|"dovecot"|"/usr/sbin/nsd"*|"nsd -c"*) return 0 ;;
  esac
  [ "$usr" = minipainel ] && [[ "$args" == php-fpm* ]] && return 0
  return 1
}
cmd_proc_kill(){ # pid [--force]
  local p="${1:-}" sig=TERM desc
  [ "${2:-}" = --force ] && sig=KILL
  [[ "$p" =~ ^[0-9]{1,8}$ ]] || die "PID inválido."
  [ -d "/proc/$p" ] || die "O processo $p já não existe."
  proc_protected "$p" && die "O processo $p é essencial ao servidor ou ao painel e não pode ser terminado aqui (usa o Terminal, se tiveres a certeza)."
  desc="$(stat -c %U "/proc/$p" 2>/dev/null): $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"
  kill -s "$sig" "$p" 2>/dev/null || die "Não foi possível terminar o processo $p."
  sleep 1
  if [ -d "/proc/$p" ] && [ "$sig" = TERM ]; then echo "Pedido de fim enviado ao processo $p ($desc); ainda está a terminar. Se não terminar, usa 'Forçar'."
  else echo "Processo $p terminado ($desc)."; fi
  return 0
}
cmd_proc_kill_site(){ # site [--force]
  local n="${1:-}" sig=TERM c
  [ "${2:-}" = --force ] && sig=KILL
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  c=$(pgrep -u "mp_$n" | wc -l)
  [ "$c" -gt 0 ] || { echo "O site $n não tem processos a correr."; return 0; }
  pkill -"$sig" -u "mp_$n" 2>/dev/null
  echo "Terminados $c processos do site $n (o PHP do site volta a arrancar no próximo pedido)."
  return 0
}

# ============================ SENTINELA (testes periódicos e reparação) ======
SN_CONF=/etc/minipainel/sentinel.conf
SN_DIR=$DATA/stats
snget(){ local v; v=$(grep -m1 "^$1=" "$SN_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
snset(){ touch "$SN_CONF"; chmod 600 "$SN_CONF"; if grep -q "^$1=" "$SN_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$SN_CONF"; else echo "$1=$2" >> "$SN_CONF"; fi; }
sn_off(){ [[ " $(snget OFF '') " == *" $1 "* ]]; }
sn_unit_ok(){ systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^$1.service"; }
SN_RES=""
sn_res(){ SN_RES+="$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6"$'\n'; }   # id grupo nome estado mensagem reparado
sn_repair_ok(){ # id -> pode reparar (máx. 3 por hora por teste)
  [ "$(snget REPAIR 1)" = 1 ] || return 1
  local n; n=$(awk -v s=$(( EPOCHSECONDS - 3600 )) -v id="$1" '$1 >= s && $2 == id' "$SN_DIR/sentinel-repairs.log" 2>/dev/null | wc -l)
  [ "$n" -lt 3 ]
}
sn_run(){ # segundos comando… — limite de tempo que funciona também com funções do bash
  local t=$1 pid w rc; shift
  ( "$@" ) & pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 5>&- 9>&- & w=$!
  wait "$pid"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  [ "$rc" = 143 ] && echo "O teste não terminou em $t s"
  return "$rc"
}
sn_check(){ # id grupo nome unidade(ou -) comando… (0 ok, 2 aviso, outro falha; imprime a mensagem)
  local id=$1 grp=$2 name=$3 unit=$4 msg rc; shift 4
  sn_off "$id" && return 0
  msg=$(sn_run 25 "$@" 2>&1); rc=$?; msg=$(printf '%s' "$msg" | tr '\n\t' '  ' | cut -c1-240)
  if [ "$rc" = 0 ]; then sn_res "$id" "$grp" "$name" ok "$msg" 0; return 0; fi
  if [ "$rc" = 2 ]; then sn_res "$id" "$grp" "$name" warn "$msg" 0; return 0; fi
  if [ "$unit" != - ] && sn_repair_ok "$id"; then
    echo "$EPOCHSECONDS $id $unit" >> "$SN_DIR/sentinel-repairs.log"
    local rout
    if [ "${unit:0:1}" = : ]; then rout=$(${unit:1} 2>&1 5>&- 9>&- | tail -n 1); else rout=$(systemctl restart "$unit" 2>&1 5>&- 9>&- | tail -n 1); fi
    sleep 4
    local m2; m2=$(sn_run 25 "$@" 2>&1) && { sn_res "$id" "$grp" "$name" ok "Falhou ($msg) e foi reparado automaticamente" 1; return 0; }
    msg="$msg; a reparação automática não resolveu${rout:+ ($(printf '%s' "$rout" | cut -c1-120))}"
  elif [ "$unit" != - ] && [ "$(snget REPAIR 1)" = 1 ]; then msg="$msg; já houve 3 reparações na última hora, sem resultado"; fi
  sn_res "$id" "$grp" "$name" fail "$msg" 0
}
# ---------- testes ----------
t_unit(){ systemctl is-active --quiet "$1" >/dev/null 2>&1 && echo "Ativo" || { echo "O serviço $1 está parado"; return 1; }; }
t_tcp(){ # host porta [esperado no início da resposta]
  local r; { exec 3<>"/dev/tcp/$1/$2"; } 2>/dev/null || { echo "Não responde na porta $2"; return 1; }
  if [ -n "${3:-}" ]; then read -r -t 6 r <&3; exec 3>&-; [[ "$r" == "$3"* ]] && echo "Responde na porta $2" || { echo "Resposta inesperada na porta $2: ${r:0:60}"; return 1; }
  else exec 3>&-; echo "Responde na porta $2"; fi
}
t_db(){ local r; r=$(mysql -uroot -N -B -e 'SELECT 1' 2>&1) && [ "$r" = 1 ] && echo "Responde a consultas" || { echo "Não responde: ${r:0:120}"; return 1; }; }
t_fpm(){ # socket ficheiro_público
  command -v cgi-fcgi >/dev/null 2>&1 || { echo "Sem a ferramenta cgi-fcgi (pacote libfcgi-bin)"; return 2; }
  [ -S "$1" ] || { echo "A socket do PHP não existe"; return 1; }
  local o; o=$(SCRIPT_FILENAME="$2/__mp_sentinela_$$.php" SCRIPT_NAME="/__mp_sentinela.php" REQUEST_METHOD=GET timeout 10 cgi-fcgi -bind -connect "$1" 2>&1)
  if [[ "$o" == *"404"* ]] || [[ "$o" == *"not found"* ]] || [[ "$o" == *"Primary script unknown"* ]]; then echo "O PHP responde"; else echo "O PHP não respondeu: ${o:0:100}"; return 1; fi
}
t_site(){ # porta
  local c; c=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null)
  case "$c" in 000) echo "Sem resposta em 15 s"; return 1 ;; 5*) echo "A página inicial deu erro $c (erro da aplicação ou do PHP)"; return 1 ;; *) echo "Página inicial: HTTP $c" ;; esac
}
t_rds(){ local r; [ -S "$1" ] || { echo "A socket do Redis não existe"; return 1; }; r=$(redis-cli -s "$1" ping 2>&1); [ "$r" = PONG ] && echo "Responde" || { echo "Não responde: ${r:0:80}"; return 1; }; }
t_redis(){ local r; r=$(redis-cli -a "$(cat /etc/minipainel/redis.pw 2>/dev/null)" --no-auth-warning ping 2>&1); [ "$r" = PONG ] && echo "Responde" || { echo "Não responde: ${r:0:80}"; return 1; }; }
t_unbound(){ dig +short +time=3 +tries=1 @127.0.0.1 localhost A >/dev/null 2>&1 && echo "Responde" || { echo "O resolver local não responde"; return 1; }; }
t_queue(){ local n; n=$(postqueue -j 2>/dev/null | wc -l); [ "$n" -lt "$(snget QUEUE_MAX 300)" ] && echo "$n mensagens na fila" || { echo "$n mensagens na fila (acima de $(snget QUEUE_MAX 300))"; return 2; }; }
t_zone(){ local s w; w=$(jq -r '.serial' "$DNS_DIR/$1.json" 2>/dev/null); s=$(dig +norec +short +time=3 +tries=1 SOA "$1" @"$(dns_get IP)" 2>/dev/null | awk '{print $3}')
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "A zona não responde"; return 1; }; [ "$s" = "$w" ] && echo "Responde (série $s)" || { echo "Série publicada $s diferente da esperada $w"; return 1; }; }
t_cert(){ local e d; e=$(cert_expiry "$1"); [ -n "$e" ] || { echo "Sem certificado"; return 2; }; d=$(( (e - EPOCHSECONDS) / 86400 ))
  if [ "$d" -lt 3 ]; then echo "Expira em $d dias"; return 1; elif [ "$d" -lt 14 ]; then echo "Expira em $d dias (a renovação ainda não aconteceu)"; return 2; fi; echo "Válido mais $d dias"; }
t_rw(){ local f=$DATA/.sentinela-rw; ( echo ok > "$f" ) 2>/dev/null && rm -f "$f" && echo "Disco com escrita" || { echo "O disco está só de leitura ou cheio"; return 1; }; }
t_inodes(){ local p; p=$(df -iP / | awk 'NR==2 {gsub("%","",$5); print $5}'); [[ "$p" =~ ^[0-9]+$ ]] || p=0; [ "$p" -lt 90 ] && echo "Inodes a $p%" || { echo "Inodes a $p%"; return 2; }; }
t_oom(){ local n; n=$(journalctl -k -q --since "-6min" 2>/dev/null | grep -c 'Out of memory: Killed process'); [ "$n" = 0 ] && echo "Sem processos terminados por falta de memória" || { echo "$n processos terminados por falta de memória nos últimos minutos"; return 2; }; }
t_segv(){ local n; n=$(journalctl -k -q --since "-6min" 2>/dev/null | grep -c 'segfault at'); [ "$n" = 0 ] && echo "Sem falhas de segmentação" || { echo "$n falhas de segmentação nos últimos minutos"; return 2; }; }
t_zombie(){ local z d; z=$(ps -eo stat= | grep -c '^Z'); d=$(ps -eo stat= | grep -c '^D'); [ "$z" -lt 20 ] && [ "$d" -lt 10 ] && echo "$z zombie, $d bloqueados" || { echo "$z processos zombie e $d bloqueados em disco"; return 2; }; }
t_ntp(){ local s; s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null); [ "$s" = no ] && { echo "O relógio não está sincronizado (NTP)"; return 2; }; echo "Relógio sincronizado"; }
t_fpmmax(){ # aumento das mensagens "reached pm.max_children" desde o último teste
  local tot prev f=$SN_DIR/.sentinela-fpmmax
  tot=$(cat /var/log/php*-fpm.log /var/log/php-fpm/*.log 2>/dev/null | grep -c 'reached pm.max_children'); prev=$(cat "$f" 2>/dev/null || echo "$tot"); echo "$tot" > "$f"
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=$tot; [ "$tot" -lt "$prev" ] && prev=0
  [ $(( tot - prev )) -le 0 ] && echo "Sem limite de processos PHP atingido" || { echo "Limite de processos PHP atingido $(( tot - prev )) vezes desde o último teste (sites lentos ou sob carga)"; return 2; }
}
t_collector(){ local a; a=$(( EPOCHSECONDS - $(stat -c %Y "$DATA/stats/live.json" 2>/dev/null || echo 0) )); [ "$a" -lt 120 ] && echo "A recolher dados" || { echo "Sem dados novos há $a s"; return 1; }; }
t_queue_panel(){ local n; n=$(find "$DATA/queue" -name '*.json' -mmin +10 2>/dev/null | wc -l); [ "$n" = 0 ] && echo "Fila de tarefas a andar" || { echo "$n tarefas paradas há mais de 10 minutos"; return 1; }; }
t_fw(){ nft list table inet minipainel >/dev/null 2>&1 && echo "Firewall carregada" || { echo "A tabela da firewall do painel não está carregada"; return 1; }; }
t_backup(){ local t; [ "$(bk_get ENABLED 1)" = 1 ] || { echo "Backups automáticos desligados"; return 0; }
  t=$(jq -r 'if (.last.ok // false) then .last.ts else 0 end' "$DATA/stats/backup.json" 2>/dev/null); [[ "$t" =~ ^[0-9]+$ ]] || t=0
  [ $(( EPOCHSECONDS - t )) -lt 93600 ] && echo "Último backup há $(( (EPOCHSECONDS - t) / 3600 )) h" || { echo "Sem backup bem-sucedido nas últimas 26 h"; return 2; }; }
cmd_sentinel_run(){
  exec 5>/run/minipainel-sentinel.lock; flock -n 5 || { echo "O sentinela já está a correr."; return 0; }
  local t0=$EPOCHSECONDS n v u
  SN_RES=""
  # serviços essenciais
  for u in nginx cron; do sn_unit_ok "$u" && sn_check "svc:$u" "Serviços" "$u" "$u" t_unit "$u"; done
  for u in mariadb mysql; do sn_unit_ok "$u" && { sn_check "svc:db" "Serviços" "MariaDB" "$u" t_unit "$u"; break; }; done
  for u in ssh sshd; do sn_unit_ok "$u" && { sn_check "svc:ssh" "Serviços" "SSH" "$u" t_unit "$u"; break; }; done
  for v in $(php_installed); do sn_unit_ok "$(php_service "$v")" && sn_check "svc:php$v" "Serviços" "PHP $v" "$(php_service "$v")" t_unit "$(php_service "$v")"; done
  sn_check "web:http" "Serviços" "Servidor web (porta 80)" nginx t_tcp 127.0.0.1 80
  sn_check "db:query" "Serviços" "Base de dados (consulta)" "$(sn_unit_ok mariadb && echo mariadb || echo mysql)" t_db
  # sites: PHP de cada site e página inicial
  for n in $(site_names); do
    [ "$(site_get "$n" ENABLED)" = 1 ] || continue
    v=$(site_get "$n" PHP)
    sn_check "site:$n:php" "Sites" "$n — PHP $v" "$(php_service "$v")" t_fpm "$(php_sock "$v" "$n")" "$WWW_ROOT/$n/public_html"
    [ "$(snget SITES 1)" = 1 ] && sn_check "site:$n:web" "Sites" "$n — página inicial" - t_site "$(site_get "$n" PORT)"
    [ "$(site_get "$n" REDIS)" = 1 ] && sn_check "site:$n:redis" "Sites" "$n — Redis" "minipainel-redis@$n" t_rds "$(rds_sock "$n")"
    [ "$(site_get "$n" SSL)" = le ] && sn_check "cert:$n" "Certificados" "$n" - t_cert "mp-$n"
  done
  # email
  if mail_on; then
    sn_check "svc:postfix" "Email" "Postfix" postfix t_unit postfix
    sn_check "mail:smtp25" "Email" "SMTP (25)" postfix t_tcp 127.0.0.1 25 220
    sn_check "mail:smtp587" "Email" "Envio (587)" postfix t_tcp 127.0.0.1 587 220
    sn_check "svc:dovecot" "Email" "Dovecot" dovecot t_unit dovecot
    sn_check "mail:imap" "Email" "IMAP (143)" dovecot t_tcp 127.0.0.1 143 "* OK"
    sn_check "svc:rspamd" "Email" "Rspamd (antispam)" rspamd t_tcp 127.0.0.1 11333
    sn_check "svc:redis" "Email" "Redis" "$(mail_svc_redis)" t_redis
    sn_check "svc:unbound" "Email" "Unbound (resolver)" unbound t_unbound
    sn_check "mail:queue" "Email" "Fila de email" - t_queue
    [ "$(mail_get CLAMAV 0)" = 1 ] && sn_unit_ok clamav-daemon && sn_check "svc:clamav" "Email" "ClamAV" clamav-daemon t_unit clamav-daemon
    sn_check "cert:mail" "Certificados" "Servidor de email" - t_cert mp-mail
  fi
  if dns_on; then
    sn_check "svc:nsd" "DNS" "NSD" nsd t_unit nsd
    for n in $(dns_zones); do sn_check "dns:$n" "DNS" "Zona $n" nsd t_zone "$n"; done
  fi
  [ -s /etc/pure-ftpd/pureftpd.passwd ] && sn_check "svc:ftp" "Serviços" "Pure-FTPd (FTPS)" pure-ftpd t_tcp 127.0.0.1 21 220
  [ -n "$(srv_get PANEL_DOMAIN '')" ] && sn_check "cert:painel" "Certificados" "Domínio do painel" - t_cert mp-painel
  # sistema
  sn_check "sys:rw" "Sistema" "Escrita no disco" - t_rw
  sn_check "sys:inodes" "Sistema" "Inodes" - t_inodes
  sn_check "sys:oom" "Sistema" "Falta de memória (OOM)" - t_oom
  sn_check "sys:segv" "Sistema" "Falhas de segmentação" - t_segv
  sn_check "sys:procs" "Sistema" "Processos zombie e bloqueados" - t_zombie
  sn_check "sys:ntp" "Sistema" "Relógio (NTP)" - t_ntp
  sn_check "sys:fpmmax" "Sistema" "Limite de processos PHP" - t_fpmmax
  # o próprio painel
  sn_check "panel:collector" "Painel" "Recolhedor de estatísticas" minipainel-stats t_collector
  sn_check "panel:queue" "Painel" "Fila de tarefas" ":systemctl restart minipainel-worker.path" t_queue_panel
  sn_check "panel:fw" "Painel" "Firewall do painel" ":/usr/local/sbin/mpanel fw-restore" t_fw
  sn_check "panel:backup" "Painel" "Backups" - t_backup
  sn_finish "$t0"
}
sn_finish(){ # estado, incidentes, disponibilidade e alertas
  local t0=$1 st=$SN_DIR/sentinel-state.json res=$SN_DIR/sentinel.json inc=$SN_DIR/sentinel-incidents.log av=$SN_DIR/sentinel-avail.json day now=$EPOCHSECONDS
  jq -e 'type == "object"' "$st" >/dev/null 2>&1 || echo '{}' > "$st"   # ficheiros estragados (ex.: uma passagem interrompida) recomeçam do zero
  jq -e 'type == "object"' "$av" >/dev/null 2>&1 || echo '{}' > "$av"; day=$(date +%Y%m%d)
  local json; json=$(printf '%s' "$SN_RES" | iconv -f utf-8 -t utf-8 -c | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {id:.[0], group:.[1], name:.[2], status:.[3], msg:.[4], repaired:(.[5] == "1")})' 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" || json='[]'
  printf '{"ts":%s,"took":%s,"repair":%s,"results":%s}\n' "$now" $(( now - t0 )) "$([ "$(snget REPAIR 1)" = 1 ] && echo true || echo false)" "$json" > "$res.tmp" && mv -f "$res.tmp" "$res"
  # disponibilidade por dia (30 dias)
  jq --argjson r "$json" --arg d "$day" --arg lim "$(date -d '-30 days' +%Y%m%d)" '
    reduce $r[] as $x (.; .[$x.id][$d] = [((.[$x.id][$d][0] // 0) + (if $x.status == "fail" then 0 else 1 end)), ((.[$x.id][$d][1] // 0) + 1)])
    | with_entries(.value |= with_entries(select(.key >= $lim)))' "$av" > "$av.tmp" && mv -f "$av.tmp" "$av"
  # transições -> incidentes e alertas
  local id name status msg rep prev since sent nst
  nst=$(cat "$st")
  while IFS=$'\t' read -r id _ name status msg rep; do
    [ -n "$id" ] || continue
    prev=$(jq -r --arg i "$id" '.[$i].status // "ok"' <<<"$nst"); since=$(jq -r --arg i "$id" '.[$i].since // 0' <<<"$nst"); sent=$(jq -r --arg i "$id" '.[$i].sent // 0' <<<"$nst")
    [[ "$since" =~ ^[0-9]+$ ]] || since=0; [[ "$sent" =~ ^[0-9]+$ ]] || sent=0; [[ "$prev" =~ ^(ok|warn|fail)$ ]] || prev=ok
    if [ "$rep" = 1 ]; then
      jq -cn --arg i "$id" --arg n "$name" --arg m "$msg" --argjson t "$now" '{id:$i, name:$n, start:$t, end:$t, msg:$m, repaired:true}' >> "$inc"
      /usr/local/sbin/mpanel alert-send "Sentinela: $name falhou e foi reparado automaticamente." --level ok --key "sn:$id" >/dev/null 2>&1
    fi
    if [ "$status" != ok ] && [ "$prev" = ok ]; then
      since=$now; sent=$now
      /usr/local/sbin/mpanel alert-send "Sentinela: $name — $msg" --level "$([ "$status" = fail ] && echo crit || echo warn)" --key "sn:$id" >/dev/null 2>&1
    elif [ "$status" != ok ] && [ $(( now - sent )) -ge 21600 ]; then
      sent=$now; /usr/local/sbin/mpanel alert-send "Sentinela (continua): $name — $msg" --level crit --key "sn:$id" >/dev/null 2>&1
    elif [ "$status" = ok ] && [ "$prev" != ok ]; then
      jq -cn --arg i "$id" --arg n "$name" --argjson s "$since" --argjson t "$now" --arg m "$(jq -r --arg i "$id" '.[$i].msg // ""' <<<"$nst")" '{id:$i, name:$n, start:$s, end:$t, msg:$m, repaired:false}' >> "$inc"
      /usr/local/sbin/mpanel alert-send "Sentinela: $name voltou ao normal." --level ok --key "sn:$id" >/dev/null 2>&1
      since=0; sent=0
    fi
    nst=$(jq -c --arg i "$id" --arg s "$status" --arg m "$msg" --argjson si "$since" --argjson se "$sent" '.[$i] = {status:$s, msg:$m, since:$si, sent:$se}' <<<"$nst")
  done <<<"$SN_RES"
  printf '%s\n' "$nst" > "$st"
  [ -f "$inc" ] && tail -n 5000 "$inc" > "$inc.tmp" && mv -f "$inc.tmp" "$inc"
  awk -v s=$(( now - 7200 )) '$1 >= s' "$SN_DIR/sentinel-repairs.log" > "$SN_DIR/sentinel-repairs.tmp" 2>/dev/null && mv -f "$SN_DIR/sentinel-repairs.tmp" "$SN_DIR/sentinel-repairs.log"
  local f; for f in "$res" "$st" "$inc" "$av"; do [ -f "$f" ] && { chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"; }; done
  echo "Sentinela: $(printf '%s' "$SN_RES" | awk -F'\t' 'NF { n++; if ($4 == "ok") o++; else if ($4 == "warn") w++; else f++; if ($6 == 1) r++ } END { printf "%d testes, %d ok, %d avisos, %d falhas, %d reparados", n, o, w, f, r }') em $(( now - t0 )) s."
}
cmd_sentinel_settings(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --repair) case "${2:-}" in on) snset REPAIR 1 ;; off) snset REPAIR 0 ;; *) die "--repair on|off" ;; esac ;;
      --sites) case "${2:-}" in on) snset SITES 1 ;; off) snset SITES 0 ;; *) die "--sites on|off" ;; esac ;;
      --off) local re='^[a-z0-9:._ -]*$'; [[ "${2:-}" =~ $re ]] || die "Lista inválida."; snset OFF "${2:-}" ;;
      *) die "Opção desconhecida: $1" ;;
    esac
    shift 2 || shift
  done
  echo "Sentinela: definições guardadas."; return 0
}

# ============================ DESEMPENHO =====================================
CACHE_ROOT=/var/cache/minipainel/fcgi
PERF_NGX=/etc/nginx/minipainel/conf.d/perf.conf
perf_ngx_write(){ # formato de log com tempos, regras de exclusão da cache e zonas por site
  local n
  install -d -m 755 /etc/nginx/minipainel/conf.d
  {
    echo "# IDDigital Hosting — desempenho (gerado pelo painel; não editar à mão)"
    echo "log_format mpcombined '\$remote_addr - \$remote_user [\$time_local] \"\$request\" \$status \$body_bytes_sent \"\$http_referer\" \"\$http_user_agent\" rt=\$request_time urt=\$upstream_response_time cs=\$upstream_cache_status';"
    cat <<'EOF'
# nunca guardar em cache: pedidos que não sejam GET/HEAD, sessões iniciadas, carrinhos e áreas privadas
map $request_method $mp_nc_m { default 1; GET 0; HEAD 0; }
map $http_cookie $mp_nc_c { default 0; "~*(wordpress_logged_in|wordpress_sec|wp-postpass|comment_author|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session|edd_items_in_cart|PrestaShop-|OCSESSID|PHPSESSID|mp_nocache)" 1; }
map $request_uri $mp_nc_u { default 0; "~*(/wp-admin|/wp-login\.php|/xmlrpc\.php|/wp-json/|/wc-api/|/cart|/carrinho|/checkout|/finalizar|/my-account|/minha-conta|/admin|/administrator|route=(checkout|account)|add-to-cart=|preview=true|/feed)" 1; }
map "$mp_nc_m$mp_nc_c$mp_nc_u" $mp_nocache { default 1; "000" 0; }
# WebP: entregar imagem.jpg.webp (se existir) a browsers que o aceitem
map $http_accept $mp_webp { default ""; "~*image/webp" ".webp"; }
gzip_comp_level 5;
gzip_min_length 256;
gzip_proxied any;
EOF
    if [ "$(srv_get BROTLI 0)" = 1 ] && brotli_ok; then
      echo "brotli on; brotli_static on; brotli_comp_level 5; brotli_min_length 256;"
      echo "brotli_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml application/rss+xml image/svg+xml application/wasm font/ttf font/otf application/vnd.ms-fontobject;"
    fi
    for n in $(site_names); do
      [ "$(site_get "$n" CACHE)" -gt 0 ] 2>/dev/null || continue
      install -d -o "$WEB_USER" -g "$WEB_GROUP" -m 750 "$CACHE_ROOT/$n"
      echo "fastcgi_cache_path $CACHE_ROOT/$n levels=1:2 keys_zone=mp_$n:16m max_size=1g inactive=2h use_temp_path=off;"
    done
  } > "$PERF_NGX"
  chmod 644 "$PERF_NGX"
}
perf_ngx_cache(){ # site -> linhas da cache para o bloco PHP (vazio se desligada)
  local n=$1 ttl; ttl=$(site_get "$n" CACHE); [[ "$ttl" =~ ^[0-9]+$ ]] && [ "$ttl" -gt 0 ] || return 0
  cat <<EOF
        fastcgi_cache mp_$n;
        fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
        fastcgi_cache_valid 200 301 302 ${ttl}s;
        fastcgi_cache_valid 404 60s;
        fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_bypass \$mp_nocache;
        fastcgi_no_cache \$mp_nocache;
        add_header X-Cache \$upstream_cache_status always;
EOF
}
cmd_site_perf(){ # site [--cache …] [--pm …] [--max-children N] [--slowlog S] [--redis on|off] [--redis-mem MB] [--static-days D] [--webp on|off] [--webp-auto on|off]
  local n="${1:-}" c pm mc sl rd rm sd wp wa; [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  c=$(site_get "$n" CACHE); pm=$(site_get "$n" PM); mc=$(site_get "$n" MAXCH); sl=$(site_get "$n" SLOW)
  rd=$(site_get "$n" REDIS); rm=$(site_get "$n" REDIS_MB); sd=$(site_get "$n" STATIC_DAYS); wp=$(site_get "$n" WEBP); wa=$(site_get "$n" WEBP_AUTO)
  while [ $# -gt 0 ]; do
    case "$1" in
      --redis) case "${2:-}" in on) rd=1 ;; off) rd=0 ;; *) die "--redis on|off" ;; esac; shift 2 || shift ;;
      --redis-mem) rm="${2:-}"; shift 2 || shift ;;
      --static-days) sd="${2:-}"; shift 2 || shift ;;
      --webp) case "${2:-}" in on) wp=1 ;; off) wp=0 ;; *) die "--webp on|off" ;; esac; shift 2 || shift ;;
      --webp-auto) case "${2:-}" in on) wa=1 ;; off) wa=0 ;; *) die "--webp-auto on|off" ;; esac; shift 2 || shift ;;
      --cache) c="${2:-}"; shift 2 || shift ;; --pm) pm="${2:-}"; shift 2 || shift ;;
      --max-children) mc="${2:-}"; shift 2 || shift ;; --slowlog) sl="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  c=${c:-0}; pm=${pm:-ondemand}; mc=${mc:-10}; sl=${sl:-5}
  [[ "$c" =~ ^(0|60|300|600|1800|3600)$ ]] || die "Cache: 0 (desligada), 60, 300, 600, 1800 ou 3600 segundos."
  [[ "$pm" =~ ^(ondemand|dynamic)$ ]] || die "Processos: ondemand (a pedido) ou dynamic (sempre prontos)."
  [[ "$mc" =~ ^[0-9]{1,3}$ ]] && [ "$mc" -ge 2 ] && [ "$mc" -le 200 ] || die "Máximo de processos entre 2 e 200."
  [[ "$sl" =~ ^[0-9]{1,2}$ ]] && [ "$sl" -le 60 ] || die "Registo de scripts lentos: 0 (desligado) a 60 segundos."
  rd=${rd:-0}; rm=${rm:-128}; sd=${sd:-30}; wp=${wp:-1}; wa=${wa:-0}
  [[ "$rm" =~ ^(32|64|128|256|512|1024)$ ]] || die "Memória do Redis: 32, 64, 128, 256, 512 ou 1024 MB."
  [[ "$sd" =~ ^(0|7|30|365)$ ]] || die "Cache no browser: 0 (desligada), 7, 30 ou 365 dias."
  site_set "$n" CACHE "$c"; site_set "$n" PM "$pm"; site_set "$n" MAXCH "$mc"; site_set "$n" SLOW "$sl"
  site_set "$n" STATIC_DAYS "$sd"; site_set "$n" WEBP "$wp"; site_set "$n" WEBP_AUTO "$wa"
  if [ "$rd" = 1 ]; then rds_enable "$n" "$rm"; site_set "$n" REDIS 1; site_set "$n" REDIS_MB "$rm"
  elif [ "$(site_get "$n" REDIS)" = 1 ]; then rds_disable "$n"; site_set "$n" REDIS 0; fi
  write_pool "$n" "$(site_get "$n" PHP)"; apply_php "$(site_get "$n" PHP)"
  write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"
  [ "$c" = 0 ] && rm -rf "${CACHE_ROOT:?}/$n"
  apply_nginx || die "Configuração do nginx inválida."
  [ "$rd" = 1 ] && echo "Redis de $n ativo ($rm MB): socket $(rds_sock "$n")."
  echo "Desempenho de $n: cache $([ "$c" = 0 ] && echo desligada || echo "de $c s"); estáticos $([ "$sd" = 0 ] && echo 'sem cache no browser' || echo "em cache no browser $sd dias")$([ "$wp" = 1 ] && echo ', WebP automático'); processos PHP $([ "$pm" = dynamic ] && echo 'sempre prontos' || echo 'a pedido') (máx. $mc); scripts lentos $([ "$sl" = 0 ] && echo 'não registados' || echo "registados acima de $sl s")."
  return 0
}
cmd_perf_sync(){ # reescreve os pools PHP de todos os sites (atualizações)
  local n v; for n in $(site_names); do write_pool "$n" "$(site_get "$n" PHP)"; done
  for v in $(php_installed); do apply_php "$v" >/dev/null 2>&1; done
  echo "Pools PHP dos sites atualizados."; return 0
}
cmd_cache_purge(){ local n="${1:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  if [ -d "$CACHE_ROOT/$n" ]; then find "$CACHE_ROOT/$n" -mindepth 1 -delete 2>/dev/null; fi
  echo "Cache do site $n limpa."; return 0; }
# ---------- OPcache (por versão de PHP) ----------
php_confd(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/conf.d"; else echo "/etc/opt/remi/php$(php_vv "$1")/php.d"; fi; }
opc_mem_auto(){ local m; m=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo); [ "$m" -ge 3500 ] && echo 256 || echo 128; }
opcache_write(){
  local v mem rv d
  mem=$(srv_get OPC_MEM auto); [ "$mem" = auto ] && mem=$(opc_mem_auto); rv=$(srv_get OPC_REVAL 60)
  for v in $(php_installed); do
    d=$(php_confd "$v"); [ -d "$d" ] || continue
    printf '; IDDigital Hosting — desempenho do PHP (gerado pelo painel; não editar à mão)\nopcache.enable=1\nopcache.memory_consumption=%s\nopcache.interned_strings_buffer=16\nopcache.max_accelerated_files=30000\nopcache.validate_timestamps=1\nopcache.revalidate_freq=%s\nopcache.save_comments=1\nrealpath_cache_size=4096K\nrealpath_cache_ttl=600\n' "$mem" "$rv" > "$d/99-minipainel.ini"
    chmod 644 "$d/99-minipainel.ini"
  done
}
cmd_opcache_settings(){
  local mem rv
  mem=$(srv_get OPC_MEM auto); rv=$(srv_get OPC_REVAL 60)
  while [ $# -gt 0 ]; do case "$1" in --memory) mem="${2:-}"; shift 2 || shift ;; --revalidate) rv="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  [ "$mem" = auto ] || { [[ "$mem" =~ ^[0-9]{2,4}$ ]] && [ "$mem" -ge 64 ] && [ "$mem" -le 2048 ]; } || die "Memória do OPcache: auto ou 64 a 2048 MB."
  [[ "$rv" =~ ^[0-9]{1,4}$ ]] && [ "$rv" -le 3600 ] || die "Verificação de alterações: 0 a 3600 segundos."
  srv_set OPC_MEM "$mem"; srv_set OPC_REVAL "$rv"; opcache_write
  local v; for v in $(php_installed); do apply_php "$v" >/dev/null 2>&1; done
  echo "OPcache: $([ "$mem" = auto ] && echo "$(opc_mem_auto) MB (automático)" || echo "$mem MB"); alterações aos ficheiros detetadas $([ "$rv" = 0 ] && echo 'em cada pedido' || echo "a cada $rv s")."
  return 0
}
cmd_opcache_reset(){ local v; for v in $(php_installed); do systemctl reload "$(php_service "$v")" >/dev/null 2>&1; done; echo "OPcache limpo em todas as versões de PHP."; return 0; }
# ---------- MariaDB ----------
db_cnf(){ if [ -d /etc/mysql/mariadb.conf.d ]; then echo /etc/mysql/mariadb.conf.d/90-minipainel.cnf; else echo /etc/my.cnf.d/90-minipainel.cnf; fi; }
db_slowlog(){ if [ -d /var/log/mysql ]; then echo /var/log/mysql/mariadb-slow.log; else echo /var/log/mariadb/mariadb-slow.log; fi; }
db_svc(){ if systemctl list-unit-files mariadb.service 2>/dev/null | grep -q '^mariadb.service'; then echo mariadb; else echo mysql; fi; }
db_bp_auto(){ # 25% da RAM com email ativo, 35% sem; entre 128 MB e 70%
  local m p; m=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo); p=35; mail_on && p=25
  local b=$(( m * p / 100 / 64 * 64 )); [ "$b" -lt 128 ] && b=128; echo "$b"
}
cmd_db_tune(){ # [--buffer auto|MB] [--slow on|off] [--slow-time S]
  local bp st stt cnf old tmp m
  bp=$(srv_get DB_BP auto); st=$(srv_get DB_SLOW 1); stt=$(srv_get DB_SLOW_T 2)
  while [ $# -gt 0 ]; do
    case "$1" in
      --buffer) bp="${2:-}"; shift 2 || shift ;;
      --slow) case "${2:-}" in on) st=1 ;; off) st=0 ;; *) die "--slow on|off" ;; esac; shift 2 || shift ;;
      --slow-time) stt="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  m=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  [ "$bp" = auto ] || { [[ "$bp" =~ ^[0-9]{3,6}$ ]] && [ "$bp" -ge 128 ] && [ "$bp" -le $(( m * 70 / 100 )) ]; } || die "Memória para dados: auto ou entre 128 MB e $(( m * 70 / 100 )) MB (70% da RAM)."
  [[ "$stt" =~ ^[0-9]{1,2}$ ]] && [ "$stt" -ge 1 ] || die "Tempo das consultas lentas: 1 a 99 segundos."
  srv_set DB_BP "$bp"; srv_set DB_SLOW "$st"; srv_set DB_SLOW_T "$stt"
  local b=$bp; [ "$b" = auto ] && b=$(db_bp_auto)
  cnf=$(db_cnf); install -d -m 755 "$(dirname "$cnf")"; old=$(mktemp); [ -f "$cnf" ] && cp -p "$cnf" "$old" || : > "$old"
  install -d -o mysql -g adm -m 2750 "$(dirname "$(db_slowlog)")" 2>/dev/null || install -d -o mysql -m 750 "$(dirname "$(db_slowlog)")"
  cat > "$cnf" <<EOF
# IDDigital Hosting — desempenho do MariaDB (gerado pelo painel; não editar à mão)
[mysqld]
innodb_buffer_pool_size = ${b}M
innodb_flush_method = O_DIRECT
max_connections = 200
table_open_cache = 4000
tmp_table_size = 64M
max_heap_table_size = 64M
slow_query_log = $([ "$st" = 1 ] && echo ON || echo OFF)
slow_query_log_file = $(db_slowlog)
long_query_time = $stt
EOF
  chmod 644 "$cnf"
  echo "A reiniciar o MariaDB (alguns segundos)..."
  if ! systemctl restart "$(db_svc)" >/dev/null 2>&1 || ! mysql -uroot -N -e 'SELECT 1' >/dev/null 2>&1; then
    # não arrancou: repõe a configuração anterior
    if [ -s "$old" ]; then cp -p "$old" "$cnf"; else rm -f "$cnf"; fi
    systemctl restart "$(db_svc)" >/dev/null 2>&1; rm -f "$old"
    die "O MariaDB não arrancou com a configuração nova; foi reposta a anterior. Detalhe: journalctl -u $(db_svc) -n 30"
  fi
  rm -f "$old"
  local real; real=$(mysql -uroot -N -e 'SELECT @@innodb_buffer_pool_size DIV 1048576' 2>/dev/null)
  [ "$real" = "$b" ] || warn "O MariaDB respondeu, mas ainda está com ${real:-?} MB para dados (esperado: $b MB). Reinicia-o: systemctl restart $(db_svc)"
  echo "MariaDB: ${b} MB para dados$([ "$bp" = auto ] && echo ' (automático)'); consultas lentas $([ "$st" = 1 ] && echo "registadas acima de $stt s" || echo 'não registadas')."
  return 0
}
cmd_db_slow_report(){ # resumo das consultas lentas para o painel
  local f out=$DATA/stats/db-slow.json; f=$(db_slowlog)
  if [ ! -s "$f" ] || ! command -v mysqldumpslow >/dev/null 2>&1; then echo '{"ts":'"$EPOCHSECONDS"',"rows":[]}' > "$out"
  else
    { mysqldumpslow -s t -t 25 "$f" 2>/dev/null || true; } | awk -v ts="$EPOCHSECONDS" '
      function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
      /^Count: / { if (q != "") emit(); match($0, /Count: [0-9]+/); c = substr($0, RSTART + 7, RLENGTH - 7)
        match($0, /Time=[0-9.]+s \([0-9.]+s\)/); t = substr($0, RSTART, RLENGTH); split(t, a, /[=s( )]+/); avg = a[2]; tot = a[3]
        rows = 0; if (match($0, /Rows(_sent)?=[0-9.]+/)) { rows = substr($0, RSTART, RLENGTH); sub(/.*=/, "", rows) }
        if (avg == "") avg = 0; if (tot == "") tot = 0
        u = $0; sub(/.*, /, "", u); q = " "; next }
      { if (q != "") q = q " " $0 }
      function emit() { gsub(/[ ]+/, " ", q); out = out (n++ ? "," : "") sprintf("{\"count\":%d,\"avg\":%s,\"total\":%s,\"rows\":%s,\"user\":\"%s\",\"query\":\"%s\"}", c, avg, tot, rows, esc(u), esc(substr(q, 2, 600))); q = "" }
      BEGIN { out = ""; n = 0 } END { if (q != "") emit(); printf "{\"ts\":%s,\"rows\":[%s]}\n", ts, out }' > "$out.tmp" && mv -f "$out.tmp" "$out"
  fi
  chown root:"$PANEL_SYSUSER" "$out"; chmod 640 "$out"
  echo "Relatório de consultas lentas atualizado."; return 0
}

pkg_install_soft(){ # pacotes… — instala um a um; os que não existirem são ignorados
  local p
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null 2>&1; done
  else
    dnf install -y -q "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do dnf install -y -q "$p" >/dev/null 2>&1; done
  fi
  return 0
}
# ---------- Redis por site (cache de objetos) ----------
RDS_CONF=/etc/minipainel/redis
rds_bin(){ command -v redis-server 2>/dev/null || echo /usr/bin/redis-server; }
rds_sock(){ echo "$WWW_ROOT/$1/tmp/redis.sock"; }
rds_unit_write(){
  cat > /etc/systemd/system/minipainel-redis@.service <<EOF
[Unit]
Description=IDDigital Hosting — Redis do site %i
After=network.target

[Service]
Type=simple
User=mp_%i
Group=mp_%i
UMask=0077
ExecStart=$(rds_bin) $RDS_CONF/%i.conf
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
}
php_ext_pkg(){ # versão extensão -> pacote
  if [ "$OS_FAMILY" = debian ]; then echo "php$1-$2"; else echo "php$(php_vv "$1")-php-pecl-$2"; fi
}
rds_enable(){ # site MB
  local n=$1 mb=$2 v; v=$(site_get "$n" PHP)
  command -v redis-server >/dev/null 2>&1 || { if [ "$OS_FAMILY" = debian ]; then pkg_install_soft redis-server; else pkg_install_soft redis; fi; }
  command -v redis-server >/dev/null 2>&1 || die "Não foi possível instalar o Redis."
  php_has_ext "$v" redis || pkg_install_soft "$(php_ext_pkg "$v" redis)"
  install -d -m 755 "$RDS_CONF"; install -d -o "mp_$n" -g "mp_$n" -m 2770 "$WWW_ROOT/$n/tmp"
  printf '# IDDigital Hosting — Redis do site %s (gerado pelo painel)\nport 0\nunixsocket %s\nunixsocketperm 600\ndaemonize no\nmaxmemory %smb\nmaxmemory-policy allkeys-lru\nsave ""\nappendonly no\ndir %s\nlogfile ""\ndatabases 4\n' \
    "$n" "$(rds_sock "$n")" "$mb" "$WWW_ROOT/$n/tmp" > "$RDS_CONF/$n.conf"
  chmod 644 "$RDS_CONF/$n.conf"
  rds_unit_write
  systemctl enable "minipainel-redis@$n" >/dev/null 2>&1; systemctl restart "minipainel-redis@$n" >/dev/null 2>&1
  apply_php "$v" >/dev/null 2>&1
}
rds_disable(){ local n=$1; systemctl disable --now "minipainel-redis@$n" >/dev/null 2>&1; rm -f "$RDS_CONF/$n.conf" "$(rds_sock "$n")"; }
php_has_ext(){ "$(php_cli "$1")" -m 2>/dev/null | grep -qix "$2"; }
# ---------- WebP ----------
webp_bin(){ command -v cwebp 2>/dev/null; }
cmd_site_webp(){ # site [--quiet] — converte .jpg/.jpeg/.png em ficheiro.ext.webp (com o utilizador do site)
  local n="${1:-}" q="${2:-}" c
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  [ -n "$(webp_bin)" ] || { if [ "$OS_FAMILY" = debian ]; then pkg_install_soft webp; else pkg_install_soft libwebp-tools; fi; }
  [ -n "$(webp_bin)" ] || die "Não foi possível instalar o conversor de WebP (cwebp)."
  c=$(runuser -u "mp_$n" -- nice -n 15 ionice -c3 bash -c '
    n=0; s=0
    while IFS= read -r -d "" f; do
      [ "$(stat -c %s "$f")" -le 20971520 ] || continue
      if [ ! -e "$f.webp" ] || [ "$f" -nt "$f.webp" ]; then
        if timeout 60 "$1" -quiet -q 82 -metadata none "$f" -o "$f.webp.tmp" 2>/dev/null; then
          if [ "$(stat -c %s "$f.webp.tmp")" -lt "$(stat -c %s "$f")" ]; then mv -f "$f.webp.tmp" "$f.webp"; n=$((n+1)); else rm -f "$f.webp.tmp"; s=$((s+1)); fi
        else rm -f "$f.webp.tmp"; fi
      fi
    done < <(find "$2" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0 2>/dev/null)
    echo "$n $s"' _ "$(webp_bin)" "$WWW_ROOT/$n/public_html")
  [ "$q" = --quiet ] || echo "WebP de $n: ${c%% *} imagens convertidas; ${c##* } ignoradas (o WebP ficava maior)."
  return 0
}
cmd_webp_nightly(){ local n; for n in $(site_names); do [ "$(site_get "$n" WEBP_AUTO)" = 1 ] && cmd_site_webp "$n" --quiet; done; return 0; }
# ---------- rede (TCP BBR) e compressão ----------
NET_SYSCTL=/etc/sysctl.d/90-minipainel-net.conf
cmd_net_tune(){ # on|off
  case "${1:-on}" in
    off) rm -f "$NET_SYSCTL"; sysctl -q -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1; srv_set NET_TUNE 0; echo "Afinação de rede desligada (volta ao normal no próximo arranque)."; return 0 ;;
    on) ;; *) die "Usa: mpanel net-tune on|off" ;;
  esac
  modprobe tcp_bbr >/dev/null 2>&1; echo tcp_bbr > /etc/modules-load.d/minipainel-bbr.conf 2>/dev/null
  local k v ok=0 fail=0 line
  { echo "# IDDigital Hosting — rede (gerado pelo painel)"
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && { echo "net.core.default_qdisc = fq"; echo "net.ipv4.tcp_congestion_control = bbr"; }
    printf 'net.core.somaxconn = 4096\nnet.ipv4.tcp_max_syn_backlog = 8192\nnet.ipv4.tcp_fastopen = 3\nnet.ipv4.tcp_slow_start_after_idle = 0\nnet.ipv4.tcp_mtu_probing = 1\n'; } > "$NET_SYSCTL"
  while IFS= read -r line; do
    [[ "$line" == \#* || -z "$line" ]] && continue
    k=${line%% =*}; v=${line#*= }
    if sysctl -q -w "$k=$v" >/dev/null 2>&1; then ok=$((ok+1)); else fail=$((fail+1)); sed -i "\\|^$k = |d" "$NET_SYSCTL"; fi   # num contentor alguns valores não se podem mudar
  done < "$NET_SYSCTL"
  srv_set NET_TUNE 1
  echo "Rede afinada: $ok parâmetros aplicados$([ "$fail" -gt 0 ] && echo ", $fail não permitidos neste sistema"); controlo de congestionamento: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)."
  return 0
}
brotli_ok(){ [ -n "$(ls /etc/nginx/modules-enabled/*brotli* /usr/share/nginx/modules/*brotli* 2>/dev/null)" ]; }
cmd_brotli(){ # on|off
  case "${1:-on}" in
    on) brotli_ok || { if [ "$OS_FAMILY" = debian ]; then pkg_install_soft libnginx-mod-http-brotli-filter libnginx-mod-http-brotli-static; else pkg_install_soft nginx-mod-brotli; fi; }
        brotli_ok || die "O módulo Brotli do nginx não está disponível neste sistema (fica só o gzip)."
        srv_set BROTLI 1 ;;
    off) srv_set BROTLI 0 ;;
    *) die "Usa: mpanel brotli on|off" ;;
  esac
  perf_ngx_write; apply_nginx || { srv_set BROTLI 0; perf_ngx_write; apply_nginx; die "O nginx recusou a configuração do Brotli; foi desligado."; }
  echo "Brotli $([ "$(srv_get BROTLI 0)" = 1 ] && echo ligado || echo desligado)."; return 0
}
perf_static_loc(){ # site -> bloco dos ficheiros estáticos (cache no browser e WebP)
  local n=$1 d w; d=$(site_get "$n" STATIC_DAYS); [[ "$d" =~ ^[0-9]+$ ]] || d=30; w=$(site_get "$n" WEBP); [ -n "$w" ] || w=1
  [ "$d" -gt 0 ] || [ "$w" = 1 ] || return 0
  if [ "$w" = 1 ]; then cat <<EOF
    location ~* \\.(?:jpe?g|png)\$ {
        add_header Vary Accept;
$([ "$d" -gt 0 ] && printf '        expires %sd;\n        add_header Cache-Control "public";\n' "$d")
        try_files \$uri\$mp_webp \$uri \$uri/ /index.php?\$query_string;
    }
EOF
  fi
  [ "$d" -gt 0 ] && cat <<EOF
    location ~* \\.(?:css|js|mjs|woff2?|ttf|otf|eot|svg|ico|gif|webp|avif|mp4|webm|pdf)\$ {
        expires ${d}d;
        add_header Cache-Control "public";
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
EOF
  return 0
}

write_state(){
  local n v st sites phps dbs
  sites=$(for n in $(site_names); do
      jq -cn --arg name "$n" --arg port "$(site_get "$n" PORT)" --arg php "$(site_get "$n" PHP)" \
        --arg en "$(site_get "$n" ENABLED)" --arg root "$WWW_ROOT/$n/public_html" \
        --arg mem "$(lim_get "$n" MEM)" --arg up "$(lim_get "$n" UPLOAD)" --arg ex "$(lim_get "$n" EXEC)" \
        --arg it "$(lim_get "$n" INPUT_TIME)" --arg iv "$(lim_get "$n" INPUT_VARS)" --arg de "$(lim_get "$n" DISPLAY_ERRORS)" \
        --arg doms "$(site_get "$n" DOMAINS)" --arg ssl "$(site_get "$n" SSL)" --arg hs "$(site_get "$n" HTTPS)" --arg www "$(site_get "$n" WWW)" \
        --arg prd "$(site_get "$n" REDIS)" --arg prm "$(site_get "$n" REDIS_MB)" --arg psd "$(site_get "$n" STATIC_DAYS)" --arg pwp "$(site_get "$n" WEBP)" --arg pwa "$(site_get "$n" WEBP_AUTO)" --arg psk "$(rds_sock "$n")" \
        --arg pc "$(site_get "$n" CACHE)" --arg ppm "$(site_get "$n" PM)" --arg pmc "$(site_get "$n" MAXCH)" --arg psl "$(site_get "$n" SLOW)" \
        --arg ftp "$(site_get "$n" FTP)" --arg sexp "$(cert_expiry "mp-$n")" --arg cok "$( [ -n "$(site_get "$n" DOMAINS)" ] && [ "$(site_get "$n" SSL)" != none ] && cert_files "mp-$n" >/dev/null && echo 1)" \
        '{name:$name, port:($port|tonumber), php:$php, enabled:($en=="1"), root:$root,
          limits:{memory:($mem|tonumber), upload:($up|tonumber), exec:($ex|tonumber),
                  input_time:($it|tonumber), input_vars:($iv|tonumber), display_errors:($de=="1")},
          domains:$doms, ssl:(if $ssl == "" then "none" else $ssl end), https:(if $hs == "" then "1" else $hs end), www:(if $www == "" then "keep" else $www end),
          ssl_exp:(if $sexp == "" then null else ($sexp|tonumber) end), https_ok:($cok == "1"), ftp:($ftp == "1"),
          perf:{cache:(($pc | tonumber?) // 0), pm:(if $ppm == "" then "ondemand" else $ppm end), maxch:(($pmc | tonumber?) // 10), slow:(($psl | tonumber?) // 5),
                redis:($prd == "1"), redis_mb:(($prm | tonumber?) // 128), static_days:(($psd | tonumber?) // 30), webp:($pwp != "0"), webp_auto:($pwa == "1"), sock:$psk}}'
    done | jq -cs '.')
  pkg_cache_load
  phps=$(for v in $(php_installed); do
      local exts mods en ed inst
      st=$(systemctl is-active "$(php_service "$v")" 2>/dev/null)
      exts=$(while IFS='|' read -r en _ _ ed; do
          inst=false; ext_installed_pkg "$en" "$v" >/dev/null && inst=true
          jq -cn --arg n "$en" --arg d "$ed" --argjson i "$inst" '{name:$n, desc:$d, installed:$i}'
        done < <(ext_catalog) | jq -cs '.')
      mods=$("$(php_cli "$v")" -m 2>/dev/null | grep -v -e '^\[' -e '^$' | sort -fu | jq -R . | jq -cs '.')
      jq -cn --arg v "$v" --arg s "$st" --argjson e "${exts:-[]}" --argjson m "${mods:-[]}" \
        '{version:$v, active:($s=="active"), extensions:$e, modules:$m}'
    done | jq -cs '.')
  local svcs host ip os up disk ram load cpus pmav dbadm=false
  pmav=$(pma_version)
  dbuser_exists "$DB_ADMIN" && dbadm=true
  svcs=$( {
      jq -cn --arg s "$(systemctl is-active nginx 2>/dev/null)" '{id:"nginx", name:"nginx", unit:"nginx", active:($s=="active")}'
      jq -cn --arg s "$(systemctl is-active mariadb 2>/dev/null)" '{id:"mariadb", name:"MariaDB", unit:"mariadb", active:($s=="active")}'
      for v in $(php_installed); do
        jq -cn --arg v "$v" --arg u "$(php_service "$v")" --arg s "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)" --arg p "$PANEL_PHP" \
          '{id:("php-"+$v), name:("PHP-FPM "+$v), unit:$u, active:($s=="active"), panel:($v==$p), version:$v}'
      done
      if mail_on; then
        for v in postfix dovecot rspamd redis unbound; do
          u=$v; [ "$v" = redis ] && u=$(mail_svc_redis)
          jq -cn --arg i "$v" --arg u "$u" --arg s "$(systemctl is-active "$u" 2>/dev/null)" \
            '{id:$i, name:({"postfix":"Postfix (SMTP)","dovecot":"Dovecot (IMAP/POP3)","rspamd":"Rspamd (antispam)","redis":"Redis","unbound":"Unbound (DNS)"}[$i]), unit:$u, active:($s=="active"), mail:true}'
        done
        if [ "$(mail_get CLAMAV 0)" = 1 ]; then u=clamav-daemon; [ "$OS_FAMILY" = debian ] || u=clamd@scan
          jq -cn --arg u "$u" --arg s "$(systemctl is-active "$u" 2>/dev/null)" '{id:"clamav", name:"ClamAV (antivírus)", unit:$u, active:($s=="active"), mail:true}'; fi
      fi
    } | jq -cs '.')
  host=$(hostname 2>/dev/null)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  os=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
  disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo 2>/dev/null)
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  cpus=$(nproc 2>/dev/null)
  dbs=$(db_sizes | while IFS=$'\t' read -r n v; do
      [ -n "$n" ] && jq -cn --arg n "$n" --arg s "$v" --arg site "$(dbmap_load | jq -r --arg d "$n" '.[$d] // ""')" '{name:$n, size_mb:($s|tonumber), site:$site}'
    done | jq -cs '.')
  local j_crons j_mail j_snaps
  j_crons=$(cron_state_json 2>/dev/null); j_mail=$(mail_state_json 2>/dev/null); j_snaps=$(upd_snaps_json 2>/dev/null)
  sites=$(jv sites "$sites" '[]'); phps=$(jv php "$phps" '[]'); dbs=$(jv databases "$dbs" '[]'); svcs=$(jv services "$svcs" '[]')
  dbadm=$(jv db_admin "$dbadm" 'false'); j_crons=$(jv crons "$j_crons" '[]'); j_mail=$(jv mail "$j_mail" '{"enabled":false}'); j_snaps=$(jv snaps "$j_snaps" '[]')
  jq -n --argjson sites "${sites:-[]}" --argjson php "${phps:-[]}" --argjson dbs "${dbs:-[]}" --argjson svcs "${svcs:-[]}" \
    --arg host "$host" --arg ip "$ip" --arg os "$os" --arg up "${up:-0}" --arg disk "${disk:-0}" --arg ram "${ram:-0}" \
    --arg load "${load:-0}" --arg cpus "${cpus:-1}" --arg pport "$PANEL_PORT" --arg pphp "$PANEL_PHP" \
    --arg pmav "$pmav" --argjson dbadm "$dbadm" --arg dbadmu "$DB_ADMIN" --argjson crons "$j_crons" \
    --argjson mail "$j_mail" \
    --argjson usnaps "$j_snaps" \
    --argjson fti "$(ftp_installed && echo true || echo false)" --arg ftpl "$(ftp_get PLAIN 0)" --arg ftip "$(ftp_get PASV_IP)" \
    --argjson jdns "$(jv dns "$(dns_state_json 2>/dev/null)" '{"enabled":false}')" --arg ldays "$(logs_days)" \
    --argjson jgeo "$(jv geo "$(geo_state_json 2>/dev/null)" '{}')" \
    --argjson jal "$(jv alerts "$(alerts_state_json 2>/dev/null)" '{}')" \
    --arg snr "$(snget REPAIR 1)" --arg sns "$(snget SITES 1)" --arg sno "$(snget OFF '')" \
    --arg pf_opm "$(srv_get OPC_MEM auto)" --arg pf_opa "$(opc_mem_auto)" --arg pf_opr "$(srv_get OPC_REVAL 60)" --arg pf_dbp "$(srv_get DB_BP auto)" --arg pf_dba "$(db_bp_auto)" \
    --arg pf_net "$(srv_get NET_TUNE 0)" --arg pf_cc "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" --arg pf_br "$(srv_get BROTLI 0)" --arg pf_bro "$(brotli_ok && echo 1 || echo 0)" \
    --arg pf_dbs "$(srv_get DB_SLOW 1)" --arg pf_dbt "$(srv_get DB_SLOW_T 2)" --arg pf_ram "$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)" \
    --arg prs "$(pget SSH 1)" --arg prsf "$(pget SSH_FAILS 5)" --arg prpf "$(pget PANEL_FAILS 10)" --arg praf "$(pget AUTH_FAILS "$(mail_get AUTH_FAILS 10)")" \
    --arg prw "$(pget WINDOW 10)" --arg prb1 "$(pget BAN1 1h)" --arg prb2 "$(pget BAN2 24h)" --arg prb3 "$(pget BAN3 7d)" \
    --arg prr "$(awk -v s=$(( EPOCHSECONDS - 86400 )) '$1 >= s' "$DATA/stats/ban-history.txt" 2>/dev/null | wc -l)" \
    --arg pss "$(pma_get SESSION 120)" --arg pse "$(pma_get EXEC 600)" --arg psu "$(pma_get UPLOAD 512)" \
    --arg spa "$(srv_get PORTS_ACCESS all)" --arg spal "$(srv_get PANEL_ALLOW '')" \
    --arg smode "$(srv_get MODE lan)" --arg semail "$(srv_get EMAIL '')" --arg spd "$(srv_get PANEL_DOMAIN '')" --arg spssl "$(srv_get PANEL_SSL le)" --arg spexp "$( [ -n "$(srv_get PANEL_DOMAIN '')" ] && cert_expiry mp-painel)" \
    --arg defphp "$DEFAULT_PHP" --arg gen "$(date '+%Y-%m-%d %H:%M:%S')" --arg ver "$MP_VERSION" \
    --arg ng "$(systemctl is-active nginx 2>/dev/null)" --arg db "$(systemctl is-active mariadb 2>/dev/null)" \
    '{version:$ver, generated:$gen, default_php:$defphp, php:$php, sites:$sites, databases:$dbs,
      services:{nginx:($ng=="active"), mariadb:($db=="active")}, service_list:$svcs,
      pma:{installed:($pmav!=""), version:$pmav}, db_admin:{user:$dbadmu, exists:$dbadm}, crons:$crons,
      mail:$mail,
      updates:{snaps:$usnaps},
      ftp:{installed:$fti, plain:($ftpl == "1"), pasv_ip:$ftip},
      pma_settings:{session:($pss|tonumber), exec:($pse|tonumber), upload:($psu|tonumber)},
      dns:$jdns, log_days:($ldays|tonumber), geo:$jgeo, alerts:$jal,
      sentinel:{repair:($snr == "1"), sites:($sns == "1"), off:$sno},
      perf:{opc_mem:$pf_opm, opc_mem_auto:($pf_opa|tonumber), opc_reval:($pf_opr|tonumber), db_bp:$pf_dbp, db_bp_auto:($pf_dba|tonumber), db_slow:($pf_dbs == "1"), db_slow_t:($pf_dbt|tonumber), ram_mb:($pf_ram|tonumber),
            net:($pf_net == "1"), cc:$pf_cc, brotli:($pf_br == "1"), brotli_ok:($pf_bro == "1")},
      protect:{ssh:($prs == "1"), ssh_fails:($prsf|tonumber), panel_fails:($prpf|tonumber), auth_fails:($praf|tonumber), window:($prw|tonumber), ban1:$prb1, ban2:$prb2, ban3:$prb3, recent:($prr|tonumber)},
      server:{mode:$smode, email:$semail, panel_domain:$spd, panel_ssl:$spssl, panel_ssl_exp:(if $spexp == "" then null else ($spexp|tonumber) end), ports_access:$spa, panel_allow:$spal},
      system:{hostname:$host, ip:$ip, os:$os, uptime:($up|tonumber), disk:($disk|tonumber), ram:($ram|tonumber),
              load:$load, cpus:($cpus|tonumber), panel_port:($pport|tonumber), panel_php:$pphp}}' > "$STATE.tmp" || { rm -f "$STATE.tmp"; return 1; }
  chown root:"$PANEL_SYSUSER" "$STATE.tmp"; chmod 640 "$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE"
}

write_result(){
  local id=$1 rc=$2 msg=$3 okv=false
  [ "$rc" -eq 0 ] && okv=true
  jq -n --arg id "$id" --argjson ok "$okv" --arg msg "$msg" '{id:$id, ok:$ok, msg:$msg}' > "$RESULTS/.$id.tmp"
  chown root:"$PANEL_SYSUSER" "$RESULTS/.$id.tmp"; chmod 640 "$RESULTS/.$id.tmp"
  mv -f "$RESULTS/.$id.tmp" "$RESULTS/$id.json"
}

# Processa a fila do painel (chamado pelo minipainel-worker.service)
cmd_worker(){
  local f id action out rc re='^[a-f0-9]{16}$'
  local -a files args
  shopt -s nullglob
  find "$RESULTS" -type f -mmin +30 -delete 2>/dev/null
  find "$DATA/tmp" -type f -mmin +60 -delete 2>/dev/null
  while :; do
    files=("$QUEUE"/*.json)
    [ ${#files[@]} -eq 0 ] && break
    for f in "${files[@]}"; do
      id=$(jq -r '.id // empty' "$f" 2>/dev/null)
      action=$(jq -r '.action // empty' "$f" 2>/dev/null)
      mapfile -t args < <(jq -r '(.args // []) | .[] | tostring' "$f" 2>/dev/null)
      rm -f "$f"
      [[ "$id" =~ $re ]] || continue
      case "$action" in
        site-add|site-del|site-php|site-enable|site-disable|site-fixperms|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|db-link|pma-update|panel-passwd-hash|service|block|unblock|allow-add|allow-del|fw-auto|cron-add|cron-edit|cron-del|cron-on|cron-off|cron-run|backup-start|bk-restore|bk-delete|bk-conf|bk-remote-add|bk-remote-test|bk-remote-del|site-domains|server-mode|panel-domain|panel-allow|ports-access|panel-user|panel-2fa|bk-key|mail-enable|mail-domain-add|mail-domain-del|mail-box-add|mail-box-set|mail-box-del|mail-alias-set|mail-alias-del|mail-settings|mail-av|mail-dns-check|mail-site|mail-queue|mail-list|site-ftp|ftp-settings|pma-settings|protect-settings|dns-enable|dns-zone-add|dns-zone-del|dns-rec-add|dns-rec-del|dns-sync|dns-check|logs-settings|terminal-start|terminal-stop|geoip-update|geo-block|overload-settings|alerts-settings|alerts-test|proc-kill|proc-kill-site|sentinel-run|sentinel-settings|site-perf|cache-purge|opcache-settings|opcache-reset|db-tune|db-slow-report|site-webp|net-tune|brotli|update-token|update-check|update-start|update-rollback|update-key|os-check|os-start|os-auto|reboot|refresh)
          out=$(dispatch "$action" "${args[@]}" 2>&1); rc=$? ;;
        *)
          out="Ação não permitida."; rc=1 ;;
      esac
      if ! write_state 2>/dev/null; then
        out="${out:+$out
}AVISO: não foi possível gerar o estado do painel (corre 'mpanel state' no servidor para ver o erro)."
        [ "$rc" -eq 0 ] && [ "$action" = refresh ] && rc=1
      fi
      write_result "$id" "$rc" "$out"
    done
  done
  return 0
}

usage(){
  cat <<'EOF'
IDDigital Hosting — CLI v2.12.1 (mpanel)
Uso: mpanel <comando> [argumentos]

Sites
  site-list
  site-add <nome> [--port N] [--php X.Y] [opções de limites, ver site-limits]
  site-del <nome> [--keep-files]
  site-php <nome> <X.Y>
  site-enable <nome>
  site-disable <nome>
  site-fixperms <nome>
  site-limits <nome>                       mostra os limites
  site-limits <nome> [--memory MB] [--upload MB] [--exec S]
                     [--input-time S] [--input-vars N] [--display-errors 0|1]

Extensões PHP (por versão; afetam todos os sites dessa versão)
  ext-list [X.Y]
  ext-add <X.Y> <extensão>
  ext-del <X.Y> <extensão>

Bases de dados (utilizador com o mesmo nome, acesso por localhost)
  db-list
  db-add <nome> [password]
  db-del <nome>
  db-passwd <nome> [password]
  db-admin-passwd [password]   cria ou muda a conta de administração (mpadmin)

phpMyAdmin (https://IP:PORTA-DO-PAINEL/phpmyadmin/, requer sessão no painel)
  pma-update [--force]         instala ou atualiza para a versão oficial mais recente

Serviços
  service <nginx|mariadb|php-X.Y> <reload|restart|start|stop>
  stats                 utilização atual do servidor e de cada site

DNS autoritativo (NSD; só responde pelas zonas do painel)
  dns-enable --ns1 ns1.dominio.pt --ns2 ns2.dominio.pt [--ip IP] [--ip6 IPv6] [--hostmaster email]
  dns-zone-add|dns-zone-del <domínio>       zona com registos automáticos (sites, email, nameservers)
  dns-rec-add <zona> <nome> <tipo> <valor> [--ttl N] [--prio N]   tipos: A AAAA CNAME MX TXT NS SRV CAA
  dns-rec-del <zona> <id> | dns-sync [zona|all] | dns-check <zona>

Desempenho
  site-perf <site> [--cache 0|60|300|600|1800|3600] [--pm ondemand|dynamic] [--max-children N] [--slowlog 0..60]
  cache-purge <site>                   limpa a cache de página do site
  site-perf … [--redis on|off] [--redis-mem MB] [--static-days 0|7|30|365] [--webp on|off] [--webp-auto on|off]
  site-webp <site>                     converte as imagens JPG/PNG do site em WebP (imagem.jpg.webp)
  net-tune on|off                      afinação de rede (TCP BBR, filas maiores)
  brotli on|off                        compressão Brotli no nginx (além do gzip)
  opcache-settings [--memory auto|MB] [--revalidate S] · opcache-reset
  db-tune [--buffer auto|MB] [--slow on|off] [--slow-time S]   afina o MariaDB (reinicia-o; repõe se falhar)
  db-slow-report                       resume as consultas lentas para o painel

Sentinela (testa todos os serviços a cada minuto; repara e alerta)
  sentinel-run                         corre todos os testes agora
  sentinel-settings [--repair on|off] [--sites on|off] [--off "id id"]

Processos
  proc-kill <pid> [--force]            termina um processo (os essenciais são recusados)
  proc-kill-site <site> [--force]      termina todos os processos de um site

Alertas (SMS por bulksms.com e email pelo servidor de email deste servidor)
  alerts-settings [--sms on|off] [--sms-id ID] [--sms-secret S] [--sms-to +351…] [--email on|off] [--email-to x@y]
                  [--cpu 90] [--cpu-min 5] [--ram 90] [--disk 90] [--conn 70] [--mail-pct 20] [--mail-min 50]
  alerts-test                          envia uma mensagem de teste
  alert-send "texto"                   envia um alerta pelos canais ativos

Países e limite de ligações
  geoip-update                         atualiza a base de países (DB-IP Lite, CC BY 4.0; todos os meses sozinha)
  geo-block add|del <país>             bloqueia ligações novas de um país (ex.: CN)
  overload-settings [--on|--off] [--max auto|N] [--start 80] [--stop 60] [--home PT]
                                       ao chegar ao limite só aceita ligações novas do país do servidor

Terminal no painel (root; só com 2FA; sessões gravadas 90 dias em /var/log/minipainel/terminal)
  terminal-stop                        fecha o terminal aberto pelo painel

Logs dos sites (/var/log/minipainel/sites e /srv/www/<site>/logs)
  logs-settings --days N               dias a guardar (7 a 365; omissão 90)

Proteção contra força bruta (SSH, painel, email, webmail, FTP)
  protect-settings [--ssh on|off] [--ssh-fails N] [--panel-fails N] [--auth-fails N] [--window MIN]
                   [--ban1 1h] [--ban2 24h] [--ban3 7d|perm]   bloqueio; reincidentes em 30 dias: 2.ª e 3.ª+ vez

FTP / SFTP (uma conta por site; a mesma password nos dois)
  site-ftp <site> [--password P]       ativa ou muda a password (FTPS: utilizador <site>; SFTP: mp_<site>)
  site-ftp <site> --off                desativa
  ftp-settings [--plain on|off] [--pasv-ip IP|none]   FTP sem cifra; IP público para o modo passivo (NAT)
  pma-settings [--session MIN] [--exec S] [--upload MB]   tempos e limites do phpMyAdmin

Atualizações
  update-token set <github_pat_…> | clear   token do GitHub só de leitura (repositório privado)
  update-check                         procura uma versão nova do painel (version.json ou, se não existir, o install.sh)
  update-start [--allow-unsigned]      atualiza o painel (cópia automática e reposição se falhar)
  update-rollback [ficheiro]           repõe uma cópia anterior do painel
  update-key set "<PEM>" | clear       chave pública que assina as versões
  os-check | os-start [--security]     atualizações do sistema operativo
  os-auto on|off                       atualizações de segurança automáticas
  reboot                               reinicia o servidor dentro de 1 minuto

Email (Postfix + Dovecot + Rspamd)
  mail-enable --host mail.dominio.pt   instala e ativa o email
  mail-domain-add|mail-domain-del <domínio>
  mail-dns-info <domínio> | mail-dns-check <domínio>
  mail-box-add <email> [--password P] [--quota MB]    (sem password: gerada)
  mail-box-set <email> [--password P] [--quota MB] | mail-box-del <email>
  mail-alias-set <alias@dom|@dom> "dest1 dest2" | mail-alias-del <alias>
  mail-site <site> --limit N | --suspend | --resume | --purge   envio do mail() de cada site
  mail-queue list|flush|delete <id>|all
  mail-settings [--dnsbl "zona1 zona2"|none] [--site-limit N] [--box-limit N] [--auth-fails N]
  mail-av on|off                       antivírus ClamAV (~1,2 GB de RAM)
  mail-list allow|deny add|del <email|@domínio|IP>   listas de remetentes permitidos e bloqueados

Segurança do painel
  panel-allow "IP rede/24 ..."|none    IPs autorizados a abrir o painel (none = todos)
  panel-user <nome>                    muda o nome de utilizador do painel
  panel-2fa off                        desativa a verificação em dois passos (recuperação na consola)
  ports-access all|lan                 portas dos sites abertas a todos ou só à rede local

Modo do servidor, domínios e SSL
  server-mode lan|internet [--email endereço]
  site-domains <site> --set "loja.pt www.loja.pt" [--ssl le|self|none] [--https 1|0] [--www keep|www|root]
  panel-domain <domínio>|none [--ssl le|self]
  ssl-renew                            renova os certificados Let's Encrypt (é automático)
  ngx-sync                             regenera a configuração nginx de todos os sites

Backups (local em /var/backups/minipainel + destinos remotos via rclone)
  backup-run [--site <site>|_bd|_sistema] [--remote <destino>]   faz backup agora
  bk-list [site]
  bk-restore <site>|_bd <id> [--what all|files|db]   repõe (faz antes um backup do estado atual)
  bk-delete <site> <id>
  bk-conf [--on|--off] [--time 03:00] [--daily 7] [--weekly 4] [--monthly 3] [--remote <destino>|none]
  bk-remote-add <nome> sftp --host H --user U --pass P [--port 22] [--path pasta]
  bk-remote-add <nome> s3 --access A --secret S --bucket B [--endpoint E] [--region R] [--provider Other]
  bk-remote-add <nome> rclone --config "[nome]\ntype = drive\n..."
  bk-remote-test <nome> | bk-remote-del <nome>
  bk-key | bk-key-set <chave>          chave que assina os backups (precisa dela para repor noutro servidor)
  db-link <base-de-dados> <site>|none   associa uma base de dados a um site (entra nos backups dele)

Tarefas agendadas (cron; correm como o utilizador do site)
  cron-list [site]
  cron-add <site> --when "*/5 * * * *" --cmd "php /srv/www/<site>/public_html/cron.php" [--label texto] [--off]
  cron-edit <site> <id> [--when ...] [--cmd ...] [--label ...]
  cron-on|cron-off|cron-run|cron-del <site> <id>
  cron-sync                            regenera os ficheiros de /etc/cron.d

Ligações e firewall (bloqueio em todas as portas, incluindo SSH)
  conn-list [ip]                       ligações abertas por IP
  block <ip|rede> [--for 1h|24h|7d|perm] [--reason texto]
  unblock <ip|rede>
  block-list
  allow-add <ip|rede> | allow-del <ip|rede>   IPs de confiança (nunca bloqueados)
  fw-auto on|off [--limit N] [--duration 1h]  bloqueio automático por excesso de ligações
  fw-restore                           repõe a tabela nftables e os bloqueios

Gestor de ficheiros
  fm-sync               recria os processos do gestor de ficheiros de todos os sites

Sistema
  php-list
  status
  passwd [--random]     muda a password do painel
  state                 regenera o estado lido pelo painel
EOF
}

dispatch(){
  local c="$1"; shift
  case "$c" in
    site-list)         cmd_site_list ;;
    site-add)          cmd_site_add "$@" ;;
    site-del)          cmd_site_del "$@" ;;
    site-php)          cmd_site_php "$@" ;;
    site-enable)       cmd_site_toggle "${1:-}" 1 ;;
    site-disable)      cmd_site_toggle "${1:-}" 0 ;;
    site-fixperms)     cmd_site_fixperms "$@" ;;
    site-limits)       cmd_site_limits "$@" ;;
    ext-list)          cmd_ext_list "$@" ;;
    ext-add)           cmd_ext_add "$@" ;;
    ext-del)           cmd_ext_del "$@" ;;
    db-list)           cmd_db_list ;;
    db-add)            cmd_db_add "$@" ;;
    db-del)            cmd_db_del "$@" ;;
    db-passwd)         cmd_db_passwd "$@" ;;
    db-admin-passwd)   cmd_db_admin_passwd "$@" ;;
    pma-update)        cmd_pma_update "$@" ;;
    php-list)          cmd_php_list ;;
    service)           cmd_service "$@" ;;
    stats)             cmd_stats ;;
    conn-list)         cmd_conn_list "$@" ;;
    block)             cmd_block "$@" ;;
    unblock)           cmd_unblock "$@" ;;
    block-list)        cmd_block_list ;;
    allow-add)         cmd_allow_add "$@" ;;
    allow-del)         cmd_allow_del "$@" ;;
    fw-auto)           cmd_fw_auto "$@" ;;
    fw-restore)        cmd_fw_restore ;;
    cron-list)         cmd_cron_list "$@" ;;
    cron-add)          cmd_cron_add "$@" ;;
    cron-edit)         cmd_cron_edit "$@" ;;
    cron-del)          cmd_cron_del "$@" ;;
    cron-on)           cmd_cron_toggle "${1:-}" "${2:-}" true ;;
    cron-off)          cmd_cron_toggle "${1:-}" "${2:-}" false ;;
    cron-run)          cmd_cron_run "$@" ;;
    cron-sync)         cmd_cron_sync ;;
    db-link)           cmd_db_link "$@" ;;
    site-domains)      cmd_site_domains "$@" ;;
    server-mode)       cmd_server_mode "$@" ;;
    panel-domain)      cmd_panel_domain "$@" ;;
    ssl-renew)         cmd_ssl_renew ;;
    ngx-sync)          cmd_ngx_sync ;;
    panel-allow)       cmd_panel_allow "$@" ;;
    ports-access)      cmd_ports_access "$@" ;;
    panel-user)        cmd_panel_user "$@" ;;
    panel-2fa)         cmd_panel_2fa "$@" ;;
    mail-enable)       cmd_mail_enable "$@" ;;
    mail-domain-add)   cmd_mail_domain_add "$@" ;;
    mail-domain-del)   cmd_mail_domain_del "$@" ;;
    mail-box-add)      cmd_mail_box_add "$@" ;;
    mail-box-set)      cmd_mail_box_set "$@" ;;
    mail-box-del)      cmd_mail_box_del "$@" ;;
    mail-alias-set)    cmd_mail_alias_set "$@" ;;
    mail-alias-del)    cmd_mail_alias_del "$@" ;;
    mail-settings)     cmd_mail_settings "$@" ;;
    mail-av)           cmd_mail_av "$@" ;;
    mail-dns-check)    cmd_mail_dns_check "$@" ;;
    mail-dns-info)     cmd_mail_dns_info "$@" ;;
    mail-site)         cmd_mail_site "$@" ;;
    mail-queue)        cmd_mail_queue "$@" ;;
    mail-list)         cmd_mail_list "$@" ;;
    site-ftp)          cmd_site_ftp "$@" ;;
    ftp-settings)      cmd_ftp_settings "$@" ;;
    pma-settings)      cmd_pma_settings "$@" ;;
    protect-settings)  cmd_protect_settings "$@" ;;
    dns-enable)        cmd_dns_enable "$@" ;;
    dns-zone-add)      cmd_dns_zone_add "$@" ;;
    dns-zone-del)      cmd_dns_zone_del "$@" ;;
    dns-rec-add)       cmd_dns_rec_add "$@" ;;
    dns-rec-del)       cmd_dns_rec_del "$@" ;;
    dns-sync)          cmd_dns_sync "$@" ;;
    dns-check)         cmd_dns_check "$@" ;;
    logs-settings)     cmd_logs_settings "$@" ;;
    terminal-start)    cmd_terminal_start "$@" ;;
    terminal-stop)     cmd_terminal_stop ;;
    geoip-update)      cmd_geoip_update ;;
    alerts-settings)   cmd_alerts_settings "$@" ;;
    proc-kill)         cmd_proc_kill "$@" ;;
    sentinel-settings) cmd_sentinel_settings "$@" ;;
    site-perf)         cmd_site_perf "$@" ;;
    cache-purge)       cmd_cache_purge "$@" ;;
    perf-sync)         cmd_perf_sync ;;
    site-webp)         cmd_site_webp "$@" ;;
    webp-nightly)      cmd_webp_nightly ;;
    net-tune)          cmd_net_tune "$@" ;;
    brotli)            cmd_brotli "$@" ;;
    opcache-settings)  cmd_opcache_settings "$@" ;;
    opcache-reset)     cmd_opcache_reset ;;
    db-tune)           cmd_db_tune "$@" ;;
    db-slow-report)    cmd_db_slow_report ;;
    sentinel-run)      cmd_sentinel_run ;;
    proc-kill-site)    cmd_proc_kill_site "$@" ;;
    alerts-test)       cmd_alerts_test ;;
    geo-block)         cmd_geo_block "$@" ;;
    overload-settings) cmd_overload_settings "$@" ;;
    trust-sync)        trust_apply; echo "IPs de confiança atualizados na firewall." ;;
    conf-lock)         conf_lock ;;
    update-check)      cmd_update_check ;;
    update-start)      cmd_update_start "$@" ;;
    update-rollback)   cmd_update_rollback "$@" ;;
    update-key)        cmd_update_key "$@" ;;
    update-token)      cmd_update_token "$@" ;;
    os-check)          cmd_os_check ;;
    os-start)          cmd_os_start "$@" ;;
    os-auto)           cmd_os_auto "$@" ;;
    reboot)            cmd_reboot ;;
    backup-start)      cmd_backup_start "$@" ;;
    bk-list)           cmd_bk_list "$@" ;;
    bk-restore)        cmd_bk_restore "$@" ;;
    bk-delete)         cmd_bk_delete "$@" ;;
    bk-conf)           cmd_bk_conf "$@" ;;
    bk-init)           cmd_bk_init ;;
    bk-remote-add)     cmd_bk_remote_add "$@" ;;
    bk-remote-test)    cmd_bk_remote_test "$@" ;;
    bk-remote-del)     cmd_bk_remote_del "$@" ;;
    bk-key)            cmd_bk_key ;;
    bk-key-set)        cmd_bk_key_set "$@" ;;
    fm-sync)           cmd_fm_sync ;;
    status)            cmd_status ;;
    passwd)            cmd_passwd "$@" ;;
    panel-passwd-hash) cmd_panel_hash "$@" ;;
    state|refresh)     return 0 ;;
    *)                 die "Comando desconhecido: $c (usa 'mpanel help')." ;;
  esac
}

# ---------- main ----------
cmd="${1:-help}"
case "$cmd" in
  help|-h|--help)       usage; exit 0 ;;
  version|-v|--version) echo "IDDigital Hosting $MP_VERSION (MiniPainel)"; exit 0 ;;
esac
[ "$(id -u)" -eq 0 ] || die "Tem de ser executado como root."
# o backup usa o seu próprio bloqueio, para não impedir as outras operações do painel
if [ "$cmd" = backup-run ]; then shift; cmd_backup_run "$@"; exit $?; fi
if [ "$cmd" = mail-spool ]; then cmd_mail_spool; exit $?; fi
# o envio de alertas só lê a configuração e escreve o histórico: nunca espera por outra operação
if [ "$cmd" = alert-send ]; then shift; cmd_alert_send "$@"; exit $?; fi
# o sentinela tem o seu próprio bloqueio: uma operação longa do painel nunca o atrasa
if [ "$cmd" = sentinel-run ]; then cmd_sentinel_run; exit $?; fi
# as atualizações têm bloqueio próprio: o instalador volta a chamar o mpanel durante a instalação
if [ "$cmd" = update-run ]; then shift; cmd_update_run "$@"; exit $?; fi
if [ "$cmd" = os-run ]; then shift; cmd_os_run "$@"; exit $?; fi
exec 9>"$LOCK"
flock -w 300 9 || die "Outra operação do painel está em curso."

if [ "$cmd" = worker ]; then cmd_worker; exit 0; fi

dispatch "$@"; rc=$?
if [ "$rc" -eq 0 ]; then
  case "$cmd" in
    site-add|site-del|site-php|site-enable|site-disable|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|pma-update|service|cron-add|cron-edit|cron-del|cron-on|cron-off|site-domains|server-mode|panel-domain|ngx-sync|panel-allow|ports-access|panel-user|panel-2fa|mail-enable|mail-domain-add|mail-domain-del|mail-box-add|mail-box-set|mail-box-del|mail-alias-set|mail-alias-del|mail-settings|mail-av|mail-site|mail-queue|mail-list|state|refresh)
      write_state || { echo "ERRO: não foi possível gerar o estado do painel ($STATE)." >&2; rc=1; } ;;
  esac
fi
exit "$rc"
MPCLI
chmod 750 /usr/local/sbin/mpanel

# ----------------------------------------------------------------------------
# 8. Worker (fila do painel) e logrotate
# ----------------------------------------------------------------------------
say "A configurar o worker..."
cat > /etc/systemd/system/minipainel-worker.service <<'EOF'
[Unit]
Description=IDDigital Hosting - processa as tarefas do painel
After=network.target mariadb.service nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mpanel worker
TimeoutStartSec=1800
EOF
cat > /etc/systemd/system/minipainel-worker.path <<'EOF'
[Unit]
Description=IDDigital Hosting - vigia a fila de tarefas do painel

[Path]
DirectoryNotEmpty=/var/lib/minipainel/queue
Unit=minipainel-worker.service

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable minipainel-worker.path >/dev/null 2>&1
systemctl restart minipainel-worker.path

say "A instalar o recolhedor de estatísticas..."
install -d -o root -g minipainel -m 750 /var/lib/minipainel/stats /var/lib/minipainel/stats/traffic
cat > /usr/local/sbin/mpanel-stats <<'MPSTATS'
#!/usr/bin/env bash
# =============================================================================
#  mpanel-stats — recolhedor de estatísticas do IDDigital Hosting v2.12.1
#  Lê o /proc a cada 5 s e grava:
#    live.json        valores atuais (servidor e por site)
#    hist-1m.csv      médias por minuto   (24 h)
#    hist-10m.csv     médias por 10 min   (7 dias)
#    hist-1h.csv      médias por hora     (30 dias)
#    sites.json       disco (de hora a hora) e tráfego das últimas 24 h por site
#    traffic/<site>.csv  pedidos e bytes por hora (30 dias), lidos dos logs do nginx
#  Colunas do histórico: ts,cpu,mem,swap,disk (em décimas de %),load (x100),rx,tx (bit/s)
# =============================================================================
set -uo pipefail
# shellcheck source=/dev/null
. /etc/minipainel/minipainel.conf 2>/dev/null
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DIR=/var/lib/minipainel/stats
TDIR=$DIR/traffic
SITES_DIR=/etc/minipainel/sites
WWW_ROOT=/srv/www
GRP=${PANEL_SYSUSER:-minipainel}
INTERVAL=5
TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
NCPU=$(nproc 2>/dev/null || echo 1)

install -d -o root -g "$GRP" -m 750 "$DIR" "$TDIR"

perm(){ chown root:"$GRP" "$1" 2>/dev/null; chmod 640 "$1" 2>/dev/null; return 0; }
put(){ local tmp="$1.tmp"; printf '%s\n' "$2" > "$tmp" && perm "$tmp" && mv -f "$tmp" "$1"; }
d10(){ printf '%d.%d' $(( $1 / 10 )) $(( $1 % 10 )); }
trim(){ local f=$1 max=$2 n; n=$(wc -l < "$f" 2>/dev/null || echo 0); if [ "$n" -gt $(( max + 30 )) ]; then tail -n "$max" "$f" > "$f.tmp" && perm "$f.tmp" && mv -f "$f.tmp" "$f"; fi; }
site_names(){ local f; for f in "$SITES_DIR"/*.conf; do [ -f "$f" ] && basename "$f" .conf; done; return 0; }

read_cpu(){
  local l; read -r l < /proc/stat
  # shellcheck disable=SC2086
  set -- $l; shift
  local idle=$(( $4 + ${5:-0} )) tot=0 x
  for x in "$@"; do tot=$(( tot + x )); done
  tot=$(( tot - ${9:-0} - ${10:-0} ))
  echo "$tot $idle"
}
read_mem(){ awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{printf "%d %d %d %d\n", t, t-a, st, st-sf}' /proc/meminfo; }
read_disk(){ df -Pk / 2>/dev/null | awk 'NR==2{print $2, $3, $4}'; }
read_net(){ awk 'NR>2{sub(/:/," "); if ($1 != "lo") { rx += $2; tx += $10 }} END{printf "%.0f %.0f\n", rx, tx}' /proc/net/dev; }

# ---------- CPU e memória por site (processos dos utilizadores mp_<site>) ----------
declare -A PREV_TICKS=() SITE_CPU=() SITE_RSS=()
sample_sites(){
  local dtus=$1 first=$2 pid user rss site t
  local -A cur=() owner=()
  local -a files=()
  SITE_CPU=(); SITE_RSS=()
  while read -r pid user rss; do
    [[ "$user" == mp_* ]] || continue
    site=${user#mp_}
    SITE_RSS[$site]=$(( ${SITE_RSS[$site]:-0} + rss ))
    owner[$pid]=$site
    files+=("/proc/$pid/stat")
  done < <(ps -eo pid=,user:40=,rss= 2>/dev/null)
  if [ ${#files[@]} -gt 0 ]; then
    while read -r pid t; do
      [ -n "${owner[$pid]:-}" ] || continue
      cur[$pid]=$t
      site=${owner[$pid]}
      if [ "$first" = 0 ]; then
        if [ -n "${PREV_TICKS[$pid]:-}" ]; then t=$(( t - ${PREV_TICKS[$pid]} )); fi
        [ "$t" -lt 0 ] && t=0
        SITE_CPU[$site]=$(( ${SITE_CPU[$site]:-0} + t ))
      fi
    done < <(awk '{ n = split(FILENAME, a, "/"); p = a[3]; sub(/^.*\) /, ""); print p, $12 + $13 }' "${files[@]}" 2>/dev/null)
  fi
  PREV_TICKS=()
  for pid in "${!cur[@]}"; do PREV_TICKS[$pid]=${cur[$pid]}; done
  # ticks -> décimas de % da capacidade total do servidor
  local v
  for site in "${!SITE_CPU[@]}"; do
    v=${SITE_CPU[$site]}
    v=$(( v * 1000 * 1000000 / (TCK * dtus * NCPU) ))
    [ "$v" -gt 1000 ] && v=1000
    SITE_CPU[$site]=$v
  done
}

# ---------- tráfego por site (leitura incremental dos logs do nginx) ----------
update_traffic(){
  local n log pos ino size oino off req bytes hour now
  now=$EPOCHSECONDS; hour=$(( now / 3600 * 3600 ))
  for n in $(site_names); do
    log=/var/log/minipainel/sites/$n/access.log; [ -f "$log" ] || log=/var/log/nginx/mp-$n.access.log
    pos=$TDIR/$n.pos
    [ -f "$log" ] || continue
    ino=$(stat -c %i "$log" 2>/dev/null) || continue
    size=$(stat -c %s "$log" 2>/dev/null) || continue
    if [ ! -f "$pos" ]; then echo "$ino $size" > "$pos"; continue; fi
    read -r oino off < "$pos"
    if [ "$oino" != "$ino" ] || [ "$size" -lt "${off:-0}" ]; then off=0; fi
    if [ "$size" -gt "$off" ]; then
      read -r req bytes < <(tail -c +$(( off + 1 )) "$log" 2>/dev/null | head -c $(( size - off )) |
        awk '{ n++; if (match($0, /" [0-9][0-9][0-9] [0-9]+ /)) { split(substr($0, RSTART + 2, RLENGTH - 3), f, " "); b += f[2] } } END { printf "%d %.0f\n", n, b }')
      if [ "${req:-0}" -gt 0 ]; then
        [ -f "$TDIR/$n.csv" ] || { : > "$TDIR/$n.csv"; perm "$TDIR/$n.csv"; }
        awk -F, -v h="$hour" -v r="$req" -v b="$bytes" 'BEGIN{OFS=","}
          { rows[NR] = $0; last = $1 }
          END {
            if (NR > 0 && last == h) { split(rows[NR], x, ","); rows[NR] = h "," (x[2] + r) "," sprintf("%.0f", x[3] + b); m = NR }
            else { m = NR + 1; rows[m] = h "," r "," b }
            s = (m > 720) ? m - 719 : 1
            for (i = s; i <= m; i++) print rows[i]
          }' "$TDIR/$n.csv" > "$TDIR/$n.csv.tmp" && perm "$TDIR/$n.csv.tmp" && mv -f "$TDIR/$n.csv.tmp" "$TDIR/$n.csv"
      fi
    fi
    echo "$ino $size" > "$pos"
  done
}

# ---------- disco por site (de hora a hora) ----------
declare -A SITE_DISK=()
update_disk(){
  local n b
  SITE_DISK=()
  for n in $(site_names); do
    b=$(nice -n 19 timeout 300 du -sb "$WWW_ROOT/$n" 2>/dev/null | awk '{print $1}')
    SITE_DISK[$n]=${b:-0}
  done
}

write_sites_json(){
  local n r b since o="" sep=""
  since=$(( EPOCHSECONDS - 86400 ))
  for n in $(site_names); do
    r=0; b=0
    if [ -f "$TDIR/$n.csv" ]; then
      read -r r b < <(awk -F, -v s="$since" '$1 >= s - 3599 { r += $2; b += $3 } END { printf "%d %.0f\n", r, b }' "$TDIR/$n.csv")
    fi
    o+="$sep\"$n\":{\"disk\":${SITE_DISK[$n]:-0},\"req24\":${r:-0},\"bytes24\":${b:-0}}"
    sep=","
  done
  put "$DIR/sites.json" "{\"ts\":$EPOCHSECONDS,\"disk_ts\":$DISK_TS,\"sites\":{$o}}"
}

aggregate(){ # origem destino início fim máximo
  tail -n 200 "$1" 2>/dev/null | awk -F, -v s="$3" -v e="$4" '
    $1 >= s && $1 < e { n++; for (i = 2; i <= 8; i++) a[i] += $i }
    END { if (n) { printf "%d", s; for (i = 2; i <= 8; i++) printf ",%.0f", a[i] / n; print "" } }' >> "$2"
  perm "$2"; trim "$2" "$5"
}

# ---------- ligações abertas (só às portas em escuta neste servidor) ----------
declare -A FW_RECENT=()
FW_AUTO=0; FW_LIMIT=150; FW_DUR=3600
read_fw_conf(){
  local f=/etc/minipainel/firewall.conf
  FW_AUTO=$(grep -m1 '^AUTO=' "$f" 2>/dev/null | cut -d= -f2); FW_AUTO=${FW_AUTO:-0}
  FW_LIMIT=$(grep -m1 '^LIMIT=' "$f" 2>/dev/null | cut -d= -f2); FW_LIMIT=${FW_LIMIT:-150}
  FW_DUR=$(grep -m1 '^DURATION=' "$f" 2>/dev/null | cut -d= -f2); FW_DUR=${FW_DUR:-3600}
}
sample_conns(){
  local lp raw tot syn dist ips c ip k
  lp=$(ss -Htln 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' | sort -u | tr '\n' ' ')
  raw=$(ss -Htna 2>/dev/null | awk -v lp=" $lp " '
    BEGIN { n = split(lp, L, " "); for (i = 1; i <= n; i++) if (L[i] != "") lport[L[i]] = 1 }
    $1 == "ESTAB" || $1 == "SYN-RECV" {
      k = split($4, a, ":"); p = a[k]
      if (!(p in lport)) next
      ip = $5; sub(/:[0-9]+$/, "", ip); gsub(/[\[\]]/, "", ip); sub(/^::ffff:/, "", ip); sub(/%.*/, "", ip)
      if (ip == "127.0.0.1" || ip == "::1") next
      cnt[ip]++; if ($1 == "SYN-RECV") syn[ip]++
      pc[ip, p]++
    }
    END {
      for (key in pc) { split(key, q, SUBSEP); ports[q[1]] = ports[q[1]] (ports[q[1]] == "" ? "" : ",") q[2] ":" pc[key] }
      for (ip in cnt) printf "%d\t%s\t%d\t%s\n", cnt[ip], ip, syn[ip] + 0, ports[ip]
    }')
  read -r tot syn dist < <(printf '%s\n' "$raw" | awk -F'\t' 'NF >= 2 { t += $1; s += $3; n++ } END { print t + 0, s + 0, n + 0 }')
  ips=$(printf '%s\n' "$raw" | grep -v '^$' | sort -t$'\t' -k1,1nr | head -n 500 | awk -F'\t' '
    BEGIN { printf "[" }
    { m = split($4, P, ","); ps = ""; for (i = 1; i <= m; i++) { split(P[i], kv, ":"); ps = ps (i > 1 ? "," : "") "\"" kv[1] "\":" kv[2] }
      printf "%s{\"ip\":\"%s\",\"n\":%d,\"syn\":%d,\"ports\":{%s}}", (NR > 1 ? "," : ""), $2, $1, $3, ps }
    END { printf "]" }')
  put "$DIR/conns.json" "{\"ts\":$EPOCHSECONDS,\"total\":${tot:-0},\"syn\":${syn:-0},\"distinct\":${dist:-0},\"ips\":${ips:-[]}}"
  # bloqueio automático
  if [ "$FW_AUTO" = 1 ] && [ -x /usr/local/sbin/mpanel ]; then
    for k in "${!FW_RECENT[@]}"; do [ "${FW_RECENT[$k]}" -lt "$EPOCHSECONDS" ] && unset "FW_RECENT[$k]"; done
    while IFS=$'\t' read -r c ip _ _; do
      [ -n "$ip" ] || continue
      [ "$c" -gt "$FW_LIMIT" ] || break
      [ -n "${FW_RECENT[$ip]:-}" ] && continue
      FW_RECENT[$ip]=$(( EPOCHSECONDS + 300 ))
      ( timeout 90 /usr/local/sbin/mpanel block "$ip" --for "${FW_DUR}s" --by auto --reason "Automático: $c ligações abertas" >/dev/null 2>&1 & )
    done < <(printf '%s\n' "$raw" | grep -v '^$' | sort -t$'\t' -k1,1nr)
  fi
}
fw_selfheal(){
  command -v nft >/dev/null 2>&1 || return 0
  [ -s /etc/minipainel/blocks.list ] || [ -f /etc/minipainel/firewall.conf ] || return 0
  nft list table inet minipainel >/dev/null 2>&1 || ( timeout 90 /usr/local/sbin/mpanel fw-restore >/dev/null 2>&1 & )
}

# ---------- último resultado das tarefas agendadas ----------
update_crons(){
  local n f id a b c t o="" sep="" re_n='^[0-9]+$' re_c='^(running|[0-9]+)$'
  for n in $(site_names); do
    for f in "$WWW_ROOT/$n"/logs/cron-*.status; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      id=${f##*/cron-}; id=${id%.status}
      [[ "$id" =~ ^[a-f0-9]{8}$ ]] || continue
      read -r a b c < <(runuser -u "mp_$n" -- cat "$f" 2>/dev/null)
      [[ "$a" =~ $re_n ]] && [[ "$b" =~ $re_n ]] && [[ "$c" =~ $re_c ]] || continue
      t='""'
      if [ -f "$WWW_ROOT/$n/logs/cron-$id.log" ] && [ ! -L "$WWW_ROOT/$n/logs/cron-$id.log" ]; then
        t=$(runuser -u "mp_$n" -- tail -n 20 "$WWW_ROOT/$n/logs/cron-$id.log" 2>/dev/null | cut -c1-500 | jq -Rs .)
      fi
      o+="$sep\"$n:$id\":{\"start\":$a,\"end\":$b,\"rc\":\"$c\",\"tail\":$t}"; sep=","
    done
  done
  put "$DIR/crons.json" "{\"ts\":$EPOCHSECONDS,\"runs\":{$o}}"
}

# ---------- email: fila dos sites e força bruta nas caixas ----------
mail_enabled(){ grep -q '^ENABLED=1$' /etc/minipainel/mail.conf 2>/dev/null; }
mail_spool_kick(){
  mail_enabled || return 0
  compgen -G "/var/spool/mp-mail/*/new/*.eml" >/dev/null 2>&1 || return 0
  ( setsid /usr/local/sbin/mpanel mail-spool >/dev/null 2>&1 & )
}
# ---------- proteção contra força bruta (SSH, painel, email, webmail, FTP) ----------
PROT_CONF=/etc/minipainel/protect.conf
pget(){ local v; v=$(grep -m1 "^$1=" "$PROT_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
jlog(){ # linhas do journal do último minuto para os identificadores dados (MP_TEST_JOURNAL só nos testes)
  if [ -n "${MP_TEST_JOURNAL:-}" ]; then cat "$MP_TEST_JOURNAL"; return 0; fi
  local a=() t; for t in "$@"; do a+=(-t "$t"); done
  journalctl -q --since "-65s" -o cat "${a[@]}" 2>/dev/null
}
auth_guard(){
  local f=$DIR/authfail.txt hist=$DIR/ban-history.txt now=$EPOCHSECONDS ipre='^[0-9a-fA-F:.]+$'
  touch "$f" "$hist"
  # SSH (todas as contas: root, utilizadores inexistentes, chaves recusadas, SFTP dos sites)
  if [ "$(pget SSH 1)" = 1 ]; then
    jlog sshd sshd-session | sed -nE \
      -e 's/.*Failed (password|publickey|keyboard-interactive\/pam|none) for (invalid user )?[^ ]* from ([0-9a-fA-F:.]+) port.*/\3/p' \
      -e 's/.*Invalid user [^ ]* from ([0-9a-fA-F:.]+) port.*/\1/p' \
      -e 's/.*maximum authentication attempts exceeded for (invalid user )?[^ ]* from ([0-9a-fA-F:.]+) port.*/\2/p' \
      -e 's/.*Connection closed by (invalid|authenticating) user [^ ]* ([0-9a-fA-F:.]+) port [0-9]+ \[preauth\].*/\2/p' \
      | grep -E "$ipre" | while read -r ip; do echo "$now $ip ssh"; done >> "$f"
  fi
  # FTP (Pure-FTPd)
  if [ -s /etc/pure-ftpd/pureftpd.passwd ]; then
    jlog pure-ftpd | sed -nE 's/^\(\?@([0-9a-fA-F:.]+)\) \[WARNING\] Authentication failed.*/\1/p' \
      | grep -E "$ipre" | while read -r ip; do echo "$now $ip auth"; done >> "$f"
  fi
  # Email (SMTP, IMAP, POP3) e webmail
  if grep -q '^ENABLED=1$' /etc/minipainel/mail.conf 2>/dev/null || [ -f /etc/minipainel/mail-enabled ]; then
    jlog postfix/submission/smtpd postfix/smtps/smtpd postfix/smtpd dovecot \
      | grep -E 'SASL [A-Z0-9-]+ authentication failed|auth failed' \
      | sed -nE 's/.*rip=([0-9a-fA-F:.]+).*/\1/p; s/^[^[]*\[([0-9a-fA-F:.]+)\]: SASL.*/\1/p' \
      | grep -E "$ipre" | while read -r ip; do echo "$now $ip auth"; done >> "$f"
    local wl=/var/lib/minipainel-webmail/logs/userlogins.log wp=$DIR/webmail-log.pos sz p
    if [ -f "$wl" ]; then
      sz=$(stat -c %s "$wl"); p=$(cat "$wp" 2>/dev/null || echo 0); [ "$sz" -lt "$p" ] && p=0
      tail -c +$(( p + 1 )) "$wl" | grep -a 'Failed login' | sed -nE 's/.* from ([0-9a-fA-F:.]+).*/\1/p' \
        | grep -E "$ipre" | while read -r ip; do echo "$now $ip auth"; done >> "$f"
      echo "$sz" > "$wp"
    fi
  fi
  # Painel (password ou código 2FA errados; lidos do registo de auditoria)
  local al=/var/lib/minipainel/logs/audit.log ap=$DIR/audit-log.pos
  if [ -f "$al" ]; then
    sz=$(stat -c %s "$al"); p=$(cat "$ap" 2>/dev/null || echo 0); [ "$sz" -lt "$p" ] && p=0
    tail -c +$(( p + 1 )) "$al" | jq -r 'select(.ok == false and ((.action // "") | test("^(Falha de início de sessão|Código de verificação em dois passos errado)"))) | .ip' 2>/dev/null \
      | grep -E "$ipre" | while read -r ip; do echo "$now $ip panel"; done >> "$f"
    echo "$sz" > "$ap"
  fi
  # contagem dentro da janela e bloqueio (mais longo para quem reincide em 30 dias)
  local win sshl panl authl
  win=$(( $(pget WINDOW 10) * 60 )); sshl=$(pget SSH_FAILS 5); panl=$(pget PANEL_FAILS 10); authl=$(pget AUTH_FAILS 10)
  awk -v s=$(( now - win )) '$1 >= s' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  awk -v s=$(( now - 2592000 )) '$1 >= s' "$hist" > "$hist.tmp" && mv -f "$hist.tmp" "$hist"
  awk '{ c[$2" "$3]++ } END { for (k in c) print c[k], k }' "$f" | while read -r n ip svc; do
    local lim=$authl name="email/FTP"
    case "$svc" in ssh) lim=$sshl; name="SSH" ;; panel) lim=$panl; name="painel" ;; esac
    [ "$n" -ge "$lim" ] || continue
    local prev dur
    prev=$(awk -v ip="$ip" '$2 == ip' "$hist" | wc -l)
    if [ "$prev" -ge 2 ]; then dur=$(pget BAN3 7d); elif [ "$prev" -eq 1 ]; then dur=$(pget BAN2 24h); else dur=$(pget BAN1 1h); fi
    if /usr/local/sbin/mpanel block "$ip" --for "$dur" --by auto --reason "Força bruta: $name ($n falhas)$([ "$prev" -gt 0 ] && echo ", reincidência $(( prev + 1 ))")" >/dev/null 2>&1; then
      echo "$now $ip" >> "$hist"
    fi
    awk -v ip="$ip" '$2 != ip' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  done
}

# ---------- limite de ligações com reserva para o país do servidor ----------
ovl_get(){ local v; v=$(grep -m1 "^$1=" /etc/minipainel/server.conf 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
ovl_cap(){
  local mx wp wc; mx=$(ovl_get OVL_MAX auto)
  if [ "$mx" != auto ]; then echo "$mx"; return; fi
  wp=$(grep -m1 -E '^\s*worker_processes' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';'); [[ "$wp" =~ ^[0-9]+$ ]] || wp=$(nproc 2>/dev/null || echo 1)
  wc=$(grep -m1 -E '^\s*worker_connections' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';'); [[ "$wc" =~ ^[0-9]+$ ]] || wc=768
  echo $(( wp * wc ))
}
ovl_rules_on(){
  nft -f - >/dev/null 2>&1 <<'EOF'
flush chain inet minipainel ovl
add rule inet minipainel ovl ip saddr @home4 return
add rule inet minipainel ovl ip6 saddr @home6 return
add rule inet minipainel ovl ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 100.64.0.0/10 } return
add rule inet minipainel ovl tcp dport 53 return
add rule inet minipainel ovl meta l4proto tcp ct state new counter reject with tcp reset
EOF
}
ovl_event(){ # registo na auditoria e para os alertas
  local m=$1
  printf '{"ts":%s,"ip":"servidor","user":"automático","action":"%s","ok":false}\n' "$EPOCHSECONDS" "$m" >> /var/lib/minipainel/logs/audit.log 2>/dev/null
  logger -t minipainel-audit "$m" 2>/dev/null
  printf '%s %s\n' "$EPOCHSECONDS" "$m" >> "$DIR/events.log"
}
overload_check(){
  command -v nft >/dev/null 2>&1 && nft list chain inet minipainel ovl >/dev/null 2>&1 || return 0
  local on tot cap st sp act since below now=$EPOCHSECONDS home OVL_STATE=$DIR/overload.json
  on=$(ovl_get OVL 1); home=$(ovl_get HOME_CC PT)
  tot=$(jq -r '.total // 0' "$DIR/conns.json" 2>/dev/null); [[ "$tot" =~ ^[0-9]+$ ]] || tot=0
  cap=$(ovl_cap); st=$(ovl_get OVL_ON 80); sp=$(ovl_get OVL_OFF 60)
  act=$(jq -r '.active // false' "$OVL_STATE" 2>/dev/null); since=$(jq -r '.since // 0' "$OVL_STATE" 2>/dev/null); below=$(jq -r '.below // 0' "$OVL_STATE" 2>/dev/null)
  if [ "$act" != true ]; then
    if [ "$on" = 1 ] && [ $(( tot * 100 )) -ge $(( cap * st )) ]; then
      ovl_rules_on; act=true; since=$now; below=0
      ovl_event "Modo de proteção ativado: $tot ligações (limite $(( cap * st / 100 ))); só são aceites ligações novas de $home e dos IPs de confiança"
    fi
  else
    [ "$(nft list chain inet minipainel ovl 2>/dev/null | grep -c reject)" = 0 ] && ovl_rules_on   # repõe as regras se a firewall foi recarregada
    if [ "$on" != 1 ] || [ $(( tot * 100 )) -lt $(( cap * sp )) ]; then
      [ "$below" = 0 ] && below=$now
      if [ "$on" != 1 ] || [ $(( now - below )) -ge 120 ]; then
        nft flush chain inet minipainel ovl >/dev/null 2>&1; act=false
        ovl_event "Modo de proteção desativado: $tot ligações; voltam a ser aceites ligações de todos os países"
        since=0; below=0
      fi
    else below=0; fi
  fi
  put "$OVL_STATE" "{\"active\":$act,\"since\":$since,\"below\":$below,\"total\":$tot,\"capacity\":$cap,\"start\":$st,\"stop\":$sp,\"home\":\"$home\",\"ts\":$now}"
}

# ---------- alertas (CPU, RAM, disco, ligações, modo de proteção, volume de email) ----------
al_get(){ local v; v=$(grep -m1 "^$1=" /etc/minipainel/alerts.conf 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
al_on(){ [ "$(al_get SMS_ON 0)" = 1 ] || [ "$(al_get EMAIL_ON 0)" = 1 ]; }
al_send(){ # chave nível texto (em segundo plano: o envio nunca atrasa a recolha)
  ( setsid /usr/local/sbin/mpanel alert-send "$3" --level "$2" --key "$1" >/dev/null 2>&1 < /dev/null & )
}
al_cond(){ # chave ativo(0/1) mensagem_disparo mensagem_resolvido
  local k=$1 on=$2 f=$DIR/alerts-state.json st fir sent now=$EPOCHSECONDS
  [ -s "$f" ] || echo '{}' > "$f"
  st=$(jq -c --arg k "$k" '.[$k] // {firing:false, sent:0}' "$f" 2>/dev/null) || st='{"firing":false,"sent":0}'
  fir=$(jq -r '.firing' <<<"$st"); sent=$(jq -r '.sent' <<<"$st")
  if [ "$on" = 1 ]; then
    if [ "$fir" != true ]; then al_send "$k" crit "$3"; fir=true; sent=$now
    elif [ $(( now - sent )) -ge 21600 ]; then al_send "$k" crit "Continua: $3"; sent=$now; fi   # lembrete a cada 6 h
  elif [ "$fir" = true ]; then al_send "$k" ok "$4"; fir=false; fi
  jq --arg k "$k" --argjson fr "$fir" --argjson s "$sent" '.[$k] = {firing:$fr, sent:$s}' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
alerts_tick(){ # médias do último minuto em milésimos: cpu ram disco
  al_on || return 0
  local f=$DIR/alerts-run.json cpu=$1 ram=$2 dsk=$3 lc lr lcn n_c n_r n_n tot cap pct ev p sz
  [ -s "$f" ] || echo '{"c":0,"r":0,"n":0}' > "$f"
  lc=$(al_get CPU 90); lr=$(al_get RAM 90); lcn=$(al_get CONN 70)
  n_c=$(jq -r '.c' "$f"); n_r=$(jq -r '.r' "$f"); n_n=$(jq -r '.n' "$f")
  if [ "$cpu" -ge $(( lc * 10 )) ]; then n_c=$(( n_c + 1 )); elif [ "$cpu" -lt $(( (lc - 10) * 10 )) ]; then n_c=0; fi
  if [ "$ram" -ge $(( lr * 10 )) ]; then n_r=$(( n_r + 1 )); elif [ "$ram" -lt $(( (lr - 5) * 10 )) ]; then n_r=0; fi
  tot=$(jq -r '.total // 0' "$DIR/overload.json" 2>/dev/null); cap=$(jq -r '.capacity // 0' "$DIR/overload.json" 2>/dev/null)
  [[ "$tot" =~ ^[0-9]+$ ]] || tot=0; [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] || cap=0
  pct=0; [ "$cap" -gt 0 ] && pct=$(( tot * 100 / cap ))
  if [ "$cap" -gt 0 ] && [ "$pct" -ge "$lcn" ]; then n_n=$(( n_n + 1 )); elif [ "$pct" -lt $(( lcn - 10 )) ]; then n_n=0; fi
  printf '{"c":%d,"r":%d,"n":%d}' "$n_c" "$n_r" "$n_n" > "$f"
  al_cond cpu "$([ "$n_c" -ge "$(al_get CPU_MIN 5)" ] && echo 1 || echo 0)" "CPU acima de ${lc}% há ${n_c} min (agora $(( cpu / 10 ))%)" "CPU normalizado ($(( cpu / 10 ))%)"
  al_cond ram "$([ "$n_r" -ge 5 ] && echo 1 || echo 0)" "RAM acima de ${lr}% há ${n_r} min (agora $(( ram / 10 ))%)" "RAM normalizada ($(( ram / 10 ))%)"
  al_cond disk "$([ "$dsk" -ge $(( $(al_get DISK 90) * 10 )) ] && echo 1 || { [ "$dsk" -ge $(( ($(al_get DISK 90) - 5) * 10 )) ] && jq -e '.disk.firing' "$DIR/alerts-state.json" >/dev/null 2>&1 && echo 1 || echo 0; })" \
    "Disco a $(( dsk / 10 ))% (limite $(al_get DISK 90)%)" "Disco normalizado ($(( dsk / 10 ))%)"
  al_cond conn "$([ "$n_n" -ge 2 ] && echo 1 || echo 0)" "Ligações a ${pct}% da capacidade ($tot de $cap)" "Ligações normalizadas (${pct}%)"
  # mudanças do modo de proteção: alerta imediato
  ev=$DIR/events.log; p=$DIR/events.pos
  if [ -f "$ev" ]; then
    sz=$(stat -c %s "$ev"); local op; op=$(cat "$p" 2>/dev/null || echo 0); [ "$sz" -lt "$op" ] && op=0
    tail -c +$(( op + 1 )) "$ev" | cut -d' ' -f2- | while read -r m; do [ -n "$m" ] && al_send ovl "$([[ "$m" == *desativado* ]] && echo ok || echo crit)" "$m"; done
    echo "$sz" > "$p"
  fi
}
# o sentinela e o recolhedor vigiam-se um ao outro
sentinel_watch(){
  [ -f /etc/cron.d/minipainel-sentinel ] && [ -f "$DIR/sentinel.json" ] || return 0
  local a on=0; a=$(( EPOCHSECONDS - $(stat -c %Y "$DIR/sentinel.json" 2>/dev/null || echo "$EPOCHSECONDS") ))
  if [ "$a" -ge 300 ]; then on=1; systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1; fi
  al_cond sentinel "$on" "O sentinela não corre há $(( a / 60 )) min (o cron foi reiniciado)" "O sentinela voltou a correr"
}
# volume de email: 30 dias a aprender o normal; depois alerta acima de +MAIL_PCT%
mail_vol_tick(){
  grep -q '^ENABLED=1$' /etc/minipainel/mail.conf 2>/dev/null || [ -f /etc/minipainel/mail-enabled ] || return 0
  local vcur=$DIR/mail-vol-cur csv=$DIR/mail-vol.csv h=$(( EPOCHSECONDS / 3600 * 3600 )) ch ci co ni no
  read -r ch ci co < "$vcur" 2>/dev/null || { ch=$h; ci=0; co=0; }
  ni=0; no=0
  if command -v journalctl >/dev/null 2>&1; then
    while read -r t; do case "$t" in in) ni=$(( ni + 1 )) ;; out) no=$(( no + 1 )) ;; esac; done < <(
      journalctl -q --cursor-file="$DIR/mail-vol.cursor" -o cat -t postfix/lmtp -t postfix/smtp -t postfix/local -t postfix/virtual 2>/dev/null |
      awk '/status=sent/ { if ($0 ~ /relay=(private\/dovecot-lmtp|local|virtual|dovecot)/) print "in"; else print "out" }')
  fi
  if [ "$ch" != "$h" ]; then
    echo "$ch,$ci,$co" >> "$csv"; mail_vol_eval "$ch" "$ci" "$co"
    awk -F, -v s=$(( EPOCHSECONDS - 60 * 86400 )) 'NR == 1 || $1 >= s' "$csv" > "$csv.tmp" && mv -f "$csv.tmp" "$csv"   # 60 dias (a 1.ª linha marca o início)
    ch=$h; ci=0; co=0
  fi
  echo "$ch $(( ci + ni )) $(( co + no ))" > "$vcur"
  perm "$csv" 2>/dev/null
}
mail_vol_eval(){ # hora entrada saída
  local csv=$DIR/mail-vol.csv first pc mn hod r ai ao
  first=$(head -n1 "$csv" | cut -d, -f1)
  [ $(( EPOCHSECONDS - first )) -ge $(( 30 * 86400 )) ] || return 0   # ainda a aprender
  pc=$(al_get MAIL_PCT 20); mn=$(al_get MAIL_MIN 50); hod=$(( $1 % 86400 / 3600 ))
  r=$(awk -F, -v hod="$hod" -v cur="$1" -v s=$(( $1 - 30 * 86400 )) '$1 >= s && $1 < cur && int(($1 % 86400) / 3600) == hod { n++; i += $2; o += $3 } END { if (n) printf "%.1f %.1f", i / n, o / n; else print "0 0" }' "$csv")
  read -r ai ao <<<"$r"
  local fi_ fo hh; hh=$(date -d "@$1" '+%Hh')
  fi_=$(awk -v v="$2" -v a="$ai" -v p="$pc" -v m="$mn" 'BEGIN { print (v > a * (1 + p / 100) && v - a >= m) ? 1 : 0 }')
  fo=$(awk -v v="$3" -v a="$ao" -v p="$pc" -v m="$mn" 'BEGIN { print (v > a * (1 + p / 100) && v - a >= m) ? 1 : 0 }')
  al_cond mail_in "$fi_" "Email recebido acima do normal: $2 mensagens entre as $hh e a hora seguinte (normal ${ai%.*}; +$(awk -v v="$2" -v a="$ai" 'BEGIN { printf "%d", (a > 0 ? (v - a) * 100 / a : 100) }')%)" "Email recebido de volta ao normal ($2 mensagens na última hora)"
  al_cond mail_out "$fo" "Email enviado acima do normal: $3 mensagens entre as $hh e a hora seguinte (normal ${ao%.*}; +$(awk -v v="$3" -v a="$ao" 'BEGIN { printf "%d", (a > 0 ? (v - a) * 100 / a : 100) }')%)" "Email enviado de volta ao normal ($3 mensagens na última hora)"
}

# ---------- processos (a cada 10 s; CPU atual calculada pela diferença entre leituras) ----------
sample_procs(){
  local now=$EPOCHSECONDS pcur=$DIR/.procs-cur prev=$DIR/.procs-prev out=$DIR/procs.tsv
  ps -eo pid=,ppid=,times=,rss=,etimes=,user:40=,comm=,args= 2>/dev/null > "$pcur" || return 0
  awk -v now="$now" -v prevf="$prev" -v newp="$prev.new" '
    BEGIN { pt = 0; while ((getline l < prevf) > 0) { n = split(l, a, " "); if (a[1] == "T") pt = a[2]; else pc[a[1]] = a[2] } print "T " now > newp }
    {
      pid = $1; ppid = $2; ct = $3; rss = $4; et = $5; usr = $6; comm = $7
      args = $0; for (i = 1; i <= 7; i++) sub(/^[ \t]*[^ \t]+/, "", args); sub(/^[ \t]+/, "", args)
      gsub(/\t/, " ", args); args = substr(args, 1, 300)
      cpu = 0; dt = now - pt
      if ((pid in pc) && dt > 0) cpu = (ct - pc[pid]) * 100 / dt; else if (et > 0) cpu = ct * 100 / et
      if (cpu < 0) cpu = 0
      print pid " " ct > newp
      printf "%s\t%s\t%.1f\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, cpu, rss, et, usr, comm, args
    }' "$pcur" | sort -t$'\t' -k3,3nr -k4,4nr | head -n 400 > "$out.tmp"
  mv -f "$prev.new" "$prev" 2>/dev/null; mv -f "$out.tmp" "$out"; perm "$out"
  printf '%s\n' "$now" > "$DIR/procs.ts"; perm "$DIR/procs.ts"
}

# ---------- ciclo principal ----------
for f in hist-1m.csv hist-10m.csv hist-1h.csv; do [ -f "$DIR/$f" ] || : > "$DIR/$f"; perm "$DIR/$f"; done
read -r p_tot p_idle <<<"$(read_cpu)"
read -r p_rx p_tx <<<"$(read_net)"
p_t=${EPOCHREALTIME/./}
first=1
cur_min=$(( EPOCHSECONDS / 60 ))
acc_n=0; a_cpu=0; a_mem=0; a_swap=0; a_disk=0; a_load=0; a_rx=0; a_tx=0
DISK_TS=0; last_hour=-1
sample_sites 1 1
first=0
read_fw_conf

while :; do
  sleep "$INTERVAL"
  now_t=${EPOCHREALTIME/./}
  dtus=$(( now_t - p_t )); [ "$dtus" -le 0 ] && dtus=1
  read -r tot idle <<<"$(read_cpu)"
  dtot=$(( tot - p_tot )); didle=$(( idle - p_idle ))
  cpu=0; [ "$dtot" -gt 0 ] && cpu=$(( (dtot - didle) * 1000 / dtot ))
  [ "$cpu" -lt 0 ] && cpu=0
  read -r mt mu st su <<<"$(read_mem)"
  mem=0; [ "${mt:-0}" -gt 0 ] && mem=$(( mu * 1000 / mt ))
  swap=0; [ "${st:-0}" -gt 0 ] && swap=$(( su * 1000 / st ))
  read -r dk_t dk_u dk_a <<<"$(read_disk)"
  disk=0; [ $(( ${dk_u:-0} + ${dk_a:-0} )) -gt 0 ] && disk=$(( dk_u * 1000 / (dk_u + dk_a) ))
  read -r l1 l5 l15 _ < /proc/loadavg
  load=$(( 10#${l1/./} ))
  read -r rx tx <<<"$(read_net)"
  rxb=$(( (rx - p_rx) * 8 * 1000000 / dtus )); [ "$rxb" -lt 0 ] && rxb=0
  txb=$(( (tx - p_tx) * 8 * 1000000 / dtus )); [ "$txb" -lt 0 ] && txb=0
  sample_sites "$dtus" "$first"

  sj=""; sep=""
  for s in $(site_names); do
    sj+="$sep\"$s\":{\"cpu\":$(d10 "${SITE_CPU[$s]:-0}"),\"rss\":${SITE_RSS[$s]:-0}}"; sep=","
  done
  printf -v tz '%(%z)T' -1
  put "$DIR/live.json" "{\"ts\":$EPOCHSECONDS,\"tz\":\"$tz\",\"cpus\":$NCPU,\"cpu\":$(d10 "$cpu"),\"mem\":{\"pct\":$(d10 "$mem"),\"used\":$mu,\"total\":$mt},\"swap\":{\"pct\":$(d10 "$swap"),\"used\":$su,\"total\":$st},\"disk\":{\"pct\":$(d10 "$disk"),\"used\":${dk_u:-0},\"total\":${dk_t:-0}},\"load\":[$l1,$l5,$l15],\"net\":{\"rx\":$rxb,\"tx\":$txb},\"sites\":{$sj}}"

  sample_conns
  overload_check
  [ $(( EPOCHSECONDS / 5 % 2 )) -eq 0 ] && sample_procs
  mail_spool_kick
  acc_n=$(( acc_n + 1 )); a_cpu=$(( a_cpu + cpu )); a_mem=$(( a_mem + mem )); a_swap=$(( a_swap + swap ))
  a_disk=$(( a_disk + disk )); a_load=$(( a_load + load )); a_rx=$(( a_rx + rxb )); a_tx=$(( a_tx + txb ))

  m=$(( EPOCHSECONDS / 60 ))
  if [ "$m" -ne "$cur_min" ]; then
    ts=$(( cur_min * 60 ))
    echo "$ts,$(( a_cpu / acc_n )),$(( a_mem / acc_n )),$(( a_swap / acc_n )),$(( a_disk / acc_n )),$(( a_load / acc_n )),$(( a_rx / acc_n )),$(( a_tx / acc_n ))" >> "$DIR/hist-1m.csv"
    trim "$DIR/hist-1m.csv" 1440
    if [ $(( m / 10 )) -ne $(( cur_min / 10 )) ]; then
      s10=$(( cur_min / 10 * 600 )); aggregate "$DIR/hist-1m.csv" "$DIR/hist-10m.csv" "$s10" $(( s10 + 600 )) 1008
    fi
    if [ $(( m / 60 )) -ne $(( cur_min / 60 )) ]; then
      s60=$(( cur_min / 60 * 3600 )); aggregate "$DIR/hist-1m.csv" "$DIR/hist-1h.csv" "$s60" $(( s60 + 3600 )) 720
    fi
    update_traffic
    read_fw_conf
    fw_selfheal
    update_crons
    auth_guard
    alerts_tick $(( a_cpu / acc_n )) $(( a_mem / acc_n )) $(( a_disk / acc_n ))
    sentinel_watch
    mail_vol_tick
    h=$(( EPOCHSECONDS / 3600 ))
    if [ "$h" -ne "$last_hour" ]; then update_disk; DISK_TS=$EPOCHSECONDS; last_hour=$h; ( setsid /usr/local/sbin/mpanel db-slow-report >/dev/null 2>&1 < /dev/null & ); fi
    write_sites_json
    acc_n=0; a_cpu=0; a_mem=0; a_swap=0; a_disk=0; a_load=0; a_rx=0; a_tx=0
    cur_min=$m
  fi
  p_tot=$tot; p_idle=$idle; p_rx=$rx; p_tx=$tx; p_t=$now_t; first=0
done
MPSTATS
chmod 750 /usr/local/sbin/mpanel-stats
cat > /etc/systemd/system/minipainel-stats.service <<'EOF'
[Unit]
Description=IDDigital Hosting - recolha de estatísticas e ligações
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mpanel-stats
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable minipainel-stats.service >/dev/null 2>&1
systemctl restart minipainel-stats.service

say "A configurar as tarefas agendadas (cron)..."
if [ "$OS_FAMILY" = debian ]; then CRON_SVC=cron; else CRON_SVC=crond; fi
systemctl enable --now "$CRON_SVC" >/dev/null 2>&1 || warn "Não foi possível ativar o serviço $CRON_SVC."
install -d -m 755 /etc/minipainel/cron
cat > /usr/local/sbin/mp-sendmail <<'MPSENDMAIL'
#!/usr/bin/env bash
# =============================================================================
#  mp-sendmail — IDDigital Hosting v2.12.1
#  Recebe o mail() do PHP de um site (corre como mp_<site>) e coloca a mensagem
#  na fila controlada pelo painel, que aplica limites, antispam e DKIM antes de
#  a entregar ao Postfix. Os sites não podem usar o sendmail nem a porta 25.
# =============================================================================
set -u
site=${1:-}; [ $# -gt 0 ] && shift
re='^[a-z][a-z0-9-]{0,23}$'
[[ "$site" =~ $re ]] || exit 75
[ "$(id -un)" = "mp_$site" ] || exit 77
[ -f /etc/minipainel/mail-enabled ] || { echo "O envio de email não está ativo neste servidor." >&2; exit 69; }
from=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|-r) from=${2:-}; shift 2 || shift ;;
    -f*) from=${1#-f}; shift ;;
    -r*) from=${1#-r}; shift ;;
    *) shift ;;
  esac
done
d=/var/spool/mp-mail/$site
[ -d "$d/new" ] && [ -d "$d/tmp" ] || exit 75
umask 077
id="$(date +%s%N).$$"
head -c 31457281 > "$d/tmp/$id.eml" || exit 75
if [ "$(stat -c %s "$d/tmp/$id.eml")" -gt 31457280 ]; then rm -f "$d/tmp/$id.eml"; echo "Mensagem demasiado grande (máx. 30 MB)." >&2; exit 75; fi
printf '%s\n' "${from:0:254}" > "$d/new/$id.from"
mv "$d/tmp/$id.eml" "$d/new/$id.eml"
exit 0
MPSENDMAIL
chown root:root /usr/local/sbin/mp-sendmail; chmod 755 /usr/local/sbin/mp-sendmail
if [ "$OS_FAMILY" != debian ] && command -v semanage >/dev/null 2>&1; then
  se_fc httpd_sys_rw_content_t "/var/spool/mp-mail(/.*)?"
fi

install -d -m 755 /usr/local/lib/minipainel
cat > /usr/local/lib/minipainel/geoip-build.php <<'MPGEO'
<?php
// IDDigital Hosting — constrói os índices de geolocalização a partir do CSV da DB-IP (CC BY 4.0)
// uso: php geoip-build.php <csv.gz> <pasta>
[$src, $dir] = [$argv[1] ?? '', $argv[2] ?? ''];
$in = gzopen($src, 'r'); if (!$in) { fwrite(STDERR, "CSV ilegível\n"); exit(1); }
@mkdir($dir . '/cc', 0750, true);
$v4 = fopen($dir . '/v4.bin.tmp', 'w'); $v6 = fopen($dir . '/v6.bin.tmp', 'w');
$cc4 = []; $cc6 = []; $n = 0;
while (($ln = gzgets($in)) !== false) {
    $p = explode(',', trim($ln)); if (count($p) !== 3) continue;
    [$a, $b, $c] = $p; if (!preg_match('/^[A-Z]{2}$/', $c) || $c === 'ZZ') continue;
    if (strpos($a, ':') === false) {
        $x = ip2long($a); $y = ip2long($b); if ($x === false || $y === false) continue;
        fwrite($v4, pack('NN', $x, $y) . $c); $cc4[$c][] = "$a-$b";
    } else {
        $x = @inet_pton($a); $y = @inet_pton($b); if ($x === false || $y === false) continue;
        fwrite($v6, $x . $y . $c); $cc6[$c][] = "$a-$b";
    }
    $n++;
}
gzclose($in); fclose($v4); fclose($v6);
if ($n < 100000) { fwrite(STDERR, "CSV incompleto ($n linhas)\n"); exit(1); }
foreach (glob($dir . '/cc/*') as $f) @unlink($f);
foreach ($cc4 as $c => $l) file_put_contents("$dir/cc/$c.v4", implode("\n", $l) . "\n");
foreach ($cc6 as $c => $l) file_put_contents("$dir/cc/$c.v6", implode("\n", $l) . "\n");
rename($dir . '/v4.bin.tmp', $dir . '/v4.bin'); rename($dir . '/v6.bin.tmp', $dir . '/v6.bin');
echo "$n gamas, " . count($cc4) . " países\n";
MPGEO
chmod 644 /usr/local/lib/minipainel/geoip-build.php
printf '# IDDigital Hosting — base de países (DB-IP Lite) e IPs de confiança na firewall\n15 5 3 * * root /usr/local/sbin/mpanel geoip-update >/dev/null 2>&1\n*/10 * * * * root /usr/local/sbin/mpanel trust-sync >/dev/null 2>&1\n' > /etc/cron.d/minipainel-geo
chmod 644 /etc/cron.d/minipainel-geo

cat > /usr/local/sbin/mpanel-term <<'MPTERM'
#!/usr/bin/env bash
# =============================================================================
#  mpanel-term — IDDigital Hosting v2.12.1
#  Sessão de terminal aberta pelo painel (ttyd). Corre como root, grava a saída
#  em /var/log/minipainel/terminal/<sessão>.log (com tempos para scriptreplay)
#  e termina ao fim de 15 minutos sem atividade.
# =============================================================================
id=${1:-}
[[ "$id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || exit 2
LOG=/var/log/minipainel/terminal
umask 027
export TERM=xterm-256color TMOUT=900 HOME=/root
cd /root || exit 1
printf '\033[1;33mIDDigital Hosting — terminal root.\033[0m Esta sessão está a ser gravada. Fecha com "exit".\r\n\r\n'
exec script -q -f -T "$LOG/$id.timing" -O "$LOG/$id.log" -c "TMOUT=900 exec bash -l"
MPTERM
chown root:root /usr/local/sbin/mpanel-term; chmod 700 /usr/local/sbin/mpanel-term
install -d -o root -g minipainel -m 2750 /var/log/minipainel/terminal
printf '# IDDigital Hosting — sentinela: testa todos os serviços a cada minuto\n* * * * * root /usr/local/sbin/mpanel sentinel-run >/dev/null 2>&1\n' > /etc/cron.d/minipainel-sentinel
chmod 644 /etc/cron.d/minipainel-sentinel
if [ "$OS_FAMILY" = debian ]; then pkg_install_soft libfcgi-bin; else pkg_install_soft fcgi; fi
printf '# IDDigital Hosting — gravações do terminal: guardar 90 dias\n45 4 * * * root find /var/log/minipainel/terminal -type f -mtime +90 -delete\n' > /etc/cron.d/minipainel-terminal
chmod 644 /etc/cron.d/minipainel-terminal

cat > /usr/local/sbin/mpanel-cron <<'MPCRON'
#!/usr/bin/env bash
# =============================================================================
#  mpanel-cron — IDDigital Hosting v2.12.1
#  Executa uma tarefa agendada de um site. Corre como o utilizador do site
#  (mp_<site>), chamado pelo cron a partir de /etc/cron.d/minipainel-<site>.
#  Não deixa sobrepor execuções e regista a saída em logs/cron-<id>.log.
# =============================================================================
set -uo pipefail
site="${1:-}"; id="${2:-}"
re_s='^[a-z][a-z0-9-]{0,23}$'; re_i='^[a-f0-9]{8}$'
[[ "$site" =~ $re_s ]] && [[ "$id" =~ $re_i ]] || { echo "Parâmetros inválidos." >&2; exit 2; }
[ "$(id -un)" = "mp_$site" ] || { echo "Tem de correr como mp_$site." >&2; exit 2; }
d=/srv/www/$site
s=/etc/minipainel/cron/$site/$id.sh
log=$d/logs/cron-$id.log
st=$d/logs/cron-$id.status
[ -r "$s" ] || { echo "Tarefa não encontrada: $id" >&2; exit 2; }
umask 027
exec 9>"$d/tmp/.cron-$id.lock"
if ! flock -n 9; then
  printf '=== %s — ignorada: a execução anterior ainda não terminou ===\n' "$(date '+%d/%m/%Y %H:%M:%S')" >> "$log"
  exit 0
fi
start=$(date +%s)
printf '%s 0 running\n' "$start" > "$st"
printf '=== %s ===\n' "$(date '+%d/%m/%Y %H:%M:%S')" >> "$log"
export PATH="/etc/minipainel/cron/$site/bin:/usr/local/bin:/usr/bin:/bin" HOME="$d"
cd "$d/public_html" 2>/dev/null || cd "$d" || exit 1
/bin/sh "$s" >> "$log" 2>&1 9>&-
rc=$?
end=$(date +%s)
printf '%s %s %s\n' "$start" "$end" "$rc" > "$st"
printf '=== terminou com código %s em %ss ===\n' "$rc" "$(( end - start ))" >> "$log"
if [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"
fi
exit "$rc"
MPCRON
chown root:root /usr/local/sbin/mpanel-cron
chmod 755 /usr/local/sbin/mpanel-cron

say "A configurar domínios e certificados..."
[ -f /etc/minipainel/server.conf ] || printf 'MODE=lan\nEMAIL=\nPANEL_DOMAIN=\nPANEL_SSL=le\n' > /etc/minipainel/server.conf
chmod 644 /etc/minipainel/server.conf
for t in certbot.timer certbot-renew.timer snap.certbot.renew.timer; do
  if systemctl list-unit-files "$t" >/dev/null 2>&1 && systemctl list-unit-files "$t" | grep -q "$t"; then systemctl enable --now "$t" >/dev/null 2>&1 || true; fi
done

say "A configurar os backups..."
install -d -o root -g minipainel -m 750 /var/backups/minipainel
if [ ! -f /etc/minipainel/backup.conf ]; then
  printf 'ENABLED=1\nTIME=03:00\nKEEP_DAILY=7\nKEEP_WEEKLY=4\nKEEP_MONTHLY=3\nREMOTE=\nENCRYPT=1\n' > /etc/minipainel/backup.conf
  chmod 600 /etc/minipainel/backup.conf
fi
grep -q '^ENCRYPT=' /etc/minipainel/backup.conf || echo 'ENCRYPT=1' >> /etc/minipainel/backup.conf
grep -q '^PORTS_ACCESS=' /etc/minipainel/server.conf 2>/dev/null || echo 'PORTS_ACCESS=all' >> /etc/minipainel/server.conf
grep -q '^PANEL_ALLOW=' /etc/minipainel/server.conf 2>/dev/null || echo 'PANEL_ALLOW=' >> /etc/minipainel/server.conf
touch /var/lib/minipainel/logs/audit.log; chown minipainel:minipainel /var/lib/minipainel/logs/audit.log; chmod 640 /var/lib/minipainel/logs/audit.log

say "A configurar a firewall de ligações (nftables)..."
[ -f /etc/minipainel/firewall.conf ] || printf 'AUTO=0\nLIMIT=150\nDURATION=3600\n' > /etc/minipainel/firewall.conf
touch /etc/minipainel/blocks.list /etc/minipainel/allow.list
chmod 600 /etc/minipainel/blocks.list /etc/minipainel/allow.list
cat > /etc/systemd/system/minipainel-firewall.service <<'EOF'
[Unit]
Description=IDDigital Hosting - bloqueios de IPs (nftables)
After=network-pre.target nftables.service firewalld.service
Wants=network-pre.target
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mpanel fw-restore

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable minipainel-firewall.service >/dev/null 2>&1 || true

cat > /etc/logrotate.d/minipainel <<'EOF'
/srv/www/*/logs/*.log /var/lib/minipainel/logs/*.log /var/lib/minipainel-pma/logs/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
EOF

# ----------------------------------------------------------------------------
# 9. Password do painel (apenas na primeira instalação)
# ----------------------------------------------------------------------------
ADMIN_PASS=""
if [ ! -s /var/lib/minipainel/auth.json ]; then
  ADMIN_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  HASH="$(printf '%s' "$ADMIN_PASS" | "$(php_cli "$PANEL_PHP")" -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT);')"
  [[ "$HASH" == '$2y$'* ]] || die "Falha ao gerar a password do painel."
  jq -n --arg u "$PANEL_USER" --arg h "$HASH" '{user:$u,hash:$h}' > /var/lib/minipainel/auth.json
  chown root:minipainel /var/lib/minipainel/auth.json
  chmod 640 /var/lib/minipainel/auth.json
fi

# ----------------------------------------------------------------------------
# 10. SELinux e firewall
# ----------------------------------------------------------------------------
if selinux_on; then
  say "A configurar SELinux..."
  setsebool -P httpd_can_network_connect=1 httpd_can_network_connect_db=1 || warn "Não foi possível ajustar os booleanos SELinux."
  se_fc(){ semanage fcontext -a -t "$1" "$2" 2>/dev/null || semanage fcontext -m -t "$1" "$2" 2>/dev/null || true; }
  se_fc httpd_sys_rw_content_t "/srv/www(/.*)?"
  se_fc httpd_sys_content_t    "/opt/minipainel(/.*)?"
  se_fc httpd_sys_rw_content_t "/var/lib/minipainel(/.*)?"
  se_fc cert_t                 "/etc/minipainel/ssl(/.*)?"
  se_fc httpd_sys_rw_content_t "/var/lib/minipainel-pma(/.*)?"
  se_fc httpd_sys_content_t    "/var/backups/minipainel(/.*)?"
  se_fc httpd_sys_content_t    "/var/www/minipainel-acme(/.*)?"
  se_fc cert_t                 "/etc/letsencrypt(/.*)?"
  install -d -m 755 /var/www/minipainel-acme /etc/letsencrypt
  restorecon -R /var/www/minipainel-acme /etc/letsencrypt >/dev/null 2>&1 || true
  install -d -o root -g minipainel -m 750 /var/backups/minipainel
  restorecon -R /srv/www /opt/minipainel /var/lib/minipainel /var/lib/minipainel-pma /etc/minipainel/ssl || true
  semanage port -a -t http_port_t -p tcp "$PANEL_PORT" 2>/dev/null \
    || semanage port -m -t http_port_t -p tcp "$PANEL_PORT" 2>/dev/null || true
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd -q --permanent --add-port="$PANEL_PORT/tcp" || true
  firewall-cmd -q --add-port="$PANEL_PORT/tcp" || true
  ok "Porta $PANEL_PORT aberta no firewalld."
elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
  ufw allow "$PANEL_PORT/tcp" >/dev/null || true
  ok "Porta $PANEL_PORT aberta no ufw."
fi

# ----------------------------------------------------------------------------
# 10b. phpMyAdmin e conta de administração do MariaDB
# ----------------------------------------------------------------------------
say "A instalar o phpMyAdmin..."
if /usr/local/sbin/mpanel pma-update; then ok "phpMyAdmin pronto."
else warn "phpMyAdmin não instalado agora. Tenta mais tarde com: mpanel pma-update"; fi

DBADMIN_PASS=""
if [ "$(mysql -uroot -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='mpadmin'" 2>/dev/null)" = 0 ]; then
  DBADMIN_OUT="$(/usr/local/sbin/mpanel db-admin-passwd 2>/dev/null || true)"
  DBADMIN_PASS="$(printf '%s\n' "$DBADMIN_OUT" | awk -F': *' '/^Password:/{print $2; exit}')"
  if [ -n "$DBADMIN_PASS" ]; then ok "Conta de administração MariaDB criada (mpadmin)."; else warn "Não foi possível criar a conta mpadmin (usa: mpanel db-admin-passwd)."; fi
fi

# ----------------------------------------------------------------------------
# 11. Arranque dos serviços
# ----------------------------------------------------------------------------
say "A arrancar serviços..."
for v in $ALL_PHP; do
  "$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" >/dev/null 2>&1 || die "Configuração do PHP-FPM $v inválida ($(php_fpm_bin "$v") -t)."
  systemctl enable "$(php_service "$v")" >/dev/null 2>&1 || true
  systemctl reload-or-restart "$(php_service "$v")"
done
nginx -t >/dev/null 2>&1 || { nginx -t; die "Configuração do nginx inválida."; }
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload-or-restart nginx

/usr/local/sbin/mpanel fm-sync || warn "Não foi possível configurar o gestor de ficheiros (mpanel fm-sync)."
/usr/local/sbin/mpanel fw-restore >/dev/null || warn "Não foi possível ativar a firewall de ligações (mpanel fw-restore)."
/usr/local/sbin/mpanel cron-sync >/dev/null || warn "Não foi possível sincronizar as tarefas agendadas (mpanel cron-sync)."
/usr/local/sbin/mpanel bk-init >/dev/null || warn "Não foi possível configurar os backups (mpanel bk-init)."
/usr/local/sbin/mpanel ngx-sync >/dev/null || warn "Não foi possível regenerar a configuração nginx dos sites (mpanel ngx-sync)."
/usr/local/sbin/mpanel pma-settings --apply >/dev/null 2>&1 || true
/usr/local/sbin/mpanel conf-lock >/dev/null 2>&1 || true
/usr/local/sbin/mpanel opcache-settings >/dev/null 2>&1 || warn "Não foi possível configurar o OPcache."
/usr/local/sbin/mpanel perf-sync >/dev/null 2>&1 || true
grep -q '^NET_TUNE=' /etc/minipainel/server.conf 2>/dev/null || /usr/local/sbin/mpanel net-tune on >/dev/null 2>&1 || true
grep -q '^BROTLI=' /etc/minipainel/server.conf 2>/dev/null || /usr/local/sbin/mpanel brotli on >/dev/null 2>&1 || warn "Brotli não disponível neste sistema (fica o gzip)."
printf '# IDDigital Hosting — converte imagens novas em WebP nos sites que o pedem\n40 3 * * * root /usr/local/sbin/mpanel webp-nightly >/dev/null 2>&1\n' > /etc/cron.d/minipainel-webp; chmod 644 /etc/cron.d/minipainel-webp
if [ ! -f /etc/mysql/mariadb.conf.d/90-minipainel.cnf ] && [ ! -f /etc/my.cnf.d/90-minipainel.cnf ]; then
  say "A afinar o MariaDB à memória do servidor..."; /usr/local/sbin/mpanel db-tune | tail -1 || warn "Não foi possível afinar o MariaDB (a configuração anterior foi mantida)."
fi
[ -f /var/lib/minipainel/geoip/v4.bin ] || /usr/local/sbin/mpanel geoip-update >/dev/null 2>&1 || warn "Não foi possível descarregar a base de países (tenta: mpanel geoip-update)."
[ -f /etc/minipainel/protect.conf ] || /usr/local/sbin/mpanel protect-settings >/dev/null 2>&1 || true
command -v pure-pw >/dev/null 2>&1 && { /usr/local/sbin/mpanel ftp-settings >/dev/null 2>&1 || warn "Não foi possível reaplicar a configuração do FTP."; }

# --- migrações numeradas: cada passo corre uma vez, por ordem, só se a versão anterior for mais antiga ---
mig_2_2_0(){
  [ -f /etc/minipainel/update.conf ] || printf 'URL=https://raw.githubusercontent.com/naoavr/painel-alojamento-nao/main\n' > /etc/minipainel/update.conf
  install -d -m 700 /var/lib/minipainel/update /var/backups/minipainel/_atualizacoes
}
MIGRATIONS=("2.2.0:mig_2_2_0")
for m in "${MIGRATIONS[@]}"; do
  mv_=${m%%:*}; mf_=${m#*:}
  if [ "$PREV_VERSION" = 0 ] || [ "$(printf '%s\n%s\n' "$PREV_VERSION" "$mv_" | sort -V | head -1)" = "$PREV_VERSION" ] && [ "$PREV_VERSION" != "$mv_" ]; then
    "$mf_" || warn "A migração $mv_ falhou."
  fi
done
echo "$MP_VERSION" > /etc/minipainel/version
printf '# IDDigital Hosting — procura diária de atualizações (painel e sistema)\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nMAILTO=""\n%d 5 * * * root /usr/local/sbin/mpanel update-check >/dev/null 2>&1; /usr/local/sbin/mpanel os-check >/dev/null 2>&1\n' "$(( RANDOM % 60 ))" > /etc/cron.d/minipainel-updates
chmod 644 /etc/cron.d/minipainel-updates
if grep -q '^ENABLED=1$' /etc/minipainel/mail.conf 2>/dev/null; then
  /usr/local/sbin/mpanel mail-enable >/dev/null || warn "Não foi possível atualizar a configuração do email (mpanel mail-enable)."
fi
/usr/local/sbin/mpanel state || warn "Não foi possível gerar o estado inicial (mpanel state)."

# ----------------------------------------------------------------------------
# Resumo
# ----------------------------------------------------------------------------
SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$SRV_IP" ] || SRV_IP="IP-do-servidor"

if [ -n "$ADMIN_PASS" ]; then
  umask 077
  cat > /root/minipainel-credenciais.txt <<EOF
IDDigital Hosting v$MP_VERSION
Painel:     https://$SRV_IP:$PANEL_PORT  (ou https://localhost:$PANEL_PORT)
Utilizador: $PANEL_USER
Password:   $ADMIN_PASS
EOF
fi
if [ -n "$DBADMIN_PASS" ]; then
  umask 077
  cat >> /root/minipainel-credenciais.txt <<EOF

phpMyAdmin: https://$SRV_IP:$PANEL_PORT/phpmyadmin/  (requer sessão no painel)
MariaDB admin: mpadmin
Password:      $DBADMIN_PASS
EOF
fi

echo
echo "=============================================================="
echo " IDDigital Hosting v$MP_VERSION instalado"
echo "=============================================================="
echo " Painel:      https://$SRV_IP:$PANEL_PORT"
echo "              https://localhost:$PANEL_PORT"
echo "              (certificado autoassinado: aceita o aviso do browser)"
if [ -n "$ADMIN_PASS" ]; then
  echo " Utilizador:  $PANEL_USER"
  echo " Password:    $ADMIN_PASS"
  echo " Guardado em: /root/minipainel-credenciais.txt"
else
  echo " Credenciais: mantidas (mudar com: mpanel passwd)"
fi
echo " phpMyAdmin:  https://$SRV_IP:$PANEL_PORT/phpmyadmin/ (com sessão no painel)"
if [ -n "$DBADMIN_PASS" ]; then
  echo " MariaDB:     mpadmin / $DBADMIN_PASS (acesso a todas as bases)"
fi
echo " PHP:         $ALL_PHP(predefinido $DEFAULT_PHP)"
echo " Sites:       /srv/www/<site>/public_html  ->  http://$SRV_IP:<porta>"
echo " Ficheiros:   no painel, página Ficheiros (envios grandes por partes)"
echo " Recursos:    no painel, página Recursos (systemctl status minipainel-stats)"
echo " Backups:     todos os dias às 03:00 em /var/backups/minipainel (página Backups)"
echo " CLI:         mpanel help"
echo "=============================================================="
