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

