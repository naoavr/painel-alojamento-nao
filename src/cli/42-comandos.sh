dispatch(){
  local c="$1"; shift
  case "$c" in
    site-list)         cmd_site_list ;;
    site-add)          cmd_site_add "$@" ;;
    site-del)          cmd_site_del "$@" ;;
    site-php)          cmd_site_php "$@" ;;
    site-enable)       cmd_site_toggle "${1:-}" 1 ;;
    site-disable)      cmd_site_toggle "${1:-}" 0 ;;
    site-fixperms)     cmd_site_fixperms "$@" ;;
    site-limits)       cmd_site_limits "$@" ;;
    ext-list)          cmd_ext_list "$@" ;;
    ext-add)           cmd_ext_add "$@" ;;
    ext-del)           cmd_ext_del "$@" ;;
    db-list)           cmd_db_list ;;
    db-add)            cmd_db_add "$@" ;;
    db-del)            cmd_db_del "$@" ;;
    db-passwd)         cmd_db_passwd "$@" ;;
    db-admin-passwd)   cmd_db_admin_passwd "$@" ;;
    pma-update)        cmd_pma_update "$@" ;;
    php-list)          cmd_php_list ;;
    service)           cmd_service "$@" ;;
    stats)             cmd_stats ;;
    conn-list)         cmd_conn_list "$@" ;;
    block)             cmd_block "$@" ;;
    unblock)           cmd_unblock "$@" ;;
    block-list)        cmd_block_list ;;
    allow-add)         cmd_allow_add "$@" ;;
    allow-del)         cmd_allow_del "$@" ;;
    fw-auto)           cmd_fw_auto "$@" ;;
    fw-restore)        cmd_fw_restore ;;
    cron-list)         cmd_cron_list "$@" ;;
    cron-add)          cmd_cron_add "$@" ;;
    cron-edit)         cmd_cron_edit "$@" ;;
    cron-del)          cmd_cron_del "$@" ;;
    cron-on)           cmd_cron_toggle "${1:-}" "${2:-}" true ;;
    cron-off)          cmd_cron_toggle "${1:-}" "${2:-}" false ;;
    cron-run)          cmd_cron_run "$@" ;;
    cron-sync)         cmd_cron_sync ;;
    db-link)           cmd_db_link "$@" ;;
    site-domains)      cmd_site_domains "$@" ;;
    server-mode)       cmd_server_mode "$@" ;;
    panel-domain)      cmd_panel_domain "$@" ;;
    ssl-renew)         cmd_ssl_renew ;;
    ngx-sync)          cmd_ngx_sync ;;
    panel-allow)       cmd_panel_allow "$@" ;;
    ports-access)      cmd_ports_access "$@" ;;
    panel-user)        cmd_panel_user "$@" ;;
    panel-2fa)         cmd_panel_2fa "$@" ;;
    mail-enable)       cmd_mail_enable "$@" ;;
    mail-domain-add)   cmd_mail_domain_add "$@" ;;
    mail-domain-del)   cmd_mail_domain_del "$@" ;;
    mail-box-add)      cmd_mail_box_add "$@" ;;
    mail-box-set)      cmd_mail_box_set "$@" ;;
    mail-box-del)      cmd_mail_box_del "$@" ;;
    mail-alias-set)    cmd_mail_alias_set "$@" ;;
    mail-alias-del)    cmd_mail_alias_del "$@" ;;
    mail-settings)     cmd_mail_settings "$@" ;;
    mail-av)           cmd_mail_av "$@" ;;
    mail-dns-check)    cmd_mail_dns_check "$@" ;;
    mail-dns-info)     cmd_mail_dns_info "$@" ;;
    mail-site)         cmd_mail_site "$@" ;;
    mail-queue)        cmd_mail_queue "$@" ;;
    mail-list)         cmd_mail_list "$@" ;;
    site-ftp)          cmd_site_ftp "$@" ;;
    ftp-settings)      cmd_ftp_settings "$@" ;;
    pma-settings)      cmd_pma_settings "$@" ;;
    protect-settings)  cmd_protect_settings "$@" ;;
    dns-enable)        cmd_dns_enable "$@" ;;
    dns-zone-add)      cmd_dns_zone_add "$@" ;;
    dns-zone-del)      cmd_dns_zone_del "$@" ;;
    dns-rec-add)       cmd_dns_rec_add "$@" ;;
    dns-rec-del)       cmd_dns_rec_del "$@" ;;
    dns-sync)          cmd_dns_sync "$@" ;;
    dns-check)         cmd_dns_check "$@" ;;
    logs-settings)     cmd_logs_settings "$@" ;;
    terminal-start)    cmd_terminal_start "$@" ;;
    terminal-stop)     cmd_terminal_stop ;;
    geoip-update)      cmd_geoip_update ;;
    alerts-settings)   cmd_alerts_settings "$@" ;;
    proc-kill)         cmd_proc_kill "$@" ;;
    sentinel-settings) cmd_sentinel_settings "$@" ;;
    site-perf)         cmd_site_perf "$@" ;;
    cache-purge)       cmd_cache_purge "$@" ;;
    perf-sync)         cmd_perf_sync ;;
    dns-cleanup)       cmd_dns_cleanup ;;
    dns-rec-edit)      cmd_dns_rec_edit "$@" ;;
    dns-reset)         cmd_dns_reset "$@" ;;
    dns-template)      cmd_dns_template "$@" ;;
    dns-import)        cmd_dns_import "$@" ;;
    dns-propagation)   cmd_dns_propagation "$@" ;;
    dns-settings)      cmd_dns_settings "$@" ;;
    dns-restart)       cmd_dns_restart ;;
    dns-server-check)  cmd_dns_server_check ;;
    dns-secondary)     cmd_dns_secondary "$@" ;;
    fm-xfer)           cmd_fm_xfer "$@" ;;
    site-webp)         cmd_site_webp "$@" ;;
    webp-nightly)      cmd_webp_nightly ;;
    net-tune)          cmd_net_tune "$@" ;;
    brotli)            cmd_brotli "$@" ;;
    opcache-settings)  cmd_opcache_settings "$@" ;;
    opcache-reset)     cmd_opcache_reset ;;
    db-tune)           cmd_db_tune "$@" ;;
    db-slow-report)    cmd_db_slow_report ;;
    sentinel-run)      cmd_sentinel_run ;;
    proc-kill-site)    cmd_proc_kill_site "$@" ;;
    alerts-test)       cmd_alerts_test ;;
    geo-block)         cmd_geo_block "$@" ;;
    overload-settings) cmd_overload_settings "$@" ;;
    trust-sync)        trust_apply; echo "IPs de confiança atualizados na firewall." ;;
    conf-lock)         conf_lock ;;
    update-check)      cmd_update_check ;;
    update-start)      cmd_update_start "$@" ;;
    update-rollback)   cmd_update_rollback "$@" ;;
    update-key)        cmd_update_key "$@" ;;
    update-token)      cmd_update_token "$@" ;;
    os-check)          cmd_os_check ;;
    os-start)          cmd_os_start "$@" ;;
    os-auto)           cmd_os_auto "$@" ;;
    reboot)            cmd_reboot ;;
    backup-start)      cmd_backup_start "$@" ;;
    bk-list)           cmd_bk_list "$@" ;;
    bk-restore)        cmd_bk_restore "$@" ;;
    bk-delete)         cmd_bk_delete "$@" ;;
    bk-conf)           cmd_bk_conf "$@" ;;
    bk-init)           cmd_bk_init ;;
    bk-remote-add)     cmd_bk_remote_add "$@" ;;
    bk-remote-test)    cmd_bk_remote_test "$@" ;;
    bk-remote-del)     cmd_bk_remote_del "$@" ;;
    bk-key)            cmd_bk_key ;;
    bk-key-set)        cmd_bk_key_set "$@" ;;
    fm-sync)           cmd_fm_sync ;;
    status)            cmd_status ;;
    passwd)            cmd_passwd "$@" ;;
    panel-passwd-hash) cmd_panel_hash "$@" ;;
    state|refresh)     return 0 ;;
    *)                 die "Comando desconhecido: $c (usa 'mpanel help')." ;;
  esac
}

