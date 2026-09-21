#!/usr/bin/env bash
# shellcheck shell=bash
# Controlled, idempotent P1 CA update.
#
# Modes:
#   auto             host Java + detected JKS/PKCS12 application truststore
#                    when available; otherwise host Java only
#   --java-only      host Java only
#   --with-keystore  host Java + detected JKS/PKCS12 application truststore
#
# Docker Java/cacerts and PEM trust files are never modified.

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$SCRIPT_DIR/p1cert.version" ]; then
  MODULE_DIR="$SCRIPT_DIR"
else
  MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

P1CERT_LIB_ONLY=1 . "$SCRIPT_DIR/p1cert_audit.sh"

UPDATE_MODE=auto
UPDATE_RESULT=UNKNOWN
UPDATE_BACKUP_DIR=""
BACKED_STORES=""

APP_ROOT_RESULT=skipped
APP_TLS_RESULT=skipped
APP_WSS_RESULT=skipped

JAVA_ROOT_RESULT='NIE WYKRYTO'
JAVA_TLS_RESULT='NIE WYKRYTO'
JAVA_WSS_RESULT='NIE WYKRYTO'

LAST_CA_RESULT=error
IMPORT_ALIAS=""
SUDO_READY=no
ACTIVE_KEYTOOL=""
STORE_OUTPUT=""
LOCAL_KEYTOOL_USE_SUDO=no

RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"

update_log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

result_label() {
  case "$1" in
    present) printf 'JUŻ OBECNY' ;;
    added)   printf 'DODANO' ;;
    skipped) printf 'POMINIĘTO' ;;
    error)   printf 'BŁĄD' ;;
    *)       printf '%s' "$1" ;;
  esac
}

usage_update() {
  cat <<'EOF'
Użycie:
  p1cert update
  p1cert update --java-only
  p1cert update --with-keystore

Tryby:
  auto
      Aktualizuje hostowy Java cacerts.
      Jeżeli wykryto obsługiwany JKS/PKCS12 aplikacji, aktualizuje również ten magazyn.

  --java-only
      Aktualizuje wyłącznie hostowy Java cacerts.

  --with-keystore
      Aktualizuje hostowy Java cacerts oraz wykryty JKS/PKCS12 aplikacji.
      Jeżeli magazyn aplikacji nie zostanie wykryty, update kończy się błędem.

P1CERT nigdy nie modyfikuje:
  - Java/cacerts wewnątrz kontenerów,
  - plików PEM używanych jako trust,
  - certyfikatów klienta TLS/WSS,
  - haseł magazynów.
EOF
}

parse_args() {
  case "${1:-}" in
    "")
      UPDATE_MODE=auto
      ;;
    --java-only)
      UPDATE_MODE=java-only
      ;;
    --with-keystore)
      UPDATE_MODE=with-keystore
      ;;
    -h|--help)
      usage_update
      exit 0
      ;;
    *)
      printf 'Nieznana opcja update: %s\n\n' "$1" >&2
      usage_update >&2
      exit 2
      ;;
  esac

  if [ "$#" -gt 1 ]; then
    printf 'Za dużo argumentów dla p1cert update.\n\n' >&2
    usage_update >&2
    exit 2
  fi
}

ensure_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_READY=yes
    return 0
  fi

  if [ "$SUDO_READY" = yes ]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    update_log 'sudo unavailable'
    return 1
  fi

  printf '%s\n' 'P1CERT potrzebuje uprawnień administracyjnych do modyfikacji hostowego magazynu certyfikatów.'
  sudo -v || {
    update_log 'sudo authorization failed'
    return 1
  }

  SUDO_READY=yes
}

backup_name() {
  local store="$1"
  local container="$2"
  local scope
  local identifier

  command -v cksum >/dev/null 2>&1 || return 1

  if [ -n "$container" ]; then
    scope="container-$(printf '%s' "$container" | tr -c '[:alnum:]._-' '_')"
  else
    scope=host
  fi

  identifier="$(printf '%s' "$container:$store" | cksum | awk '{print $1}')" || return 1
  [ -n "$identifier" ] || return 1

  printf '%s-%s.bak\n' "$scope" "$identifier"
}

