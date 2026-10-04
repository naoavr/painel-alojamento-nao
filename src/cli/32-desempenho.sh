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

