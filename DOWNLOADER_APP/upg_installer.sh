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
# - Pyta czy pobrać AMMS, PI, BK czy AMCS
# - Pokazuje listę dostępnych wersji
# - Pobiera wybrany plik lub pliki do ~/UPG
# - Przed pobraniem usuwa stare pliki zgodnie z wybranym typem:
#   * AMMS/PI: *.jar
#   * BK: *.war
#   * AMCS: tylko istniejący plik docelowy AMCS
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

VERSION="1.0.4"
MANIFEST_URL="https://helpdesk.itgo.com.pl/nextcloud/index.php/s/s2778Z6z4rEibLp/download"

TARGET_DIR="${HOME}/UPG"
AMCS_TARGET_DIR="${HOME}/UTILITY/AMCS"

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

cleanup_old_artifacts() {
  local app_type="$1"
  shift

  local target_file
  for target_file in "$@"; do
    [ -n "$target_file" ] && mkdir -p "$(dirname "$target_file")"
  done

  case "$app_type" in
    amms|pi)
      find "$TARGET_DIR" -maxdepth 1 -type f -name "*.jar" -print -delete 2>/dev/null || true
      ;;
    bk)
      find "$TARGET_DIR" -maxdepth 1 -type f -name "*.war" -print -delete 2>/dev/null || true
      ;;
    amcs)
      for target_file in "$@"; do
        if [ -f "$target_file" ]; then
          printf '%s\n' "$target_file"
          rm -f "$target_file"
        fi
      done
      ;;
  esac
}

fetch_manifest() {
  curl -fsSL "$MANIFEST_URL"
}

print_versions() {
  local manifest="$1"
  local channel="$2"
  printf '%s\n' "$manifest" | jq -r --arg channel "$channel" '.channels[$channel][].version' | nl -w1 -s') '
}

get_versions_count() {
  local manifest="$1"
  local channel="$2"
  printf '%s\n' "$manifest" | jq -r --arg channel "$channel" '.channels[$channel] | length'
}

resolve_download_urls() {
  local manifest="$1"
  local app_type="$2"
  local choice="$3"
  local channel key

  case "$app_type" in
    amms) channel="core"; key="amms" ;;
    pi) channel="core"; key="pi" ;;
    amcs) channel="amcs"; key="amcs_updater" ;;
    bk)
      printf '%s\n' "$manifest" | jq -r --argjson n "$choice" '
        .channels.bk[$n-1]
        | [.bk_raporty_war, .bk_infomedica_server_war]
        | .[]
        | select(. != null and . != "")
      '
      return
      ;;
    *)
      echo "ERROR: Nieznany typ aplikacji: ${app_type}" >&2
      exit 1
      ;;
  esac

  printf '%s\n' "$manifest" | jq -r --arg channel "$channel" --arg key "$key" --argjson n "$choice" '
    .channels[$channel][$n-1][$key] // empty
  '
}

resolve_channel() {
  local app_type="$1"
  case "$app_type" in
    amms|pi) printf '%s\n' "core" ;;
    bk) printf '%s\n' "bk" ;;
    amcs) printf '%s\n' "amcs" ;;
    *)
      echo "ERROR: Nieznany typ aplikacji: ${app_type}" >&2
      exit 1
      ;;
  esac
}

resolve_target_dir() {
  local app_type="$1"
  case "$app_type" in
    amcs) printf '%s\n' "$AMCS_TARGET_DIR" ;;
    *) printf '%s\n' "$TARGET_DIR" ;;
  esac
}

resolve_version() {
  local manifest="$1"
  local channel="$2"
  local choice="$3"
  printf '%s\n' "$manifest" | jq -r --arg channel "$channel" --argjson n "$choice" '.channels[$channel][$n-1].version'
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
  local app_choice app_type channel choice versions_count selected_version manifest
  local download_dir
  local start_ts end_ts elapsed_human url filename target_file size_human
  local urls=()
  local filenames=()
  local target_files=()
  local sizes_human=()

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
  echo "3) BK"
  echo "4) AMCS"
  read -r -p "Wybierz [1-4]: " app_choice

  case "$app_choice" in
    1) app_type="amms" ;;
    2) app_type="pi" ;;
    3) app_type="bk" ;;
    4) app_type="amcs" ;;
    *)
      echo "ERROR: Błędny wybór."
      exit 1
      ;;
  esac

  download_dir="$(resolve_target_dir "$app_type")"
  manifest="$(fetch_manifest)"
  channel="$(resolve_channel "$app_type")"

  echo
  echo "Dostępne wersje:"
  print_versions "$manifest" "$channel"

  versions_count="$(get_versions_count "$manifest" "$channel")"
  if [ "$versions_count" -lt 1 ]; then
    echo "ERROR: Brak wersji w kanale manifestu: ${channel}"
    exit 1
  fi

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

  while IFS= read -r url; do
    [ -n "$url" ] && urls+=("$url")
  done < <(resolve_download_urls "$manifest" "$app_type" "$choice")

  selected_version="$(resolve_version "$manifest" "$channel" "$choice")"

  if [ "${#urls[@]}" -lt 1 ]; then
    echo "ERROR: Nie udało się wyznaczyć URL dla wybranego wariantu."
    if [ "$app_type" = "bk" ]; then
      echo "ERROR: Wybrana wersja BK nie zawiera żadnego pliku do pobrania."
    fi
    exit 1
  fi

  for url in "${urls[@]}"; do
    filename="$(resolve_filename_from_header "$url")"
    target_file="${download_dir}/${filename}"
    filenames+=("$filename")
    target_files+=("$target_file")
  done

  echo
  echo "Przygotowanie katalogu docelowego: ${download_dir}"
  mkdir -p "$download_dir"
  echo "Usuwanie starych plików dla typu ${app_type^^} z ${download_dir}:"
  cleanup_old_artifacts "$app_type" "${target_files[@]}"

  echo
  echo "Pobieranie:"
  echo "  Typ     : ${app_type^^}"
  echo "  Wersja  : ${selected_version}"
  for i in "${!filenames[@]}"; do
    echo "  Plik    : ${filenames[$i]}"
    echo "  Cel     : ${target_files[$i]}"
  done
  echo

  start_ts="$(date +%s)"
  for i in "${!urls[@]}"; do
    wget -O "${target_files[$i]}" "${urls[$i]}"
  done
  end_ts="$(date +%s)"

  elapsed_human="$(format_duration "$(( end_ts - start_ts ))")"
  for target_file in "${target_files[@]}"; do
    if [ ! -f "$target_file" ]; then
      echo "ERROR: Plik nie został pobrany: ${target_file}"
      exit 1
    fi

    size_human="$(format_size_gb "$target_file")"
    sizes_human+=("$size_human")
  done

  echo
  echo "========================================"
  echo "PODSUMOWANIE"
  echo "========================================"
  echo "Pobrano:"
  for i in "${!filenames[@]}"; do
    echo "  - ${filenames[$i]}"
    echo "    Zapisano do : ${target_files[$i]}"
    echo "    Rozmiar     : ${sizes_human[$i]}"
  done
  echo "Typ         : ${app_type^^}"
  echo "Wersja      : ${selected_version}"
  echo "Czas        : ${elapsed_human}"
  echo "Installer   : ${VERSION}"
  echo "Ver file    : ${VERSION_FILE}"
  echo "Launcher    : ${LOCAL_LAUNCHER}"
  echo "========================================"
}

main "$@"