new_backup_dir() {
  [ -n "$UPDATE_BACKUP_DIR" ] && return 0

  mkdir -p "$MODULE_DIR/backups" || return 1
  UPDATE_BACKUP_DIR="$(
    umask 077
    mktemp -d "$MODULE_DIR/backups/p1cert-update.XXXXXX"
  )" || return 1
}

local_store_requires_sudo() {
  local store="$1"
  local operation="$2"

  LOCAL_KEYTOOL_USE_SUDO=no

  [ "$(id -u)" -eq 0 ] && return 0
  [ -e "$store" ] || return 1

  case "$operation" in
    list)
      [ -r "$store" ] || LOCAL_KEYTOOL_USE_SUDO=yes
      ;;
    import)
      if [ ! -r "$store" ] || [ ! -w "$store" ]; then
        LOCAL_KEYTOOL_USE_SUDO=yes
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

keytool_list_local() {
  local store="$1" store_type="$2" password="$3"
  local -a args

  [ -n "$ACTIVE_KEYTOOL" ] && [ -x "$ACTIVE_KEYTOOL" ] || return 1

  args=(-list -v -keystore "$store")
  [ -z "$store_type" ] || args+=(-storetype "$store_type")

  local_store_requires_sudo "$store" list || return 1

  if [ "$LOCAL_KEYTOOL_USE_SUDO" = yes ]; then
    ensure_sudo || return 1
    printf '%s\n' "$password" | sudo env LC_ALL=C "$ACTIVE_KEYTOOL" "${args[@]}" 2>/dev/null
  else
    printf '%s\n' "$password" | LC_ALL=C "$ACTIVE_KEYTOOL" "${args[@]}" 2>/dev/null
  fi
}

keytool_list_container() {
  local store="$1" store_type="$2" password="$3" container="$4"
  local -a args

  args=(-list -v -keystore "$store")
  [ -z "$store_type" ] || args+=(-storetype "$store_type")

  printf '%s\n' "$password" |
    docker exec -i "$container" env LC_ALL=C keytool "${args[@]}" 2>/dev/null
}

store_output() {
  local store store_type password container output_file

  shift
  store="$1"
  store_type="$2"
  password="$3"
  container="$4"

  STORE_OUTPUT=""
  output_file="$(mktemp "${TMPDIR:-/tmp}/p1cert-keytool.XXXXXX")" || return 1

  if [ -n "$container" ]; then
    if keytool_list_container "$store" "$store_type" "$password" "$container" > "$output_file"; then
      STORE_OUTPUT="$(cat "$output_file")"
      rm -f "$output_file"
      return 0
    fi
  else
    if keytool_list_local "$store" "$store_type" "$password" > "$output_file"; then
      STORE_OUTPUT="$(cat "$output_file")"
      rm -f "$output_file"
      return 0
    fi
  fi

  rm -f "$output_file"
  STORE_OUTPUT=""
  return 1
}

store_has_fp() {
  local output

  [ -n "${TARGET_FP:-}" ] || return 2

  store_output "$@" || return 2
  output="$STORE_OUTPUT"

  printf '%s\n' "$output" | grep -F -q "$TARGET_FP"
}

store_has_alias() {
  local alias="$1"
  local store="$2"
  local store_type="$3"
  local password="$4"
  local container="$5"
  local output

  store_output update "$store" "$store_type" "$password" "$container" || return 2
  output="$STORE_OUTPUT"

  # keytool output is forced to the C locale by the list helpers, making this
  # exact label stable across supported RHEL/Oracle Linux installations.
  printf '%s\n' "$output" | grep -F -i -x -q "Alias name: $alias"
}

alternative_alias() {
  local preferred="$1"
  local fingerprint="$2"
  local fingerprint_id

  fingerprint_id="${fingerprint//:/}"
  [ -n "$fingerprint_id" ] || return 1
  printf '%s-%s\n' "$preferred" "$fingerprint_id"
}

