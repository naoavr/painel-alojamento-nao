#!/usr/bin/env bash
# =============================================================================
#  mpanel-cron — IDDigital Hosting v2.13.2
#  Executa uma tarefa agendada de um site. Corre como o utilizador do site
#  (mp_<site>), chamado pelo cron a partir de /etc/cron.d/minipainel-<site>.
#  Não deixa sobrepor execuções e regista a saída em logs/cron-<id>.log.
# =============================================================================
set -uo pipefail
site="${1:-}"; id="${2:-}"
re_s='^[a-z][a-z0-9-]{0,23}$'; re_i='^[a-f0-9]{8}$'
[[ "$site" =~ $re_s ]] && [[ "$id" =~ $re_i ]] || { echo "Parâmetros inválidos." >&2; exit 2; }
[ "$(id -un)" = "mp_$site" ] || { echo "Tem de correr como mp_$site." >&2; exit 2; }
d=/srv/www/$site
s=/etc/minipainel/cron/$site/$id.sh
log=$d/logs/cron-$id.log
st=$d/logs/cron-$id.status
[ -r "$s" ] || { echo "Tarefa não encontrada: $id" >&2; exit 2; }
umask 027
exec 9>"$d/tmp/.cron-$id.lock"
if ! flock -n 9; then
  printf '=== %s — ignorada: a execução anterior ainda não terminou ===\n' "$(date '+%d/%m/%Y %H:%M:%S')" >> "$log"
  exit 0
fi
start=$(date +%s)
printf '%s 0 running\n' "$start" > "$st"
printf '=== %s ===\n' "$(date '+%d/%m/%Y %H:%M:%S')" >> "$log"
export PATH="/etc/minipainel/cron/$site/bin:/usr/local/bin:/usr/bin:/bin" HOME="$d"
cd "$d/public_html" 2>/dev/null || cd "$d" || exit 1
/bin/sh "$s" >> "$log" 2>&1 9>&-
rc=$?
end=$(date +%s)
printf '%s %s %s\n' "$start" "$end" "$rc" > "$st"
printf '=== terminou com código %s em %ss ===\n' "$rc" "$(( end - start ))" >> "$log"
if [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"
fi
exit "$rc"
