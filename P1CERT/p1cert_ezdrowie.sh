#!/usr/bin/env bash
# shellcheck shell=bash
# P1CERT ezdrowie: controlled replacement of local ezdrowie.gov.pl certificates
# with the source certificate published in the ITGO Nextcloud.
#
# This namespace is a deliberate, separate exception to the read-only/CA-only
# rules of `p1cert audit|update`.  It only touches files that:
#   - live below /srv, /usr/local or /opt and are named like ezdrowie.gov.pl,
#   - contain one X.509 certificate or a valid PEM certificate chain (leaf ->
#     intermediate CA(s) -> root) whose leaf has an ezdrowie.gov.pl identity,
#   - were explicitly approved by an operator in `p1cert ezdrowie plan`.
#
# The script runs unprivileged.  Privileged steps go through a root-owned
# helper that re-validates every argument on its own: one "apply" operation
# per target replaces the certificate and, only when approved and only for a
# unit/service the helper itself proves to use that certificate, restarts it
# and rolls back on failure; "schedule" arms the one-shot timer.

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$SCRIPT_DIR/p1cert.version" ]; then
  MODULE_DIR="$SCRIPT_DIR"
else
  MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# shellcheck source=p1cert_ezdrowie_lib.sh
. "$SCRIPT_DIR/p1cert_ezdrowie_lib.sh"

# Nextcloud location is part of the application, not of the local config.
EZ_NEXTCLOUD_URL='https://helpdesk.itgo.com.pl/nextcloud'
EZ_NEXTCLOUD_USER='itgonc'
EZ_REMOTE_FOLDER='P1CERT_EZDROWIE'
EZ_CRED_NAME='p1cert-ezdrowie-nextcloud'
EZ_MAX_REMOTE_FILES=50

# All working data lives below the module directory
# (/home/itgo/UTILITY/P1CERT in production).
ez_set_module_dir() {
  MODULE_DIR="$1"
  CONFIG_DIR="$MODULE_DIR/config"
  STATE_DIR="$MODULE_DIR/state"
  LOG_DIR="$MODULE_DIR/logs"
  BACKUPS_DIR="$MODULE_DIR/backups"
  EZ_BACKUP_ROOT="$BACKUPS_DIR/ezdrowie"
  EZ_CRED_FILE="$CONFIG_DIR/ezdrowie-nextcloud.cred"
  EZ_CRED_MODE_FILE="$CONFIG_DIR/ezdrowie-credential-mode"
  EZ_PLAN_FILE="$STATE_DIR/ezdrowie-plan"
  EZ_SCHEDULE_FILE="$STATE_DIR/ezdrowie-schedule"
  EZ_LAST_RUN_FILE="$STATE_DIR/ezdrowie-last-run"
  EZ_LOCK_FILE="$STATE_DIR/ezdrowie.lock"
}
ez_set_module_dir "$MODULE_DIR"

EZ_HELPER='/usr/local/libexec/itgo-p1cert/p1cert-ezdrowie-helper'
# Exact caller <-> helper contract version required from "helper ping" (not
# the P1CERT release version).  2: PEM chains, apply with old/new file SHA-256.
# 3: root/operator owned, group-writable target directories (ez_target_dir_ok)
# with descriptor/inode bound replacement; an API 2 helper is refused.
EZ_HELPER_API=3
EZ_SERVICE_UNIT='itgo-p1cert-ezdrowie.service'
EZ_TIMER_UNIT='itgo-p1cert-ezdrowie.timer'
# Trusted owner/group of target directories besides the P1CERT user itself
# (see ez_target_dir_ok; the helper applies the same rule).  Tests may
# override them.
EZ_TRUSTED_UID=0
EZ_TRUSTED_GID=0
# A scheduled run acts only from the planned time up to this many seconds
# later; earlier (clock jump) or later (delayed start) it does nothing.
EZ_SCHEDULE_GRACE_SECONDS=900

EZ_LOG_FILE=""
EZ_TMP=""
EZ_PASSWORD=""
EZ_CRED_MODE=""
EZ_HELPER_STATE=unknown

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# Tests can mirror the filesystem below an isolated directory.
fs_path() {
  case "${P1CERT_FS_ROOT:-}" in
    '') printf '%s\n' "$1" ;;
    *) printf '%s%s\n' "${P1CERT_FS_ROOT%/}" "$1" ;;
  esac
}

ez_cleanup() {
  EZ_PASSWORD=""
  unset EZ_PASSWORD
  if [ -n "$EZ_TMP" ] && [ -d "$EZ_TMP" ]; then
    rm -rf -- "$EZ_TMP"
  fi
}

ez_tmpdir() {
  [ -n "$EZ_TMP" ] && [ -d "$EZ_TMP" ] && return 0
  EZ_TMP="$(mktemp -d "${TMPDIR:-/tmp}/p1cert-ezdrowie.XXXXXX")" || {
    printf '%s\n' 'BŁĄD: nie można utworzyć katalogu tymczasowego.' >&2
    return 1
  }
  chmod 0700 "$EZ_TMP"
}

# Neutralizes control bytes (newlines, ESC sequences) in untrusted text before
# it reaches the terminal or a log; UTF-8 text is kept.
ez_printable() {
  printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'
}

ez_log_open() {
  local command_name="$1"

  if [ -L "$LOG_DIR" ]; then
    printf 'BŁĄD: katalog logów jest symlinkiem: %s\n' "$LOG_DIR" >&2
    return 1
  fi
  mkdir -p "$LOG_DIR" || return 1
  EZ_LOG_FILE="$LOG_DIR/p1cert-ezdrowie-${command_name}-$(date '+%Y%m%d_%H%M%S')-$$.log"
  : >> "$EZ_LOG_FILE" || return 1
  chmod 0600 "$EZ_LOG_FILE" 2>/dev/null || true
  ez_log "ezdrowie $command_name started user=$(id -un 2>/dev/null || printf unknown)"
}

ez_log() {
  [ -n "$EZ_LOG_FILE" ] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$(ez_printable "$*")" >> "$EZ_LOG_FILE"
}

ez_say() {
  printf '%s\n' "$*"
  ez_log "$*"
}

ez_warn() {
  printf 'UWAGA: %s\n' "$*" >&2
  ez_log "WARNING: $*"
}

ez_err() {
  printf 'BŁĄD: %s\n' "$*" >&2
  ez_log "ERROR: $*"
}

ez_has_crlf() {
  case "$1" in
    *$'\r'*|*$'\n'*) return 0 ;;
  esac
  return 1
}

ez_is_tty() {
  [ -t 0 ]
}

ez_ask_yes() {
  local answer=""

  read -r -p "$1 [t/N]: " answer || return 1
  case "$answer" in
    t|T|tak|TAK|Tak|y|Y|yes|YES) return 0 ;;
  esac
  return 1
}

ez_fmt_epoch() {
  date -d "@$1" '+%F %T %Z' 2>/dev/null || printf '%s' "$1"
}

ez_status_label() {
  case "$1" in
    VALID) printf 'WAŻNY' ;;
    EXPIRES_SOON) printf 'WAŻNY (wygasa w ciągu 30 dni)' ;;
    EXPIRED) printf 'WYGASŁY' ;;
    NOT_YET_VALID) printf 'JESZCZE NIEWAŻNY' ;;
    *) printf '%s' "$1" ;;
  esac
}

ez_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 < "$1" | awk '{print $NF}'
  fi
}

ez_file_owner_ok() {
  local owner

  owner="$(stat -c '%u' -- "$1" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -u)" ]
}

# Writes stdin to $1 atomically (temporary file in the same directory).
ez_write_atomic() {
  local destination="$1" tmp

  [ ! -L "$destination" ] || return 1
  tmp="$(mktemp "${destination%/*}/.${destination##*/}.XXXXXX")" || return 1
  if ! cat > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
}

ez_prepare_dir() {
  local dir="$1" mode="$2"

  if [ -L "$dir" ]; then
    ez_err "katalog jest symlinkiem: $dir"
    return 1
  fi
  mkdir -p "$dir" && chmod "$mode" "$dir"
}

ez_have_flock() {
  command -v flock >/dev/null 2>&1
}

# Runs a function under an exclusive lock shared by plan/run/schedule/
# schedule-cancel.  Without flock nothing is executed (fail closed).
ez_with_lock() {
  local lock_status

  if ! ez_have_flock; then
    ez_err 'polecenie flock (util-linux) jest niedostępne; operacja nie zostanie wykonana bez blokady.'
    return 1
  fi
  ez_prepare_dir "$STATE_DIR" 0755 || return 1
  if [ -L "$EZ_LOCK_FILE" ]; then
    ez_err "lock jest symlinkiem: $EZ_LOCK_FILE"
    return 1
  fi
  [ -e "$EZ_LOCK_FILE" ] || : >> "$EZ_LOCK_FILE" || return 1
  {
    flock -n 9
    lock_status=$?
    if [ "$lock_status" -ne 0 ]; then
      ez_err 'inna operacja p1cert ezdrowie jest w toku.'
      return 1
    fi
    "$@"
  } 9<"$EZ_LOCK_FILE"
}

# ---------------------------------------------------------------------------
# Root helper
# ---------------------------------------------------------------------------

ez_helper_installed() {
  local owner mode

  [ -f "$EZ_HELPER" ] && [ ! -L "$EZ_HELPER" ] && [ -x "$EZ_HELPER" ] || return 1
  owner="$(stat -c '%u' -- "$EZ_HELPER" 2>/dev/null)" || return 1
  mode="$(stat -c '%a' -- "$EZ_HELPER" 2>/dev/null)" || return 1
  [ "$owner" = 0 ] || return 1
  case "$mode" in
    *[2367][0-7]|*[2367]) return 1 ;;
  esac
  return 0
}

ez_helper() {
  sudo -n -- "$EZ_HELPER" "$@"
}

# Runs a helper operation; helper diagnostics go to stderr and the log.
ez_helper_run() {
  local rc line

  ez_tmpdir || return 1
  ez_helper "$@" 2>"$EZ_TMP/helper.err"
  rc=$?
  if [ -s "$EZ_TMP/helper.err" ]; then
    sed 's/^/helper: /' "$EZ_TMP/helper.err" >&2
    while IFS= read -r line; do
      ez_log "helper: $line"
    done < "$EZ_TMP/helper.err"
  fi
  : > "$EZ_TMP/helper.err"
  return "$rc"
}

# True when "ping" output reports a working helper with exactly the expected
# API version (no missing, older or newer version is accepted).
ez_helper_ping_ok() {
  local out="$1" ok="" api="" line

  while IFS= read -r line; do
    case "$line" in
      HELPER=OK) ok=yes ;;
      API_VERSION=*) [ -z "$api" ] || return 1; api="${line#API_VERSION=}" ;;
    esac
  done <<EOF
$out
EOF
  [ "$ok" = yes ] && [ -n "$api" ] && [ "$api" = "$EZ_HELPER_API" ]
}

# EZ_HELPER_STATE: unknown | yes | no (missing/sudo) | api (incompatible).
ez_helper_usable() {
  local out

  case "$EZ_HELPER_STATE" in
    yes) return 0 ;;
    no|api) return 1 ;;
  esac
  EZ_HELPER_STATE=no
  ez_helper_installed && command -v sudo >/dev/null 2>&1 || return 1
  out="$(ez_helper ping 2>/dev/null)" || return 1
  if ! ez_helper_ping_ok "$out"; then
    EZ_HELPER_STATE=api
    return 1
  fi
  EZ_HELPER_STATE=yes
}