select_import_alias() {
  local preferred="$1"
  local fingerprint="$2"
  local store="$3"
  local store_type="$4"
  local password="$5"
  local container="$6"
  local selected
  local alias_result

  if store_has_alias "$preferred" "$store" "$store_type" "$password" "$container"; then
    selected="$(alternative_alias "$preferred" "$fingerprint")" || return 1

    if store_has_alias "$selected" "$store" "$store_type" "$password" "$container"; then
      return 1
    else
      alias_result=$?
    fi

    [ "$alias_result" -eq 1 ] || return 1
    IMPORT_ALIAS="$selected"
    return 0
  else
    alias_result=$?
  fi

  [ "$alias_result" -eq 1 ] || return 1
  IMPORT_ALIAS="$preferred"
  return 0
}

backup_store() {
  local store="$1" container="$2" destination

  new_backup_dir || return 1
  destination="$UPDATE_BACKUP_DIR/$(backup_name "$store" "$container")" || return 1
  [ ! -e "$destination" ] || return 1

  if [ -n "$container" ]; then
    docker cp "$container:$store" "$destination" >/dev/null 2>&1
    return $?
  fi

  if cp -p "$store" "$destination" 2>/dev/null; then
    return 0
  fi

  ensure_sudo || return 1

  sudo cp -p "$store" "$destination" >/dev/null 2>&1 || return 1
  sudo chown "${RUN_USER}:${RUN_GROUP}" "$destination" >/dev/null 2>&1 || true

  return 0
}

ensure_backup() {
  local store="$1" container="$2" backup_key="$container:$store"

  case "|$BACKED_STORES|" in
    *"|$backup_key|"*)
      return 0
      ;;
  esac

  backup_store "$store" "$container" || return 1
  BACKED_STORES="${BACKED_STORES:+$BACKED_STORES|}$backup_key"
}

keytool_import_local() {
  local store="$1" store_type="$2" password="$3" alias="$4" cert_file="$5"
  local -a args

  [ -n "$ACTIVE_KEYTOOL" ] && [ -x "$ACTIVE_KEYTOOL" ] || return 1

  args=(
    -importcert
    -noprompt
    -alias "$alias"
    -file "$cert_file"
    -keystore "$store"
  )
  [ -z "$store_type" ] || args+=(-storetype "$store_type")

  local_store_requires_sudo "$store" import || return 1

  if [ "$LOCAL_KEYTOOL_USE_SUDO" = yes ]; then
    ensure_sudo || return 1
    printf '%s\n' "$password" |
      sudo "$ACTIVE_KEYTOOL" "${args[@]}" >/dev/null 2>&1
  else
    printf '%s\n' "$password" |
      "$ACTIVE_KEYTOOL" "${args[@]}" >/dev/null 2>&1
  fi
}

keytool_import_container() {
  local store="$1" store_type="$2" password="$3" container="$4" alias="$5" cert_file="$6"
  local container_cert="/tmp/p1cert-${alias}-$$.pem"
  local -a args

  docker cp "$cert_file" "$container:$container_cert" >/dev/null 2>&1 || return 1

  args=(
    -importcert
    -noprompt
    -alias "$alias"
    -file "$container_cert"
    -keystore "$store"
  )
  [ -z "$store_type" ] || args+=(-storetype "$store_type")

  if ! printf '%s\n' "$password" |
    docker exec -i "$container" keytool "${args[@]}" >/dev/null 2>&1; then
    docker exec "$container" rm -f "$container_cert" >/dev/null 2>&1 || true
    return 1
  fi

  docker exec "$container" rm -f "$container_cert" >/dev/null 2>&1 || true
}

import_certificate() {
  local store="$1" store_type="$2" password="$3" container="$4" alias="$5" cert_file="$6"

  if [ -n "$container" ]; then
    keytool_import_container \
      "$store" "$store_type" "$password" "$container" "$alias" "$cert_file"
  else
    keytool_import_local \
      "$store" "$store_type" "$password" "$alias" "$cert_file"
  fi
}

