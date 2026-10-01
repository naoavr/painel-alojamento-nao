#!/usr/bin/env bash
# =============================================================================
#  MiniPainel v1.5.0 — instalador
#  Painel de alojamento mínimo: nginx + PHP-FPM (várias versões) + MariaDB + phpMyAdmin,
#  gestor de ficheiros e estatísticas de recursos
#  Os sites são servidos por porta: http://IP:PORTA ou http://localhost:PORTA
#  Suporta: Debian 12/13, Ubuntu 22.04/24.04, AlmaLinux/Rocky 9/10
#
#  Uso:
#    bash minipainel-install-v1.5.0.sh [--php "7.4 8.1 8.2 8.3 8.4"] [--panel-port 2443] [--force]
#
#  Pode ser executado novamente (atualiza a partir da v1.0.0 ou acrescenta
#  versões de PHP com --php); sites, bases de dados, extensões e password do
#  painel são preservados. Sem --php, numa atualização mantêm-se as versões
#  de PHP já instaladas.
# =============================================================================
set -Eeuo pipefail

MP_VERSION="1.5.0"
PHP_VERSIONS="7.4 8.1 8.2 8.3 8.4"
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
    die "O nginx já tem configurações (${extra[*]}). O MiniPainel substitui o nginx.conf; usa --force para continuar."
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
  pkg_install ca-certificates curl gnupg jq openssl iproute2 procps logrotate nginx mariadb-server mariadb-client
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
  pkg_install nginx mariadb-server mariadb jq openssl curl iproute procps-ng logrotate policycoreutils-python-utils
fi
ok "Pacotes base instalados."

if [ "$UPGRADE" -eq 1 ] && [ "$PHP_ARG" -eq 0 ]; then
  CUR_PHP="$(php_installed | tr '\n' ' ')"
  [ -n "${CUR_PHP// /}" ] && PHP_VERSIONS="$CUR_PHP"
fi
say "A instalar versões de PHP: $PHP_VERSIONS"
for v in $PHP_VERSIONS; do
  pkgs=()
  if [ "$OS_FAMILY" = debian ]; then
    for e in fpm cli common mysql curl gd mbstring xml zip intl bcmath opcache soap sqlite3 readline; do pkgs+=("php$v-$e"); done
  else
    vv="$(php_vv "$v")"
    for e in php-fpm php-cli php-common php-mysqlnd php-gd php-mbstring php-xml php-pecl-zip php-intl php-bcmath php-opcache php-soap php-pdo php-process; do pkgs+=("php$vv-$e"); done
  fi
  pkg_install_soft "${pkgs[@]}"
  if [ -x "$(php_fpm_bin "$v")" ]; then ok "PHP $v instalado."; else warn "PHP $v não ficou instalado (indisponível nesta distribuição?)."; fi
done

ALL_PHP="$(php_installed | tr '\n' ' ')"
[ -n "${ALL_PHP// /}" ] || die "Nenhuma versão de PHP ficou instalada."
HIGHEST_PHP="$(php_installed | tail -n1)"

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
    client_max_body_size 128M;
    access_log /var/log/nginx/access.log;

    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css text/xml application/javascript application/json application/xml image/svg+xml;

    include /etc/nginx/minipainel/panel.conf;
    include /etc/nginx/minipainel/sites/*.conf;
}
EOF

PANEL_SOCK="$(php_run_dir "$PANEL_PHP")/minipainel.sock"
PMA_SOCK="$(php_run_dir "$PANEL_PHP")/minipainel-pma.sock"
PANEL_RUN="$(php_run_dir "$PANEL_PHP")"
L6=""
[ "$IPV6" = 1 ] && L6="    listen [::]:$PANEL_PORT ssl;"
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

    location / {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
        fastcgi_pass unix:$PANEL_SOCK;
        fastcgi_read_timeout 900s;
    }
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
request_terminate_timeout = 900s
php_admin_value[open_basedir] = /opt/minipainel/:/var/lib/minipainel/
php_admin_value[session.save_path] = /var/lib/minipainel/sessions
php_admin_value[upload_tmp_dir] = /var/lib/minipainel/tmp
php_admin_value[sys_temp_dir] = /var/lib/minipainel/tmp
php_admin_value[error_log] = /var/lib/minipainel/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[max_execution_time] = 870
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
 * MiniPainel v1.5.0 — painel web
 * O painel não executa comandos: lê o estado (state.json) e coloca tarefas
 * numa fila, processadas como root pelo worker (mpanel worker).
 * As tarefas são assíncronas: o painel acompanha-as sem ficar bloqueado,
 * o que permite reiniciar serviços (incluindo o PHP do próprio painel).
 */
