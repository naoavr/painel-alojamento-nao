#!/usr/bin/env bash
# NOTAS: Ficheiros: copiar e mover entre sites; encaminhamento ao mudar o domínio do painel; acertos no DNS.
# =============================================================================
#  IDDigital Hosting v2.14.1 — instalador (MiniPainel)
#  Painel de alojamento mínimo: nginx + PHP-FPM (várias versões) + MariaDB + phpMyAdmin,
#  gestor de ficheiros e estatísticas de recursos
#  Os sites são servidos por porta: http://IP:PORTA ou http://localhost:PORTA
#  Suporta: Debian 12/13, Ubuntu 22.04/24.04, AlmaLinux/Rocky 9/10
#
#  Uso:
#    bash minipainel-install-v2.14.1.sh [--php "7.4 8.3 8.4"] [--panel-port 2443] [--force]
#  (por omissão instala do PHP 7.0 ao 8.5; no AlmaLinux/Rocky o repositório Remi só tem do 7.4 para cima)
#
#  Pode ser executado novamente (atualiza a partir da v1.0.0 ou acrescenta
#  versões de PHP com --php); sites, bases de dados, extensões e password do
#  painel são preservados. Sem --php, numa atualização mantêm-se as versões
#  de PHP já instaladas.
# =============================================================================
set -Eeuo pipefail

MP_VERSION="2.14.1"
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
cat > /opt/minipainel/manual.md <<'MPMANUAL'
@@INCLUDE docs/manual.md@@
MPMANUAL
chown root:root /opt/minipainel/manual.md; chmod 644 /opt/minipainel/manual.md

cat > /opt/minipainel/public/index.php <<'MPPANEL'
@@INCLUDE src/panel/index.php@@
MPPANEL
chown -R root:root /opt/minipainel/public
chmod 644 /opt/minipainel/public/index.php
# qrcode-generator (c) Kazuhiko Arase, licença MIT — usado para o código QR do 2FA
cat > /opt/minipainel/qrcode.js <<'MPQR'
@@INCLUDE src/panel/qrcode.js@@
MPQR
chmod 644 /opt/minipainel/qrcode.js

say "A instalar o gestor de ficheiros..."
install -d -o root -g root -m 755 /opt/minipainel/files
cat > /opt/minipainel/files/index.php <<'MPFILES'
@@INCLUDE src/panel/files-api.php@@
MPFILES
chown root:root /opt/minipainel/files/index.php
chmod 644 /opt/minipainel/files/index.php

# ----------------------------------------------------------------------------
# 7. CLI (mpanel) — também usado pelo worker da fila
# ----------------------------------------------------------------------------
say "A instalar o CLI mpanel..."
cat > /usr/local/sbin/mpanel <<'MPCLI'
@@INCLUDE src/cli/00-base.sh@@
@@INCLUDE src/cli/10-sites.sh@@
@@INCLUDE src/cli/11-bases-de-dados.sh@@
@@INCLUDE src/cli/12-php-extensoes.sh@@
@@INCLUDE src/cli/13-phpmyadmin-servicos.sh@@
@@INCLUDE src/cli/14-firewall.sh@@
@@INCLUDE src/cli/15-tarefas-agendadas.sh@@
@@INCLUDE src/cli/16-backups.sh@@
@@INCLUDE src/cli/17-dominios-ssl.sh@@
@@INCLUDE src/cli/20-email.sh@@
@@INCLUDE src/cli/21-atualizacoes.sh@@
@@INCLUDE src/cli/22-ftp-sftp.sh@@
@@INCLUDE src/cli/23-phpmyadmin-limites.sh@@
@@INCLUDE src/cli/24-forca-bruta.sh@@
@@INCLUDE src/cli/25-dns.sh@@
@@INCLUDE src/cli/26-logs.sh@@
@@INCLUDE src/cli/27-terminal.sh@@
@@INCLUDE src/cli/28-paises-ligacoes.sh@@
@@INCLUDE src/cli/29-alertas.sh@@
@@INCLUDE src/cli/30-processos.sh@@
@@INCLUDE src/cli/31-sentinela.sh@@
@@INCLUDE src/cli/32-desempenho.sh@@
@@INCLUDE src/cli/40-estado.sh@@
@@INCLUDE src/cli/41-worker-ajuda.sh@@
@@INCLUDE src/cli/42-comandos.sh@@
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
@@INCLUDE src/stats/mpanel-stats.sh@@
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
@@INCLUDE src/helpers/mp-sendmail.sh@@
MPSENDMAIL
chown root:root /usr/local/sbin/mp-sendmail; chmod 755 /usr/local/sbin/mp-sendmail
if [ "$OS_FAMILY" != debian ] && command -v semanage >/dev/null 2>&1; then
  se_fc httpd_sys_rw_content_t "/var/spool/mp-mail(/.*)?"
fi

install -d -m 755 /usr/local/lib/minipainel
cat > /usr/local/lib/minipainel/geoip-build.php <<'MPGEO'
@@INCLUDE src/helpers/geoip-build.php@@
MPGEO
chmod 644 /usr/local/lib/minipainel/geoip-build.php
printf '# IDDigital Hosting — base de países (DB-IP Lite) e IPs de confiança na firewall\n15 5 3 * * root /usr/local/sbin/mpanel geoip-update >/dev/null 2>&1\n*/10 * * * * root /usr/local/sbin/mpanel trust-sync >/dev/null 2>&1\n' > /etc/cron.d/minipainel-geo
chmod 644 /etc/cron.d/minipainel-geo

cat > /usr/local/sbin/mpanel-term <<'MPTERM'
@@INCLUDE src/helpers/mpanel-term.sh@@
MPTERM
chown root:root /usr/local/sbin/mpanel-term; chmod 700 /usr/local/sbin/mpanel-term
install -d -o root -g minipainel -m 2750 /var/log/minipainel/terminal
printf '# IDDigital Hosting — sentinela: testa todos os serviços a cada minuto\n* * * * * root /usr/local/sbin/mpanel sentinel-run >/dev/null 2>&1\n' > /etc/cron.d/minipainel-sentinel
chmod 644 /etc/cron.d/minipainel-sentinel
if [ "$OS_FAMILY" = debian ]; then pkg_install_soft libfcgi-bin; else pkg_install_soft fcgi; fi
printf '# IDDigital Hosting — gravações do terminal: guardar 90 dias\n45 4 * * * root find /var/log/minipainel/terminal -type f -mtime +90 -delete\n' > /etc/cron.d/minipainel-terminal
chmod 644 /etc/cron.d/minipainel-terminal

cat > /usr/local/sbin/mpanel-cron <<'MPCRON'
@@INCLUDE src/helpers/mpanel-cron.sh@@
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
/usr/local/sbin/mpanel dns-cleanup 2>/dev/null | sed 's/^/  /' || true
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