update_one_ca() {
  local label="$1"
  local target_fp="$2"
  local alias="$3"
  local cert_file="$4"
  local store="$5"
  local store_type="$6"
  local password="$7"
  local container="$8"
  local check_result

  TARGET_FP="$target_fp"

  if store_has_fp update "$store" "$store_type" "$password" "$container"; then
    LAST_CA_RESULT=present
    return 0
  else
    check_result=$?
  fi

  if [ "$check_result" -eq 2 ]; then
    update_log "cannot inspect store for $label: $store"
    LAST_CA_RESULT=error
    return 0
  fi

  select_import_alias \
    "$alias" "$target_fp" "$store" "$store_type" "$password" "$container" || {
      update_log "no safe alias available for $label: $store"
      LAST_CA_RESULT=error
      return 0
    }

  ensure_backup "$store" "$container" || {
    update_log "backup failed for $label: $store"
    LAST_CA_RESULT=error
    return 0
  }

  import_certificate \
    "$store" "$store_type" "$password" "$container" "$IMPORT_ALIAS" "$cert_file" || {
      update_log "import failed for $label: $store"
      LAST_CA_RESULT=error
      return 0
    }

  TARGET_FP="$target_fp"

  if store_has_fp update "$store" "$store_type" "$password" "$container"; then
    LAST_CA_RESULT=added
  else
    update_log "verification failed for $label: $store"
    LAST_CA_RESULT=error
  fi
}

update_store_pair() {
  local scope="$1"
  local store="$2"
  local store_type="$3"
  local password="$4"
  local container="$5"

  local root_result
  local tls_result
  local wss_result

  if [ -z "$container" ]; then
    case "$scope" in
      java)
        ACTIVE_KEYTOOL="${JAVA_KEYTOOL:-}"
        ;;
      app)
        ACTIVE_KEYTOOL="$(command -v keytool 2>/dev/null || true)"
        ;;
    esac
  else
    ACTIVE_KEYTOOL=""
  fi

  update_one_ca \
    RootCA \
    "$TARGET_ROOT_FP" \
    itgo-p1-rootca-2025 \
    "$PAYLOAD_TMP/root.pem" \
    "$store" "$store_type" "$password" "$container"
  root_result="$LAST_CA_RESULT"

  update_one_ca \
    SubCA-TLS \
    "$TARGET_TLS_FP" \
    itgo-p1-subca-tls-2025 \
    "$PAYLOAD_TMP/tls.pem" \
    "$store" "$store_type" "$password" "$container"
  tls_result="$LAST_CA_RESULT"

  update_one_ca \
    SubCA-WSS \
    "$TARGET_WSS_FP" \
    itgo-p1-subca-wss-2025 \
    "$PAYLOAD_TMP/wss.pem" \
    "$store" "$store_type" "$password" "$container"
  wss_result="$LAST_CA_RESULT"

  case "$scope" in
    app)
      APP_ROOT_RESULT="$root_result"
      APP_TLS_RESULT="$tls_result"
      APP_WSS_RESULT="$wss_result"
      ;;
    java)
      JAVA_ROOT_RESULT="$root_result"
      JAVA_TLS_RESULT="$tls_result"
      JAVA_WSS_RESULT="$wss_result"
      ;;
  esac
}

results_ok() {
  case "$1" in present|added) ;; *) return 1 ;; esac
  case "$2" in present|added) ;; *) return 1 ;; esac
  case "$3" in present|added) ;; *) return 1 ;; esac
  return 0
}

write_update_state() {
  local temp_file

  write_state

  temp_file="$STATE_FILE.$$.tmp"
  umask 077

  {
    awk '1' "$STATE_FILE"
    printf 'UPDATE_MODE=%s\n' "$UPDATE_MODE"
    printf 'UPDATE_RESULT=%s\n' "$UPDATE_RESULT"
    printf 'UPDATE_TIMESTAMP=%s\n' "$(date '+%FT%T%z')"
  } > "$temp_file"

  mv -f "$temp_file" "$STATE_FILE"
  chmod 0644 "$STATE_FILE"
}

