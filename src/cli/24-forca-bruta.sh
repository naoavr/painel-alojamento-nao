# ============================ PROTEÇÃO CONTRA FORÇA BRUTA ====================
PROT_CONF=/etc/minipainel/protect.conf
pget(){ local v; v=$(grep -m1 "^$1=" "$PROT_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
cmd_protect_settings(){
  local ssh sshf panf authf win b1 b2 b3 re='^[0-9]{1,4}$' rd='^([0-9]{1,4}[mhd]|perm)$'
  ssh=$(pget SSH 1); sshf=$(pget SSH_FAILS 5); panf=$(pget PANEL_FAILS 10); authf=$(pget AUTH_FAILS "$(mail_get AUTH_FAILS 10)")
  win=$(pget WINDOW 10); b1=$(pget BAN1 1h); b2=$(pget BAN2 24h); b3=$(pget BAN3 7d)
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh) case "${2:-}" in on) ssh=1 ;; off) ssh=0 ;; *) die "--ssh on|off" ;; esac; shift 2 || shift ;;
      --ssh-fails) sshf="${2:-}"; shift 2 || shift ;;
      --panel-fails) panf="${2:-}"; shift 2 || shift ;;
      --auth-fails) authf="${2:-}"; shift 2 || shift ;;
      --window) win="${2:-}"; shift 2 || shift ;;
      --ban1) b1="${2:-}"; shift 2 || shift ;;
      --ban2) b2="${2:-}"; shift 2 || shift ;;
      --ban3) b3="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  for v in "$sshf" "$panf" "$authf"; do [[ "$v" =~ $re ]] && [ "$v" -ge 3 ] && [ "$v" -le 100 ] || die "Número de falhas entre 3 e 100."; done
  [[ "$win" =~ $re ]] && [ "$win" -ge 1 ] && [ "$win" -le 1440 ] || die "Janela entre 1 e 1440 minutos."
  for v in "$b1" "$b2" "$b3"; do [[ "$v" =~ $rd ]] || die "Duração inválida: $v (ex.: 15m, 1h, 24h, 7d ou perm)."; done
  printf 'SSH=%s\nSSH_FAILS=%s\nPANEL_FAILS=%s\nAUTH_FAILS=%s\nWINDOW=%s\nBAN1=%s\nBAN2=%s\nBAN3=%s\n' "$ssh" "$sshf" "$panf" "$authf" "$win" "$b1" "$b2" "$b3" > "$PROT_CONF"
  chmod 600 "$PROT_CONF"
  mail_on && mail_set AUTH_FAILS "$authf"
  echo "Proteção: SSH $([ "$ssh" = 1 ] && echo "ativa ($sshf falhas)" || echo desligada), painel $panf falhas, email/FTP $authf falhas, em $win min; bloqueio $b1, reincidentes $b2, a partir da 3.ª vez $b3."
  return 0
}

