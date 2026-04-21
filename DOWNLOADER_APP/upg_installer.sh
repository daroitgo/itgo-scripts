#!/usr/bin/env bash
# shellcheck shell=bash

# Re-exec in bash if started by sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

# ==========================================================
# ITGO UPG Installer Fetcher
# Version: 1.0.1
#
# Opis:
# - Pobiera manifest versions.json z Nextcloud
# - Pyta czy pobrać AMMS czy PI
# - Pokazuje listę dostępnych wersji
# - Pobiera wybrany plik do ~/UPG
# - Przed pobraniem usuwa wszystkie pliki *.jar z ~/UPG
# - Utrzymuje lokalny launcher:
#     ~/UTILITY/DOWNLOADER_APP/bin/dwupg
# - Zapisuje wersję instalera do:
#     ~/UTILITY/DOWNLOADER_APP/.downloader_version
# - Na końcu pokazuje podsumowanie:
#   * co pobrano
#   * czas pobierania (min, sek)
#   * rozmiar pliku (GB)
#
# Wymagania:
# - bash
# - curl
# - jq
# - wget
# ==========================================================

VERSION="1.0.2"
MANIFEST_URL="https://helpdesk.itgo.com.pl/nextcloud/index.php/s/s2778Z6z4rEibLp/download"

TARGET_DIR="${HOME}/UPG"

UTILITY_DIR="${HOME}/UTILITY"
DOWNLOADER_DIR="${UTILITY_DIR}/DOWNLOADER_APP"
BIN_DIR="${DOWNLOADER_DIR}/bin"
APP_SCRIPT="${DOWNLOADER_DIR}/upg_installer.sh"
LOCAL_LAUNCHER="${BIN_DIR}/dwupg"
VERSION_FILE="${DOWNLOADER_DIR}/.downloader_version"

LEGACY_DWUPG="/usr/local/bin/dwupg"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Brak wymaganego polecenia: $1"
    exit 1
  }
}

ensure_dirs() {
  mkdir -p "$TARGET_DIR"
  mkdir -p "$UTILITY_DIR"
  mkdir -p "$DOWNLOADER_DIR"
  mkdir -p "$BIN_DIR"
  chmod 0755 "$UTILITY_DIR" "$DOWNLOADER_DIR" 2>/dev/null || true
  chmod 0700 "$BIN_DIR" 2>/dev/null || true
}

write_version_file() {
  printf "%s\n" "$VERSION" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE" 2>/dev/null || true
}

script_source_path() {
  local src="${BASH_SOURCE[0]}"
  local dir base
  dir="$(cd "$(dirname "$src")" && pwd)"
  base="$(basename "$src")"
  printf "%s/%s\n" "$dir" "$base"
}

cleanup_legacy_dwupg() {
  rm -f "$LEGACY_DWUPG" \
        "${LEGACY_DWUPG}.bak" \
        "${LEGACY_DWUPG}.bak."* 2>/dev/null || true
}

write_local_launcher() {
  cat > "$LOCAL_LAUNCHER" <<EOF_DWUPG
#!/usr/bin/env bash
exec "$APP_SCRIPT" "\$@"
EOF_DWUPG
  chmod 0700 "$LOCAL_LAUNCHER" 2>/dev/null || true
}

install_local_artifacts() {
  local src
  src="$(script_source_path)"

  ensure_dirs

  if [ "$src" != "$APP_SCRIPT" ]; then
    cp -f "$src" "$APP_SCRIPT"
  fi

  chmod 0700 "$APP_SCRIPT" 2>/dev/null || true
  write_local_launcher
  write_version_file
  cleanup_legacy_dwupg
}

uninstall_downloader_app() {
  cleanup_legacy_dwupg
  rm -rf "$DOWNLOADER_DIR" 2>/dev/null || true
  echo "OK: usunięto DOWNLOADER_APP z ${DOWNLOADER_DIR}"
  echo "OK: usunięto legacy ${LEGACY_DWUPG} oraz backupy (jeśli istniały)"
}

cleanup_old_jars() {
  mkdir -p "$TARGET_DIR"
  find "$TARGET_DIR" -maxdepth 1 -type f -name "*.jar" -print -delete 2>/dev/null || true
}

fetch_manifest() {
  curl -fsSL "$MANIFEST_URL"
}

print_versions() {
  fetch_manifest | jq -r '.versions[].version' | nl -w1 -s') '
}

get_versions_count() {
  fetch_manifest | jq -r '.versions | length'
}

