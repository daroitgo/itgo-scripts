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
# 4: systemd binding through SSL.patch of the classic Integration Platform
# (ez_systemd_bound rule C); helpers of API 1-3 are refused.
# 5: Docker Compose applications (apply-docker, recover, plan version 3,
# PKCS12 tool); helpers of API 1-4 are refused.
EZ_HELPER_API=5
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

# appConfig.properties of the IntegrationPlatform installation a unit runs
# from (ez_systemd_ip_root), printed only when it satisfies the same narrow
# policy the root helper enforces (ez_pi_appconfig_trusted with the unit's
# User=); nothing otherwise.
ez_detect_pi_appconfig() {
  local props="$1" root ids auid agid file

  root="$(ez_systemd_ip_root "$props")" || return 1
  file="$(fs_path "$root/$EZ_PI_APPCONFIG_REL")"
  [ -e "$file" ] || [ -L "$file" ] || return 1
  ids="$(ez_systemd_app_ids "$props" "$EZ_TRUSTED_UID" "$EZ_TRUSTED_GID")" || return 1
  read -r auid agid <<EOF
$ids
EOF
  ez_pi_appconfig_trusted "${P1CERT_FS_ROOT:-}" "$root" "$EZ_TRUSTED_UID" "$EZ_TRUSTED_GID" "$auid" "$agid" || {
    ez_log "appConfig.properties of $root is not controlled only by root and the unit user; not used for detection"
    return 1
  }
  ez_pi_appconfig_load "$file"
}

# Prints "systemd|<unit>|<reason>" for units that satisfy the same binding
# rule the root helper enforces before a restart (ez_systemd_bound): the unit
# configuration names the exact certificate path, the unit runs from the
# same IntegrationPlatform installation directory that contains the file, or
# SSL.patch in appConfig.properties of the installation the unit runs from
# names exactly the certificate.  Denied system units are never offered.
ez_detect_systemd() {
  local cert="$1" dir fsdir file unit seen=" " props config kind path reason appcfg

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
        -p WorkingDirectory -p ExecStart -p Environment -p EnvironmentFiles -p User -- "$unit" 2>/dev/null)" || continue
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
      appcfg="$(ez_detect_pi_appconfig "$props")" || appcfg=""
      reason="$(ez_systemd_bound "$cert" "$props" "$config" "$appcfg")" || continue
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
# Docker Compose discovery (read-only)
# ---------------------------------------------------------------------------

EZ_DC_SEP="$(printf '\034')"
# Upper bound for the files listed from one bind-mounted directory.
EZ_DC_DIR_SCAN_MAX=50
EZ_DC_DIR_ONLY='plik tylko w zamontowanym katalogu (brak odwołania w konfiguracji)'

ez_dc_unit_show() {
  systemctl show --no-pager -p LoadState -p ActiveState -p FragmentPath -p DropInPaths \
    -p WorkingDirectory -p ExecStart -p Environment -p EnvironmentFiles -- "$1" 2>/dev/null
}

# Note about a project (service "-") or a service: SERR (ambiguous), SWARN,
# UNMAPPED, PW (password variable name), PROFILES.
ez_dc_note() {
  DN_PROJ[$DN_COUNT]="$1"; DN_SVC[$DN_COUNT]="$2"; DN_KIND[$DN_COUNT]="$3"; DN_TEXT[$DN_COUNT]="$4"
  DN_COUNT=$((DN_COUNT + 1))
}

ez_dc_ref() {
  DR_PROJ[$DR_COUNT]="$1"; DR_SVC[$DR_COUNT]="$2"; DR_HOST[$DR_COUNT]="$3"; DR_CONT[$DR_COUNT]="$4"; DR_ORIGIN[$DR_COUNT]="$5"
  DR_COUNT=$((DR_COUNT + 1))
}

# Certificates and keystores inside a bind-mounted host directory that no
# variable names explicitly (OLD archives are not descended).
ez_dc_dir_refs() {
  local p="$1" svc="$2" host="$3" cont="$4" fs prefix file logical n=0

  ez_path_under_roots "$host" || return 0
  ez_dc_path_in_old_dir "$host/x" && return 0
  ez_path_no_symlinks "${P1CERT_FS_ROOT:-}" "$host" || return 0
  fs="$(fs_path "$host")"
  # A mounted file without a certificate extension counts only when its
  # content is a certificate or keystore (configuration files are ignored).
  if [ -f "$fs" ] && [ ! -L "$fs" ]; then
    [ -r "$fs" ] && [ "$(ez_store_type "$fs")" != UNKNOWN ] || return 0
    ez_dc_ref "$p" "$svc" "$host" "$cont" mount
    return 0
  fi
  [ -d "$fs" ] && [ ! -L "$fs" ] || return 0
  prefix="${P1CERT_FS_ROOT:-}"
  prefix="${prefix%/}"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$EZ_DC_DIR_SCAN_MAX" ]; then
      ez_dc_note "$p" "$svc" SWARN "katalog $host zawiera więcej niż $EZ_DC_DIR_SCAN_MAX plików certyfikatów - pominięto resztę"
      break
    fi
    logical="${file#"$prefix"}"
    ez_dc_ref "$p" "$svc" "$logical" "$cont${logical#"$host"}" dir
  done <<EOF
$(find -P "$fs" -mindepth 1 -maxdepth 3 \( -type d \( -iname '*old*' -o -name .git -o -name node_modules \) -prune \) -o \
    -type f \( -iname '*.pem' -o -iname '*.crt' -o -iname '*.cer' -o -iname '*.der' -o -iname '*.jks' \
    -o -iname '*.p12' -o -iname '*.pfx' \) -print 2>/dev/null | LC_ALL=C sort)
EOF
}

# Appends one compose project (DCI_* and DCP_* already set) to DP_* and its
# references and notes to DR_* / DN_*.
ez_dc_add_project() {
  local unit="$1" active="$2" input="$3" p="$DP_COUNT" prefix t a b c d

  prefix="${P1CERT_FS_ROOT:-}"
  prefix="${prefix%/}"
  DP_UNIT[$p]="$unit"; DP_ACTIVE[$p]="$active"; DP_VERSION[$p]="$DCI_VERSION"; DP_PROG[$p]="$DCI_PROG"
  DP_SUB[$p]="$DCI_SUB"; DP_PROJDIR[$p]="$DCP_PROJDIR"; DP_FILES[$p]="$DCP_FILES"; DP_ENVFILE[$p]=""
  DP_ERR[$p]="$DCP_ERR"; DP_PROFILES[$p]="$DCP_PROFILES"; DP_SERVICES[$p]=""
  # What ez_dc_secret needs to read one value again later (in memory only).
  DP_INPUT[$p]="$input"; DP_ENVCFG[$p]="$DCP_ENVFILE"; DP_ENVEXPL[$p]=0
  [ -z "${DCI_ENVFILE:-}" ] || DP_ENVEXPL[$p]=1
  DP_COUNT=$((DP_COUNT + 1))
  if [ "$DCP_PROJDIR" != - ] && ez_dc_path_in_old_dir "$DCP_PROJDIR/x"; then
    ez_dc_note "$p" - SWARN 'katalog projektu zawiera "OLD" w nazwie - jego pliki są pomijane'
  fi
  [ -n "$DCP_FILES" ] || return 0
  while IFS="$EZ_DC_SEP" read -r t a b c d; do
    case "$t" in
      DOTENV) [ "$b" != used ] || DP_ENVFILE[$p]="$a" ;;
      ERR) DP_ERR[$p]="${DP_ERR[$p]:-$b}" ;;
      SVC)
        ez_compose_service_ok "$a" || { DP_ERR[$p]="${DP_ERR[$p]:-nieobsługiwana nazwa usługi Compose}"; continue; }
        DP_SERVICES[$p]="${DP_SERVICES[$p]:+${DP_SERVICES[$p]} }$a"
        [ "$b" != profiles ] || ez_dc_note "$p" "$a" PROFILES 'usługa przypisana do profilu Compose'
        ;;
      SERR)
        # One service that cannot be analysed makes the whole project
        # uncertain: its unknown mounts may hide the same certificate.
        ez_dc_note "$p" "$a" SERR "$b"
        DP_ERR[$p]="${DP_ERR[$p]:-usługa $a: $b}"
        ;;
      SWARN) ez_dc_note "$p" "$a" SWARN "$b" ;;
      ENVFILE) [ "$c" = used ] || ez_dc_note "$p" "$a" SWARN "brak opcjonalnego env_file $b" ;;
      REF)
        # A variable naming a mounted directory: covered by the DIR scan.
        case "$d" in
          env:*) [ ! -d "$(fs_path "$b")" ] || continue ;;
        esac
        ez_dc_ref "$p" "$a" "$b" "$c" "$d"
        ;;
      DIR) ez_dc_dir_refs "$p" "$a" "$b" "$c" ;;
      UNMAPPED)
        case "$d" in
          relative) ez_dc_note "$p" "$a" UNMAPPED "$b=$c - ścieżka względna, nieznany katalog roboczy kontenera" ;;
          *) ez_dc_note "$p" "$a" UNMAPPED "$b=$c - plik wewnątrz obrazu (brak wolumenu z hosta)" ;;
        esac
        ;;
      PW)
        ez_dc_note "$p" "$a" PW "$b ($c)"
        DW_PROJ[$DW_COUNT]="$p"; DW_SVC[$DW_COUNT]="$a"; DW_NAME[$DW_COUNT]="$b"; DW_FILE[$DW_COUNT]="$d"; DW_SRC[$DW_COUNT]="$c"
        DW_UNAME[$DW_COUNT]="$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')"
        DW_COUNT=$((DW_COUNT + 1))
        ;;
    esac
  done <<EOF
$(ez_dc_model "$prefix" "$input" 2>/dev/null)
EOF
}

