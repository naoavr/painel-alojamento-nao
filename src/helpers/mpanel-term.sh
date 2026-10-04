#!/usr/bin/env bash
# =============================================================================
#  mpanel-term — IDDigital Hosting v2.13.1
#  Sessão de terminal aberta pelo painel (ttyd). Corre como root, grava a saída
#  em /var/log/minipainel/terminal/<sessão>.log (com tempos para scriptreplay)
#  e termina ao fim de 15 minutos sem atividade.
# =============================================================================
id=${1:-}
[[ "$id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || exit 2
LOG=/var/log/minipainel/terminal
umask 027
export TERM=xterm-256color TMOUT=900 HOME=/root
cd /root || exit 1
printf '\033[1;33mIDDigital Hosting — terminal root.\033[0m Esta sessão está a ser gravada. Fecha com "exit".\r\n\r\n'
exec script -q -f -T "$LOG/$id.timing" -O "$LOG/$id.log" -c "TMOUT=900 exec bash -l"
