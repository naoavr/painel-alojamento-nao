write_state(){
  local n v st sites phps dbs
  sites=$(for n in $(site_names); do
      jq -cn --arg name "$n" --arg port "$(site_get "$n" PORT)" --arg php "$(site_get "$n" PHP)" \
        --arg en "$(site_get "$n" ENABLED)" --arg root "$WWW_ROOT/$n/public_html" \
        --arg mem "$(lim_get "$n" MEM)" --arg up "$(lim_get "$n" UPLOAD)" --arg ex "$(lim_get "$n" EXEC)" \
        --arg it "$(lim_get "$n" INPUT_TIME)" --arg iv "$(lim_get "$n" INPUT_VARS)" --arg de "$(lim_get "$n" DISPLAY_ERRORS)" \
        --arg doms "$(site_get "$n" DOMAINS)" --arg ssl "$(site_get "$n" SSL)" --arg hs "$(site_get "$n" HTTPS)" --arg www "$(site_get "$n" WWW)" \
        --arg prd "$(site_get "$n" REDIS)" --arg prm "$(site_get "$n" REDIS_MB)" --arg psd "$(site_get "$n" STATIC_DAYS)" --arg pwp "$(site_get "$n" WEBP)" --arg pwa "$(site_get "$n" WEBP_AUTO)" --arg psk "$(rds_sock "$n")" \
        --arg pc "$(site_get "$n" CACHE)" --arg ppm "$(site_get "$n" PM)" --arg pmc "$(site_get "$n" MAXCH)" --arg psl "$(site_get "$n" SLOW)" \
        --arg ftp "$(site_get "$n" FTP)" --arg sexp "$(cert_expiry "mp-$n")" --arg cok "$( [ -n "$(site_get "$n" DOMAINS)" ] && [ "$(site_get "$n" SSL)" != none ] && cert_files "mp-$n" >/dev/null && echo 1)" \
        '{name:$name, port:($port|tonumber), php:$php, enabled:($en=="1"), root:$root,
          limits:{memory:($mem|tonumber), upload:($up|tonumber), exec:($ex|tonumber),
                  input_time:($it|tonumber), input_vars:($iv|tonumber), display_errors:($de=="1")},
          domains:$doms, ssl:(if $ssl == "" then "none" else $ssl end), https:(if $hs == "" then "1" else $hs end), www:(if $www == "" then "keep" else $www end),
          ssl_exp:(if $sexp == "" then null else ($sexp|tonumber) end), https_ok:($cok == "1"), ftp:($ftp == "1"),
          perf:{cache:(($pc | tonumber?) // 0), pm:(if $ppm == "" then "ondemand" else $ppm end), maxch:(($pmc | tonumber?) // 10), slow:(($psl | tonumber?) // 5),
                redis:($prd == "1"), redis_mb:(($prm | tonumber?) // 128), static_days:(($psd | tonumber?) // 30), webp:($pwp != "0"), webp_auto:($pwa == "1"), sock:$psk}}'
    done | jq -cs '.')
  pkg_cache_load
  phps=$(for v in $(php_installed); do
      local exts mods en ed inst
      st=$(systemctl is-active "$(php_service "$v")" 2>/dev/null)
      exts=$(while IFS='|' read -r en _ _ ed; do
          inst=false; ext_installed_pkg "$en" "$v" >/dev/null && inst=true
          jq -cn --arg n "$en" --arg d "$ed" --argjson i "$inst" '{name:$n, desc:$d, installed:$i}'
        done < <(ext_catalog) | jq -cs '.')
      mods=$("$(php_cli "$v")" -m 2>/dev/null | grep -v -e '^\[' -e '^$' | sort -fu | jq -R . | jq -cs '.')
      jq -cn --arg v "$v" --arg s "$st" --argjson e "${exts:-[]}" --argjson m "${mods:-[]}" \
        '{version:$v, active:($s=="active"), extensions:$e, modules:$m}'
    done | jq -cs '.')
  local svcs host ip os up disk ram load cpus pmav dbadm=false
  pmav=$(pma_version)
  dbuser_exists "$DB_ADMIN" && dbadm=true
  svcs=$( {
      jq -cn --arg s "$(systemctl is-active nginx 2>/dev/null)" '{id:"nginx", name:"nginx", unit:"nginx", active:($s=="active")}'
      jq -cn --arg s "$(systemctl is-active mariadb 2>/dev/null)" '{id:"mariadb", name:"MariaDB", unit:"mariadb", active:($s=="active")}'
      for v in $(php_installed); do
        jq -cn --arg v "$v" --arg u "$(php_service "$v")" --arg s "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)" --arg p "$PANEL_PHP" \
          '{id:("php-"+$v), name:("PHP-FPM "+$v), unit:$u, active:($s=="active"), panel:($v==$p), version:$v}'
      done
      if mail_on; then
        for v in postfix dovecot rspamd redis unbound; do
          u=$v; [ "$v" = redis ] && u=$(mail_svc_redis)
          jq -cn --arg i "$v" --arg u "$u" --arg s "$(systemctl is-active "$u" 2>/dev/null)" \
            '{id:$i, name:({"postfix":"Postfix (SMTP)","dovecot":"Dovecot (IMAP/POP3)","rspamd":"Rspamd (antispam)","redis":"Redis","unbound":"Unbound (DNS)"}[$i]), unit:$u, active:($s=="active"), mail:true}'
        done
        if [ "$(mail_get CLAMAV 0)" = 1 ]; then u=clamav-daemon; [ "$OS_FAMILY" = debian ] || u=clamd@scan
          jq -cn --arg u "$u" --arg s "$(systemctl is-active "$u" 2>/dev/null)" '{id:"clamav", name:"ClamAV (antivírus)", unit:$u, active:($s=="active"), mail:true}'; fi
      fi
    } | jq -cs '.')
  host=$(hostname 2>/dev/null)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  os=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
  disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo 2>/dev/null)
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  cpus=$(nproc 2>/dev/null)
  dbs=$(db_sizes | while IFS=$'\t' read -r n v; do
      [ -n "$n" ] && jq -cn --arg n "$n" --arg s "$v" --arg site "$(dbmap_load | jq -r --arg d "$n" '.[$d] // ""')" '{name:$n, size_mb:($s|tonumber), site:$site}'
    done | jq -cs '.')
  local j_crons j_mail j_snaps
  j_crons=$(cron_state_json 2>/dev/null); j_mail=$(mail_state_json 2>/dev/null); j_snaps=$(upd_snaps_json 2>/dev/null)
  sites=$(jv sites "$sites" '[]'); phps=$(jv php "$phps" '[]'); dbs=$(jv databases "$dbs" '[]'); svcs=$(jv services "$svcs" '[]')
  dbadm=$(jv db_admin "$dbadm" 'false'); j_crons=$(jv crons "$j_crons" '[]'); j_mail=$(jv mail "$j_mail" '{"enabled":false}'); j_snaps=$(jv snaps "$j_snaps" '[]')
  jq -n --argjson sites "${sites:-[]}" --argjson php "${phps:-[]}" --argjson dbs "${dbs:-[]}" --argjson svcs "${svcs:-[]}" \
    --arg host "$host" --arg ip "$ip" --arg os "$os" --arg up "${up:-0}" --arg disk "${disk:-0}" --arg ram "${ram:-0}" \
    --arg load "${load:-0}" --arg cpus "${cpus:-1}" --arg pport "$PANEL_PORT" --arg pphp "$PANEL_PHP" \
    --arg pmav "$pmav" --argjson dbadm "$dbadm" --arg dbadmu "$DB_ADMIN" --argjson crons "$j_crons" \
    --argjson mail "$j_mail" \
    --argjson usnaps "$j_snaps" \
    --argjson fti "$(ftp_installed && echo true || echo false)" --arg ftpl "$(ftp_get PLAIN 0)" --arg ftip "$(ftp_get PASV_IP)" \
    --argjson jdns "$(jv dns "$(dns_state_json 2>/dev/null)" '{"enabled":false}')" --arg ldays "$(logs_days)" \
    --argjson jgeo "$(jv geo "$(geo_state_json 2>/dev/null)" '{}')" \
    --argjson jal "$(jv alerts "$(alerts_state_json 2>/dev/null)" '{}')" \
    --arg snr "$(snget REPAIR 1)" --arg sns "$(snget SITES 1)" --arg sno "$(snget OFF '')" \
    --arg pf_opm "$(srv_get OPC_MEM auto)" --arg pf_opa "$(opc_mem_auto)" --arg pf_opr "$(srv_get OPC_REVAL 60)" --arg pf_dbp "$(srv_get DB_BP auto)" --arg pf_dba "$(db_bp_auto)" \
    --arg pf_net "$(srv_get NET_TUNE 0)" --arg pf_cc "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" --arg pf_br "$(srv_get BROTLI 0)" --arg pf_bro "$(brotli_ok && echo 1 || echo 0)" \
    --arg pf_dbs "$(srv_get DB_SLOW 1)" --arg pf_dbt "$(srv_get DB_SLOW_T 2)" --arg pf_ram "$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)" \
    --arg prs "$(pget SSH 1)" --arg prsf "$(pget SSH_FAILS 5)" --arg prpf "$(pget PANEL_FAILS 10)" --arg praf "$(pget AUTH_FAILS "$(mail_get AUTH_FAILS 10)")" \
    --arg prw "$(pget WINDOW 10)" --arg prb1 "$(pget BAN1 1h)" --arg prb2 "$(pget BAN2 24h)" --arg prb3 "$(pget BAN3 7d)" \
    --arg prr "$(awk -v s=$(( EPOCHSECONDS - 86400 )) '$1 >= s' "$DATA/stats/ban-history.txt" 2>/dev/null | wc -l)" \
    --arg pss "$(pma_get SESSION 120)" --arg pse "$(pma_get EXEC 600)" --arg psu "$(pma_get UPLOAD 512)" \
    --arg spa "$(srv_get PORTS_ACCESS all)" --arg spal "$(srv_get PANEL_ALLOW '')" \
    --arg smode "$(srv_get MODE lan)" --arg semail "$(srv_get EMAIL '')" --arg spd "$(srv_get PANEL_DOMAIN '')" --arg spssl "$(srv_get PANEL_SSL le)" --arg spexp "$( [ -n "$(srv_get PANEL_DOMAIN '')" ] && cert_expiry mp-painel)" \
    --arg defphp "$DEFAULT_PHP" --arg gen "$(date '+%Y-%m-%d %H:%M:%S')" --arg ver "$MP_VERSION" \
    --arg ng "$(systemctl is-active nginx 2>/dev/null)" --arg db "$(systemctl is-active mariadb 2>/dev/null)" \
    '{version:$ver, generated:$gen, default_php:$defphp, php:$php, sites:$sites, databases:$dbs,
      services:{nginx:($ng=="active"), mariadb:($db=="active")}, service_list:$svcs,
      pma:{installed:($pmav!=""), version:$pmav}, db_admin:{user:$dbadmu, exists:$dbadm}, crons:$crons,
      mail:$mail,
      updates:{snaps:$usnaps},
      ftp:{installed:$fti, plain:($ftpl == "1"), pasv_ip:$ftip},
      pma_settings:{session:($pss|tonumber), exec:($pse|tonumber), upload:($psu|tonumber)},
      dns:$jdns, log_days:($ldays|tonumber), geo:$jgeo, alerts:$jal,
      sentinel:{repair:($snr == "1"), sites:($sns == "1"), off:$sno},
      perf:{opc_mem:$pf_opm, opc_mem_auto:($pf_opa|tonumber), opc_reval:($pf_opr|tonumber), db_bp:$pf_dbp, db_bp_auto:($pf_dba|tonumber), db_slow:($pf_dbs == "1"), db_slow_t:($pf_dbt|tonumber), ram_mb:($pf_ram|tonumber),
            net:($pf_net == "1"), cc:$pf_cc, brotli:($pf_br == "1"), brotli_ok:($pf_bro == "1")},
      protect:{ssh:($prs == "1"), ssh_fails:($prsf|tonumber), panel_fails:($prpf|tonumber), auth_fails:($praf|tonumber), window:($prw|tonumber), ban1:$prb1, ban2:$prb2, ban3:$prb3, recent:($prr|tonumber)},
      server:{mode:$smode, email:$semail, panel_domain:$spd, panel_ssl:$spssl, panel_ssl_exp:(if $spexp == "" then null else ($spexp|tonumber) end), ports_access:$spa, panel_allow:$spal},
      system:{hostname:$host, ip:$ip, os:$os, uptime:($up|tonumber), disk:($disk|tonumber), ram:($ram|tonumber),
              load:$load, cpus:($cpus|tonumber), panel_port:($pport|tonumber), panel_php:$pphp}}' > "$STATE.tmp" || { rm -f "$STATE.tmp"; return 1; }
  chown root:"$PANEL_SYSUSER" "$STATE.tmp"; chmod 640 "$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE"
}

write_result(){
  local id=$1 rc=$2 msg=$3 okv=false
  [ "$rc" -eq 0 ] && okv=true
  jq -n --arg id "$id" --argjson ok "$okv" --arg msg "$msg" '{id:$id, ok:$ok, msg:$msg}' > "$RESULTS/.$id.tmp"
  chown root:"$PANEL_SYSUSER" "$RESULTS/.$id.tmp"; chmod 640 "$RESULTS/.$id.tmp"
  mv -f "$RESULTS/.$id.tmp" "$RESULTS/$id.json"
}

# Processa a fila do painel (chamado pelo minipainel-worker.service)
