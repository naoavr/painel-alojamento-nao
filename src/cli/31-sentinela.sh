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
t_backup(){ local t; [ "$(bk_conf ENABLED 1)" = 1 ] || { echo "Backups automáticos desligados"; return 0; }
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
    while IFS= read -r n; do [ -n "$n" ] && sn_check "dns:$n" "DNS" "Zona $n" nsd t_zone "$n"; done < <(dns_zones)
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

