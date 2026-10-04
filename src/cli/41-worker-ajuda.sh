cmd_worker(){
  local f id action out rc re='^[a-f0-9]{16}$'
  local -a files args
  shopt -s nullglob
  find "$RESULTS" -type f -mmin +30 -delete 2>/dev/null
  find "$DATA/tmp" -type f -mmin +60 -delete 2>/dev/null
  while :; do
    files=("$QUEUE"/*.json)
    [ ${#files[@]} -eq 0 ] && break
    for f in "${files[@]}"; do
      id=$(jq -r '.id // empty' "$f" 2>/dev/null)
      action=$(jq -r '.action // empty' "$f" 2>/dev/null)
      mapfile -t args < <(jq -r '(.args // []) | .[] | tostring' "$f" 2>/dev/null)
      rm -f "$f"
      [[ "$id" =~ $re ]] || continue
      case "$action" in
        site-add|site-del|site-php|site-enable|site-disable|site-fixperms|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|db-link|pma-update|panel-passwd-hash|service|block|unblock|allow-add|allow-del|fw-auto|cron-add|cron-edit|cron-del|cron-on|cron-off|cron-run|backup-start|bk-restore|bk-delete|bk-conf|bk-remote-add|bk-remote-test|bk-remote-del|site-domains|server-mode|panel-domain|panel-allow|ports-access|panel-user|panel-2fa|bk-key|mail-enable|mail-domain-add|mail-domain-del|mail-box-add|mail-box-set|mail-box-del|mail-alias-set|mail-alias-del|mail-settings|mail-av|mail-dns-check|mail-site|mail-queue|mail-list|site-ftp|ftp-settings|pma-settings|protect-settings|dns-enable|dns-zone-add|dns-zone-del|dns-rec-add|dns-rec-del|dns-sync|dns-check|logs-settings|terminal-start|terminal-stop|geoip-update|geo-block|overload-settings|alerts-settings|alerts-test|proc-kill|proc-kill-site|sentinel-run|sentinel-settings|site-perf|cache-purge|opcache-settings|opcache-reset|db-tune|db-slow-report|site-webp|net-tune|brotli|dns-rec-edit|dns-reset|dns-template|dns-import|dns-propagation|dns-settings|dns-restart|dns-server-check|update-token|update-check|update-start|update-rollback|update-key|os-check|os-start|os-auto|reboot|refresh)
          out=$(dispatch "$action" "${args[@]}" 2>&1); rc=$? ;;
        *)
          out="Ação não permitida."; rc=1 ;;
      esac
      if ! write_state 2>/dev/null; then
        out="${out:+$out
}AVISO: não foi possível gerar o estado do painel (corre 'mpanel state' no servidor para ver o erro)."
        [ "$rc" -eq 0 ] && [ "$action" = refresh ] && rc=1
      fi
      write_result "$id" "$rc" "$out"
    done
  done
  return 0
}

usage(){
  cat <<'EOF'
IDDigital Hosting — CLI v2.13.0 (mpanel)
Uso: mpanel <comando> [argumentos]

Sites
  site-list
  site-add <nome> [--port N] [--php X.Y] [opções de limites, ver site-limits]
  site-del <nome> [--keep-files]
  site-php <nome> <X.Y>
  site-enable <nome>
  site-disable <nome>
  site-fixperms <nome>
  site-limits <nome>                       mostra os limites
  site-limits <nome> [--memory MB] [--upload MB] [--exec S]
                     [--input-time S] [--input-vars N] [--display-errors 0|1]

Extensões PHP (por versão; afetam todos os sites dessa versão)
  ext-list [X.Y]
  ext-add <X.Y> <extensão>
  ext-del <X.Y> <extensão>

Bases de dados (utilizador com o mesmo nome, acesso por localhost)
  db-list
  db-add <nome> [password]
  db-del <nome>
  db-passwd <nome> [password]
  db-admin-passwd [password]   cria ou muda a conta de administração (mpadmin)

phpMyAdmin (https://IP:PORTA-DO-PAINEL/phpmyadmin/, requer sessão no painel)
  pma-update [--force]         instala ou atualiza para a versão oficial mais recente

Serviços
  service <nginx|mariadb|php-X.Y> <reload|restart|start|stop>
  stats                 utilização atual do servidor e de cada site

DNS autoritativo (NSD; só responde pelas zonas do painel)
  dns-enable --ns1 ns1.dominio.pt --ns2 ns2.dominio.pt [--ip IP] [--ip6 IPv6] [--hostmaster email]
  dns-zone-add|dns-zone-del <domínio>       zona com registos automáticos (sites, email, nameservers)
  dns-rec-add <zona> <nome> <tipo> <valor> [--ttl N] [--prio N]   tipos: A AAAA CNAME MX TXT NS SRV CAA
  dns-rec-del <zona> <id> | dns-sync [zona|all] | dns-check <zona>

Desempenho
  site-perf <site> [--cache 0|60|300|600|1800|3600] [--pm ondemand|dynamic] [--max-children N] [--slowlog 0..60]
  cache-purge <site>                   limpa a cache de página do site
  site-perf … [--redis on|off] [--redis-mem MB] [--static-days 0|7|30|365] [--webp on|off] [--webp-auto on|off]
  site-webp <site>                     converte as imagens JPG/PNG do site em WebP (imagem.jpg.webp)
  net-tune on|off                      afinação de rede (TCP BBR, filas maiores)

DNS (gestão avançada)
  dns-rec-edit <zona> <id> <nome> <tipo> <valor> [--ttl N|0] [--prio N]   (0 = TTL automático)
  dns-reset <zona>                     repõe os registos predefinidos do painel
  dns-template <zona> local|google|microsoft   email deste servidor, Google Workspace ou Microsoft 365
  dns-import <zona> "<texto BIND>"     acrescenta os registos de um ficheiro de zona
  dns-propagation <zona>               compara este servidor com a Google (8.8.8.8)
  dns-settings [--ttl N] [--refresh N] [--retry N] [--expire N] [--minimum N]
  dns-restart · dns-server-check       reinicia / verifica a saúde do servidor DNS
  brotli on|off                        compressão Brotli no nginx (além do gzip)
  opcache-settings [--memory auto|MB] [--revalidate S] · opcache-reset
  db-tune [--buffer auto|MB] [--slow on|off] [--slow-time S]   afina o MariaDB (reinicia-o; repõe se falhar)
  db-slow-report                       resume as consultas lentas para o painel

Sentinela (testa todos os serviços a cada minuto; repara e alerta)
  sentinel-run                         corre todos os testes agora
  sentinel-settings [--repair on|off] [--sites on|off] [--off "id id"]

Processos
  proc-kill <pid> [--force]            termina um processo (os essenciais são recusados)
  proc-kill-site <site> [--force]      termina todos os processos de um site

Alertas (SMS por bulksms.com e email pelo servidor de email deste servidor)
  alerts-settings [--sms on|off] [--sms-id ID] [--sms-secret S] [--sms-to +351…] [--email on|off] [--email-to x@y]
                  [--cpu 90] [--cpu-min 5] [--ram 90] [--disk 90] [--conn 70] [--mail-pct 20] [--mail-min 50]
  alerts-test                          envia uma mensagem de teste
  alert-send "texto"                   envia um alerta pelos canais ativos

Países e limite de ligações
  geoip-update                         atualiza a base de países (DB-IP Lite, CC BY 4.0; todos os meses sozinha)
  geo-block add|del <país>             bloqueia ligações novas de um país (ex.: CN)
  overload-settings [--on|--off] [--max auto|N] [--start 80] [--stop 60] [--home PT]
                                       ao chegar ao limite só aceita ligações novas do país do servidor

Terminal no painel (root; só com 2FA; sessões gravadas 90 dias em /var/log/minipainel/terminal)
  terminal-stop                        fecha o terminal aberto pelo painel

Logs dos sites (/var/log/minipainel/sites e /srv/www/<site>/logs)
  logs-settings --days N               dias a guardar (7 a 365; omissão 90)

Proteção contra força bruta (SSH, painel, email, webmail, FTP)
  protect-settings [--ssh on|off] [--ssh-fails N] [--panel-fails N] [--auth-fails N] [--window MIN]
                   [--ban1 1h] [--ban2 24h] [--ban3 7d|perm]   bloqueio; reincidentes em 30 dias: 2.ª e 3.ª+ vez

FTP / SFTP (uma conta por site; a mesma password nos dois)
  site-ftp <site> [--password P]       ativa ou muda a password (FTPS: utilizador <site>; SFTP: mp_<site>)
  site-ftp <site> --off                desativa
  ftp-settings [--plain on|off] [--pasv-ip IP|none]   FTP sem cifra; IP público para o modo passivo (NAT)
  pma-settings [--session MIN] [--exec S] [--upload MB]   tempos e limites do phpMyAdmin

Atualizações
  update-token set <github_pat_…> | clear   token do GitHub só de leitura (repositório privado)
  update-check                         procura uma versão nova do painel (version.json ou, se não existir, o install.sh)
  update-start [--allow-unsigned]      atualiza o painel (cópia automática e reposição se falhar)
  update-rollback [ficheiro]           repõe uma cópia anterior do painel
  update-key set "<PEM>" | clear       chave pública que assina as versões
  os-check | os-start [--security]     atualizações do sistema operativo
  os-auto on|off                       atualizações de segurança automáticas
  reboot                               reinicia o servidor dentro de 1 minuto

Email (Postfix + Dovecot + Rspamd)
  mail-enable --host mail.dominio.pt   instala e ativa o email
  mail-domain-add|mail-domain-del <domínio>
  mail-dns-info <domínio> | mail-dns-check <domínio>
  mail-box-add <email> [--password P] [--quota MB]    (sem password: gerada)
  mail-box-set <email> [--password P] [--quota MB] | mail-box-del <email>
  mail-alias-set <alias@dom|@dom> "dest1 dest2" | mail-alias-del <alias>
  mail-site <site> --limit N | --suspend | --resume | --purge   envio do mail() de cada site
  mail-queue list|flush|delete <id>|all
  mail-settings [--dnsbl "zona1 zona2"|none] [--site-limit N] [--box-limit N] [--auth-fails N]
  mail-av on|off                       antivírus ClamAV (~1,2 GB de RAM)
  mail-list allow|deny add|del <email|@domínio|IP>   listas de remetentes permitidos e bloqueados

Segurança do painel
  panel-allow "IP rede/24 ..."|none    IPs autorizados a abrir o painel (none = todos)
  panel-user <nome>                    muda o nome de utilizador do painel
  panel-2fa off                        desativa a verificação em dois passos (recuperação na consola)
  ports-access all|lan                 portas dos sites abertas a todos ou só à rede local

Modo do servidor, domínios e SSL
  server-mode lan|internet [--email endereço]
  site-domains <site> --set "loja.pt www.loja.pt" [--ssl le|self|none] [--https 1|0] [--www keep|www|root]
  panel-domain <domínio>|none [--ssl le|self]
  ssl-renew                            renova os certificados Let's Encrypt (é automático)
  ngx-sync                             regenera a configuração nginx de todos os sites

Backups (local em /var/backups/minipainel + destinos remotos via rclone)
  backup-run [--site <site>|_bd|_sistema] [--remote <destino>]   faz backup agora
  bk-list [site]
  bk-restore <site>|_bd <id> [--what all|files|db]   repõe (faz antes um backup do estado atual)
  bk-delete <site> <id>
  bk-conf [--on|--off] [--time 03:00] [--daily 7] [--weekly 4] [--monthly 3] [--remote <destino>|none]
  bk-remote-add <nome> sftp --host H --user U --pass P [--port 22] [--path pasta]
  bk-remote-add <nome> s3 --access A --secret S --bucket B [--endpoint E] [--region R] [--provider Other]
  bk-remote-add <nome> rclone --config "[nome]\ntype = drive\n..."
  bk-remote-test <nome> | bk-remote-del <nome>
  bk-key | bk-key-set <chave>          chave que assina os backups (precisa dela para repor noutro servidor)
  db-link <base-de-dados> <site>|none   associa uma base de dados a um site (entra nos backups dele)

Tarefas agendadas (cron; correm como o utilizador do site)
  cron-list [site]
  cron-add <site> --when "*/5 * * * *" --cmd "php /srv/www/<site>/public_html/cron.php" [--label texto] [--off]
  cron-edit <site> <id> [--when ...] [--cmd ...] [--label ...]
  cron-on|cron-off|cron-run|cron-del <site> <id>
  cron-sync                            regenera os ficheiros de /etc/cron.d

Ligações e firewall (bloqueio em todas as portas, incluindo SSH)
  conn-list [ip]                       ligações abertas por IP
  block <ip|rede> [--for 1h|24h|7d|perm] [--reason texto]
  unblock <ip|rede>
  block-list
  allow-add <ip|rede> | allow-del <ip|rede>   IPs de confiança (nunca bloqueados)
  fw-auto on|off [--limit N] [--duration 1h]  bloqueio automático por excesso de ligações
  fw-restore                           repõe a tabela nftables e os bloqueios

Gestor de ficheiros
  fm-sync               recria os processos do gestor de ficheiros de todos os sites

Sistema
  php-list
  status
  passwd [--random]     muda a password do painel
  state                 regenera o estado lido pelo painel
EOF
}

