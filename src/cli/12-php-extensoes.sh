cmd_ext_add(){
  local v="${1:-}" x="${2:-}" p out okp=""
  php_is_installed "$v" || die "PHP $v não está instalado."
  ext_known "$x" || die "Extensão desconhecida: $x (usa 'mpanel ext-list')."
  pkg_cache_load
  ext_installed_pkg "$x" "$v" >/dev/null && die "A extensão $x já está instalada no PHP $v."
  for p in $(ext_pkgs "$x" "$v"); do
    if out=$(sys_pkg_install "$p" 2>&1); then okp=$p; break; fi
  done
  if [ -z "$okp" ]; then
    echo "$out" | tail -n 4 >&2
    die "Não foi possível instalar $x para o PHP $v (pacote indisponível nesta distribuição?)."
  fi
  apply_php "$v" || die "A extensão foi instalada, mas o PHP-FPM $v não recarregou. Verifica: $(php_fpm_bin "$v") -t"
  echo "Extensão $x instalada no PHP $v ($okp)."
  return 0
}

cmd_ext_del(){
  local v="${1:-}" x="${2:-}" p others out
  php_is_installed "$v" || die "PHP $v não está instalado."
  ext_known "$x" || die "Extensão desconhecida: $x"
  pkg_cache_load
  p=$(ext_installed_pkg "$x" "$v") || die "A extensão $x não está instalada no PHP $v."
  if [ "$OS_FAMILY" = debian ]; then
    others=$(apt-get -s remove "$p" 2>/dev/null | awk -v p="$p" '/^Remv /{ if ($2 != p) printf "%s ", $2 }')
  else
    others=$(rpm -e --test "$p" 2>&1 | awk '/is needed by/{ printf "%s ", $NF }')
  fi
  if [ -n "${others// /}" ]; then
    die "Remover $x também removeria: $others. Remove primeiro essas extensões ou mantém $x."
  fi
  out=$(sys_pkg_remove "$p" 2>&1) || { echo "$out" | tail -n 4 >&2; die "Não foi possível remover $x do PHP $v."; }
  apply_php "$v" || die "A extensão foi removida, mas o PHP-FPM $v não recarregou. Verifica: $(php_fpm_bin "$v") -t"
  echo "Extensão $x removida do PHP $v."
  return 0
}

# ---------- phpMyAdmin e conta de administração ----------
pma_version(){ if [ -f "$PMA_DIR/.mp-version" ]; then cat "$PMA_DIR/.mp-version"; fi; }
pma_write_config(){
  if [ ! -s "$PMA_CONF" ]; then
    cat > "$PMA_CONF" <<EOF
<?php
/* MiniPainel — configuração do phpMyAdmin (copiada para $PMA_DIR em cada atualização) */
declare(strict_types=1);
\$cfg['blowfish_secret'] = '$(gen_pass 32)';
\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = false;
\$cfg['TempDir'] = '/var/lib/minipainel-pma/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['VersionCheck'] = false;
\$cfg['SendErrorReports'] = 'never';
\$cfg['LoginCookieValidity'] = 7200;
\$cfg['DefaultLang'] = 'pt';
EOF
  fi
  chown root:"$PMA_USER" "$PMA_CONF"
  chmod 640 "$PMA_CONF"
}

# Garante que o config.inc.php existe e é legível pelo pool do phpMyAdmin
pma_fix_config(){
  [ -d "$PMA_DIR" ] || return 0
  pma_write_config
  pma_settings_apply
  se_restore "$PMA_DIR/config.inc.php"
}

