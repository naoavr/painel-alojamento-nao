fw_has_nft(){ command -v nft >/dev/null 2>&1; }
fw_ip_valid(){
  local re4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
  local re6='^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$'
  if [[ "$1" =~ $re4 ]]; then
    local o x; IFS=. read -ra o <<<"${1%%/*}"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
  fi
  [[ "$1" =~ $re6 ]]
}
fw_fam(){ if [[ "$1" == *:* ]]; then echo 6; else echo 4; fi; }
fw_prefix(){ if [[ "$1" == */* ]]; then echo "${1#*/}"; elif [[ "$1" == *:* ]]; then echo 128; else echo 32; fi; }
ip2int(){ local a b c d; IFS=. read -r a b c d <<<"${1%%/*}"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
in_cidr4(){ # ip cidr
  local bits mask; bits=$(fw_prefix "$2")
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$1") & mask )) -eq $(( $(ip2int "$2") & mask )) ]
}
fw_overlap(){ # a b — verdadeiro se uma rede contém a outra (IPv6: só igualdade exata)
  local a=$1 b=$2
  [ "$(fw_fam "$a")" = "$(fw_fam "$b")" ] || return 1
  if [ "$(fw_fam "$a")" = 4 ]; then in_cidr4 "${a%%/*}" "$b" || in_cidr4 "${b%%/*}" "$a"; return; fi
  [ "${a%%/*}" = "${b%%/*}" ]
}
fw_protected_list(){
  echo 127.0.0.1; echo ::1
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$'
  [ -f "$FW_ALLOW" ] && grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}'
  if [ -s "$FW_ADMIN" ]; then
    jq -r --argjson lim $(( EPOCHSECONDS - 7 * 86400 )) 'to_entries[] | select(.value > $lim) | .key' "$FW_ADMIN" 2>/dev/null
  fi
  return 0
}
fw_conf_get(){ local v; v=$(grep -m1 "^$1=" "$FW_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
fw_secs(){
  local re='^[0-9]{1,7}[smhd]?$'
  case "$1" in perm|permanente|0) echo 0; return 0 ;; esac
  [[ "$1" =~ $re ]] || return 1
  case "$1" in
    *s) echo "${1%s}" ;; *m) echo $(( ${1%m} * 60 )) ;; *h) echo $(( ${1%h} * 3600 )) ;; *d) echo $(( ${1%d} * 86400 )) ;; *) echo "$1" ;;
  esac
}
fw_init(){
  fw_has_nft || die "O nftables (nft) não está instalado."
  nft list table inet minipainel >/dev/null 2>&1 && return 0
  nft -f - <<'NFT' || die "Não foi possível criar a tabela nftables do painel."
table inet minipainel {
  set block4 { type ipv4_addr; flags interval, timeout; }
  set block6 { type ipv6_addr; flags interval, timeout; }
  set trust4 { type ipv4_addr; flags interval; }
  set trust6 { type ipv6_addr; flags interval; }
  set geo4 { type ipv4_addr; flags interval; }
  set geo6 { type ipv6_addr; flags interval; }
  set home4 { type ipv4_addr; flags interval; }
  set home6 { type ipv6_addr; flags interval; }
  chain ovl {
  }
  chain input {
    type filter hook input priority -10; policy accept;
    ip saddr @block4 drop
    ip6 saddr @block6 drop
    ip saddr @trust4 accept
    ip6 saddr @trust6 accept
    ct state new ip saddr @geo4 counter drop
    ct state new ip6 saddr @geo6 counter drop
    ct state new jump ovl
  }
}
NFT
}
fw_nft_add(){ # ip segundos
  local set el="$1"
  set="block$(fw_fam "$1")"
  [ "$2" -gt 0 ] && el="$1 timeout ${2}s"
  nft delete element inet minipainel "$set" "{ $1 }" >/dev/null 2>&1
  nft add element inet minipainel "$set" "{ $el }"
}
fw_nft_del(){ nft delete element inet minipainel "block$(fw_fam "$1")" "{ $1 }" >/dev/null 2>&1; return 0; }
fw_list_set(){ # reescreve a lista sem a linha do IP indicado e sem expirados
  local skip=$1 tmp="$FW_BLOCKS.tmp"
  [ -f "$FW_BLOCKS" ] || : > "$FW_BLOCKS"
  awk -F'|' -v s="$skip" -v now="$EPOCHSECONDS" '$1 != s && ($2 == 0 || $2 > now)' "$FW_BLOCKS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$FW_BLOCKS"
}
fw_write_state(){
  local blocks allow nftok=false
  fw_has_nft && nft list table inet minipainel >/dev/null 2>&1 && nftok=true
  blocks=$( [ -f "$FW_BLOCKS" ] && awk -F'|' -v now="$EPOCHSECONDS" '$2 == 0 || $2 > now' "$FW_BLOCKS" | while IFS='|' read -r ip ex cr by rs; do
      jq -cn --arg ip "$ip" --arg ex "$ex" --arg cr "$cr" --arg by "$by" --arg rs "$rs" '{ip:$ip, exp:($ex|tonumber), created:($cr|tonumber), by:$by, reason:$rs}'
    done | jq -cs '.')
  allow=$( [ -f "$FW_ALLOW" ] && grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}' | jq -R . | jq -cs '.')
  jq -n --argjson b "${blocks:-[]}" --argjson a "${allow:-[]}" --argjson nft "$nftok" \
    --arg on "$(fw_conf_get AUTO 0)" --arg lim "$(fw_conf_get LIMIT 150)" --arg dur "$(fw_conf_get DURATION 3600)" \
    '{nft:$nft, auto:{on:($on=="1"), limit:($lim|tonumber), duration:($dur|tonumber)}, blocks:$b, allow:$a}' > "$FW_STATE.tmp" \
    && chown root:"$PANEL_SYSUSER" "$FW_STATE.tmp" && chmod 640 "$FW_STATE.tmp" && mv -f "$FW_STATE.tmp" "$FW_STATE"
  return 0
}