ez_require_helper() {
  ez_helper_usable && return 0
  if [ "$EZ_HELPER_STATE" = api ]; then
    ez_err "uprzywilejowany helper ma niezgodną wersję API (wymagana $EZ_HELPER_API); uruchom ponownie instalator P1CERT."
  else
    ez_err "uprzywilejowany helper P1CERT jest niedostępny ($EZ_HELPER lub wpis sudoers). Uruchom ponownie instalator P1CERT."
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Credentials and Nextcloud WebDAV
# ---------------------------------------------------------------------------

ez_credentials() {
  local password="" encrypted="" recovered="" mode="plain-0600" cred_tmp="" mode_tmp=""

  ez_log_open credentials || return 1
  if ! ez_is_tty; then
    ez_err 'p1cert ezdrowie credentials wymaga interaktywnego terminala.'
    return 1
  fi
  printf 'Nextcloud: %s\nUżytkownik: %s\nKatalog: %s\n' "$EZ_NEXTCLOUD_URL" "$EZ_NEXTCLOUD_USER" "$EZ_REMOTE_FOLDER"
  read -r -s -p 'Nextcloud App Password: ' password || true
  printf '\n'
  if [ -z "$password" ] || ez_has_crlf "$password"; then
    password=""
    ez_err 'App Password nie może być pusty ani zawierać CR/LF.'
    return 1
  fi

  ez_prepare_dir "$CONFIG_DIR" 0700 || { password=""; return 1; }
  if [ -L "$EZ_CRED_FILE" ] || [ -L "$EZ_CRED_MODE_FILE" ]; then
    password=""
    ez_err 'plik credentials jest symlinkiem; odmowa zapisu.'
    return 1
  fi

  if command -v systemd-creds >/dev/null 2>&1; then
    encrypted="$(printf '%s' "$password" | systemd-creds encrypt --user --name="$EZ_CRED_NAME" - - 2>/dev/null)" || encrypted=""
    if [ -n "$encrypted" ]; then
      recovered="$(printf '%s' "$encrypted" | systemd-creds decrypt --user --name="$EZ_CRED_NAME" - - 2>/dev/null)" || recovered=""
      if [ "$recovered" = "$password" ]; then
        mode=systemd-creds
      else
        encrypted=""
      fi
      recovered=""
    fi
  fi

  cred_tmp="$(mktemp "$CONFIG_DIR/.ezdrowie-nextcloud.cred.XXXXXX")" || { password=""; encrypted=""; return 1; }
  mode_tmp="$(mktemp "$CONFIG_DIR/.ezdrowie-credential-mode.XXXXXX")" || { rm -f -- "$cred_tmp"; password=""; encrypted=""; return 1; }
  if [ "$mode" = systemd-creds ]; then
    printf '%s\n' "$encrypted" > "$cred_tmp"
  else
    printf '%s' "$password" > "$cred_tmp"
  fi
  if [ $? -ne 0 ] || ! printf '%s\n' "$mode" > "$mode_tmp" ||
     ! chmod 0600 "$cred_tmp" "$mode_tmp" ||
     ! mv -f -- "$cred_tmp" "$EZ_CRED_FILE" || ! mv -f -- "$mode_tmp" "$EZ_CRED_MODE_FILE"; then
    rm -f -- "$cred_tmp" "$mode_tmp"
    password=""; encrypted=""
    ez_err 'nie można zapisać credentials.'
    return 1
  fi
  password=""; encrypted=""
  if [ "$mode" = plain-0600 ]; then
    ez_warn 'systemd-creds --user jest niedostępny; App Password chroniony wyłącznie uprawnieniami pliku 0600.'
  fi
  ez_say "Zapisano Nextcloud App Password. Tryb: $mode"
  ez_say "Plik: $EZ_CRED_FILE"
}

ez_load_credential() {
  local mode="" mode_perm file

  EZ_PASSWORD=""
  EZ_CRED_MODE=""
  if ! ez_dir_safe "$CONFIG_DIR" "$(id -u)"; then
    ez_err "katalog $CONFIG_DIR musi być katalogiem (nie symlinkiem) bieżącego użytkownika bez zapisu dla grupy/innych (zalecane 0700)."
    return 1
  fi
  if [ ! -f "$EZ_CRED_FILE" ] || [ ! -f "$EZ_CRED_MODE_FILE" ] || [ -L "$EZ_CRED_FILE" ] || [ -L "$EZ_CRED_MODE_FILE" ]; then
    ez_err 'brak Nextcloud App Password. Uruchom: p1cert ezdrowie credentials'
    return 1
  fi
  for file in "$EZ_CRED_FILE" "$EZ_CRED_MODE_FILE"; do
    if ! ez_file_owner_ok "$file"; then
      ez_err "plik credentials nie należy do bieżącego użytkownika: $file"
      return 1
    fi
    mode_perm="$(stat -c '%a' -- "$file" 2>/dev/null)"
    [ "$mode_perm" = 600 ] || {
      ez_err "plik credentials musi mieć uprawnienia 0600 (jest: ${mode_perm:-?}): $file"
      return 1
    }
  done
  IFS= read -r mode < "$EZ_CRED_MODE_FILE" || [ -n "$mode" ] || true
  case "$mode" in
    systemd-creds)
      EZ_PASSWORD="$(systemd-creds decrypt --user --name="$EZ_CRED_NAME" "$EZ_CRED_FILE" - 2>/dev/null)" || {
        EZ_PASSWORD=""
        ez_err 'nie można odszyfrować Nextcloud App Password (systemd-creds).'
        return 1
      }
      ;;
    plain-0600)
      EZ_PASSWORD="$(cat -- "$EZ_CRED_FILE")" || {
        EZ_PASSWORD=""
        ez_err 'nie można odczytać Nextcloud App Password.'
        return 1
      }
      ;;
    *)
      ez_err 'nieobsługiwany tryb credentials.'
      return 1
      ;;
  esac
  if [ -z "$EZ_PASSWORD" ] || ez_has_crlf "$EZ_PASSWORD"; then
    EZ_PASSWORD=""
    ez_err 'nieprawidłowy Nextcloud App Password.'
    return 1
  fi
  EZ_CRED_MODE="$mode"
}

ez_curl_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

ez_origin() {
  printf '%s' "$EZ_NEXTCLOUD_URL" | sed -n 's#^\(https://[^/]*\).*#\1#p'
}

ez_dav_folder_path() {
  local origin

  origin="$(ez_origin)"
  printf '%s/remote.php/dav/files/%s/%s/' "${EZ_NEXTCLOUD_URL#"$origin"}" "$EZ_NEXTCLOUD_USER" "$EZ_REMOTE_FOLDER"
}

# Credentials are passed to curl through a config on stdin, never in argv.
# -q (first argument) ignores any ~/.curlrc, so nothing depends on HOME.
ez_curl() {
  local method="$1" url="$2" output="$3" depth="${4:-}" http=""

  [ -n "$EZ_PASSWORD" ] || return 1
  http="$({
    printf 'user = "%s"\n' "$(ez_curl_escape "${EZ_NEXTCLOUD_USER}:${EZ_PASSWORD}")"
    printf 'request = "%s"\n' "$method"
    if [ -n "$depth" ]; then
      printf 'header = "Depth: %s"\n' "$depth"
    fi
    printf 'proto = "=https"\nproto-redir = "=https"\n'
    printf 'connect-timeout = 20\nmax-time = 120\n'
    if [ "$method" = GET ]; then
      printf 'max-filesize = %s\n' "$EZ_MAX_CERT_BYTES"
    else
      printf 'max-filesize = 1048576\n'
    fi
    printf 'fail\nsilent\nshow-error\n'
    printf 'output = "%s"\n' "$(ez_curl_escape "$output")"
    printf 'url = "%s"\n' "$(ez_curl_escape "$url")"
    printf 'write-out = "%%{http_code}"\n'
  } | curl -q --config - 2>>"${EZ_LOG_FILE:-/dev/null}")" || {
    ez_log "WebDAV $method failed http=${http:-none}"
    return 1
  }
  case "$method:$http" in
    PROPFIND:207|GET:200) return 0 ;;
  esac
  ez_log "WebDAV $method unexpected http=${http:-none}"
  return 1
}

ez_test() {
  local rc=0

  ez_log_open test || return 1
  ez_tmpdir || return 1
  command -v curl >/dev/null 2>&1 || { ez_err 'curl jest wymagany.'; return 1; }
  printf 'URL: %s\nUżytkownik: %s\nKatalog zdalny: %s\n' "$EZ_NEXTCLOUD_URL" "$EZ_NEXTCLOUD_USER" "$EZ_REMOTE_FOLDER"
  if ! ez_load_credential; then
    printf 'Tryb credentials: BRAK\nERROR: brak poprawnych credentials.\n'
    return 1
  fi
  printf 'Tryb credentials: %s\n' "$EZ_CRED_MODE"
  if ez_curl PROPFIND "$(ez_origin)$(ez_dav_folder_path)" "$EZ_TMP/propfind.xml" 0; then
    ez_say 'SUCCESS: uwierzytelniony WebDAV PROPFIND do katalogu P1CERT_EZDROWIE powiódł się.'
  else
    ez_say 'ERROR: WebDAV PROPFIND do katalogu P1CERT_EZDROWIE nie powiódł się.'
    rc=1
  fi
  EZ_PASSWORD=""
  return "$rc"
}

# Decodes %HH sequences.  Every "%" must start exactly "%HH" (two hex
# digits, not %00); anything else is malformed and returns 1.  The input
# contains no backslash (checked by the caller), so printf %b only ever sees
# the \xHH escapes produced here.
ez_url_decode() {
  local rest="$1"

  case "$1" in
    *\\*) return 1 ;;
  esac
  while :; do
    case "$rest" in
      *%*) rest="${rest#*%}" ;;
      *) break ;;
    esac
    case "$rest" in
      00*) return 1 ;;
      [0-9A-Fa-f][0-9A-Fa-f]*) ;;
      *) return 1 ;;
    esac
  done
  printf '%b' "${1//%/\\x}"
}