refresh_update_presence() {
  local app_enabled="$1"
  local app_store="$2"
  local app_container="$3"
  local output

  TARGET_ROOT_PRESENT=unknown
  TARGET_TLS_PRESENT=unknown
  TARGET_WSS_PRESENT=unknown

  if [ "$app_enabled" = yes ] && [ -n "$app_store" ]; then
    if [ -n "$app_container" ]; then
      ACTIVE_KEYTOOL=""
    else
      ACTIVE_KEYTOOL="$(command -v keytool 2>/dev/null || true)"
    fi

    if store_output \
      app \
      "$app_store" \
      "$SERVER_TRUST_TYPE" \
      "$SERVER_TRUST_PASSWORD" \
      "$app_container"; then
      output="$STORE_OUTPUT"
      mark_targets "$output"
    fi
  fi

  JAVA_TARGET_ROOT_PRESENT=unknown
  JAVA_TARGET_TLS_PRESENT=unknown
  JAVA_TARGET_WSS_PRESENT=unknown

  if [ "$JAVA_DETECTED" = yes ] && [ -n "$JAVA_CACERTS" ]; then
    ACTIVE_KEYTOOL="${JAVA_KEYTOOL:-}"

    if store_output java "$JAVA_CACERTS" "" changeit ""; then
      output="$STORE_OUTPUT"
      if printf '%s\n' "$output" | grep -F -q "$TARGET_ROOT_FP"; then
        JAVA_TARGET_ROOT_PRESENT=yes
      else
        JAVA_TARGET_ROOT_PRESENT=no
      fi

      if printf '%s\n' "$output" | grep -F -q "$TARGET_TLS_FP"; then
        JAVA_TARGET_TLS_PRESENT=yes
      else
        JAVA_TARGET_TLS_PRESENT=no
      fi

      if printf '%s\n' "$output" | grep -F -q "$TARGET_WSS_FP"; then
        JAVA_TARGET_WSS_PRESENT=yes
      else
        JAVA_TARGET_WSS_PRESENT=no
      fi
    fi
  fi
}

payload_ready_for_update() {
  [ -n "${PAYLOAD_TMP:-}" ] || return 1
  [ -d "$PAYLOAD_TMP" ] || return 1

  [ -n "${TARGET_ROOT_FP:-}" ] || return 1
  [ -n "${TARGET_TLS_FP:-}" ] || return 1
  [ -n "${TARGET_WSS_FP:-}" ] || return 1

  [ -s "$PAYLOAD_TMP/root.pem" ] || return 1
  [ -s "$PAYLOAD_TMP/tls.pem" ] || return 1
  [ -s "$PAYLOAD_TMP/wss.pem" ] || return 1

  return 0
}

canonical_local_path() {
  local path="$1"

  readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
}

local_store_is_java_cacerts() {
  local store="$1"
  local store_real
  local java_real

  [ -n "${JAVA_CACERTS:-}" ] || return 1

  store_real="$(canonical_local_path "$store")"
  java_real="$(canonical_local_path "$JAVA_CACERTS")"

  [ "$store_real" = "$java_real" ]
}

