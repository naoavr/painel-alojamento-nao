#!/usr/bin/env bash
# =============================================================================
#  mpanel-stats — recolhedor de estatísticas do IDDigital Hosting v2.13.1
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