declare(strict_types=1);

const MP_VERSION = '1.5.0';
const MP_DATA    = '/var/lib/minipainel';
const MP_QUEUE   = MP_DATA . '/queue';
const MP_RESULTS = MP_DATA . '/results';
const MP_TMP     = MP_DATA . '/tmp';
const MP_RL      = MP_DATA . '/ratelimit';
const MP_STATE   = MP_DATA . '/state.json';
const MP_AUTH    = MP_DATA . '/auth.json';
const MP_IDLE    = 7200;
const MP_STATS   = MP_DATA . '/stats';
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
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");

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
    header('Location: ?' . http_build_query(['p' => $p] + $q));
    exit;
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
];
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
            flash($ok, $msg, stripos($msg, 'password') !== false);
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
    return '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' . h($title) . ' · MiniPainel</title>'
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
.p-ok{background:var(--ok-bg);color:var(--ok)}.p-off{background:var(--line-2);color:var(--ink-2)}.p-err{background:var(--err-bg);color:var(--err)}
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

function render_login(string $err): void { ?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head('Entrar') ?></head>
<body class="auth">
<div class="auth-wrap">
  <section class="auth-side">
    <span class="brand"><span class="logo"><?= ic('server') ?></span>MiniPainel</span>
    <div class="auth-hero">
      <h1>Gerir o servidor<br><span>e todos os sites.</span></h1>
      <p>Sites, bases de dados, ficheiros e serviços, a partir de um só painel.</p>
    </div>
    <div class="auth-foot">© <?= date('Y') ?> MiniPainel · v<?= h(MP_VERSION) ?></div>
  </section>
  <section class="auth-main">
    <form method="post" action="./" class="auth-form">
      <h2>Iniciar sessão</h2>
      <p>Acede ao painel de alojamento.</p>
      <?php if ($err !== ''): ?><div class="err"><?= h($err) ?></div><?php endif; ?>
      <?= csrf_field() ?>
      <label class="fld">Utilizador<input class="in" name="user" autocomplete="username" required autofocus></label>
      <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="current-password" required></label>
      <button class="btn" type="submit">Entrar</button>
    </form>
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
    'bd'       => ['Bases de dados', 'db'],
    'php'      => ['PHP', 'code'],
    'servicos' => ['Serviços', 'pulse'],
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

if (qget('poll') === '1') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{"pending":0}'; exit; }
    echo json_encode(['pending' => job_collect()]);
    exit;
}