# Lists and validates every remote certificate candidate.  Fills R_* arrays.
# Returns 1 when the remote folder cannot be read (nothing may change then).
ez_fetch_remote() {
  local origin prefix href name display file rc now reason i

  R_COUNT=0
  R_NAME=(); R_FILE=(); R_STATE=(); R_REASON=(); R_FP=(); R_NA=(); R_NB=()
  R_NOT_AFTER=(); R_NOT_BEFORE=(); R_SUBJECT=(); R_ISSUER=(); R_CN=(); R_NAMES=(); R_IS_CA=(); R_SELF=()
  R_FMT=(); R_NCERT=()

  ez_tmpdir || return 1
  command -v curl >/dev/null 2>&1 || { ez_err 'curl jest wymagany.'; return 1; }
  ez_load_credential || return 1
  origin="$(ez_origin)"
  prefix="$(ez_dav_folder_path)"
  if ! ez_curl PROPFIND "$origin$prefix" "$EZ_TMP/propfind.xml" 1; then
    EZ_PASSWORD=""
    ez_err 'nie można odczytać katalogu P1CERT_EZDROWIE w Nextcloud.'
    return 1
  fi
  now="$(date -u '+%s')"

  while IFS= read -r href; do
    case "$href" in
      "$origin"/*) href="${href#"$origin"}" ;;
    esac
    case "$href" in
      "$prefix"*) name="${href#"$prefix"}" ;;
      *) continue ;;
    esac
    [ -n "$name" ] || continue
    case "$name" in
      */*|*[!A-Za-z0-9._%+-]*)
        ez_warn "pominięto zdalny wpis o nieobsługiwanej nazwie: $(ez_printable "$name")"
        continue
        ;;
    esac
    if ! display="$(ez_url_decode "$name")"; then
      ez_warn "pominięto zdalny wpis o niepoprawnym kodowaniu nazwy: $(ez_printable "$name")"
      continue
    fi
    case "$display" in
      *[!A-Za-z0-9._+\ -]*|.*)
        ez_warn "pominięto zdalny wpis o nieobsługiwanej nazwie: $(ez_printable "$name")"
        continue
        ;;
    esac
    ez_ext_supported "$display" || continue
    if [ "$R_COUNT" -ge "$EZ_MAX_REMOTE_FILES" ]; then
      ez_warn "katalog zdalny zawiera więcej niż $EZ_MAX_REMOTE_FILES certyfikatów; pozostałe pominięto."
      break
    fi

    i="$R_COUNT"
    file="$EZ_TMP/remote-$i.cert"
    R_NAME[$i]="$display"; R_FILE[$i]="$file"; R_STATE[$i]=INVALID; R_REASON[$i]=''
    R_FP[$i]=''; R_NA[$i]=0; R_NB[$i]=0; R_NOT_AFTER[$i]=''; R_NOT_BEFORE[$i]=''
    R_SUBJECT[$i]=''; R_ISSUER[$i]=''; R_CN[$i]=''; R_NAMES[$i]=''; R_IS_CA[$i]=no; R_SELF[$i]=no
    R_FMT[$i]=''; R_NCERT[$i]=0
    R_COUNT=$((R_COUNT + 1))

    if ! ez_curl GET "$origin$href" "$file"; then
      R_REASON[$i]='nie można pobrać pliku'
      continue
    fi
    ez_cert_inspect "$file"
    rc=$?
    case "$rc" in
      0) ;;
      2) R_REASON[$i]="plik zawiera dane inne niż certyfikaty (${EZC_REASON:-dodatkowy blok PEM lub dane po certyfikacie DER})"; continue ;;
      3) R_REASON[$i]='plik zawiera klucz prywatny'; continue ;;
      4) R_REASON[$i]='plik jest zbyt duży'; continue ;;
      5) R_REASON[$i]="plik zawiera kilka certyfikatów, które nie tworzą prawidłowego łańcucha PEM (${EZC_REASON:-brak szczegółów})"; continue ;;
      *) R_REASON[$i]='plik nie jest poprawnym certyfikatem X.509'; continue ;;
    esac
    R_FMT[$i]="$EZC_FORMAT"; R_NCERT[$i]="$EZC_COUNT"
    R_FP[$i]="$EZC_FP"; R_NA[$i]="$EZC_NA_EPOCH"; R_NB[$i]="$EZC_NB_EPOCH"
    R_NOT_AFTER[$i]="$EZC_NOT_AFTER"; R_NOT_BEFORE[$i]="$EZC_NOT_BEFORE"
    R_SUBJECT[$i]="$EZC_SUBJECT"; R_ISSUER[$i]="$EZC_ISSUER"; R_CN[$i]="$EZC_CN"; R_NAMES[$i]="$EZC_NAMES"
    R_IS_CA[$i]="$EZC_IS_CA"; R_SELF[$i]="$EZC_SELF_SIGNED"

    if [ "$EZC_NB_EPOCH" -gt "$now" ]; then
      R_REASON[$i]='certyfikat jeszcze nie jest ważny'
    elif [ "$EZC_NA_EPOCH" -le "$now" ]; then
      R_REASON[$i]='certyfikat wygasł'
    elif ! reason="$(ez_primary_identity "$EZC_CN" "$EZC_NAMES")"; then
      R_REASON[$i]='certyfikat nie ma tożsamości ezdrowie.gov.pl'
    elif ez_is_nonprod_name "$reason"; then
      R_REASON[$i]="certyfikat nieprodukcyjny ($reason)"
    elif [ "$EZC_IS_CA" = yes ]; then
      R_REASON[$i]='certyfikat CA'
    elif [ "$EZC_SELF_SIGNED" = yes ]; then
      R_REASON[$i]='certyfikat samopodpisany'
    else
      R_STATE[$i]=VALID
    fi
  done <<EOF
$(grep -o '<[A-Za-z0-9]*:\{0,1\}href>[^<]*</[A-Za-z0-9]*:\{0,1\}href>' "$EZ_TMP/propfind.xml" 2>/dev/null | sed 's/<[^>]*>//g')
EOF
  EZ_PASSWORD=""

  i=0
  while [ "$i" -lt "$R_COUNT" ]; do
    if [ "${R_STATE[$i]}" = VALID ]; then
      ez_log "remote ${R_NAME[$i]} VALID fp=${R_FP[$i]} notAfter=${R_NOT_AFTER[$i]} certificates=${R_NCERT[$i]}"
    else
      ez_log "remote ${R_NAME[$i]} INVALID: ${R_REASON[$i]}"
    fi
    i=$((i + 1))
  done
  return 0
}

ez_print_remote() {
  local i=0

  printf '\nCertyfikaty źródłowe (Nextcloud %s):\n' "$EZ_REMOTE_FOLDER"
  if [ "$R_COUNT" -eq 0 ]; then
    printf '  brak\n'
    return 0
  fi
  while [ "$i" -lt "$R_COUNT" ]; do
    printf '  - %s: ' "${R_NAME[$i]}"
    if [ "${R_STATE[$i]}" = VALID ]; then
      printf 'POPRAWNY, NotAfter %s, SHA-256 %s' "${R_NOT_AFTER[$i]}" "${R_FP[$i]}"
      if [ "${R_NCERT[$i]}" -gt 1 ]; then
        printf ' (łańcuch PEM: %s certyfikaty; dane certyfikatu końcowego)' "${R_NCERT[$i]}"
      fi
      printf '\n'
    else
      printf 'ODRZUCONY (%s)\n' "${R_REASON[$i]}"
    fi
    i=$((i + 1))
  done
}

# Selects the best source certificate for one local certificate: valid,
# production, identity-compatible, with the latest NotAfter.
# Sets SEL_STATE (ABSENT|INVALID|VALID), SEL_INDEX and SEL_REASON.
ez_select_remote() {
  local local_cn="$1" local_names="$2" i=0 best=-1 tie=no reason last_reason=""

  SEL_STATE=ABSENT; SEL_INDEX=-1; SEL_REASON='brak certyfikatu źródłowego'
  [ "$R_COUNT" -gt 0 ] || return 0
  while [ "$i" -lt "$R_COUNT" ]; do
    if [ "${R_STATE[$i]}" != VALID ]; then
      last_reason="${R_NAME[$i]}: ${R_REASON[$i]}"
      i=$((i + 1))
      continue
    fi
    if ! reason="$(ez_identity_compatible "$local_cn" "$local_names" "${R_NAMES[$i]}" "${R_IS_CA[$i]}" "${R_SELF[$i]}")"; then
      last_reason="${R_NAME[$i]}: $reason"
      i=$((i + 1))
      continue
    fi
    if [ "$best" -lt 0 ] || [ "${R_NA[$i]}" -gt "${R_NA[$best]}" ]; then
      best="$i"
      tie=no
    elif [ "${R_NA[$i]}" -eq "${R_NA[$best]}" ] && [ "${R_FP[$i]}" != "${R_FP[$best]}" ]; then
      tie=yes
    fi
    i=$((i + 1))
  done
  if [ "$best" -lt 0 ]; then
    SEL_STATE=INVALID
    SEL_REASON="brak poprawnego, zgodnego certyfikatu źródłowego (${last_reason:-brak szczegółów})"
  elif [ "$tie" = yes ]; then
    SEL_STATE=INVALID
    SEL_REASON='kilka różnych certyfikatów źródłowych z tym samym NotAfter; wybór niejednoznaczny'
  else
    SEL_STATE=VALID
    SEL_INDEX="$best"
    SEL_REASON=''
  fi
}

# ---------------------------------------------------------------------------
# Local scan (read-only)
# ---------------------------------------------------------------------------

ez_local_find() {
  local root fsroot path logical prefix

  prefix="${P1CERT_FS_ROOT:-}"
  prefix="${prefix%/}"
  for root in $EZ_ALLOWED_ROOTS; do
    fsroot="$(fs_path "$root")"
    [ -d "$fsroot" ] && [ ! -L "$fsroot" ] || continue
    while IFS= read -r -d '' path; do
      logical="${path#"$prefix"}"
      ez_name_matches "${logical##*/}" || continue
      printf '%s\n' "$(ez_printable "$logical")"
    # OLD directories (any case) are certificate archives: not descended.
    done < <(find -P "$fsroot" \( -name node_modules -o -name .git -o \( -type d -iname old \) \) -prune -o \
      -type f \( -iname '*.pem' -o -iname '*.crt' -o -iname '*.cer' \) -size -1024k -print0 2>/dev/null)
  done
}

ez_candidate_paths() {
  {
    ez_local_find
    if ez_helper_usable; then
      ez_helper_run find-candidates < /dev/null 2>/dev/null || true
    fi
  } | LC_ALL=C sort -u
}

# Copies a local certificate (directly or through the helper) to $2.
ez_fetch_local() {
  local logical="$1" destination="$2" fs

  fs="$(fs_path "$logical")"
  ez_path_no_symlinks "${P1CERT_FS_ROOT:-}" "$logical" || return 2
  [ -f "$fs" ] && [ ! -L "$fs" ] || return 1
  if [ -r "$fs" ]; then
    cat -- "$fs" > "$destination" 2>/dev/null
    return
  fi
  if ez_helper_usable; then
    ez_helper_run read "$logical" > "$destination" < /dev/null
    return
  fi
  return 1
}

# Fills L_* arrays with every candidate and its inspection result.
ez_collect_local() {
  local path i rc now file

  L_COUNT=0
  L_PATH=(); L_STATE=(); L_REASON=(); L_FILE=(); L_FP=(); L_NA=(); L_NB=()
  L_NOT_AFTER=(); L_NOT_BEFORE=(); L_SUBJECT=(); L_ISSUER=(); L_CN=(); L_NAMES=(); L_VALIDITY=()
  L_FMT=(); L_NCERT=()
  ez_tmpdir || return 1
  now="$(date -u '+%s')"
  # Resolve helper availability once in this shell (the candidate list is
  # produced in a subshell).
  ez_helper_usable || true

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    i="$L_COUNT"
    L_COUNT=$((L_COUNT + 1))
    file="$EZ_TMP/local-$i.cert"
    L_PATH[$i]="$path"; L_STATE[$i]=INVALID; L_REASON[$i]=''; L_FILE[$i]="$file"
    L_FP[$i]=''; L_NA[$i]=0; L_NB[$i]=0; L_NOT_AFTER[$i]=''; L_NOT_BEFORE[$i]=''
    L_SUBJECT[$i]=''; L_ISSUER[$i]=''; L_CN[$i]=''; L_NAMES[$i]=''; L_VALIDITY[$i]=''
    L_FMT[$i]=''; L_NCERT[$i]=0

    if ! ez_target_path_ok "$path"; then
      if ez_path_in_old_dir "$path"; then
        L_REASON[$i]='katalog archiwum OLD - wyłączony z obsługi ezdrowie'
      else
        L_REASON[$i]='ścieżka zawiera nieobsługiwane znaki'
      fi
      continue
    fi
    ez_fetch_local "$path" "$file"
    rc=$?
    case "$rc" in
      0) ;;
      2) L_REASON[$i]='ścieżka zawiera symlink'; continue ;;
      *) L_REASON[$i]='nie można odczytać pliku'; continue ;;
    esac
    ez_cert_inspect "$file"
    rc=$?
    case "$rc" in
      0) ;;
      2) L_REASON[$i]="plik zawiera dane inne niż certyfikaty (${EZC_REASON:-dodatkowy blok PEM lub dane po certyfikacie DER}) - obsługa ręczna"; rm -f -- "$file"; continue ;;
      3) L_REASON[$i]='plik zawiera klucz prywatny - pominięto'; rm -f -- "$file"; continue ;;
      4) L_REASON[$i]='plik jest zbyt duży'; rm -f -- "$file"; continue ;;
      5) L_REASON[$i]="plik zawiera kilka certyfikatów, które nie tworzą prawidłowego łańcucha PEM (${EZC_REASON:-brak szczegółów}) - obsługa ręczna"; rm -f -- "$file"; continue ;;
      *) L_REASON[$i]='plik nie jest poprawnym certyfikatem X.509'; rm -f -- "$file"; continue ;;
    esac
    L_STATE[$i]=OK
    L_FP[$i]="$EZC_FP"; L_NA[$i]="$EZC_NA_EPOCH"; L_NB[$i]="$EZC_NB_EPOCH"
    L_NOT_AFTER[$i]="$EZC_NOT_AFTER"; L_NOT_BEFORE[$i]="$EZC_NOT_BEFORE"
    L_SUBJECT[$i]="$EZC_SUBJECT"; L_ISSUER[$i]="$EZC_ISSUER"; L_CN[$i]="$EZC_CN"; L_NAMES[$i]="$EZC_NAMES"
    L_VALIDITY[$i]="$(ez_validity_status "$EZC_NB_EPOCH" "$EZC_NA_EPOCH" "$now")"
    L_FMT[$i]="$EZC_FORMAT"; L_NCERT[$i]="$EZC_COUNT"
  done <<EOF
