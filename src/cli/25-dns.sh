# ============================ DNS AUTORITATIVO (NSD) =========================
DNS_CONF=/etc/minipainel/dns.conf           # ENABLED, NS1, NS2, IP, IP6, HOSTMASTER
DNS_DIR=/etc/minipainel/dns                 # <zona>.json
NSD_ZONES=/etc/nsd/zones
dns_get(){ local v; v=$(grep -m1 "^$1=" "$DNS_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
dns_set(){ touch "$DNS_CONF"; chmod 600 "$DNS_CONF"; if grep -q "^$1=" "$DNS_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$DNS_CONF"; else echo "$1=$2" >> "$DNS_CONF"; fi; }
dns_on(){ [ "$(dns_get ENABLED 0)" = 1 ]; }
dns_need(){ dns_on || die "O DNS não está ativo. Ativa-o na página DNS ou com: mpanel dns-enable --ns1 ns1.dominio.pt --ns2 ns2.dominio.pt"; }
dns_zone_json(){ echo "$DNS_DIR/$1.json"; }
dns_load(){ local f; f=$(dns_zone_json "$1"); if [ -s "$f" ]; then cat "$f"; else echo '{"serial":0,"records":[]}'; fi; }
dns_save(){ install -d -m 700 "$DNS_DIR"; printf '%s\n' "$2" | jq '.' > "$(dns_zone_json "$1").tmp" && chmod 600 "$(dns_zone_json "$1").tmp" && mv -f "$(dns_zone_json "$1").tmp" "$(dns_zone_json "$1")"; }
dns_zones(){ [ -d "$DNS_DIR" ] || return 0; find "$DNS_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed 's|\.json$||' | grep -E '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' | sort; }   # só domínios a sério (com ponto)
dns_fqdn(){ case "$1" in *.) echo "$1" ;; *.*) echo "$1." ;; *) echo "$1" ;; esac; }   # valores com domínio completo levam ponto final
dns_serial(){ local old=$1 d; d=$(date +%Y%m%d); if [ "${old:0:8}" = "$d" ]; then echo $(( old + 1 )); else echo "${d}01"; fi; }
dns_ips(){ ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
dns_txt_quote(){ # divide em pedaços de 255 caracteres entre aspas
  local v=$1 out="" chunk
  v=${v//\\/\\\\}; v=${v//\"/\\\"}
  while [ -n "$v" ]; do chunk=${v:0:250}; v=${v:250}; out+="\"$chunk\" "; done
  echo "${out% }"
}
dns_write_zone(){ # gera o ficheiro de zona, verifica-o e só então o ativa
  local z=$1 j f tmp ns1 ns2 hm serial
  j=$(dns_load "$z"); f="$NSD_ZONES/$z.zone"; tmp=$(mktemp)
  ns1=$(dns_get NS1); ns2=$(dns_get NS2); hm=$(dns_get HOSTMASTER "hostmaster.$z"); hm=${hm/@/.}
  serial=$(jq -r '.serial' <<<"$j")
  {
    printf '; IDDigital Hosting — zona %s (gerada pelo painel; não editar à mão)\n$ORIGIN %s.\n$TTL %s\n' "$z" "$z" "$(dns_get DEF_TTL 3600)"
    printf '@ IN SOA %s %s ( %s %s %s %s %s )\n' "$(dns_fqdn "$ns1")" "$(dns_fqdn "$hm")" "$serial" "$(dns_get SOA_REFRESH 10800)" "$(dns_get SOA_RETRY 3600)" "$(dns_get SOA_EXPIRE 1209600)" "$(dns_get SOA_MIN 3600)"
    local nsx; while IFS= read -r nsx; do [ -n "$nsx" ] && printf '@ IN NS %s\n' "$(dns_fqdn "$nsx")"; done < <(dns_ns_list)
    jq -r '.records[] | [.name, (if (.ttl // 0) >= 60 then (.ttl|tostring) else "-" end), .type, (.prio // 0 | tostring), .value] | @tsv' <<<"$j" | while IFS=$'\t' read -r n t ty pr v; do
      [ "$t" = "-" ] && t=""   # TTL automático: usa o $TTL da zona (um campo vazio deslocaria as colunas)
      case "$ty" in
        TXT) printf '%s %s IN TXT %s\n' "$n" "$t" "$(dns_txt_quote "$v")" ;;
        MX) printf '%s %s IN MX %s %s\n' "$n" "$t" "$pr" "$(dns_fqdn "$v")" ;;
        SRV) printf '%s %s IN SRV %s %s %s %s\n' "$n" "$t" "$pr" "${v%% *}" "$(echo "$v" | awk '{print $2}')" "$(dns_fqdn "${v##* }")" ;;
        CNAME|NS) printf '%s %s IN %s %s\n' "$n" "$t" "$ty" "$(dns_fqdn "$v")" ;;
        CAA) printf '%s %s IN CAA %s\n' "$n" "$t" "$v" ;;
        *) printf '%s %s IN %s %s\n' "$n" "$t" "$ty" "$v" ;;
      esac
    done
  } > "$tmp"
  local errf; errf=$(mktemp)
  if ! nsd-checkzone "$z" "$tmp" >"$errf" 2>&1; then
    local e; e=$(tail -n 3 "$errf" | tr '\n' ' '); rm -f "$tmp" "$errf"
    echo "Zona $z inválida: $e" >&2; return 1
  fi
  rm -f "$errf"
  install -d -o root -g nsd -m 750 "$NSD_ZONES"
  install -o root -g nsd -m 640 "$tmp" "$f"; rm -f "$tmp"
  return 0
}
# ---------- DNS secundário externo (ex.: Hurricane Electric) ----------
dns_sec_on(){ [ -n "$(dns_get SEC_IPS '')" ]; }
dns_ns_list(){ # nameservers da zona e da delegação: ns1 do painel, ns2 (sem secundário) e os do secundário
  local n
  echo "$(dns_get NS1)"
  if ! dns_sec_on || [ "$(dns_get SEC_KEEP_NS2 0)" = 1 ]; then echo "$(dns_get NS2)"; fi
  if dns_sec_on; then for n in $(dns_get SEC_NS ''); do echo "$n"; done; fi
}
dns_nsd_outgoing(){ # o outgoing-interface só é válido dentro das regras da zona: nunca no server: do nsd.conf
  [ -f /etc/nsd/nsd.conf ] && sed -i '/^    outgoing-interface:/d' /etc/nsd/nsd.conf
  return 0
}
cmd_dns_secondary(){ # --provider he|custom|off [--ips "…"] [--notify "…"] [--ns "…"] [--tsig on|off] [--keep-ns2 on|off] [--new-key]
  local prov="" ips ntf nss tsig kn2 newkey=0 a
  dns_need
  ips=$(dns_get SEC_IPS ''); ntf=$(dns_get SEC_NOTIFY ''); nss=$(dns_get SEC_NS ''); tsig=$(dns_get SEC_TSIG 1); kn2=$(dns_get SEC_KEEP_NS2 0)
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) prov="${2:-}"; shift 2 || shift ;;
      --ips) ips="${2:-}"; shift 2 || shift ;;
      --notify) ntf="${2:-}"; shift 2 || shift ;;
      --ns) nss="${2:-}"; shift 2 || shift ;;
      --tsig) case "${2:-}" in on) tsig=1 ;; off) tsig=0 ;; *) die "--tsig on|off" ;; esac; shift 2 || shift ;;
      --keep-ns2) case "${2:-}" in on) kn2=1 ;; off) kn2=0 ;; *) die "--keep-ns2 on|off" ;; esac; shift 2 || shift ;;
      --new-key) newkey=1; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  case "$prov" in
    off) for a in SEC_PROVIDER SEC_IPS SEC_NOTIFY SEC_NS; do dns_set "$a" ""; done
         local z; while IFS= read -r z; do [ -n "$z" ] && dns_bump "$z" "$(dns_load "$z")" >/dev/null 2>&1; done < <(dns_zones)
         dns_apply; echo "DNS secundário desligado: as zonas voltam a ter só os nameservers deste servidor."; return 0 ;;
    he) ips="216.218.133.2 2001:470:600::2"; ntf="216.218.133.2"; [ -n "$nss" ] && [ "$(dns_get SEC_PROVIDER '')" = he ] || nss="ns2.he.net ns3.he.net ns4.he.net ns5.he.net" ;;
    custom|"") prov=${prov:-$(dns_get SEC_PROVIDER custom)} ;;
    *) die "Serviço: he (Hurricane Electric), custom ou off." ;;
  esac
  for a in $ips $ntf; do fw_ip_valid "$a" || die "IP inválido: $a"; done
  for a in $nss; do [[ "$a" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "Nameserver inválido: $a"; done
  [ -n "$ips" ] && [ -n "$nss" ] || die "Indica os IPs que copiam as zonas e os nameservers do serviço."
  dns_set SEC_PROVIDER "$prov"; dns_set SEC_IPS "$ips"; dns_set SEC_NOTIFY "${ntf:-$ips}"; dns_set SEC_NS "$nss"; dns_set SEC_TSIG "$tsig"; dns_set SEC_KEEP_NS2 "$kn2"
  [ -n "$(dns_get SEC_KEYNAME '')" ] || dns_set SEC_KEYNAME "minipainel-$(hostname -s | tr -cd 'a-z0-9-' | cut -c1-30)-xfr"
  if [ "$newkey" = 1 ] || [ -z "$(dns_get SEC_KEY '')" ]; then dns_set SEC_KEY "$(openssl rand -base64 32)"; fi
  # os NS das zonas mudam (entram os do secundário): série nova em todas
  local z; while IFS= read -r z; do [ -n "$z" ] && dns_bump "$z" "$(dns_load "$z")" >/dev/null 2>&1; done < <(dns_zones)
  dns_nsd_outgoing
  dns_apply || die "Configuração do NSD inválida; o secundário não foi ativado."
  systemctl restart nsd >/dev/null 2>&1 || true   # o outgoing-interface só é lido ao arrancar
  echo "DNS secundário ativo ($prov): cópia autorizada para $ips$([ "$tsig" = 1 ] && echo ' com chave TSIG'); nameservers das zonas: $(dns_ns_list | tr '\n' ' ')"
  return 0
}
dns_sec_conf(){ # bloco do NSD: chave, quem pode copiar e quem é avisado
  dns_sec_on || return 0
  local a k=NOKEY
  if [ "$(dns_get SEC_TSIG 1)" = 1 ]; then
    k=$(dns_get SEC_KEYNAME)
    printf 'key:\n    name: "%s"\n    algorithm: hmac-sha256\n    secret: "%s"\n' "$k" "$(dns_get SEC_KEY)"
  fi
  printf 'pattern:\n    name: "mp-secundario"\n'
  for a in $(dns_get SEC_IPS); do printf '    provide-xfr: %s %s\n' "$a" "$k"; done
  for a in $(dns_get SEC_NOTIFY); do printf '    notify: %s NOKEY\n' "$a"; done
  # avisos e cópias saem sempre dos IPs públicos configurados (o secundário só aceita avisos do principal)
  for a in $(dns_get IP) $(dns_get IP6); do printf '    outgoing-interface: %s\n' "$a"; done
}
dns_apply(){ # lista de zonas do NSD e recarga
  local z
  local before after
  before=$(md5sum /etc/nsd/minipainel-zones.conf 2>/dev/null | awk '{print $1}')
  local pat=""; dns_sec_on && pat='    include-pattern: "mp-secundario"\n'
  { echo "# IDDigital Hosting — zonas (gerado pelo painel; não editar à mão)"; dns_sec_conf
    while IFS= read -r z; do [ -n "$z" ] && printf "zone:\n    name: \"%s\"\n    zonefile: \"%s/%s.zone\"\n$pat" "$z" "$NSD_ZONES" "$z"; done < <(dns_zones); } > /etc/nsd/minipainel-zones.conf
  chown root:nsd /etc/nsd/minipainel-zones.conf 2>/dev/null; chmod 640 /etc/nsd/minipainel-zones.conf   # pode ter a chave TSIG
  after=$(md5sum /etc/nsd/minipainel-zones.conf | awk '{print $1}')
  nsd-checkconf /etc/nsd/nsd.conf >/dev/null 2>&1 || { echo "Configuração do NSD inválida." >&2; return 1; }
  if [ "$before" != "$after" ]; then
    # zonas acrescentadas ou retiradas: o NSD só as lê ao arrancar (corte inferior a 1 segundo)
    systemctl restart nsd >/dev/null 2>&1 || { pkill -x nsd; sleep 1; nsd -c /etc/nsd/nsd.conf >/dev/null 2>&1; }
  else
    systemctl reload nsd >/dev/null 2>&1 || pkill -HUP -x nsd 2>/dev/null
  fi
  return 0
}
dns_bump(){ # zona json -> grava com serial novo, gera e ativa (repõe o anterior se falhar)
  local z=$1 j=$2 old
  old=$(dns_load "$z")
  j=$(jq --argjson s "$(dns_serial "$(jq -r '.serial' <<<"$old")")" '.serial = $s' <<<"$j")
  dns_save "$z" "$j"
  if ! dns_write_zone "$z"; then dns_save "$z" "$old"; return 1; fi
  dns_apply
}
dns_auto_records(){ # registos automáticos da zona: sites, email e nameservers que pertencem a ela
  local z=$1 ip ip6 n d rel recs="[]" h
  ip=$(dns_get IP); ip6=$(dns_get IP6)
  add(){ recs=$(jq -c --arg n "$1" --arg t "$2" --arg v "$3" --argjson p "${4:-0}" '. + [{name:$n, type:$t, value:$v, ttl:0, prio:$p, auto:true}]' <<<"$recs"); }
  rel(){ if [ "$1" = "$z" ]; then echo "@"; else echo "${1%."$z"}"; fi; }
  add "@" A "$ip"; [ -n "$ip6" ] && add "@" AAAA "$ip6"
  add "www" A "$ip"; [ -n "$ip6" ] && add "www" AAAA "$ip6"
  for h in "$(dns_get NS1)" "$(dns_get NS2)"; do case "$h" in *."$z") add "$(rel "$h")" A "$ip" ;; esac; done
  for n in $(site_names); do for d in $(site_get "$n" DOMAINS); do
    case "$d" in "$z"|"www.$z") ;; *."$z") add "$(rel "$d")" A "$ip" ;; esac
  done; done
  if mail_on; then
    h=$(mail_get HOST)
    case "$h" in *."$z") add "$(rel "$h")" A "$ip" ;; esac
    if [ "$(mail_data | jq --arg d "$z" '.domains | has($d)')" = true ]; then
      add "@" MX "$h" 10
      add "@" TXT "v=spf1 mx a:$h ~all"
      [ -n "$(mail_dkim_value "$z")" ] && add "mp._domainkey" TXT "$(mail_dkim_value "$z")"
      add "_dmarc" TXT "v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@$z"
    fi
  fi
  add "@" CAA '0 issue "letsencrypt.org"'
  jq -c 'unique_by([.name, .type, .value])' <<<"$recs"
}
dns_sync_zone(){ # substitui os registos automáticos pelos atuais (mantém os manuais)
  local z=$1 j auto
  [ -f "$DNS_DIR/$z.json" ] || return 0   # nunca cria zonas: só atualiza as que existem
  j=$(dns_load "$z"); auto=$(dns_auto_records "$z")
  j=$(jq --argjson a "$auto" '(.off // []) as $off | .records = ([.records[] | select(.auto != true)] + ($a | map(select((.name + "|" + .type) as $k | ($off | index($k)) | not)) | to_entries | map(.value + {id: ("auto" + (.key | tostring))})))' <<<"$j")
  dns_bump "$z" "$j"
}
dns_autosync(){ # chamado quando muda um site ou o email: atualiza as zonas afetadas
  dns_on || return 0
  local z; while IFS= read -r z; do [ -n "$z" ] && dns_sync_zone "$z" >/dev/null 2>&1; done < <(dns_zones)
  return 0
}