if (empty($_SESSION['user'])) {
    $err = '';
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
        $wait = rl_wait();
        if ($wait > 0) {
            $err = 'Demasiadas tentativas. Tenta novamente dentro de ' . (int)ceil($wait / 60) . ' min.';
        } elseif (!csrf_ok()) {
            $err = 'A sessão expirou. Tenta novamente.';
        } else {
            $u = post('user');
            $p = post_raw('pass');
            if ($auth !== null && hash_equals((string)($auth['user'] ?? ''), $u) && password_verify($p, (string)($auth['hash'] ?? ''))) {
                rl_clear();
                session_regenerate_id(true);
                $_SESSION['user'] = $u;
                $_SESSION['seen'] = time();
                unset($_SESSION['csrf']);
                go('resumo');
            }
            rl_fail();
            usleep(random_int(300000, 800000));
            $err = 'Utilizador ou password incorretos.';
        }
    }
    render_login($err);
    exit;
}
$_SESSION['seen'] = time();

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

        case 'db_add':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Nome inválido: usa minúsculas, números e "_", a começar por letra (máx. 32).'); $back = ['novo' => 'bd']; break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); $back = ['novo' => 'bd']; break; }
            job_submit('db-add', $pw !== '' ? [$db, $pw] : [$db], 'Criar a base de dados ' . $db);
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
    'ficheiros'=> 'Ficheiros de cada site, geridos com o utilizador do próprio site.',
];
$groups = ['Geral' => ['resumo', 'recursos'], 'Alojamento' => ['sites', 'ficheiros', 'bd', 'php'], 'Sistema' => ['servicos', 'conta']];
$section = 'Geral';
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
    <a class="brand" href="?p=resumo"><span class="logo"><?= ic('server') ?></span>MiniPainel</a>
    <nav class="nav">
      <?php foreach ($groups as $gl => $keys): ?>
        <div class="nav-sec"><?= h($gl) ?></div>
        <?php foreach ($keys as $k): $pd = $pages[$k]; ?>
          <a href="?p=<?= h($k) ?>"<?= $k === $page ? ' class="on" aria-current="page"' : '' ?>><?= ic($pd[1]) ?><?= h($pd[0]) ?></a>
          <?php if ($k === 'bd' && $pmaOn): ?><a href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('table') ?>phpMyAdmin<?= ic('ext', 'tail') ?></a><?php endif; ?>
        <?php endforeach; ?>
      <?php endforeach; ?>
    </nav>
    <div class="side-foot">MiniPainel v<?= h(MP_VERSION) ?></div>
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
        <?php endif; ?>
        <form method="post" style="margin:0"><?= act_fields('refresh') ?><button class="chip" type="submit" title="Atualizar estado" aria-label="Atualizar estado"><?= ic('reload') ?><span class="lbl">Atualizar</span></button></form>
        <span class="chip sm hide-m">v<?= h(MP_VERSION) ?></span>
        <span class="chip ghost hide-m"><?= h($today) ?></span>
        <button class="chip icon" type="button" data-theme-toggle title="Mudar tema" aria-label="Mudar tema"><?= ic('moon') ?></button>
        <details class="dd me">
          <summary class="chip" aria-label="Conta"><span class="av-me"><?= h(substr((string)$_SESSION['user'], 0, 1)) ?></span><span class="lbl"><?= h($_SESSION['user']) ?></span><?= ic('chev', 'chev') ?></summary>
          <div class="dd-menu">
            <a href="?p=conta"><?= ic('user') ?>Conta e password</a>
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
                <div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu"><span class="mono">:<?= $port ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div>
                <div class="bar"><i style="width:<?= round($rq * 100 / $reqMax, 1) ?>%"></i></div>
                <b class="num"><?= h(fmt_int($rq)) ?></b>
                <span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span>
                <?php if ($on): ?><a class="iconbtn" href="<?= h(site_url($host, $port)) ?>" target="_blank" rel="noopener" title="Abrir" aria-label="Abrir <?= h($n) ?>"><?= ic('ext') ?></a><?php else: ?><span></span><?php endif; ?>
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
          <?php foreach ($sites as $s):
                $n = (string)($s['name'] ?? ''); $port = (int)($s['port'] ?? 0); $on = !empty($s['enabled']); $L = site_limits($s);
                $url = site_url($host, $port); ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu mono"><?= h($s['root'] ?? '') ?></div></div></div></td>
              <td data-label="Endereço">
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
    $fmSite = in_array(qget('site'), $names, true) ? qget('site') : ($names[0] ?? '');
