# ============================ FTP / FTPS / SFTP ==============================
FTP_CONF=/etc/minipainel/ftp.conf          # PLAIN=0|1, PASV_IP=, PASV=30000:30100
PF_PASSWD=/etc/pure-ftpd/pureftpd.passwd
PF_PDB=/etc/pure-ftpd/pureftpd.pdb
SFTP_ROOT=/srv/sftp
ftp_get(){ local v; v=$(grep -m1 "^$1=" "$FTP_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
ftp_set(){ touch "$FTP_CONF"; chmod 600 "$FTP_CONF"; if grep -q "^$1=" "$FTP_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$FTP_CONF"; else echo "$1=$2" >> "$FTP_CONF"; fi; }
ftp_svc(){ systemctl list-unit-files pure-ftpd.service >/dev/null 2>&1 && echo pure-ftpd || echo pure-ftpd; }
ssh_svc(){ if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh.service'; then echo ssh; else echo sshd; fi; }
ftp_installed(){ command -v pure-pw >/dev/null 2>&1; }
pf_set(){ # opção valor (Debian: um ficheiro por opção; EL: pure-ftpd.conf)
  if [ -d /etc/pure-ftpd/conf ]; then printf '%s\n' "$2" > "/etc/pure-ftpd/conf/$1"
  else
    local f=/etc/pure-ftpd/pure-ftpd.conf
    if grep -qE "^#?\s*$1\s" "$f"; then sed -i -E "s|^#?\s*$1\s.*|$1 $2|" "$f"; else echo "$1 $2" >> "$f"; fi
  fi
}
ftp_cert(){ # certificado para o FTPS (o do servidor de correio, do domínio do painel ou o autoassinado)
  local c pem
  c=$(cert_files mp-mail 2>/dev/null || cert_files mp-painel 2>/dev/null || echo "/etc/minipainel/ssl/panel.crt /etc/minipainel/ssl/panel.key")
  if [ -d /etc/pure-ftpd/conf ]; then pem=/etc/ssl/private/pure-ftpd.pem; else pem=/etc/pki/pure-ftpd/pure-ftpd.pem; install -d -m 700 /etc/pki/pure-ftpd; fi
  cat "${c##* }" "${c%% *}" > "$pem.tmp" && chmod 600 "$pem.tmp" && mv -f "$pem.tmp" "$pem"
}
ftp_fw(){
  local r; r=$(ftp_get PASV 30000:30100)
  fw_open 21 >/dev/null 2>&1
  if systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd -q --permanent --add-port="${r/:/-}/tcp" >/dev/null 2>&1; firewall-cmd -q --add-port="${r/:/-}/tcp" >/dev/null 2>&1
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then ufw allow "$r/tcp" >/dev/null 2>&1; fi
  return 0
}
ftp_config(){ # (re)aplica a configuração do Pure-FTPd e do SFTP
  local r ip
  r=$(ftp_get PASV 30000:30100); ip=$(ftp_get PASV_IP)
  pf_set ChrootEveryone yes; pf_set NoAnonymous yes; pf_set PureDB "$PF_PDB"; pf_set MinUID 100
  pf_set PassivePortRange "${r/:/ }"; pf_set DontResolve yes; pf_set MaxClientsPerIP 8; pf_set MaxClientsNumber 50
  if [ -d /etc/pure-ftpd/conf ]; then pf_set Umask "137 027"; else pf_set Umask "137:027"; fi
  pf_set ProhibitDotFilesWrite no; pf_set ProhibitDotFilesRead no
  pf_set TLS "$([ "$(ftp_get PLAIN 0)" = 1 ] && echo 1 || echo 2)"
  if [ -n "$ip" ]; then pf_set ForcePassiveIP "$ip"; else
    if [ -d /etc/pure-ftpd/conf ]; then rm -f /etc/pure-ftpd/conf/ForcePassiveIP; else sed -i -E 's|^ForcePassiveIP .*|# ForcePassiveIP|' /etc/pure-ftpd/pure-ftpd.conf; fi
  fi
  if [ -d /etc/pure-ftpd/auth ]; then
    rm -f /etc/pure-ftpd/auth/*unix /etc/pure-ftpd/auth/*pam /etc/pure-ftpd/auth/*PAM /etc/pure-ftpd/auth/*Unix 2>/dev/null
    ln -sfn ../conf/PureDB /etc/pure-ftpd/auth/50pure
    pf_set UnixAuthentication no; pf_set PAMAuthentication no
  else
    sed -i -E 's|^#?\s*PAMAuthentication\s.*|PAMAuthentication no|; s|^#?\s*UnixAuthentication\s.*|UnixAuthentication no|' /etc/pure-ftpd/pure-ftpd.conf
  fi
  ftp_cert
  touch "$PF_PASSWD"; chmod 600 "$PF_PASSWD"; pure-pw mkdb "$PF_PDB" -f "$PF_PASSWD" >/dev/null 2>&1
  # SFTP: utilizadores do grupo mp-sftp ficam fechados na pasta do site e só podem transferir ficheiros
  getent group mp-sftp >/dev/null 2>&1 || groupadd -r mp-sftp
  install -d -o root -g root -m 755 "$SFTP_ROOT"
  install -d -m 755 /etc/ssh/sshd_config.d
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  cat > /etc/ssh/sshd_config.d/10-minipainel-sftp.conf <<'EOF'
# IDDigital Hosting — SFTP dos sites (gerado pelo painel; não editar à mão)
Match Group mp-sftp
    ChrootDirectory /srv/sftp/%u
    ForceCommand internal-sftp -d /site -u 0027
    PasswordAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
Match all
EOF
  chmod 644 /etc/ssh/sshd_config.d/10-minipainel-sftp.conf
  if sshd -t 2>/dev/null; then systemctl reload "$(ssh_svc)" >/dev/null 2>&1
  else rm -f /etc/ssh/sshd_config.d/10-minipainel-sftp.conf; warn "A configuração do SSH ficou inválida; o SFTP não foi ativado."; fi
  systemctl enable "$(ftp_svc)" >/dev/null 2>&1; systemctl restart "$(ftp_svc)" >/dev/null 2>&1
  ftp_fw
}
ftp_install(){
  ftp_installed && return 0
  echo "A instalar o Pure-FTPd..."
  if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q pure-ftpd >/dev/null 2>&1
  else dnf install -y -q pure-ftpd >/dev/null 2>&1; fi
  ftp_installed || die "Falhou a instalação do Pure-FTPd."
  [ -f "$FTP_CONF" ] || printf 'PLAIN=0\nPASV=30000:30100\nPASV_IP=\n' > "$FTP_CONF"
  ftp_config
}
ftp_bind(){ # site on|off — a pasta do site aparece dentro da prisão do SFTP
  local n=$1 u="mp_$1" d="$SFTP_ROOT/mp_$1"
  if [ "$2" = on ]; then
    install -d -o root -g root -m 755 "$d" "$d/site"
    grep -q " $d/site " /etc/fstab || echo "$WWW_ROOT/$n $d/site none bind,nofail 0 0 # minipainel-sftp" >> /etc/fstab
    mountpoint -q "$d/site" || mount --bind "$WWW_ROOT/$n" "$d/site"
    usermod -aG mp-sftp "$u" >/dev/null 2>&1
  else
    gpasswd -d "$u" mp-sftp >/dev/null 2>&1
    mountpoint -q "$d/site" && umount "$d/site"
    sed -i "\\| $d/site |d" /etc/fstab
    [ -d "$d/site" ] && rmdir "$d/site" 2>/dev/null; [ -d "$d" ] && rmdir "$d" 2>/dev/null
  fi
  return 0
}
cmd_site_ftp(){ # site --hash H | --password P | --off
  local n="${1:-}" h="" pw="" off=0 u uid gid
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  while [ $# -gt 0 ]; do
    case "$1" in
      --hash) h="${2:-}"; shift 2 || shift ;;
      --password) pw="${2:-}"; shift 2 || shift ;;
      --off) off=1; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  u="mp_$n"
  if [ "$off" = 1 ]; then
    [ -f "$PF_PASSWD" ] && { grep -v "^$n:" "$PF_PASSWD" > "$PF_PASSWD.tmp"; mv -f "$PF_PASSWD.tmp" "$PF_PASSWD"; chmod 600 "$PF_PASSWD"; pure-pw mkdb "$PF_PDB" -f "$PF_PASSWD" >/dev/null 2>&1; }
    ftp_bind "$n" off
    usermod -p '!' "$u" >/dev/null 2>&1
    site_set "$n" FTP 0
    echo "Acesso FTP/SFTP do site $n desativado."
    return 0
  fi
  if [ -n "$pw" ]; then [ ${#pw} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."; h=$(printf '%s' "$pw" | mail_hash_stdin); fi
  local gen=""
  if [ -z "$h" ]; then gen=$(gen_pass 16); h=$(printf '%s' "$gen" | mail_hash_stdin); fi
  valid_mailhash "$h" || die "Hash de password inválido."
  ftp_install
  uid=$(id -u "$u"); gid=$(id -g "$u")
  touch "$PF_PASSWD"
  { grep -v "^$n:" "$PF_PASSWD"; printf '%s:%s:%s:%s::%s/./::::::::::::\n' "$n" "$h" "$uid" "$gid" "$WWW_ROOT/$n"; } > "$PF_PASSWD.tmp"
  mv -f "$PF_PASSWD.tmp" "$PF_PASSWD"; chmod 600 "$PF_PASSWD"
  pure-pw mkdb "$PF_PDB" -f "$PF_PASSWD" >/dev/null 2>&1 || die "Não foi possível atualizar a base de utilizadores do FTP."
  printf '%s:%s\n' "$u" "$h" | chpasswd -e >/dev/null 2>&1 || die "Não foi possível definir a password do SFTP."
  ftp_bind "$n" on
  site_set "$n" FTP 1
  local host; host=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "Acesso ao site $n ativo."
  echo "FTPS: servidor $host, porta 21, utilizador $n (FTP com TLS explícito$([ "$(ftp_get PLAIN 0)" = 1 ] && echo '; FTP simples também permitido'))."
  echo "SFTP: servidor $host, porta 22, utilizador $u."
  [ -n "$gen" ] && echo "Password: $gen"
  return 0
}
cmd_ftp_settings(){
  local re_ip='^[0-9.]+$'
  while [ $# -gt 0 ]; do
    case "$1" in
      --plain) case "${2:-}" in on) ftp_set PLAIN 1 ;; off) ftp_set PLAIN 0 ;; *) die "--plain on|off" ;; esac; shift 2 || shift ;;
      --pasv-ip) [ "${2:-}" = none ] && ftp_set PASV_IP "" || { [[ "${2:-}" =~ $re_ip ]] && fw_ip_valid "$2" || die "IP inválido."; ftp_set PASV_IP "$2"; }; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  ftp_installed && ftp_config
  echo "Definições do FTP guardadas."
  return 0
}