resolve_url() {
  local app_type="$1"
  local choice="$2"
  fetch_manifest | jq -r --arg app "$app_type" --argjson n "$choice" '.versions[$n-1][$app]'
}

resolve_version() {
  local choice="$1"
  fetch_manifest | jq -r --argjson n "$choice" '.versions[$n-1].version'
}

resolve_filename_from_header() {
  local url="$1"
  local filename

  filename="$(
    curl -fsSIL "$url" \
      | awk -F'filename=\"' '/^Content-Disposition:/ {print $2}' \
      | tr -d '"' \
      | tr -d '\r'
  )"

  if [ -z "$filename" ]; then
    echo "ERROR: Nie udało się ustalić nazwy pliku z nagłówka HTTP."
    exit 1
  fi

  printf '%s\n' "$filename"
}

format_duration() {
  local total_seconds="$1"
  local minutes=$(( total_seconds / 60 ))
  local seconds=$(( total_seconds % 60 ))
  printf '%d min %d sek' "$minutes" "$seconds"
}

format_size_gb() {
  local file_path="$1"
  local bytes
  bytes="$(stat -c '%s' "$file_path" 2>/dev/null || wc -c < "$file_path")"
  awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b/1024/1024/1024 }'
}

main() {
  local app_choice app_type choice versions_count url selected_version filename target_file
  local start_ts end_ts elapsed_human size_human

  if [ "${1:-}" = "--uninstall" ]; then
    uninstall_downloader_app
    exit 0
  fi

  if [ "${1:-}" = "--install" ]; then
    install_local_artifacts
    echo "OK: DOWNLOADER_APP installed locally"
    echo "Launcher: ${LOCAL_LAUNCHER}"
    exit 0
  fi

  require_cmd curl
  require_cmd jq
  require_cmd wget

  install_local_artifacts

  echo "ITGO UPG Installer Fetcher v${VERSION}"
  echo "Launcher lokalny: ${LOCAL_LAUNCHER}"
  echo

  echo "Co chcesz pobrać?"
  echo "1) AMMS"
  echo "2) PI"
  read -r -p "Wybierz [1-2]: " app_choice

  case "$app_choice" in
    1) app_type="amms" ;;
    2) app_type="pi" ;;
    *)
      echo "ERROR: Błędny wybór."
      exit 1
      ;;
  esac

  echo
  echo "Dostępne wersje:"
  print_versions

  versions_count="$(get_versions_count)"
  echo
  read -r -p "Wybierz numer wersji [1-${versions_count}]: " choice

  case "$choice" in
    ''|*[!0-9]*)
      echo "ERROR: Musisz podać numer."
      exit 1
      ;;
  esac

  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$versions_count" ]; then
    echo "ERROR: Numer poza zakresem."
    exit 1
  fi

  url="$(resolve_url "$app_type" "$choice")"
  selected_version="$(resolve_version "$choice")"

  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "ERROR: Nie udało się wyznaczyć URL dla wybranego wariantu."
    exit 1
  fi

  filename="$(resolve_filename_from_header "$url")"
  target_file="${TARGET_DIR}/${filename}"

  echo
  echo "Przygotowanie katalogu docelowego: ${TARGET_DIR}"
  echo "Usuwanie starych plików JAR z ${TARGET_DIR}:"
  cleanup_old_jars

  echo
  echo "Pobieranie:"
  echo "  Typ     : ${app_type^^}"
  echo "  Wersja  : ${selected_version}"
  echo "  Plik    : ${filename}"
  echo "  Cel     : ${target_file}"
  echo

  start_ts="$(date +%s)"
  wget -O "$target_file" "$url"
  end_ts="$(date +%s)"

  if [ ! -f "$target_file" ]; then
    echo "ERROR: Plik nie został pobrany."
    exit 1
  fi

  elapsed_human="$(format_duration "$(( end_ts - start_ts ))")"
  size_human="$(format_size_gb "$target_file")"

  echo
  echo "========================================"
  echo "PODSUMOWANIE"
  echo "========================================"
  echo "Pobrano     : ${filename}"
  echo "Typ         : ${app_type^^}"
  echo "Wersja      : ${selected_version}"
  echo "Zapisano do : ${target_file}"
  echo "Czas        : ${elapsed_human}"
  echo "Rozmiar     : ${size_human}"
  echo "Installer   : ${VERSION}"
  echo "Ver file    : ${VERSION_FILE}"
  echo "Launcher    : ${LOCAL_LAUNCHER}"
  echo "========================================"
}

main "$@"