?>
      <?php if (!$names): ?>
        <section class="card"><div class="empty"><b>Ainda não há sites</b>Cria um site para poderes gerir os ficheiros dele.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div></section>
      <?php else: ?>
      <section class="card fm" id="fm" data-site="<?= h($fmSite) ?>" data-dir="<?= h(qget('dir')) ?>">
        <div class="fm-bar">
          <select class="in fm-site" id="fm-site" aria-label="Site">
            <?php foreach ($names as $n): ?><option value="<?= h($n) ?>"<?= $n === $fmSite ? ' selected' : '' ?>><?= h($n) ?></option><?php endforeach; ?>
          </select>
          <nav class="crumbs" id="fm-crumbs" aria-label="Caminho"></nav>
          <div class="fm-tools">
            <button class="btn sm sec" type="button" data-fm="mkdir"><?= ic('folderplus') ?>Nova pasta</button>
            <button class="btn sm sec" type="button" data-fm="newfile"><?= ic('file') ?>Novo ficheiro</button>
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
        <div class="card-f mu" id="fm-foot">Arrasta ficheiros ou pastas para a lista para os enviar. Os envios são feitos por partes e retomam se a ligação falhar.</div>
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
          <thead><tr><th>Base de dados</th><th>Utilizador</th><th class="r">Tamanho</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($dbs as $d): $n = (string)($d['name'] ?? ''); ?>
            <tr>
              <td class="first" data-label="Base de dados"><div class="who"><span class="av t-blue"><?= ic('db') ?></span><div class="nm mono"><?= h($n) ?></div></div></td>
              <td class="mono" data-label="Utilizador"><?= h($n) ?>@localhost</td>
              <td class="r" data-label="Tamanho"><?= h(number_format((float)($d['size_mb'] ?? 0), 2, ',', ' ')) ?> MB</td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($pmaOn): ?><a href="/phpmyadmin/index.php?route=/database/structure&amp;db=<?= h(rawurlencode($n)) ?>" target="_blank" rel="noopener"><?= ic('table') ?>Abrir no phpMyAdmin</a><?php endif; ?>
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
        <?php endif; ?>
      </section>

<?php elseif ($page === 'php'):
    $selV = qget('v') !== '' ? qget('v') : $defPhp;
    $sel = null;
    foreach ($phps as $p) { if ((string)($p['version'] ?? '') === $selV) $sel = $p; }
    if ($sel === null && $phps) $sel = $phps[0];
    $sv = $sel !== null ? (string)($sel['version'] ?? '') : '';
?>
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
              <td class="first" data-label="Versão"><div class="who"><span class="av t-vio"><?= ic('code') ?></span><a class="nm" href="?p=php&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a></div></td>
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

<?php else: ?>
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
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar base de dados</button></div>
  </form>
</dialog>

<?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); if (!valid_site($n)) continue; $L = site_limits($s); ?>
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
    var c = $('fm-crumbs'), parts = st.path ? st.path.split('/') : [], h = '<button type="button" data-path="">' + IC.home + esc(st.site) + '</button>';
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
    if (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n) && it.n.indexOf('.') === -1) return edit(join(st.path, it.n));
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
    if (!it.d && (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n))) o.push(['edit', IC.edit, 'Editar']);
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
  $('fm-site').addEventListener('change', function (e) { st.site = e.target.value; load(''); });
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