# Fills DP_* (compose projects: units running compose, then projects found
# below the allowed roots that no unit runs), DR_* (certificate/keystore
# references) and DN_* (notes).
ez_dc_collect() {
  local dir fsdir file unit seen=" " props active input prefix root i j

  DP_COUNT=0; DP_UNIT=(); DP_ACTIVE=(); DP_VERSION=(); DP_PROG=(); DP_SUB=(); DP_PROJDIR=(); DP_FILES=()
  DP_ENVFILE=(); DP_ERR=(); DP_PROFILES=(); DP_SERVICES=(); DP_INPUT=(); DP_ENVCFG=(); DP_ENVEXPL=()
  DW_COUNT=0; DW_PROJ=(); DW_SVC=(); DW_NAME=(); DW_UNAME=(); DW_FILE=(); DW_SRC=()
  DR_COUNT=0; DR_PROJ=(); DR_SVC=(); DR_HOST=(); DR_CONT=(); DR_ORIGIN=()
  DN_COUNT=0; DN_PROJ=(); DN_SVC=(); DN_KIND=(); DN_TEXT=()
  prefix="${P1CERT_FS_ROOT:-}"
  prefix="${prefix%/}"

  if command -v systemctl >/dev/null 2>&1; then
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
        props="$(ez_dc_unit_show "$unit")" || continue
        printf '%s\n' "$props" | grep -F -x -q 'LoadState=loaded' || continue
        ez_dc_invocation "$props" || continue
        active="$(printf '%s\n' "$props" | sed -n 's/^ActiveState=//p' | head -n 1)"
        if [ "$DCI_VERSION" = '?' ]; then
          # Not analysable: no project directory or file is guessed.
          DCP_FILES=''; DCP_PROJDIR='-'; DCP_PROFILES=''; DCP_ERR="$DCI_ERR"
          ez_dc_add_project "$unit" "${active:-unknown}" ""
          continue
        fi
        input="$(ez_dc_unit_env_input "$props" "$DCI_ASSIGN")"
        ez_dc_project "$prefix" "$input"
        ez_dc_add_project "$unit" "${active:-unknown}" "$input"
      done
    done
  fi

  # One project run by several units: the restart target is ambiguous.
  i=0
  while [ "$i" -lt "$DP_COUNT" ]; do
    j=0
    while [ "$j" -lt "$DP_COUNT" ]; do
      if [ "$i" -ne "$j" ] && [ "${DP_PROJDIR[$i]}" != - ] && [ "${DP_PROJDIR[$i]}" = "${DP_PROJDIR[$j]}" ]; then
        DP_ERR[$i]="${DP_ERR[$i]:-projekt uruchamia kilka jednostek systemd (${DP_UNIT[$j]})}"
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  for root in $EZ_ALLOWED_ROOTS; do
    [ -d "$(fs_path "$root")" ] || continue
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      dir="${file#"$prefix"}"
      dir="${dir%/*}"
      ez_dc_path_ok "$dir" || continue
      i=0
      while [ "$i" -lt "$DP_COUNT" ]; do
        [ "${DP_PROJDIR[$i]}" != "$dir" ] || break
        i=$((i + 1))
      done
      [ "$i" -eq "$DP_COUNT" ] || continue
      DCI_VERSION='-'; DCI_PROG=''; DCI_CWD="$dir"; DCI_FILES=''; DCI_PROJDIR=''; DCI_ENVFILE=''
      DCI_NAME=''; DCI_PROFILES=''; DCI_SUB=''; DCI_ASSIGN=''; DCI_ERR=''
      ez_dc_project "$prefix" ""
      ez_dc_add_project - - ""
    done <<EOF
$(find -P "$(fs_path "$root")" -mindepth 1 -maxdepth 4 \( -type d \( -iname '*old*' -o -name .git -o -name node_modules \) -prune \) -o \
    -type f \( -name compose.yaml -o -name compose.yml -o -name docker-compose.yaml -o -name docker-compose.yml \) \
    -print 2>/dev/null | LC_ALL=C sort)
EOF
  done
}

# Classifies one referenced host file by its content (EZD_*):
#   EZD_STATE  CERT (X.509 PEM/DER), STORE (JKS/PKCS12), MISSING or SKIP,
#   EZD_TYPE   ez_store_type, EZD_REASON, and for CERT the leaf data and
#   EZD_EZ (yes: an ezdrowie.gov.pl identity, e.g. *.ezdrowie.gov.pl).
ez_dc_inspect() {
  local path="$1" fs size rc identity

  EZD_STATE=SKIP; EZD_REASON=""; EZD_TYPE=""; EZD_FP=""; EZD_SUBJECT=""; EZD_NOT_AFTER=""
  EZD_NAMES=""; EZD_EZ=no; EZD_COUNT=0
  if ! ez_dc_path_ok "$path"; then
    EZD_REASON='ścieżka zawiera nieobsługiwane znaki'
    return 0
  fi
  if ez_dc_path_in_old_dir "$path"; then
    EZD_REASON='katalog z "OLD" w nazwie (archiwum) - wyłączony z obsługi'
    return 0
  fi
  if ! ez_path_under_roots "$path"; then
    EZD_REASON='poza katalogami /srv, /usr/local, /opt'
    return 0
  fi
  fs="$(fs_path "$path")"
  if [ ! -e "$fs" ] && [ ! -L "$fs" ]; then
    EZD_STATE=MISSING
    EZD_REASON='plik nie istnieje na hoście'
    return 0
  fi
  if ! ez_path_no_symlinks "${P1CERT_FS_ROOT:-}" "$path"; then
    EZD_REASON='ścieżka zawiera symlink'
    return 0
  fi
  [ -f "$fs" ] || { EZD_REASON='nie jest zwykłym plikiem'; return 0; }
  [ -r "$fs" ] || { EZD_REASON='brak uprawnień odczytu dla użytkownika P1CERT'; return 0; }
  size="$(ez_file_size "$fs")"
  if [ -z "$size" ] || [ "$size" -gt "$EZ_DC_MAX_STORE_BYTES" ]; then
    EZD_REASON='plik jest zbyt duży'
    return 0
  fi
  EZD_TYPE="$(ez_store_type "$fs")"
  case "$EZD_TYPE" in
    PEM|DER)
      rc=0
      ez_cert_inspect "$fs" || rc=$?
      case "$rc" in
        0)
          EZD_STATE=CERT; EZD_FP="$EZC_FP"; EZD_SUBJECT="$EZC_SUBJECT"; EZD_NOT_AFTER="$EZC_NOT_AFTER"
          EZD_NAMES="$EZC_NAMES"; EZD_COUNT="$EZC_COUNT"
          if identity="$(ez_primary_identity "$EZC_CN" "$EZC_NAMES")"; then
            EZD_EZ=yes
            ! ez_is_nonprod_name "$identity" || EZD_REASON="tożsamość nieprodukcyjna ($identity)"
          fi
          ;;
        3) EZD_REASON='zawiera klucz prywatny (materiał klienta TLS/WSS) - nie jest celem podmiany' ;;
        4) EZD_REASON='plik certyfikatu jest zbyt duży' ;;
        *) EZD_REASON="nie jest pojedynczym certyfikatem ani poprawnym łańcuchem PEM${EZC_REASON:+ ($EZC_REASON)}" ;;
      esac
      ;;
    JKS|PKCS12) EZD_STATE=STORE ;;
    JCEKS) EZD_REASON='magazyn JCEKS - nieobsługiwany (tylko JKS i PKCS12)' ;;
    *) EZD_REASON='nierozpoznany format pliku' ;;
  esac
  return 0
}

# DT_SURE[$1] yes|no and DT_WHY[$1]: a file is a certain result only when
# exactly one systemd unit runs the project(s) naming it, every such project
# is unambiguous and at least one service names it explicitly (mount or
# variable; a file merely present in a mounted directory is not enough).
# A project that only mounts the directory holding a named file does not
# use it as far as the configuration shows: it does not count.
ez_dc_certainty() {
  local t="$1" r p why="" explicit=no units=" " n=0

  for r in ${DT_REFS[$t]}; do
    [ "${DR_ORIGIN[$r]}" = dir ] || explicit=yes
  done
  for r in ${DT_REFS[$t]}; do
    [ "$explicit" = no ] || [ "${DR_ORIGIN[$r]}" != dir ] || continue
    p="${DR_PROJ[$r]}"
    if [ -n "${DP_ERR[$p]}" ]; then
      case "$why" in
        *"[$((p + 1))]"*) ;;
        *) why="${why:+$why, }niejednoznaczna konfiguracja projektu [$((p + 1))]" ;;
      esac
    fi
    if [ "${DP_UNIT[$p]}" = - ]; then
      case "$why" in *'brak jednostki'*) ;; *) why="${why:+$why, }brak jednostki systemd" ;; esac
    elif ! ez_names_contain "$units" "${DP_UNIT[$p]}"; then
      units="$units${DP_UNIT[$p]} "
      n=$((n + 1))
    fi
  done
  [ "$explicit" = yes ] || why="${why:+$why, }$EZ_DC_DIR_ONLY"
  [ "$n" -le 1 ] || why="${why:+$why, }plik używany przez kilka jednostek:${units% }"
  DT_WHY[$t]="$why"
  if [ -z "$why" ]; then DT_SURE[$t]=yes; else DT_SURE[$t]=no; fi
}