# ---------- main ----------
cmd="${1:-help}"
case "$cmd" in
  help|-h|--help)       usage; exit 0 ;;
  version|-v|--version) echo "IDDigital Hosting $MP_VERSION (MiniPainel)"; exit 0 ;;
esac
[ "$(id -u)" -eq 0 ] || die "Tem de ser executado como root."
# o backup usa o seu próprio bloqueio, para não impedir as outras operações do painel
if [ "$cmd" = backup-run ]; then shift; cmd_backup_run "$@"; exit $?; fi
if [ "$cmd" = mail-spool ]; then cmd_mail_spool; exit $?; fi
# o envio de alertas só lê a configuração e escreve o histórico: nunca espera por outra operação
if [ "$cmd" = alert-send ]; then shift; cmd_alert_send "$@"; exit $?; fi
# o sentinela tem o seu próprio bloqueio: uma operação longa do painel nunca o atrasa
if [ "$cmd" = sentinel-run ]; then cmd_sentinel_run; exit $?; fi
# as atualizações têm bloqueio próprio: o instalador volta a chamar o mpanel durante a instalação
if [ "$cmd" = update-run ]; then shift; cmd_update_run "$@"; exit $?; fi
if [ "$cmd" = os-run ]; then shift; cmd_os_run "$@"; exit $?; fi
exec 9>"$LOCK"
flock -w 300 9 || die "Outra operação do painel está em curso."

if [ "$cmd" = worker ]; then cmd_worker; exit 0; fi

dispatch "$@"; rc=$?
if [ "$rc" -eq 0 ]; then
  case "$cmd" in
    site-add|site-del|site-php|site-enable|site-disable|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|pma-update|service|cron-add|cron-edit|cron-del|cron-on|cron-off|site-domains|server-mode|panel-domain|ngx-sync|panel-allow|ports-access|panel-user|panel-2fa|mail-enable|mail-domain-add|mail-domain-del|mail-box-add|mail-box-set|mail-box-del|mail-alias-set|mail-alias-del|mail-settings|mail-av|mail-site|mail-queue|mail-list|state|refresh)
      write_state || { echo "ERRO: não foi possível gerar o estado do painel ($STATE)." >&2; rc=1; } ;;
  esac
fi
exit "$rc"
