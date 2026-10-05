# =============================== EMAIL ======================================
MAIL_CONF=/etc/minipainel/mail.conf
MAIL_DATA=/etc/minipainel/mail/data.json      # {domains:{}, boxes:{}, aliases:{}}
VMAIL=/var/mail/vhosts
PF_MP=/etc/postfix/mp
DV_USERS=/etc/dovecot/mp-users
MSPOOL=/var/spool/mp-mail                      # envio dos sites (escrito pelos sites)
MLIB=/var/lib/minipainel/mail                  # contadores, retidos e rejeitados (só root)
RSPAMD_LOCAL=/etc/rspamd/local.d
DKIM_DIR=/var/lib/rspamd/dkim
mail_get(){ local v; v=$(grep -m1 "^$1=" "$MAIL_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
mail_set(){
  install -d -m 755 /etc/minipainel; touch "$MAIL_CONF"; chmod 600 "$MAIL_CONF"
  if grep -q "^$1=" "$MAIL_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$MAIL_CONF"; else echo "$1=$2" >> "$MAIL_CONF"; fi
}
mail_on(){ [ "$(mail_get ENABLED 0)" = 1 ]; }
conf_lock(){ # ficheiros de configuração sem segredos mas com informação útil a um atacante: só root
  local f; for f in /etc/minipainel/minipainel.conf /etc/minipainel/server.conf /etc/minipainel/mail.conf /etc/minipainel/ftp.conf \
    /etc/minipainel/pma.conf /etc/minipainel/firewall.conf /etc/minipainel/update.conf /etc/minipainel/backup-remotes.json; do [ -f "$f" ] && chmod 600 "$f"; done
  if [ "$(mail_get ENABLED 0)" = 1 ]; then : > /etc/minipainel/mail-enabled; chmod 644 /etc/minipainel/mail-enabled; else rm -f /etc/minipainel/mail-enabled; fi
  return 0
}
mail_need(){ mail_on || die "O email não está ativo. Ativa-o na página Email ou com: mpanel mail-enable --host mail.dominio.pt"; }
mail_data(){ if [ -s "$MAIL_DATA" ]; then cat "$MAIL_DATA"; else echo '{"domains":{},"boxes":{},"aliases":{}}'; fi; }
mail_data_save(){
  install -d -m 700 "$(dirname "$MAIL_DATA")"
  printf '%s\n' "$1" | jq '.' > "$MAIL_DATA.tmp" && chmod 600 "$MAIL_DATA.tmp" && mv -f "$MAIL_DATA.tmp" "$MAIL_DATA"
}
valid_email(){ local re='^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'; [[ "$1" =~ $re ]]; }
valid_mailhash(){ local re='^\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$'; [[ "$1" =~ $re ]]; }
mail_hash_stdin(){ "$(php_cli "$PANEL_PHP")" -r 'echo crypt(rtrim(stream_get_contents(STDIN), "\n"), "\$6\$" . substr(strtr(base64_encode(random_bytes(12)), "+", "."), 0, 16) . "\$");'; }
mail_svc_redis(){ if systemctl list-unit-files redis-server.service >/dev/null 2>&1 && systemctl list-unit-files redis-server.service | grep -q redis-server; then echo redis-server; else echo redis; fi; }
mail_cert(){ cert_files mp-mail || echo "/etc/minipainel/ssl/panel.crt /etc/minipainel/ssl/panel.key"; }

# --- recursivo DNS local (as listas negras não respondem a resolvers públicos) ---
mail_resolver_setup(){
  install -d -m 755 /etc/unbound/unbound.conf.d
  cat > /etc/unbound/unbound.conf.d/minipainel.conf <<'EOF'
# IDDigital Hosting — resolver local para o antispam (listas negras)
server:
    interface: 127.0.0.1
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    prefetch: yes
EOF
  if [ -d /etc/unbound/unbound.conf.d ] && ! grep -q 'unbound.conf.d' /etc/unbound/unbound.conf 2>/dev/null; then
    echo 'include: "/etc/unbound/unbound.conf.d/*.conf"' >> /etc/unbound/unbound.conf
  fi
  if [ ! -s /var/lib/unbound/root.key ]; then
    install -d -m 755 /var/lib/unbound
    command -v unbound-anchor >/dev/null 2>&1 && timeout 30 unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1
    [ -s /var/lib/unbound/root.key ] || cp /usr/share/dns/root.key /var/lib/unbound/root.key 2>/dev/null
    chown unbound:unbound /var/lib/unbound /var/lib/unbound/root.key 2>/dev/null
  fi
  systemctl enable --now unbound >/dev/null 2>&1; systemctl restart unbound >/dev/null 2>&1
  # só muda o resolver do sistema se o unbound estiver mesmo a responder
  if ! mail_unbound_ok; then
    warn "O Unbound não está a responder em 127.0.0.1; o resolver do sistema não foi alterado (as listas negras podem não funcionar)."
    return 0
  fi
  if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    install -d -m 755 /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=127.0.0.1\nDomains=~.\n' > /etc/systemd/resolved.conf.d/minipainel.conf
    systemctl restart systemd-resolved >/dev/null 2>&1
  else
    if [ -d /etc/NetworkManager/conf.d ]; then printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-minipainel-dns.conf; systemctl reload NetworkManager >/dev/null 2>&1; fi
    [ -f /etc/resolv.conf.minipainel ] || cp -pL /etc/resolv.conf /etc/resolv.conf.minipainel 2>/dev/null
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    printf '# IDDigital Hosting — resolver local (unbound); original em /etc/resolv.conf.minipainel\nnameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf
  fi
}

mail_unbound_ok(){ local i; for i in 1 2 3 4 5 6; do dig +short +time=2 +tries=1 @127.0.0.1 . NS 2>/dev/null | grep -q . && return 0; sleep 1; done; return 1; }
mail_dnsbl_sites(){ # para o postscreen
  local own s out="zen.spamhaus.org=127.0.0.[2..11]*3, b.barracudacentral.org=127.0.0.2*2, bl.spamcop.net*1, psbl.surriel.com*1"
  own=$(mail_get DNSBL "dnsbl.3rhost.pt")
  for s in $own; do out+=", $s*3"; done
  echo "$out"
}
mail_postfix_config(){
  local h c ip6=all cf kf
  h=$(mail_get HOST); c=$(mail_cert); cf=${c%% *}; kf=${c##* }
  [ "${IPV6:-0}" = 1 ] || ip6=ipv4
  install -d -m 755 "$PF_MP"
  [ -s /etc/postfix/main.cf ] || printf '# IDDigital Hosting — Postfix (gerido pelo painel com postconf)\n' > /etc/postfix/main.cf
  printf '/^mp_/ x\n' > "$PF_MP/site_users"
  postconf -e "myhostname = $h" "myorigin = \$myhostname" "mydestination = \$myhostname, localhost" "mynetworks = 127.0.0.0/8 [::1]/128" \
    "inet_interfaces = all" "inet_protocols = $ip6" "smtpd_banner = \$myhostname ESMTP" "biff = no" "append_dot_mydomain = no" \
    "virtual_mailbox_domains = texthash:$PF_MP/vdomains" "virtual_mailbox_maps = texthash:$PF_MP/vmailbox" \
    "virtual_alias_maps = texthash:$PF_MP/valias" "virtual_transport = lmtp:unix:private/dovecot-lmtp" \
    "smtpd_sasl_type = dovecot" "smtpd_sasl_path = private/auth" "smtpd_sasl_auth_enable = no" \
    "smtpd_sender_login_maps = texthash:$PF_MP/sender_login" \
    "smtpd_tls_cert_file = $cf" "smtpd_tls_key_file = $kf" "smtpd_tls_security_level = may" "smtpd_tls_auth_only = yes" \
    "smtpd_tls_protocols = >=TLSv1.2" "smtpd_tls_mandatory_protocols = >=TLSv1.2" "smtp_tls_security_level = may" "smtp_tls_protocols = >=TLSv1.2" \
    "smtpd_helo_required = yes" "disable_vrfy_command = yes" "strict_rfc821_envelopes = yes" \
    "smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname" \
    "smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain" \
    "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination" \
    "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_non_fqdn_recipient, reject_unknown_recipient_domain" \
    "milter_protocol = 6" "milter_default_action = accept" "milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}" \
    "smtpd_milters = inet:127.0.0.1:11332" "non_smtpd_milters = inet:127.0.0.1:11332" \
    "message_size_limit = 52428800" "mailbox_size_limit = 0" "recipient_delimiter = +" \
    "authorized_submit_users = !regexp:$PF_MP/site_users, static:anyone" \
    "postscreen_access_list = permit_mynetworks" "postscreen_dnsbl_sites = $(mail_dnsbl_sites)" \
    "postscreen_dnsbl_threshold = 3" "postscreen_dnsbl_action = enforce" "postscreen_greet_action = enforce" \
    "postscreen_pipelining_enable = no" "postscreen_non_smtp_command_enable = no" "postscreen_bare_newline_enable = no" \
    "smtpd_client_connection_rate_limit = 30" "smtpd_client_message_rate_limit = 100" "anvil_rate_time_unit = 60s" \
    "smtpd_client_auth_rate_limit = 10" "compatibility_level = 3.6"
  postconf -M "smtp/inet=smtp inet n - n - 1 postscreen" \
              "smtpd/pass=smtpd pass - - n - - smtpd" \
              "dnsblog/unix=dnsblog unix - - n - 0 dnsblog" \
              "tlsproxy/unix=tlsproxy unix - - n - 0 tlsproxy" \
              "submission/inet=submission inet n - n - - smtpd" \
              "smtps/inet=smtps inet n - n - - smtpd"
  local svc
  for svc in submission smtps; do
    postconf -P "$svc/inet/syslog_name=postfix/$svc" "$svc/inet/smtpd_sasl_auth_enable=yes" \
      "$svc/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject" \
      "$svc/inet/smtpd_sender_restrictions=reject_sender_login_mismatch,permit_sasl_authenticated,reject" \
      "$svc/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject" \
      "$svc/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject" \
      "$svc/inet/milter_macro_daemon_name=ORIGINATING"
  done
  postconf -P "submission/inet/smtpd_tls_security_level=encrypt" "smtps/inet/smtpd_tls_wrappermode=yes"
}
mail_dovecot_config(){
  local h c vu vg
  h=$(mail_get HOST); c=$(mail_cert); vu=$(id -u vmail); vg=$(id -g vmail)
  sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null
  install -d -m 755 /etc/dovecot/sieve
  cat > /etc/dovecot/sieve/mp-spam.sieve <<'EOF'
require ["fileinto", "mailbox"];
if anyof (header :contains "X-Spam" "Yes", header :contains "X-Spam-Status" "Yes") { fileinto :create "Junk"; stop; }
EOF
  cat > /etc/dovecot/conf.d/99-minipainel.conf <<EOF
# IDDigital Hosting — caixas de correio virtuais (gerado pelo painel; não editar à mão)
protocols = imap pop3 lmtp sieve
listen = *$([ "${IPV6:-0}" = 1 ] && echo ', ::')
ssl = required
ssl_cert = <${c%% *}
ssl_key = <${c##* }
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
disable_plaintext_auth = yes
auth_mechanisms = plain login
auth_verbose = yes
auth_failure_delay = 3 secs
mail_location = maildir:~/Maildir
mail_privileged_group = vmail
first_valid_uid = $vu
last_valid_uid = $vu
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%Lu $DV_USERS
}
userdb {
  driver = passwd-file
  args = username_format=%Lu $DV_USERS
  default_fields = uid=$vu gid=$vg home=$VMAIL/%Ld/%Ln
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
protocol lmtp {
  mail_plugins = \$mail_plugins quota sieve
  postmaster_address = postmaster@$h
}
protocol imap {
  mail_plugins = \$mail_plugins quota imap_quota
}
protocol pop3 {
  mail_plugins = \$mail_plugins quota
}
namespace inbox {
  mailbox Drafts {
    auto = subscribe
    special_use = \\Drafts
  }
  mailbox Junk {
    auto = subscribe
    special_use = \\Junk
  }
  mailbox Trash {
    auto = subscribe
    special_use = \\Trash
  }
  mailbox Sent {
    auto = subscribe
    special_use = \\Sent
  }
}
plugin {
  quota = maildir:Quota
  quota_rule = *:storage=1G
  quota_exceeded_message = A caixa de correio está cheia.
  sieve = file:~/sieve;active=~/.dovecot.sieve
  sieve_before = /etc/dovecot/sieve/mp-spam.sieve
}
EOF
  sievec /etc/dovecot/sieve/mp-spam.sieve >/dev/null 2>&1
  touch "$DV_USERS"; chown root:dovecot "$DV_USERS"; chmod 640 "$DV_USERS"
}
mail_rspamd_config(){
  install -d -m 755 "$RSPAMD_LOCAL"
  install -d -o _rspamd -g _rspamd -m 750 "$DKIM_DIR" 2>/dev/null || install -d -o rspamd -g rspamd -m 750 "$DKIM_DIR"
  printf 'bind_socket = "127.0.0.1:11332";\nmilter = yes;\ntimeout = 120s;\nupstream "local" {\n  default = yes;\n  self_scan = yes;\n}\n' > "$RSPAMD_LOCAL/worker-proxy.inc"
  printf 'bind_socket = "127.0.0.1:11333";\n' > "$RSPAMD_LOCAL/worker-normal.inc"
  if mail_unbound_ok; then printf 'dns {\n  nameserver = ["127.0.0.1:53:10"];\n}\nlocal_addrs = "127.0.0.0/8, ::1";\n' > "$RSPAMD_LOCAL/options.inc"
  else printf 'local_addrs = "127.0.0.0/8, ::1";\n' > "$RSPAMD_LOCAL/options.inc"; fi
  mail_secrets
  printf 'reject = 15;\nadd_header = 6;\ngreylist = 4;\n' > "$RSPAMD_LOCAL/actions.conf"
  printf 'enabled = true;\n' > "$RSPAMD_LOCAL/greylist.conf"
  printf 'path = "%s/$domain.$selector.key";\nselector = "mp";\nallow_username_mismatch = true;\nsign_local = true;\nsign_authenticated = true;\nuse_domain = "header";\nallow_hdrfrom_mismatch = false;\n' "$DKIM_DIR" > "$RSPAMD_LOCAL/dkim_signing.conf"
  cp "$RSPAMD_LOCAL/dkim_signing.conf" "$RSPAMD_LOCAL/arc.conf"
  printf 'use = ["x-spamd-bar", "x-spam-level", "x-spam-status", "authentication-results"];\nauthenticated_headers = ["authentication-results"];\n' > "$RSPAMD_LOCAL/milter_headers.conf"
  printf 'rates {\n  user = {\n    bucket = {\n      burst = 100;\n      rate = "%s / 1h";\n    }\n  }\n}\n' "$(mail_get BOX_LIMIT 200)" > "$RSPAMD_LOCAL/ratelimit.conf"
  {
    printf 'rbls {\n'
    local n=0 z
    for z in $(mail_get DNSBL "dnsbl.3rhost.pt"); do
      n=$((n + 1))
      printf '  mp_own_%s {\n    rbl = "%s";\n    ipv6 = false;\n    received = false;\n    symbol = "MP_OWN_DNSBL_%s";\n    description = "Lista negra própria (%s)";\n  }\n' "$n" "$z" "$n" "$z"
    done
    printf '}\n'
  } > "$RSPAMD_LOCAL/rbl.conf"
  {
    printf 'symbols {\n'
    local i
    for i in $(seq 1 "$(mail_get DNSBL "dnsbl.3rhost.pt" | wc -w)"); do printf '  "MP_OWN_DNSBL_%s" {\n    weight = 7.0;\n  }\n' "$i"; done
    printf '}\n'
  } > "$RSPAMD_LOCAL/rbl_group.conf"
  if [ "$(mail_get CLAMAV 0)" = 1 ]; then
    local sock=/run/clamav/clamd.ctl; [ -S /run/clamd.scan/clamd.sock ] && sock=/run/clamd.scan/clamd.sock
    printf 'clamav {\n  action = "reject";\n  message = "Vírus detetado: ${VIRUS}";\n  type = "clamav";\n  servers = "%s";\n  symbol = "CLAM_VIRUS";\n  scan_mime_parts = true;\n  max_size = 26214400;\n}\n' "$sock" > "$RSPAMD_LOCAL/antivirus.conf"
  else
    rm -f "$RSPAMD_LOCAL/antivirus.conf"
  fi
}
# Bloqueia a porta 25 de saída para tudo exceto o root e o Postfix: um site comprometido não envia spam diretamente.
mail_rspamd_user(){ if id _rspamd >/dev/null 2>&1; then echo _rspamd; else echo rspamd; fi; }
mail_fw_apply(){
  fw_has_nft || return 0
  nft delete table inet minipainel_mail >/dev/null 2>&1
  mail_on || return 0
  local pu ru vu du
  pu=$(id -u postfix 2>/dev/null) || return 0
  ru=$(id -u "$(mail_rspamd_user)" 2>/dev/null) || ru=$pu
  vu=$(id -u vmail 2>/dev/null) || vu=$pu
  du=$(id -u redis 2>/dev/null) || du=$ru
  # porta 25: só o root e o Postfix (um site comprometido não envia spam diretamente)
  # Redis e Rspamd: só os serviços de email lhes chegam (os sites não leem o histórico nem mexem no antispam)
  nft -f - <<EOF
table inet minipainel_mail {
  chain output {
    type filter hook output priority 0; policy accept;
    tcp dport 25 meta skuid != { 0, $pu } counter reject with tcp reset
    tcp dport 6379 meta skuid != { 0, $ru, $du } counter reject with tcp reset
    tcp dport { 11332, 11333, 11334 } meta skuid != { 0, $pu, $ru, $vu } counter reject with tcp reset
  }
}
EOF
}
# passwords do Redis e do controlador do Rspamd (segunda barreira, além da firewall local)
mail_secrets(){
  local rp cp rc g
  [ -s /etc/minipainel/redis.pw ] || ( umask 077; openssl rand -hex 24 > /etc/minipainel/redis.pw )
  [ -s /etc/minipainel/rspamd-controller.pw ] || ( umask 077; openssl rand -hex 24 > /etc/minipainel/rspamd-controller.pw )
  rp=$(cat /etc/minipainel/redis.pw); cp=$(cat /etc/minipainel/rspamd-controller.pw)
  for rc in /etc/redis/redis.conf /etc/redis.conf; do
    [ -f "$rc" ] || continue
    if grep -qE '^\s*requirepass\s' "$rc"; then sed -i -E "s|^\s*requirepass\s.*|requirepass $rp|" "$rc"; else echo "requirepass $rp" >> "$rc"; fi
    break
  done
  g=$(id -gn "$(mail_rspamd_user)" 2>/dev/null || echo root)
  printf 'servers = "127.0.0.1";\npassword = "%s";\n' "$rp" > "$RSPAMD_LOCAL/redis.conf"
  printf 'bind_socket = "127.0.0.1:11334";\npassword = "%s";\nenable_password = "%s";\nsecure_ip = "127.0.0.2";\n' "$cp" "$cp" > "$RSPAMD_LOCAL/worker-controller.inc"
  chown root:"$g" "$RSPAMD_LOCAL/redis.conf" "$RSPAMD_LOCAL/worker-controller.inc"; chmod 640 "$RSPAMD_LOCAL/redis.conf" "$RSPAMD_LOCAL/worker-controller.inc"
  # cabeçalho com a password para quem fala com o controlador (aprendizagem como vmail; estado como root)
  printf 'Password: %s\n' "$cp" > /etc/minipainel/rspamd-controller.hdr
  chown root:vmail /etc/minipainel/rspamd-controller.hdr 2>/dev/null; chmod 640 /etc/minipainel/rspamd-controller.hdr
}
mail_apply(){ # gera os mapas do Postfix e os utilizadores do Dovecot a partir de data.json
  local j; j=$(mail_data)
  install -d -m 755 "$PF_MP"
  jq -r '.domains | keys[] | "\(.) OK"' <<<"$j" > "$PF_MP/vdomains"
  jq -r '.boxes | keys[] | "\(.) OK"' <<<"$j" > "$PF_MP/vmailbox"
  jq -r '.aliases | to_entries[] | "\(.key) \(.value | join(","))"' <<<"$j" > "$PF_MP/valias"
  {
    jq -r '.boxes | keys[] | "\(.) \(.)"' <<<"$j"
    jq -r '(.boxes | keys) as $b | .aliases | to_entries[] | . as $a | ($a.value | map(select(. as $d | $b | index($d)))) as $own | select($own | length > 0) | "\($a.key) \($own | join(","))"' <<<"$j"
  } > "$PF_MP/sender_login"
  chmod 644 "$PF_MP"/vdomains "$PF_MP"/vmailbox "$PF_MP"/valias "$PF_MP"/sender_login
  jq -r '.boxes | to_entries[] | "\(.key):{SHA512-CRYPT}\(.value.hash)::::::userdb_quota_rule=*:storage=\(.value.quota)M"' <<<"$j" > "$DV_USERS.tmp"
  chown root:dovecot "$DV_USERS.tmp"; chmod 640 "$DV_USERS.tmp"; mv -f "$DV_USERS.tmp" "$DV_USERS"
  postfix reload >/dev/null 2>&1 || systemctl reload postfix >/dev/null 2>&1
  return 0
}
# --- ativação ---
cmd_mail_enable(){
  local h="" re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'
  while [ $# -gt 0 ]; do case "$1" in --host) h="${2:-}"; shift 2 || shift ;; *) die "Opção desconhecida: $1" ;; esac; done
  h=$(printf '%s' "${h:-$(mail_get HOST)}" | tr 'A-Z' 'a-z')
  [[ "$h" =~ $re ]] || die "Indica o nome do servidor de correio (ex.: mail.iddigital.pt) com --host."
  echo "A instalar Postfix, Dovecot, Rspamd, Redis e Unbound (pode demorar alguns minutos)..."
  if [ "$OS_FAMILY" = debian ]; then
    echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
    echo "postfix postfix/mailname string $h" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q postfix dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-managesieved \
      rspamd redis-server unbound bind9-dnsutils >/dev/null 2>&1 || die "Falhou a instalação dos pacotes de email."
  else
    if [ ! -f /etc/yum.repos.d/rspamd.repo ]; then
      local elv; elv=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
      curl -fsSL "https://rspamd.com/rpm-stable/centos-$elv/rspamd.repo" -o /etc/yum.repos.d/rspamd.repo && rpm --import https://rspamd.com/rpm-stable/gpg.key || die "Não foi possível adicionar o repositório do Rspamd."
    fi
    dnf install -y -q postfix dovecot dovecot-pigeonhole rspamd redis unbound bind-utils >/dev/null 2>&1 || die "Falhou a instalação dos pacotes de email."
  fi
  id vmail >/dev/null 2>&1 || useradd -r -U -d "$VMAIL" -s "$(command -v nologin || echo /sbin/nologin)" -c "IDDigital Hosting mail" vmail
  install -d -o vmail -g vmail -m 750 "$VMAIL"
  install -d -m 711 "$MSPOOL"; install -d -m 700 "$MLIB" "$MLIB/held" "$MLIB/rejected" "$MLIB/sent"
  mail_set ENABLED 1; mail_set HOST "$h"; conf_lock
  [ -n "$(mail_get DNSBL)" ] || mail_set DNSBL "dnsbl.3rhost.pt"
  [ -n "$(mail_get SITE_LIMIT)" ] || mail_set SITE_LIMIT 100
  [ -n "$(mail_get BOX_LIMIT)" ] || mail_set BOX_LIMIT 200
  [ -n "$(mail_get AUTH_FAILS)" ] || mail_set AUTH_FAILS 10
  [ -n "$(mail_get CLAMAV)" ] || mail_set CLAMAV 0
  [ -s "$MAIL_DATA" ] || mail_data_save '{"domains":{},"boxes":{},"aliases":{}}'
  echo "A configurar o resolver DNS local (unbound)..."; mail_resolver_setup
  mail_host_web; local errf; errf=$(mktemp)
  if [ "$(srv_get MODE lan)" = internet ]; then
    le_issue mp-mail "$h" 2>"$errf" || { self_issue mp-mail "$h"; echo "Aviso: certificado Let's Encrypt para $h falhou; ficou um autoassinado. $(head -c 300 "$errf")"; }
  else
    cert_files mp-mail >/dev/null || self_issue mp-mail "$h"
  fi
  rm -f "$errf"
  mail_postfix_config; mail_dovecot_config; mail_rspamd_config; mail_learning_config; mail_lists_config; mail_apply
  local s; for s in $(mail_svc_redis) unbound rspamd dovecot postfix; do systemctl enable "$s" >/dev/null 2>&1; systemctl restart "$s" >/dev/null 2>&1 || warn "O serviço $s não arrancou."; done
  for s in 25 465 587 993 995 143 110; do fw_open "$s" >/dev/null 2>&1; done
  mail_fw_apply
  echo "A instalar o webmail (Roundcube)..."; mail_webmail_setup
  write_fm_pool_email
  # o mail() do PHP dos sites passa a ir para a fila controlada do painel
  for s in $(site_names); do mail_site_spool "$s"; write_pool "$s" "$(site_get "$s" PHP)"; done
  for s in $(php_installed); do apply_php "$s" >/dev/null 2>&1; done
  echo "Email ativo em $h. Webmail: https://$h:$WM_PORT. Próximo passo: adiciona um domínio de email e cria os registos DNS indicados."
  return 0
}
mail_host_web(){ # porta 80 para a validação do certificado do servidor de correio
  local h; h=$(mail_get HOST)
  [ -n "$h" ] || { rm -f "$NGX_CONFD/mail-host.conf"; return 0; }
  install -d -m 755 "$NGX_CONFD"
  { printf '# IDDigital Hosting — validação do certificado de %s\nserver {\n    listen 80;\n    server_name %s;\n' "$h" "$h"; acme_loc; printf '    location / { return 444; }\n}\n'; } > "$NGX_CONFD/mail-host.conf"
  ngx_default_sync; apply_nginx >/dev/null 2>&1
}
mail_site_spool(){ local s=$1; id "mp_$s" >/dev/null 2>&1 || return 0; install -d -m 711 "$MSPOOL"; install -d -o "mp_$s" -g "mp_$s" -m 700 "$MSPOOL/$s" "$MSPOOL/$s/tmp" "$MSPOOL/$s/new"; }

# --- domínios, caixas e aliases ---
cmd_mail_domain_add(){
  local d="${1:-}" j
  mail_need; valid_domain "$d" || die "Domínio inválido: $d"
  j=$(mail_data); [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = false ] || die "O domínio $d já existe."
  install -d -o vmail -g vmail -m 750 "$VMAIL/$d"
  if [ ! -s "$DKIM_DIR/$d.mp.key" ]; then
    rspamadm dkim_keygen -s mp -b 2048 -d "$d" -k "$DKIM_DIR/$d.mp.key" > "$DKIM_DIR/$d.mp.txt" 2>/dev/null || die "Não foi possível gerar a chave DKIM."
    chown "$(stat -c %U "$DKIM_DIR")":"$(stat -c %G "$DKIM_DIR")" "$DKIM_DIR/$d.mp.key" "$DKIM_DIR/$d.mp.txt"; chmod 640 "$DKIM_DIR/$d.mp.key"
  fi
  j=$(jq --arg d "$d" --arg t "$EPOCHSECONDS" '.domains[$d] = {created:($t|tonumber)}' <<<"$j")
  mail_data_save "$j"; mail_apply
  dns_autosync
  echo "Domínio de email $d adicionado com DKIM. $(dns_on && [ -f "$DNS_DIR/$d.json" ] && echo 'Os registos foram criados na zona DNS deste servidor.' || echo 'Cria os registos DNS indicados na página Email.')"
  return 0
}
cmd_mail_domain_del(){
  local d="${1:-}" j
  mail_need; j=$(mail_data)
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = true ] || die "O domínio $d não existe."
  j=$(jq --arg d "$d" '.domains |= del(.[$d]) | .boxes |= with_entries(select(.key | endswith("@" + $d) | not)) | .aliases |= with_entries(select(.key | endswith("@" + $d) | not))' <<<"$j")
  mail_data_save "$j"; mail_apply
  rm -rf "${VMAIL:?}/$d" "$DKIM_DIR/$d.mp.key" "$DKIM_DIR/$d.mp.txt"
  dns_autosync
  echo "Domínio $d apagado, com as caixas de correio e os aliases."
  return 0
}
mail_box_args(){ # --hash H | --password P, --quota N
  BHASH=""; BQUOTA=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hash) BHASH="${2:-}"; shift 2 || shift ;;
      --password) BHASH=$(printf '%s' "${2:-}" | mail_hash_stdin); [ ${#2} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."; shift 2 || shift ;;
      --quota) BQUOTA="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [ -z "$BHASH" ] || valid_mailhash "$BHASH" || die "Hash de password inválido."
  [ -z "$BQUOTA" ] || { [[ "$BQUOTA" =~ ^[0-9]{1,7}$ ]] && [ "$BQUOTA" -ge 10 ]; } || die "Quota inválida (MB, mínimo 10)."
}
cmd_mail_box_add(){
  local e="${1:-}" d j BHASH BQUOTA gen=""
  [ $# -gt 0 ] && shift
  mail_need; e=$(printf '%s' "$e" | tr 'A-Z' 'a-z'); valid_email "$e" || die "Endereço inválido: $e"
  mail_box_args "$@"; d=${e#*@}
  j=$(mail_data)
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = true ] || die "O domínio $d não está configurado no email."
  [ "$(jq --arg e "$e" '(.boxes | has($e)) or (.aliases | has($e))' <<<"$j")" = false ] || die "O endereço $e já existe."
  if [ -z "$BHASH" ]; then gen=$(gen_pass 16); BHASH=$(printf '%s' "$gen" | mail_hash_stdin); fi
  j=$(jq --arg e "$e" --arg h "$BHASH" --argjson q "${BQUOTA:-1024}" --arg t "$EPOCHSECONDS" '.boxes[$e] = {hash:$h, quota:$q, created:($t|tonumber)}' <<<"$j")
  mail_data_save "$j"; mail_apply
  echo "Caixa de correio $e criada (quota ${BQUOTA:-1024} MB)."
  [ -n "$gen" ] && echo "Password: $gen"
  mail_client_info "$e"
  return 0
}
mail_client_info(){ local h; h=$(mail_get HOST); echo "Configuração: IMAP $h:993 (SSL) · POP3 $h:995 (SSL) · SMTP $h:465 (SSL) ou 587 (STARTTLS) · utilizador: $1"; }
cmd_mail_box_set(){
  local e="${1:-}" j BHASH BQUOTA
  [ $# -gt 0 ] && shift
  mail_need; j=$(mail_data)
  [ "$(jq --arg e "$e" '.boxes | has($e)' <<<"$j")" = true ] || die "A caixa $e não existe."
  mail_box_args "$@"
  [ -n "$BHASH" ] && j=$(jq --arg e "$e" --arg h "$BHASH" '.boxes[$e].hash = $h' <<<"$j")
  [ -n "$BQUOTA" ] && j=$(jq --arg e "$e" --argjson q "$BQUOTA" '.boxes[$e].quota = $q' <<<"$j")
  mail_data_save "$j"; mail_apply
  echo "Caixa $e atualizada.$([ -n "$BHASH" ] && echo " Password alterada.")$([ -n "$BQUOTA" ] && echo " Quota: $BQUOTA MB.")"
  return 0
}
cmd_mail_box_del(){
  local e="${1:-}" j u d
  mail_need; j=$(mail_data)
  [ "$(jq --arg e "$e" '.boxes | has($e)' <<<"$j")" = true ] || die "A caixa $e não existe."
  j=$(jq --arg e "$e" '.boxes |= del(.[$e]) | .aliases |= (map_values(map(select(. != $e))) | with_entries(select(.value | length > 0)))' <<<"$j")
  mail_data_save "$j"; mail_apply
  u=${e%@*}; d=${e#*@}
  [[ "$u" =~ ^[a-z0-9._+-]+$ ]] && rm -rf "${VMAIL:?}/$d/$u"
  echo "Caixa de correio $e apagada."
  return 0
}
cmd_mail_alias_set(){
  local a="${1:-}" dests="${2:-}" j d x list="[]"
  mail_need; a=$(printf '%s' "$a" | tr 'A-Z' 'a-z')
  valid_email "$a" || [[ "$a" =~ ^@([a-z0-9-]+\.)+[a-z]{2,}$ ]] || die "Alias inválido: $a (usa nome@dominio ou @dominio para receber tudo)."
  d=${a#*@}; j=$(mail_data)
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$j")" = true ] || die "O domínio $d não está configurado no email."
  [ "$(jq --arg a "$a" '.boxes | has($a)' <<<"$j")" = false ] || die "$a já é uma caixa de correio."
  for x in $(printf '%s' "$dests" | tr 'A-Z,;' 'a-z  '); do
    valid_email "$x" || die "Destino inválido: $x"
    list=$(jq -c --arg x "$x" '. + [$x] | unique' <<<"$list")
  done
  [ "$(jq 'length' <<<"$list")" -gt 0 ] || die "Indica pelo menos um destino."
  [ "$(jq 'length' <<<"$list")" -le 20 ] || die "Máximo de 20 destinos."
  j=$(jq --arg a "$a" --argjson l "$list" '.aliases[$a] = $l' <<<"$j")
  mail_data_save "$j"; mail_apply
  echo "Encaminhamento $a → $(jq -r 'join(", ")' <<<"$list")."
  return 0
}
cmd_mail_alias_del(){
  local a="${1:-}" j; mail_need; j=$(mail_data)
  [ "$(jq --arg a "$a" '.aliases | has($a)' <<<"$j")" = true ] || die "O alias $a não existe."
  mail_data_save "$(jq --arg a "$a" '.aliases |= del(.[$a])' <<<"$j")"; mail_apply
  echo "Alias $a apagado."; return 0
}

# --- definições do antispam e antivírus ---
cmd_mail_settings(){
  local re_n='^[0-9]{1,5}$' z
  mail_need
  while [ $# -gt 0 ]; do
    case "$1" in
      --dnsbl) z="${2:-}"; [ "$z" = none ] && z=""; for x in $z; do valid_domain "$x" || die "Lista negra inválida: $x"; done; mail_set DNSBL "$z"; shift 2 || shift ;;
      --site-limit) [[ "${2:-}" =~ $re_n ]] || die "Limite inválido."; mail_set SITE_LIMIT "$2"; shift 2 || shift ;;
      --box-limit) [[ "${2:-}" =~ $re_n ]] || die "Limite inválido."; mail_set BOX_LIMIT "$2"; shift 2 || shift ;;
      --auth-fails) [[ "${2:-}" =~ $re_n ]] && [ "$2" -ge 3 ] || die "Valor inválido (mínimo 3)."; mail_set AUTH_FAILS "$2"
                    if [ -f "$PROT_CONF" ]; then sed -i "s/^AUTH_FAILS=.*/AUTH_FAILS=$2/" "$PROT_CONF"; fi; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  postconf -e "postscreen_dnsbl_sites = $(mail_dnsbl_sites)"; mail_rspamd_config
  postfix reload >/dev/null 2>&1; systemctl reload rspamd >/dev/null 2>&1 || systemctl restart rspamd >/dev/null 2>&1
  echo "Definições do antispam guardadas."; return 0
}
cmd_mail_av(){
  local a="${1:-}"; mail_need
  case "$a" in
    on)
      echo "A instalar o ClamAV (cerca de 1,2 GB de RAM quando ativo)..."
      if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q clamav-daemon clamav-freshclam >/dev/null 2>&1 || die "Falhou a instalação do ClamAV."
        systemctl enable --now clamav-freshclam clamav-daemon >/dev/null 2>&1
      else dnf install -y -q clamav clamd clamav-update >/dev/null 2>&1 || die "Falhou a instalação do ClamAV."
        sed -i 's/^#\?LocalSocket .*/LocalSocket \/run\/clamd.scan\/clamd.sock/' /etc/clamd.d/scan.conf; sed -i 's/^Example/#Example/' /etc/clamd.d/scan.conf /etc/freshclam.conf
        freshclam >/dev/null 2>&1; systemctl enable --now clamd@scan >/dev/null 2>&1
      fi
      mail_set CLAMAV 1 ;;
    off) mail_set CLAMAV 0
      systemctl disable --now clamav-daemon clamd@scan >/dev/null 2>&1 ;;
    *) die "Usa: mpanel mail-av on|off" ;;
  esac
  mail_rspamd_config; systemctl restart rspamd >/dev/null 2>&1
  echo "Antivírus $([ "$a" = on ] && echo 'ativado (as primeiras assinaturas podem demorar alguns minutos a descarregar)' || echo desativado)."
  return 0
}