say "A instalar o gestor de ficheiros..."
install -d -o root -g root -m 755 /opt/minipainel/files
cat > /opt/minipainel/files/index.php <<'MPFILES'
<?php
/**
 * MiniPainel v1.5.0 — gestor de ficheiros (API)
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
if (!preg_match('/^[a-z][a-z0-9-]{0,23}$/', $site)) fm_fail(400, 'Site inválido.');
$ROOT = realpath('/srv/www/' . $site);
if ($ROOT === false || !is_dir($ROOT)) fm_fail(404, 'A pasta do site não foi encontrada.');
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

$readOnly = ['list', 'get', 'dl', 'upstat'];
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

case 'upstat':
    $id = q('id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $part = $ROOT . '/tmp/.mp-up-' . $id . '.part';
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
    $part = $ROOT . '/tmp/.mp-up-' . $id . '.part';
    if (!is_dir($ROOT . '/tmp')) fm_fail(500, 'A pasta tmp do site não existe.');
    // limpa envios abandonados há mais de um dia
    if (mt_rand(1, 20) === 1) foreach ((array)glob($ROOT . '/tmp/.mp-up-*.part') as $old) { if (is_string($old) && filemtime($old) < time() - 86400) @unlink($old); }
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
#  mpanel — MiniPainel CLI v1.5.0
# =============================================================================
set -uo pipefail

MP_VERSION="1.5.0"
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
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
pm.max_requests = 500
chdir = /
php_admin_value[open_basedir] = $WWW_ROOT/$n/
php_admin_value[upload_tmp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[sys_temp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[session.save_path] = $WWW_ROOT/$n/tmp
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[error_log] = $WWW_ROOT/$n/logs/php-error.log
php_admin_flag[log_errors] = on
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
  local n=$1 p=$2 v=$3 dest=$4 l6="" up rt
  if [ "${IPV6:-0}" = 1 ]; then l6="    listen [::]:$p;"; fi
  up=$(lim_get "$n" UPLOAD)
  rt=$(( $(lim_get "$n" EXEC) + 30 )); [ "$rt" -lt 300 ] && rt=300
  cat > "$dest" <<EOF
# MiniPainel — site $n (gerido pelo mpanel; não editar à mão)
server {
    listen $p;
$l6
    server_name _;
    root $WWW_ROOT/$n/public_html;
    index index.php index.html index.htm;
    client_max_body_size ${up}M;
    access_log /var/log/nginx/mp-$n.access.log;
    error_log  /var/log/nginx/mp-$n.error.log;

    location ~ /\.(?!well-known) { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

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
    }
}
EOF
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
    site_exists "$n" || rm -f "$f"
  done
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
  local n="${1:-}" port="" v="$DEFAULT_PHP" key val lo hi re='^[0-9]{1,6}$'
  local -A lims=()
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 || shift ;;
      --php)  v="${2:-}";    shift 2 || shift ;;
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
  return 0
}

cmd_site_del(){
  local n="${1:-}" keep=0
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--keep-files" ] && keep=1
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local v p se fw
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); se=$(site_get "$n" SE_PORT); fw=$(site_get "$n" FW_PORT)

  rm -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled"
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  rm -f "$(php_pool_dir "$v")/mp-$n.conf" "$(fm_pool_file "$n")"
  apply_php "$v" || warn "Verifica o PHP-FPM $v."
  if [ "$PANEL_PHP" != "$v" ]; then apply_php "$PANEL_PHP" || warn "Verifica o PHP-FPM $PANEL_PHP."; fi
  rm -f "/var/lib/minipainel/stats/traffic/$n.csv" "/var/lib/minipainel/stats/traffic/$n.pos"
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
    if ! apply_nginx || ! wait_listen "$p"; then
      mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled"; apply_nginx >/dev/null 2>&1
      die "O nginx não conseguiu servir na porta $p; o site continua desativado."
    fi
    site_set "$n" ENABLED 1
    echo "Site '$n' ativado."
  else
    [ "$cur" = 0 ] && die "O site '$n' já está desativado."
    mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" || die "Configuração nginx do site em falta."
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
  find "$d" -type d -exec chmod 2750 {} +
  find "$d" -type f -exec chmod 640 {} +
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
  local n="${1:-}" pw="${2:-}"
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
  printf 'Base de dados criada.\nServidor:      localhost (porta 3306)\nBase de dados: %s\nUtilizador:    %s\nPassword:      %s\n' "$n" "$n" "$pw"
  return 0
}

cmd_db_del(){
  local n="${1:-}"
  valid_db "$n" || die "Nome inválido."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" || die "A base de dados '$n' não existe."
  db_exec "DROP DATABASE \`$n\`; DROP USER IF EXISTS '$n'@'localhost'; FLUSH PRIVILEGES;" || die "Falha ao apagar '$n'."
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
  cp -p "$PMA_CONF" "$PMA_DIR/config.inc.php"
  chown root:"$PMA_USER" "$PMA_DIR/config.inc.php"
  chmod 640 "$PMA_DIR/config.inc.php"
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

write_auth(){
  local u=$1 hsh=$2
  jq -n --arg u "$u" --arg h "$hsh" '{user:$u,hash:$h}' > "$AUTH.tmp" || return 1
  chown root:"$PANEL_SYSUSER" "$AUTH.tmp"; chmod 640 "$AUTH.tmp"
  mv -f "$AUTH.tmp" "$AUTH"
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

write_state(){
  local n v st sites phps dbs
  sites=$(for n in $(site_names); do
      jq -cn --arg name "$n" --arg port "$(site_get "$n" PORT)" --arg php "$(site_get "$n" PHP)" \
        --arg en "$(site_get "$n" ENABLED)" --arg root "$WWW_ROOT/$n/public_html" \
        --arg mem "$(lim_get "$n" MEM)" --arg up "$(lim_get "$n" UPLOAD)" --arg ex "$(lim_get "$n" EXEC)" \
        --arg it "$(lim_get "$n" INPUT_TIME)" --arg iv "$(lim_get "$n" INPUT_VARS)" --arg de "$(lim_get "$n" DISPLAY_ERRORS)" \
        '{name:$name, port:($port|tonumber), php:$php, enabled:($en=="1"), root:$root,
          limits:{memory:($mem|tonumber), upload:($up|tonumber), exec:($ex|tonumber),
                  input_time:($it|tonumber), input_vars:($iv|tonumber), display_errors:($de=="1")}}'
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
      [ -n "$n" ] && jq -cn --arg n "$n" --arg s "$v" '{name:$n, size_mb:($s|tonumber)}'
    done | jq -cs '.')
  jq -n --argjson sites "${sites:-[]}" --argjson php "${phps:-[]}" --argjson dbs "${dbs:-[]}" --argjson svcs "${svcs:-[]}" \
    --arg host "$host" --arg ip "$ip" --arg os "$os" --arg up "${up:-0}" --arg disk "${disk:-0}" --arg ram "${ram:-0}" \
    --arg load "${load:-0}" --arg cpus "${cpus:-1}" --arg pport "$PANEL_PORT" --arg pphp "$PANEL_PHP" \
    --arg pmav "$pmav" --argjson dbadm "$dbadm" --arg dbadmu "$DB_ADMIN" \
    --arg defphp "$DEFAULT_PHP" --arg gen "$(date '+%Y-%m-%d %H:%M:%S')" --arg ver "$MP_VERSION" \
    --arg ng "$(systemctl is-active nginx 2>/dev/null)" --arg db "$(systemctl is-active mariadb 2>/dev/null)" \
    '{version:$ver, generated:$gen, default_php:$defphp, php:$php, sites:$sites, databases:$dbs,
      services:{nginx:($ng=="active"), mariadb:($db=="active")}, service_list:$svcs,
      pma:{installed:($pmav!=""), version:$pmav}, db_admin:{user:$dbadmu, exists:$dbadm},
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
        site-add|site-del|site-php|site-enable|site-disable|site-fixperms|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|pma-update|panel-passwd-hash|service|refresh)
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
MiniPainel CLI v1.5.0
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
  version|-v|--version) echo "MiniPainel $MP_VERSION"; exit 0 ;;
esac
[ "$(id -u)" -eq 0 ] || die "Tem de ser executado como root."
exec 9>"$LOCK"
flock -w 300 9 || die "Outra operação do MiniPainel está em curso."

if [ "$cmd" = worker ]; then cmd_worker; exit 0; fi

dispatch "$@"; rc=$?
if [ "$rc" -eq 0 ]; then
  case "$cmd" in
    site-add|site-del|site-php|site-enable|site-disable|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|pma-update|service|state|refresh)
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
Description=MiniPainel - processa as tarefas do painel
After=network.target mariadb.service nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mpanel worker
TimeoutStartSec=1800
EOF
cat > /etc/systemd/system/minipainel-worker.path <<'EOF'
[Unit]
Description=MiniPainel - vigia a fila de tarefas do painel

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
#  mpanel-stats — recolhedor de estatísticas do MiniPainel v1.5.0
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
    log=/var/log/nginx/mp-$n.access.log
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
    h=$(( EPOCHSECONDS / 3600 ))
    if [ "$h" -ne "$last_hour" ]; then update_disk; DISK_TS=$EPOCHSECONDS; last_hour=$h; fi
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
Description=MiniPainel - recolha de estatísticas de recursos
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
/usr/local/sbin/mpanel state || warn "Não foi possível gerar o estado inicial (mpanel state)."

# ----------------------------------------------------------------------------
# Resumo
# ----------------------------------------------------------------------------
SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$SRV_IP" ] || SRV_IP="IP-do-servidor"

if [ -n "$ADMIN_PASS" ]; then
  umask 077
  cat > /root/minipainel-credenciais.txt <<EOF
MiniPainel v$MP_VERSION
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
echo " MiniPainel v$MP_VERSION instalado"
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
echo " CLI:         mpanel help"
echo "=============================================================="
