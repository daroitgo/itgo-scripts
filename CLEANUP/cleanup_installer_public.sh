#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# UPG XML + ~/.cache cleanup installer
# Version: 1.0.1
#
# Co robi:
# - wstawia/odświeża blok w ~/.bashrc
# - zapisuje wersję instalera do:
#   ~/UTILITY/UPG_CLEANUP/.upg_cleanup_version
# - przy wyjściu z interaktywnej sesji SSH usuwa:
#   1) /home/itgo/UPG/*.xml
#   2) zawartość ~/.cache (zostawia katalog)
#
# Uwaga:
# - dotyczy użytkownika, na którym uruchamiasz instalator (HOME)
# - ścieżka /home/itgo/UPG jest na stałe
# ==========================================================

VERSION="1.0.1"

UTILITY_DIR="${HOME}/UTILITY"
MODULE_DIR="${UTILITY_DIR}/UPG_CLEANUP"
VERSION_FILE="${MODULE_DIR}/.upg_cleanup_version"

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

ensure_dirs() {
  mkdir -p "$UTILITY_DIR"
  mkdir -p "$MODULE_DIR"
  chmod 0755 "$UTILITY_DIR" "$MODULE_DIR" 2>/dev/null || true
}

write_version_file() {
  printf "%s\n" "$VERSION" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE" 2>/dev/null || true
}

backup_bashrc() {
  touch "$BASHRC"
  cp -a "$BASHRC" "${BASHRC}.bak.$(date +%Y%m%d_%H%M%S)"
}

remove_old_block_if_exists() {
  if grep -qF "$BLOCK_START" "$BASHRC"; then
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$BASHRC" > "${BASHRC}.tmp"
    mv "${BASHRC}.tmp" "$BASHRC"
  fi
}

append_fresh_block() {
  printf "\n%s\n" "$SNIPPET" >> "$BASHRC"
}

main() {
  ensure_dirs
  write_version_file
  backup_bashrc
  remove_old_block_if_exists
  append_fresh_block

  echo "OK: blok wstawiony/odświeżony w $BASHRC (backup zrobiony)."
  echo "OK: wersja instalera zapisana do $VERSION_FILE"
  echo "INFO: Zaloguj się ponownie przez SSH i wyloguj, żeby trap zadziałał."
  echo "DONE"
}

main "$@"