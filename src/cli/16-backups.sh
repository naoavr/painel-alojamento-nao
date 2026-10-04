bk_conf(){ local v; v=$(grep -m1 "^$1=" "$BK_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
bk_remotes(){ if [ -s "$BK_REMOTES" ]; then cat "$BK_REMOTES"; else echo '[]'; fi; }
bk_rc(){ rclone --config "$BK_RCLONE" "$@"; }
# Tipos aceites na configuração colada (destinos remotos reais). sftp e s3 só pelo formulário.
BK_RAW_TYPES=" drive onedrive dropbox b2 webdav ftp pcloud box mega swift azureblob azurefiles gcs koofr opendrive yandex jottacloud sharefile seafile hidrive putio storj protondrive mailru premiumizeme quatrix sugarsync zoho filefabric "
bk_section(){ awk -v n="[$1]" '$0 == n { f = 1; next } /^\[/ { f = 0 } f' "$BK_RCLONE" 2>/dev/null; }
bk_cfg_check(){ # $1 = texto da secção (sem o cabeçalho); $2 = form|raw. Imprime o motivo se for inseguro.
  local txt=$1 how=$2 type k v line
  type=$(printf '%s\n' "$txt" | awk -F= '/^[[:space:]]*type[[:space:]]*=/ { v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }')
  [ -n "$type" ] || { echo "falta o tipo (type = ...)"; return 1; }
  if [ "$how" = raw ]; then
    [[ "$BK_RAW_TYPES" == *" $type "* ]] || { echo "o tipo '$type' não é permitido aqui (usa o formulário para SFTP e S3)"; return 1; }
  else
    case "$type" in sftp|s3) ;; *) [[ "$BK_RAW_TYPES" == *" $type "* ]] || { echo "o tipo '$type' não é permitido"; return 1; } ;; esac
  fi
  while IFS= read -r line; do
    case "$line" in ''|'#'*|';'*) continue ;; esac
    [[ "$line" == *=* ]] || { echo "linha inválida: $line"; return 1; }
    k=${line%%=*}; k=${k//[[:space:]]/}; v=${line#*=}; v=${v#"${v%%[![:space:]]*}"}
    case "$k" in
      ssh|remote|upstreams) echo "a opção '$k' não é permitida"; return 1 ;;
      key_file) [ "$how" = form ] && [[ "$v" == /etc/minipainel/rclone-keys/*.key ]] && [[ "$v" != *..* ]] || { echo "a opção '$k' não é permitida"; return 1; } ;;
      *_file|*_path|*file) echo "a opção '$k' não é permitida (lê ficheiros locais)"; return 1 ;;
    esac
  done <<<"$txt"
  return 0
}
bk_remote_ok(){ # nome -> 0 se o destino estiver configurado de forma segura
  local why; why=$(bk_cfg_check "$(bk_section "$1")" form) && return 0
  echo "O destino '$1' tem uma configuração não permitida ($why). Remove-o e volta a criá-lo." >&2
  return 1
}
BK_KEY=/etc/minipainel/backup.key
bk_key_ensure(){ if [ ! -s "$BK_KEY" ]; then ( umask 077; openssl rand -hex 32 > "$BK_KEY" ); fi; chmod 600 "$BK_KEY"; }
# HMAC-SHA256 do manifesto (a chave nunca passa na linha de comandos)
bk_hmac(){ "$(php_cli "$PANEL_PHP")" -r 'echo hash_hmac("sha256", (string)file_get_contents($argv[1]), trim((string)file_get_contents($argv[2])));' "$1" "$BK_KEY" 2>/dev/null; }
bk_sign(){ bk_key_ensure; bk_hmac "$1/manifest.json" > "$1/manifest.sig"; chown root:"$PANEL_SYSUSER" "$1/manifest.sig"; chmod 640 "$1/manifest.sig"; }
# 0 = assinatura e ficheiros válidos; 1 = alterado; 2 = backup antigo sem assinatura
bk_verify(){
  local dir=$1 f rel listed
  [ -f "$dir/manifest.sig" ] || return 2
  [ -s "$BK_KEY" ] || return 1
  [ "$(cat "$dir/manifest.sig")" = "$(bk_hmac "$dir/manifest.json")" ] || return 1
  jq -e '.sums | type == "object"' "$dir/manifest.json" >/dev/null 2>&1 || return 1
  ( cd "$dir" && jq -r '.sums | to_entries[] | "\(.value)  \(.key)"' manifest.json | sha256sum -c --quiet --strict >/dev/null 2>&1 ) || return 1
  listed=$(jq -r '.sums | keys[]' "$dir/manifest.json")
  while IFS= read -r f; do
    rel=${f#"$dir"/}
    case "$rel" in manifest.json|manifest.sig) continue ;; esac
    printf '%s\n' "$listed" | grep -qxF "$rel" || return 1
  done < <(find "$dir" -type f)
  return 0
}
cmd_bk_key(){ bk_key_ensure; echo "Chave dos backups (guarda-a fora do servidor; é precisa para repor backups remotos noutro servidor):"; cat "$BK_KEY"; return 0; }
cmd_bk_key_set(){ local k="${1:-}" re='^[0-9a-f]{64}$'; [[ "$k" =~ $re ]] || die "Chave inválida (64 caracteres hexadecimais)."; ( umask 077; echo "$k" > "$BK_KEY" ); echo "Chave dos backups definida."; return 0; }
bk_remote_root(){ bk_remotes | jq -r --arg n "$1" '.[] | select(.name == $n) | .root'; }
bk_host(){ hostname -s 2>/dev/null || echo servidor; }
bk_gz(){ if command -v pigz >/dev/null 2>&1; then echo "pigz -6"; else echo "gzip -6"; fi; }
bk_status(){ # running: texto do passo ou vazio
  local f=$DATA/stats/backup-run.json
  if [ -n "${1:-}" ]; then jq -n --arg s "$1" --arg t "$EPOCHSECONDS" '{step:$s, since:($t|tonumber)}' > "$f.tmp" && chown root:"$PANEL_SYSUSER" "$f.tmp" && chmod 640 "$f.tmp" && mv -f "$f.tmp" "$f"
  else rm -f "$f"; fi
}
bk_write_state(){
  local sets total
  sets=$(find "$BK_DIR" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | while read -r m; do jq -c '.' "$m" 2>/dev/null; done | jq -cs 'sort_by(-.created)')
  total=$(du -sb "$BK_DIR" 2>/dev/null | awk '{print $1}')
  jq -n --argjson sets "${sets:-[]}" --argjson rem "$(bk_remotes)" --arg total "${total:-0}" \
     --arg en "$(bk_conf ENABLED 1)" --arg time "$(bk_conf TIME 03:00)" --arg kd "$(bk_conf KEEP_DAILY 7)" --arg kw "$(bk_conf KEEP_WEEKLY 4)" \
     --arg km "$(bk_conf KEEP_MONTHLY 3)" --arg r "$(bk_conf REMOTE '')" --argjson last "$(cat "$DATA/stats/backup-last.json" 2>/dev/null || echo null)" \
     --arg ec "$(bk_conf ENCRYPT 1)" \
     '{conf:{enabled:($en=="1"), time:$time, keep_daily:($kd|tonumber), keep_weekly:($kw|tonumber), keep_monthly:($km|tonumber), remote:$r, encrypt:($ec=="1")},
       remotes:$rem, sets:$sets, total:($total|tonumber), last:$last}' > "$BK_STATE.tmp" \
    && chown root:"$PANEL_SYSUSER" "$BK_STATE.tmp" && chmod 640 "$BK_STATE.tmp" && mv -f "$BK_STATE.tmp" "$BK_STATE"
  return 0
}
bk_cron_apply(){
  local t h m
  t=$(bk_conf TIME 03:00); h=$((10#${t%%:*})); m=$((10#${t##*:}))
  if [ "$(bk_conf ENABLED 1)" = 1 ]; then
    printf '# IDDigital Hosting — backups automáticos (gerado pelo painel)\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nMAILTO=""\n%d %d * * * root /usr/local/sbin/mpanel backup-run --auto >/dev/null 2>&1\n' "$m" "$h" > /etc/cron.d/minipainel-backup
    chmod 644 /etc/cron.d/minipainel-backup
  else
    rm -f /etc/cron.d/minipainel-backup
  fi
  touch /etc/cron.d 2>/dev/null
  return 0
}

# Cria um conjunto: $1 = site | _bd | _sistema ; $2 = auto|manual|pre-restauro ; imprime o id
bk_make(){
  local s=$1 type=$2 id dir gz d u files=false dbs="[]" size rc
  id=$(date '+%Y%m%d-%H%M%S'); dir="$BK_DIR/$s/$id"
  [ -e "$dir" ] && { sleep 1; id=$(date '+%Y%m%d-%H%M%S'); dir="$BK_DIR/$s/$id"; }
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$BK_DIR" "$BK_DIR/$s"
  install -d -m 700 "$dir.part"
  gz=$(bk_gz)
  if [ "$s" = _sistema ]; then
    bk_status "Configuração do sistema"
    tar -C / -czf "$dir.part/sistema.tar.gz" --ignore-failed-read etc/minipainel etc/nginx/minipainel etc/cron.d var/lib/minipainel/auth.json 2>/dev/null
    files=true
  elif [ "$s" != _bd ]; then
    bk_status "Ficheiros de $s"
    tar -C "$WWW_ROOT" --exclude="$s/tmp" -I "$gz" -cpf "$dir.part/ficheiros.tar.gz" "$s"; rc=$?
    [ "$rc" -le 1 ] || { rm -rf "$dir.part"; echo "ERRO: falhou a cópia dos ficheiros de $s (tar $rc)." >&2; return 1; }
    install -d -m 700 "$dir.part/config"
    cp -p "$SITES_DIR/$s.conf" "$dir.part/config/site.conf" 2>/dev/null
    cp -p "$CRON_DIR/$s.json" "$dir.part/config/cron.json" 2>/dev/null
    files=true
  fi
  local list=""
  if [ "$s" = _bd ]; then
    list=$(db_sizes | awk '{print $1}' | while read -r d; do [ -n "$d" ] && [ "$d" != "$DB_ADMIN" ] && [ -z "$(dbmap_load | jq -r --arg d "$d" '.[$d] // empty')" ] && echo "$d"; done)
  elif [ "$s" != _sistema ]; then
    list=$(dbs_of_site "$s")
  fi
  for d in $list; do
    db_exists "$d" || continue
    bk_status "Base de dados $d"
    mysqldump -uroot --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 "$d" 2>"$dir.part/.err" | $gz > "$dir.part/bd-$d.sql.gz"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "ERRO: falhou a cópia da base de dados $d: $(head -c 300 "$dir.part/.err")" >&2; rm -rf "$dir.part"; return 1; fi
    u=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$d' AND Host='localhost'" 2>/dev/null)
    if [ "$u" = 1 ]; then
      { db_q "SHOW CREATE USER '$d'@'localhost'" 2>/dev/null | sed 's/$/;/'; db_q "SHOW GRANTS FOR '$d'@'localhost'" 2>/dev/null | sed 's/$/;/'; } > "$dir.part/bd-$d.user.sql"
    fi
    dbs=$(jq -c --arg d "$d" '. + [$d]' <<<"$dbs")
  done
  rm -f "$dir.part/.err"
  size=$(du -sb "$dir.part" | awk '{print $1}')
  local sums
  sums=$(cd "$dir.part" && find . -type f -printf '%P\n' | sort | while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"; done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -cs 'add // {}')
  jq -n --arg s "$s" --arg id "$id" --arg t "$type" --arg c "$EPOCHSECONDS" --arg sz "$size" --argjson f "$files" --argjson dbs "$dbs" \
        --arg v "$MP_VERSION" --arg php "$( [ -f "$SITES_DIR/$s.conf" ] && site_get "$s" PHP)" \
        --argjson sums "$sums" \
        '{site:$s, id:$id, type:$t, created:($c|tonumber), size:($sz|tonumber), files:$f, dbs:$dbs, version:$v, php:$php, remote:"", sums:$sums}' > "$dir.part/manifest.json"
  bk_sign "$dir.part"
  chown -R root:"$PANEL_SYSUSER" "$dir.part"; find "$dir.part" -type f -exec chmod 640 {} +; chmod 750 "$dir.part"; [ -d "$dir.part/config" ] && chmod 750 "$dir.part/config"
  mv "$dir.part" "$dir"
  echo "$id"
}
bk_upload(){ # site id remote
  local s=$1 id=$2 r=$3 root
  bk_remote_ok "$r" || return 1
  root=$(bk_remote_root "$r"); [ -n "$root" ] || { echo "Destino remoto '$r' não existe." >&2; return 1; }
  local src="$BK_DIR/$s/$id" stage="" enc=false rc
  if [ "$(bk_conf ENCRYPT 1)" = 1 ]; then
    bk_status "Cifra de $s"
    stage=$(mktemp -d /var/tmp/mp-bkup.XXXXXX)
    bk_encrypt_dir "$src" "$stage" || { rm -rf "$stage"; echo "Falhou a cifra do backup." >&2; return 1; }
    src=$stage; enc=true
  fi
  bk_status "Envio de $s para $r"
  bk_rc copy "$src" "$r:$root/$(bk_host)/$s/$id" --transfers 2 2>&1 | tail -n 3 >&2
  rc=${PIPESTATUS[0]}
  [ -n "$stage" ] && rm -rf "$stage"
  [ "$rc" -eq 0 ] || return 1
  jq --arg r "$r" --argjson e "$enc" '.remote = $r | .remote_enc = $e' "$BK_DIR/$s/$id/manifest.json" > "$BK_DIR/$s/$id/manifest.tmp" && mv -f "$BK_DIR/$s/$id/manifest.tmp" "$BK_DIR/$s/$id/manifest.json"
  chown root:"$PANEL_SYSUSER" "$BK_DIR/$s/$id/manifest.json"; chmod 640 "$BK_DIR/$s/$id/manifest.json"
  [ -f "$BK_DIR/$s/$id/manifest.sig" ] && bk_sign "$BK_DIR/$s/$id"
}
# Retenção avô-pai-filho: lê ids (AAAAMMDD-HHMMSS) no stdin e imprime os que devem ser apagados
bk_gfs(){
  local kd kw km
  kd=$(bk_conf KEEP_DAILY 7); kw=$(bk_conf KEEP_WEEKLY 4); km=$(bk_conf KEEP_MONTHLY 3)
  sort -r | while read -r id; do
    [ -n "$id" ] || continue
    echo "$id $(date -d "${id:0:8}" '+%G%V' 2>/dev/null || echo 0)"
  done | awk -v kd="$kd" -v kw="$kw" -v km="$km" '
    { id = $1; day = substr(id, 1, 8); wk = $2; mo = substr(id, 1, 6); keep = 0
      if (!(day in D) && nd < kd) { D[day] = 1; nd++; keep = 1 }
      if (!(wk in W) && nw < kw) { W[wk] = 1; nw++; keep = 1 }
      if (!(mo in M) && nm < km) { M[mo] = 1; nm++; keep = 1 }
      if (!keep) print id }'
}
bk_prune_local(){ # site
  local s=$1 id
  [ -d "$BK_DIR/$s" ] || return 0
  for id in $(for m in "$BK_DIR/$s"/*/manifest.json; do [ -f "$m" ] && jq -r 'select(.type == "auto") | .id' "$m"; done | bk_gfs); do
    rm -rf "${BK_DIR:?}/$s/$id"
  done
  find "$BK_DIR/$s" -maxdepth 1 -name '*.part' -mmin +720 -exec rm -rf {} + 2>/dev/null
}
bk_prune_remote(){ # site remote
  local s=$1 r=$2 root id
  bk_remote_ok "$r" 2>/dev/null || return 0
  root=$(bk_remote_root "$r"); [ -n "$root" ] || return 0
  for id in $(bk_rc lsf --dirs-only "$r:$root/$(bk_host)/$s" 2>/dev/null | tr -d '/' | grep -E '^[0-9]{8}-[0-9]{6}$' | bk_gfs); do
    bk_rc purge "$r:$root/$(bk_host)/$s/$id" >/dev/null 2>&1
  done
}

