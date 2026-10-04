# ============================ ALERTAS (SMS bulksms.com e email) ==============
ALERT_CONF=/etc/minipainel/alerts.conf
ALERT_LOG=$DATA/stats/alerts.log
aget(){ local v; v=$(grep -m1 "^$1=" "$ALERT_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-${2:-}}"; }
aset(){ touch "$ALERT_CONF"; chmod 600 "$ALERT_CONF"; if grep -q "^$1=" "$ALERT_CONF"; then sed -i "s|^$1=.*|$1=$2|" "$ALERT_CONF"; else echo "$1=$2" >> "$ALERT_CONF"; fi; }
sms_send(){ # texto -> 0 enviado
  local id sec to body tmp code
  id=$(aget SMS_ID); sec=$(aget SMS_SECRET); to=$(aget SMS_TO)
  [ -n "$id" ] && [ -n "$sec" ] && [ -n "$to" ] || return 2
  body=$(printf '%s' "$1" | cut -c1-450)
  tmp=$(mktemp); chmod 600 "$tmp"
  jq -n --arg t "$to" --arg b "$body" '{to: ($t | split(",") | map(gsub("\\s"; ""))), body: $b, encoding: "UNICODE"}' > "$tmp"
  # credenciais lidas de um descritor (nunca na linha de comandos)
  code=$(curl -sS -m 25 -o /dev/null -w '%{http_code}' -K <(printf 'user = "%s:%s"\n' "$id" "$sec") \
        -H 'Content-Type: application/json' --data-binary @"$tmp" "${MP_BULKSMS_URL:-https://api.bulksms.com/v1/messages}" 2>/dev/null)
  rm -f "$tmp"
  [ "$code" = 201 ] || [ "$code" = 200 ]
}
alert_mail_send(){ # assunto texto -> 0 enviado
  local to from; to=$(aget EMAIL_TO)
  [ -n "$to" ] && mail_on || return 2
  from="alertas@$(mail_get HOST)"
  { printf 'From: IDDigital Hosting <%s>\nTo: %s\nSubject: =?UTF-8?B?%s?=\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\nX-MP-Alert: 1\n\n' \
      "$from" "$to" "$(printf '%s' "$1" | base64 -w0)"
    printf '%s\n\n-- \nServidor %s (%s)\n' "$2" "$(hostname -f 2>/dev/null || hostname)" "$(date '+%d/%m/%Y %H:%M')"; } | /usr/sbin/sendmail -t -i -f "$from"
}
cmd_alert_send(){ # "texto" [--level crit|warn|ok] [--key chave]
  local msg="${1:-}" lvl=warn key=manual s="off" e="off" host
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do case "$1" in --level) lvl="${2:-warn}"; shift 2 || shift ;; --key) key="${2:-manual}"; shift 2 || shift ;; *) shift ;; esac; done
  [ -n "$msg" ] || die "Indica o texto do alerta."
  host=$(hostname -s)
  if [ "$(aget SMS_ON 0)" = 1 ]; then if sms_send "[$host] $msg"; then s=ok; else s=falhou; fi; fi
  if [ "$(aget EMAIL_ON 0)" = 1 ]; then if alert_mail_send "[$host] $(printf '%s' "$msg" | cut -c1-80)" "$msg"; then e=ok; else e=falhou; fi; fi
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$DATA/stats"
  jq -cn --arg m "$msg" --arg l "$lvl" --arg k "$key" --arg s "$s" --arg e "$e" --argjson t "$EPOCHSECONDS" '{ts:$t, key:$k, level:$l, msg:$m, sms:$s, email:$e}' >> "$ALERT_LOG"
  chown root:"$PANEL_SYSUSER" "$ALERT_LOG"; chmod 640 "$ALERT_LOG"
  tail -n 2000 "$ALERT_LOG" > "$ALERT_LOG.tmp" && mv -f "$ALERT_LOG.tmp" "$ALERT_LOG"; chown root:"$PANEL_SYSUSER" "$ALERT_LOG"; chmod 640 "$ALERT_LOG"
  echo "Alerta registado (SMS: $s; email: $e)."
  return 0
}
cmd_alerts_settings(){
  local k v re_n='^[0-9]{1,3}$' re_tel='^\+?[0-9]{9,15}(,\+?[0-9]{9,15})*$'
  while [ $# -gt 0 ]; do
    k=$1; v="${2:-}"
    case "$k" in
      --sms) case "$v" in on) aset SMS_ON 1 ;; off) aset SMS_ON 0 ;; *) die "--sms on|off" ;; esac ;;
      --email) case "$v" in on) aset EMAIL_ON 1 ;; off) aset EMAIL_ON 0 ;; *) die "--email on|off" ;; esac ;;
      --sms-id) [[ "$v" =~ ^[A-Za-z0-9_-]{4,80}$ ]] || die "Token ID inválido."; aset SMS_ID "$v" ;;
      --sms-secret) [[ "$v" =~ ^[A-Za-z0-9_.+/=-]{4,200}$ ]] || die "Token secreto inválido."; aset SMS_SECRET "$v" ;;
      --sms-to) v=${v// /}; [[ "$v" =~ $re_tel ]] || die "Número inválido (formato internacional, ex.: +351912345678; vários separados por vírgulas)."; aset SMS_TO "$v" ;;
      --email-to) [[ "$v" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] || die "Email inválido."; aset EMAIL_TO "$v" ;;
      --cpu|--ram|--disk|--conn) [[ "$v" =~ $re_n ]] && [ "$v" -ge 10 ] && [ "$v" -le 100 ] || die "$k: percentagem entre 10 e 100."; aset "$(printf '%s' "${k#--}" | tr a-z A-Z)" "$v" ;;
      --cpu-min) [[ "$v" =~ $re_n ]] && [ "$v" -ge 1 ] && [ "$v" -le 120 ] || die "Minutos entre 1 e 120."; aset CPU_MIN "$v" ;;
      --mail-pct) [[ "$v" =~ $re_n ]] && [ "$v" -ge 5 ] && [ "$v" -le 500 ] || die "Percentagem entre 5 e 500."; aset MAIL_PCT "$v" ;;
      --mail-min) [[ "$v" =~ ^[0-9]{1,6}$ ]] && [ "$v" -ge 1 ] || die "Mínimo inválido."; aset MAIL_MIN "$v" ;;
      *) die "Opção desconhecida: $k" ;;
    esac
    shift 2 || shift
  done
  echo "Alertas guardados."; return 0
}
cmd_alerts_test(){
  [ "$(aget SMS_ON 0)" = 1 ] || [ "$(aget EMAIL_ON 0)" = 1 ] || die "Ativa primeiro o SMS ou o email."
  cmd_alert_send "Teste de alertas do IDDigital Hosting: se recebeste esta mensagem, os alertas estão a funcionar." --level ok --key teste
}
alerts_state_json(){
  local first n=0
  first=$(head -n1 "$DATA/stats/mail-vol.csv" 2>/dev/null | cut -d, -f1); [[ "$first" =~ ^[0-9]+$ ]] || first=0
  [ "$first" -gt 0 ] && n=$(( (EPOCHSECONDS - first) / 86400 ))
  jq -n --arg so "$(aget SMS_ON 0)" --arg sid "$(aget SMS_ID)" --arg ss "$([ -n "$(aget SMS_SECRET)" ] && echo 1 || echo 0)" --arg st "$(aget SMS_TO)" \
     --arg eo "$(aget EMAIL_ON 0)" --arg et "$(aget EMAIL_TO "$(srv_get EMAIL '')")" --arg mo "$(mail_on && echo 1 || echo 0)" \
     --arg cpu "$(aget CPU 90)" --arg cm "$(aget CPU_MIN 5)" --arg ram "$(aget RAM 90)" --arg disk "$(aget DISK 90)" --arg conn "$(aget CONN 70)" \
     --arg mp "$(aget MAIL_PCT 20)" --arg mm "$(aget MAIL_MIN 50)" --arg f "$first" --arg n "$n" \
     '{sms_on:($so=="1"), sms_id:$sid, sms_secret:($ss=="1"), sms_to:$st, email_on:($eo=="1"), email_to:$et, mail_on:($mo=="1"),
       cpu:($cpu|tonumber), cpu_min:($cm|tonumber), ram:($ram|tonumber), disk:($disk|tonumber), conn:($conn|tonumber),
       mail_pct:($mp|tonumber), mail_min:($mm|tonumber), learn_start:($f|tonumber), learn_days:($n|tonumber)}'
}