container_store_is_java_cacerts() {
  local container="$1"
  local store="$2"

  [ -n "$container" ] && [ -n "$store" ] || return 1

  docker exec "$container" sh -c '
    store="$1"

    canonical_path() {
      readlink -f "$1" 2>/dev/null || printf "%s\n" "$1"
    }

    store_real="$(canonical_path "$store")"

    java_home=""

    if command -v java >/dev/null 2>&1; then
      java_home="$(
        java -XshowSettings:properties -version 2>&1 |
          awk -F= '"'"'
            /^[[:space:]]*java.home[[:space:]]*=/ {
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
              print $2
              exit
            }
          '"'"'
      )"
    fi

    if [ -n "$java_home" ]; then
      for candidate in \
        "$java_home/lib/security/cacerts" \
        "$java_home/jre/lib/security/cacerts"
      do
        if [ "$store_real" = "$(canonical_path "$candidate")" ]; then
          exit 0
        fi
      done
    fi

    if command -v keytool >/dev/null 2>&1; then
      keytool_bin="$(command -v keytool)"
      keytool_bin="$(canonical_path "$keytool_bin")"
      keytool_dir="$(dirname "$keytool_bin")"

      for candidate in \
        "$keytool_dir/../lib/security/cacerts" \
        "$keytool_dir/../jre/lib/security/cacerts"
      do
        if [ "$store_real" = "$(canonical_path "$candidate")" ]; then
          exit 0
        fi
      done
    fi

    exit 1
  ' sh "$store" >/dev/null 2>&1
}

prepare_app_store() {
  APP_ENABLED=no
  APP_STORE=""
  APP_CONTAINER=""

  case "$SERVER_TRUST_TYPE" in
    JKS|jks|PKCS12|pkcs12)
      ;;
    *)
      return 1
      ;;
  esac

  [ -n "$SERVER_TRUST_PATH" ] || return 1

  APP_STORE="$(fs_path "$SERVER_TRUST_PATH")"

  if local_store_is_java_cacerts "$APP_STORE"; then
    update_log "refusing application truststore equal to host Java cacerts: $APP_STORE"
    APP_STORE=""
    return 1
  fi

  if command -v keytool >/dev/null 2>&1 && [ -e "$APP_STORE" ]; then
    APP_ENABLED=yes
    return 0
  fi

  APP_CONTAINER="$(find_container || true)"

  if [ -z "$APP_CONTAINER" ]; then
    APP_STORE=""
    return 1
  fi

  APP_STORE="$(container_path "$APP_CONTAINER" || true)"

  if [ -z "$APP_STORE" ]; then
    APP_CONTAINER=""
    return 1
  fi

  if ! docker exec "$APP_CONTAINER" sh -c \
    'command -v keytool >/dev/null 2>&1' >/dev/null 2>&1; then
    APP_STORE=""
    APP_CONTAINER=""
    return 1
  fi

  if container_store_is_java_cacerts "$APP_CONTAINER" "$APP_STORE"; then
    update_log "refusing application truststore equal to container Java cacerts: $APP_STORE"
    APP_STORE=""
    APP_CONTAINER=""
    return 1
  fi

  APP_ENABLED=yes
  return 0
}

