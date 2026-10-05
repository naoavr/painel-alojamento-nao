#!/usr/bin/env bash
# =============================================================================
#  mpanel — IDDigital Hosting CLI v2.15.0
# =============================================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # o cron só tem /usr/bin:/bin (sem nft, postqueue, sysctl…)

MP_VERSION="2.15.0"
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

