cmd_server_mode(){
  local m="${1:-}" em=""
  [ $# -gt 0 ] && shift
  case "$m" in lan|internet) ;; *) die "Usa: mpanel server-mode lan|internet [--email endereço]" ;; esac
  while [ $# -gt 0 ]; do case "$1" in --email) em="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  local re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  if [ -n "$em" ]; then [ "$em" = none ] && em="" || [[ "$em" =~ $re ]] || die "Email inválido: $em"; srv_set EMAIL "$em"; fi
  srv_set MODE "$m"
  [ "$m" = internet ] && ports_web_open
  echo "Modo do servidor: $([ "$m" = lan ] && echo 'LAN (sites por porta)' || echo 'Internet (sites com domínio e SSL)')."
  return 0
}
cmd_site_domains(){
  local n="${1:-}" doms ssl https www d o old_doms old_ssl old_https old_www f bak msg=""
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  old_doms=$(site_get "$n" DOMAINS); old_ssl=$(site_get "$n" SSL); old_https=$(site_get "$n" HTTPS); old_www=$(site_get "$n" WWW)
  doms=$old_doms; ssl=${old_ssl:-none}; https=${old_https:-1}; www=${old_www:-keep}
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) doms="${2:-}"; shift 2 || shift ;;
      --ssl) ssl="${2:-}"; shift 2 || shift ;;
      --https) https="${2:-}"; shift 2 || shift ;;
      --www) www="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  doms=$(printf '%s' "$doms" | tr 'A-Z,;' 'a-z  ' | tr -s ' \n\t' ' ' | sed 's/^ //; s/ $//')
  case "$ssl" in none|le|self) ;; *) die "SSL inválido: usa none, le ou self." ;; esac
  case "$https" in 0|1) ;; *) die "--https tem de ser 0 ou 1." ;; esac
  case "$www" in keep|www|root) ;; *) die "--www tem de ser keep, www ou root." ;; esac
  local cnt=0 seen=" "
  for d in $doms; do
    valid_domain "$d" || die "Domínio inválido: $d"
    [[ "$seen" == *" $d "* ]] && die "Domínio repetido: $d"; seen+="$d "
    o=$(domain_owner "$d") && [ "$o" != "$n" ] && die "O domínio $d já está em uso ($o)."
    cnt=$((cnt + 1))
  done
  [ "$cnt" -le 30 ] || die "Máximo de 30 domínios por site."
  [ -z "$doms" ] && ssl=none
  f=$(site_conf "$n"); bak="$f.bak"; cp -p "$f" "$bak"
  site_set "$n" DOMAINS "$doms"; site_set "$n" SSL "$ssl"; site_set "$n" HTTPS "$https"; site_set "$n" WWW "$www"
  # 1) configuração sem o certificado novo (permite a validação HTTP do Let's Encrypt)
  write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"
  ngx_default_sync
  if ! apply_nginx; then
    mv -f "$bak" "$f"; write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"; ngx_default_sync; apply_nginx >/dev/null 2>&1
    die "Configuração do nginx inválida; nada foi alterado."
  fi
  rm -f "$bak"
  [ -n "$doms" ] && ports_web_open
  # 2) certificado
  if [ "$ssl" = le ]; then
    local errf; errf=$(mktemp)
    # shellcheck disable=SC2086
    if le_issue "mp-$n" $doms 2>"$errf"; then msg="Certificado Let's Encrypt emitido."
    else msg="Os domínios ficaram ativos em HTTP, mas o certificado não foi emitido.
$(cat "$errf")
Confirma que os domínios apontam para este servidor e que as portas 80 e 443 estão acessíveis da Internet."; fi
    rm -f "$errf"
  elif [ "$ssl" = self ]; then
    # shellcheck disable=SC2086
    self_issue "mp-$n" $doms && msg="Certificado autoassinado criado (o browser vai mostrar um aviso)."
  else
    [ -z "$doms" ] && le_delete "mp-$n"
  fi
  # 3) configuração final com HTTPS
  write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  dns_autosync
  if [ -z "$doms" ]; then echo "Site $n sem domínios (só por porta)."; else echo "Domínios de $n: $doms."; fi
  [ -n "$msg" ] && echo "$msg"
  return 0
}
cmd_panel_domain(){
  local d="${1:-}" ssl=le msg=""
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--ssl" ] && ssl="${2:-le}"
  case "$ssl" in le|self) ;; *) die "--ssl tem de ser le ou self." ;; esac
  if [ "$d" = none ] || [ -z "$d" ]; then
    srv_set PANEL_DOMAIN ""; panel_domain_write; ngx_default_sync; apply_nginx || warn "Verifica o nginx."
    le_delete mp-painel; echo "O painel deixou de ter domínio próprio (continua na porta $PANEL_PORT)."; return 0
  fi
  d=$(printf '%s' "$d" | tr 'A-Z' 'a-z')
  valid_domain "$d" || die "Domínio inválido: $d"
  local o; o=$(domain_owner "$d") && [ "$o" != painel ] && die "O domínio $d já está em uso pelo site $o."
  srv_set PANEL_DOMAIN "$d"; srv_set PANEL_SSL "$ssl"
  panel_domain_write; ngx_default_sync
  apply_nginx || { srv_set PANEL_DOMAIN ""; panel_domain_write; ngx_default_sync; apply_nginx >/dev/null 2>&1; die "Configuração do nginx inválida; nada foi alterado."; }
  ports_web_open
  if [ "$ssl" = le ]; then
    local errf; errf=$(mktemp)
    if le_issue mp-painel "$d" 2>"$errf"; then msg="Certificado Let's Encrypt emitido."
    else msg="O painel ficou em https://$d com um certificado autoassinado, porque o Let's Encrypt falhou:
