#!/usr/bin/env bash
# =============================================================================
#  IDDigital Hosting (MiniPainel) — gera o install.sh a partir de src/
#    bash build.sh            -> escreve ./install.sh
#    bash build.sh destino.sh -> escreve noutro ficheiro
#  Cada linha "@@INCLUDE caminho@@" de src/installer.sh é substituída pelo
#  conteúdo desse ficheiro, sem nenhuma alteração.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
out=${1:-install.sh}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^@@INCLUDE\ (.+)@@$ ]]; then
    f=${BASH_REMATCH[1]}
    [ -f "$f" ] || { echo "Falta o ficheiro: $f" >&2; exit 1; }
    cat -- "$f"
  else
    printf '%s\n' "$line"
  fi
done < src/installer.sh > "$tmp"
bash -n "$tmp" || { echo "O install.sh gerado tem erros de sintaxe." >&2; exit 1; }
mv -f "$tmp" "$out"; trap - EXIT
chmod 755 "$out"
echo "Gerado $out — v$(grep -m1 -oE '^MP_VERSION="[0-9.]+"' "$out" | cut -d'"' -f2) · SHA-256 $(sha256sum "$out" | cut -d' ' -f1)"
