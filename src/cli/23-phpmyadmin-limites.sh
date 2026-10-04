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