cmd_dns_cleanup(){ # remove zonas cujo nome não é um domínio (ex.: bin, boot… criadas por um erro antigo)
  local f n c=0
  [ -d "$DNS_DIR" ] || { echo "Sem zonas DNS."; return 0; }
  while IFS= read -r f; do
    n=${f%.json}
    if ! [[ "$n" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then rm -f -- "$DNS_DIR/$f" "$NSD_ZONES/$n.zone"; c=$((c+1)); fi
  done < <(find "$DNS_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n')
  if [ "$c" -gt 0 ] && dns_on; then dns_apply >/dev/null 2>&1; fi
  echo "Zonas DNS inválidas removidas: $c."; return 0
}
# ---------- DNS: edição, modelos, importação, propagação e servidor ----------
dns_off_keys(){ dns_load "$1" | jq -c '.off // []'; }   # nome|tipo que o painel deixou de gerir (o utilizador alterou-os)
dns_rec_norm(){ # zona nome -> nome relativo
  local z=$1 n; n=$(printf '%s' "$2" | tr 'A-Z' 'a-z'); n=${n%.}; n=${n%."$z"}; [ "$n" = "$z" ] && n="@"; [ -n "$n" ] || n="@"; echo "$n"
}
dns_ttl_ok(){ [[ "$1" =~ ^[0-9]{1,6}$ ]] && { [ "$1" = 0 ] || [ "$1" -ge 60 ]; }; }
cmd_dns_rec_edit(){ # zona id nome tipo valor [--ttl N] [--prio N]
  local z="${1:-}" id="${2:-}" n="${3:-}" t="${4:-}" v="${5:-}" ttl=0 pr=10 j why old
  dns_need; [ $# -ge 5 ] && shift 5
  while [ $# -gt 0 ]; do case "$1" in --ttl) ttl="${2:-}"; shift 2 || shift ;; --prio) pr="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  [[ "$id" =~ ^[A-Za-z0-9]{3,16}$ ]] || die "Identificador inválido."
  old=$(dns_load "$z" | jq -c --arg id "$id" '.records[] | select(.id == $id)'); [ -n "$old" ] || die "Registo não encontrado."
  n=$(dns_rec_norm "$z" "$n"); t=$(printf '%s' "$t" | tr 'a-z' 'A-Z')
  dns_ttl_ok "$ttl" || die "TTL inválido (Auto ou 60 segundos ou mais)."; [[ "$pr" =~ ^[0-9]{1,5}$ ]] || die "Prioridade inválida."
  why=$(dns_valid_rec "$n" "$t" "$v") || die "$why"
  # um registo do painel que é alterado passa a manual, e o painel deixa de gerir esse nome+tipo
  j=$(dns_load "$z" | jq --arg id "$id" --arg n "$n" --arg t "$t" --arg v "$v" --argjson ttl "$ttl" --argjson p "$pr" --arg nid "$(openssl rand -hex 6)" '
      (.records[] | select(.id == $id)) as $o
      | .off = ((.off // []) + (if $o.auto == true then [$o.name + "|" + $o.type] else [] end) | unique)
      | .records = [.records[] | if .id == $id then {id:(if $o.auto == true then $nid else $id end), name:$n, type:$t, value:$v, ttl:$ttl, prio:$p, auto:false} else . end]')
  dns_bump "$z" "$j" || die "Registo recusado pelo verificador de zonas; nada foi alterado."
  echo "Registo atualizado em $z."; return 0
}
cmd_dns_reset(){ # zona — volta aos registos predefinidos do painel
  local z="${1:-}" j auto; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  auto=$(dns_auto_records "$z")
  j=$(dns_load "$z" | jq --argjson a "$auto" '($a | map(.name + "|" + .type)) as $k | .off = [] | .records = [.records[] | select(.auto != true) | select((.name + "|" + .type) as $x | ($k | index($x)) | not)]')
  dns_save "$z" "$j"; dns_sync_zone "$z" || die "Não foi possível repor a zona."
  echo "Registos predefinidos repostos em $z (os registos manuais de outros nomes mantêm-se)."; return 0
}
cmd_dns_template(){ # zona local|google|microsoft
  local z="${1:-}" tp="${2:-}" j mx spf; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  # tira o email atual (MX e SPF), seja do painel ou manual
  j=$(dns_load "$z" | jq '.records = [.records[] | select(.name != "@" or (.type != "MX" and (.type != "TXT" or ((.value | test("^v=spf1")) | not))))]')
  case "$tp" in
    local) j=$(jq '.off = ((.off // []) - ["@|MX", "@|TXT"])' <<<"$j"); dns_save "$z" "$j"; dns_sync_zone "$z" || die "Falhou."; echo "O email de $z passa a ser recebido por este servidor."; return 0 ;;
    google) mx='[{"v":"smtp.google.com","p":1}]'; spf='v=spf1 include:_spf.google.com ~all' ;;
    microsoft) mx=$(jq -cn --arg h "$(printf '%s' "$z" | tr '.' '-').mail.protection.outlook.com" '[{v:$h, p:0}]'); spf='v=spf1 include:spf.protection.outlook.com ~all' ;;
    *) die "Modelo: local, google ou microsoft." ;;
  esac
  j=$(jq --argjson mx "$mx" --arg spf "$spf" --arg tp "$tp" '
      .off = ((.off // []) + ["@|MX", "@|TXT"] | unique)
      | .records += ($mx | map({id:("t" + (.p|tostring) + (now|floor|tostring)), name:"@", type:"MX", value:.v, ttl:0, prio:.p, auto:false}))
      | .records += [{id:("s" + (now|floor|tostring)), name:"@", type:"TXT", value:$spf, ttl:0, prio:0, auto:false}]
      | if $tp == "microsoft" then (.records = [.records[] | select(.name != "autodiscover")] | .records += [{id:("a" + (now|floor|tostring)), name:"autodiscover", type:"CNAME", value:"autodiscover.outlook.com", ttl:0, prio:0, auto:false}]) else . end' <<<"$j")
  dns_bump "$z" "$j" || die "Não foi possível aplicar o modelo."
  echo "Modelo de email $( [ "$tp" = google ] && echo 'Google Workspace' || echo 'Microsoft 365') aplicado a $z."; return 0
}
cmd_dns_import(){ # zona texto-da-zona (formato BIND) — acrescenta os registos que não existam
  local z="${1:-}" txt="${2:-}" rows j ok=0 skip=0 bad=0 n t ttl p v why; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  [ -n "$txt" ] && [ ${#txt} -le 200000 ] || die "Cola o conteúdo do ficheiro de zona (até 200 KB)."
  rows=$(printf '%s' "$txt" | "$(php_cli "$PANEL_PHP")" -r '
    $z = $argv[1]; $origin = $z . "."; $ttl = 0; $last = "@"; $src = stream_get_contents(STDIN);
    $src = preg_replace_callback("/\\(([^)]*)\\)/s", function ($m) { return " " . str_replace(["\r", "\n"], " ", $m[1]) . " "; }, $src);  // registos em várias linhas (SOA, TXT longos): numa só linha
    foreach (preg_split("/\\r?\\n/", $src) as $ln) {
      $out = ""; $q = false; for ($i = 0; $i < strlen($ln); $i++) { $c = $ln[$i]; if ($c === "\"") $q = !$q; if ($c === ";" && !$q) break; $out .= $c; }
      if (trim($out) === "") continue;
      if (preg_match("/^\\\$ORIGIN\\s+(\\S+)/i", $out, $m)) { $origin = rtrim($m[1], ".") . "."; continue; }
      if (preg_match("/^\\\$TTL\\s+(\\d+)/i", $out, $m)) { continue; }
      $own = preg_match("/^\\s/", $out) ? $last : null;
      preg_match_all("/\"(?:[^\"\\\\]|\\\\.)*\"|\\S+/", trim($out), $mm); $tk = $mm[0];
      if ($own === null) { $own = array_shift($tk); $last = $own; }
      $rt = 0; while ($tk && (ctype_digit($tk[0]) || in_array(strtoupper($tk[0]), ["IN", "CH", "HS"], true))) { $x = array_shift($tk); if (ctype_digit($x)) $rt = (int)$x; }
      if (!$tk) continue; $type = strtoupper(array_shift($tk));
      $full = $own === "@" ? $origin : (substr($own, -1) === "." ? $own : $own . "." . $origin);
      $full = strtolower(rtrim($full, ".")); $zz = strtolower($z);
      if ($full === $zz) $name = "@"; elseif (substr($full, -strlen($zz) - 1) === "." . $zz) $name = substr($full, 0, -strlen($zz) - 1); else continue;
      $prio = 0;
      if ($type === "MX") { $prio = (int)array_shift($tk); $val = rtrim((string)array_shift($tk), "."); }
      elseif ($type === "SRV") { $prio = (int)array_shift($tk); $val = implode(" ", array_map(function ($x) { return rtrim($x, "."); }, $tk)); }
      elseif ($type === "TXT") { $val = implode("", array_map(function ($x) { return stripslashes(trim($x, "\"")); }, $tk)); }
      elseif ($type === "CNAME" || $type === "NS") { $val = rtrim((string)array_shift($tk), "."); if ($type === "NS" && $name === "@") continue; }
      elseif (in_array($type, ["A", "AAAA", "CAA"], true)) { $val = implode(" ", $tk); }
      else continue;
      echo implode("\t", [$name, $type, $rt, $prio, str_replace(["\t", "\n"], " ", $val)]), "\n";
    }' "$z" 2>/dev/null)
  j=$(dns_load "$z")
  while IFS=$'\t' read -r n t ttl p v; do
    [ -n "$n" ] || continue
    [ "$ttl" -ge 60 ] 2>/dev/null || ttl=0
    if ! why=$(dns_valid_rec "$n" "$t" "$v"); then bad=$((bad+1)); continue; fi
    if [ "$(jq --arg n "$n" --arg t "$t" --arg v "$v" '[.records[] | select(.name == $n and .type == $t and .value == $v)] | length' <<<"$j")" != 0 ]; then skip=$((skip+1)); continue; fi
    j=$(jq --arg n "$n" --arg t "$t" --arg v "$v" --argjson ttl "$ttl" --argjson p "${p:-0}" --arg id "$(openssl rand -hex 6)" '.records += [{id:$id, name:$n, type:$t, value:$v, ttl:$ttl, prio:$p, auto:false}]' <<<"$j")
    ok=$((ok+1))
  done <<<"$rows"
  [ "$ok" -gt 0 ] && { dns_bump "$z" "$j" || die "A zona importada tem erros; nada foi alterado."; }
  echo "Importação para $z: $ok registos acrescentados, $skip já existiam, $bad inválidos ignorados."; return 0
}
cmd_dns_propagation(){ # zona — compara este servidor com a Google (8.8.8.8)
  local z="${1:-}" f=$DATA/stats/dns-prop.json rows="[]" n t fq l g ip; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  ip=$(dns_get IP)
  while IFS=$'\t' read -r n t; do
    [ -n "$n" ] || continue
    if [ "$n" = "@" ]; then fq=$z; else fq="$n.$z"; fi
    l=$(dig +short +time=3 +tries=1 "$t" "$fq" @"$ip" 2>/dev/null | sed 's/\.$//' | tr -d '"' | sort | tr '\n' ' ' | sed 's/ $//')
    g=$(dig +short +time=3 +tries=1 "$t" "$fq" @8.8.8.8 2>/dev/null | sed 's/\.$//' | tr -d '"' | sort | tr '\n' ' ' | sed 's/ $//')
    rows=$(jq -c --arg n "$n" --arg t "$t" --arg l "$l" --arg g "$g" '. + [{name:$n, type:$t, local:$l, public:$g, ok:($l == $g and $l != "")}]' <<<"$rows")
  done < <(dns_load "$z" | jq -r '[.records[] | [.name, .type]] | unique | .[] | @tsv')
  [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1 || echo '{}' > "$f"
  jq --arg z "$z" --argjson r "$rows" --arg ts "$EPOCHSECONDS" '.[$z] = {ts:($ts|tonumber), rows:$r}' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"
  echo "Propagação de $z: $(jq '[.[] | select(.ok)] | length' <<<"$rows") de $(jq 'length' <<<"$rows") iguais na Internet."; return 0
}
cmd_dns_settings(){ # --ttl N --refresh N --retry N --expire N --minimum N
  local k v; dns_need
  while [ $# -gt 0 ]; do
    case "$1" in --ttl) k=DEF_TTL ;; --refresh) k=SOA_REFRESH ;; --retry) k=SOA_RETRY ;; --expire) k=SOA_EXPIRE ;; --minimum) k=SOA_MIN ;; *) die "Opção desconhecida: $1" ;; esac
    v="${2:-}"; [[ "$v" =~ ^[0-9]{2,8}$ ]] && [ "$v" -ge 60 ] || die "Valor inválido para $1 (segundos, mínimo 60)."
    dns_set "$k" "$v"; shift 2 || shift
  done
  local z; while IFS= read -r z; do [ -n "$z" ] && dns_bump "$z" "$(dns_load "$z")" >/dev/null 2>&1; done < <(dns_zones)
  echo "Valores predefinidos do DNS guardados e aplicados a todas as zonas."; return 0
}
cmd_dns_restart(){ dns_need; systemctl restart nsd >/dev/null 2>&1 && echo "Servidor DNS reiniciado." || die "O NSD não arrancou: journalctl -u nsd -n 30"; return 0; }
cmd_dns_server_check(){ # saúde do servidor DNS
  local f=$DATA/stats/dns-server.json r="[]" ip ns z1 a out
  dns_need; ip=$(dns_get IP); z1=$(dns_zones | head -n 1)
  chk(){ r=$(jq -c --arg id "$1" --arg n "$2" --arg s "$3" --arg m "$4" '. + [{id:$id, name:$n, status:$s, msg:$m}]' <<<"$r"); }
  if systemctl is-active --quiet nsd >/dev/null 2>&1; then chk svc "Serviço NSD" ok "A correr"; else chk svc "Serviço NSD" fail "Parado (botão Reiniciar)"; fi
  if out=$(nsd-checkconf /etc/nsd/nsd.conf 2>&1); then chk conf "Configuração" ok "Válida"; else chk conf "Configuração" fail "$(printf '%s' "$out" | tail -n 1 | cut -c1-160)"; fi
  for ns in $(dns_ns_list | grep -vxF -f <(dns_get SEC_NS "" | tr " " "\n" | grep .) 2>/dev/null || dns_ns_list); do   # só os nameservers deste servidor que estão em uso
    a=$(dig +short +time=3 +tries=1 A "$ns" @8.8.8.8 2>/dev/null | tail -n 1)
    if [ "$a" = "$ip" ]; then chk "ns:$ns" "$ns na Internet" ok "Aponta para $ip"
    elif [ -z "$a" ]; then chk "ns:$ns" "$ns na Internet" fail "Não existe na Internet: cria o registo A $ns → $ip na zona do domínio-mãe"
    else chk "ns:$ns" "$ns na Internet" fail "Aponta para $a (devia ser $ip)"; fi
  done
  if [ -n "$z1" ]; then
    if dig +short +time=3 +tries=1 SOA "$z1" @"$ip" 2>/dev/null | grep -q .; then chk udp "Resposta por UDP" ok "Responde ($z1)"; else chk udp "Resposta por UDP" fail "Não responde na porta 53/UDP"; fi
    if dig +short +tcp +time=3 +tries=1 SOA "$z1" @"$ip" 2>/dev/null | grep -q .; then chk tcp "Resposta por TCP" ok "Responde ($z1)"; else chk tcp "Resposta por TCP" fail "Não responde na porta 53/TCP"; fi
    if [ "$(jq -r '.[] | select(.id == "udp") | .status' <<<"$r")" != ok ]; then chk axfr "Transferência de zona" warn "Não testado (o servidor não responde)"
    elif dig AXFR "$z1" @"$ip" +time=3 +tries=1 2>/dev/null | grep -q 'IN[[:space:]]\+SOA'; then chk axfr "Transferência de zona" fail "Qualquer pessoa consegue copiar as zonas (AXFR aberto)"; else chk axfr "Transferência de zona" ok "Recusada (as zonas não podem ser copiadas)"; fi
  else chk udp "Zonas" warn "Ainda não há zonas para testar"; fi
  if [ "$(jq -r '.[] | select(.id == "udp") | .status' <<<"$r")" != ok ]; then chk open "Resolver aberto" warn "Não testado (o servidor não responde)"; jq -n --argjson r "$r" --arg ts "$EPOCHSECONDS" '{ts:($ts|tonumber), rows:$r}' > "$f"; chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"; echo "Verificação do servidor DNS: $(jq '[.[] | select(.status == "ok")] | length' <<<"$r") de $(jq 'length' <<<"$r") OK."; return 0; fi
  out=$(dig +time=3 +tries=1 A google.com @"$ip" 2>/dev/null | grep -o 'status: [A-Z]*' | cut -d' ' -f2)
  if [ "$out" = NOERROR ] && dig +short +time=3 +tries=1 A google.com @"$ip" 2>/dev/null | grep -q .; then chk open "Resolver aberto" fail "Responde por domínios de terceiros (pode ser usado em ataques)"; else chk open "Resolver aberto" ok "Não (só responde pelas tuas zonas)"; fi
  if dns_sec_on; then   # o secundário tem a versão atual de cada zona?
    local sns zz ok=0 tot=0 miss="" o1 o2
    sns=$(dns_get SEC_NS | awk '{print $1}')
    while IFS= read -r zz; do
      [ -n "$zz" ] || continue; tot=$((tot+1))
      o1=$(dig +short +time=3 +tries=1 SOA "$zz" @"$ip" 2>/dev/null | awk '{print $3}')
      o2=$(dig +short +time=4 +tries=1 SOA "$zz" @"$sns" 2>/dev/null | awk '{print $3}')
      if [ -n "$o2" ] && [ "$o2" = "$o1" ]; then ok=$((ok+1)); else miss+=" $zz"; fi
    done < <(dns_zones)
    if [ "$tot" = 0 ]; then chk sec "DNS secundário" warn "Ainda não há zonas para copiar"
    elif [ "$ok" = "$tot" ]; then chk sec "DNS secundário ($sns)" ok "Cópia em dia nas $tot zonas"
    elif [ "$ok" = 0 ]; then chk sec "DNS secundário ($sns)" fail "Nenhuma zona copiada ainda: acrescenta cada domínio no serviço (ex.: dns.he.net → Add a new slave)"
    else chk sec "DNS secundário ($sns)" warn "$ok de $tot em dia; por copiar ou desatualizadas:$miss"; fi
  fi
  jq -n --argjson r "$r" --arg ts "$EPOCHSECONDS" '{ts:($ts|tonumber), rows:$r}' > "$f"; chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"
  echo "Verificação do servidor DNS: $(jq '[.[] | select(.status == "ok")] | length' <<<"$r") de $(jq 'length' <<<"$r") OK."; return 0
}
cmd_dns_enable(){
  local ns1="" ns2="" ip="" ip6="" hm="" a re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'
  while [ $# -gt 0 ]; do
    case "$1" in
      --ns1) ns1="${2:-}"; shift 2 || shift ;; --ns2) ns2="${2:-}"; shift 2 || shift ;;
      --ip) ip="${2:-}"; shift 2 || shift ;; --ip6) ip6="${2:-}"; shift 2 || shift ;;
      --hostmaster) hm="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  ns1=${ns1:-$(dns_get NS1)}; ns2=${ns2:-$(dns_get NS2)}
  [[ "$ns1" =~ $re ]] && [[ "$ns2" =~ $re ]] && [ "$ns1" != "$ns2" ] || die "Indica dois nameservers diferentes (ex.: --ns1 ns1.host.iddigital.pt --ns2 ns2.host.iddigital.pt)."
  ip=${ip:-$(dns_get IP)}; [ -n "$ip" ] || ip=$(curl -s4 -m 6 https://api.ipify.org 2>/dev/null)
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Indica o IP público do servidor com --ip."
  [ -z "$ip6" ] || fw_ip_valid "$ip6" || die "IPv6 inválido."
  hm=${hm:-$(dns_get HOSTMASTER "$(srv_get EMAIL '')")}; [ -n "$hm" ] || hm="hostmaster@${ns1#*.}"
  if ! command -v nsd >/dev/null 2>&1; then
    echo "A instalar o NSD..."
    if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q nsd >/dev/null 2>&1; else dnf install -y -q nsd >/dev/null 2>&1; fi
    command -v nsd >/dev/null 2>&1 || die "Falhou a instalação do NSD."
  fi
  dns_set ENABLED 1; dns_set NS1 "$ns1"; dns_set NS2 "$ns2"; dns_set IP "$ip"; dns_set IP6 "$ip6"; dns_set HOSTMASTER "$hm"
  install -d -m 700 "$DNS_DIR"; install -d -o root -g nsd -m 750 "$NSD_ZONES"
  [ -f /etc/nsd/nsd.conf.minipainel-orig ] || cp -p /etc/nsd/nsd.conf /etc/nsd/nsd.conf.minipainel-orig 2>/dev/null
  {
    echo "# IDDigital Hosting — servidor DNS autoritativo (gerado pelo painel; não editar à mão)"
    echo "# Só responde pelas zonas do painel; nunca faz resolução recursiva."
    echo "server:"
    for a in $(dns_ips); do echo "    ip-address: $a"; done
    echo "    hide-version: yes"
    echo "    refuse-any: yes"
    echo "    verbosity: 1"
    echo "    round-robin: no"
    echo "remote-control:"
    echo "    control-enable: no"
    echo 'include: "/etc/nsd/minipainel-zones.conf"'
  } > /etc/nsd/nsd.conf
  chmod 644 /etc/nsd/nsd.conf
  touch /etc/nsd/minipainel-zones.conf
  local z; while IFS= read -r z; do [ -n "$z" ] || continue; dns_write_zone "$z" || warn "Zona $z com erros."; done < <(dns_zones)
  dns_apply || die "Não foi possível ativar o NSD."
  systemctl enable --now nsd >/dev/null 2>&1; systemctl restart nsd >/dev/null 2>&1
  fw_open 53 >/dev/null 2>&1
  if systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd -q --permanent --add-service=dns; firewall-cmd -q --add-service=dns
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then ufw allow 53 >/dev/null 2>&1; fi
  echo "DNS ativo: $ns1 e $ns2 → $ip."
  echo "No registador do domínio de $ns1 cria os registos de cola (glue): $ns1 e $ns2 com o IP $ip."
  return 0
}
dns_valid_rec(){ # nome tipo valor prioridade
  local n=$1 t=$2 v=$3 re_n='^(@|\*|(\*\.)?[a-z0-9_]([a-z0-9_-]{0,62})(\.[a-z0-9_]([a-z0-9_-]{0,62}))*)$'
  [[ "$n" =~ $re_n ]] || { echo "Nome inválido: $n (usa @ para o domínio, ou o nome sem o domínio, ex.: www)"; return 1; }
  [ ${#v} -le 2000 ] && [[ "$v" != *[$'\n\r']* ]] || { echo "Valor inválido."; return 1; }
  case "$t" in
    A) [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "IPv4 inválido."; return 1; } ;;
    AAAA) [[ "$v" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$v" == *:* ]] || { echo "IPv6 inválido."; return 1; } ;;
    CNAME|NS|MX) [[ "$v" =~ ^([a-z0-9_]([a-z0-9_-]{0,62})\.)*[a-z0-9_]([a-z0-9_-]{0,62})\.?$ ]] || { echo "Destino inválido: $v"; return 1; } ;;
    TXT) [ -n "$v" ] || { echo "O texto não pode ficar vazio."; return 1; } ;;
    SRV) [[ "$v" =~ ^[0-9]{1,5}\ [0-9]{1,5}\ [a-z0-9._-]+\.?$ ]] || { echo "SRV: usa 'peso porta destino' (ex.: 5 5060 sip.dominio.pt)."; return 1; } ;;
    CAA) [[ "$v" =~ ^[0-9]{1,3}\ (issue|issuewild|iodef)\ \"[^\"]*\"$ ]] || { echo "CAA: usa ex. 0 issue \"letsencrypt.org\""; return 1; } ;;
    *) echo "Tipo não suportado: $t (A, AAAA, CNAME, MX, TXT, NS, SRV, CAA)"; return 1 ;;
  esac
  [ "$t" = CNAME ] && [ "$n" = "@" ] && { echo "Não é possível um CNAME no próprio domínio (@)."; return 1; }
  return 0
}
cmd_dns_zone_add(){
  local z="${1:-}"; dns_need; z=$(printf '%s' "$z" | tr 'A-Z' 'a-z')
  valid_domain "$z" || die "Domínio inválido: $z"
  [ -f "$(dns_zone_json "$z")" ] && die "A zona $z já existe."
  dns_save "$z" '{"serial":0,"records":[]}'
  dns_sync_zone "$z" || { rm -f "$(dns_zone_json "$z")"; die "Não foi possível criar a zona."; }
  echo "Zona $z criada com os registos automáticos (sites, email e nameservers). No registador, aponta os nameservers para $(dns_get NS1) e $(dns_get NS2)."
  return 0
}
cmd_dns_zone_del(){
  local z="${1:-}"; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  rm -f "$(dns_zone_json "$z")" "$NSD_ZONES/$z.zone"; dns_apply
  echo "Zona $z apagada."; return 0
}
cmd_dns_rec_add(){ # zona nome tipo valor [--ttl N] [--prio N]
  local z="${1:-}" n="${2:-}" t="${3:-}" v="${4:-}" ttl=0 pr=10 j why
  dns_need; [ $# -ge 4 ] && shift 4
  while [ $# -gt 0 ]; do case "$1" in --ttl) ttl="${2:-}"; shift 2 || shift ;; --prio) pr="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  n=$(printf '%s' "$n" | tr 'A-Z' 'a-z'); n=${n%."$z"}; n=${n%.}; [ "$n" = "$z" ] && n="@"; [ -n "$n" ] || n="@"
  t=$(printf '%s' "$t" | tr 'a-z' 'A-Z')
  dns_ttl_ok "$ttl" || die "TTL inválido (Auto ou 60 segundos ou mais)."; [[ "$pr" =~ ^[0-9]{1,5}$ ]] || die "Prioridade inválida."
  why=$(dns_valid_rec "$n" "$t" "$v") || die "$why"
  j=$(dns_load "$z" | jq --arg n "$n" --arg t "$t" --arg v "$v" --argjson ttl "$ttl" --argjson p "$pr" --arg id "$(openssl rand -hex 6)" \
      '.records += [{id:$id, name:$n, type:$t, value:$v, ttl:$ttl, prio:$p, auto:false}]')
  dns_bump "$z" "$j" || die "Registo recusado pelo verificador de zonas; nada foi alterado."
  echo "Registo $n $t $v acrescentado a $z."; return 0
}
cmd_dns_rec_del(){
  local z="${1:-}" id="${2:-}" j; dns_need
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  [[ "$id" =~ ^[A-Za-z0-9]{3,16}$ ]] || die "Identificador inválido."
  [ "$(dns_load "$z" | jq --arg id "$id" '[.records[] | select(.id == $id)] | length')" = 1 ] || die "Registo não encontrado."
  j=$(dns_load "$z" | jq --arg id "$id" '(.records[] | select(.id == $id)) as $o | .off = ((.off // []) + (if $o.auto == true then [$o.name + "|" + $o.type] else [] end) | unique) | .records |= map(select(.id != $id))')
  dns_bump "$z" "$j" || die "Não foi possível atualizar a zona."
  echo "Registo apagado de $z."; return 0
}
cmd_dns_sync(){ local z="${1:-all}"; dns_need
  if [ "$z" = all ]; then dns_autosync; echo "Zonas sincronizadas."; return 0; fi
  [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  dns_sync_zone "$z" || die "Falhou."; echo "Zona $z sincronizada com os sites e o email."; return 0; }
cmd_dns_check(){ # a delegação no registador já aponta para este servidor?
  local z="${1:-}" got ours r f=$DATA/stats/dns-check.json
  dns_need; [ -f "$(dns_zone_json "$z")" ] || die "A zona $z não existe."
  got=$(dig +short NS "$z" @8.8.8.8 2>/dev/null | sed 's/\.$//' | sort | tr '\n' ' ')
  ours=$(dns_ns_list | sort -u | tr '\n' ' ')
  r=$(dig +short SOA "$z" @"$(dns_get IP)" 2>/dev/null | awk '{print $3}')
  [ -s "$f" ] || echo '{}' > "$f"
  jq --arg z "$z" --arg g "$got" --argjson ok "$([ "$got" = "$ours" ] && echo true || echo false)" --arg r "$r" --arg t "$EPOCHSECONDS" \
    '.[$z] = {checked:($t|tonumber), delegated:$ok, found:$g, serial_public:$r}' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"
  if [ "$got" = "$ours" ]; then echo "Delegação de $z correta: os nameservers apontam para este servidor."
  else echo "A delegação de $z ainda não aponta para este servidor (encontrado: ${got:-nada}). Altera os nameservers no registador para: $(dns_ns_list | tr '\n' ' ')"; fi
  return 0
}
dns_state_json(){
  dns_on || { echo '{"enabled":false}'; return 0; }
  local z zs="[]" chk; chk=$(cat "$DATA/stats/dns-check.json" 2>/dev/null || echo '{}'); jq -e . >/dev/null 2>&1 <<<"$chk" || chk='{}'
  while IFS= read -r z; do [ -n "$z" ] || continue; zs=$(jq -c --arg z "$z" --argjson d "$(dns_load "$z")" --argjson c "$chk" '. + [{name:$z, serial:$d.serial, records:$d.records, off:($d.off // []), check:($c[$z] // null)}]' <<<"$zs"); done < <(dns_zones)
  jq -n --arg ns1 "$(dns_get NS1)" --arg ns2 "$(dns_get NS2)" --arg ip "$(dns_get IP)" --arg ip6 "$(dns_get IP6)" --argjson zs "$zs" \
    --arg act "$(systemctl is-active nsd 2>/dev/null)" --arg hm "$(dns_get HOSTMASTER '')" \
    --arg st "$(dns_get DEF_TTL 3600) $(dns_get SOA_REFRESH 10800) $(dns_get SOA_RETRY 3600) $(dns_get SOA_EXPIRE 1209600) $(dns_get SOA_MIN 3600)" \
    --argjson nsl "$(dns_ns_list | jq -R . | jq -sc 'map(select(length > 0))')" \
    --arg sp "$(dns_get SEC_PROVIDER '')" --arg si "$(dns_get SEC_IPS '')" --arg sn "$(dns_get SEC_NS '')" --arg st2 "$(dns_get SEC_TSIG 1)" \
    --arg sk "$(dns_get SEC_KEYNAME '')" --arg ss "$(dns_get SEC_KEY '')" --arg s2 "$(dns_get SEC_KEEP_NS2 0)" \
    '{enabled:true, ns1:$ns1, ns2:$ns2, ip:$ip, ip6:$ip6, hostmaster:$hm, active:($act == "active"), zones:$zs, ns_list:$nsl,
      sec:(if $si == "" then null else {provider:$sp, ips:($si | split(" ")), ns:($sn | split(" ")), tsig:($st2 == "1"), keyname:$sk, key:$ss, keep_ns2:($s2 == "1")} end),
      soa:($st | split(" ") | {ttl:(.[0]|tonumber), refresh:(.[1]|tonumber), retry:(.[2]|tonumber), expire:(.[3]|tonumber), minimum:(.[4]|tonumber)})}'
}