# Groups DR_* by host path into DT_* and inspects every file once.
ez_dc_targets() {
  local r t

  DT_COUNT=0; DT_PATH=(); DT_REFS=(); DT_STATE=(); DT_TYPE=(); DT_REASON=(); DT_FP=(); DT_SUBJECT=()
  DT_NOT_AFTER=(); DT_NAMES=(); DT_EZ=(); DT_NCERT=(); DT_SURE=(); DT_WHY=()
  DT_SSTATUS=(); DT_SREASON=(); DT_SP1=(); DT_SP1WHY=(); DT_P1FP=(); DT_PWDESC=(); DT_SBLOCK=()
  DT_P1ALIAS=(); DT_P1NAMES=(); DT_P1NA=(); DT_SHA=()
  r=0
  while [ "$r" -lt "$DR_COUNT" ]; do
    t=0
    while [ "$t" -lt "$DT_COUNT" ]; do
      [ "${DT_PATH[$t]}" != "${DR_HOST[$r]}" ] || break
      t=$((t + 1))
    done
    if [ "$t" -eq "$DT_COUNT" ]; then
      DT_PATH[$t]="${DR_HOST[$r]}"; DT_REFS[$t]=""
      DT_COUNT=$((DT_COUNT + 1))
    fi
    DT_REFS[$t]="${DT_REFS[$t]} $r"
    r=$((r + 1))
  done
  t=0
  while [ "$t" -lt "$DT_COUNT" ]; do
    ez_dc_certainty "$t"
    ez_dc_inspect "${DT_PATH[$t]}"
    DT_STATE[$t]="$EZD_STATE"; DT_TYPE[$t]="$EZD_TYPE"; DT_REASON[$t]="$EZD_REASON"; DT_FP[$t]="$EZD_FP"
    DT_SUBJECT[$t]="$EZD_SUBJECT"; DT_NOT_AFTER[$t]="$EZD_NOT_AFTER"; DT_NAMES[$t]="$EZD_NAMES"
    DT_EZ[$t]="$EZD_EZ"; DT_NCERT[$t]="$EZD_COUNT"
    DT_SSTATUS[$t]=""; DT_SREASON[$t]=""; DT_SP1[$t]=""; DT_SP1WHY[$t]=""; DT_PWDESC[$t]=""; DT_SBLOCK[$t]=""
    DT_P1FP[$t]=""; DT_P1ALIAS[$t]=""; DT_P1NAMES[$t]=""; DT_P1NA[$t]=""; DT_SHA[$t]=""
    case "$EZD_STATE" in
      CERT|STORE) DT_SHA[$t]="$(ez_file_digest "$(fs_path "${DT_PATH[$t]}")")" ;;
    esac
    if [ "$EZD_STATE" = CERT ] && [ "$EZD_EZ" = yes ] && [ -z "$EZD_REASON" ]; then
      DT_P1FP[$t]="$EZD_FP"
    fi
    [ "$EZD_STATE" != STORE ] || ez_dc_store "$t"
    ez_log "docker target ${DT_PATH[$t]} state=$EZD_STATE type=$EZD_TYPE ezdrowie=$EZD_EZ certain=${DT_SURE[$t]}${EZD_FP:+ fp=$EZD_FP}${DT_SSTATUS[$t]:+ store=${DT_SSTATUS[$t]} p1=${DT_SP1[$t]}}${DT_P1FP[$t]:+ p1fp=${DT_P1FP[$t]}}"
    t=$((t + 1))
  done
}

# True when service $3 of project $1 names target $2 through a mount or a
# variable (not only through a directory listing).
ez_dc_named() {
  local r
  for r in ${DT_REFS[$2]}; do
    [ "${DR_PROJ[$r]}" = "$1" ] && [ "${DR_SVC[$r]}" = "$3" ] && [ "${DR_ORIGIN[$r]}" != dir ] && return 0
  done
  return 1
}

# Password variables of the service behind reference $1 that the
# configuration binds to the referenced store (PB_CANDS: DW_* indices,
# PB_RULE: the rule; the rules ez_dc_pw_stem, ez_dc_pw_base and
# ez_dc_pw_named are shared with the root helper).  Never by order or by
# being the only password:
#   1. the store is named by variable K: K without _FILE/_PATH/_LOCATION/
#      _LOC/_NAME, followed by the password word (P1_KEYSTORE_PATH ->
#      P1_KEYSTORE_PASSWORD, JAVAX_NET_SSL_TRUSTSTORE ->
#      JAVAX_NET_SSL_TRUSTSTOREPASSWORD),
#   2. otherwise the file name without extension, on the host or in the
#      container (truststore.p12 -> TRUSTSTORE_PASSWORD or
#      <PREFIX>_TRUSTSTORE_PASSWORD).
# A password variable also matches by the variable it is set from
# (ez_dc_pw_match: KS_PASS: ${P1_KEYSTORE_PASSWORD}).
ez_dc_pw_bind() {
  local r="$1" p="${DR_PROJ[$1]}" svc="${DR_SVC[$1]}" origin="${DR_ORIGIN[$1]}" stem base cbase w

  PB_CANDS=""; PB_RULE=""
  case "$origin" in
    env:*)
      stem="$(ez_dc_pw_stem "$origin")"
      w=0
      while [ "$w" -lt "$DW_COUNT" ]; do
        if [ "${DW_PROJ[$w]}" = "$p" ] && [ "${DW_SVC[$w]}" = "$svc" ] && ez_dc_pw_match "${DW_UNAME[$w]}" "${DW_SRC[$w]}" "$stem"; then
          PB_CANDS="$PB_CANDS $w"
        fi
        w=$((w + 1))
      done
      PB_RULE="nazwa zmiennej ścieżki ${origin#env:}"
      ;;
  esac
  [ -z "$PB_CANDS" ] || return 0
  base="$(ez_dc_pw_base "${DR_HOST[$r]}")"
  cbase="$(ez_dc_pw_base "${DR_CONT[$r]}")"
  w=0
  while [ "$w" -lt "$DW_COUNT" ]; do
    if [ "${DW_PROJ[$w]}" = "$p" ] && [ "${DW_SVC[$w]}" = "$svc" ] &&
      { ez_dc_pw_match "${DW_UNAME[$w]}" "${DW_SRC[$w]}" "$base" suffix ||
        ez_dc_pw_match "${DW_UNAME[$w]}" "${DW_SRC[$w]}" "$cbase" suffix; }; then
      PB_CANDS="$PB_CANDS $w"
    fi
    w=$((w + 1))
  done
  PB_RULE="nazwa pliku ${DR_HOST[$r]##*/}"
  [ "$cbase" = "$base" ] || PB_RULE="$PB_RULE / ${DR_CONT[$r]##*/} w kontenerze"
}

# Prints the value of password variable DW $1: through ez_dc_secret, or the
# first line of the host file a NAME_FILE variable points to.  Status 2 when
# it cannot be read.  The value only goes to stdout (captured by $(...)).
ez_dc_pw_value() {
  local w="$1" p="${DW_PROJ[$1]}" prefix path fs size line=""

  case "${DW_FILE[$w]}" in
    '')
      prefix="${P1CERT_FS_ROOT:-}"
      prefix="${prefix%/}"
      ez_dc_secret "$prefix" "${DP_INPUT[$p]}" "${DP_ENVCFG[$p]}" "${DP_ENVEXPL[$p]}" "${DP_FILES[$p]}" \
        "${DP_PROJDIR[$p]}" "${DW_SVC[$w]}" "${DW_NAME[$w]}" || return 2
      ;;
    file:) return 2 ;;
    file:*)
      path="${DW_FILE[$w]#file:}"
      ez_dc_path_ok "$path" && ! ez_dc_path_in_old_dir "$path" || return 2
      ez_path_no_symlinks "${P1CERT_FS_ROOT:-}" "$path" || return 2
      fs="$(fs_path "$path")"
      [ -f "$fs" ] && [ -r "$fs" ] || return 2
      size="$(ez_file_size "$fs")"
      [ -n "$size" ] && [ "$size" -le 4096 ] || return 2
      IFS= read -r line < "$fs" || [ -n "$line" ] || return 2
      printf '%s' "${line%"$(printf '\r')"}"
      ;;
    *) return 2 ;;
  esac
}

# Short description of password variable DW $1 (name and origin, no value).
ez_dc_pw_label() {
  case "${DW_FILE[$1]}" in
    file:?*) printf 'plik %s ze zmiennej %s usługi %s' "${DW_FILE[$1]#file:}" "${DW_NAME[$1]}" "${DW_SVC[$1]}" ;;
    *) printf 'zmienna %s usługi %s' "${DW_NAME[$1]}" "${DW_SVC[$1]}" ;;
  esac
}

# Opens keystore target $1 read-only: binds its password from the
# configuration, verifies password and integrity, lists the entries and
# identifies the P1 certificate.  Sets DT_SSTATUS, DT_SREASON, DT_SP1,
# DT_SP1WHY, DT_P1FP, DT_PWDESC and DT_SBLOCK (report lines).  The password
# lives only in local/EZS_PASSWORD variables and is cleared here.
# Password of keystore target $1, bound by the configuration (see
# ez_dc_pw_bind): EZS_PASSWORD (caller clears it), DSP_HAVE yes|no and, without
# a usable password, DSP_STATUS/DSP_REASON.  Sets DT_PWDESC (names only).
ez_dc_store_pw() {
  local t="$1" r w bound="" nb=0 amb="" names value status="" reason="" have=no n explicit=no

  DT_PWDESC[$t]=""
  for r in ${DT_REFS[$t]}; do
    [ "${DR_ORIGIN[$r]}" = dir ] || explicit=yes
  done
  for r in ${DT_REFS[$t]}; do
    # A directory listing adds nothing when a service names the file (the
    # root helper binds through named references only).
    [ "${DR_ORIGIN[$r]}" != dir ] || [ "$explicit" = no ] || continue
    ez_dc_pw_bind "$r"
    set -- $PB_CANDS
    if [ "$#" -eq 1 ]; then
      if ! ez_names_contain "$bound" "$1"; then
        bound="$bound $1"
        nb=$((nb + 1))
        DT_PWDESC[$t]="${DT_PWDESC[$t]:+${DT_PWDESC[$t]}; }$(ez_dc_pw_label "$1") (powiązanie: $PB_RULE)"
      fi
    elif [ "$#" -gt 1 ]; then
      names=""
      for w in "$@"; do
        names="${names:+$names, }${DW_NAME[$w]}"
      done
      amb="${amb:+$amb; }usługa ${DR_SVC[$r]}: $names"
    fi
  done
  if [ -n "$amb" ]; then
    status=HASLO_NIEJEDNOZNACZNE
    reason="kilka zmiennych hasła pasuje do magazynu ($amb)"
  elif [ "$nb" -eq 0 ]; then
    status=BRAK_HASLA
    reason='brak zmiennej hasła powiązanej z magazynem (nazwą zmiennej ścieżki lub nazwą pliku)'
  else
    EZS_PASSWORD=""
    have=yes
    n=0
    for w in $bound; do
      value=""
      if ! value="$(ez_dc_pw_value "$w")"; then
        status=HASLO_NIEJEDNOZNACZNE
        reason="nie można odczytać wartości: $(ez_dc_pw_label "$w")"
        have=no
        break
      fi
      if [ "$n" -eq 0 ]; then
        EZS_PASSWORD="$value"
      elif [ "$value" != "$EZS_PASSWORD" ]; then
        status=HASLO_NIEJEDNOZNACZNE
        reason='zmienne hasła powiązane z magazynem mają różne wartości'
        have=no
        break
      fi
      n=$((n + 1))
    done
    value=""
    [ "$have" = yes ] || EZS_PASSWORD=""
  fi
  DSP_HAVE="$have"; DSP_STATUS="$status"; DSP_REASON="$reason"
}