# --- registos DNS e verificação ---
mail_public_ip(){ local ip; ip=$(mail_get PUBLIC_IP); [ -n "$ip" ] || ip=$(curl -s4 -m 6 https://api.ipify.org 2>/dev/null); [[ "$ip" =~ ^[0-9.]+$ ]] && echo "$ip"; }
mail_dkim_value(){ tr -d '\n\t' < "$DKIM_DIR/$1.mp.txt" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"\n' | tr -s ' ' | sed 's/^ //'; }
cmd_mail_dns_check(){
  local d="${1:-}" h ip mx spf dk dm ptr a out
  mail_need; [ "$(mail_data | jq --arg d "$d" '.domains | has($d)')" = true ] || die "O domínio $d não existe."
  h=$(mail_get HOST); ip=$(mail_public_ip)
  mx=$(dig +short MX "$d" | awk '{print $2}' | sed 's/\.$//' | tr '\n' ' ')
  spf=$(dig +short TXT "$d" | tr -d '"' | grep -i '^v=spf1' | head -1)
  dk=$(dig +short TXT "mp._domainkey.$d" | tr -d '" \n')
  dm=$(dig +short TXT "_dmarc.$d" | tr -d '"' | head -1)
  a=$(dig +short A "$h" | tail -1)
  ptr=$( [ -n "$ip" ] && dig +short -x "$ip" | sed 's/\.$//' | head -1)
  out=$(jq -n --arg d "$d" --arg h "$h" --arg ip "$ip" --arg mx "$mx" --arg spf "$spf" --arg dk "$dk" --arg dkx "$(mail_dkim_value "$d" | tr -d ' ')" \
    --arg dm "$dm" --arg a "$a" --arg ptr "$ptr" --arg t "$EPOCHSECONDS" \
    '{checked:($t|tonumber), ip:$ip,
      mx:{ok:($mx | split(" ") | index($h) != null), found:$mx},
      a:{ok:($ip != "" and $a == $ip), found:$a},
      spf:{ok:($spf != "" and (($spf | test(" mx( |$)")) or ($spf | contains("a:" + $h)) or ($ip != "" and ($spf | contains("ip4:" + $ip))))), found:$spf},
      dkim:{ok:($dk != "" and $dk == $dkx), found:(if $dk == "" then "" else "publicado" end)},
      dmarc:{ok:($dm | test("^v=DMARC1")), found:$dm},
      ptr:{ok:($ptr == $h), found:$ptr}}')
  local f=$DATA/stats/mail-dns.json
  jq --arg d "$d" --argjson o "$out" '.[$d] = $o' "$( [ -s "$f" ] && echo "$f" || { echo '{}' > "$f"; echo "$f"; })" > "$f.tmp" && mv -f "$f.tmp" "$f"
  chown root:"$PANEL_SYSUSER" "$f"; chmod 640 "$f"
  local bad; bad=$(jq -r 'to_entries | map(select(.value | type == "object" and has("ok") and (.ok | not)) | .key) | join(", ")' <<<"$out")
  if [ -z "$bad" ]; then echo "DNS de $d: tudo correto."; else echo "DNS de $d: falta corrigir $bad. Vê os valores na página Email."; fi
  return 0
}
# --- envio dos sites: fila controlada, limites e suspensão automática ---
mail_site_sent(){ # site segundos -> n.º de envios nesse período
  local f="$MLIB/sent/$1" since=$(( EPOCHSECONDS - $2 ))
  [ -f "$f" ] || { echo 0; return; }
  awk -v s="$since" '$1 >= s' "$f" | wc -l
}
mail_site_rej(){ local f="$MLIB/rejected/$1.log" since=$(( EPOCHSECONDS - $2 )); [ -f "$f" ] || { echo 0; return; }; awk -v s="$since" '$1 >= s' "$f" | wc -l; }
mail_site_from_ok(){ # site from -> 0 se o remetente pertence ao site (domínios do site)
  local s=$1 f=$2 d; d=${f#*@}
  valid_email "$f" || return 1
  [[ " $(site_get "$s" DOMAINS) " == *" $d "* ]] && return 0
  [[ " $(site_get "$s" DOMAINS) " == *" www.$d "* ]] && return 0
  return 1
}
mail_hdrs(){ awk 'BEGIN{h=""} /^\r?$/{exit} /^[ \t]/{h=h" "$0; next} {if(h!="")print h; h=$0} END{if(h!="")print h}' "$1"; }  # cabeçalhos, com linhas dobradas juntas
mail_count_rcpt(){ # destinatários em To/Cc/Bcc (e Resent-*)
  mail_hdrs "$1" | grep -iE '^(resent-)?(to|cc|bcc):' | sed -E 's/^[^:]*://' | grep -oE '[A-Za-z0-9._%+=-]+@[A-Za-z0-9.-]+' | sort -fu | wc -l
}
mail_fix_from(){ # msg site remetente: o From: tem de ser de um domínio do site; senão passa a ser o remetente validado
  local f=$1 s=$2 env=$3 hf addr d disp tmp
  hf=$(mail_hdrs "$f" | grep -im1 '^from:' | sed -E 's/^[^:]*:[ \t]*//')
  addr=$(printf '%s' "$hf" | grep -oE '[A-Za-z0-9._%+=-]+@[A-Za-z0-9.-]+' | head -1 | tr 'A-Z' 'a-z'); d=${addr#*@}
  if [ -n "$addr" ] && { [[ " $(site_get "$s" DOMAINS) " == *" $d "* ]] || [[ " $(site_get "$s" DOMAINS) " == *" www.$d "* ]]; }; then return 0; fi
  disp=$(printf '%s' "$hf" | sed -nE 's/^"?([^"<]*[^" <])"?[ \t]*<.*/\1/p' | tr -d '\r\n' | cut -c1-80)
  tmp=$(mktemp /var/tmp/mp-msg.XXXXXX)
  awk -v nf="From: ${disp:+\"$disp\" }<$env>" -v rt="$addr" '
    BEGIN{inh=1; skip=0; hasrt=0}
    inh && /^\r?$/ { if (!hasrt && rt != "") print "Reply-To: " rt; inh=0; print; next }
    inh && /^[ \t]/ { if (skip) next; print; next }
    inh { skip=0; if (tolower($0) ~ /^from:/) { print nf; skip=1; next } if (tolower($0) ~ /^reply-to:/) hasrt=1; print; next }
    { print }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
cmd_mail_spool(){
  mail_on || return 0
  exec 7>/run/minipainel-mailspool.lock; flock -n 7 || return 0
  local s u lim sent f base from msg res act sc rej susp nheld
  for s in $(site_names); do
    [ -d "$MSPOOL/$s/new" ] || continue
    u="mp_$s"; id "$u" >/dev/null 2>&1 || continue
    susp=$(site_get "$s" MAIL_SUSP); lim=$(site_get "$s" MAIL_LIMIT); lim=${lim:-$(mail_get SITE_LIMIT 100)}
    sent=$(mail_site_sent "$s" 3600)
    for f in $(cd "$MSPOOL/$s/new" && ls -1 -- *.eml 2>/dev/null | sort | head -n 200); do
      [ "$susp" = 1 ] && break
      [ "$sent" -ge "$lim" ] && break
      base=${f%.eml}
      msg=$(mktemp /var/tmp/mp-msg.XXXXXX)
      runuser -u "$u" -- head -c 31457280 "$MSPOOL/$s/new/$f" > "$msg" 2>/dev/null
      from=$(runuser -u "$u" -- head -c 300 "$MSPOOL/$s/new/$base.from" 2>/dev/null | head -n 1 | tr -d '\r <>')
      mail_site_from_ok "$s" "$from" || from="$s@$(mail_get HOST)"
      local nr maxr; maxr=$(mail_get MAX_RCPT 50)
      nr=$(mail_count_rcpt "$msg")
      mail_fix_from "$msg" "$s" "$from"
      res=$(rspamc -h 127.0.0.1:11333 --json -u "site-$s" -i 127.0.0.1 -F "$from" < "$msg" 2>/dev/null)
      act=$(jq -r '.action // "no action"' <<<"$res" 2>/dev/null); sc=$(jq -r '.score // 0' <<<"$res" 2>/dev/null)
      if [ "$nr" -gt "$maxr" ] || [ "$nr" -eq 0 ]; then act=reject; sc="rcpt:$nr"; fi
      if [ "$nr" -le "$maxr" ] && [ "$sent" -gt 0 ] && [ $(( sent + nr )) -gt "$lim" ] && [ "$act" != reject ]; then rm -f "$msg"; break; fi
      if [ "$act" = reject ]; then
        install -d -m 700 "$MLIB/rejected/$s"; mv -f "$msg" "$MLIB/rejected/$s/$base.eml"
        echo "$EPOCHSECONDS $sc" >> "$MLIB/rejected/$s.log"
        rej=$(mail_site_rej "$s" 3600)
        if [ "$rej" -ge "$(mail_get SPAM_SUSPEND 5)" ]; then
          site_set "$s" MAIL_SUSP 1; site_set "$s" MAIL_SUSP_WHY "spam detetado ($rej mensagens rejeitadas na última hora)"; susp=1
          jq -cn --arg t "$EPOCHSECONDS" --arg a "Envio de email do site $s suspenso automaticamente: $rej mensagens com spam na última hora" '{ts:($t|tonumber), ip:"servidor", user:"automático", action:$a, ok:false}' >> "$DATA/logs/audit.log"
        fi
      else
        { printf 'X-MP-Site: %s\n' "$s"; cat "$msg"; } | /usr/sbin/sendmail -t -i -f "$from" && { local k; for (( k = 0; k < nr; k++ )); do echo "$EPOCHSECONDS"; done >> "$MLIB/sent/$s"; sent=$(( sent + nr )); }
        rm -f "$msg"
      fi
      runuser -u "$u" -- rm -f "$MSPOOL/$s/new/$f" "$MSPOOL/$s/new/$base.from"
    done
    # guarda só as últimas 24 h dos contadores
    for f in "$MLIB/sent/$s" "$MLIB/rejected/$s.log"; do [ -f "$f" ] && awk -v s="$(( EPOCHSECONDS - 86400 ))" '$1 >= s' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"; done
  done
  return 0
}
cmd_mail_site(){ # site --limit N | --suspend | --resume | --purge
  local s="${1:-}" re='^[0-9]{1,6}$'
  [ $# -gt 0 ] && shift
  valid_site "$s" && site_exists "$s" || die "O site '$s' não existe."
  case "${1:-}" in
    --limit) [[ "${2:-}" =~ $re ]] || die "Limite inválido."; site_set "$s" MAIL_LIMIT "$2"; echo "Limite de envio de $s: $2 emails por hora." ;;
    --suspend) site_set "$s" MAIL_SUSP 1; site_set "$s" MAIL_SUSP_WHY "suspenso manualmente"; echo "Envio de email do site $s suspenso (as mensagens ficam retidas)." ;;
    --resume) site_set "$s" MAIL_SUSP 0; site_set "$s" MAIL_SUSP_WHY ""; rm -f "$MLIB/rejected/$s.log"; echo "Envio de email do site $s retomado." ;;
    --purge) find "$MSPOOL/$s/new" -type f -delete 2>/dev/null; rm -rf "${MLIB:?}/rejected/$s"; echo "Mensagens retidas e rejeitadas de $s apagadas." ;;
    *) die "Usa: mpanel mail-site <site> --limit N | --suspend | --resume | --purge" ;;
  esac
  return 0
}
cmd_mail_queue(){ # list | flush | delete <id>|all
  mail_need
  case "${1:-list}" in
    list) postqueue -j 2>/dev/null | jq -r '[.queue_id, .queue_name, .sender, (.recipients | map(.address) | join(",")), ((.recipients[0].delay_reason // "") | .[0:80])] | @tsv' ;;
    flush) postqueue -f; echo "Fila reenviada." ;;
    delete) local q="${2:-}" re='^[0-9A-Za-z]{6,20}$'
      if [ "$q" = all ]; then postsuper -d ALL >/dev/null 2>&1; echo "Fila de correio esvaziada."
      else [[ "$q" =~ $re ]] || die "Identificador inválido."; postsuper -d "$q" >/dev/null 2>&1 && echo "Mensagem $q apagada da fila."; fi ;;
    *) die "Usa: mpanel mail-queue list|flush|delete <id>|all" ;;
  esac
  return 0
}
mail_state_json(){
  if ! mail_on; then echo '{"enabled":false}'; return 0; fi
  local j dns q s sites="[]" used
  j=$(mail_data)
  dns=$(cat "$DATA/stats/mail-dns.json" 2>/dev/null || echo '{}')
  q=$(postqueue -j 2>/dev/null | jq -cs 'map({id:.queue_id, q:.queue_name, from:.sender, to:(.recipients | map(.address) | join(", ")), why:((.recipients[0].delay_reason // "") | .[0:160]), t:.arrival_time, size:.message_size}) | .[0:200]' 2>/dev/null)
  for s in $(site_names); do
    sites=$(jq -c --arg s "$s" --arg h1 "$(mail_site_sent "$s" 3600)" --arg h24 "$(mail_site_sent "$s" 86400)" \
      --arg held "$(find "$MSPOOL/$s/new" -name '*.eml' 2>/dev/null | wc -l)" --arg rej "$(find "$MLIB/rejected/$s" -name '*.eml' 2>/dev/null | wc -l)" \
      --arg su "$(site_get "$s" MAIL_SUSP)" --arg why "$(site_get "$s" MAIL_SUSP_WHY)" --arg lim "$(site_get "$s" MAIL_LIMIT)" \
      '. + [{site:$s, sent_1h:($h1|tonumber), sent_24h:($h24|tonumber), held:($held|tonumber), rejected:($rej|tonumber), suspended:($su=="1"), why:$why, limit:(if $lim == "" then null else ($lim|tonumber) end)}]' <<<"$sites")
  done
  local dk; dk=$(jq -r '.domains | keys[]' <<<"$j" | while read -r d; do printf '%s\t%s\n' "$d" "$(mail_dkim_value "$d")"; done | jq -R 'split("\t") | {(.[0]): (.[1] // "")}' | jq -cs 'add // {}')
  used=$(jq -r '.boxes | keys[]' <<<"$j" | while read -r e; do printf '%s\t%s\n' "$e" "$(du -sm "$VMAIL/${e#*@}/${e%@*}" 2>/dev/null | awk '{print $1}')"; done | jq -R 'split("\t") | {(.[0]): ((.[1] // "0") | tonumber? // 0)}' | jq -cs 'add // {}')
  local lists hist
  lists=$(mail_lists_json 2>/dev/null); hist=$(mail_history_json 2>/dev/null)
  dns=$(jv mail.dns "$dns" '{}'); q=$(jv mail.queue "$q" '[]'); sites=$(jv mail.sites "$sites" '[]'); used=$(jv mail.used "$used" '{}'); dk=$(jv mail.dkim "$dk" '{}')
  lists=$(jv mail.lists "$lists" '[]'); hist=$(jv mail.history "$hist" '[]')
  jq -n --argjson j "$j" --argjson dns "$dns" --argjson q "$q" --argjson sites "$sites" --argjson used "$used" --argjson dk "$dk" \
    --arg h "$(mail_get HOST)" --arg dnsbl "$(mail_get DNSBL)" --arg sl "$(mail_get SITE_LIMIT 100)" --arg bl "$(mail_get BOX_LIMIT 200)" \
    --arg af "$(mail_get AUTH_FAILS 10)" --arg av "$(mail_get CLAMAV 0)" --arg exp "$(cert_expiry mp-mail)" \
    --arg wmp "$WM_PORT" --argjson lists "$lists" --argjson hist "$hist" \
    --arg st "$(for x in postfix dovecot rspamd; do systemctl is-active "$x" 2>/dev/null; done | grep -c '^active$')" \
    '{enabled:true, host:$h, dnsbl:$dnsbl, site_limit:($sl|tonumber), box_limit:($bl|tonumber), auth_fails:($af|tonumber), clamav:($av=="1"),
      cert_exp:(if $exp == "" then null else ($exp|tonumber) end), services_ok:($st == "3"),
      domains:[$j.domains | keys[] | . as $d | {name:$d, boxes:([$j.boxes | keys[] | select(endswith("@" + $d))] | length), dns:($dns[$d] // null), dkim:(($dk // {})[$d] // "")}],
      boxes:[$j.boxes | to_entries[] | {email:.key, quota:.value.quota, used:($used[.key] // 0)}],
      aliases:[$j.aliases | to_entries[] | {alias:.key, dests:.value}],
      sites:$sites, queue:$q, webmail:("https://" + $h + ":" + $wmp), lists:$lists, history:$hist}'
}
cmd_mail_dns_info(){ # registos a criar para um domínio
  local d="${1:-}" h ip; mail_need
  h=$(mail_get HOST); ip=$(mail_public_ip)
  printf '%s\tMX\t10 %s\n' "$d" "$h"
  printf '%s\tTXT\tv=spf1 mx a:%s ~all\n' "$d" "$h"
  printf 'mp._domainkey.%s\tTXT\t%s\n' "$d" "$(mail_dkim_value "$d")"
  printf '_dmarc.%s\tTXT\tv=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@%s\n' "$d" "$d"
  printf '%s\tA\t%s\n' "$h" "${ip:-<IP público>}"
  printf '%s\tPTR\t%s (pedir ao fornecedor do servidor)\n' "${ip:-<IP público>}" "$h"
}

# --- gestor de ficheiros da área Email (corre como vmail; só /var/mail/vhosts) ---
MAILFM_TMP=/var/lib/minipainel-mailfm
write_fm_pool_email(){
  local f; f=$(fm_pool_file _email)
  install -d -o vmail -g vmail -m 700 "$MAILFM_TMP"
  cat > "$f" <<EOF
; IDDigital Hosting — gestor de ficheiros da área Email (corre como vmail; gerido pelo mpanel)
[mp-fm-_email]
user = vmail
group = vmail
listen = $(php_run_dir "$PANEL_PHP")/mp-fm-_email.sock
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
request_terminate_timeout = 0
php_admin_value[open_basedir] = $VMAIL/:$MAILFM_TMP/:/opt/minipainel/files/
php_admin_value[upload_tmp_dir] = $MAILFM_TMP
php_admin_value[sys_temp_dir] = $MAILFM_TMP
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 72M
php_admin_value[memory_limit] = 256M
php_value[max_execution_time] = 900
php_admin_value[max_input_time] = 900
php_admin_value[error_log] = $MAILFM_TMP/ficheiros-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF
  chmod 644 "$f"
}

# --- webmail (Roundcube do repositório da distribuição: atualizações de segurança automáticas) ---
WM_DATA=/var/lib/minipainel-webmail
WM_PORT=2096
wm_paths(){ # define WM_ROOT (raiz pública), WM_CONF (config.inc.php) e WM_SQL
  if [ -d /var/lib/roundcube/public_html ]; then WM_ROOT=/var/lib/roundcube/public_html; WM_CONF=/etc/roundcube/config.inc.php; WM_SQL=/usr/share/roundcube/SQL
  else WM_ROOT=/usr/share/roundcubemail; WM_CONF=/etc/roundcubemail/config.inc.php; WM_SQL=/usr/share/roundcubemail/SQL; fi
  [ -d "$WM_SQL" ] || WM_SQL=/var/lib/roundcube/SQL
}
mail_webmail_setup(){
  local key ip6="" c
  if [ "$OS_FAMILY" = debian ]; then
    echo "roundcube-core roundcube/dbconfig-install boolean false" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends roundcube-core roundcube-sqlite3 roundcube-plugins sqlite3 >/dev/null 2>&1 || { warn "Falhou a instalação do Roundcube."; return 1; }
  else
    dnf install -y -q roundcubemail sqlite >/dev/null 2>&1 || { warn "Falhou a instalação do Roundcube."; return 1; }
  fi
  wm_paths
  id mp-webmail >/dev/null 2>&1 || useradd -r -U -d "$WM_DATA" -s "$(command -v nologin || echo /sbin/nologin)" -c "IDDigital Hosting webmail" mp-webmail
  install -d -o mp-webmail -g mp-webmail -m 750 "$WM_DATA" "$WM_DATA/temp" "$WM_DATA/logs"
  [ -s /etc/minipainel/webmail.key ] || ( umask 077; openssl rand -base64 18 | tr -d '\n=' | cut -c1-24 > /etc/minipainel/webmail.key )
  key=$(cat /etc/minipainel/webmail.key)
  cat > "$WM_CONF" <<EOF
<?php
// IDDigital Hosting — configuração do webmail (gerada pelo painel; não editar à mão)
\$config = [];
\$config['db_dsnw'] = 'sqlite:///$WM_DATA/roundcube.db?mode=0640';
\$config['imap_host'] = 'ssl://127.0.0.1:993';
\$config['smtp_host'] = 'tls://127.0.0.1:587';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['managesieve_host'] = 'tls://127.0.0.1';
\$config['managesieve_port'] = 4190;
\$config['managesieve_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['managesieve_vacation'] = 1;
\$config['markasjunk_learning_driver'] = null;
\$config['product_name'] = 'IDDigital Webmail';
\$config['support_url'] = '';
\$config['des_key'] = '$key';
\$config['plugins'] = ['archive', 'zipdownload', 'managesieve', 'markasjunk'];
\$config['language'] = 'pt_PT';
\$config['skin'] = 'elastic';
\$config['temp_dir'] = '$WM_DATA/temp/';
\$config['log_dir'] = '$WM_DATA/logs/';
\$config['log_driver'] = 'file';
\$config['log_logins'] = true;
\$config['login_rate_limit'] = 3;
\$config['enable_installer'] = false;
\$config['ip_check'] = true;
\$config['use_https'] = true;
\$config['session_lifetime'] = 30;
\$config['max_message_size'] = '25M';
\$config['username_domain_forced'] = false;
\$config['login_lc'] = 2;
\$config['junk_mbox'] = 'Junk';
\$config['create_default_folders'] = true;
EOF
  chown root:mp-webmail "$WM_CONF"; chmod 640 "$WM_CONF"
  if [ ! -s "$WM_DATA/roundcube.db" ]; then
    sqlite3 "$WM_DATA/roundcube.db" < "$WM_SQL/sqlite.initial.sql" >/dev/null 2>&1 || warn "Não foi possível criar a base de dados do webmail."
  else
    runuser -u mp-webmail -- php "$(dirname "$WM_SQL")/bin/updatedb.sh" --package=roundcube --dir="$WM_SQL" >/dev/null 2>&1
  fi
  chown mp-webmail:mp-webmail "$WM_DATA/roundcube.db"; chmod 640 "$WM_DATA/roundcube.db"
  # PHP-FPM próprio (utilizador sem acesso aos sites)
  cat > "$(php_pool_dir "$PANEL_PHP")/mp-webmail.conf" <<EOF
; IDDigital Hosting — webmail (corre como mp-webmail; gerido pelo mpanel)
[mp-webmail]
user = mp-webmail
group = mp-webmail
listen = $(php_run_dir "$PANEL_PHP")/mp-webmail.sock
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
php_admin_value[upload_max_filesize] = 25M
php_admin_value[post_max_size] = 30M
php_admin_value[memory_limit] = 256M
php_admin_value[session.gc_maxlifetime] = 21600
php_admin_value[upload_tmp_dir] = $WM_DATA/temp
php_admin_value[sys_temp_dir] = $WM_DATA/temp
php_admin_value[error_log] = $WM_DATA/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_flag[expose_php] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF
  apply_php "$PANEL_PHP" >/dev/null 2>&1 || warn "Verifica o PHP-FPM $PANEL_PHP."
  c=$(mail_cert)
  [ "${IPV6:-0}" = 1 ] && ip6="    listen [::]:$WM_PORT ssl http2;"
  cat > "$NGX_CONFD/webmail.conf" <<EOF
# IDDigital Hosting — webmail (Roundcube) em https://$(mail_get HOST):$WM_PORT
server {
    listen $WM_PORT ssl http2;
$ip6
    server_name _;
    ssl_certificate     ${c%% *};
    ssl_certificate_key ${c##* };
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:MPSSL:1m;
    error_page 497 =301 https://\$host:\$server_port\$request_uri;
    root $WM_ROOT;
    index index.php;
    client_max_body_size 30M;
    access_log /var/log/nginx/webmail.access.log;
    error_log  /var/log/nginx/webmail.error.log;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy same-origin always;
    location ~ ^/(config|temp|logs|SQL|bin|installer|vendor|program/(include|lib|localization|steps))(/|\$) { deny all; }
    location ~ /\\. { deny all; }
    location ~ \\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\\.php)(/.*)\$;
        if (!-f \$document_root\$fastcgi_script_name) { return 404; }
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:$(php_run_dir "$PANEL_PHP")/mp-webmail.sock;
        fastcgi_read_timeout 300s;
    }
}
EOF
  chmod 644 "$NGX_CONFD/webmail.conf"
  fw_open "$WM_PORT" >/dev/null 2>&1
  apply_nginx >/dev/null 2>&1 || warn "Verifica o nginx (nginx -t)."
  return 0
}

# --- o Bayes aprende quando o utilizador move mensagens para o Lixo ou para fora dele ---
mail_learning_config(){
  install -d -m 755 /etc/dovecot/sieve
  printf '#!/bin/sh\nexec curl -s -m 30 -H @/etc/minipainel/rspamd-controller.hdr --data-binary @- http://127.0.0.1:11334/learnspam >/dev/null\n' > /etc/dovecot/sieve/mp-learn-spam.sh
  printf '#!/bin/sh\nexec curl -s -m 30 -H @/etc/minipainel/rspamd-controller.hdr --data-binary @- http://127.0.0.1:11334/learnham >/dev/null\n' > /etc/dovecot/sieve/mp-learn-ham.sh
  chmod 755 /etc/dovecot/sieve/mp-learn-spam.sh /etc/dovecot/sieve/mp-learn-ham.sh
  printf 'require ["vnd.dovecot.pipe", "copy", "imapsieve"];\npipe :copy "mp-learn-spam.sh";\n' > /etc/dovecot/sieve/mp-learn-spam.sieve
  printf 'require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];\nif environment :matches "imap.mailbox" "*" { set "mailbox" "${1}"; }\nif string "${mailbox}" "Trash" { stop; }\npipe :copy "mp-learn-ham.sh";\n' > /etc/dovecot/sieve/mp-learn-ham.sieve
  cat > /etc/dovecot/conf.d/99-minipainel-learn.conf <<'EOF'
# IDDigital Hosting — aprendizagem do antispam (mover para/de Lixo treina o Bayes do Rspamd)
protocol imap {
  mail_plugins = $mail_plugins imap_sieve
}
plugin {
  sieve_plugins = sieve_imapsieve sieve_extprograms
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
  sieve_pipe_bin_dir = /etc/dovecot/sieve
  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY APPEND
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/mp-learn-spam.sieve
  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/mp-learn-ham.sieve
}
EOF
  sievec /etc/dovecot/sieve/mp-learn-spam.sieve >/dev/null 2>&1; sievec /etc/dovecot/sieve/mp-learn-ham.sieve >/dev/null 2>&1
  printf 'autolearn = true;\nmin_learns = 50;\n' > "$RSPAMD_LOCAL/classifier-bayes.conf"
}

# --- listas de remetentes (permitir / bloquear) ---
MAIL_LISTS=/etc/rspamd/local.d
mail_lists_config(){
  local t
  for t in allow-from allow-domain allow-ip deny-from deny-domain deny-ip; do [ -f "$MAIL_LISTS/mp-$t.map" ] || : > "$MAIL_LISTS/mp-$t.map"; done
  cat > "$RSPAMD_LOCAL/multimap.conf" <<EOF
MP_ALLOW_FROM { type = "from"; filter = "email:addr"; map = "$MAIL_LISTS/mp-allow-from.map"; score = -20.0; description = "Remetente permitido no painel"; }
MP_ALLOW_DOMAIN { type = "from"; filter = "email:domain"; map = "$MAIL_LISTS/mp-allow-domain.map"; score = -20.0; description = "Domínio permitido no painel"; }
MP_ALLOW_IP { type = "ip"; map = "$MAIL_LISTS/mp-allow-ip.map"; score = -20.0; description = "IP permitido no painel"; }
MP_DENY_FROM { type = "from"; filter = "email:addr"; map = "$MAIL_LISTS/mp-deny-from.map"; score = 20.0; description = "Remetente bloqueado no painel"; }
MP_DENY_DOMAIN { type = "from"; filter = "email:domain"; map = "$MAIL_LISTS/mp-deny-domain.map"; score = 20.0; description = "Domínio bloqueado no painel"; }
MP_DENY_IP { type = "ip"; map = "$MAIL_LISTS/mp-deny-ip.map"; score = 20.0; description = "IP bloqueado no painel"; }
EOF
}
cmd_mail_list(){ # allow|deny add|del <email | @dominio | IP>
  local l="${1:-}" op="${2:-}" v t f
  mail_need
  v=$(printf '%s' "${3:-}" | tr 'A-Z' 'a-z')
  case "$l" in allow|deny) ;; *) die "Usa: mpanel mail-list allow|deny add|del <email|@domínio|IP>" ;; esac
  if valid_email "$v"; then t=from
  elif [[ "$v" == @* ]] && valid_domain "${v#@}"; then t=domain; v=${v#@}
  elif fw_ip_valid "$v"; then t=ip
  else die "Valor inválido: usa um email, @domínio ou um IP."; fi
  f="$MAIL_LISTS/mp-$l-$t.map"; touch "$f"
  case "$op" in
    add) grep -qxF "$v" "$f" || echo "$v" >> "$f"; echo "$([ "$l" = allow ] && echo Permitido || echo Bloqueado): $([ "$t" = domain ] && echo "@")$v" ;;
    del) grep -vxF "$v" "$f" > "$f.tmp"; mv -f "$f.tmp" "$f"; echo "Removido da lista: $([ "$t" = domain ] && echo "@")$v" ;;
    *) die "Usa add ou del." ;;
  esac
  chmod 644 "$f"
  return 0
}
mail_lists_json(){
  local l t
  for l in allow deny; do for t in from domain ip; do
    [ -s "$MAIL_LISTS/mp-$l-$t.map" ] && sed "s/^/$l $t /" "$MAIL_LISTS/mp-$l-$t.map"
  done; done | jq -R 'split(" ") | {list:.[0], type:.[1], value:(if .[1] == "domain" then "@" + .[2] else .[2] end)}' | jq -cs '.'
}
mail_history_json(){ # últimas mensagens rejeitadas ou marcadas como spam (histórico do Rspamd)
  local r; r=$(curl -s -m 5 -H @/etc/minipainel/rspamd-controller.hdr http://127.0.0.1:11334/history 2>/dev/null)
  jq -e . >/dev/null 2>&1 <<<"$r" || { echo '[]'; return 0; }
  printf '%s' "$r" | jq -c '[(.rows // [])[] | select(.action == "reject" or .action == "add header" or .action == "rewrite subject") |
    {t:.unix_time, action:.action, score:((.score // 0) * 10 | floor / 10), from:(.sender_mime // .sender_smtp // ""), to:((.rcpt_mime // .rcpt_smtp // []) | if type == "array" then join(", ") else . end),
     subject:(.subject // ""), ip:(.ip // ""), symbols:([(.symbols // {}) | to_entries[] | select((.value.score // 0) >= 1) | .key] | .[0:8])}] | .[0:150]' 2>/dev/null || echo '[]'
}

# ---------- importar caixas de correio de outro servidor (Dovecot doveadm + imapc) ----------
MI_DIR=$DATA/mail-import
MI_STATE=$DATA/stats/mail-import.json
mi_conf(){ # id host porta ssl utilizador verificar_cert prefixo password(stdin) -> ficheiro de configuração temporário (só root)
  local id=$1 host=$2 port=$3 ssl=$4 user=$5 ver=$6 pre=$7 pass f
  IFS= read -r pass
  install -d -m 700 "$MI_DIR"; f="$MI_DIR/$id.conf"
  ( umask 077
    {
      echo "!include /etc/dovecot/dovecot.conf"
      echo "imapc_host = $host"; echo "imapc_port = $port"; echo "imapc_ssl = $ssl"
      echo "imapc_user = $user"; printf 'imapc_password = %s\n' "$pass"
      echo "imapc_features = rfc822.size fetch-headers"
      [ -n "$pre" ] && echo "imapc_list_prefix = $pre"
      echo "ssl_client_ca_dir = /etc/ssl/certs"
      echo "imapc_ssl_verify = $([ "$ver" = 1 ] && echo yes || echo no)"
      echo "mail_prefetch_count = 20"
      echo "imapc_max_idle_time = 29 mins"
    } > "$f" )
  echo "$f"
}
mi_args(){ # interpreta as opções comuns
  MI_HOST=""; MI_PORT=993; MI_SSL=imaps; MI_USER=""; MI_VER=1; MI_PRE=""; MI_EXCL=1; MI_SINCE=""; MI_DEST=""; MI_CREATE=0; MI_PASS=""; MI_LIST=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) MI_HOST="${2:-}"; shift 2 || shift ;;
      --port) MI_PORT="${2:-}"; shift 2 || shift ;;
      --ssl) MI_SSL="${2:-}"; shift 2 || shift ;;
      --user) MI_USER="${2:-}"; shift 2 || shift ;;
      --no-verify) MI_VER=0; shift ;;
      --prefix) MI_PRE="${2:-}"; shift 2 || shift ;;
      --all-folders) MI_EXCL=0; shift ;;
      --since) MI_SINCE="${2:-}"; shift 2 || shift ;;
      --dest) MI_DEST=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z'); shift 2 || shift ;;
      --create) MI_CREATE=1; shift ;;
      --password) MI_PASS="${2:-}"; shift 2 || shift ;;   # vem da fila do painel (corre no mesmo processo: não aparece na lista de processos)
      --list) MI_LIST="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$MI_HOST" =~ ^[A-Za-z0-9.-]{1,253}$|^[0-9a-fA-F:.]+$ ]] || die "Servidor de origem inválido."
  [[ "$MI_PORT" =~ ^[0-9]{1,5}$ ]] || die "Porta inválida."
  [[ "$MI_SSL" =~ ^(imaps|starttls|no)$ ]] || die "Segurança: imaps, starttls ou no."
  [ -n "$MI_LIST" ] || [[ -n "$MI_USER" && ${#MI_USER} -le 200 && ! "$MI_USER" =~ [[:space:][:cntrl:]] ]] || die "Utilizador de origem inválido."
  [[ -z "$MI_PRE" || "$MI_PRE" =~ ^[A-Za-z0-9._/-]{1,40}$ ]] || die "Prefixo inválido."
  [[ -z "$MI_SINCE" || "$MI_SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Data inválida (AAAA-MM-DD)."
}
cmd_mail_import_test(){ # opções; password no stdin
  mail_need; mi_args "$@"
  local id="t$EPOCHSECONDS$RANDOM" f out rc
  [ -n "$MI_PASS" ] || IFS= read -r MI_PASS
  f=$(printf '%s\n' "$MI_PASS" | mi_conf "$id" "$MI_HOST" "$MI_PORT" "$MI_SSL" "$MI_USER" "$MI_VER" "$MI_PRE")
  # o doveadm pergunta ao Dovecot em execução pelo utilizador: usa uma caixa real (a de destino, se já existir);
  # com mail_location=imapc: só se fala com a origem, a caixa local não é lida nem alterada
  local tu=""
  [ -n "$MI_DEST" ] && [ "$(jq --arg e "$MI_DEST" '.boxes | has($e)' <<<"$(mail_data)")" = true ] && tu=$MI_DEST
  [ -n "$tu" ] || tu=$(jq -r '.boxes | keys[0] // ""' <<<"$(mail_data)")
  [ -n "$tu" ] || { rm -f "$f"; die "Cria primeiro uma caixa de correio neste servidor (é usada para o teste)."; }
  out=$(timeout 90 doveadm -c "$f" -o mail_location=imapc: mailbox status -u "$tu" "messages vsize" '*' 2>&1); rc=$?
  rm -f "$f"
  if [ "$rc" != 0 ] || [ -z "$out" ]; then
    out=$(printf '%s' "$out" | grep -iE 'error|fail|auth|refused|timed|certificate' | head -n 1 | sed 's/^.*Error: //; s/^imapc([^)]*): //' | cut -c1-200)
    die "Não foi possível ligar ou entrar na caixa de origem: ${out:-sem resposta}"
  fi
  # resumo: pastas, mensagens, tamanho; e se as pastas vêm dentro de INBOX (cPanel/Courier)
  printf '%s\n' "$out" | awk '
    !/messages=/ { next }
    { n = $1; sub(/^[^ ]+ /, ""); m = 0; v = 0; for (i = 1; i <= NF; i++) { if ($i ~ /^messages=/) { m = substr($i, 10) } if ($i ~ /^vsize=/) { v = substr($i, 7) } }
      f++; tm += m; tv += v; if (n ~ /^INBOX[.\/]./) pre++; list = list (list ? ", " : "") n " (" m ")" }
    END { printf "Ligação OK: %d pastas, %d mensagens, %.1f MB.\n", f, tm, tv / 1048576; if (pre > 1 && pre >= f - 2) print "As pastas da origem estão dentro de INBOX: usa o prefixo INBOX."; print "Pastas: " list }'
  return 0
}
mi_state(){ # estado para o painel (sem passwords)
  local f j="[]"
  for f in "$MI_DIR"/*.json; do [ -f "$f" ] && j=$(jq -c --slurpfile r "$f" '. + $r' <<<"$j"); done
  install -d -m 755 "$(dirname "$MI_STATE")"
  jq -c 'sort_by(.created) | reverse | .[0:200]' <<<"$j" > "$MI_STATE.tmp" && mv -f "$MI_STATE.tmp" "$MI_STATE"
  chown root:"$PANEL_SYSUSER" "$MI_STATE"; chmod 640 "$MI_STATE"
}
mi_add(){ # acrescenta uma importação à fila (password em MI_PASS)
  local id d pass=$MI_PASS
  [ -n "$pass" ] || die "Falta a password da caixa de origem."
  d=${MI_DEST#*@}
  [ "$(jq --arg d "$d" '.domains | has($d)' <<<"$(mail_data)")" = true ] || die "O domínio $d não está configurado no email."
  if [ "$(jq --arg e "$MI_DEST" '.boxes | has($e)' <<<"$(mail_data)")" != true ]; then
    [ "$MI_CREATE" = 1 ] || die "A caixa $MI_DEST não existe (ativa \"criar as caixas que não existam\")."
    [ ${#pass} -ge 10 ] || die "A caixa $MI_DEST não existe e a password da origem tem menos de 10 caracteres: cria a caixa primeiro."
    cmd_mail_box_add "$MI_DEST" --password "$pass" >/dev/null || die "Não foi possível criar a caixa $MI_DEST."
  fi
  id="$EPOCHSECONDS$(printf '%04d' $((RANDOM % 10000)))"
  install -d -m 700 "$MI_DIR"
  ( umask 077; printf '%s\n' "$pass" > "$MI_DIR/$id.pass" )
  jq -n --arg id "$id" --arg h "$MI_HOST" --arg p "$MI_PORT" --arg s "$MI_SSL" --arg u "$MI_USER" --arg v "$MI_VER" --arg pre "$MI_PRE" \
        --arg x "$MI_EXCL" --arg since "$MI_SINCE" --arg d "$MI_DEST" --arg c "$MI_CREATE" --arg t "$EPOCHSECONDS" \
    '{id:$id, host:$h, port:($p|tonumber), ssl:$s, user:$u, verify:($v == "1"), prefix:$pre, exclude:($x == "1"), since:$since, dest:$d, create:($c == "1"),
      status:"pending", created:($t|tonumber), started:0, ended:0, msgs:0, mb:0, msg:"Na fila"}' > "$MI_DIR/$id.json"
  chmod 600 "$MI_DIR/$id.json"
  echo "$id"
}
cmd_mail_import_start(){ # opções (--dest obrigatório); password no stdin
  mail_need; mi_args "$@"; valid_email "$MI_DEST" || die "Caixa de destino inválida."
  [ -n "$MI_PASS" ] || IFS= read -r MI_PASS
  local id; id=$(mi_add) || exit 1
  mi_state; mi_runner_spawn
  echo "Importação de $MI_USER@$MI_HOST para $MI_DEST na fila (corre em segundo plano)."
  return 0
}
cmd_mail_import_bulk(){ # opções comuns + --list "origem;password;destino" (uma por linha) ou as linhas no stdin
  mail_need
  local line u p d n=0 bad=0 base=() lst="" a
  while [ $# -gt 0 ]; do if [ "$1" = --list ]; then lst="${2:-}"; shift 2 || shift; else base+=("$1"); shift; fi; done
  [ -n "$lst" ] || lst=$(cat)
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; [ -n "${line// }" ] || continue; [[ "$line" == \#* ]] && continue
    IFS=';' read -r u p d <<<"$line"
    u=$(printf '%s' "$u" | xargs); d=$(printf '%s' "${d:-$u}" | xargs | tr 'A-Z' 'a-z')
    if [ -z "$u" ] || [ -z "$p" ] || ! valid_email "$d"; then bad=$((bad+1)); continue; fi
    ( mi_args "${base[@]}" --user "$u" --dest "$d" --password "$p"; mi_add >/dev/null ) && n=$((n+1)) || bad=$((bad+1))
  done <<<"$lst"
  [ "$n" -gt 0 ] || die "Nenhuma linha válida (formato: origem;password;destino)."
  mi_state; mi_runner_spawn
  echo "$n caixas na fila para importar$([ "$bad" -gt 0 ] && echo "; $bad linhas ignoradas (incompletas ou com destino inválido)")."
  return 0
}
mi_runner_spawn(){ # um só executor em segundo plano, fora do bloqueio do painel
  ( setsid /usr/local/sbin/mpanel mail-import-run </dev/null >/dev/null 2>&1 & ) 9>&-
}
cmd_mail_import_run(){ # executa a fila, uma caixa de cada vez
  exec 8>/run/minipainel-mail-import.lock; flock -n 8 || return 0
  local f id j pass conf log rc out m v q ex
  while :; do
    f=$(for x in "$MI_DIR"/*.json; do [ -f "$x" ] && jq -e '.status == "pending"' "$x" >/dev/null 2>&1 && echo "$x"; done | sort | head -n 1)
    [ -n "$f" ] || break
    j=$(cat "$f"); id=$(jq -r .id <<<"$j")
    upd(){ jq "$@" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"; mi_state; }
    upd --arg t "$EPOCHSECONDS" '.status = "running" | .started = ($t|tonumber) | .msg = "A importar…"'
    pass=$(cat "$MI_DIR/$id.pass" 2>/dev/null)
    local dest; dest=$(jq -r .dest <<<"$j")
    if [ "$(jq --arg e "$dest" '.boxes | has($e)' <<<"$(mail_data)")" != true ]; then
      rm -f "$MI_DIR/$id.pass"; upd --arg t "$EPOCHSECONDS" '.status = "failed" | .ended = ($t|tonumber) | .msg = "A caixa de destino já não existe."'; continue
    fi
    conf=$(printf '%s\n' "$pass" | mi_conf "$id" "$(jq -r .host <<<"$j")" "$(jq -r .port <<<"$j")" "$(jq -r .ssl <<<"$j")" "$(jq -r .user <<<"$j")" "$( [ "$(jq -r .verify <<<"$j")" = true ] && echo 1 || echo 0)" "$(jq -r .prefix <<<"$j")")
    rm -f "$MI_DIR/$id.pass"; pass=""
    log="$MI_DIR/$id.log"
    ex=(); [ "$(jq -r .exclude <<<"$j")" = true ] && ex=(-x Trash -x Junk -x Spam -x "Deleted Items" -x "Junk E-mail" -x "INBOX.Trash" -x "INBOX.Junk" -x "INBOX.Spam")
    local since; since=$(jq -r .since <<<"$j"); [ -n "$since" ] && ex+=(-t "$since")
    timeout 21600 doveadm -c "$conf" -o mail_fsync=never sync -1 -R "${ex[@]}" -u "$dest" imapc: > "$log" 2>&1; rc=$?
    rm -f "$conf"
    out=$(doveadm mailbox status -u "$dest" "messages vsize" '*' 2>/dev/null | awk '{for (i = 1; i <= NF; i++) { if ($i ~ /^messages=/) m += substr($i, 10); if ($i ~ /^vsize=/) v += substr($i, 7) } } END { printf "%d %d", m, v / 1048576 }')
    m=${out% *}; v=${out#* }
    if [ "$rc" = 0 ]; then
      upd --arg t "$EPOCHSECONDS" --argjson m "${m:-0}" --argjson v "${v:-0}" '.status = "done" | .ended = ($t|tonumber) | .msgs = $m | .mb = $v | .msg = "Concluída"'
    else
      q=$(grep -iE 'error|fail|quota|auth' "$log" | tail -n 2 | sed 's/^.*Error: //' | cut -c1-220 | tr '\n' ' ')
      upd --arg t "$EPOCHSECONDS" --argjson m "${m:-0}" --argjson v "${v:-0}" --arg e "${q:-erro $rc}" '.status = "failed" | .ended = ($t|tonumber) | .msgs = $m | .mb = $v | .msg = ("Falhou: " + $e)'
    fi
    chmod 600 "$log"
  done
  return 0
}
cmd_mail_import_clear(){ # apaga do histórico as importações terminadas
  local f; for f in "$MI_DIR"/*.json; do [ -f "$f" ] || continue; jq -e '.status == "done" or .status == "failed"' "$f" >/dev/null 2>&1 && rm -f "$f" "${f%.json}.log"; done
  mi_state; echo "Histórico de importações limpo."; return 0
}
