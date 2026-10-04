cmd_pma_update(){
  local force=0 latest cur tmp url want got
  [ "${1:-}" = "--force" ] && force=1
  id "$PMA_USER" >/dev/null 2>&1 || die "Utilizador $PMA_USER em falta; volta a correr o instalador."
  latest=$(curl -fsSL --max-time 30 https://www.phpmyadmin.net/home_page/version.txt 2>/dev/null | head -n1 | tr -d '\r')
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Não foi possível obter a versão do phpMyAdmin (sem acesso a phpmyadmin.net?)."
  cur=$(pma_version)
  if [ "$cur" = "$latest" ] && [ "$force" = 0 ]; then
    pma_fix_config
    echo "O phpMyAdmin já está na versão mais recente ($cur)."
    return 0
  fi
  tmp=$(mktemp -d /var/tmp/mp-pma.XXXXXX) || die "Não foi possível criar pasta temporária."
  url="https://files.phpmyadmin.net/phpMyAdmin/$latest/phpMyAdmin-$latest-all-languages.tar.gz"
  if ! curl -fsSL --max-time 600 -o "$tmp/pma.tgz" "$url" || ! curl -fsSL --max-time 30 -o "$tmp/pma.sha256" "$url.sha256"; then
    rm -rf "$tmp"; die "Falha no download do phpMyAdmin $latest."
  fi
  want=$(awk '{print $1; exit}' "$tmp/pma.sha256")
  got=$(sha256sum "$tmp/pma.tgz" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then rm -rf "$tmp"; die "O SHA-256 do phpMyAdmin $latest não confere; nada foi alterado."; fi
  mkdir "$tmp/x"
  if ! tar xzf "$tmp/pma.tgz" -C "$tmp/x" --strip-components=1 || [ ! -f "$tmp/x/index.php" ]; then
    rm -rf "$tmp"; die "O pacote do phpMyAdmin não é válido; nada foi alterado."
  fi
  rm -rf "$tmp/x/setup" "$tmp/x/examples" "$tmp/x/test"
  pma_write_config
  cp -p "$PMA_CONF" "$tmp/x/config.inc.php"
  echo "$latest" > "$tmp/x/.mp-version"
  chown -R root:root "$tmp/x"
  find "$tmp/x" -type d -exec chmod 755 {} +
  find "$tmp/x" -type f -exec chmod 644 {} +
  chown root:"$PMA_USER" "$tmp/x/config.inc.php"; chmod 640 "$tmp/x/config.inc.php"
  rm -rf "$PMA_DIR.new" "$PMA_DIR.old"
  mv "$tmp/x" "$PMA_DIR.new" || { rm -rf "$tmp" "$PMA_DIR.new"; die "Falha ao copiar o phpMyAdmin."; }
  if [ -d "$PMA_DIR" ]; then mv "$PMA_DIR" "$PMA_DIR.old"; fi
  if ! mv "$PMA_DIR.new" "$PMA_DIR"; then
    if [ -d "$PMA_DIR.old" ]; then mv "$PMA_DIR.old" "$PMA_DIR"; fi
    rm -rf "$tmp" "$PMA_DIR.new"; die "Falha ao instalar o phpMyAdmin; a versão anterior foi reposta."
  fi
  se_restore "$PMA_DIR"
  rm -rf "$PMA_DIR.old" "$tmp"
  if [ -n "$cur" ]; then echo "phpMyAdmin atualizado de $cur para $latest."; else echo "phpMyAdmin $latest instalado."; fi
  return 0
}

cmd_db_admin_passwd(){
  local pw="${1:-}"
  if [ -z "$pw" ]; then pw=$(gen_pass 24)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  if dbuser_exists "$DB_ADMIN"; then
    db_exec "ALTER USER '$DB_ADMIN'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || die "Falha ao alterar a password de $DB_ADMIN."
    echo "Password da conta de administração alterada."
  else
    db_exec "CREATE USER '$DB_ADMIN'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON *.* TO '$DB_ADMIN'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;" || { db_exec "DROP USER IF EXISTS '$DB_ADMIN'@'localhost';" >/dev/null 2>&1; die "Falha ao criar a conta $DB_ADMIN."; }
    echo "Conta de administração criada (acesso a todas as bases de dados, só a partir de localhost)."
  fi
  printf 'Utilizador: %s\nPassword: %s\n' "$DB_ADMIN" "$pw"
  return 0
}

# ---------- comandos: sistema ----------
cmd_php_list(){
  local v n c
  printf '%-8s %-10s %-6s %s\n' VERSAO ESTADO SITES ""
  for v in $(php_installed); do
    c=0
    for n in $(site_names); do [ "$(site_get "$n" PHP)" = "$v" ] && c=$((c+1)); done
    printf '%-8s %-10s %-6s %s\n' "$v" "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)" "$c" \
      "$([ "$v" = "$DEFAULT_PHP" ] && echo '(predefinida)')"
  done
  return 0
}

cmd_status(){
  local v
  printf '%-26s %s\n' nginx "$(systemctl is-active nginx 2>/dev/null)"
  printf '%-26s %s\n' mariadb "$(systemctl is-active mariadb 2>/dev/null)"
  for v in $(php_installed); do
    printf '%-26s %s\n' "$(php_service "$v")" "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)"
  done
  printf '%-26s %s\n' minipainel-worker.path "$(systemctl is-active minipainel-worker.path 2>/dev/null)"
  echo
  echo "Painel: https://<IP-do-servidor>:$PANEL_PORT   PHP predefinido: $DEFAULT_PHP   Sites: $(site_names | wc -l)"
  return 0
}

cmd_service(){
  local id="${1:-}" act="${2:-}" unit name v="" out label
  case "$act" in
    reload) label=recarregado ;; restart) label=reiniciado ;; start) label=iniciado ;; stop) label=parado ;;
    *) die "Ação inválida: usa reload, restart, start ou stop." ;;
  esac
  case "$id" in
    nginx)   unit=nginx;   name=nginx ;;
    mariadb) unit=mariadb; name=MariaDB ;;
    php-*)   v="${id#php-}"; php_is_installed "$v" || die "PHP $v não está instalado."
             unit=$(php_service "$v"); name="PHP-FPM $v" ;;
    postfix|dovecot|rspamd|unbound) mail_on || die "O email não está ativo."; unit=$id; name=$id ;;
    redis) mail_on || die "O email não está ativo."; unit=$(mail_svc_redis); name=Redis ;;
    clamav) [ "$(mail_get CLAMAV 0)" = 1 ] || die "O antivírus não está ativo."; unit=clamav-daemon; systemctl list-unit-files clamd@.service >/dev/null 2>&1 && [ "$OS_FAMILY" != debian ] && unit=clamd@scan; name=ClamAV ;;
    *) die "Serviço desconhecido: $id (nginx, mariadb ou php-X.Y)." ;;
  esac
  if [ "$act" = stop ]; then
    [ "$id" = nginx ] && die "Parar o nginx deixaria o painel inacessível. Usa restart."
    [ "$id" = mariadb ] && die "Parar o MariaDB deixaria todos os sites sem base de dados. Usa restart."
    [ "$v" = "$PANEL_PHP" ] && die "O PHP $v é usado pelo próprio painel e não pode ser parado."
  fi
  [ "$id" = mariadb ] && [ "$act" = reload ] && die "O MariaDB não suporta recarregar. Usa restart."
  if [ "$act" = reload ] && ! systemctl is-active --quiet "$unit"; then die "$name não está a correr. Usa start."; fi
  if [ "$act" != stop ]; then
    if [ "$id" = nginx ]; then
      out=$(nginx -t 2>&1) || { echo "$out" >&2; die "Configuração do nginx inválida; nada foi feito."; }
    elif [ -n "$v" ]; then
      out=$("$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" 2>&1) || { echo "$out" >&2; die "Configuração do PHP-FPM $v inválida; nada foi feito."; }
    fi
  fi
  systemctl "$act" "$unit" >/dev/null 2>&1 || die "Falha ao executar '$act' em $unit (ver: journalctl -u $unit -n 30)."
  if [ "$act" != stop ]; then
    sleep 1
    systemctl is-active --quiet "$unit" || die "$name não ficou ativo (ver: journalctl -u $unit -n 30)."
  fi
  echo "$name $label."
  [ "$act" = stop ] && echo "Volta a arrancar automaticamente no próximo reinício do servidor."
  return 0
}

# ---------- firewall: ligações e bloqueio de IPs (nftables, tabela própria) ----------
FW_BLOCKS=/etc/minipainel/blocks.list   # ip|expira (epoch, 0 = permanente)|criado|origem|motivo
FW_ALLOW=/etc/minipainel/allow.list     # um IP ou rede por linha
FW_CONF=/etc/minipainel/firewall.conf   # AUTO, LIMIT, DURATION
FW_STATE=$DATA/stats/fw.json
FW_ADMIN=$DATA/logs/admin-ips.json      # IPs de onde o painel foi usado (escrito pelo painel)