$(cat "$errf")"; fi
    rm -f "$errf"
  else
    self_issue mp-painel "$d"; msg="Certificado autoassinado criado."
  fi
  panel_domain_write; apply_nginx || warn "Verifica o nginx."
  echo "Painel disponível em https://$d (e continua em https://IP:$PANEL_PORT)."
  echo "$msg"
  return 0
}
cmd_ssl_renew(){ command -v certbot >/dev/null 2>&1 || die "O certbot não está instalado."; certbot renew --non-interactive --deploy-hook "systemctl reload nginx" 2>&1 | grep -E 'renew|success|fail|skip|No renewals' | tail -n 6; return 0; }

cmd_ngx_sync(){ # regenera a configuração nginx de todos os sites, do servidor por omissão e do domínio do painel
  local n
  install -d -m 755 "$NGX_INC" "$NGX_CONFD" "$ACME_ROOT"
  panel_allow_write; ports_allow_write
  for n in $(site_names); do logs_migrate_site "$n"; write_nginx "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" "$(ngx_file "$n")"; done
  logs_rotate_conf
  ngx_default_sync; panel_domain_write
  apply_nginx || die "Configuração do nginx inválida depois de regenerar (nginx -t)."
  echo "Configuração nginx regenerada."
  return 0
}

# ---------- segurança do painel e das portas dos sites ----------
PANEL_ALLOW_INC=/etc/nginx/minipainel/panel-allow.inc
PORTS_ALLOW_INC=/etc/nginx/minipainel/ports-allow.inc
audit_cli(){ # regista ações feitas diretamente na consola
  [ -t 0 ] || return 0
  logger -t minipainel-audit -p authpriv.notice "consola root: $1" 2>/dev/null
  jq -cn --arg t "$EPOCHSECONDS" --arg a "$1" '{ts:($t|tonumber), ip:"consola", user:"root", action:$a, ok:true}' >> "$DATA/logs/audit.log" 2>/dev/null
  chown "$PANEL_SYSUSER:$PANEL_SYSUSER" "$DATA/logs/audit.log" 2>/dev/null; return 0
}
auth_update(){ # filtro jq aplicado ao auth.json
  local base='{}'; [ -s "$AUTH" ] && base=$(cat "$AUTH")
  jq "$@" <<<"$base" > "$AUTH.tmp" || { rm -f "$AUTH.tmp"; return 1; }
  chown root:"$PANEL_SYSUSER" "$AUTH.tmp"; chmod 640 "$AUTH.tmp"; mv -f "$AUTH.tmp" "$AUTH"
}
panel_allow_write(){
  local l ip; l=$(srv_get PANEL_ALLOW '')
  {
    echo "# IDDigital Hosting — IPs autorizados a abrir o painel (gerado pelo painel)"
    if [ -n "$l" ]; then
      printf '    allow 127.0.0.1;\n    allow ::1;\n'
      for ip in $l; do printf '    allow %s;\n' "$ip"; done
      printf '    deny all;\n'
    fi
  } > "$PANEL_ALLOW_INC"
  chmod 644 "$PANEL_ALLOW_INC"
}
ports_allow_write(){
  local ip
  {
    echo "# IDDigital Hosting — acesso pelas portas dos sites (gerado pelo painel)"
    if [ "$(srv_get PORTS_ACCESS all)" = lan ]; then
      for ip in 127.0.0.0/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10; do printf '    allow %s;\n' "$ip"; done
      if [ -f "$FW_ALLOW" ]; then grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}' | while read -r ip; do fw_ip_valid "$ip" && printf '    allow %s;\n' "$ip"; done; fi
      printf '    deny all;\n'
    fi
  } > "$PORTS_ALLOW_INC"
  chmod 644 "$PORTS_ALLOW_INC"
}
cmd_panel_allow(){
  local l="$*" ip
  [ "$l" = none ] && l=""
  l=$(printf '%s' "$l" | tr ',;\n' '   ' | xargs)
  for ip in $l; do fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"; done
  srv_set PANEL_ALLOW "$l"; panel_allow_write
  apply_nginx || { srv_set PANEL_ALLOW ""; panel_allow_write; apply_nginx >/dev/null 2>&1; die "Configuração do nginx inválida; o painel continua aberto a todos."; }
  audit_cli "IPs autorizados no painel: ${l:-todos}"
  if [ -n "$l" ]; then echo "O painel só abre a partir de: $l (e do próprio servidor). Para anular na consola: mpanel panel-allow none"
  else echo "O painel abre a partir de qualquer IP."; fi
  return 0
}
cmd_ports_access(){
  local m="${1:-}"
  case "$m" in all|lan) ;; *) die "Usa: mpanel ports-access all|lan" ;; esac
  srv_set PORTS_ACCESS "$m"; ports_allow_write
  apply_nginx || die "Configuração do nginx inválida (nginx -t)."
  if [ "$m" = lan ]; then echo "As portas dos sites só respondem à rede local e aos IPs de confiança. Os domínios (80/443) continuam públicos."
  else echo "As portas dos sites respondem a qualquer IP."; fi
  return 0
}
cmd_panel_user(){
  local u="${1:-}" re='^[a-z][a-z0-9._-]{2,31}$'
  [[ "$u" =~ $re ]] || die "Nome inválido: 3 a 32 caracteres (minúsculas, números, '.', '_' e '-'), a começar por letra."
  auth_update --arg u "$u" '.user = $u' || die "Falha ao gravar."
  sed -i "s/^PANEL_USER=.*/PANEL_USER=$u/" "$CONF"
  audit_cli "Utilizador do painel alterado para $u"
  echo "O utilizador do painel passa a ser '$u'. Usa-o no próximo início de sessão."
  return 0
}
cmd_panel_2fa(){
  local a="${1:-}" sec="${2:-}" re='^[A-Z2-7]{16,64}$' codes="" hashes="[]" c i
  case "$a" in
    set)
      [[ "$sec" =~ $re ]] || die "Segredo inválido."
      for i in 1 2 3 4 5 6 7 8; do
        c="$(openssl rand -hex 3)-$(openssl rand -hex 3)"; codes+="$c "
        hashes=$(jq -c --arg h "$(printf '%s' "$c" | sha256sum | awk '{print $1}')" '. + [$h]' <<<"$hashes")
      done
      auth_update --arg s "$sec" --argjson r "$hashes" '.totp = $s | .recovery = $r' || die "Falha ao gravar."
      rm -f "$DATA/logs/2fa-used.json"
      audit_cli "Verificação em dois passos ativada"
      echo "Verificação em dois passos ativada."
      echo "Códigos de recuperação (guarda-os em local seguro; cada um só funciona uma vez):"
      for c in $codes; do echo "  $c"; done
      ;;
    off)
      auth_update 'del(.totp, .recovery)' || die "Falha ao gravar."
      rm -f "$DATA/logs/2fa-used.json"
      audit_cli "Verificação em dois passos desativada"
      echo "Verificação em dois passos desativada."
      ;;
    *) die "Usa: mpanel panel-2fa off (para desativar na consola)" ;;
  esac
  return 0
}

