# ============================ ATUALIZAÇÕES ===================================
UPD_CONF=/etc/minipainel/update.conf          # URL=, KEY (chave pública em update.pub)
UPD_PUB=/etc/minipainel/update.pub
UPD_DIR=/var/lib/minipainel/update
UPD_SNAP=/var/backups/minipainel/_atualizacoes
UPD_STATE=$DATA/stats/update.json
OSU_STATE=$DATA/stats/os-updates.json
UPD_RUN=$DATA/stats/update-run.json
upd_url(){ local v; v=$(grep -m1 '^URL=' "$UPD_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-https://raw.githubusercontent.com/naoavr/painel-alojamento-nao/main}"; }
UPD_TOKEN=/etc/minipainel/update.token
upd_get(){ # url ficheiro [segundos] -> código HTTP (token do GitHub lido de um descritor, nunca na linha de comandos)
  local u=$1 out=$2 t=${3:-60} tok=""
  [ -s "$UPD_TOKEN" ] && tok=$(cat "$UPD_TOKEN")
  if [ -n "$tok" ] && [[ "$u" == https://raw.githubusercontent.com/* || "$u" == https://api.github.com/* ]]; then
    curl -sSL -m "$t" -o "$out" -w '%{http_code}' -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") "$u" 2>/dev/null
  else
    curl -sSL -m "$t" -o "$out" -w '%{http_code}' "$u" 2>/dev/null
  fi
}
upd_err(){ # código -> explicação
  case "$1" in
    401|403) echo "o GitHub recusou o acesso (token inválido, expirado ou sem permissão de leitura do conteúdo)" ;;
    404) if [ -s "$UPD_TOKEN" ]; then echo "ficheiro não encontrado (o token tem acesso a este repositório?)"; else echo "ficheiro não encontrado (se o repositório for privado, configura o token do GitHub em Atualizações)"; fi ;;
    000) echo "sem ligação ao GitHub" ;;
    *) echo "erro HTTP $1" ;;
  esac
}
cmd_update_token(){ # set <token> | clear
  case "${1:-}" in
    set) local t="${2:-}"; [[ "$t" =~ ^(github_pat_[A-Za-z0-9_]{20,255}|gh[pousr]_[A-Za-z0-9]{20,255})$ ]] || die "Token inválido (começa por github_pat_ ou ghp_)."
         ( umask 077; printf '%s\n' "$t" > "$UPD_TOKEN" ); chmod 600 "$UPD_TOKEN"
         local tmp c; tmp=$(mktemp); c=$(upd_get "$(upd_url)/install.sh" "$tmp" 30); rm -f "$tmp"
         if [ "$c" = 200 ]; then echo "Token guardado: o repositório está acessível."; else echo "Token guardado, mas o teste falhou: $(upd_err "$c")."; fi ;;
    clear) rm -f "$UPD_TOKEN"; echo "Token do GitHub removido." ;;
    *) die "Usa: mpanel update-token set <token> | clear" ;;
  esac
  return 0
}
upd_status(){ # passo em curso (texto) ou vazio para terminar
  if [ -n "${1:-}" ]; then jq -n --arg s "$1" --arg k "${2:-painel}" --arg t "$EPOCHSECONDS" '{step:$s, kind:$k, since:($t|tonumber)}' > "$UPD_RUN.tmp" && chown root:"$PANEL_SYSUSER" "$UPD_RUN.tmp" && chmod 640 "$UPD_RUN.tmp" && mv -f "$UPD_RUN.tmp" "$UPD_RUN"
  else rm -f "$UPD_RUN"; fi
}
upd_save(){ # ficheiro json
  printf '%s\n' "$2" > "$1.tmp" && chown root:"$PANEL_SYSUSER" "$1.tmp" && chmod 640 "$1.tmp" && mv -f "$1.tmp" "$1"
}
upd_newer(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }   # $2 é mais recente que $1
upd_verify(){ # pasta -> 0 assinatura válida; 2 sem chave configurada; 1 falha
  local d=$1 sum
  sum=$(sha256sum "$d/install.sh" | awk '{print $1}')
  if [ -s "$d/version.json" ]; then [ "$sum" = "$(jq -r '.sha256 // ""' "$d/version.json" 2>/dev/null)" ] || return 1; fi
  [ -s "$UPD_PUB" ] || return 2
  [ -s "$d/install.sh.sig" ] || return 1
  base64 -d "$d/install.sh.sig" > "$d/sig.bin" 2>/dev/null || return 1
  openssl pkeyutl -verify -pubin -inkey "$UPD_PUB" -rawin -in "$d/install.sh" -sigfile "$d/sig.bin" >/dev/null 2>&1 || return 1
  return 0
}
cmd_update_check(){
  local u j="" latest notes signed=false tmp c sum="" src=version.json
  u=$(upd_url); tmp=$(mktemp)
  c=$(upd_get "$u/version.json" "$tmp" 20)
  if [ "$c" = 200 ] && jq -e '.version' "$tmp" >/dev/null 2>&1; then j=$(cat "$tmp")
  else
    # sem version.json: lê a versão do próprio instalador
    c=$(upd_get "$u/install.sh" "$tmp" 120)
    if [ "$c" = 200 ] && latest=$(grep -m1 -oE '^MP_VERSION="[0-9]+(\.[0-9]+)+"' "$tmp" | cut -d'"' -f2) && [ -n "$latest" ]; then
      sum=$(sha256sum "$tmp" | awk '{print $1}'); src=install.sh
      j=$(jq -n --arg v "$latest" --arg s "$sum" --arg n "$(grep -m1 -E '^# NOTAS:' "$tmp" | sed 's/^# NOTAS:[[:space:]]*//')" '{version:$v, sha256:$s, notes:$n, date:""}')
    fi
  fi
  rm -f "$tmp"
  if [ -z "$j" ]; then
    upd_save "$UPD_STATE" "$(jq -n --arg c "$MP_VERSION" --arg t "$EPOCHSECONDS" --arg e "Não foi possível obter a versão publicada em $u: $(upd_err "$c")." --argjson k "$([ -s "$UPD_PUB" ] && echo true || echo false)" --argjson tk "$([ -s "$UPD_TOKEN" ] && echo true || echo false)" \
      '{current:$c, latest:null, checked:($t|tonumber), error:$e, key:$k, token:$tk}')"
    die "Não foi possível obter a versão publicada em $u: $(upd_err "$c")."
  fi
  latest=$(jq -r '.version' <<<"$j"); notes=$(jq -r '.notes // ""' <<<"$j"); sum=$(jq -r '.sha256 // ""' <<<"$j")
  [ -s "$UPD_PUB" ] && signed=true
  upd_save "$UPD_STATE" "$(jq -n --arg c "$MP_VERSION" --arg l "$latest" --arg n "$notes" --arg d "$(jq -r '.date // ""' <<<"$j")" --arg t "$EPOCHSECONDS" --argjson k "$signed" \
     --argjson tk "$([ -s "$UPD_TOKEN" ] && echo true || echo false)" --arg sh "$sum" --arg src "$src" \
     --argjson nw "$(upd_newer "$MP_VERSION" "$latest" && echo true || echo false)" \
     '{current:$c, latest:$l, notes:$n, date:$d, checked:($t|tonumber), newer:$nw, key:$k, token:$tk, sha256:$sh, source:$src, error:null}')"
  if upd_newer "$MP_VERSION" "$latest"; then echo "Há uma versão nova: $latest (instalada: $MP_VERSION)."; else echo "O painel está atualizado ($MP_VERSION)."; fi
  return 0
}
upd_snapshot(){ # cópia do painel antes de atualizar -> imprime o caminho
  local ts f
  ts=$(date '+%Y%m%d-%H%M%S'); install -d -m 700 "$UPD_SNAP"; f="$UPD_SNAP/$ts-v$MP_VERSION.tar.gz"
  local items=(etc/minipainel opt/minipainel usr/local/sbin/mpanel usr/local/sbin/mpanel-stats usr/local/sbin/mpanel-cron usr/local/sbin/mp-sendmail
    etc/nginx/minipainel etc/nginx/nginx.conf) x
  for x in /etc/php/*/fpm/pool.d /etc/opt/remi/*/php-fpm.d /etc/php-fpm.d /etc/systemd/system/minipainel-*; do [ -e "$x" ] && items+=("${x#/}"); done
  tar -C / -czf "$f" --ignore-failed-read "${items[@]}" 2>/dev/null
  chmod 600 "$f"; echo "$f"
}
upd_restore(){ # ficheiro (a conta de acesso e o 2FA nunca são repostos a partir de uma cópia)
  tar -C / -xzpf "$1" --exclude=var/lib/minipainel/auth.json --exclude=etc/minipainel/update.pub || return 1
  systemctl daemon-reload >/dev/null 2>&1
  local v; for v in $(php_installed); do systemctl restart "$(php_service "$v")" >/dev/null 2>&1; done
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  systemctl restart minipainel-stats.service minipainel-worker.path >/dev/null 2>&1
  return 0
}
upd_health(){ # o painel responde depois da atualização?
  local c i
  nginx -t >/dev/null 2>&1 || return 1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    c=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "https://127.0.0.1:$PANEL_PORT/" 2>/dev/null)
    [ "$c" = 200 ] && return 0; sleep 2
  done
  return 1
}
upd_finish(){ # ok msg
  local f=$DATA/stats/update-last.json
  upd_save "$f" "$(jq -n --arg t "$EPOCHSECONDS" --argjson ok "$1" --arg m "$2" '{ts:($t|tonumber), ok:$ok, msg:$m}')"
  jq -cn --arg t "$EPOCHSECONDS" --arg a "$2" --argjson ok "$1" '{ts:($t|tonumber), ip:"servidor", user:"atualização", action:$a, ok:$ok}' >> "$DATA/logs/audit.log" 2>/dev/null
  upd_status ""
}
# Corre noutra unidade do systemd: o instalador reinicia serviços do painel e não pode matar este processo.
# Corre a partir de uma cópia: o instalador substitui o próprio mpanel durante a atualização.
upd_spawn(){ # comando...
  local cp=/run/minipainel-upd.sh
  install -m 700 /usr/local/sbin/mpanel "$cp"
  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemd-run --quiet --collect --unit="minipainel-upd-$EPOCHSECONDS" /bin/bash "$cp" "$@" >/dev/null 2>&1
  else
    setsid /bin/bash "$cp" "$@" >/dev/null 2>&1 < /dev/null 9>&- &
  fi
}
cmd_update_start(){ [ -f "$UPD_RUN" ] && die "Já está a decorrer uma atualização."; upd_status "A preparar" painel; upd_spawn update-run "$@"; echo "Atualização iniciada. O progresso aparece na página Atualizações."; return 0; }
cmd_update_run(){
  local u d v rc snap log allow_unsigned=0
  [ "${1:-}" = "--allow-unsigned" ] && allow_unsigned=1
  exec 6>/run/minipainel-update.lock; flock -n 6 || die "Já está a decorrer uma atualização."
  u=$(upd_url); d="$UPD_DIR/novo"; rm -rf "$d"; install -d -m 700 "$d"
  upd_status "A descarregar a versão nova" painel
  local c; c=$(upd_get "$u/install.sh" "$d/install.sh" 300)
  [ "$c" = 200 ] || { rm -f "$d/install.sh"; upd_finish false "Atualização falhou: não foi possível descarregar o instalador de $u ($(upd_err "$c"))."; die "Falhou o download."; }
  [ "$(upd_get "$u/version.json" "$d/version.json" 60)" = 200 ] && jq -e . "$d/version.json" >/dev/null 2>&1 || rm -f "$d/version.json"
  [ "$(upd_get "$u/install.sh.sig" "$d/install.sh.sig" 60)" = 200 ] || rm -f "$d/install.sh.sig"
  v=$(jq -r '.version // ""' "$d/version.json" 2>/dev/null); [ -n "$v" ] || v=$(grep -m1 -oE '^MP_VERSION="[0-9]+(\.[0-9]+)+"' "$d/install.sh" | cut -d'"' -f2)
  [ -n "$v" ] || { upd_finish false "Atualização recusada: o ficheiro descarregado não parece ser o instalador do painel."; die "Instalador inválido."; }
  upd_status "A verificar a assinatura" painel
  upd_verify "$d"; rc=$?
  if [ "$rc" = 1 ]; then upd_finish false "Atualização para $v recusada: o ficheiro não corresponde ao version.json ou a assinatura é inválida."; die "Verificação falhou."; fi
  if [ "$rc" = 2 ] && [ "$allow_unsigned" = 0 ]; then upd_finish false "Atualização para $v recusada: não está configurada a chave pública das atualizações (ou confirma a instalação sem assinatura)."; die "Sem chave de assinatura."; fi
  bash -n "$d/install.sh" || { upd_finish false "Atualização para $v recusada: o instalador tem erros de sintaxe."; die "Instalador inválido."; }
  upd_status "A guardar uma cópia da versão atual ($MP_VERSION)" painel
  snap=$(upd_snapshot)
  upd_status "A instalar a versão $v" painel
  log="$UPD_DIR/instalacao-$v-$(date +%Y%m%d-%H%M%S).log"
  if bash "$d/install.sh" --panel-port "$PANEL_PORT" > "$log" 2>&1 && upd_health; then
    cp "$d/install.sh" "$UPD_DIR/install-$v.sh"
    upd_finish true "Painel atualizado de $MP_VERSION para $v."
    /usr/local/sbin/mpanel update-check >/dev/null 2>&1
    return 0
  fi
  upd_status "A instalação falhou; a repor a versão $MP_VERSION" painel
  upd_restore "$snap"
  if upd_health; then upd_finish false "A atualização para $v falhou e foi reposta a versão $MP_VERSION. Registo: $log"
  else upd_finish false "A atualização para $v falhou e a reposição automática não pôs o painel a responder. Na consola: tar -C / -xzpf $snap ; registo: $log"; fi
  return 1
}
cmd_update_rollback(){
  local f="${1:-}"
  [ -n "$f" ] || f=$(ls -1t "$UPD_SNAP"/*.tar.gz 2>/dev/null | head -1)
  case "$f" in "$UPD_SNAP"/*.tar.gz) ;; *) f="$UPD_SNAP/$f" ;; esac
  [ -f "$f" ] && [[ "$(basename "$f")" =~ ^[0-9]{8}-[0-9]{6}-v[0-9.]+\.tar\.gz$ ]] || die "Cópia não encontrada: $1"
  upd_restore "$f" || die "Falhou a reposição."
  jq -cn --arg t "$EPOCHSECONDS" --arg a "Reposta a cópia $(basename "$f")" '{ts:($t|tonumber), ip:"servidor", user:"atualização", action:$a, ok:true}' >> "$DATA/logs/audit.log"
  echo "Reposta a cópia $(basename "$f"). Atualiza a página do painel."
  return 0
}
cmd_update_key(){ # set <PEM em base64 numa linha> | clear
  case "${1:-}" in
    set) local pem tmp; tmp=$(mktemp); printf '%s' "${2:-}" | sed 's/\\n/\n/g' > "$tmp"
      grep -q 'BEGIN PUBLIC KEY' "$tmp" && openssl pkey -pubin -in "$tmp" -noout >/dev/null 2>&1 || { rm -f "$tmp"; die "Chave pública inválida (formato PEM, Ed25519)."; }
      [ "$(openssl pkey -pubin -in "$tmp" -noout -text 2>/dev/null | head -1 | grep -ci ed25519)" = 1 ] || { rm -f "$tmp"; die "A chave tem de ser Ed25519."; }
      install -m 644 "$tmp" "$UPD_PUB"; rm -f "$tmp"; echo "Chave pública das atualizações guardada." ;;
    clear) rm -f "$UPD_PUB"; echo "Chave pública das atualizações removida." ;;
    *) die "Usa: mpanel update-key set \"<PEM>\" | clear" ;;
  esac
  [ -f "$UPD_STATE" ] && upd_save "$UPD_STATE" "$(jq --argjson k "$([ -s "$UPD_PUB" ] && echo true || echo false)" '.key = $k' "$UPD_STATE")"
  return 0
}
upd_snaps_json(){ ls -1t "$UPD_SNAP"/*.tar.gz 2>/dev/null | head -n 10 | while read -r f; do printf '%s\t%s\n' "$(basename "$f")" "$(stat -c %s "$f")"; done | jq -R 'split("\t") | {file:.[0], size:(.[1]|tonumber)}' | jq -cs '.'; }

# --- atualizações do sistema operativo ---
cmd_os_check(){
  local list sec total reboot=false auto=false
  upd_status "A procurar atualizações do sistema" sistema
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    list=$(apt list --upgradable 2>/dev/null | awk -F'[/ ]' 'NR>1 && $1 != "" {sec = ($2 ~ /security/) ? "1" : "0"; print $1 "\t" $3 "\t" sec}')
    [ -f /var/run/reboot-required ] && reboot=true
    [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && auto=true
  else
    local secl; secl=$(dnf -q updateinfo list --security 2>/dev/null | awk '{print $3}' | sed -E 's/-[0-9][^-]*-[^-]*$//' | sort -u)
    list=$(dnf -q check-update 2>/dev/null | awk 'NF==3 && $1 ~ /\./ {n=$1; sub(/\.[^.]+$/, "", n); print n "\t" $2}' | while IFS=$'\t' read -r n v; do printf '%s\t%s\t%s\n' "$n" "$v" "$(grep -qxF "$n" <<<"$secl" && echo 1 || echo 0)"; done)
    command -v needs-restarting >/dev/null 2>&1 && { needs-restarting -r >/dev/null 2>&1 || reboot=true; }
    systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1 && auto=true
  fi
  total=$(printf '%s' "$list" | grep -c . ); sec=$(printf '%s\n' "$list" | awk -F'\t' '$3 == "1"' | grep -c .)
  upd_save "$OSU_STATE" "$(printf '%s\n' "$list" | grep . | jq -R 'split("\t") | {name:.[0], version:.[1], security:(.[2] == "1")}' | jq -cs \
     --arg t "$EPOCHSECONDS" --argjson r "$reboot" --argjson a "$auto" '{checked:($t|tonumber), total:length, security:(map(select(.security)) | length), reboot:$r, auto:$a, packages:(sort_by(if .security then 0 else 1 end) | .[0:300])}')"
  upd_status ""
  echo "$total atualizações do sistema disponíveis ($sec de segurança).$([ "$reboot" = true ] && echo " O servidor precisa de ser reiniciado.")"
  return 0
}
cmd_os_start(){ [ -f "$UPD_RUN" ] && die "Já está a decorrer uma atualização."; upd_status "A preparar" sistema; upd_spawn os-run "$@"; echo "Atualização do sistema iniciada em segundo plano."; return 0; }
cmd_os_run(){
  local only_sec=0 rc log
  [ "${1:-}" = "--security" ] && only_sec=1
  exec 6>/run/minipainel-update.lock; flock -n 6 || die "Já está a decorrer uma atualização."
  log="$UPD_DIR/sistema-$(date +%Y%m%d-%H%M%S).log"; install -d -m 700 "$UPD_DIR"
  upd_status "A instalar atualizações do sistema$([ "$only_sec" = 1 ] && echo ' (segurança)')" sistema
  if [ "$OS_FAMILY" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    local opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    if [ "$only_sec" = 1 ]; then
      local pk; pk=$(apt list --upgradable 2>/dev/null | awk -F'/' 'NR>1 && $2 ~ /security/ {print $1}')
      if [ -n "$pk" ]; then apt-get install "${opts[@]}" --only-upgrade $pk > "$log" 2>&1; rc=$?; else rc=0; echo "Sem atualizações de segurança." > "$log"; fi
    else apt-get upgrade "${opts[@]}" > "$log" 2>&1; rc=$?; fi
  else
    if [ "$only_sec" = 1 ]; then dnf -y upgrade --security > "$log" 2>&1; rc=$?; else dnf -y upgrade > "$log" 2>&1; rc=$?; fi
  fi
  # os serviços do painel continuam ativos?
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  local v; for v in $(php_installed); do systemctl is-active "$(php_service "$v")" >/dev/null 2>&1 || systemctl restart "$(php_service "$v")" >/dev/null 2>&1; done
  if [ "$rc" = 0 ]; then upd_finish true "Atualizações do sistema instaladas$([ "$only_sec" = 1 ] && echo ' (segurança)')."
  else upd_finish false "As atualizações do sistema terminaram com erro (código $rc). Registo: $log"; fi
  cmd_os_check >/dev/null 2>&1
  return 0
}
cmd_os_auto(){
  case "${1:-}" in
    on)
      if [ "$OS_FAMILY" = debian ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades >/dev/null 2>&1 || die "Falhou a instalação do unattended-upgrades."
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades
        printf '// IDDigital Hosting — só atualizações de segurança, sem reiniciar sozinho\nUnattended-Upgrade::Automatic-Reboot "false";\nUnattended-Upgrade::Remove-Unused-Dependencies "true";\nDpkg::Options { "--force-confdef"; "--force-confold"; };\n' > /etc/apt/apt.conf.d/52minipainel-unattended
        systemctl enable --now unattended-upgrades >/dev/null 2>&1
      else
        dnf install -y -q dnf-automatic >/dev/null 2>&1 || die "Falhou a instalação do dnf-automatic."
        sed -i 's/^upgrade_type *=.*/upgrade_type = security/; s/^apply_updates *=.*/apply_updates = yes/' /etc/dnf/automatic.conf
        systemctl enable --now dnf-automatic.timer >/dev/null 2>&1
      fi
      echo "Atualizações de segurança automáticas ativadas (o servidor não é reiniciado sozinho)." ;;
    off)
      if [ "$OS_FAMILY" = debian ]; then printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
      else systemctl disable --now dnf-automatic.timer >/dev/null 2>&1; fi
      echo "Atualizações automáticas desativadas." ;;
    *) die "Usa: mpanel os-auto on|off" ;;
  esac
  [ -f "$OSU_STATE" ] && upd_save "$OSU_STATE" "$(jq --argjson a "$([ "$1" = on ] && echo true || echo false)" '.auto = $a' "$OSU_STATE")"
  return 0
}
cmd_reboot(){ echo "O servidor vai reiniciar dentro de 1 minuto."; jq -cn --arg t "$EPOCHSECONDS" '{ts:($t|tonumber), ip:"servidor", user:"sistema", action:"Reinício do servidor pedido", ok:true}' >> "$DATA/logs/audit.log"; shutdown -r +1 "Reinício pedido no IDDigital Hosting" >/dev/null 2>&1 || ( sleep 60; reboot ) >/dev/null 2>&1 & return 0; }

