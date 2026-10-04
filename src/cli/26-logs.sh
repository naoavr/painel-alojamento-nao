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