ez_dc_store() {
  local t="$1" status reason have i n line block="" others=0 k fs

  ez_dc_store_pw "$t"
  have="$DSP_HAVE"; status="$DSP_STATUS"; reason="$DSP_REASON"

  fs="$(fs_path "${DT_PATH[$t]}")"
  ez_store_open "$fs" "${DT_TYPE[$t]}" "$have" || true
  EZS_PASSWORD=""
  if [ "$have" != yes ] && [ "$EZS_STATUS" = BRAK_HASLA ] && [ -n "$status" ]; then
    EZS_STATUS="$status"
    case "${DT_TYPE[$t]}" in
      JKS) EZS_REASON="$reason - wpisy odczytane ze struktury, integralność niezweryfikowana" ;;
      *) EZS_REASON="$reason" ;;
    esac
  fi
  ez_store_p1
  DT_SSTATUS[$t]="$EZS_STATUS"; DT_SREASON[$t]="$EZS_REASON"; DT_SP1[$t]="$EZS_P1"; DT_SP1WHY[$t]="$EZS_P1_WHY"
  DT_P1FP[$t]=""; DT_P1ALIAS[$t]=""; DT_P1NAMES[$t]=""; DT_P1NA[$t]=""
  if [ -n "$EZS_P1_ROW" ]; then
    DT_P1FP[$t]="${ES_FP[$EZS_P1_ROW]}"; DT_P1ALIAS[$t]="${ES_ALIAS[$EZS_P1_ROW]}"
    DT_P1NAMES[$t]="${ES_NAMES[$EZS_P1_ROW]}"; DT_P1NA[$t]="${ES_NOT_AFTER[$EZS_P1_ROW]}"
  fi

  # Report lines (built now: ES_* belong to the last opened store).
  if [ "$EZS_ENTRIES" -gt 0 ] || [ -n "$EZS_FORMAT" ]; then
    line="${EZS_FORMAT:-${DT_TYPE[$t]}}, wpisy: $EZS_ENTRIES (z kluczem prywatnym: $EZS_KEYS)"
  else
    line="${DT_TYPE[$t]}"
  fi
  block="          Format:     $line
          Hasło:      ${DT_PWDESC[$t]:-nie powiązano}${DT_PWDESC[$t]:+ - wartość nie jest wyświetlana}
"
  if [ "$EZS_STATUS" = OK ]; then
    block="$block          Magazyn:    OK - hasło poprawne, integralność potwierdzona
"
  else
    block="$block          Magazyn:    $EZS_STATUS - $EZS_REASON
"
  fi
  [ -z "$EZS_NOTE" ] || block="$block          Uwaga:      $EZS_NOTE
"
  if [ "$ES_COUNT" -gt 0 ]; then
    block="$block          Wpisy:
"
    i=0
    while [ "$i" -lt "$ES_COUNT" ]; do
      if [ "${ES_KIND[$i]}" = PrivateKeyEntry ] && [ "${ES_POS[$i]}" = 1 ]; then
        n=0
        k=0
        while [ "$k" -lt "$ES_COUNT" ]; do
          [ "${ES_KIND[$k]}" != PrivateKeyEntry ] || [ "${ES_ENTRY[$k]}" != "${ES_ENTRY[$i]}" ] || n=$((n + 1))
          k=$((k + 1))
        done
        block="$block            PrivateKeyEntry \"${ES_ALIAS[$i]}\" (łańcuch: $n): ${ES_SUBJECT[$i]:-nieczytelny certyfikat} - klucz prywatny, wpis nie będzie modyfikowany
"
      elif [ -n "${ES_ID[$i]}" ] || [ "${ES_OK[$i]}" != yes ]; then
        block="$block            ${ES_KIND[$i]} \"${ES_ALIAS[$i]}\": "
        if [ "${ES_OK[$i]}" != yes ]; then
          block="${block}nieczytelny certyfikat
"
        else
          block="$block${ES_NAMES[$i]}, ważny do ${ES_NOT_AFTER[$i]}, SHA-256 ${ES_FP[$i]}"
          [ "${ES_NONPROD[$i]}" = no ] || block="$block (nieprodukcyjny)"
          [ "${ES_CA[$i]}" = no ] || block="$block (CA)"
          [ "${ES_POS[$i]}" = 1 ] || block="$block (pozycja ${ES_POS[$i]} w łańcuchu klucza)"
          block="$block
"
        fi
      elif [ "${ES_KIND[$i]}" != PrivateKeyEntry ]; then
        others=$((others + 1))
      fi
      i=$((i + 1))
    done
    [ "$others" -eq 0 ] || block="$block            pozostałe certyfikaty niezwiązane z ezdrowie.gov.pl: $others
"
  fi
  case "$EZS_P1" in
    PEWNA)
      block="$block          P1:         PEWNA - alias \"${ES_ALIAS[$EZS_P1_ROW]}\", SHA-256 ${ES_FP[$EZS_P1_ROW]}, ważny do ${ES_NOT_AFTER[$EZS_P1_ROW]}${EZS_P1_WHY:+ ($EZS_P1_WHY)}
"
      ;;
    *) block="$block          P1:         $EZS_P1${EZS_P1_WHY:+ - $EZS_P1_WHY}
" ;;
  esac
  DT_SBLOCK[$t]="$block"

  # Certainty of the target: configuration (E1) and the store itself.
  if [ "$EZS_STATUS" = OK ] && { [ "$EZS_P1" = BRAK ] || [ "$EZS_P1" = CHRONIONY ]; }; then
    DT_SURE[$t]=na
    DT_WHY[$t]='magazyn nie zawiera certyfikatu P1 do podmiany'
  else
    [ "$EZS_STATUS" = OK ] || DT_WHY[$t]="${DT_WHY[$t]:+${DT_WHY[$t]}, }magazyn: $EZS_STATUS"
    [ "$EZS_P1" = PEWNA ] || DT_WHY[$t]="${DT_WHY[$t]:+${DT_WHY[$t]}, }identyfikacja P1: $EZS_P1"
    [ -z "${DT_WHY[$t]}" ] || DT_SURE[$t]=no
  fi
  ez_store_reset
}

ez_dc_print_target() {
  local p="$1" t="$2" r label="" others="" line

  printf '      - %s\n' "$(ez_printable "${DT_PATH[$t]}")"
  for r in ${DT_REFS[$t]}; do
    if [ "${DR_PROJ[$r]}" != "$p" ]; then
      ez_names_contain "$others" "$((DR_PROJ[$r] + 1))" || others="${others:+$others }$((DR_PROJ[$r] + 1))"
      continue
    fi
    # The directory listing only matters when nothing names the file.
    [ "${DR_ORIGIN[$r]}" != dir ] || ! ez_dc_named "$p" "$t" "${DR_SVC[$r]}" || continue
    case "${DR_ORIGIN[$r]}" in
      mount) label='wolumen' ;;
      dir) label='plik w zamontowanym katalogu (bez odwołania w konfiguracji)' ;;
      env:*) label="zmienna ${DR_ORIGIN[$r]#env:}" ;;
      *) label="${DR_ORIGIN[$r]}" ;;
    esac
    printf '          Odwołanie:  usługa %s, %s -> %s\n' "${DR_SVC[$r]}" "$(ez_printable "$label")" "$(ez_printable "${DR_CONT[$r]}")"
  done
  [ -z "$others" ] || printf '          Uwaga:      plik używany także przez projekt(y) [%s]\n' "$others"
  case "${DT_STATE[$t]}" in
    CERT|STORE)
      if [ "${DT_SURE[$t]}" = yes ]; then
        printf '          Wynik:      PEWNY\n'
      elif [ "${DT_SURE[$t]}" = na ]; then
        printf '          Wynik:      NIE DOTYCZY - %s\n' "$(ez_printable "${DT_WHY[$t]}")"
      else
        printf '          Wynik:      NIEPEWNY - %s\n' "$(ez_printable "${DT_WHY[$t]}")"
      fi
      ;;
  esac
  case "${DT_STATE[$t]}" in
    CERT)
      if [ "${DT_NCERT[$t]}" -gt 1 ]; then
        printf '          Format:     %s, łańcuch %s certyfikatów (dane certyfikatu końcowego)\n' "${DT_TYPE[$t]}" "${DT_NCERT[$t]}"
      else
        printf '          Format:     %s (X.509)\n' "${DT_TYPE[$t]}"
      fi
      printf '          SHA-256:    %s\n' "${DT_FP[$t]}"
      printf '          Subject:    %s\n' "$(ez_printable "${DT_SUBJECT[$t]}")"
      printf '          Not After:  %s\n' "${DT_NOT_AFTER[$t]}"
      if [ "${DT_EZ[$t]}" = yes ]; then
        printf '          ezdrowie:   TAK (%s)%s\n' "$(ez_printable "${DT_NAMES[$t]}")" "${DT_REASON[$t]:+ - ${DT_REASON[$t]}}"
      else
        printf '          ezdrowie:   NIE (%s)\n' "$(ez_printable "${DT_NAMES[$t]:-brak nazw DNS}")"
      fi
      ;;
    STORE)
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$(ez_printable "$line")"
      done <<EOF
