# ============================ TERMINAL (ttyd, root, só com 2FA) ==============
TERM_RUN=/run/minipainel-term
TERM_LOG=/var/log/minipainel/terminal
TTYD_VER=1.7.7
TTYD_SHA_X86=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
TTYD_SHA_ARM=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
term_bin(){ if command -v ttyd >/dev/null 2>&1; then command -v ttyd; else echo /usr/local/lib/minipainel/ttyd; fi; }
term_install(){
  [ -x "$(term_bin)" ] && return 0
  if [ "$OS_FAMILY" = debian ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q ttyd >/dev/null 2>&1; else dnf install -y -q ttyd >/dev/null 2>&1; fi
  [ -x "$(term_bin)" ] && return 0
  # sem pacote na distribuição: binário oficial com versão e SHA-256 fixados
  local arch sha url tmp; arch=$(uname -m)
  case "$arch" in x86_64) sha=$TTYD_SHA_X86 ;; aarch64) sha=$TTYD_SHA_ARM ;; *) die "Arquitetura $arch sem ttyd disponível." ;; esac
  url="https://github.com/tsl0922/ttyd/releases/download/$TTYD_VER/ttyd.$arch"; tmp=$(mktemp)
  curl -fsSL -m 120 -o "$tmp" "$url" || { rm -f "$tmp"; die "Não foi possível descarregar o ttyd."; }
  [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$sha" ] || { rm -f "$tmp"; die "O ttyd descarregado não corresponde ao SHA-256 esperado; instalação recusada."; }
  install -d -m 755 /usr/local/lib/minipainel; install -m 755 "$tmp" /usr/local/lib/minipainel/ttyd; rm -f "$tmp"
}
term_2fa_on(){ jq -e '(.totp // "") != ""' "$AUTH" >/dev/null 2>&1; }
cmd_terminal_start(){
  local tok="${1:-}" re='^[a-f0-9]{32}$' bin w=() id i
  [[ "$tok" =~ $re ]] || die "Pedido inválido."
  term_2fa_on || die "O terminal só pode ser usado com a verificação em dois passos ativa (Conta)."
  term_install; bin=$(term_bin)
  cmd_terminal_stop >/dev/null 2>&1
  install -d -o root -g "$WEB_GROUP" -m 2750 "$TERM_RUN"
  install -d -o root -g "$PANEL_SYSUSER" -m 2750 "$TERM_LOG"
  "$bin" --help 2>&1 | grep -q -- '--writable' && w=(-W)
  id=$(date '+%Y%m%d-%H%M%S')
  local args=(-i "$TERM_RUN/term.sock" -b "/terminal/$tok" -o -O "${w[@]}" -t fontSize=14 -t disableLeaveAlert=true -t "titleFixed=Terminal — $(hostname -s)" /usr/local/sbin/mpanel-term "$id")
  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemd-run --quiet --collect --unit=minipainel-term --property=RuntimeMaxSec=14400 --property=UMask=0007 "$bin" "${args[@]}" >/dev/null 2>&1 || die "Não foi possível arrancar o terminal."
  else
    ( umask 007; setsid bash -c 'echo $$ > "$0"; exec timeout 4h "$@"' "$TERM_RUN/ttyd.pid" "$bin" "${args[@]}" >/dev/null 2>&1 < /dev/null 9>&- & )
  fi
  for i in $(seq 1 30); do [ -S "$TERM_RUN/term.sock" ] && break; sleep 0.2; done
  [ -S "$TERM_RUN/term.sock" ] || die "O terminal não arrancou."
  chgrp "$WEB_GROUP" "$TERM_RUN/term.sock" 2>/dev/null; chmod 660 "$TERM_RUN/term.sock" 2>/dev/null
  logger -t minipainel-audit -p authpriv.notice "terminal root aberto pelo painel (sessão $id)" 2>/dev/null
  echo "Terminal pronto (sessão $id; fecha ao fim de 15 min sem atividade)."
  return 0
}
cmd_terminal_stop(){
  systemctl stop minipainel-term >/dev/null 2>&1
  local pg; pg=$(cat "$TERM_RUN/ttyd.pid" 2>/dev/null)
  if [[ "$pg" =~ ^[0-9]+$ ]]; then kill -TERM -- "-$pg" >/dev/null 2>&1; sleep 0.3; kill -KILL -- "-$pg" >/dev/null 2>&1; fi
  rm -f "$TERM_RUN/term.sock" "$TERM_RUN/ttyd.pid"
  echo "Terminal fechado."; return 0
}