cmd_block(){
  local ip="${1:-}" dur="24h" reason="" by="manual" extra="" secs exp p
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) dur="${2:-}"; shift 2 || shift ;;
      --reason) reason="${2:-}"; shift 2 || shift ;;
      --by) by="${2:-}"; shift 2 || shift ;;
      --protect) extra="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  if [ "$(fw_fam "$ip")" = 4 ] && [ "$(fw_prefix "$ip")" -lt 8 ]; then die "Rede demasiado grande (mínimo /8)."; fi
  if [ "$(fw_fam "$ip")" = 6 ] && [ "$(fw_prefix "$ip")" -lt 32 ]; then die "Rede demasiado grande (mínimo /32)."; fi
  case "$by" in manual|auto) ;; *) by=manual ;; esac
  secs=$(fw_secs "$dur") || die "Duração inválida: $dur (ex.: 3600s, 1h, 24h, 7d ou perm)."
  reason=$(printf '%s' "$reason" | tr -d '|\r\n' | cut -c1-80)
  p=$( { fw_protected_list; if [ -n "$extra" ] && fw_ip_valid "$extra"; then echo "$extra"; fi; } | sort -u | while read -r q; do
         if [ -n "$q" ] && fw_ip_valid "$q" && fw_overlap "$ip" "$q"; then echo "$q"; break; fi
       done )
  [ -z "$p" ] || die "Não é possível bloquear $ip: abrange $p, que está protegido (este servidor, IP de confiança ou IP de onde usas o painel)."
  fw_init
  fw_nft_add "$ip" "$secs" || die "O nftables recusou o bloqueio de $ip."
  exp=0; [ "$secs" -gt 0 ] && exp=$(( EPOCHSECONDS + secs ))
  fw_list_set "$ip"
  echo "$ip|$exp|$EPOCHSECONDS|$by|$reason" >> "$FW_BLOCKS"
  ss -K dst "$ip" >/dev/null 2>&1
  fw_write_state
  if [ "$secs" -gt 0 ]; then echo "$ip bloqueado até $(date -d "@$exp" '+%d/%m/%Y %H:%M'). Ligações abertas cortadas."
  else echo "$ip bloqueado permanentemente. Ligações abertas cortadas."; fi
  return 0
}
cmd_unblock(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  fw_has_nft && fw_nft_del "$ip"
  fw_list_set "$ip"
  fw_write_state
  echo "$ip desbloqueado."
  return 0
}
cmd_block_list(){
  printf '%-40s %-17s %-8s %s\n' "IP / REDE" "EXPIRA" "ORIGEM" "MOTIVO"
  [ -f "$FW_BLOCKS" ] && awk -F'|' -v now="$EPOCHSECONDS" '$2 == 0 || $2 > now' "$FW_BLOCKS" | while IFS='|' read -r ip ex cr by rs; do
    printf '%-40s %-17s %-8s %s\n' "$ip" "$([ "$ex" = 0 ] && echo permanente || date -d "@$ex" '+%d/%m/%Y %H:%M')" "$by" "$rs"
  done
  return 0
}
cmd_allow_add(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  touch "$FW_ALLOW"; chmod 600 "$FW_ALLOW"
  grep -qxF "$ip" "$FW_ALLOW" || echo "$ip" >> "$FW_ALLOW"
  if [ "$(srv_get PORTS_ACCESS all)" = lan ]; then ports_allow_write; apply_nginx >/dev/null 2>&1; fi
  if [ -f "$FW_BLOCKS" ] && cut -d'|' -f1 "$FW_BLOCKS" | grep -qxF "$ip"; then fw_has_nft && fw_nft_del "$ip"; fw_list_set "$ip"; fi
  fw_write_state
  echo "$ip adicionado aos IPs de confiança (nunca é bloqueado)."
  return 0
}
cmd_allow_del(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  if [ -f "$FW_ALLOW" ]; then grep -vxF "$ip" "$FW_ALLOW" > "$FW_ALLOW.tmp"; mv -f "$FW_ALLOW.tmp" "$FW_ALLOW"; fi
  [ -f "$FW_ALLOW" ] && grep -qxF "$ip" "$FW_ALLOW" && die "Não foi possível remover $ip."
  chmod 600 "$FW_ALLOW" 2>/dev/null
  if [ "$(srv_get PORTS_ACCESS all)" = lan ]; then ports_allow_write; apply_nginx >/dev/null 2>&1; fi
  fw_write_state
  echo "$ip removido dos IPs de confiança."
  return 0
}
cmd_fw_auto(){
  local on="${1:-}" lim dur secs re='^[0-9]{1,6}$'
  case "$on" in on|1) on=1 ;; off|0) on=0 ;; *) die "Usa: mpanel fw-auto on|off [--limit N] [--duration 1h]" ;; esac
  shift
  lim=$(fw_conf_get LIMIT 150); dur=$(fw_conf_get DURATION 3600)
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) lim="${2:-}"; shift 2 || shift ;;
      --duration) dur="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$lim" =~ $re ]] && [ "$lim" -ge 10 ] || die "O limite tem de ser um número igual ou superior a 10."
  secs=$(fw_secs "$dur") || die "Duração inválida: $dur"
  [ "$secs" -gt 0 ] || die "O bloqueio automático tem de ter duração (não pode ser permanente)."
  printf 'AUTO=%s\nLIMIT=%s\nDURATION=%s\n' "$on" "$lim" "$secs" > "$FW_CONF"; chmod 644 "$FW_CONF"
  fw_write_state
  if [ "$on" = 1 ]; then echo "Bloqueio automático ativo: IPs com mais de $lim ligações abertas ficam bloqueados durante $(( secs / 60 )) min."
  else echo "Bloqueio automático desativado."; fi
  return 0
}
cmd_fw_restore(){
  local ip ex cr by rs left
  fw_has_nft || { warn "O nftables não está instalado."; return 0; }
  nft delete table inet minipainel >/dev/null 2>&1
  fw_init
  fw_list_set ""
  [ -f "$FW_BLOCKS" ] && while IFS='|' read -r ip ex cr by rs; do
    left=0; [ "$ex" != 0 ] && left=$(( ex - EPOCHSECONDS ))
    [ "$ex" != 0 ] && [ "$left" -le 0 ] && continue
    fw_nft_add "$ip" "$left" >/dev/null 2>&1 || warn "Não foi possível repor o bloqueio de $ip."
  done < "$FW_BLOCKS"
  fw_write_state
  mail_fw_apply
  geo_apply
  echo "Bloqueios repostos: $( [ -f "$FW_BLOCKS" ] && wc -l < "$FW_BLOCKS" || echo 0)."
  return 0
}
cmd_conn_list(){
  local f=$DATA/stats/conns.json ip="${1:-}"
  [ -s "$f" ] || die "Ainda não há dados. Verifica: systemctl status minipainel-stats"
  if [ -n "$ip" ]; then
    jq -r --arg ip "$ip" '.ips[] | select(.ip == $ip) | "\(.ip): \(.n) ligações (\(.syn) em espera)", (.ports | to_entries[] | "  porta \(.key): \(.value)")' "$f"
  else
    jq -r '"Ligações abertas: \(.total)   IPs distintos: \(.distinct)   Em espera (SYN): \(.syn)", (.ips[:30][] | "  \(.n)\t\(.ip)\t" + (.ports | to_entries | map("\(.key)(\(.value))") | join(" ")))' "$f"
  fi
  return 0
}

# ---------- tarefas agendadas (cron) por site, como o utilizador do site ----------
CRON_DIR=/etc/minipainel/cron          # <site>.json (definições) e <site>/<id>.sh (comandos)