${DT_SBLOCK[$t]}
EOF
      ;;
    MISSING) printf '          Status:     BRAK PLIKU (%s)\n' "${DT_REASON[$t]}" ;;
    *) printf '          Status:     POMINIĘTO (%s)\n' "$(ez_printable "${DT_REASON[$t]}")" ;;
  esac
}

ez_dc_print() {
  local p=0 t r k shown n

  printf 'Aplikacje Docker Compose i ich certyfikaty (tylko odczyt):\n'
  if [ "$DP_COUNT" -eq 0 ]; then
    printf '  nie znaleziono\n'
    return 0
  fi
  while [ "$p" -lt "$DP_COUNT" ]; do
    printf '\n[%s] ' "$((p + 1))"
    if [ "${DP_UNIT[$p]}" = - ]; then
      printf 'projekt bez jednostki systemd: %s\n' "$(ez_printable "${DP_PROJDIR[$p]}")"
      printf '    Jednostka:  BRAK - P1CERT nie zrestartuje tej aplikacji\n'
    else
      printf 'jednostka systemd: %s (stan: %s)\n' "${DP_UNIT[$p]}" "$(ez_printable "${DP_ACTIVE[$p]}")"
      case "${DP_VERSION[$p]}" in
        v1) printf '    Compose:    v1 (docker-compose) %s\n' "$(ez_printable "${DP_SUB[$p]}")" ;;
        v2) printf '    Compose:    v2 (docker compose) %s\n' "$(ez_printable "${DP_SUB[$p]}")" ;;
        *) printf '    Compose:    nierozpoznane wywołanie\n' ;;
      esac
    fi
    if [ "${DP_PROJDIR[$p]}" != - ]; then
      printf '    Katalog:    %s\n' "$(ez_printable "${DP_PROJDIR[$p]}")"
      if [ -n "${DP_FILES[$p]}" ]; then
        printf '    Pliki:      %s\n' "$(ez_printable "$(printf '%s' "${DP_FILES[$p]}" | tr '\n' ' ')")"
      fi
      printf '    Zmienne:    %s\n' "$(ez_printable "${DP_ENVFILE[$p]:-brak pliku .env}")"
    fi
    [ -z "${DP_PROFILES[$p]}" ] || printf '    Profile:    %s\n' "$(ez_printable "${DP_PROFILES[$p]}")"
    [ -z "${DP_SERVICES[$p]}" ] || printf '    Usługi:     %s\n' "$(ez_printable "${DP_SERVICES[$p]}")"
    if [ -n "${DP_ERR[$p]}" ]; then
      printf '    Status:     NIEJEDNOZNACZNA KONFIGURACJA - %s (podmiana będzie odrzucona)\n' "$(ez_printable "${DP_ERR[$p]}")"
    else
      printf '    Status:     OK\n'
    fi
    k=0
    while [ "$k" -lt "$DN_COUNT" ]; do
      if [ "${DN_PROJ[$k]}" = "$p" ]; then
        case "${DN_KIND[$k]}" in
          SERR) printf '    NIEJEDNOZNACZNE: usługa %s: %s\n' "${DN_SVC[$k]}" "$(ez_printable "${DN_TEXT[$k]}")" ;;
          SWARN|PROFILES) printf '    Uwaga:      usługa %s: %s\n' "${DN_SVC[$k]}" "$(ez_printable "${DN_TEXT[$k]}")" ;;
          UNMAPPED) printf '    Poza hostem: usługa %s: %s\n' "${DN_SVC[$k]}" "$(ez_printable "${DN_TEXT[$k]}")" ;;
        esac
      fi
      k=$((k + 1))
    done
    printf '    Certyfikaty i magazyny:\n'
    shown=0
    t=0
    while [ "$t" -lt "$DT_COUNT" ]; do
      n=0
      for r in ${DT_REFS[$t]}; do
        [ "${DR_PROJ[$r]}" != "$p" ] || n=1
      done
      if [ "$n" -eq 1 ]; then
        ez_dc_print_target "$p" "$t"
        shown=$((shown + 1))
      fi
      t=$((t + 1))
    done
    [ "$shown" -gt 0 ] || printf '      brak odwołań do plików certyfikatów\n'
    p=$((p + 1))
  done
}

ez_discover() {
  local t certs=0 ez=0 stores=0 opened=0 p1=0 unsure=0 fps="" nfps=0

  ez_log_open discover || return 1
  ez_dc_collect
  ez_dc_targets
  ez_dc_print
  t=0
  while [ "$t" -lt "$DT_COUNT" ]; do
    case "${DT_STATE[$t]}" in
      CERT|STORE)
        [ "${DT_SURE[$t]}" = yes ] || [ "${DT_SURE[$t]}" = na ] || unsure=$((unsure + 1))
        case "${DT_STATE[$t]}" in
          CERT) certs=$((certs + 1)); [ "${DT_EZ[$t]}" != yes ] || ez=$((ez + 1)) ;;
          *)
            stores=$((stores + 1))
            [ "${DT_SSTATUS[$t]}" != OK ] || opened=$((opened + 1))
            [ "${DT_SP1[$t]}" != PEWNA ] || p1=$((p1 + 1))
            ;;
        esac
        ;;
    esac
    if [ -n "${DT_P1FP[$t]}" ] && ! ez_names_contain "$fps" "${DT_P1FP[$t]}"; then
      fps="$fps ${DT_P1FP[$t]}"
      nfps=$((nfps + 1))
    fi
    t=$((t + 1))
  done
  printf '\nPodsumowanie: projekty %s, pliki %s (certyfikaty X.509 %s, w tym ezdrowie.gov.pl %s; magazyny JKS/PKCS12 %s, otwarte poprawnie %s, z jednoznacznym certyfikatem P1 %s; wyniki niepewne %s).\n' \
    "$DP_COUNT" "$DT_COUNT" "$certs" "$ez" "$stores" "$opened" "$p1" "$unsure"
  if [ "$nfps" -gt 0 ]; then
    printf 'Odciski SHA-256 produkcyjnych certyfikatów ezdrowie.gov.pl w plikach i magazynach (%s):\n' "$nfps"
    for t in $fps; do
      printf '  %s\n' "$t"
    done
    [ "$nfps" -eq 1 ] || printf 'Uwaga: aplikacje używają różnych certyfikatów ezdrowie.gov.pl.\n'
  fi
  printf 'Polecenie niczego nie zmienia. Podmianę w aplikacjach Docker przygotowuje p1cert ezdrowie plan.\n'
  ez_log "discover finished projects=$DP_COUNT files=$DT_COUNT certificates=$certs ezdrowie=$ez stores=$stores opened=$opened p1=$p1 uncertain=$unsure p1fps=$nfps"
}

# ---------------------------------------------------------------------------
# Docker Compose applications in plan and run.  This unprivileged side only
# decides and reports: files are written and units restarted exclusively by
# the root helper (apply-docker), which derives the application, the files,
# the passwords and the stores again on its own.
# ---------------------------------------------------------------------------