cmd_backup_run(){
  local auto=0 only="" remote="" s id ok=0 fail=0 msgs="" t0 used r
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto=1; shift ;;
      --site) only="${2:-}"; shift 2 || shift ;;
      --remote) remote="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  exec 8>"$BK_LOCK"; flock -n 8 || die "Já está a decorrer um backup."
  used=$(df -P "$(dirname "$BK_DIR")" | awk 'NR==2{gsub("%","",$5); print $5}')
  if [ "${used:-0}" -ge 90 ]; then
    jq -n --arg t "$EPOCHSECONDS" '{ts:($t|tonumber), ok:false, msg:"Backup cancelado: o disco está acima de 90% de ocupação.", duration:0}' > "$DATA/stats/backup-last.json"
    bk_write_state; die "Backup cancelado: o disco está acima de 90% de ocupação."
  fi
  [ "$auto" = 1 ] && remote=$(bk_conf REMOTE '')
  t0=$EPOCHSECONDS
  local targets
  if [ -n "$only" ]; then
    case "$only" in _bd|_sistema) ;; *) valid_site "$only" && site_exists "$only" || die "O site '$only' não existe." ;; esac
    targets=$only
  else
    targets="$(site_names) _bd _sistema"
  fi
  local errf; errf=$(mktemp)
  for s in $targets; do
    : > "$errf"
    if id=$(bk_make "$s" "$([ "$auto" = 1 ] && echo auto || echo manual)" 2>"$errf"); then
      ok=$((ok + 1))
      if [ -n "$remote" ]; then
        bk_upload "$s" "$id" "$remote" 2>>"$errf" || { fail=$((fail + 1)); msgs+="$s: falhou o envio para $remote ($(tail -n 1 "$errf" | head -c 200)). "; }
      fi
      if [ "$auto" = 1 ]; then bk_prune_local "$s"; [ -n "$remote" ] && bk_prune_remote "$s" "$remote"; fi
    else
      fail=$((fail + 1)); msgs+="$s: $(tr '\n' ' ' < "$errf" | head -c 300) "
    fi
  done
  rm -f "$errf"
  bk_status ""
  jq -n --arg t "$EPOCHSECONDS" --arg d "$(( EPOCHSECONDS - t0 ))" --argjson ok "$([ "$fail" = 0 ] && echo true || echo false)" \
        --arg m "$( [ "$fail" = 0 ] && echo "$ok conjunto(s) guardado(s)${remote:+ e enviados para $remote}." || echo "$ok guardado(s), $fail com erro. $msgs")" \
        '{ts:($t|tonumber), ok:$ok, msg:$m, duration:($d|tonumber)}' > "$DATA/stats/backup-last.json"
  chown root:"$PANEL_SYSUSER" "$DATA/stats/backup-last.json"; chmod 640 "$DATA/stats/backup-last.json"
  bk_write_state
  if [ "$fail" = 0 ]; then echo "Backup concluído: $ok conjunto(s) em $(( EPOCHSECONDS - t0 ))s${remote:+, enviados para $remote}."; return 0; fi
  echo "Backup com erros: $msgs" >&2; return 1
}
cmd_backup_start(){ # lança em segundo plano (usado pelo painel)
  [ -n "$(flock -n "$BK_LOCK" true 2>&1 || echo busy)" ] && die "Já está a decorrer um backup."
  setsid /usr/local/sbin/mpanel backup-run "$@" >/dev/null 2>&1 < /dev/null 9>&- &
  echo "Backup iniciado em segundo plano. O progresso aparece na página Backups."
  return 0
}
bk_need_set(){ # site id -> garante cópia local (vai buscar ao destino remoto se for preciso)
  local s=$1 id=$2 re='^[0-9]{8}-[0-9]{6}$' r root
  [[ "$id" =~ $re ]] || die "Identificador de backup inválido: $id"
  case "$s" in _bd|_sistema) ;; *) valid_site "$s" || die "Site inválido: $s" ;; esac
  BK_FETCHED=0
  [ -f "$BK_DIR/$s/$id/manifest.json" ] && return 0
  r=$(bk_conf REMOTE ''); [ -n "$r" ] || die "O backup $id de $s não existe localmente."
  bk_remote_ok "$r" || die "Destino remoto recusado por razões de segurança."
  root=$(bk_remote_root "$r")
  BK_FETCHED=1
  bk_rc copy "$r:$root/$(bk_host)/$s/$id" "$BK_DIR/$s/$id" >/dev/null 2>&1 && [ -f "$BK_DIR/$s/$id/manifest.json" ] || die "O backup $id de $s não existe localmente nem em $r."
  bk_decrypt_dir "$BK_DIR/$s/$id" || { rm -rf "${BK_DIR:?}/$s/$id"; die "Não foi possível decifrar o backup: a chave dos backups deste servidor não é a mesma que o cifrou (usa 'mpanel bk-key-set')."; }
  chown -R root:"$PANEL_SYSUSER" "$BK_DIR/$s/$id"
}
cmd_bk_restore(){
  local s="${1:-}" id="${2:-}" what=all dir m d f uexists tmp pre="" created=0 port php noverify=0 vr newpw="" BK_FETCHED=0
  [ $# -ge 2 ] && shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --what) what="${2:-all}"; shift 2 || shift ;;
      --no-verify) noverify=1; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  case "$what" in all|files|db) ;; *) die "Use --what all|files|db" ;; esac
  [ "$s" = _sistema ] && die "A configuração do sistema não é reposta pelo painel; extrai sistema.tar.gz manualmente se precisares."
  bk_need_set "$s" "$id"
  dir="$BK_DIR/$s/$id"; m="$dir/manifest.json"
  bk_verify "$dir"; vr=$?
  if [ "$vr" = 1 ] && [ "$noverify" = 0 ]; then
    [ "$BK_FETCHED" = 1 ] && rm -rf "${dir:?}"
    die "Restauro recusado: a assinatura do backup não é válida ou os ficheiros foram alterados. Se vem de outro servidor, define primeiro a chave com 'mpanel bk-key-set'."
  fi
  if [ "$vr" = 2 ] && [ "$BK_FETCHED" = 1 ] && [ "$noverify" = 0 ]; then
    rm -rf "${dir:?}"; die "Restauro recusado: o backup remoto não tem assinatura (é anterior à v1.9.1). Para o repor mesmo assim, usa no servidor: mpanel bk-restore $s $id --no-verify"
  fi
  if [ "$s" != _bd ]; then
    if ! site_exists "$s"; then
      [ "$what" = db ] && die "O site $s não existe; repõe tudo (--what all) para o recriar."
      port=$(grep -m1 '^PORT=' "$dir/config/site.conf" 2>/dev/null | cut -d= -f2); php=$(jq -r '.php' "$m")
      php_is_installed "$php" || php=$DEFAULT_PHP
      if port_owner "$port" >/dev/null || port_listening "$port"; then port=""; fi
      ( cmd_site_add "$s" ${port:+--port "$port"} --php "$php" ) >/dev/null || die "Não foi possível recriar o site $s."
      created=1
      grep -E '^(MEM|UPLOAD|EXEC|INPUT_TIME|INPUT_VARS|DISPLAY_ERRORS)=' "$dir/config/site.conf" 2>/dev/null | while IFS='=' read -r k v; do site_set "$s" "$k" "$v"; done
      write_pool "$s" "$(site_get "$s" PHP)"; write_nginx "$s" "$(site_get "$s" PORT)" "$(site_get "$s" PHP)" "$(ngx_file "$s")"
      apply_php "$(site_get "$s" PHP)" >/dev/null 2>&1; apply_nginx >/dev/null 2>&1
    else
      pre=$(bk_make "$s" pre-restauro 2>/dev/null) || die "Não foi possível criar a cópia de segurança antes de repor; nada foi alterado."
    fi
  else
    pre=$(bk_make _bd pre-restauro 2>/dev/null) || die "Não foi possível criar a cópia de segurança antes de repor; nada foi alterado."
  fi
  if [ "$what" != db ] && [ "$s" != _bd ]; then
    tmp="$WWW_ROOT/.restauro-$s-$$"; install -d -m 700 "$tmp"
    tar -C "$tmp" --no-same-owner -xzpf "$dir/ficheiros.tar.gz" "$s/public_html" || { rm -rf "$tmp"; die "Falhou a extração dos ficheiros."; }
    find "$tmp" -type f -perm /6000 -exec chmod ug-s {} + 2>/dev/null
    [ -d "$tmp/$s/public_html" ] || { rm -rf "$tmp"; die "O backup não contém public_html."; }
    mv "$WWW_ROOT/$s/public_html" "$WWW_ROOT/$s/.public_html.antes-$id" && mv "$tmp/$s/public_html" "$WWW_ROOT/$s/public_html" || {
      [ -d "$WWW_ROOT/$s/.public_html.antes-$id" ] && mv "$WWW_ROOT/$s/.public_html.antes-$id" "$WWW_ROOT/$s/public_html"; rm -rf "$tmp"; die "Falhou a substituição dos ficheiros; nada foi alterado."; }
    chown -R "mp_$s:mp_$s" "$WWW_ROOT/$s/public_html"; chmod 2750 "$WWW_ROOT/$s/public_html"
    se_restore "$WWW_ROOT/$s/public_html"
    rm -rf "$tmp" "$WWW_ROOT/$s/.public_html.antes-$id"
    if [ "$what" = all ] && [ -f "$dir/config/cron.json" ]; then cp "$dir/config/cron.json" "$CRON_DIR/$s.json"; chmod 600 "$CRON_DIR/$s.json"; cron_write_site "$s"; fi
  fi
  if [ "$what" != files ]; then
    for f in "$dir"/bd-*.sql.gz; do
      [ -f "$f" ] || continue
      d=${f##*/bd-}; d=${d%.sql.gz}; valid_db "$d" || continue
      db_exec "DROP DATABASE IF EXISTS \`$d\`; CREATE DATABASE \`$d\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || die "Falhou a recriação da base de dados $d."
      gzip -dc "$f" | mysql -uroot "$d" || die "Falhou a importação de $d${pre:+ (o estado anterior está no backup $pre)}."
      uexists=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$d' AND Host='localhost'" 2>/dev/null)
      if [ "$uexists" = 0 ]; then
        # recria só o utilizador da própria base de dados, com o hash da password original (nunca executa o SQL do backup)
        local hsh ng="${d//_/\\_}"
        hsh=$( [ -f "$dir/bd-$d.user.sql" ] && grep -m1 -oE "IDENTIFIED BY PASSWORD '\*[0-9A-F]{40}'" "$dir/bd-$d.user.sql" | grep -oE '\*[0-9A-F]{40}')
        if [ -n "$hsh" ]; then
          db_exec "CREATE USER '$d'@'localhost' IDENTIFIED BY PASSWORD '$hsh'; GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$d'@'localhost'; FLUSH PRIVILEGES;" || warn "Não foi possível recriar o utilizador $d."
        else
          local pw; pw=$(gen_pass 20)
          db_exec "CREATE USER '$d'@'localhost' IDENTIFIED BY '$pw'; GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$d'@'localhost'; FLUSH PRIVILEGES;" && newpw+=" $d: $pw"
        fi
      fi
      [ "$s" != _bd ] && dbmap_set "$d" "$s"
    done
  fi
  bk_write_state
  echo "Backup $id de $s reposto ($what).${pre:+ O estado anterior ficou guardado no backup $pre.}$([ "$created" = 1 ] && echo " O site foi recriado.")"
  [ "$vr" = 2 ] && echo "Aviso: backup antigo, sem assinatura (anterior à v1.9.1)."
  [ -n "$newpw" ] && echo "Utilizadores recriados com password nova (atualiza a configuração do site):$newpw"
  return 0
}
cmd_bk_delete(){
  local s="${1:-}" id="${2:-}" re='^[0-9]{8}-[0-9]{6}$'
  [[ "$id" =~ $re ]] || die "Identificador inválido."
  case "$s" in _bd|_sistema) ;; *) valid_site "$s" || die "Site inválido." ;; esac
  [ -d "$BK_DIR/$s/$id" ] || die "O backup $id de $s não existe."
  rm -rf "${BK_DIR:?}/$s/$id"; bk_write_state
  echo "Backup $id de $s apagado (cópia local)."
  return 0
}
cmd_bk_conf(){
  local en tm kd kw km r ec re_t='^([01][0-9]|2[0-3]):[0-5][0-9]$' re_n='^[0-9]{1,3}$'
  en=$(bk_conf ENABLED 1); tm=$(bk_conf TIME 03:00); kd=$(bk_conf KEEP_DAILY 7); kw=$(bk_conf KEEP_WEEKLY 4); km=$(bk_conf KEEP_MONTHLY 3); r=$(bk_conf REMOTE ''); ec=$(bk_conf ENCRYPT 1)
  while [ $# -gt 0 ]; do
    case "$1" in
      --on) en=1; shift ;; --off) en=0; shift ;;
      --time) tm="${2:-}"; shift 2 || shift ;;
      --daily) kd="${2:-}"; shift 2 || shift ;;
      --weekly) kw="${2:-}"; shift 2 || shift ;;
      --monthly) km="${2:-}"; shift 2 || shift ;;
      --remote) r="${2:-}"; shift 2 || shift ;;
      --encrypt) case "${2:-}" in on|1) ec=1 ;; off|0) ec=0 ;; *) die "--encrypt on|off" ;; esac; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$tm" =~ $re_t ]] || die "Hora inválida: $tm (HH:MM)."
  for v in "$kd" "$kw" "$km"; do [[ "$v" =~ $re_n ]] || die "Retenção inválida: $v"; done
  [ "$kd" -ge 1 ] || die "Guarda pelo menos 1 backup diário."
  [ "$r" = none ] && r=""
  [ -z "$r" ] || [ -n "$(bk_remote_root "$r")" ] || die "O destino remoto '$r' não existe."
  printf 'ENABLED=%s\nTIME=%s\nKEEP_DAILY=%s\nKEEP_WEEKLY=%s\nKEEP_MONTHLY=%s\nREMOTE=%s\nENCRYPT=%s\n' "$en" "$tm" "$kd" "$kw" "$km" "$r" "$ec" > "$BK_CONF"; chmod 600 "$BK_CONF"
  bk_cron_apply; bk_write_state
  if [ "$en" = 1 ]; then echo "Backups automáticos todos os dias às $tm (guarda $kd diários, $kw semanais e $km mensais)${r:+, com cópia em $r}."
  else echo "Backups automáticos desativados."; fi
  return 0
}
cmd_bk_remote_add(){ # nome tipo opções...
  local n="${1:-}" t="${2:-}" root="" host="" port=22 user="" pass="" key="" prov=Other ep="" reg="" ak="" sk="" bucket="" raw="" re='^[a-z][a-z0-9-]{1,23}$'
  [ $# -ge 2 ] && shift 2
  [[ "$n" =~ $re ]] || die "Nome inválido (minúsculas, números e '-', 2 a 24 caracteres)."
  command -v rclone >/dev/null 2>&1 || die "O rclone não está instalado."
  [ -z "$(bk_remote_root "$n")" ] || die "Já existe um destino chamado $n."
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host="${2:-}"; shift 2 || shift ;; --port) port="${2:-}"; shift 2 || shift ;;
      --user) user="${2:-}"; shift 2 || shift ;; --pass) pass="${2:-}"; shift 2 || shift ;;
      --key) key="${2:-}"; shift 2 || shift ;; --path) root="${2:-}"; shift 2 || shift ;;
      --provider) prov="${2:-}"; shift 2 || shift ;; --endpoint) ep="${2:-}"; shift 2 || shift ;;
      --region) reg="${2:-}"; shift 2 || shift ;; --access) ak="${2:-}"; shift 2 || shift ;;
      --secret) sk="${2:-}"; shift 2 || shift ;; --bucket) bucket="${2:-}"; shift 2 || shift ;;
      --config) raw="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  touch "$BK_RCLONE"; chmod 600 "$BK_RCLONE"
  case "$t" in
    sftp)
      [ -n "$host" ] && [ -n "$user" ] || die "Indica o servidor e o utilizador."
      [ -n "$pass" ] || [ -n "$key" ] || die "Indica a password ou a chave privada."
      [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "Porta inválida."
      [[ "$host$user" != *[$'\n\r ']* ]] || die "Servidor ou utilizador inválido."
      {
        printf '\n[%s]\ntype = sftp\nhost = %s\nuser = %s\nport = %s\nshell_type = unix\n' "$n" "$host" "$user" "$port"
        [ -n "$pass" ] && printf 'pass = %s\n' "$(printf '%s' "$pass" | rclone obscure -)"
        if [ -n "$key" ]; then install -d -m 700 /etc/minipainel/rclone-keys; printf '%s\n' "$key" | sed 's/\\n/\n/g' > "/etc/minipainel/rclone-keys/$n.key"; chmod 600 "/etc/minipainel/rclone-keys/$n.key"; printf 'key_file = /etc/minipainel/rclone-keys/%s.key\n' "$n"; fi
      } >> "$BK_RCLONE"
      root=${root:-backups} ;;
    s3)
      [ -n "$ak" ] && [ -n "$sk" ] && [ -n "$bucket" ] || die "Indica a chave de acesso, a chave secreta e o bucket."
      [[ "$prov$ak$sk$ep$reg" != *[$'\n\r']* ]] || die "Valores inválidos."
      {
        printf '\n[%s]\ntype = s3\nprovider = %s\naccess_key_id = %s\nsecret_access_key = %s\nno_check_bucket = true\n' "$n" "$prov" "$ak" "$sk"
        [ -n "$ep" ] && printf 'endpoint = %s\n' "$ep"
        [ -n "$reg" ] && printf 'region = %s\n' "$reg"
      } >> "$BK_RCLONE"
      root="$bucket${root:+/$root}" ;;
    rclone)
      [ -n "$raw" ] || die "Cola a secção de configuração do rclone."
      raw=$(printf '%s' "$raw" | sed 's/\\n/\n/g' | sed 's/[[:space:]]*$//')
      [ "$(printf '%s\n' "$raw" | grep -c '^\[')" = 1 ] && [ "$(printf '%s\n' "$raw" | sed -n '1{/^\[/p}')" = "[$n]" ] || die "A configuração tem de ter uma só secção, a começar por [$n]."
      local why; why=$(bk_cfg_check "$(printf '%s\n' "$raw" | sed '1d')" raw) || die "Configuração recusada: $why."
      grep -q "^\[$n\]$" "$BK_RCLONE" && die "Já existe [$n] na configuração do rclone."
      printf '\n%s\n' "$raw" >> "$BK_RCLONE"
      root=${root:-iddigital-hosting} ;;
    *) die "Tipo inválido: usa sftp, s3 ou rclone." ;;
  esac
  jq --arg n "$n" --arg t "$t" --arg r "$root" '. + [{name:$n, type:$t, root:$r}]' <<<"$(bk_remotes)" > "$BK_REMOTES.tmp" && chmod 600 "$BK_REMOTES.tmp" && mv -f "$BK_REMOTES.tmp" "$BK_REMOTES"
  bk_write_state
  echo "Destino $n ($t) adicionado. Usa 'Testar' para confirmar o acesso."
  return 0
}
cmd_bk_remote_test(){
  local n="${1:-}" root f
  root=$(bk_remote_root "$n"); [ -n "$root" ] || die "O destino $n não existe."
  bk_remote_ok "$n" || die "Destino recusado por razões de segurança."
  local errf; errf=$(mktemp)
  f="teste-$(bk_host)-$EPOCHSECONDS.txt"
  echo "IDDigital Hosting: teste de escrita" | bk_rc rcat "$n:$root/$f" 2>"$errf" || { head -c 400 "$errf" >&2; rm -f "$errf"; die "Não foi possível escrever em $n:$root."; }
  bk_rc deletefile "$n:$root/$f" >/dev/null 2>&1; rm -f "$errf"
  echo "Destino $n acessível: escrita e remoção em $root funcionaram."
  return 0
}
cmd_bk_remote_del(){
  local n="${1:-}"
  [ -n "$(bk_remote_root "$n")" ] || die "O destino $n não existe."
  bk_rc config delete "$n" >/dev/null 2>&1; rm -f "/etc/minipainel/rclone-keys/$n.key"
  jq --arg n "$n" 'map(select(.name != $n))' <<<"$(bk_remotes)" > "$BK_REMOTES.tmp" && chmod 600 "$BK_REMOTES.tmp" && mv -f "$BK_REMOTES.tmp" "$BK_REMOTES"
  [ "$(bk_conf REMOTE '')" = "$n" ] && sed -i 's/^REMOTE=.*/REMOTE=/' "$BK_CONF"
  bk_write_state
  echo "Destino $n removido (os backups já enviados para lá não foram apagados)."
  return 0
}
cmd_bk_init(){
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$BK_DIR"; bk_key_ensure; bk_cron_apply; bk_write_state
  local r; for r in $(bk_remotes | jq -r '.[].name'); do bk_remote_ok "$r" || true; done
  echo "Backups configurados."; return 0
}
cmd_bk_list(){
  local s="${1:-}"
  printf '%-12s %-16s %-13s %-10s %-8s %s\n' SITE ID TIPO TAMANHO REMOTO "BASES DE DADOS"
  find "$BK_DIR" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | while read -r m; do jq -r '[.site, .id, .type, (.size|tostring), (if .remote == "" then "-" else .remote end), (.dbs | join(","))] | @tsv' "$m"; done |
    sort -k2,2r | while IFS=$'\t' read -r a b c d e f; do [ -z "$s" ] || [ "$s" = "$a" ] || continue; printf '%-12s %-16s %-13s %-10s %-8s %s\n' "$a" "$b" "$c" "$(numfmt --to=iec "$d" 2>/dev/null || echo "$d")" "$e" "$f"; done
  return 0
}