run_update() {
  local java_container=''
  local java_ok=no
  local app_ok=yes

  parse_args "$@"

  mkdir -p "$LOG_DIR" "$STATE_DIR"
  LOG_FILE="$LOG_DIR/p1cert-update-$(date '+%Y%m%d_%H%M%S').log"

  update_log "update started mode=$UPDATE_MODE"

  if ! load_payload || ! payload_ready_for_update; then
    UPDATE_RESULT=UNKNOWN
    update_log 'update aborted: payload validation failed'
    printf '%s\n' 'BŁĄD: payload P1CERT jest niekompletny lub nieprawidłowy.' >&2
    write_update_state
    return 2
  fi

  detect_source
  detect_java

  prepare_app_store || true

  case "$UPDATE_MODE" in
    java-only)
      APP_ENABLED=no
      APP_ROOT_RESULT=skipped
      APP_TLS_RESULT=skipped
      APP_WSS_RESULT=skipped
      ;;
    with-keystore)
      if [ "$APP_ENABLED" != yes ]; then
        printf '%s\n' \
          'BŁĄD: nie wykryto obsługiwanego magazynu aplikacji JKS/PKCS12.' >&2

        APP_ROOT_RESULT=error
        APP_TLS_RESULT=error
        APP_WSS_RESULT=error
        UPDATE_RESULT=UNKNOWN

        write_update_state
        update_log 'update aborted: application keystore not detected'
        return 2
      fi
      ;;
    auto)
      if [ "$APP_ENABLED" != yes ]; then
        APP_ROOT_RESULT=skipped
        APP_TLS_RESULT=skipped
        APP_WSS_RESULT=skipped
      fi
      ;;
  esac

  if [ "$APP_ENABLED" = yes ]; then
    update_log "updating application truststore: $SERVER_TRUST_TYPE"

    update_store_pair \
      app \
      "$APP_STORE" \
      "$SERVER_TRUST_TYPE" \
      "$SERVER_TRUST_PASSWORD" \
      "$APP_CONTAINER"

    if results_ok \
      "$APP_ROOT_RESULT" \
      "$APP_TLS_RESULT" \
      "$APP_WSS_RESULT"; then
      app_ok=yes
    else
      app_ok=no
    fi
  fi

  if [ "$JAVA_DETECTED" = yes ] &&
     [ -n "$JAVA_CACERTS" ] &&
     [ -n "${JAVA_KEYTOOL:-}" ] &&
     [ -x "$JAVA_KEYTOOL" ]; then

    update_log "updating host Java cacerts: $JAVA_CACERTS"

    update_store_pair \
      java \
      "$JAVA_CACERTS" \
      "" \
      changeit \
      "$java_container"

    if results_ok \
      "$JAVA_ROOT_RESULT" \
      "$JAVA_TLS_RESULT" \
      "$JAVA_WSS_RESULT"; then
      java_ok=yes
    fi
  else
    JAVA_ROOT_RESULT=error
    JAVA_TLS_RESULT=error
    JAVA_WSS_RESULT=error
    update_log 'host Java cacerts or matching host Java keytool not detected'
  fi

  if [ "$java_ok" = yes ] && [ "$app_ok" = yes ]; then
    UPDATE_RESULT=OK
  else
    UPDATE_RESULT=UNKNOWN
  fi

  refresh_update_presence \
    "$APP_ENABLED" \
    "$APP_STORE" \
    "$APP_CONTAINER"

  write_update_state
  update_log "update finished result=$UPDATE_RESULT"

  printf 'Tryb update: %s\n' "$UPDATE_MODE"

  if [ "$APP_ENABLED" = yes ]; then
    printf \
      'Magazyn aplikacji (%s):\n  RootCA 2025: %s\n  SubCA TLS 2025: %s\n  SubCA WSS 2025: %s\n' \
      "$SERVER_TRUST_TYPE" \
      "$(result_label "$APP_ROOT_RESULT")" \
      "$(result_label "$APP_TLS_RESULT")" \
      "$(result_label "$APP_WSS_RESULT")"
  else
    printf \
      'Magazyn aplikacji:\n  RootCA 2025: %s\n  SubCA TLS 2025: %s\n  SubCA WSS 2025: %s\n' \
      "$(result_label "$APP_ROOT_RESULT")" \
      "$(result_label "$APP_TLS_RESULT")" \
      "$(result_label "$APP_WSS_RESULT")"
  fi

  printf \
    'Host Java cacerts:\n  Ścieżka: %s\n  RootCA 2025: %s\n  SubCA TLS 2025: %s\n  SubCA WSS 2025: %s\nWynik update: %s\n' \
    "${JAVA_CACERTS:-NIE WYKRYTO}" \
    "$(result_label "$JAVA_ROOT_RESULT")" \
    "$(result_label "$JAVA_TLS_RESULT")" \
    "$(result_label "$JAVA_WSS_RESULT")" \
    "$UPDATE_RESULT"

  if [ -n "$UPDATE_BACKUP_DIR" ]; then
    printf 'Backup: %s\n' "$UPDATE_BACKUP_DIR"
  fi

  if [ "$UPDATE_RESULT" = OK ]; then
    printf '%s\n' \
      'Zmiany zapisane. Jeżeli aplikacja korzysta z aktualizowanego magazynu, wykonaj jej kontrolowany restart.'
    return 0
  fi

  return 1
}

if [ "${P1CERT_UPDATE_LIB_ONLY:-0}" != 1 ]; then
  run_update "$@"
fi
