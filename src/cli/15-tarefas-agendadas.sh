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
