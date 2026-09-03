#!/usr/bin/env bash
# shellcheck shell=bash
# Controlled, idempotent CA update for legacy P1ADAPTER and P1CER only.

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$SCRIPT_DIR/p1cert.version" ]; then MODULE_DIR="$SCRIPT_DIR"; else MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; fi
P1CERT_LIB_ONLY=1 . "$SCRIPT_DIR/p1cert_audit.sh"

UPDATE_RESULT=UNKNOWN
UPDATE_BACKUP_DIR=""
BACKED_STORES=""
APP_ROOT_RESULT=UNKNOWN
APP_TLS_RESULT=UNKNOWN
JAVA_ROOT_RESULT='NIE WYKRYTO'
JAVA_TLS_RESULT='NIE WYKRYTO'
LAST_CA_RESULT=error

update_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
result_label() {
  case "$1" in present) printf 'JUŻ OBECNY' ;; added) printf 'DODANO' ;; error) printf 'BŁĄD' ;; *) printf '%s' "$1" ;; esac
}
backup_name() { basename "$1"; }

new_backup_dir() {
  [ -n "$UPDATE_BACKUP_DIR" ] && return 0
  UPDATE_BACKUP_DIR="$MODULE_DIR/backups/$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "$UPDATE_BACKUP_DIR" || return 1
}

store_output() {
  local scope="$1" store="$2" store_type="$3" password="$4" container="$5"
  if [ -n "$container" ]; then
    printf '%s\n' "$password" | docker exec -i "$container" keytool -list -v -keystore "$store" -storetype "$store_type" 2>/dev/null || true
  else
    printf '%s\n' "$password" | keytool -list -v -keystore "$store" -storetype "$store_type" 2>/dev/null || true
  fi
}
store_has_fp() {
  local output
  output="$(store_output "$@")"
  [ -n "$output" ] || return 2
  printf '%s\n' "$output" | grep -F -q "$TARGET_FP"
}
backup_store() {
  local store="$1" container="$2" destination
  new_backup_dir || return 1
  destination="$UPDATE_BACKUP_DIR/$(backup_name "$store")"
  if [ -n "$container" ]; then
    docker cp "$container:$store" "$destination" >/dev/null 2>&1
  else
    cp -p "$store" "$destination" 2>/dev/null
  fi
}
ensure_backup() {
  local store="$1" container="$2" backup_key="$container:$store"
  case "|$BACKED_STORES|" in *"|$backup_key|"*) return 0 ;; esac
  backup_store "$store" "$container" || return 1
  BACKED_STORES="${BACKED_STORES:+$BACKED_STORES|}$backup_key"
}
import_certificate() {
  local store="$1" store_type="$2" password="$3" container="$4" alias="$5" cert_file="$6"
  if [ -n "$container" ]; then
    # Payload files are local; copy each public CA into a disposable location
    # in the target container rather than exposing secrets in arguments.
    local container_cert="/tmp/p1cert-${alias}-$$.pem"
    docker cp "$cert_file" "$container:$container_cert" >/dev/null 2>&1 || return 1
    printf '%s\n' "$password" | docker exec -i "$container" keytool -importcert -noprompt -alias "$alias" -file "$container_cert" -keystore "$store" -storetype "$store_type" >/dev/null 2>&1
    docker exec "$container" rm -f "$container_cert" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$password" | keytool -importcert -noprompt -alias "$alias" -file "$cert_file" -keystore "$store" -storetype "$store_type" >/dev/null 2>&1
  fi
}
update_one_ca() {
  local label="$1" target_fp="$2" alias="$3" cert_file="$4" store="$5" store_type="$6" password="$7" container="$8" check_result
  TARGET_FP="$target_fp"
  if store_has_fp app "$store" "$store_type" "$password" "$container"; then
    LAST_CA_RESULT=present; return 0
  else
    check_result=$?
  fi
  if [ "$check_result" -eq 2 ]; then LAST_CA_RESULT=error; return 0; fi
  ensure_backup "$store" "$container" || { update_log "backup failed for $label"; LAST_CA_RESULT=error; return 0; }
  import_certificate "$store" "$store_type" "$password" "$container" "$alias" "$cert_file" || { update_log "import failed for $label"; LAST_CA_RESULT=error; return 0; }
  TARGET_FP="$target_fp"
  if store_has_fp app "$store" "$store_type" "$password" "$container"; then LAST_CA_RESULT=added; else LAST_CA_RESULT=error; fi
}

update_store_pair() {
  local scope="$1" store="$2" store_type="$3" password="$4" container="$5" root_result tls_result
  update_one_ca RootCA "$TARGET_ROOT_FP" itgo-p1-rootca-2025 "$PAYLOAD_TMP/root.pem" "$store" "$store_type" "$password" "$container"; root_result="$LAST_CA_RESULT"
  update_one_ca SubCA-TLS "$TARGET_TLS_FP" itgo-p1-subca-tls-2025 "$PAYLOAD_TMP/tls.pem" "$store" "$store_type" "$password" "$container"; tls_result="$LAST_CA_RESULT"
  case "$scope" in
    app) APP_ROOT_RESULT="$root_result"; APP_TLS_RESULT="$tls_result" ;;
    java) JAVA_ROOT_RESULT="$root_result"; JAVA_TLS_RESULT="$tls_result" ;;
  esac
}