# ---------- cifra das cópias remotas dos backups ----------
bk_enc_pass(){ # ficheiro temporário com a frase de cifra (derivada da chave dos backups)
  local f; f=$(mktemp /run/mp-bkenc.XXXXXX); chmod 600 "$f"
  bk_key_ensure
  printf 'enc:%s' "$(tr -d '[:space:]' < "$BK_KEY")" | sha256sum | awk '{print $1}' > "$f"
  echo "$f"
}
bk_encrypt_dir(){ # origem destino
  local src=$1 dst=$2 pf rel
  pf=$(bk_enc_pass)
  while IFS= read -r rel; do
    mkdir -p "$dst/$(dirname "$rel")"
    case "$rel" in
      manifest.json|manifest.sig) cp -p "$src/$rel" "$dst/$rel" ;;
      *) openssl enc -aes-256-ctr -pbkdf2 -iter 100000 -salt -pass "file:$pf" -in "$src/$rel" -out "$dst/$rel.enc" || { rm -f "$pf"; return 1; } ;;
    esac
  done < <(cd "$src" && find . -type f -printf '%P\n')
  : > "$dst/ENCRYPTED"
  rm -f "$pf"
}
bk_decrypt_dir(){ # pasta (decifra no lugar)
  local dir=$1 pf f
  [ -f "$dir/ENCRYPTED" ] || return 0
  pf=$(bk_enc_pass)
  while IFS= read -r f; do
    openssl enc -d -aes-256-ctr -pbkdf2 -iter 100000 -pass "file:$pf" -in "$f" -out "${f%.enc}" 2>/dev/null || { rm -f "$pf"; return 1; }
    rm -f "$f"
  done < <(find "$dir" -type f -name '*.enc')
  rm -f "$pf" "$dir/ENCRYPTED"
}

