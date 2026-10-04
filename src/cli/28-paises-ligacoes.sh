# ============================ PAÍSES E LIMITE DE LIGAÇÕES ====================
GEO_DIR=/var/lib/minipainel/geoip
geo_cc_valid(){ [[ "$1" =~ ^[A-Z]{2}$ ]] && [ -f "$GEO_DIR/cc/$1.v4" ] || [ -f "$GEO_DIR/cc/$1.v6" ]; }
cmd_geoip_update(){
  local m tmp ok=0
  tmp=$(mktemp); install -d -o root -g "$PANEL_SYSUSER" -m 750 "$GEO_DIR"
  for m in "$(date +%Y-%m)" "$(date -d '-1 month' +%Y-%m)"; do
    curl -fsSL -m 300 -o "$tmp" "https://download.db-ip.com/free/dbip-country-lite-$m.csv.gz" && gzip -t "$tmp" 2>/dev/null && [ "$(stat -c %s "$tmp")" -gt 1000000 ] && { ok=1; break; }
  done
  [ "$ok" = 1 ] || { rm -f "$tmp"; die "Não foi possível descarregar a base de geolocalização (DB-IP)."; }
  "$(php_cli "$PANEL_PHP")" /usr/local/lib/minipainel/geoip-build.php "$tmp" "$GEO_DIR" || { rm -f "$tmp"; die "Falhou a construção da base de geolocalização."; }
  rm -f "$tmp"
  chown -R root:"$PANEL_SYSUSER" "$GEO_DIR"; find "$GEO_DIR" -type d -exec chmod 750 {} +; find "$GEO_DIR" -type f -exec chmod 640 {} +
  date +%s > "$GEO_DIR/updated"
  geo_apply
  echo "Base de geolocalização atualizada (DB-IP Lite, $(date +%Y-%m))."
  return 0
}
geo_elems(){ # ficheiro(s) de gamas -> linhas "add element"
  local set=$1; shift
  cat "$@" 2>/dev/null | grep -v '^$' | awk -v s="$set" 'BEGIN{n=0} { if (n % 2000 == 0) { if (n) print " }"; printf "add element inet minipainel %s {", s } else printf ","; printf " %s", $0; n++ } END { if (n) print " }" }'
}
geo_apply(){ # carrega países bloqueados, país da casa e IPs de confiança na firewall
  fw_has_nft || return 0
  nft list table inet minipainel >/dev/null 2>&1 || return 0
  nft list set inet minipainel geo4 >/dev/null 2>&1 || return 0
  local f c home; f=$(mktemp); home=$(srv_get HOME_CC PT)
  {
    for c in geo4 geo6 home4 home6; do echo "flush set inet minipainel $c"; done
    local files4=() files6=()
    for c in $(srv_get GEO_BLOCK ''); do files4+=("$GEO_DIR/cc/$c.v4"); files6+=("$GEO_DIR/cc/$c.v6"); done
    [ ${#files4[@]} -gt 0 ] && geo_elems geo4 "${files4[@]}" && geo_elems geo6 "${files6[@]}"
    geo_elems home4 "$GEO_DIR/cc/$home.v4"; geo_elems home6 "$GEO_DIR/cc/$home.v6"
  } > "$f"
  nft -f "$f" 2>/dev/null || warn "Não foi possível carregar os países na firewall."
  rm -f "$f"; trust_apply
  return 0
}
trust_apply(){ # IPs que nunca são bloqueados (servidor, confiança, admin dos últimos 7 dias)
  nft list set inet minipainel trust4 >/dev/null 2>&1 || return 0
  local ip f; f=$(mktemp)
  { echo "flush set inet minipainel trust4"; echo "flush set inet minipainel trust6"
    for ip in $(fw_protected_list | sort -u); do
      if [[ "$ip" == *:* ]]; then echo "add element inet minipainel trust6 { $ip }"; elif [[ "$ip" =~ ^[0-9./]+$ ]]; then echo "add element inet minipainel trust4 { $ip }"; fi
    done; } > "$f"
  nft -f "$f" 2>/dev/null; rm -f "$f"; return 0
}
cmd_geo_block(){ # add|del CC
  local op="${1:-}" c; c=$(printf '%s' "${2:-}" | tr 'a-z' 'A-Z'); local cur
  geo_cc_valid "$c" || die "País desconhecido: $c (código de 2 letras, ex.: CN). Se a base ainda não existir: mpanel geoip-update"
  [ "$c" = "$(srv_get HOME_CC PT)" ] && [ "$op" = add ] && die "Não é possível bloquear o país do próprio servidor ($c)."
  cur=" $(srv_get GEO_BLOCK '') "
  case "$op" in
    add) [[ "$cur" == *" $c "* ]] || cur+="$c " ;;
    del) cur=${cur// $c / } ;;
    *) die "Usa: mpanel geo-block add|del <país>" ;;
  esac
  srv_set GEO_BLOCK "$(echo $cur | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  geo_apply
  echo "$([ "$op" = add ] && echo "País $c bloqueado (ligações novas)." || echo "País $c desbloqueado.")"
  return 0
}
cmd_overload_settings(){
  local on mx st sp home re='^[0-9]{1,7}$'
  on=$(srv_get OVL 1); mx=$(srv_get OVL_MAX auto); st=$(srv_get OVL_ON 80); sp=$(srv_get OVL_OFF 60); home=$(srv_get HOME_CC PT)
  while [ $# -gt 0 ]; do
    case "$1" in
      --on) on=1; shift ;; --off) on=0; shift ;;
      --max) mx="${2:-}"; shift 2 || shift ;; --start) st="${2:-}"; shift 2 || shift ;; --stop) sp="${2:-}"; shift 2 || shift ;;
      --home) home=$(printf '%s' "${2:-}" | tr 'a-z' 'A-Z'); shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [ "$mx" = auto ] || { [[ "$mx" =~ $re ]] && [ "$mx" -ge 50 ]; } || die "Capacidade inválida (auto ou um número ≥ 50)."
  [[ "$st" =~ ^[0-9]{1,2}$ ]] && [[ "$sp" =~ ^[0-9]{1,2}$ ]] && [ "$st" -ge 5 ] && [ "$sp" -ge 1 ] && [ "$sp" -lt "$st" ] || die "Os limites são percentagens, e o de saída tem de ser menor que o de entrada."
  geo_cc_valid "$home" || [ ! -d "$GEO_DIR/cc" ] || die "País desconhecido: $home"
  [[ " $(srv_get GEO_BLOCK '') " == *" $home "* ]] && die "O país $home está bloqueado; desbloqueia-o primeiro."
  srv_set OVL "$on"; srv_set OVL_MAX "$mx"; srv_set OVL_ON "$st"; srv_set OVL_OFF "$sp"; srv_set HOME_CC "$home"
  geo_apply
  echo "Proteção por limite de ligações: $([ "$on" = 1 ] && echo "ativa (entra aos $st%, sai abaixo de $sp%; capacidade $mx; mantém sempre $home)" || echo desligada)."
  return 0
}
ovl_capacity(){ # ligações simultâneas que o servidor aguenta (nginx)
  local mx wp wc; mx=$(srv_get OVL_MAX auto)
  if [ "$mx" != auto ]; then echo "$mx"; return; fi
  wp=$(grep -m1 -E '^\s*worker_processes' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')
  [[ "$wp" =~ ^[0-9]+$ ]] || wp=$(nproc 2>/dev/null || echo 1)
  wc=$(grep -m1 -E '^\s*worker_connections' /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';'); [[ "$wc" =~ ^[0-9]+$ ]] || wc=768
  echo $(( wp * wc ))
}
geo_state_json(){
  local upd n; upd=$(cat "$GEO_DIR/updated" 2>/dev/null || echo 0); n=$(ls "$GEO_DIR/cc" 2>/dev/null | sed 's/\..*//' | sort -u | tr '\n' ' ')
  jq -n --arg b "$(srv_get GEO_BLOCK '')" --arg h "$(srv_get HOME_CC PT)" --arg u "$upd" --arg l "$n" --arg on "$(srv_get OVL 1)" --arg mx "$(srv_get OVL_MAX auto)" \
     --arg cap "$(ovl_capacity)" --arg st "$(srv_get OVL_ON 80)" --arg sp "$(srv_get OVL_OFF 60)" \
     '{block:($b | split(" ") | map(select(. != ""))), home:$h, updated:($u|tonumber), countries:($l | split(" ") | map(select(. != ""))),
       ovl:{on:($on == "1"), max:$mx, capacity:($cap|tonumber), start:($st|tonumber), stop:($sp|tonumber)}}'
}