$(ez_candidate_paths)
EOF

  i=0
  while [ "$i" -lt "$L_COUNT" ]; do
    if [ "${L_STATE[$i]}" = OK ]; then
      ez_log "local ${L_PATH[$i]} fp=${L_FP[$i]} notAfter=${L_NOT_AFTER[$i]} status=${L_VALIDITY[$i]} certificates=${L_NCERT[$i]}"
    else
      ez_log "local ${L_PATH[$i]} skipped: ${L_REASON[$i]}"
    fi
    i=$((i + 1))
  done
}

ez_print_local() {
  local i=0

  printf 'Lokalne certyfikaty ezdrowie.gov.pl (/srv, /usr/local, /opt):\n'
  if [ "$L_COUNT" -eq 0 ]; then
    printf '  nie znaleziono\n'
    return 0
  fi
  while [ "$i" -lt "$L_COUNT" ]; do
    printf '\n[%s] %s\n' "$((i + 1))" "${L_PATH[$i]}"
    printf '    Plik:        %s\n' "${L_PATH[$i]##*/}"
    if [ "${L_STATE[$i]}" = OK ]; then
      printf '    SHA-256:     %s\n' "${L_FP[$i]}"
      printf '    Subject:     %s\n' "$(ez_printable "${L_SUBJECT[$i]}")"
      printf '    Issuer:      %s\n' "$(ez_printable "${L_ISSUER[$i]}")"
      printf '    Not Before:  %s\n' "${L_NOT_BEFORE[$i]}"
      printf '    Not After:   %s\n' "${L_NOT_AFTER[$i]}"
      printf '    Status:      %s\n' "$(ez_status_label "${L_VALIDITY[$i]}")"
      if [ "${L_NCERT[$i]}" -gt 1 ]; then
        printf '    Łańcuch:     PEM, %s certyfikaty (powyższe dane dotyczą certyfikatu końcowego)\n' "${L_NCERT[$i]}"
      fi
    else
      printf '    Status:      POMINIĘTO (%s)\n' "${L_REASON[$i]}"
    fi
    i=$((i + 1))
  done
}

ez_scan() {
  ez_log_open scan || return 1
  ez_collect_local || return 1
  ez_print_local
  ez_log "scan finished candidates=$L_COUNT"
}

# ---------------------------------------------------------------------------
# Application / service detection
# ---------------------------------------------------------------------------

# Prints "systemd|<unit>|<reason>" for units that satisfy the same binding
# rule the root helper enforces before a restart (ez_systemd_bound): the unit
# configuration names the exact certificate path, or the unit runs from the
# same IntegrationPlatform installation directory that contains the file.
# Denied system units are never offered.
ez_detect_systemd() {
  local cert="$1" dir fsdir file unit seen=" " props config kind path reason

  command -v systemctl >/dev/null 2>&1 || return 0
  for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    fsdir="$(fs_path "$dir")"
    [ -d "$fsdir" ] || continue
    for file in "$fsdir"/*.service; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      unit="${file##*/}"
      ez_unit_name_ok "$unit" || continue
      case "$seen" in *" $unit "*) continue ;; esac
      seen="$seen$unit "
      ez_unit_denied "$unit" && continue

      props="$(systemctl show --no-pager -p LoadState -p FragmentPath -p DropInPaths \
        -p WorkingDirectory -p ExecStart -p Environment -p EnvironmentFiles -- "$unit" 2>/dev/null)" || continue
      printf '%s\n' "$props" | grep -F -x -q 'LoadState=loaded' || continue
      config=""
      while IFS=' ' read -r kind path; do
        [ -n "$path" ] || continue
        ez_path_chars_ok "$path" || continue
        path="$(fs_path "$path")"
        [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || continue
        config="$config
$(cat -- "$path" 2>/dev/null)"
      done <<EOF
$(ez_systemd_config_files "$props")
EOF
      reason="$(ez_systemd_bound "$cert" "$props" "$config")" || continue
      printf 'systemd|%s|%s\n' "$unit" "$reason"
    done
  done
}

EZ_COMPOSE_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unq(s) { s = trim(s); if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2); return s }
function expand(s,   out, tok, inner, name, def) {
  out = ""
  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*/)) {
    tok = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1)
    s = substr(s, RSTART + RLENGTH)
    if (substr(tok, 2, 1) == "{") inner = substr(tok, 3, length(tok) - 3); else inner = substr(tok, 2)
    name = inner; def = ""
    if (match(inner, /[^A-Za-z0-9_]/)) {
      name = substr(inner, 1, RSTART - 1); def = substr(inner, RSTART)
      if (def ~ /^:?[-=]/) sub(/^:?[-=]/, "", def); else def = ""
    }
    if ((name in env) && env[name] != "") out = out env[name]; else out = out def
  }
  return out s
}
function normpath(p,   n, parts, i, sp, stack, out) {
  if (substr(p, 1, 1) != "/") p = proj "/" p
  n = split(p, parts, "/"); sp = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (sp > 0) sp--; continue }
    stack[++sp] = parts[i]
  }
  out = ""
  for (i = 1; i <= sp; i++) out = out "/" stack[i]
  return out == "" ? "/" : out
}
function covers(src) { return (cert == src || index(cert, src "/") == 1) }
function isname(c) { return (c ~ /[A-Za-z0-9._-]/) }
function hasword(line, w,   pos, rest, before, after, off) {
  off = 0; rest = line
  while ((pos = index(rest, w)) > 0) {
    before = (off + pos > 1) ? substr(line, off + pos - 1, 1) : ""
    after = substr(line, off + pos + length(w), 1)
    if ((before == "" || !isname(before)) && (after == "" || !isname(after))) return 1
    off += pos; rest = substr(line, off + 1)
  }
  return 0
}
function refs(line) { return hasword(line, cert) || hasword(line, base) }
function hit(svc, why) { hits++; if (!((svc SUBSEP why) in seen)) { seen[svc SUBSEP why] = 1; print svc "|" why } }
function envfile_refs(path,   line, found) {
  path = fsroot normpath(expand(unq(path)))
  found = 0
  while ((getline line < path) > 0) { if (refs(expand(line))) found = 1 }
  close(path)
  return found
}
BEGIN {
  if (envfile != "") {
    while ((getline line < envfile) > 0) {
      sub(/\r$/, "", line)
      if (line ~ /^[ \t]*(#|$)/) continue
      sub(/^[ \t]*export[ \t]+/, "", line)
      eq = index(line, "="); if (eq == 0) continue
      k = trim(substr(line, 1, eq - 1)); v = unq(substr(line, eq + 1))
      if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/) env[k] = v
    }
    close(envfile)
  }
}
FNR == 1 { pass++; section = ""; svc = ""; svcind = -1; propind = -1; prop = ""; defind = -1; def = "" }
{
  line = $0; sub(/\r$/, "", line)
  if (line ~ /^[ \t]*(#|$)/) next
  sub(/[ \t]+#.*$/, "", line)
  match(line, /^ */); ind = RLENGTH; content = substr(line, ind + 1)
  if (ind == 0) { section = content; sub(/:.*/, "", section); svc = ""; svcind = -1; propind = -1; prop = ""; defind = -1; def = ""; next }
}
pass == 1 && (section == "configs" || section == "secrets") {
  if (defind < 0) defind = ind
  if (ind == defind) { def = content; sub(/:.*/, "", def); def = unq(def); next }
  if (def != "" && content ~ /^file:/) { v = content; sub(/^file:[ \t]*/, "", v); if (covers(normpath(expand(unq(v))))) defhit[section SUBSEP def] = 1 }
  next
}
pass == 2 && section == "services" {
  if (svcind < 0) svcind = ind
  if (ind == svcind) {
    svc = ""
    if (content ~ /^[^ :]+:[ \t]*$/) { svc = content; sub(/:.*/, "", svc); svc = unq(svc); services[++nsvc] = svc }
    prop = ""; propind = -1; next
  }
  if (svc == "" || ind < svcind) next
  if (propind < 0) propind = ind
  if (ind == propind) {
    prop = content; sub(/:.*/, "", prop)
    val = ""; if (index(content, ":") > 0) val = trim(substr(content, index(content, ":") + 1))
    if (prop == "env_file" && val != "" && val !~ /^\[/) { if (envfile_refs(val)) hit(svc, "env_file") }
  }
  if (refs(expand(content))) hit(svc, "reference")
  if (ind > propind) {
    if (prop == "volumes") {
      if (content ~ /^- /) {
        v = expand(unq(substr(content, 3)))
        if (v ~ /^(\.|\/)/) { src = v; c = index(src, ":"); if (c > 0) src = substr(src, 1, c - 1); if (covers(normpath(src))) hit(svc, "volume") }
      }
      if (content ~ /^(- )?source:/) { v = content; sub(/^(- )?source:[ \t]*/, "", v); v = expand(unq(v)); if (v ~ /^(\.|\/)/ && covers(normpath(v))) hit(svc, "volume") }
    }
    if (prop == "env_file" && content ~ /^- /) { v = substr(content, 3); sub(/^path:[ \t]*/, "", v); if (envfile_refs(v)) hit(svc, "env_file") }
    if (prop == "configs" || prop == "secrets") {
      n = ""
      if (content ~ /^- /) n = unq(substr(content, 3))
      if (content ~ /^(- )?source:/) { n = content; sub(/^(- )?source:[ \t]*/, "", n); n = unq(n) }
      if (n != "" && ((prop SUBSEP n) in defhit)) hit(svc, prop)
    }
  }
}
END {
  if (hits == 0 && covers(proj)) for (i = 1; i <= nsvc; i++) print services[i] "|project"
}
'

# Compose file that docker compose itself would pick in a directory.
ez_compose_file_in() {
  local dir="$1" name

  for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$(fs_path "$dir/$name")" ] && [ ! -L "$(fs_path "$dir/$name")" ]; then
      printf '%s/%s' "$dir" "$name"
      return 0
    fi
  done
  return 1
}

# Prints "compose|<project-dir>|<service>|<reason>".  This is a static
# analysis of the compose files for the operator; before a restart the root
# helper independently requires that the running containers of the service
# bind-mount the certificate.
ez_detect_compose() {
  local cert="$1" base="${1##*/}" prefix dirs="" dir file root project envfile service why line

  prefix="${P1CERT_FS_ROOT:-}"
  prefix="${prefix%/}"

  # Ancestors of the certificate directory, then compose projects in the
  # usual application locations.
  dir="${cert%/*}"
  while [ -n "$dir" ] && ez_path_under_roots "$dir"; do
    dirs="${dirs:+$dirs }$dir"
    dir="${dir%/*}"
  done
  for root in $EZ_ALLOWED_ROOTS; do
    [ -d "$(fs_path "$root")" ] || continue
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      dir="${file#"$prefix"}"
      dir="${dir%/*}"
      ez_path_under_roots "$dir" || continue
      ez_names_contain "$dirs" "$dir" || dirs="${dirs:+$dirs }$dir"
    done <<EOF
$(find -P "$(fs_path "$root")" -maxdepth 3 -type f \( -name compose.yaml -o -name compose.yml -o -name docker-compose.yaml -o -name docker-compose.yml \) 2>/dev/null)
EOF
  done

  for project in $dirs; do
    file="$(ez_compose_file_in "$project")" || continue
    envfile="$(fs_path "$project/.env")"
    [ -f "$envfile" ] && [ ! -L "$envfile" ] || envfile=""
    while IFS='|' read -r service why; do
      [ -n "$service" ] || continue
      ez_compose_service_ok "$service" || continue
      case "$why" in
        reference) line='compose odwołuje się do pliku certyfikatu' ;;
        volume) line='wolumen obejmuje plik certyfikatu' ;;
        env_file) line='env_file odwołuje się do certyfikatu' ;;
        configs|secrets) line="compose $why obejmuje certyfikat" ;;
        project) line='certyfikat w katalogu projektu (service niejednoznaczny)' ;;
        *) continue ;;
      esac
      printf 'compose|%s|%s|%s\n' "$project" "$service" "$line"
    done <<EOF
