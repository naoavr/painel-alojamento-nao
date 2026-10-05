#!/usr/bin/env bash
# =============================================================================
#  mp-sendmail — IDDigital Hosting v2.15.1
#  Recebe o mail() do PHP de um site (corre como mp_<site>) e coloca a mensagem
#  na fila controlada pelo painel, que aplica limites, antispam e DKIM antes de
#  a entregar ao Postfix. Os sites não podem usar o sendmail nem a porta 25.
# =============================================================================
set -u
site=${1:-}; [ $# -gt 0 ] && shift
re='^[a-z][a-z0-9-]{0,23}$'
[[ "$site" =~ $re ]] || exit 75
[ "$(id -un)" = "mp_$site" ] || exit 77
[ -f /etc/minipainel/mail-enabled ] || { echo "O envio de email não está ativo neste servidor." >&2; exit 69; }
from=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|-r) from=${2:-}; shift 2 || shift ;;
    -f*) from=${1#-f}; shift ;;
    -r*) from=${1#-r}; shift ;;
    *) shift ;;
  esac
done
d=/var/spool/mp-mail/$site
[ -d "$d/new" ] && [ -d "$d/tmp" ] || exit 75
umask 077
id="$(date +%s%N).$$"
head -c 31457281 > "$d/tmp/$id.eml" || exit 75
if [ "$(stat -c %s "$d/tmp/$id.eml")" -gt 31457280 ]; then rm -f "$d/tmp/$id.eml"; echo "Mensagem demasiado grande (máx. 30 MB)." >&2; exit 75; fi
printf '%s\n' "${from:0:254}" > "$d/new/$id.from"
mv "$d/tmp/$id.eml" "$d/new/$id.eml"
exit 0