write_auth(){ # mantém a verificação em dois passos ao mudar a password
  auth_update --arg u "$1" --arg h "$2" '.user = $u | .hash = $h'
}

cmd_passwd(){
  local p1 p2 rnd=0 h
  if [ "${1:-}" = "--random" ]; then
    rnd=1; p1=$(gen_pass 16)
  else
    [ -t 0 ] || die "Sem terminal interativo; usa 'mpanel passwd --random'."
    read -rsp "Nova password do painel: " p1; echo
    read -rsp "Repetir: " p2; echo
    [ "$p1" = "$p2" ] || die "As passwords não coincidem."
    [ ${#p1} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."
  fi
  h=$(printf '%s' "$p1" | "$(php_cli "$PANEL_PHP")" -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT);')
  [[ "$h" == '$2y$'* ]] || die "Falha ao gerar o hash da password."
  write_auth "$PANEL_USER" "$h" || die "Falha ao gravar a password."
  echo "Password do painel alterada (utilizador: $PANEL_USER)."
  if [ "$rnd" = 1 ]; then echo "Nova password: $p1"; fi
  return 0
}

cmd_panel_hash(){
  local h="${1:-}" re='^\$2y\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
  [[ "$h" =~ $re ]] || die "Hash inválido."
  write_auth "$PANEL_USER" "$h" || die "Falha ao gravar a password."
  echo "Password do painel alterada."
  return 0
}

# Valida um valor JSON do estado; se for inválido usa o valor por omissão e regista qual foi (para diagnóstico).
jv(){ # nome valor omissão
  if [ -n "$2" ] && jq . >/dev/null 2>&1 <<<"$2"; then printf '%s' "$2"; return 0; fi
  printf '%s %s: valor inválido: %s\n' "$(date '+%F %T')" "$1" "$(printf '%s' "$2" | head -c 300 | tr '\n' ' ')" >> "$DATA/logs/state-errors.log" 2>/dev/null
  echo "AVISO: estado do painel: o campo '$1' estava inválido e foi ignorado (detalhes em $DATA/logs/state-errors.log)." >&2
  printf '%s' "$3"
}