$(awk -v cert="$cert" -v base="$base" -v proj="$project" -v envfile="$envfile" -v fsroot="$prefix" "$EZ_COMPOSE_AWK" "$(fs_path "$file")" "$(fs_path "$file")" 2>/dev/null)
EOF
  done
}

# Fills C_* arrays with the restart candidates of one certificate.
ez_detect_targets() {
  local cert="$1" kind a b reason line key seen=" "

  C_COUNT=0
  C_KIND=(); C_A=(); C_B=(); C_REASON=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      systemd\|*)
        IFS='|' read -r kind a reason <<EOF
$line
EOF
        b='-'
        ;;
      compose\|*)
        IFS='|' read -r kind a b reason <<EOF
$line
EOF
        ;;
      *) continue ;;
    esac
    key="$kind:$a:$b"
    case "$seen" in *" $key "*) continue ;; esac
    seen="$seen$key "
    C_KIND[$C_COUNT]="$kind"; C_A[$C_COUNT]="$a"; C_B[$C_COUNT]="$b"; C_REASON[$C_COUNT]="$reason"
    C_COUNT=$((C_COUNT + 1))
    ez_log "detected $kind $a $b ($reason) for $cert"
  done <<EOF
$(ez_detect_systemd "$cert"; ez_detect_compose "$cert")
EOF
}

ez_restart_label() {
  case "$1" in
    systemd) printf 'systemctl restart %s' "$2" ;;
    compose) printf 'restart kontenerów usługi Compose %s (katalog %s)' "$3" "$2" ;;
    *) printf 'brak restartu' ;;
  esac
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

# Parses one TARGET record (plan version 2) without eval:
#   path|local-leaf-fp|local-notafter|local-file-sha256|
#   source-leaf-fp|source-notafter|source-file-sha256|kind|a|b
# The *-file-sha256 values are the SHA-256 of the exact bytes of the whole
# local file and of the whole source file approved by the operator.
# Appends to P_* arrays.
ez_plan_parse_target() {
  local path lfp lna ldg rfp rna rdg kind a b separators i

  # Exactly 10 fields = exactly 9 separators.  "read" alone cannot tell a
  # trailing empty field ("...|-|") from none, so count them first.
  separators="${1//[!|]/}"
  [ "${#separators}" -eq 9 ] || return 1
  IFS='|' read -r path lfp lna ldg rfp rna rdg kind a b <<EOF
$1
EOF
  ez_target_path_ok "$path" || return 1
  ez_fp_ok "$lfp" && ez_fp_ok "$rfp" || return 1
  ez_epoch_ok "$lna" && ez_epoch_ok "$rna" || return 1
  ez_digest_ok "$ldg" && ez_digest_ok "$rdg" || return 1
  [ "$lfp" != "$rfp" ] || return 1
  case "$kind" in
    none) [ "$a" = - ] && [ "$b" = - ] || return 1 ;;
    systemd) ez_unit_name_ok "$a" && [ "$b" = - ] || return 1 ;;
    compose) ez_path_under_roots "$a" && ez_compose_service_ok "$b" || return 1 ;;
    *) return 1 ;;
  esac
  i=0
  while [ "$i" -lt "$P_COUNT" ]; do
    [ "${P_PATH[$i]}" != "$path" ] || return 1
    i=$((i + 1))
  done
  P_PATH[$P_COUNT]="$path"; P_LFP[$P_COUNT]="$lfp"; P_LNA[$P_COUNT]="$lna"; P_LDG[$P_COUNT]="$ldg"
  P_RFP[$P_COUNT]="$rfp"; P_RNA[$P_COUNT]="$rna"; P_RDG[$P_COUNT]="$rdg"
  P_KIND[$P_COUNT]="$kind"; P_A[$P_COUNT]="$a"; P_B[$P_COUNT]="$b"
  P_COUNT=$((P_COUNT + 1))
}

# Loads the accepted plan.  Returns 2 when absent, 1 when invalid; an invalid
# plan leaves no partially loaded targets behind.
ez_plan_load() {
  local rc

  ez_plan_load_records "${1:-$EZ_PLAN_FILE}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    P_COUNT=0; P_ID=""
    P_PATH=(); P_LFP=(); P_LNA=(); P_LDG=(); P_RFP=(); P_RNA=(); P_RDG=(); P_KIND=(); P_A=(); P_B=()
  fi
  return "$rc"
}

ez_plan_load_records() {
  local file="$1" line key value version=""

  P_COUNT=0; P_ID=""; P_CREATED_AT=""; P_CREATED_BY=""
  P_PATH=(); P_LFP=(); P_LNA=(); P_LDG=(); P_RFP=(); P_RNA=(); P_RDG=(); P_KIND=(); P_A=(); P_B=()
  [ -e "$file" ] || [ -L "$file" ] || return 2
  if [ -L "$file" ] || [ ! -f "$file" ] || ! ez_file_owner_ok "$file"; then
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) return 1 ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      PLAN_VERSION) [ "$value" = 2 ] || return 1; version=2 ;;
      PLAN_ID)
        printf '%s\n' "$value" | grep -E -q '^[0-9]{14}-[0-9]+$' || return 1
        P_ID="$value"
        ;;
      CREATED_AT)
        case "$value" in ''|*[!0-9T:+-]*) return 1 ;; esac
        P_CREATED_AT="$value"
        ;;
      CREATED_BY|HOST)
        case "$value" in *[!A-Za-z0-9._-]*) return 1 ;; esac
        [ "$key" = HOST ] || P_CREATED_BY="$value"
        ;;
      TARGET) ez_plan_parse_target "$value" || return 1 ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$version" = 2 ] && [ -n "$P_ID" ] || return 1
  return 0
}

ez_plan_load_reported() {
  local rc

  ez_plan_load
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) ez_err "brak zaakceptowanego planu ($EZ_PLAN_FILE). Uruchom: p1cert ezdrowie plan" ;;
    *) ez_err "plan $EZ_PLAN_FILE jest nieprawidłowy lub ma starszy format (wymagany PLAN_VERSION=2); utwórz nowy: p1cert ezdrowie plan" ;;
  esac
  return "$rc"
}

ez_plan_print() {
  local i=0

  printf 'Plan: %s\n  ID: %s\n  Utworzony: %s przez %s\n  Targety: %s\n' \
    "$EZ_PLAN_FILE" "$P_ID" "$P_CREATED_AT" "$P_CREATED_BY" "$P_COUNT"
  while [ "$i" -lt "$P_COUNT" ]; do
    printf '  - %s\n      lokalny SHA-256: %s\n      nowy SHA-256:    %s\n      restart: %s\n' \
      "${P_PATH[$i]}" "${P_LFP[$i]}" "${P_RFP[$i]}" "$(ez_restart_label "${P_KIND[$i]}" "${P_A[$i]}" "${P_B[$i]}")"
    i=$((i + 1))
  done
}