# ez_dc_app_decide <p>: the P1 files of compose project <p> (DP_*/DT_* from
# ez_dc_collect and ez_dc_targets) and what the source certificate (R_*,
# ez_fetch_remote) changes in them:
#   DU_ALL  every P1 file (DT indices), DU_UPD the files to replace,
#   DU_SRC  the selected source (R_* index), DU_DETAIL one line per file,
#   DU_REASON why the application is refused (return 1).
# Files: PEM/DER certificates with a production ezdrowie.gov.pl identity and
# JKS/PKCS12 keystores whose P1 trustedCertEntry is certain.  The application
# is refused as a whole when it has no systemd unit, an ambiguous
# configuration, one uncertain P1 file, no usable source, files that would
# need different sources or a format the source cannot keep.
# PrivateKeyEntry entries, client keystores (no P1 certificate) and other
# certificates are never targets.
ez_dc_app_decide() {
  local p="$1" t r mine names fp na action reason

  DU_ALL=""; DU_UPD=""; DU_SRC=-1; DU_REASON=""; DU_DETAIL=""; DU_SKIP=""
  [ "${DP_UNIT[$p]}" != - ] || { DU_REASON='projekt bez jednostki systemd'; return 1; }
  [ -z "${DP_ERR[$p]}" ] || { DU_REASON="niejednoznaczna konfiguracja projektu: ${DP_ERR[$p]}"; return 1; }
  t=0
  while [ "$t" -lt "$DT_COUNT" ]; do
    # dir: the project only mounts a directory holding the file; such a
    # P1 file is reported (DU_SKIP), never replaced and never a blocker.
    mine=no
    for r in ${DT_REFS[$t]}; do
      [ "${DR_PROJ[$r]}" = "$p" ] || continue
      if [ "${DR_ORIGIN[$r]}" != dir ]; then mine=yes; elif [ "$mine" = no ]; then mine=dir; fi
    done
    if [ "$mine" = dir ]; then
      case "${DT_STATE[$t]}" in
        CERT) [ "${DT_EZ[$t]}" != yes ] || [ -n "${DT_REASON[$t]}" ] || DU_SKIP="$DU_SKIP $t" ;;
        STORE) [ "${DT_SURE[$t]}" = na ] || DU_SKIP="$DU_SKIP $t" ;;
      esac
    elif [ "$mine" = yes ]; then
      case "${DT_STATE[$t]}" in
        CERT)
          if [ "${DT_EZ[$t]}" = yes ] && [ -z "${DT_REASON[$t]}" ]; then
            [ "${DT_SURE[$t]}" = yes ] || { DU_REASON="${DT_PATH[$t]}: wynik niepewny (${DT_WHY[$t]})"; return 1; }
            DU_ALL="$DU_ALL $t"
          fi
          ;;
        STORE)
          if [ "${DT_SURE[$t]}" != na ]; then
            [ "${DT_SURE[$t]}" = yes ] || { DU_REASON="${DT_PATH[$t]}: wynik niepewny (${DT_WHY[$t]})"; return 1; }
            ez_dc_alias_ok "${DT_P1ALIAS[$t]}" || { DU_REASON="${DT_PATH[$t]}: alias wpisu P1 zawiera nieobsługiwane znaki"; return 1; }
            DU_ALL="$DU_ALL $t"
          fi
          ;;
      esac
    fi
    t=$((t + 1))
  done
  [ -n "$DU_ALL" ] || { DU_REASON='aplikacja nie ma certyfikatu P1 do podmiany'; return 1; }

  # One source certificate for all files; SHA-256 decides what changes.
  for t in $DU_ALL; do
    if [ "${DT_STATE[$t]}" = CERT ]; then
      names="${DT_NAMES[$t]}"; fp="${DT_FP[$t]}"; na="$(ez_to_epoch "${DT_NOT_AFTER[$t]}")"
    else
      names="${DT_P1NAMES[$t]}"; fp="${DT_P1FP[$t]}"; na="$(ez_to_epoch "${DT_P1NA[$t]}")"
    fi
    ez_epoch_ok "$na" || { DU_REASON="${DT_PATH[$t]}: nieczytelna data ważności"; return 1; }
    ez_select_remote "" "$names"
    [ "$SEL_STATE" = VALID ] || { DU_REASON="${DT_PATH[$t]}: $SEL_REASON"; return 1; }
    if [ "$DU_SRC" -lt 0 ]; then
      DU_SRC="$SEL_INDEX"
    elif [ "$DU_SRC" != "$SEL_INDEX" ]; then
      DU_REASON='różne certyfikaty źródłowe dla plików jednej aplikacji'
      return 1
    fi
    if [ "${DT_STATE[$t]}" = CERT ] &&
      ! reason="$(ez_replacement_format_ok "${DT_TYPE[$t]}" "${DT_NCERT[$t]}" "${R_FMT[$DU_SRC]}" "${R_NCERT[$DU_SRC]}")"; then
      DU_REASON="${DT_PATH[$t]}: $reason"
      return 1
    fi
    action="$(ez_decide VALID "$fp" "$na" "${R_FP[$DU_SRC]}" "${R_NA[$DU_SRC]}")"
    DU_DETAIL="$DU_DETAIL${DT_PATH[$t]}: $action (obecny SHA-256 $fp)
"
    [ "$action" != UPDATE ] || DU_UPD="$DU_UPD $t"
  done
  return 0
}

# Old fingerprint and alias of a target (the P1 entry of a keystore).
ez_dc_target_fp() {
  if [ "${DT_STATE[$1]}" = CERT ]; then printf '%s' "${DT_FP[$1]}"; else printf '%s' "${DT_P1FP[$1]}"; fi
}

# DC_APP_FILES: the P1 files of every unambiguous Docker application
# (ez_dc_app_decide succeeds); the classic part of the plan leaves them to
# the Docker part.  Files of refused applications keep the classic handling.
ez_dc_app_files() {
  local p=0 t

  DC_APP_FILES=""
  while [ "$p" -lt "$DP_COUNT" ]; do
    if ez_dc_app_decide "$p"; then
      for t in $DU_ALL; do
        DC_APP_FILES="${DC_APP_FILES:+$DC_APP_FILES }${DT_PATH[$t]}"
      done
    fi
    p=$((p + 1))
  done
}

# Report of the P1 files of application $1 left out by ez_dc_app_decide
# (DU_SKIP: only in a mounted directory, no reference in the configuration).
ez_dc_app_skipped() {
  local t

  for t in $DU_SKIP; do
    ez_say "  INFO       [$(($1 + 1))] ${DP_UNIT[$1]}: $(ez_printable "${DT_PATH[$t]}") - $EZ_DC_DIR_ONLY - pominięty, nie blokuje aplikacji"
  done
}

