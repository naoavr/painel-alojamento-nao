# ============================ PROCESSOS ======================================
proc_protected(){ # pid -> 0 se não pode ser terminado pelo painel
  local p=$1 comm args usr
  [ "$p" -le 2 ] && return 0
  [ -d "/proc/$p" ] || return 1
  comm=$(cat "/proc/$p/comm" 2>/dev/null); args=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null); usr=$(stat -c %U "/proc/$p" 2>/dev/null)
  [ -z "$args" ] && return 0                                    # threads do kernel
  [ "$p" = "$$" ] || [ "$p" = "$PPID" ] && return 0
  case "$comm" in systemd|systemd-*|init|dbus-daemon|dbus-broker|agetty|cron|crond|rsyslogd|journald|udevd|polkitd|mariadbd|mysqld|master|containerd|dockerd) return 0 ;; esac
  case "$args" in
    "nginx: master"*|"php-fpm: master"*|"php-fpm: pool minipainel"*|"sshd: /usr/sbin/sshd"*|"/usr/sbin/sshd"*|*mpanel-stats*|*"mpanel worker"*|"/usr/sbin/dovecot"*|"dovecot"|"/usr/sbin/nsd"*|"nsd -c"*) return 0 ;;
  esac
  [ "$usr" = minipainel ] && [[ "$args" == php-fpm* ]] && return 0
  return 1
}
cmd_proc_kill(){ # pid [--force]
  local p="${1:-}" sig=TERM desc
  [ "${2:-}" = --force ] && sig=KILL
  [[ "$p" =~ ^[0-9]{1,8}$ ]] || die "PID inválido."
  [ -d "/proc/$p" ] || die "O processo $p já não existe."
  proc_protected "$p" && die "O processo $p é essencial ao servidor ou ao painel e não pode ser terminado aqui (usa o Terminal, se tiveres a certeza)."
  desc="$(stat -c %U "/proc/$p" 2>/dev/null): $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"
  kill -s "$sig" "$p" 2>/dev/null || die "Não foi possível terminar o processo $p."
  sleep 1
  if [ -d "/proc/$p" ] && [ "$sig" = TERM ]; then echo "Pedido de fim enviado ao processo $p ($desc); ainda está a terminar. Se não terminar, usa 'Forçar'."
  else echo "Processo $p terminado ($desc)."; fi
  return 0
}
cmd_proc_kill_site(){ # site [--force]
  local n="${1:-}" sig=TERM c
  [ "${2:-}" = --force ] && sig=KILL
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  c=$(pgrep -u "mp_$n" | wc -l)
  [ "$c" -gt 0 ] || { echo "O site $n não tem processos a correr."; return 0; }
  pkill -"$sig" -u "mp_$n" 2>/dev/null
  echo "Terminados $c processos do site $n (o PHP do site volta a arrancar no próximo pedido)."
  return 0
}