ez_plan() {
  local i r decision approved=0 candidates=0 choice kind a b n issuer_note reason ldg rdg
  local -a A_PATH=() A_LFP=() A_LNA=() A_LDG=() A_RFP=() A_RNA=() A_RDG=() A_KIND=() A_A=() A_B=()

  ez_log_open plan || return 1
  if ! ez_is_tty; then
    ez_err 'p1cert ezdrowie plan wymaga interaktywnego terminala (akceptacja operatora).'
    return 1
  fi
  ez_collect_local || return 1
  ez_print_local
  if ! ez_fetch_remote; then
    ez_err 'nie można zweryfikować certyfikatu źródłowego; plan nie został zmieniony.'
    return 1
  fi
  ez_print_remote

  printf '\nDecyzje:\n'
  i=0
  while [ "$i" -lt "$L_COUNT" ]; do
    if [ "${L_STATE[$i]}" != OK ]; then
      ez_say "  SKIP       ${L_PATH[$i]} (${L_REASON[$i]})"
      i=$((i + 1))
      continue
    fi
    ez_select_remote "${L_CN[$i]}" "${L_NAMES[$i]}"
    if [ "$SEL_STATE" = VALID ]; then
      r="$SEL_INDEX"
      decision="$(ez_decide VALID "${L_FP[$i]}" "${L_NA[$i]}" "${R_FP[$r]}" "${R_NA[$r]}")"
    else
      r=-1
      decision="$(ez_decide "$SEL_STATE" "${L_FP[$i]}" "${L_NA[$i]}" '' 0)"
    fi
    case "$decision" in
      SKIP) ez_say "  SKIP       ${L_PATH[$i]} ($SEL_REASON)"; i=$((i + 1)); continue ;;
      SKIP_WARNING) ez_warn "SKIP ${L_PATH[$i]}: $SEL_REASON"; i=$((i + 1)); continue ;;
      NO_CHANGE) ez_say "  NO CHANGE  ${L_PATH[$i]} (źródło: ${R_NAME[$r]}, NotAfter ${R_NOT_AFTER[$r]})"; i=$((i + 1)); continue ;;
    esac
    # Same rule as the root helper: a chain only into a PEM target, a local
    # chain is never reduced to a single certificate.
    if ! reason="$(ez_replacement_format_ok "${L_FMT[$i]}" "${L_NCERT[$i]}" "${R_FMT[$r]}" "${R_NCERT[$r]}")"; then
      ez_warn "SKIP ${L_PATH[$i]}: $reason (źródło: ${R_NAME[$r]}) - wymagana podmiana ręczna."
      i=$((i + 1))
      continue
    fi
    # The helper is called by this user through sudo, so it is the operator.
    if ! ez_target_dir_ok "$(fs_path "${L_PATH[$i]%/*}")" "$EZ_TRUSTED_UID" "$EZ_TRUSTED_GID" "$(id -u)" "$(id -g)"; then
      ez_warn "SKIP ${L_PATH[$i]}: katalog docelowy nie należy do root ani do użytkownika P1CERT, jest zapisywalny dla innych albo dla grupy innej niż root/grupa użytkownika P1CERT; helper odmówi podmiany - wymagana podmiana ręczna."
      i=$((i + 1))
      continue
    fi
    # The approval binds the exact bytes of both whole files (not only the
    # leaf): the local copy inspected above and the downloaded source.
    ldg="$(ez_file_digest "${L_FILE[$i]}")"
    rdg="$(ez_file_digest "${R_FILE[$r]}")"
    if ! ez_digest_ok "$ldg" || ! ez_digest_ok "$rdg"; then
      ez_warn "SKIP ${L_PATH[$i]}: nie można obliczyć SHA-256 pliku lokalnego lub źródłowego."
      i=$((i + 1))
      continue
    fi

    candidates=$((candidates + 1))
    issuer_note=""
    [ "${L_ISSUER[$i]}" = "${R_ISSUER[$r]}" ] || issuer_note=yes
    ez_say "  UPDATE CANDIDATE ${L_PATH[$i]}"
    printf '\n=== UPDATE CANDIDATE %s ===\n' "$candidates"
    printf '  Lokalny certyfikat: %s\n' "${L_PATH[$i]}"
    printf '  Lokalny NotAfter:   %s\n' "${L_NOT_AFTER[$i]}"
    printf '  Zdalny plik:        %s\n' "${R_NAME[$r]}"
    printf '  Zdalny NotAfter:    %s\n' "${R_NOT_AFTER[$r]}"
    printf '  Stary SHA-256:      %s\n' "${L_FP[$i]}"
    printf '  Nowy SHA-256:       %s\n' "${R_FP[$r]}"
    printf '  Nowy Subject:       %s\n' "$(ez_printable "${R_SUBJECT[$r]}")"
    printf '  Nowy Issuer:        %s\n' "$(ez_printable "${R_ISSUER[$r]}")"
    printf '  SHA-256 pliku lok.: %s\n' "$ldg"
    printf '  SHA-256 pliku źr.:  %s\n' "$rdg"
    if [ "${L_NCERT[$i]}" -gt 1 ] || [ "${R_NCERT[$r]}" -gt 1 ]; then
      printf '  Łańcuch PEM:        obecnie %s, nowy %s certyfikat(y); decyzja dotyczy certyfikatu końcowego, zapisany zostanie cały zweryfikowany plik źródłowy\n' \
        "${L_NCERT[$i]}" "${R_NCERT[$r]}"
    fi
    if [ -n "$issuer_note" ]; then
      printf '  UWAGA: wystawca nowego certyfikatu różni się od obecnego.\n'
      ez_log "issuer change for ${L_PATH[$i]}"
    fi

    ez_detect_targets "${L_PATH[$i]}"
    kind=none; a='-'; b='-'
    if [ "$C_COUNT" -eq 0 ]; then
      printf '  Aplikacja/usługa:   NIE WYKRYTO\n  Przewidywany restart: brak (restart ręczny po weryfikacji)\n'
    else
      printf '  Wykryte aplikacje/usługi:\n'
      n=0
      while [ "$n" -lt "$C_COUNT" ]; do
        printf '    %s) %s - %s\n' "$((n + 1))" "$(ez_restart_label "${C_KIND[$n]}" "${C_A[$n]}" "${C_B[$n]}")" "${C_REASON[$n]}"
        n=$((n + 1))
      done
      if [ "$C_COUNT" -eq 1 ]; then
        printf '  Przewidywany restart: %s\n' "$(ez_restart_label "${C_KIND[0]}" "${C_A[0]}" "${C_B[0]}")"
      else
        printf '  Przewidywany restart: NIEJEDNOZNACZNY - wymagany wybór operatora\n'
      fi
      case " ${C_KIND[*]} " in
        *' compose '*)
          printf '  Uwaga: restart Compose wykonuje helper tylko, gdy działające kontenery usługi mają bind mount tego certyfikatu;\n'
          printf '         w przeciwnym razie przy run target zostanie pominięty bez zmian.\n'
          ;;
      esac
    fi

    if ! ez_ask_yes '  Dopuścić PODMIANĘ tego certyfikatu?'; then
      ez_say "  operator odrzucił podmianę: ${L_PATH[$i]}"
      i=$((i + 1))
      continue
    fi
    if [ "$C_COUNT" -eq 1 ]; then
      if ez_ask_yes "  Dopuścić RESTART: $(ez_restart_label "${C_KIND[0]}" "${C_A[0]}" "${C_B[0]}")?"; then
        kind="${C_KIND[0]}"; a="${C_A[0]}"; b="${C_B[0]}"
      fi
    elif [ "$C_COUNT" -gt 1 ]; then
      choice=""
      read -r -p "  Wybierz numer usługi do restartu (1-$C_COUNT) albo 0, aby odrzucić restart: " choice || choice=0
      case "$choice" in
        ''|*[!0-9]*) choice=0 ;;
      esac
      if [ "$choice" -ge 1 ] && [ "$choice" -le "$C_COUNT" ]; then
        n=$((choice - 1))
        if ez_ask_yes "  Potwierdź RESTART: $(ez_restart_label "${C_KIND[$n]}" "${C_A[$n]}" "${C_B[$n]}")?"; then
          kind="${C_KIND[$n]}"; a="${C_A[$n]}"; b="${C_B[$n]}"
        fi
      fi
    fi
    ez_say "  zaakceptowano: ${L_PATH[$i]} restart=$(ez_restart_label "$kind" "$a" "$b")"
    A_PATH[$approved]="${L_PATH[$i]}"; A_LFP[$approved]="${L_FP[$i]}"; A_LNA[$approved]="${L_NA[$i]}"
    A_LDG[$approved]="$ldg"
    A_RFP[$approved]="${R_FP[$r]}"; A_RNA[$approved]="${R_NA[$r]}"; A_RDG[$approved]="$rdg"
    A_KIND[$approved]="$kind"; A_A[$approved]="$a"; A_B[$approved]="$b"
    approved=$((approved + 1))
    i=$((i + 1))
  done

  printf '\nUPDATE CANDIDATES: %s, zaakceptowane: %s\n' "$candidates" "$approved"
  if [ "$candidates" -eq 0 ]; then
    ez_say 'Brak kandydatów do aktualizacji; zapisany plan nie został zmieniony.'
    return 0
  fi

  ez_prepare_dir "$STATE_DIR" 0755 || return 1
  {
    printf '# P1CERT ezdrowie plan - generated by "p1cert ezdrowie plan". Do not edit.\n'
    printf 'PLAN_VERSION=2\n'
    printf 'PLAN_ID=%s-%s\n' "$(date '+%Y%m%d%H%M%S')" "$$"
    printf 'CREATED_AT=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'CREATED_BY=%s\n' "$(printf '%s' "$(id -un 2>/dev/null)" | tr -c 'A-Za-z0-9._-' '_')"
    printf 'HOST=%s\n' "$(printf '%s' "$(hostname 2>/dev/null)" | tr -c 'A-Za-z0-9._-' '_')"
    n=0
    while [ "$n" -lt "$approved" ]; do
      printf 'TARGET=%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${A_PATH[$n]}" "${A_LFP[$n]}" "${A_LNA[$n]}" "${A_LDG[$n]}" \
        "${A_RFP[$n]}" "${A_RNA[$n]}" "${A_RDG[$n]}" "${A_KIND[$n]}" "${A_A[$n]}" "${A_B[$n]}"
      n=$((n + 1))
    done
  } | ez_write_atomic "$EZ_PLAN_FILE" || {
    ez_err "nie można zapisać planu: $EZ_PLAN_FILE"
    return 1
  }
  if ! ez_plan_load; then
    ez_err 'zapisany plan nie przechodzi walidacji.'
    return 1
  fi
  ez_say "Zapisano plan: $EZ_PLAN_FILE (ID $P_ID, targety: $P_COUNT)"
  if [ -f "$EZ_SCHEDULE_FILE" ]; then
    ez_warn 'istnieje zaplanowane uruchomienie dla poprzedniego planu; nie zostanie ono wykonane dla nowego planu. Użyj ponownie: p1cert ezdrowie schedule'
  fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

ez_backup_dir_create() {
  local ts dir n=0

  [ -z "${RUN_BACKUP_DIR:-}" ] || return 0
  ez_prepare_dir "$BACKUPS_DIR" 0700 || return 1
  ez_prepare_dir "$EZ_BACKUP_ROOT" 0700 || return 1
  ts="$(date '+%Y%m%d_%H%M%S')"
  dir="$EZ_BACKUP_ROOT/$ts"
  # mkdir without -p never reuses or overwrites an existing backup.
  while ! mkdir -m 0700 -- "$dir" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || return 1
    dir="$EZ_BACKUP_ROOT/${ts}_$n"
  done
  RUN_BACKUP_DIR="$dir"
}

# Backs up the inspected old certificate copy and writes its manifest.
ez_backup_target() {
  local index="$1" path="$2" old_copy="$3" old_fp="$4" new_fp="$5" old_na="$6" new_na="$7"
  local name meta owner group uid gid mode context backup manifest

  ez_backup_dir_create || return 1
  name="${path##*/}"
  backup="$RUN_BACKUP_DIR/$index-$name"
  manifest="$backup.manifest"
  [ ! -e "$backup" ] && [ ! -e "$manifest" ] || return 1
  meta="$(stat -c '%U|%G|%u|%g|%a' -- "$(fs_path "$path")" 2>/dev/null)" || return 1
  IFS='|' read -r owner group uid gid mode <<EOF
$meta
EOF
  context="$(stat -c '%C' -- "$(fs_path "$path")" 2>/dev/null || true)"
  case "$context" in ''|*[!A-Za-z0-9_:.,-]*|'?') context=none ;; esac

  cp -- "$old_copy" "$backup" && chmod 0400 "$backup" || return 1
  ez_cert_inspect "$backup" && [ "$EZC_FP" = "$old_fp" ] || return 1
  {
    printf 'ORIGINAL_PATH=%s\n' "$path"
    printf 'ORIGINAL_NAME=%s\n' "$name"
    printf 'BACKUP_FILE=%s\n' "${backup##*/}"
    printf 'OLD_FP=%s\n' "$old_fp"
    printf 'NEW_FP=%s\n' "$new_fp"
    printf 'OLD_NOT_AFTER=%s\n' "$(date -u -d "@$old_na" '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'NEW_NOT_AFTER=%s\n' "$(date -u -d "@$new_na" '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'OLD_NOT_AFTER_EPOCH=%s\nNEW_NOT_AFTER_EPOCH=%s\n' "$old_na" "$new_na"
    printf 'OWNER=%s\nGROUP=%s\nOWNER_UID=%s\nGROUP_GID=%s\nMODE=%s\n' "$owner" "$group" "$uid" "$gid" "$mode"
    printf 'SELINUX_CONTEXT=%s\n' "$context"
    printf 'PLAN_ID=%s\n' "$P_ID"
    printf 'OPERATION_TIMESTAMP=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$manifest" && chmod 0400 "$manifest" || return 1
  ez_log "backup $path -> $backup"
}

ez_set_result() {
  T_RESULT[$1]="$2"
  T_DETAIL[$1]="$3"
  ez_log "target ${P_PATH[$1]}: $2 - $3"
}

# Calls exactly one helper operation for an approved target: "apply" (no
# restart approved), "apply-systemd" or "apply-compose".  The helper replaces
# the certificate, restarts only the approved unit/service after proving its
# relation to the certificate and rolls back from its own copy of the old
# certificate if the restart fails.  The plan's SHA-256 of the exact old target
# file and of the exact source file are passed along; the helper refuses any
# other bytes.  Prints the helper RESULT value.
ez_helper_apply() {
  local i="$1" old_fp="$2" new_fp="$3" new_file="$4" out rc

  case "${P_KIND[$i]}" in
    none) out="$(ez_helper_run apply "${P_PATH[$i]}" "$old_fp" "$new_fp" "${P_LDG[$i]}" "${P_RDG[$i]}" < "$new_file")" ;;
    systemd) out="$(ez_helper_run apply-systemd "${P_PATH[$i]}" "$old_fp" "$new_fp" "${P_LDG[$i]}" "${P_RDG[$i]}" "${P_A[$i]}" < "$new_file")" ;;
    compose) out="$(ez_helper_run apply-compose "${P_PATH[$i]}" "$old_fp" "$new_fp" "${P_LDG[$i]}" "${P_RDG[$i]}" "${P_A[$i]}" "${P_B[$i]}" < "$new_file")" ;;
    *) return 2 ;;
  esac
  rc=$?
  ez_log "helper apply ${P_PATH[$i]} rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
  printf '%s\n' "$out" | sed -n 's/^RESULT=//p' | head -n 1
  return "$rc"
}