# Docker part of the plan: every application with P1 files is shown with
# its files, the source, the state of its unit and the predicted restart;
# the operator approves the replacement of ALL its files as one operation
# and, separately, the restart of its unit.  Approved applications go to
# PA_* (plan records APP and APP_TARGET).  DOCKER_CANDIDATES counts the
# applications offered.  Needs ez_dc_collect/ez_dc_targets and R_*.
ez_plan_docker() {
  local p t caps p12=unknown reason state alias line k

  PA_COUNT=0; PA_UNIT=(); PA_RESTART=(); PA_SFP=(); PA_SNA=(); PA_SDG=(); PA_TARGETS=()
  DOCKER_CANDIDATES=0
  [ "$DP_COUNT" -gt 0 ] || return 0
  # PKCS12 is replaced by the root helper with its own Java runtime and its
  # integrity-checked tool; it reports both in "ping".
  if ez_helper_usable; then
    caps="$(ez_helper_run ping 2>/dev/null)" || caps=""
    case "$caps" in
      *P12_TOOL=OK*) p12=yes ;;
      *) p12=no ;;
    esac
  fi
  printf '\nAplikacje Docker Compose:\n'
  p=0
  while [ "$p" -lt "$DP_COUNT" ]; do
    if ! ez_dc_app_decide "$p"; then
      ez_dc_app_skipped "$p"
      [ "$DU_REASON" = 'aplikacja nie ma certyfikatu P1 do podmiany' ] ||
        ez_say "  SKIP       [$((p + 1))] ${DP_UNIT[$p]} ${DP_PROJDIR[$p]}: $DU_REASON"
      p=$((p + 1))
      continue
    fi
    ez_dc_app_skipped "$p"
    if [ -z "$DU_UPD" ]; then
      ez_say "  NO CHANGE  [$((p + 1))] ${DP_UNIT[$p]}: certyfikaty P1 aplikacji są aktualne"
      p=$((p + 1))
      continue
    fi
    reason=""
    for t in $DU_UPD; do
      # A file approved above as a classic target (A_PATH of ez_plan) stays
      # there: one file is never in two operations of the same plan.
      if ez_names_contain "${A_PATH[*]:-}" "${DT_PATH[$t]}"; then
        reason="${DT_PATH[$t]}: plik jest już zatwierdzony jako klasyczny target tego planu"
        break
      fi
      if [ "${DT_TYPE[$t]}" = PKCS12 ] && [ "$p12" != yes ]; then
        case "$p12" in
          unknown) reason="${DT_PATH[$t]}: PKCS12 wymaga helpera P1CERT (niedostępny - nie można sprawdzić środowiska Java)" ;;
          *) reason="${DT_PATH[$t]}: PKCS12 wymaga środowiska Java 8+ i sprawdzonego narzędzia p1cert-pkcs12.jar w helperze (P1CERT nie instaluje Javy)" ;;
        esac
        break
      fi
      if ! ez_target_dir_ok "$(fs_path "${DT_PATH[$t]%/*}")" "$EZ_TRUSTED_UID" "$EZ_TRUSTED_GID" "$(id -u)" "$(id -g)"; then
        reason="${DT_PATH[$t]}: katalog nie należy do root ani do użytkownika P1CERT albo jest zapisywalny dla innych; helper odmówi - wymagana podmiana ręczna"
        break
      fi
    done
    if [ -n "$reason" ]; then
      ez_warn "SKIP aplikacja [$((p + 1))] ${DP_UNIT[$p]}: $reason"
      p=$((p + 1))
      continue
    fi

    DOCKER_CANDIDATES=$((DOCKER_CANDIDATES + 1))
    state="${DP_ACTIVE[$p]}"
    printf '\n=== APLIKACJA DOCKER %s: %s ===\n' "$DOCKER_CANDIDATES" "${DP_UNIT[$p]}"
    printf '  Jednostka:          %s (stan: %s)\n' "${DP_UNIT[$p]}" "$(ez_printable "$state")"
    printf '  Projekt Compose:    %s\n' "$(ez_printable "${DP_PROJDIR[$p]}")"
    printf '  Źródło:             %s (NotAfter %s)\n' "${R_NAME[$DU_SRC]}" "${R_NOT_AFTER[$DU_SRC]}"
    printf '  Nowy SHA-256:       %s\n' "${R_FP[$DU_SRC]}"
    printf '  Pliki (podmieniane razem, jedną operacją):\n'
    for t in $DU_UPD; do
      if [ "${DT_STATE[$t]}" = CERT ]; then
        printf '    - %s (%s)\n' "$(ez_printable "${DT_PATH[$t]}")" "${DT_TYPE[$t]}"
      else
        printf '    - %s (%s, wpis "%s"; pozostałe wpisy i klucze prywatne bez zmian)\n' \
          "$(ez_printable "${DT_PATH[$t]}")" "${DT_TYPE[$t]}" "${DT_P1ALIAS[$t]}"
      fi
      printf '        stary SHA-256: %s\n' "$(ez_dc_target_fp "$t")"
    done
    if [ "$state" = active ]; then
      printf '  Przewidywany restart: systemctl restart %s (jednostka zarządza całym projektem Compose)\n' "${DP_UNIT[$p]}"
    else
      printf '  Przewidywany restart: brak - jednostka nie jest aktywna i nie zostanie uruchomiona\n'
    fi
    if ! ez_ask_yes "  Dopuścić PODMIANĘ certyfikatu P1 we wszystkich plikach aplikacji ${DP_UNIT[$p]}?"; then
      ez_say "  operator odrzucił aplikację: ${DP_UNIT[$p]}"
      p=$((p + 1))
      continue
    fi
    k="$PA_COUNT"
    PA_RESTART[$k]=no
    if [ "$state" = active ] && ez_ask_yes "  Dopuścić RESTART: systemctl restart ${DP_UNIT[$p]}?"; then
      PA_RESTART[$k]=yes
    fi
    PA_UNIT[$k]="${DP_UNIT[$p]}"; PA_SFP[$k]="${R_FP[$DU_SRC]}"; PA_SNA[$k]="${R_NA[$DU_SRC]}"
    PA_SDG[$k]="$(ez_file_digest "${R_FILE[$DU_SRC]}")"
    PA_TARGETS[$k]=""
    for t in $DU_UPD; do
      alias=-
      [ "${DT_STATE[$t]}" = CERT ] || alias="${DT_P1ALIAS[$t]}"
      line="${DT_PATH[$t]}|${DT_TYPE[$t]}|${DT_SHA[$t]}|$(ez_dc_target_fp "$t")|$alias"
      PA_TARGETS[$k]="${PA_TARGETS[$k]:+${PA_TARGETS[$k]}
}$line"
    done
    PA_COUNT=$((PA_COUNT + 1))
    ez_say "  zaakceptowano aplikację: ${DP_UNIT[$p]} restart=${PA_RESTART[$k]}"
    p=$((p + 1))
  done
}

# Validates one plan target of a Docker application (same rule as the
# helper): path|type|old-file-sha256|old-fp|alias.
ez_plan_app_target_ok() {
  ez_dc_target_spec_ok "$1"
}

# Runs one approved Docker application of the plan through the root helper
# (T entry $1, PA_* index $2).
ez_run_docker_app() {
  local i="$1" k="$2" r=0 src=-1 out rc result state line t n=0 path type sha fp alias
  local -a args=()

  P_PATH[$i]="docker:${PA_UNIT[$k]}"
  while [ "$r" -lt "$R_COUNT" ]; do
    if [ "${R_STATE[$r]}" = VALID ] && [ "${R_FP[$r]}" = "${PA_SFP[$k]}" ] &&
      [ "$(ez_file_digest "${R_FILE[$r]}")" = "${PA_SDG[$k]}" ]; then
      src="$r"
      break
    fi
    r=$((r + 1))
  done
  if [ "$src" -lt 0 ]; then
    ez_set_result "$i" SKIP 'source certificate file differs from the accepted plan; create a new plan'
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    args[$n]="$line"
    n=$((n + 1))
  done <<EOF
${PA_TARGETS[$k]}
EOF
  ez_say "Podmiana w aplikacji Docker: ${PA_UNIT[$k]} ($n plik(i), restart: ${PA_RESTART[$k]})"
  out="$(ez_helper_run apply-docker "${PA_UNIT[$k]}" "${PA_RESTART[$k]}" "${PA_SDG[$k]}" "${PA_SFP[$k]}" "${args[@]}" < "${R_FILE[$src]}")"
  rc=$?
  ez_log "helper apply-docker ${PA_UNIT[$k]} rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
  result="$(printf '%s\n' "$out" | sed -n 's/^RESULT=//p' | head -n 1)"
  state="$(printf '%s\n' "$out" | sed -n 's/^UNIT_STATE_BEFORE=//p' | head -n 1)"
  case "$rc:$result" in
    0:UPDATED_RESTARTED|0:UPDATED) ;;
    0:NO_CHANGE) ez_set_result "$i" NO_CHANGE 'helper: all files already hold the source certificate'; return 0 ;;
    2:*) ez_set_result "$i" REFUSED 'helper refused (plan, source, paths, application binding or stores did not verify); nothing changed'; return 0 ;;
    3:*) ez_set_result "$i" SKIP 'a file changed since the accepted plan (exact bytes or fingerprint differ); nothing changed; create a new plan'; return 0 ;;
    4:*) ez_set_result "$i" ERROR 'replacement undone by the helper before any restart (verification failed); original files restored'; return 0 ;;
    5:*) ez_set_result "$i" ROLLBACK "restart of ${PA_UNIT[$k]} failed or did not restart the containers; original files restored; restart with them succeeded"; return 0 ;;
    6:*) ez_set_result "$i" ROLLBACK_RESTART_FAILED "restart of ${PA_UNIT[$k]} failed; original files restored and verified, but the application still does not run correctly - manual intervention required"; return 0 ;;
    7:*) ez_set_result "$i" CRITICAL "ROLLBACK FAILED - original files NOT restored; see the helper journal (p1cert ezdrowie recover)"; return 0 ;;
    8:*) ez_set_result "$i" CRITICAL 'an interrupted operation is not recovered yet; run: p1cert ezdrowie recover'; return 0 ;;
    *) ez_set_result "$i" ERROR "helper apply-docker failed (code $rc)"; return 0 ;;
  esac

  # Independent check of the files (as the P1CERT user).
  while IFS='|' read -r path type sha fp alias; do
    [ -n "$path" ] || continue
    case "$type" in
      PEM|DER)
        if ! ez_cert_inspect "$(fs_path "$path")" || [ "$EZC_FP" != "${PA_SFP[$k]}" ]; then
          ez_set_result "$i" ERROR "helper reported success but $path does not hold the source certificate - manual check required"
          return 0
        fi
        ;;
      *)
        if [ "$(ez_file_digest "$(fs_path "$path")")" = "$sha" ]; then
          ez_set_result "$i" ERROR "helper reported success but $path is unchanged - manual check required"
          return 0
        fi
        ;;
    esac
  done <<EOF
${PA_TARGETS[$k]}
EOF
  if [ "$result" = UPDATED_RESTARTED ]; then
    ez_set_result "$i" UPDATED "$n file(s) replaced and verified; ${PA_UNIT[$k]} restarted, containers verified"
  elif [ "${PA_RESTART[$k]}" = yes ]; then
    ez_set_result "$i" UPDATED "$n file(s) replaced and verified; ${PA_UNIT[$k]} was ${state:-not active} before - not started"
  else
    ez_set_result "$i" UPDATED "$n file(s) replaced and verified; no restart approved (restart ${PA_UNIT[$k]} manually)"
  fi
}

# True when the helper reports interrupted Docker operations (ping).
ez_docker_pending() {
  local n

  n="$(ez_helper_run ping 2>/dev/null | sed -n 's/^DOCKER_PENDING=//p' | head -n 1)"
  case "$n" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Recovery of interrupted Docker operations by the root helper (journal);
# each recovered or failed operation becomes a T entry.  Returns 1 when an
# operation could not be recovered.
ez_run_recover() {
  local out line id kind detail rc=0

  out="$(ez_helper_run recover)" || rc=1
  while IFS= read -r line; do
    case "$line" in
      RECOVERY=RECOVERED\|*|RECOVERY=FAILED\|*) ;;
      *) continue ;;
    esac
    line="${line#RECOVERY=}"
    kind="${line%%|*}"; line="${line#*|}"; id="${line%%|*}"; detail="${line#*|}"
    P_PATH[$T_COUNT]="recovery:$id"
    T_RESULT[$T_COUNT]=PENDING; T_DETAIL[$T_COUNT]=''
    if [ "$kind" = RECOVERED ]; then
      ez_set_result "$T_COUNT" RECOVERED "interrupted Docker operation recovered: $detail"
    else
      ez_set_result "$T_COUNT" CRITICAL "interrupted Docker operation could NOT be recovered: $detail"
      rc=1
    fi
    T_COUNT=$((T_COUNT + 1))
  done <<EOF
$out
EOF
  return "$rc"
}

ez_recover_body() {
  local out rc

  ez_require_helper || return 1
  out="$(ez_helper_run recover)"
  rc=$?
  printf '%s\n' "$out" | sed -n 's/^RECOVERY=//p' | while IFS= read -r line; do
    printf '  %s\n' "$(ez_printable "$line")"
  done
  ez_log "recover rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
  return "$rc"
}

ez_recover() {
  ez_log_open recover || return 1
  printf 'Odzyskiwanie przerwanych operacji Docker (dziennik helpera):\n'
  ez_with_lock ez_recover_body
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
    PA_COUNT=0; PA_UNIT=(); PA_RESTART=(); PA_SFP=(); PA_SNA=(); PA_SDG=(); PA_TARGETS=()
  fi
  return "$rc"
}

# APP=<unit>|<restart yes|no>|<source-fp>|<source-notafter>|<source-file-sha256>
ez_plan_parse_app() {
  local unit restart sfp sna sdg separators k=0

  separators="${1//[!|]/}"
  [ "${#separators}" -eq 4 ] || return 1
  IFS='|' read -r unit restart sfp sna sdg <<EOF
$1
EOF
  ez_unit_name_ok "$unit" && ! ez_unit_denied "$unit" || return 1
  case "$restart" in yes|no) ;; *) return 1 ;; esac
  ez_fp_ok "$sfp" && ez_epoch_ok "$sna" && ez_digest_ok "$sdg" || return 1
  while [ "$k" -lt "$PA_COUNT" ]; do
    [ "${PA_UNIT[$k]}" != "$unit" ] || return 1
    k=$((k + 1))
  done
  PA_UNIT[$PA_COUNT]="$unit"; PA_RESTART[$PA_COUNT]="$restart"; PA_SFP[$PA_COUNT]="$sfp"
  PA_SNA[$PA_COUNT]="$sna"; PA_SDG[$PA_COUNT]="$sdg"; PA_TARGETS[$PA_COUNT]=""
  PA_COUNT=$((PA_COUNT + 1))
}

# APP_TARGET=<unit>|<path>|<type>|<old-file-sha256>|<old-fp>|<alias|->
# (after its APP record; a path appears once in the whole plan).
ez_plan_parse_app_target() {
  local unit="${1%%|*}" target="${1#*|}" k=0 found=-1 i path

  ez_plan_app_target_ok "$target" || return 1
  path="${target%%|*}"
  while [ "$k" -lt "$PA_COUNT" ]; do
    [ "${PA_UNIT[$k]}" != "$unit" ] || found="$k"
    case "
${PA_TARGETS[$k]}" in
      *"
$path|"*) return 1 ;;
    esac
    k=$((k + 1))
  done
  [ "$found" -ge 0 ] || return 1
  i=0
  while [ "$i" -lt "$P_COUNT" ]; do
    [ "${P_PATH[$i]}" != "$path" ] || return 1
    i=$((i + 1))
  done
  PA_TARGETS[$found]="${PA_TARGETS[$found]:+${PA_TARGETS[$found]}
}$target"
}

ez_plan_load_records() {
  local file="$1" line key value version="" k

  P_COUNT=0; P_ID=""; P_CREATED_AT=""; P_CREATED_BY=""
  P_PATH=(); P_LFP=(); P_LNA=(); P_LDG=(); P_RFP=(); P_RNA=(); P_RDG=(); P_KIND=(); P_A=(); P_B=()
  PA_COUNT=0; PA_UNIT=(); PA_RESTART=(); PA_SFP=(); PA_SNA=(); PA_SDG=(); PA_TARGETS=()
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
      PLAN_VERSION)
        case "$value" in 2|3) version="$value" ;; *) return 1 ;; esac
        ;;
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
      APP) [ "$version" = 3 ] && ez_plan_parse_app "$value" || return 1 ;;
      APP_TARGET) [ "$version" = 3 ] && ez_plan_parse_app_target "$value" || return 1 ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ -n "$version" ] && [ -n "$P_ID" ] || return 1
  # Version 3 exists only for Docker applications (a classic plan stays 2).
  [ "$version" = 2 ] || [ "$PA_COUNT" -gt 0 ] || return 1
  # Every approved application has at least one file.
  k=0
  while [ "$k" -lt "$PA_COUNT" ]; do
    [ -n "${PA_TARGETS[$k]}" ] || return 1
    k=$((k + 1))
  done
  return 0
}

ez_plan_load_reported() {
  local rc

  ez_plan_load
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) ez_err "brak zaakceptowanego planu ($EZ_PLAN_FILE). Uruchom: p1cert ezdrowie plan" ;;
    *) ez_err "plan $EZ_PLAN_FILE jest nieprawidłowy lub ma starszy format (wymagany PLAN_VERSION=2 lub 3); utwórz nowy: p1cert ezdrowie plan" ;;
  esac
  return "$rc"
}

ez_plan_print() {
  local i=0 k=0 path type sha fp alias

  printf 'Plan: %s\n  ID: %s\n  Utworzony: %s przez %s\n  Targety: %s\n' \
    "$EZ_PLAN_FILE" "$P_ID" "$P_CREATED_AT" "$P_CREATED_BY" "$P_COUNT"
  while [ "$i" -lt "$P_COUNT" ]; do
    printf '  - %s\n      lokalny SHA-256: %s\n      nowy SHA-256:    %s\n      restart: %s\n' \
      "${P_PATH[$i]}" "${P_LFP[$i]}" "${P_RFP[$i]}" "$(ez_restart_label "${P_KIND[$i]}" "${P_A[$i]}" "${P_B[$i]}")"
    i=$((i + 1))
  done
  [ "${PA_COUNT:-0}" -gt 0 ] || return 0
  printf '  Aplikacje Docker: %s\n' "$PA_COUNT"
  while [ "$k" -lt "$PA_COUNT" ]; do
    printf '  - %s (nowy SHA-256: %s; restart: %s)\n' "${PA_UNIT[$k]}" "${PA_SFP[$k]}" \
      "$([ "${PA_RESTART[$k]}" = yes ] && printf 'systemctl restart %s, jeżeli jednostka będzie aktywna' "${PA_UNIT[$k]}" || printf 'brak')"
    while IFS='|' read -r path type sha fp alias; do
      [ -n "$path" ] || continue
      printf '      %s (%s%s), stary SHA-256: %s\n' "$path" "$type" "$([ "$alias" = - ] || printf ', wpis %s' "$alias")" "$fp"
    done <<EOF
${PA_TARGETS[$k]}
EOF
    k=$((k + 1))
  done
}

ez_plan() {
  local i r decision approved=0 candidates=0 choice kind a b n issuer_note reason ldg rdg line
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

  # Docker Compose applications first: a file of an unambiguous application
  # is replaced only together with its other files (one operation, one
  # restart of its unit), never as a separate classic target.
  ez_dc_collect
  ez_dc_targets
  ez_dc_app_files

  printf '\nDecyzje:\n'
  i=0
  while [ "$i" -lt "$L_COUNT" ]; do
    if [ "${L_STATE[$i]}" != OK ]; then
      ez_say "  SKIP       ${L_PATH[$i]} (${L_REASON[$i]})"
      i=$((i + 1))
      continue
    fi
    if ez_names_contain "$DC_APP_FILES" "${L_PATH[$i]}"; then
      ez_say "  DOCKER     ${L_PATH[$i]} (plik aplikacji Docker - decyzja w części \"Aplikacje Docker Compose\")"
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

  # Docker Compose applications (one decision per application).
  ez_plan_docker
  candidates=$((candidates + DOCKER_CANDIDATES))

  printf '\nUPDATE CANDIDATES: %s, zaakceptowane: %s\n' "$candidates" "$((approved + PA_COUNT))"
  if [ "$candidates" -eq 0 ]; then
    ez_say 'Brak kandydatów do aktualizacji; zapisany plan nie został zmieniony.'
    return 0
  fi

  ez_prepare_dir "$STATE_DIR" 0755 || return 1
  {
    printf '# P1CERT ezdrowie plan - generated by "p1cert ezdrowie plan". Do not edit.\n'
    # Version 3 only with Docker applications: a classic plan stays version 2.
    if [ "$PA_COUNT" -gt 0 ]; then printf 'PLAN_VERSION=3\n'; else printf 'PLAN_VERSION=2\n'; fi
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
    n=0
    while [ "$n" -lt "$PA_COUNT" ]; do
      printf 'APP=%s|%s|%s|%s|%s\n' "${PA_UNIT[$n]}" "${PA_RESTART[$n]}" "${PA_SFP[$n]}" "${PA_SNA[$n]}" "${PA_SDG[$n]}"
      printf '%s\n' "${PA_TARGETS[$n]}" | while IFS= read -r line; do
        [ -z "$line" ] || printf 'APP_TARGET=%s|%s\n' "${PA_UNIT[$n]}" "$line"
      done
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
  ez_say "Zapisano plan: $EZ_PLAN_FILE (ID $P_ID, targety: $P_COUNT, aplikacje Docker: $PA_COUNT)"
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
  if [ "$P_COUNT" -eq 0 ] && [ "$PA_COUNT" -eq 0 ]; then
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

  T_COUNT=$((P_COUNT + PA_COUNT))
  i=0
  while [ "$i" -lt "$T_COUNT" ]; do
    T_RESULT[$i]=PENDING; T_DETAIL[$i]=''
    [ "$i" -lt "$P_COUNT" ] || P_PATH[$i]="docker:${PA_UNIT[$((i - P_COUNT))]}"
    i=$((i + 1))
  done
  # An interrupted Docker operation is recovered (or reported) before
  # anything else; the helper refuses new Docker operations until then.
  # Without Docker applications in the plan the helper is asked whether one
  # is pending (a plan made after the interruption).
  if [ "$PA_COUNT" -gt 0 ] || ez_docker_pending; then
    ez_run_recover || true
  fi

  if ! ez_fetch_remote; then
    i=0
    while [ "$i" -lt "$((P_COUNT + PA_COUNT))" ]; do
      ez_set_result "$i" SKIP 'remote source unavailable'
      i=$((i + 1))
    done
  else
    i=0
    while [ "$i" -lt "$P_COUNT" ]; do
      ez_replace_one "$i"
      i=$((i + 1))
    done
    while [ "$i" -lt "$((P_COUNT + PA_COUNT))" ]; do
      ez_run_docker_app "$i" "$((i - P_COUNT))"
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
  # Approved Docker applications (PA_*) are targets too: a plan may have
  # only them.
  if [ "$P_COUNT" -eq 0 ] && [ "$PA_COUNT" -eq 0 ]; then
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
  discover          aplikacje Docker Compose i używane przez nie certyfikaty
                    oraz magazyny JKS/PKCS12 (tylko odczyt)
  plan              porównaj ze źródłem i zaakceptuj podmiany/restarty
  run [--yes]       wykonaj zaakceptowany plan
  schedule [YYYY-MM-DD HH:MM]
                    zaplanuj JEDNORAZOWE wykonanie zaakceptowanego planu
  schedule-status   pokaż plan, timer i wynik ostatniego run
  schedule-cancel   anuluj oczekujące uruchomienie (plan i backupy zostają)
  recover           odzyskaj przerwaną operację Docker (przywraca oryginalne pliki)
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
    discover) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_discover ;;
    plan) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_with_lock ez_plan ;;
    run) ez_run "$@" ;;
    schedule) ez_schedule "$@" ;;
    schedule-status) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_schedule_status ;;
    schedule-cancel) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_schedule_cancel ;;
    recover) [ "$#" -eq 0 ] || { ez_usage >&2; return 2; }; ez_recover ;;
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
