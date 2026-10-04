cmd_db_add(){
  local n="${1:-}" pw="" dsite=""
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --site) dsite="${2:-}"; shift 2 || shift ;;
      *) pw="$1"; shift ;;
    esac
  done
  if [ -n "$dsite" ]; then valid_site "$dsite" && site_exists "$dsite" || die "O site '$dsite' não existe."; fi
  valid_db "$n" || die "Nome inválido. Usa minúsculas, números e '_', a começar por letra (máx. 32)."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" && die "A base de dados '$n' já existe."
  dbuser_exists "$n" && die "O utilizador MariaDB '$n' já existe."
  if [ -z "$pw" ]; then pw=$(gen_pass 20)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  local ng="${n//_/\\_}"
  if ! db_exec "CREATE DATABASE \`$n\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$n'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$n'@'localhost';
FLUSH PRIVILEGES;"; then
    db_exec "DROP DATABASE IF EXISTS \`$n\`; DROP USER IF EXISTS '$n'@'localhost';" >/dev/null 2>&1
    die "Falha ao criar a base de dados '$n'."
  fi
  [ -n "$dsite" ] && dbmap_set "$n" "$dsite"
  printf 'Base de dados criada.\nServidor:      localhost (porta 3306)\nBase de dados: %s\nUtilizador:    %s\nPassword:      %s\n' "$n" "$n" "$pw"
  [ -n "$dsite" ] && echo "Associada ao site $dsite."
  return 0
}

cmd_db_del(){
  local n="${1:-}"
  valid_db "$n" || die "Nome inválido."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" || die "A base de dados '$n' não existe."
  db_exec "DROP DATABASE \`$n\`; DROP USER IF EXISTS '$n'@'localhost'; FLUSH PRIVILEGES;" || die "Falha ao apagar '$n'."
  dbmap_set "$n" ""
  echo "Base de dados '$n' e utilizador '$n' apagados."
  return 0
}

cmd_db_passwd(){
  local n="${1:-}" pw="${2:-}"
  valid_db "$n" || die "Nome inválido."
  dbuser_exists "$n" || die "O utilizador MariaDB '$n' não existe."
  if [ -z "$pw" ]; then pw=$(gen_pass 20)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  db_exec "ALTER USER '$n'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || die "Falha ao alterar a password."
  printf 'Password alterada.\nUtilizador: %s\nPassword:   %s\n' "$n" "$pw"
  return 0
}

# ---------- extensões PHP opcionais (por versão) ----------
# nome|sufixo Debian/Ubuntu (php<ver>-X)|sufixos Remi, alternativas separadas por vírgula (php<vv>-X)|descrição
ext_catalog(){
  cat <<'EOF'
apcu|apcu|php-pecl-apcu|Cache de dados em memória (APCu)
gmp|gmp|php-gmp|Aritmética de precisão arbitrária
igbinary|igbinary|php-pecl-igbinary|Serialização binária rápida
imagick|imagick|php-pecl-imagick-im7,php-pecl-imagick|Tratamento de imagens com ImageMagick
imap|imap|php-imap,php-pecl-imap|Acesso a caixas de correio IMAP
ldap|ldap|php-ldap|Autenticação LDAP e Active Directory
memcached|memcached|php-pecl-memcached|Cliente Memcached
mongodb|mongodb|php-pecl-mongodb|Cliente MongoDB
pgsql|pgsql|php-pgsql|Ligação a PostgreSQL
redis|redis|php-pecl-redis6,php-pecl-redis5|Cliente Redis
ssh2|ssh2|php-pecl-ssh2|Ligações SSH e SFTP
tidy|tidy|php-tidy|Limpeza e correção de HTML
xdebug|xdebug|php-pecl-xdebug3,php-pecl-xdebug|Depuração; só para desenvolvimento (torna o PHP mais lento)
yaml|yaml|php-pecl-yaml|Leitura e escrita de YAML
EOF
}
ext_known(){ local re='^[a-z0-9_]{2,20}$'; [[ "$1" =~ $re ]] && [ -n "$(ext_catalog | grep -m1 "^$1|")" ]; }
ext_pkgs(){
  local line en deb remi ed a
  line=$(ext_catalog | grep -m1 "^$1|")
  [ -n "$line" ] || return 1
  IFS='|' read -r en deb remi ed <<<"$line"
  if [ "$OS_FAMILY" = debian ]; then
    echo "php$2-$deb"
  else
    local IFS=,
    for a in $remi; do echo "php$(php_vv "$2")-$a"; done
  fi
}
PKG_CACHE=""
pkg_cache_load(){
  if [ "$OS_FAMILY" = debian ]; then
    PKG_CACHE=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | awk '$2=="installed"{print $1}')
  else
    PKG_CACHE=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null)
  fi
}
pkg_has(){ [[ $'\n'"$PKG_CACHE"$'\n' == *$'\n'"$1"$'\n'* ]]; }
ext_installed_pkg(){ local c; for c in $(ext_pkgs "$1" "$2"); do if pkg_has "$c"; then echo "$c"; return 0; fi; done; return 1; }
sys_pkg_install(){
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends "$1" && return 0
    apt-get -o DPkg::Lock::Timeout=180 update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends "$1"
  else
    dnf install -y -q "$1"
  fi
}
sys_pkg_remove(){
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 remove -y -q "$1"
  else
    dnf remove -y -q "$1"
  fi
}

cmd_ext_list(){
  local v="${1:-}" vs x en d
  if [ -n "$v" ]; then php_is_installed "$v" || die "PHP $v não está instalado."; vs="$v"; else vs=$(php_installed); fi
  pkg_cache_load
  for v in $vs; do
    echo "PHP $v"
    while IFS='|' read -r en _ _ d; do
      if ext_installed_pkg "$en" "$v" >/dev/null; then x=instalada; else x=-; fi
      printf '  %-11s %-10s %s\n' "$en" "$x" "$d"
    done < <(ext_catalog)
  done
  return 0
}