ez_replace_one() {
  local i="$1" r rc copy decision result label reason

  copy="$EZ_TMP/run-local-$i.cert"
  if ! ez_fetch_local "${P_PATH[$i]}" "$copy" || ! ez_cert_inspect "$copy"; then
    ez_set_result "$i" SKIP 'local certificate missing or unreadable'
    return 0
  fi
  ez_cert_save CUR
  ez_select_remote "$CUR_CN" "$CUR_NAMES"
  if [ "$SEL_STATE" != VALID ]; then
    if [ "$SEL_STATE" = ABSENT ]; then
      ez_set_result "$i" SKIP 'remote source absent'
    else
      ez_set_result "$i" SKIP "remote source invalid: $SEL_REASON"
      ez_warn "${P_PATH[$i]}: $SEL_REASON"
    fi
    return 0
  fi
  r="$SEL_INDEX"
  if [ "${R_FP[$r]}" = "$CUR_FP" ]; then
    ez_set_result "$i" NO_CHANGE 'local certificate already identical to source'
    return 0
  fi
  if [ "$CUR_FP" != "${P_LFP[$i]}" ]; then
    ez_set_result "$i" SKIP 'local fingerprint differs from the accepted plan; create a new plan'
    return 0
  fi
  if [ "${R_FP[$r]}" != "${P_RFP[$i]}" ]; then
    ez_set_result "$i" SKIP 'source certificate differs from the accepted plan; create a new plan'
    return 0
  fi
  # The plan approved exact files, not only leaf certificates: any other byte
  # (intermediate/root of a chain, line endings, ...) requires a new plan.
  # The helper checks both digests again inside its own operation.
  if [ "$(ez_file_digest "$copy")" != "${P_LDG[$i]}" ]; then
    ez_set_result "$i" SKIP 'local certificate file changed since the accepted plan (SHA-256 of the whole file differs); create a new plan'
    return 0
  fi
  if [ "$(ez_file_digest "${R_FILE[$r]}")" != "${P_RDG[$i]}" ]; then
    ez_set_result "$i" SKIP 'source certificate file changed since the accepted plan (SHA-256 of the whole file differs); create a new plan'
    return 0
  fi
  decision="$(ez_decide VALID "$CUR_FP" "$CUR_NA_EPOCH" "${R_FP[$r]}" "${R_NA[$r]}")"
  if [ "$decision" != UPDATE ]; then
    ez_set_result "$i" NO_CHANGE 'local certificate is not older than source'
    return 0
  fi
  if ! reason="$(ez_replacement_format_ok "$CUR_FORMAT" "$CUR_COUNT" "${R_FMT[$r]}" "${R_NCERT[$r]}")"; then
    ez_set_result "$i" SKIP "certificate file format not replaceable automatically: $reason"
    return 0
  fi
  ez_log "decision UPDATE ${P_PATH[$i]} old=$CUR_FP new=${R_FP[$r]} certificates=$CUR_COUNT->${R_NCERT[$r]}"

  # Audit/operator backup.  The helper never uses it: its rollback source is
  # its own copy of the old certificate read inside the same operation.
  if ! ez_backup_target "$((i + 1))" "${P_PATH[$i]}" "$copy" "$CUR_FP" "${R_FP[$r]}" "$CUR_NA_EPOCH" "${R_NA[$r]}"; then
    ez_set_result "$i" ERROR 'backup failed; certificate not replaced'
    return 0
  fi

  label="$(ez_restart_label "${P_KIND[$i]}" "${P_A[$i]}" "${P_B[$i]}")"
  [ "${P_KIND[$i]}" = none ] || ez_say "Podmiana + restart: ${P_PATH[$i]} -> $label"
  result="$(ez_helper_apply "$i" "$CUR_FP" "${R_FP[$r]}" "${R_FILE[$r]}")"
  rc=$?
  case "$rc:$result" in
    0:UPDATED|0:UPDATED_RESTARTED) ;;
    0:NO_CHANGE) ez_set_result "$i" NO_CHANGE 'helper: certificate already identical to source'; return 0 ;;
    2:*) ez_set_result "$i" REFUSED "helper refused (validation or unconfirmed service relation); certificate not replaced"; return 0 ;;
    3:*) ez_set_result "$i" SKIP 'helper precondition changed (fingerprint or exact file bytes differ from the accepted plan); certificate not replaced'; return 0 ;;
    4:*) ez_set_result "$i" ERROR 'replacement undone by helper before restart (verification or service relation failed); previous certificate restored'; return 0 ;;
    5:*) ez_set_result "$i" ROLLBACK "$label failed; previous certificate restored; restart with previous certificate succeeded"; return 0 ;;
    6:*) ez_set_result "$i" ROLLBACK_RESTART_FAILED "$label failed; previous certificate restored and verified, but the application/service still did not start correctly with it - manual intervention required"; return 0 ;;
    7:*) ez_set_result "$i" CRITICAL "ROLLBACK FAILED - previous certificate NOT restored; restore manually from $RUN_BACKUP_DIR"; return 0 ;;
    *) ez_set_result "$i" ERROR "helper apply failed (code $rc)"; return 0 ;;
  esac

  # Independent verification of the file on disk.
  copy="$EZ_TMP/run-verify-$i.cert"
  # A chain is written byte for byte: the whole file must equal the source.
  if ! ez_fetch_local "${P_PATH[$i]}" "$copy" || ! ez_cert_inspect "$copy" ||
     [ "$EZC_FP" != "${R_FP[$r]}" ] || [ "$EZC_NA_EPOCH" != "${R_NA[$r]}" ] ||
     [ "$EZC_COUNT" != "${R_NCERT[$r]}" ] ||
     { [ "${R_NCERT[$r]}" -gt 1 ] && [ "$(ez_file_digest "$copy")" != "$(ez_file_digest "${R_FILE[$r]}")" ]; }; then
    ez_set_result "$i" ERROR 'helper reported success but the file on disk does not match the source - manual check required'
    return 0
  fi
  if [ "$result" = UPDATED_RESTARTED ]; then
    ez_set_result "$i" UPDATED "replaced, verified and $label succeeded"
  else
    ez_set_result "$i" UPDATED 'replaced and verified; no restart approved (restart manually if required)'
  fi
}

ez_schedule_value() {
  local key="$1" line

  [ -f "$EZ_SCHEDULE_FILE" ] && [ ! -L "$EZ_SCHEDULE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$EZ_SCHEDULE_FILE"
  return 1
}

ez_last_run_write() {
  local mode="$1" result="$2" i=0 detail

  ez_prepare_dir "$STATE_DIR" 0755 || return 1
  {
    printf 'LAST_RUN_TIMESTAMP=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'LAST_RUN_MODE=%s\n' "$mode"
    printf 'LAST_RUN_PLAN_ID=%s\n' "${P_ID:-none}"
    printf 'LAST_RUN_RESULT=%s\n' "$result"
    printf 'LAST_RUN_LOG=%s\n' "$EZ_LOG_FILE"
    printf 'LAST_RUN_BACKUP=%s\n' "${RUN_BACKUP_DIR:-none}"
    while [ "$i" -lt "${T_COUNT:-0}" ]; do
      detail="$(printf '%s' "${T_DETAIL[$i]}" | tr -c 'A-Za-z0-9 ._:;,()/@+=-' '_')"
      printf 'TARGET_RESULT=%s|%s|%s\n' "${P_PATH[$i]}" "${T_RESULT[$i]}" "$detail"
      i=$((i + 1))
    done
  } | ez_write_atomic "$EZ_LAST_RUN_FILE"
  chmod 0644 "$EZ_LAST_RUN_FILE" 2>/dev/null || true
}

ez_schedule_consume() {
  ez_helper_run schedule-cancel >/dev/null || ez_warn 'nie można wyłączyć timera po jednorazowym uruchomieniu.'
  rm -f -- "$EZ_SCHEDULE_FILE"
  ez_log 'schedule consumed'
}

# Overall run result from T_RESULT[], most severe first:
#   CRITICAL > ROLLBACK_RESTART_FAILED > ROLLBACK > ERROR (incl. REFUSED)
#   > PARTIAL (some SKIP next to UPDATED/NO_CHANGE) > SKIPPED (all SKIP)
#   > OK (something updated, rest NO_CHANGE) > NO_CHANGE.
ez_run_result() {
  local i=0 critical=0 rrf=0 rollback=0 error=0 skip=0 updated=0 nochange=0

  while [ "$i" -lt "${T_COUNT:-0}" ]; do
    case "${T_RESULT[$i]}" in
      CRITICAL) critical=$((critical + 1)) ;;
      ROLLBACK_RESTART_FAILED) rrf=$((rrf + 1)) ;;
      ROLLBACK) rollback=$((rollback + 1)) ;;
      UPDATED) updated=$((updated + 1)) ;;
      NO_CHANGE) nochange=$((nochange + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
      *) error=$((error + 1)) ;;
    esac
    i=$((i + 1))
  done
  if [ "$critical" -gt 0 ]; then printf 'CRITICAL'
  elif [ "$rrf" -gt 0 ]; then printf 'ROLLBACK_RESTART_FAILED'
  elif [ "$rollback" -gt 0 ]; then printf 'ROLLBACK'
  elif [ "$error" -gt 0 ]; then printf 'ERROR'
  elif [ "$skip" -gt 0 ] && [ $((updated + nochange)) -gt 0 ]; then printf 'PARTIAL'
  elif [ "$skip" -gt 0 ]; then printf 'SKIPPED'
  elif [ "$updated" -gt 0 ]; then printf 'OK'
  else printf 'NO_CHANGE'
  fi
}