# ---------- modo do servidor, domínios e SSL ----------
SRV_CONF=/etc/minipainel/server.conf     # MODE=lan|internet, EMAIL, PANEL_DOMAIN, PANEL_SSL
ACME_ROOT=/var/www/minipainel-acme
NGX_INC=/etc/nginx/minipainel/inc
NGX_CONFD=/etc/nginx/minipainel/conf.d
SELF_SSL=/etc/minipainel/ssl/sites
srv_get(){ local v; v=$(grep -m1 "^$1=" "$SRV_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
srv_set(){
  touch "$SRV_CONF"; chmod 600 "$SRV_CONF"
  if grep -q "^$1=" "$SRV_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$SRV_CONF"; else echo "$1=$2" >> "$SRV_CONF"; fi
}
valid_domain(){ local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'; [ ${#1} -le 253 ] && [[ "$1" =~ $re ]]; }
domain_owner(){ # imprime o site (ou "painel") que usa o domínio
  local d=$1 n
  [ "$(srv_get PANEL_DOMAIN '')" = "$d" ] && { echo painel; return 0; }
  for n in $(site_names); do [[ " $(site_get "$n" DOMAINS) " == *" $d "* ]] && { echo "$n"; return 0; }; done
  return 1
}
cert_files(){ # nome -> "crt key" se existir certificado
  local n=$1
  if [ -s "/etc/letsencrypt/live/$n/fullchain.pem" ]; then echo "/etc/letsencrypt/live/$n/fullchain.pem /etc/letsencrypt/live/$n/privkey.pem"; return 0; fi
  if [ -s "$SELF_SSL/$n.crt" ]; then echo "$SELF_SSL/$n.crt $SELF_SSL/$n.key"; return 0; fi
  return 1
}
cert_expiry(){ local c; c=$(cert_files "$1") || return 0; openssl x509 -enddate -noout -in "${c%% *}" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null; }
self_issue(){ # nome domínios...
  local n=$1 san="" d; shift
  for d in "$@"; do san+="${san:+,}DNS:$d"; done
  install -d -m 700 "$SELF_SSL"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 -keyout "$SELF_SSL/$n.key" -out "$SELF_SSL/$n.crt" \
    -subj "/CN=$1" -addext "subjectAltName=$san" >/dev/null 2>&1 || return 1
  chmod 600 "$SELF_SSL/$n.key"
}
le_issue(){ # nome domínios... (valida primeiro no ambiente de testes do Let's Encrypt)
  local n=$1 d out em; shift
  command -v certbot >/dev/null 2>&1 || { echo "O certbot não está instalado." >&2; return 1; }
  local args=(certonly --webroot -w "$ACME_ROOT" --cert-name "$n" --non-interactive --agree-tos --keep-until-expiring --expand --deploy-hook "systemctl reload nginx")
  em=$(srv_get EMAIL ''); if [ -n "$em" ]; then args+=(-m "$em"); else args+=(--register-unsafely-without-email); fi
  [ -n "${MP_ACME_SERVER:-}" ] && args+=(--server "$MP_ACME_SERVER")
  for d in "$@"; do args+=(-d "$d"); done
  install -d -m 755 "$ACME_ROOT"
  if [ -z "${MP_ACME_SERVER:-}" ]; then
    out=$(certbot "${args[@]}" --dry-run 2>&1) || { echo "O Let's Encrypt não conseguiu validar os domínios:"; echo "$out" | grep -E 'Domain:|Type:|Detail:|Hint:|Error' | head -n 8; return 1; } >&2
  fi
  out=$(certbot "${args[@]}" 2>&1) || { echo "Falhou o pedido do certificado:"; echo "$out" | grep -E 'Domain:|Type:|Detail:|Hint:|Error|too many' | head -n 8; return 1; } >&2
  return 0
}
le_delete(){ command -v certbot >/dev/null 2>&1 && certbot delete --cert-name "$1" --non-interactive >/dev/null 2>&1; rm -f "$SELF_SSL/$1.crt" "$SELF_SSL/$1.key"; return 0; }
acme_loc(){ printf '    location ^~ /.well-known/acme-challenge/ { root %s; default_type text/plain; }\n' "$ACME_ROOT"; }
canon_redirect(){ # domínios www -> linha de redirecionamento ou vazio
  local doms=$1 mode=$2 first canon d
  [ "$mode" = keep ] || [ -z "$doms" ] && return 0
  first=${doms%% *}; first=${first#www.}
  if [ "$mode" = www ]; then canon="www.$first"; else canon="$first"; fi
  for d in $doms; do [ "$d" = "$canon" ] && { printf '    if ($host != "%s") { return 301 $scheme://%s$request_uri; }\n' "$canon" "$canon"; return 0; }; done
  return 0
}
# Servidores HTTP/HTTPS de um conjunto de domínios: nome include domínios ssl(none|le|self) https www
domain_servers(){
  local n=$1 inc=$2 doms=$3 ssl=$4 https=$5 www=$6 l6="" l6s="" crt key cf
  [ -n "$doms" ] || return 0
  [ "${IPV6:-0}" = 1 ] && { l6="    listen [::]:80;"; l6s="    listen [::]:443 ssl http2;"; }
  cf=""; [ "$ssl" != none ] && cf=$(cert_files "$n")
  printf '\n# domínios: %s\nserver {\n    listen 80;\n%s\n    server_name %s;\n' "$doms" "$l6" "$doms"
  acme_loc
  if [ -n "$cf" ] && [ "$https" = 1 ]; then
    printf '    location / { return 301 https://$host$request_uri; }\n}\n'
  else
    canon_redirect "$doms" "$www"
    printf '    include %s;\n}\n' "$inc"
  fi
  if [ -n "$cf" ]; then
    crt=${cf%% *}; key=${cf##* }
    printf '\nserver {\n    listen 443 ssl http2;\n%s\n    server_name %s;\n    ssl_certificate     %s;\n    ssl_certificate_key %s;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:MPSSL:1m;\n' "$l6s" "$doms" "$crt" "$key"
    canon_redirect "$doms" "$www"
    printf '    include %s;\n}\n' "$inc"
  fi
}
# Servidor por omissão nas portas 80/443 quando há domínios (pedidos com nomes desconhecidos são recusados)
ngx_default_sync(){
  local any=0 p80=0 n l6="" l6s=""
  install -d -m 755 "$NGX_CONFD" "$ACME_ROOT"
  [ -n "$(srv_get PANEL_DOMAIN '')" ] && any=1
  for n in $(site_names); do
    [ -n "$(site_get "$n" DOMAINS)" ] && any=1
    [ "$(site_get "$n" PORT)" = 80 ] && [ "$(site_get "$n" ENABLED)" = 1 ] && p80=1
  done
  [ "${IPV6:-0}" = 1 ] && { l6="    listen [::]:80 default_server;"; l6s="    listen [::]:443 ssl http2 default_server;"; }
  if [ "$any" = 0 ]; then rm -f "$NGX_CONFD/default.conf"; return 0; fi
  {
    echo "# IDDigital Hosting — servidor por omissão (gerado pelo painel)"
    if [ "$p80" = 0 ]; then printf 'server {\n    listen 80 default_server;\n%s\n    server_name _;\n' "$l6"; acme_loc; printf '    location / { return 444; }\n}\n'; fi
    printf 'server {\n    listen 443 ssl http2 default_server;\n%s\n    server_name _;\n    ssl_certificate     /etc/minipainel/ssl/panel.crt;\n    ssl_certificate_key /etc/minipainel/ssl/panel.key;\n    return 444;\n}\n' "$l6s"
  } > "$NGX_CONFD/default.conf"
  chmod 644 "$NGX_CONFD/default.conf"
}
ports_web_open(){ local p; for p in 80 443; do fw_open "$p" >/dev/null 2>&1; done; return 0; }

# Domínio do painel (porta 443), com o mesmo conteúdo do painel na porta própria
panel_domain_write(){
  local d ssl cf l6="" l6s=""
  d=$(srv_get PANEL_DOMAIN ''); ssl=$(srv_get PANEL_SSL le)
  if [ -z "$d" ]; then rm -f "$NGX_CONFD/panel-domain.conf"; return 0; fi
  [ "${IPV6:-0}" = 1 ] && { l6="    listen [::]:80;"; l6s="    listen [::]:443 ssl http2;"; }
  cf=$(cert_files mp-painel) || cf="/etc/minipainel/ssl/panel.crt /etc/minipainel/ssl/panel.key"
  {
    printf '# IDDigital Hosting — painel em %s (gerado pelo painel)\nserver {\n    listen 80;\n%s\n    server_name %s;\n' "$d" "$l6" "$d"
    acme_loc
    printf '    location / { return 301 https://$host$request_uri; }\n}\n'
    printf 'server {\n    listen 443 ssl http2;\n%s\n    server_name %s;\n    ssl_certificate     %s;\n    ssl_certificate_key %s;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_session_cache shared:MPSSL:1m;\n    include /etc/nginx/minipainel/panel.inc;\n}\n' "$l6s" "$d" "${cf%% *}" "${cf##* }"
  } > "$NGX_CONFD/panel-domain.conf"
  chmod 644 "$NGX_CONFD/panel-domain.conf"
}

