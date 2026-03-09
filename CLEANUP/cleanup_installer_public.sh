#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# UPG XML + ~/.cache cleanup installer
# Version: 1.0.1
#
# Co robi:
# - wstawia/odświeża blok w ~/.bashrc
# - przy wyjściu z interaktywnej sesji SSH usuwa:
#   1) /home/itgo/UPG/*.xml
#   2) zawartość ~/.cache (zostawia katalog)
#
# Uwaga:
# - dotyczy użytkownika, na którym uruchamiasz instalator (HOME)
# - ścieżka /home/itgo/UPG jest na stałe (jak u Ciebie); jeśli kiedyś
#   chcesz, można to parametryzować.
# ==========================================================

BASHRC="${HOME}/.bashrc"

BLOCK_START="# >>> UPG XML cleanup (auto) >>>"
BLOCK_END="# <<< UPG XML cleanup (auto) <<<"

SNIPPET=$(cat <<'EOF'
# >>> UPG XML cleanup (auto) >>>
cleanup_upg_xml_and_cache() {
  # 1) UPG XML
  shopt -s nullglob
  local files=(/home/itgo/UPG/*.xml)
  if (( ${#files[@]} )); then
    rm -f -- "${files[@]}"
  fi

  # 2) ~/.cache (czyść zawartość, zostaw katalog)
  shopt -s dotglob nullglob
  local cache_items=("${HOME}/.cache/"*)
  if (( ${#cache_items[@]} )); then
    rm -rf -- "${cache_items[@]}"
  fi
  shopt -u dotglob
}

# tylko gdy to sesja SSH i interaktywny shell
if [[ -n "${SSH_CONNECTION-}" && $- == *i* ]]; then
  trap cleanup_upg_xml_and_cache EXIT
fi
# <<< UPG XML cleanup (auto) <<<
EOF
)

touch "$BASHRC"
cp -a "$BASHRC" "${BASHRC}.bak.$(date +%Y%m%d_%H%M%S)"

# usuń stary blok jeśli istnieje
if grep -qF "$BLOCK_START" "$BASHRC"; then
  awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0==start {inside=1; next}
    $0==end   {inside=0; next}
    !inside   {print}
  ' "$BASHRC" > "${BASHRC}.tmp"
  mv "${BASHRC}.tmp" "$BASHRC"
fi

# dopisz świeży blok
printf "\n%s\n" "$SNIPPET" >> "$BASHRC"

echo "OK: blok wstawiony/odświeżony w $BASHRC (backup zrobiony)."
echo "INFO: Zaloguj się ponownie przez SSH i wyloguj, żeby trap zadziałał."
echo "DONE"