ez_run_body() {
  local mode="$1" assume_yes="$2" rc i result
  local scheduled_epoch="" scheduled_sha="" now

  RUN_BACKUP_DIR=""
  T_COUNT=0; T_RESULT=(); T_DETAIL=()
  ez_tmpdir || return 1

  if [ "$mode" = scheduled ]; then
    scheduled_epoch="$(ez_schedule_value SCHEDULED_EPOCH || true)"
    scheduled_sha="$(ez_schedule_value PLAN_SHA256 || true)"
    if ! ez_epoch_ok "$scheduled_epoch" || [ -z "$scheduled_sha" ]; then
      ez_err 'uruchomienie z timera bez poprawnego stanu harmonogramu; nic nie zmieniono.'
      ez_last_run_write "$mode" SKIPPED
      ez_helper_run schedule-cancel >/dev/null 2>&1 || true
      return 3
    fi
    now="$(date '+%s')"
    # Never before the planned time, at most EZ_SCHEDULE_GRACE_SECONDS after.
    if ! ez_schedule_window_ok "$now" "$scheduled_epoch" "$EZ_SCHEDULE_GRACE_SECONDS"; then
      ez_err "uruchomienie poza oknem harmonogramu ($(ez_fmt_epoch "$scheduled_epoch")); nic nie zmieniono."
      ez_last_run_write "$mode" SKIPPED
      ez_schedule_consume
      return 3
    fi
  fi

  ez_plan_load_reported
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ez_last_run_write "$mode" SKIPPED
    [ "$mode" != scheduled ] || ez_schedule_consume
    return 3
  fi
  if [ "$mode" = scheduled ] && [ "$(ez_sha256_file "$EZ_PLAN_FILE")" != "$scheduled_sha" ]; then
    ez_err 'plan zmienił się po zaplanowaniu; nic nie zmieniono. Zaplanuj ponownie: p1cert ezdrowie schedule'
    ez_last_run_write "$mode" SKIPPED
    ez_schedule_consume
    return 3
  fi

  ez_plan_print
  if [ "$P_COUNT" -eq 0 ]; then
    ez_say 'Plan nie zawiera targetów. NO CHANGE.'
    ez_last_run_write "$mode" NO_CHANGE
    [ "$mode" != scheduled ] || ez_schedule_consume
    return 0
  fi
  if [ "$mode" = manual ] && [ "$assume_yes" != yes ]; then
    if ! ez_is_tty; then
      ez_err 'p1cert ezdrowie run bez terminala wymaga --yes.'
      return 1
    fi
    ez_ask_yes 'Wykonać zaakceptowany plan teraz?' || { ez_say 'Anulowano.'; return 0; }
  fi
  if ! ez_require_helper; then
    ez_last_run_write "$mode" ERROR
    [ "$mode" != scheduled ] || ez_schedule_consume
    return 1
  fi

  T_COUNT="$P_COUNT"
  i=0
  while [ "$i" -lt "$T_COUNT" ]; do
    T_RESULT[$i]=PENDING; T_DETAIL[$i]=''
    i=$((i + 1))
  done

  if ! ez_fetch_remote; then
    i=0
    while [ "$i" -lt "$T_COUNT" ]; do
      ez_set_result "$i" SKIP 'remote source unavailable'
      i=$((i + 1))
    done
  else
    i=0
    while [ "$i" -lt "$T_COUNT" ]; do
      ez_replace_one "$i"
      i=$((i + 1))
    done
  fi

  result="$(ez_run_result)"

  printf '\nWynik:\n'
  i=0
  while [ "$i" -lt "$T_COUNT" ]; do
    printf '  %-10s %s (%s)\n' "${T_RESULT[$i]}" "${P_PATH[$i]}" "${T_DETAIL[$i]}"
    i=$((i + 1))
  done
  [ -z "$RUN_BACKUP_DIR" ] || printf 'Backup: %s\n' "$RUN_BACKUP_DIR"
  printf 'Wynik run: %s\nLog: %s\n' "$result" "$EZ_LOG_FILE"
  ez_log "run finished result=$result"
  ez_last_run_write "$mode" "$result"
  [ "$mode" != scheduled ] || ez_schedule_consume

  case "$result" in
    OK|NO_CHANGE) return 0 ;;
    SKIPPED) return 3 ;;
    *) return 1 ;;
  esac
}

ez_run() {
  local mode=manual assume_yes=no arg

  for arg in "$@"; do
    case "$arg" in
      --scheduled) mode=scheduled ;;
      --yes) assume_yes=yes ;;
      *) printf 'Nieznana opcja run: %s\n' "$arg" >&2; return 2 ;;
    esac
  done
  ez_log_open run || return 1
  ez_log "run mode=$mode"
  ez_with_lock ez_run_body "$mode" "$assume_yes"
}

# ---------------------------------------------------------------------------
# One-shot scheduler
# ---------------------------------------------------------------------------

ez_schedule_body() {
  local when="$1" day time out epoch at sha

  ez_plan_load_reported || return 1
  if [ "$P_COUNT" -eq 0 ]; then
    ez_err 'zaakceptowany plan nie zawiera targetów; nie ma czego planować.'
    return 1
  fi
  ez_require_helper || return 1
  if [ -z "$when" ]; then
    read -r -p 'Data i godzina jednorazowego uruchomienia (YYYY-MM-DD HH:MM): ' when || true
  fi
  day="${when%% *}"
  time="${when#* }"
  printf '%s\n' "$day" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' &&
    printf '%s\n' "$time" | grep -E -q '^[0-9]{2}:[0-9]{2}$' || {
      ez_err 'oczekiwany format: YYYY-MM-DD HH:MM'
      return 2
    }
  ez_plan_print
  printf 'Jednorazowe uruchomienie: %s (czas lokalny serwera)\n' "$when"
  printf 'Jeżeli serwer będzie wyłączony w tym czasie, uruchomienie NIE zostanie nadrobione.\n'
  ez_ask_yes 'Zaplanować wykonanie tego planu?' || { ez_say 'Anulowano.'; return 0; }

  sha="$(ez_sha256_file "$EZ_PLAN_FILE")"
  out="$(ez_helper_run schedule "$day" "$time")" || {
    ez_err 'nie można zaplanować uruchomienia.'
    return 1
  }
  epoch="$(printf '%s\n' "$out" | sed -n 's/^SCHEDULED_EPOCH=//p' | head -n 1)"
  at="$(printf '%s\n' "$out" | sed -n 's/^SCHEDULED_AT=//p' | head -n 1)"
  ez_epoch_ok "$epoch" || { ez_err 'nieprawidłowa odpowiedź helpera.'; return 1; }
  {
    printf 'SCHEDULED_AT=%s\n' "$at"
    printf 'SCHEDULED_EPOCH=%s\n' "$epoch"
    printf 'PLAN_ID=%s\n' "$P_ID"
    printf 'PLAN_SHA256=%s\n' "$sha"
    printf 'CREATED_AT=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } | ez_write_atomic "$EZ_SCHEDULE_FILE" || {
    ez_err 'nie można zapisać stanu harmonogramu; anuluję timer.'
    ez_helper_run schedule-cancel >/dev/null || true
    return 1
  }
  ez_say "Zaplanowano jednorazowe wykonanie planu $P_ID na $at ($EZ_TIMER_UNIT, Persistent=false)."
}

ez_schedule() {
  local when=""

  case "$#" in
    0) ;;
    1) when="$1" ;;
    2) when="$1 $2" ;;
    *) printf 'Użycie: p1cert ezdrowie schedule [YYYY-MM-DD HH:MM]\n' >&2; return 2 ;;
  esac
  ez_log_open schedule || return 1
  if ! ez_is_tty; then
    ez_err 'p1cert ezdrowie schedule wymaga interaktywnego terminala.'
    return 1
  fi
  ez_with_lock ez_schedule_body "$when"
}

ez_schedule_status() {
  local rc value line enabled active next timer_file

  printf 'P1CERT ezdrowie - harmonogram\n\n'
  ez_plan_load
  rc=$?
  case "$rc" in
    0) ez_plan_print ;;
    2) printf 'Plan: brak\n' ;;
    *) printf 'Plan: NIEPRAWIDŁOWY (%s)\n' "$EZ_PLAN_FILE" ;;
  esac

  printf '\n'
  if value="$(ez_schedule_value SCHEDULED_AT)"; then
    printf 'Zaplanowane uruchomienie: %s\n' "$value"
    printf '  Plan ID: %s\n' "$(ez_schedule_value PLAN_ID || printf '?')"
    if [ "$rc" -eq 0 ] && [ "$(ez_sha256_file "$EZ_PLAN_FILE")" = "$(ez_schedule_value PLAN_SHA256 || true)" ]; then
      printf '  Zgodność z bieżącym planem: TAK\n'
    else
      printf '  Zgodność z bieżącym planem: NIE (uruchomienie nic nie zmieni; zaplanuj ponownie)\n'
    fi
  else
    printf 'Zaplanowane uruchomienie: brak\n'
  fi

  timer_file="/etc/systemd/system/$EZ_TIMER_UNIT"
  if command -v systemctl >/dev/null 2>&1; then
    enabled="$(systemctl is-enabled "$EZ_TIMER_UNIT" 2>/dev/null)" || true
    active="$(systemctl is-active "$EZ_TIMER_UNIT" 2>/dev/null)" || true
    next="$(systemctl show --no-pager -p NextElapseUSecRealtime "$EZ_TIMER_UNIT" 2>/dev/null | sed -n 's/^NextElapseUSecRealtime=//p')"
    printf 'Timer %s: %s\n' "$EZ_TIMER_UNIT" "$([ -f "$timer_file" ] && printf 'zainstalowany' || printf 'brak')"
    printf '  enabled: %s\n  active: %s\n  następne uruchomienie: %s\n' "${enabled:-unknown}" "${active:-unknown}" "${next:-brak}"
  else
    printf 'Timer: systemctl niedostępny\n'
  fi

  printf '\n'
  if [ -f "$EZ_LAST_RUN_FILE" ] && [ ! -L "$EZ_LAST_RUN_FILE" ]; then
    printf 'Ostatni run:\n'
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        LAST_RUN_TIMESTAMP=*|LAST_RUN_MODE=*|LAST_RUN_PLAN_ID=*|LAST_RUN_RESULT=*|LAST_RUN_LOG=*|LAST_RUN_BACKUP=*|TARGET_RESULT=*)
          printf '  %s\n' "$(ez_printable "$line")"
          ;;
      esac
    done < "$EZ_LAST_RUN_FILE"
  else
    printf 'Ostatni run: brak\n'
  fi
}

ez_schedule_cancel_body() {
  ez_require_helper || return 1
  if ! ez_helper_run schedule-cancel >/dev/null; then
    ez_err 'nie można anulować timera.'
    return 1
  fi
  rm -f -- "$EZ_SCHEDULE_FILE"
  ez_say "Anulowano oczekujące uruchomienie ($EZ_TIMER_UNIT). Plan i backupy zostały zachowane."
}

ez_schedule_cancel() {
  ez_log_open schedule-cancel || return 1
  ez_with_lock ez_schedule_cancel_body
}

# ---------------------------------------------------------------------------

ez_usage() {
  cat <<'EOF'
Użycie: p1cert ezdrowie <polecenie>

Automatyczna, zatwierdzana przez operatora podmiana certyfikatów ezdrowie.gov.pl.

Polecenia:
  credentials       zapisz Nextcloud App Password (jedyna lokalna konfiguracja)
  test              sprawdź dostęp WebDAV do katalogu P1CERT_EZDROWIE
  scan              znajdź lokalne certyfikaty ezdrowie.gov.pl (tylko odczyt)
  plan              porównaj ze źródłem i zaakceptuj podmiany/restarty
  run [--yes]       wykonaj zaakceptowany plan
  schedule [YYYY-MM-DD HH:MM]
                    zaplanuj JEDNORAZOWE wykonanie zaakceptowanego planu
  schedule-status   pokaż plan, timer i wynik ostatniego run
  schedule-cancel   anuluj oczekujące uruchomienie (plan i backupy zostają)
  help              pokaż tę pomoc
EOF
}

ez_main() {
  local command_name="${1:-help}"

  [ "$#" -gt 0 ] && shift
  case "$command_name" in
    help|-h|--help) ez_usage; return 0 ;;
  esac
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' 'BŁĄD: p1cert ezdrowie nie może działać jako root. Uruchom jako użytkownik P1CERT (np. itgo); uprawnienia root zapewnia dedykowany helper.' >&2
    return 1
  fi
  if [ "${EZ_LIB_API:-}" != "$EZ_HELPER_API" ]; then
    printf '%s\n' 'BŁĄD: biblioteka p1cert_ezdrowie_lib.sh ma niezgodną wersję API (niepełna aktualizacja); uruchom ponownie instalator P1CERT.' >&2
    return 1
  fi
  trap ez_cleanup EXIT
  trap 'ez_cleanup; exit 130' HUP INT TERM
  case "$command_name" in
    credentials) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_credentials ;;
    test) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_test ;;
    scan) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_scan ;;
    plan) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_with_lock ez_plan ;;
    run) ez_run "$@" ;;
    schedule) ez_schedule "$@" ;;
    schedule-status) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_schedule_status ;;
    schedule-cancel) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_schedule_cancel ;;
    *)
      printf 'Nieznane polecenie ezdrowie: %s\n\n' "$(ez_printable "$command_name")" >&2
      ez_usage >&2
      return 2
      ;;
  esac
}

if [ "${P1CERT_EZDROWIE_LIB_ONLY:-0}" != 1 ]; then
  ez_main "$@"
  exit $?
fi