write_update_state() {
  local temp_file
  write_state
  temp_file="$STATE_FILE.$$.tmp"
  umask 077
  {
    awk '1' "$STATE_FILE"
    printf 'UPDATE_RESULT=%s\nUPDATE_TIMESTAMP=%s\n' "$UPDATE_RESULT" "$(date '+%FT%T%z')"
  } > "$temp_file"
  mv -f "$temp_file" "$STATE_FILE"; chmod 0644 "$STATE_FILE"
}

refresh_update_presence() {
  local app_store="$1" app_container="$2" java_container="$3" output
  TARGET_ROOT_PRESENT=unknown; TARGET_TLS_PRESENT=unknown
  if [ -n "$app_store" ]; then
    output="$(store_output app "$app_store" "$SERVER_TRUST_TYPE" "$SERVER_TRUST_PASSWORD" "$app_container")"
    [ -z "$output" ] || mark_targets "$output"
  fi
  JAVA_TARGET_ROOT_PRESENT=unknown; JAVA_TARGET_TLS_PRESENT=unknown
  if [ "$JAVA_DETECTED" = yes ] && [ -n "$JAVA_CACERTS" ]; then
    output="$(store_output java "$JAVA_CACERTS" JKS changeit "$java_container")"
    if [ -n "$output" ]; then
      if printf '%s\n' "$output" | grep -F -q "$TARGET_ROOT_FP"; then JAVA_TARGET_ROOT_PRESENT=yes; else JAVA_TARGET_ROOT_PRESENT=no; fi
      if printf '%s\n' "$output" | grep -F -q "$TARGET_TLS_FP"; then JAVA_TARGET_TLS_PRESENT=yes; else JAVA_TARGET_TLS_PRESENT=no; fi
    fi
  fi
}

run_update() {
  local app_store app_container java_container
  mkdir -p "$LOG_DIR" "$STATE_DIR"; LOG_FILE="$LOG_DIR/p1cert-update-$(date '+%Y%m%d_%H%M%S').log"; update_log 'update started'
  load_payload; detect_source
  case "$PROFILE" in
    P1ADAPTER|P1CER) ;;
    *) printf 'UPDATE NIEOBSŁUGIWANY DLA PROFILU: %s\n' "$PROFILE"; UPDATE_RESULT=UNKNOWN; write_update_state; return 0 ;;
  esac
  if [ "$AUDIT_RESULT" = UNKNOWN ] || [ -z "$SERVER_TRUST_PATH" ]; then UPDATE_RESULT=UNKNOWN; write_update_state; return 0; fi
  case "$SERVER_TRUST_TYPE" in JKS|jks|PKCS12|pkcs12) ;; *) UPDATE_RESULT=UNKNOWN; write_update_state; return 0 ;; esac

  app_store="$(fs_path "$SERVER_TRUST_PATH")"; app_container=''
  if ! { command -v keytool >/dev/null 2>&1 && [ -r "$app_store" ]; }; then
    app_container="$(find_container)"; [ -n "$app_container" ] && app_store="$(container_path "$app_container" || true)"
  fi
  if [ -z "$app_store" ] || { [ -n "$app_container" ] && ! docker exec "$app_container" sh -c 'command -v keytool >/dev/null 2>&1' >/dev/null 2>&1; }; then
    APP_ROOT_RESULT=error; APP_TLS_RESULT=error
  else
    update_store_pair app "$app_store" "$SERVER_TRUST_TYPE" "$SERVER_TRUST_PASSWORD" "$app_container"
  fi

  SOURCE_CONTAINER="$app_container"; detect_java
  java_container="$SOURCE_CONTAINER"
  if [ "$JAVA_DETECTED" = yes ] && [ -n "$JAVA_CACERTS" ]; then
    update_store_pair java "$JAVA_CACERTS" JKS changeit "$java_container"
    [ -z "$java_container" ] || printf '%s\n' 'UWAGA: Java cacerts zmodyfikowany wewnątrz kontenera; zmiana może zniknąć po odtworzeniu kontenera.'
  fi
  if [ "$APP_ROOT_RESULT" != error ] && [ "$APP_TLS_RESULT" != error ] && [ "$JAVA_ROOT_RESULT" != error ] && [ "$JAVA_TLS_RESULT" != error ] && [ "$JAVA_ROOT_RESULT" != 'NIE WYKRYTO' ] && [ "$JAVA_TLS_RESULT" != 'NIE WYKRYTO' ]; then UPDATE_RESULT=OK; else UPDATE_RESULT=UNKNOWN; fi
  refresh_update_presence "$app_store" "$app_container" "$java_container"
  write_update_state; update_log "update finished result=$UPDATE_RESULT"
  printf 'Magazyn aplikacji:\n  RootCA 2025: %s\n  SubCA TLS 2025: %s\nJava cacerts:\n  RootCA 2025: %s\n  SubCA TLS 2025: %s\nWynik update: %s\n' "$(result_label "$APP_ROOT_RESULT")" "$(result_label "$APP_TLS_RESULT")" "$(result_label "$JAVA_ROOT_RESULT")" "$(result_label "$JAVA_TLS_RESULT")" "$UPDATE_RESULT"
  [ "$UPDATE_RESULT" != OK ] || printf '%s\n' 'Zmiany zapisane. Wymagany restart aplikacji/kontenera przed użyciem nowych CA.'
}

if [ "${P1CERT_UPDATE_LIB_ONLY:-0}" != 1 ]; then run_update "$@"; fi
