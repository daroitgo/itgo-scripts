#!/usr/bin/env bash
# shellcheck shell=bash
# Read-only P1 certificate audit. Targets are read from the versioned payload.

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
VERSION_FILE="$MODULE_DIR/p1cert.version"
LOG_DIR="$MODULE_DIR/logs"
STATE_DIR="$MODULE_DIR/state"
STATE_FILE="$STATE_DIR/p1cert-state"
[ -r "$VERSION_FILE" ] && . "$VERSION_FILE"
P1CERT_VERSION="${P1CERT_VERSION:-UNKNOWN}"

P1_USED=no
SOURCE_TYPE=UNKNOWN
SOURCE_PATH=""
SOURCE_PASSWORD=""
SOURCE_CONTAINER=""
APP_DIR=""
PAYLOAD_ID=""
PAYLOAD_CHANGE_AT=""
SERVER_CERT_MODE=""
PRESERVE_WSS=""
PAYLOAD_ZIP=""
PAYLOAD_TMP=""
PAYLOAD_ERROR=""
TARGET_ROOT_FP=""
TARGET_TLS_FP=""
SERVER_CERT_FP=""
TARGET_ROOT_PRESENT=unknown
TARGET_TLS_PRESENT=unknown
SERVER_CERT_TARGET_PRESENT=unknown
JAVA_DETECTED=no
JAVA_LABEL='NIE WYKRYTO'
JAVA_CACERTS=""
JAVA_TARGET_ROOT_PRESENT=unknown
JAVA_TARGET_TLS_PRESENT=unknown
AUDIT_RESULT=OK

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}
payload_fail() {
  PAYLOAD_ERROR="$1"
  AUDIT_RESULT=UNKNOWN
  log "payload error: $1"
}
cleanup() {
  if [ -n "$PAYLOAD_TMP" ] && [ -d "$PAYLOAD_TMP" ]; then
    rm -rf "$PAYLOAD_TMP"
  fi
}
trap cleanup EXIT HUP INT TERM
yesno() {
  case "$1" in
    yes) printf TAK ;;
    no) printf NIE ;;
    *) printf NIEZNANE ;;
  esac
}

config_value() {
  local file="$1" key="$2" value
  [ -r "$file" ] || return 0
  value="$(awk -v wanted="$key" '$0 ~ "^[[:space:]]*(-[[:space:]]+)?(export[[:space:]]+)?" wanted "[[:space:]]*=" { sub("^[[:space:]]*(-[[:space:]]+)?(export[[:space:]]+)?" wanted "[[:space:]]*=[[:space:]]*", ""); print; exit }' "$file")"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

resolve_config_path() {
  local base_dir="$1" value="$2"
  case "$value" in
    /*)
      printf '%s\n' "$value"
      ;;
    *)
      while [ "${value#./}" != "$value" ]; do
        value="${value#./}"
      done
      printf '%s/%s\n' "${base_dir%/}" "$value"
      ;;
  esac
}

docker_backend() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s\n' docker-compose-plugin
  elif command -v docker-compose >/dev/null 2>&1; then
    printf '%s\n' docker-compose-legacy
  elif command -v docker >/dev/null 2>&1; then
    printf '%s\n' docker-without-compose
  else
    printf '%s\n' docker-unavailable
  fi
}

safe_payload_path() {
  case "$1" in ""|/*|*\\*|*".."*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  return 0
}
find_payload() {
  local path
  for path in "$MODULE_DIR/certs/p1-production-certs.zip" "$SCRIPT_DIR/certs/p1-production-certs.zip"; do
    if [ -r "$path" ]; then
      PAYLOAD_ZIP="$path"
      return 0
    fi
  done
  return 1
}

manifest_value() {
  awk -F= -v wanted="$2" '$1 == wanted { print substr($0, length(wanted) + 2); exit }' "$1"
}
validate_manifest() {
  local file="$1" key value
  awk '/^[[:space:]]*($|#)/ { next } /^[A-Z_]+=[^[:cntrl:]]*$/ { key=$0; sub(/=.*/, "", key); if (key !~ /^(PAYLOAD_SCHEMA|PAYLOAD_ID|CHANGE_AT|TARGET_ROOT_FILE|TARGET_TLS_FILE|SERVER_CERT_MODE|SERVER_CERT_FILE|PRESERVE_WSS)$/ || ++seen[key] > 1) exit 1; next } { exit 1 }' "$file" || return 1
  for key in PAYLOAD_SCHEMA PAYLOAD_ID TARGET_ROOT_FILE TARGET_TLS_FILE SERVER_CERT_MODE PRESERVE_WSS CHANGE_AT; do value="$(manifest_value "$file" "$key")"; [ -n "$value" ] || return 1; done
  [ "$(manifest_value "$file" PAYLOAD_SCHEMA)" = 1 ] || return 1
  case "$(manifest_value "$file" SERVER_CERT_MODE)" in preserve|replace) ;; *) return 1 ;; esac
  case "$(manifest_value "$file" PRESERVE_WSS)" in true|false) ;; *) return 1 ;; esac
  [ "$(manifest_value "$file" SERVER_CERT_MODE)" != replace ] || [ -n "$(manifest_value "$file" SERVER_CERT_FILE)" ] || return 1
}
extract_file() {
  local entry="$1" destination="$2"
  safe_payload_path "$entry" || return 1
  unzip -p "$PAYLOAD_ZIP" "$entry" > "$destination" 2>/dev/null
  [ -s "$destination" ]
}
read_certificate() {
  local file="$1" type="$2" data fingerprint subject issuer not_before not_after
  data="$(openssl x509 -in "$file" -noout -fingerprint -sha256 -subject -issuer -startdate -enddate 2>/dev/null)" || \
    data="$(openssl x509 -inform DER -in "$file" -noout -fingerprint -sha256 -subject -issuer -startdate -enddate 2>/dev/null)" || return 1
  fingerprint="$(printf '%s\n' "$data" | awk -F= '{ field=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", field); if (tolower(field) == "sha256 fingerprint") { print toupper($2); exit } }')"
  subject="$(printf '%s\n' "$data" | sed -n 's/^subject=//p')"; issuer="$(printf '%s\n' "$data" | sed -n 's/^issuer=//p')"
  not_before="$(printf '%s\n' "$data" | sed -n 's/^notBefore=//p')"; not_after="$(printf '%s\n' "$data" | sed -n 's/^notAfter=//p')"
  [ -n "$fingerprint" ] && [ -n "$subject" ] && [ -n "$issuer" ] && [ -n "$not_before" ] && [ -n "$not_after" ] || return 1
  case "$type" in ROOT) TARGET_ROOT_FP="$fingerprint" ;; TLS) TARGET_TLS_FP="$fingerprint" ;; SERVER) SERVER_CERT_FP="$fingerprint" ;; esac
}
load_payload() {
  local manifest root_file tls_file server_file
  command -v unzip >/dev/null 2>&1 || { payload_fail 'unzip unavailable'; return; }
  command -v openssl >/dev/null 2>&1 || { payload_fail 'openssl unavailable'; return; }
  find_payload || { payload_fail 'payload ZIP missing'; return; }
  PAYLOAD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/p1cert.XXXXXX")" || { payload_fail 'cannot create temporary directory'; return; }
  manifest="$PAYLOAD_TMP/manifest.env"; extract_file manifest.env "$manifest" || { payload_fail 'manifest.env missing from payload'; return; }
  validate_manifest "$manifest" || { payload_fail 'invalid manifest.env'; return; }
  PAYLOAD_ID="$(manifest_value "$manifest" PAYLOAD_ID)"; PAYLOAD_CHANGE_AT="$(manifest_value "$manifest" CHANGE_AT)"
  SERVER_CERT_MODE="$(manifest_value "$manifest" SERVER_CERT_MODE)"; PRESERVE_WSS="$(manifest_value "$manifest" PRESERVE_WSS)"
  root_file="$(manifest_value "$manifest" TARGET_ROOT_FILE)"; tls_file="$(manifest_value "$manifest" TARGET_TLS_FILE)"; server_file="$(manifest_value "$manifest" SERVER_CERT_FILE)"
  safe_payload_path "$root_file" && safe_payload_path "$tls_file" || { payload_fail 'unsafe target path in manifest'; return; }
  extract_file "$root_file" "$PAYLOAD_TMP/root.pem" || { payload_fail 'target RootCA missing from payload'; return; }
  extract_file "$tls_file" "$PAYLOAD_TMP/tls.pem" || { payload_fail 'target SubCA TLS missing from payload'; return; }
  read_certificate "$PAYLOAD_TMP/root.pem" ROOT || { payload_fail 'cannot read target RootCA certificate'; return; }
  read_certificate "$PAYLOAD_TMP/tls.pem" TLS || { payload_fail 'cannot read target SubCA TLS certificate'; return; }
  if [ "$SERVER_CERT_MODE" = replace ]; then safe_payload_path "$server_file" || { payload_fail 'unsafe server certificate path in manifest'; return; }; extract_file "$server_file" "$PAYLOAD_TMP/server.pem" || { payload_fail 'target server certificate missing from payload'; return; }; read_certificate "$PAYLOAD_TMP/server.pem" SERVER || { payload_fail 'cannot read target server certificate'; return; }; fi
}

path_from_p1adapter() {
  local file="$1"
  local folder
  local store

  folder="$(config_value "$file" KEYSTORES_FOLDER)"
  store="$(config_value "$file" KEYSTORE_FILE)"
  SOURCE_TYPE="$(config_value "$file" KEYSTORE_TYPE)"
  SOURCE_PASSWORD="$(config_value "$file" KEYSTORE_PASSWORD)"
  [ -n "$SOURCE_TYPE" ] || SOURCE_TYPE=JKS

  if [ -n "$store" ]; then
    case "$store" in
      /*) SOURCE_PATH="$store" ;;
      *) SOURCE_PATH="$(resolve_config_path /srv/P1ADAPTER "${folder%/}/$store")" ;;
    esac
  fi
}
detect_source() {
  local file value
  if [ -d /srv/P1ADAPTER ]; then APP_DIR=/srv/P1ADAPTER; path_from_p1adapter /srv/P1ADAPTER/.env; if [ -n "$SOURCE_PATH" ]; then P1_USED=yes; return 0; fi; for file in /srv/P1ADAPTER/docker-compose.yml /srv/P1ADAPTER/compose.yml /srv/P1ADAPTER/compose.yaml; do [ -r "$file" ] || continue; value="$(config_value "$file" KEYSTORE_FILE)"; if [ -n "$value" ]; then SOURCE_PATH="$(resolve_config_path "$APP_DIR" "$value")"; SOURCE_TYPE="$(config_value "$file" KEYSTORE_TYPE)"; [ -n "$SOURCE_TYPE" ] || SOURCE_TYPE=JKS; P1_USED=yes; return 0; fi; done; P1_USED=unknown; AUDIT_RESULT=UNKNOWN; return 0; fi
  if [ -d /srv/P1CER ]; then APP_DIR=/srv/P1CER; for file in /srv/P1CER/docker-compose.yml /srv/P1CER/compose.yml /srv/P1CER/compose.yaml; do [ -r "$file" ] || continue; SOURCE_PATH="$(config_value "$file" CSIOZ_EREJESTRACJA_TRUSTSTORE_PATH)"; SOURCE_PASSWORD="$(config_value "$file" CSIOZ_EREJESTRACJA_TRUSTSTORE_PASSWORD)"; SOURCE_TYPE="$(config_value "$file" CSIOZ_EREJESTRACJA_TRUSTSTORE_TYPE)"; if [ -n "$SOURCE_PATH" ]; then SOURCE_PATH="$(resolve_config_path "$APP_DIR" "$SOURCE_PATH")"; [ -n "$SOURCE_TYPE" ] || SOURCE_TYPE=PKCS12; P1_USED=yes; return 0; fi; for value in CSIOZ_EREJESTRACJA_SSL_KEYSTORE_PATH CSIOZ_EREJESTRACJA_TLS_KEYSTORE_PATH CSIOZ_EREJESTRACJA_WSS_KEYSTORE_PATH; do SOURCE_PATH="$(config_value "$file" "$value")"; case "$SOURCE_PATH" in *.pem|*.PEM|*.cer|*.CER|*.crt|*.CRT) SOURCE_PATH="$(resolve_config_path "$APP_DIR" "$SOURCE_PATH")"; SOURCE_TYPE=PEM; P1_USED=yes; return 0 ;; esac; done; done; P1_USED=unknown; AUDIT_RESULT=UNKNOWN; fi
}

map_mounts_to_container_path() {
  local mounts="$1"
  local source
  local destination
  local best_source=""
  local best_destination=""

  while IFS='|' read -r source destination; do
    [ -n "$source" ] && [ -n "$destination" ] || continue
    case "$SOURCE_PATH" in
      "$source"|"$source"/*)
        if [ "${#source}" -gt "${#best_source}" ]; then
          best_source="$source"
          best_destination="$destination"
        fi
        ;;
    esac
  done <<EOF
$mounts
EOF
  [ -n "$best_source" ] || return 1
  printf '%s\n' "${best_destination%/}${SOURCE_PATH#$best_source}"
}

container_path() {
  local container="$1"
  local mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' "$container" 2>/dev/null || true)"
  map_mounts_to_container_path "$mounts"
}
find_container() {
  local container
  local project_dir
  command -v docker >/dev/null 2>&1 || return 0
  for container in $(docker ps --format '{{.ID}}' 2>/dev/null); do
    if container_path "$container" >/dev/null 2>&1; then
      printf '%s\n' "$container"
      return 0
    fi
  done
  if [ -n "$APP_DIR" ]; then
    for container in $(docker ps --format '{{.ID}}' 2>/dev/null); do
      project_dir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container" 2>/dev/null || true)"
      if [ "$project_dir" = "$APP_DIR" ]; then
        printf '%s\n' "$container"
        return 0
      fi
    done
  fi
  docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk '/p1adapter|p1cer|P1ADAPTER|P1CER/ {print $1; exit}'
}

mark_targets() {
  local data="$1"
  if printf '%s\n' "$data" | grep -F -q "$TARGET_ROOT_FP"; then TARGET_ROOT_PRESENT=yes; else TARGET_ROOT_PRESENT=no; fi
  if printf '%s\n' "$data" | grep -F -q "$TARGET_TLS_FP"; then TARGET_TLS_PRESENT=yes; else TARGET_TLS_PRESENT=no; fi
}

audit_pem() {
  local output
  command -v openssl >/dev/null 2>&1 && [ -r "$SOURCE_PATH" ] || return 1
  output="$(openssl x509 -in "$SOURCE_PATH" -noout -fingerprint -sha256 2>/dev/null || true)"
  [ -n "$output" ] || return 1
  mark_targets "$output"
}
audit_store() {
  local keytool_bin=""
  local store_path="$SOURCE_PATH"
  local output

  if command -v keytool >/dev/null 2>&1 && [ -r "$SOURCE_PATH" ]; then
    keytool_bin=keytool
  else
    SOURCE_CONTAINER="$(find_container)"
    if [ -z "$SOURCE_CONTAINER" ] || ! docker exec "$SOURCE_CONTAINER" sh -c 'command -v keytool >/dev/null 2>&1' >/dev/null 2>&1; then
      return 1
    fi
    store_path="$(container_path "$SOURCE_CONTAINER")"
    output="$(printf '%s\n' "$SOURCE_PASSWORD" | docker exec -i "$SOURCE_CONTAINER" keytool -list -v -keystore "$store_path" -storetype "$SOURCE_TYPE" 2>/dev/null || true)"
    [ -n "$output" ] || return 1
    mark_targets "$output"
    return 0
  fi

  output="$(printf '%s\n' "$SOURCE_PASSWORD" | "$keytool_bin" -list -v -keystore "$store_path" -storetype "$SOURCE_TYPE" 2>/dev/null || true)"
  [ -n "$output" ] || return 1
  mark_targets "$output"
}

detect_java() {
  local java_bin=""
  local settings=""
  local container="${SOURCE_CONTAINER:-$(find_container)}"

  if [ -n "$container" ] && docker exec "$container" sh -c 'command -v java >/dev/null 2>&1' >/dev/null 2>&1; then
    settings="$(docker exec "$container" java -XshowSettings:properties -version 2>&1 || true)"
    SOURCE_CONTAINER="$container"
  else
    java_bin="$(ps -eo pid=,args= 2>/dev/null | awk '/[j]ava/ && /\/srv\/P1(ADAPTER|CER)/ {print $1; exit}')"
    if [ -n "$java_bin" ] && [ -r "/proc/$java_bin/exe" ]; then
      java_bin="$(readlink -f "/proc/$java_bin/exe" 2>/dev/null || true)"
    elif [ -z "$container" ] && command -v java >/dev/null 2>&1; then
      java_bin=java
    else
      return 0
    fi
    settings="$("$java_bin" -XshowSettings:properties -version 2>&1 || true)"
  fi

  JAVA_DETECTED=yes
  JAVA_LABEL="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*java.vendor[[:space:]]*=/{v=$2} /^[[:space:]]*java.version[[:space:]]*=/{x=$2} END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); print v " " x}')"
  JAVA_CACERTS="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*java.home[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 "/lib/security/cacerts"; exit}')"
  [ -n "$SOURCE_CONTAINER" ] || [ -f "$JAVA_CACERTS" ] || JAVA_CACERTS=""
}

audit_java_cacerts() {
  local output

  [ "$JAVA_DETECTED" = yes ] && [ -n "$JAVA_CACERTS" ] || return 0
  if [ -n "$SOURCE_CONTAINER" ]; then
    docker exec "$SOURCE_CONTAINER" sh -c 'command -v keytool >/dev/null 2>&1' >/dev/null 2>&1 || return 0
    output="$(printf '%s\n' changeit | docker exec -i "$SOURCE_CONTAINER" keytool -list -v -keystore "$JAVA_CACERTS" 2>/dev/null || true)"
  else
    command -v keytool >/dev/null 2>&1 || return 0
    output="$(printf '%s\n' changeit | keytool -list -v -keystore "$JAVA_CACERTS" 2>/dev/null || true)"
  fi
  [ -n "$output" ] || return 0
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
}

write_state() {
  local temp_file

  mkdir -p "$STATE_DIR"
  temp_file="$STATE_FILE.$$.tmp"
  umask 077
  {
    printf 'P1_USED=%s\n' "$P1_USED"
    [ -n "$SOURCE_PATH" ] && printf 'SOURCE_TYPE=%s\nSOURCE_PATH=%s\n' "$SOURCE_TYPE" "$SOURCE_PATH"
    [ -n "$PAYLOAD_ID" ] && printf 'PAYLOAD_ID=%s\nPAYLOAD_CHANGE_AT=%s\n' "$PAYLOAD_ID" "$PAYLOAD_CHANGE_AT"
    printf 'TARGET_ROOT_PRESENT=%s\nTARGET_TLS_PRESENT=%s\nSERVER_CERT_MODE=%s\nSERVER_CERT_TARGET_PRESENT=%s\nPRESERVE_WSS=%s\nJAVA_DETECTED=%s\n' "$TARGET_ROOT_PRESENT" "$TARGET_TLS_PRESENT" "${SERVER_CERT_MODE:-unknown}" "$SERVER_CERT_TARGET_PRESENT" "${PRESERVE_WSS:-unknown}" "$JAVA_DETECTED"
    [ -n "$JAVA_CACERTS" ] && printf 'JAVA_CACERTS=%s\n' "$JAVA_CACERTS"
    printf 'JAVA_TARGET_ROOT_PRESENT=%s\nJAVA_TARGET_TLS_PRESENT=%s\nAUDIT_RESULT=%s\nAUDIT_TIMESTAMP=%s\n' "$JAVA_TARGET_ROOT_PRESENT" "$JAVA_TARGET_TLS_PRESENT" "$AUDIT_RESULT" "$(date '+%FT%T%z')"
  } > "$temp_file"
  mv -f "$temp_file" "$STATE_FILE"
  chmod 0644 "$STATE_FILE"
}

if [ "${P1CERT_LIB_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
mkdir -p "$LOG_DIR" "$STATE_DIR"; LOG_FILE="$LOG_DIR/p1cert-audit-$(date '+%Y%m%d_%H%M%S').log"; log 'audit started'; log "docker_backend=$(docker_backend)"; load_payload; detect_source
if [ "$P1_USED" = yes ] && [ "$AUDIT_RESULT" != UNKNOWN ]; then SOURCE_CONTAINER="$(find_container)"; case "$SOURCE_TYPE" in PEM|pem|CER|cer|CRT|crt) audit_pem || { AUDIT_RESULT=UNKNOWN; log 'active PEM source could not be inspected'; } ;; *) audit_store || { AUDIT_RESULT=UNKNOWN; log 'active keystore could not be inspected'; } ;; esac; fi
detect_java; [ "$AUDIT_RESULT" = UNKNOWN ] || audit_java_cacerts; write_state; log "audit finished result=$AUDIT_RESULT p1_used=$P1_USED"
printf 'P1CERT %s\nHost: %s\nP1: %s\n' "$P1CERT_VERSION" "$(hostname 2>/dev/null || printf UNKNOWN)" "$(yesno "$P1_USED")"; [ -z "$SOURCE_PATH" ] || printf 'Typ: %s\nŹródło: %s\n' "$SOURCE_TYPE" "$SOURCE_PATH"
if [ -n "$PAYLOAD_ID" ]; then printf 'Payload: %s\nZmiana: %s\n' "$PAYLOAD_ID" "$PAYLOAD_CHANGE_AT"; else printf 'Payload: NIEZNANY (%s)\n' "${PAYLOAD_ERROR:-nie wykryto}"; fi
printf 'Docelowy RootCA: %s\nDocelowy SubCA TLS: %s\n' "$(yesno "$TARGET_ROOT_PRESENT")" "$(yesno "$TARGET_TLS_PRESENT")"
case "$SERVER_CERT_MODE" in preserve) printf 'Certyfikat serwera: ZACHOWAJ\n' ;; replace) printf 'Certyfikat serwera: target NIEZNANE\n' ;; *) printf 'Certyfikat serwera: NIEZNANE\n' ;; esac
if [ "$PRESERVE_WSS" = true ]; then printf 'WSS: ZACHOWAJ\n'; elif [ -n "$PRESERVE_WSS" ]; then printf 'WSS: polityka payloadu=%s\n' "$PRESERVE_WSS"; else printf 'WSS: NIEZNANE\n'; fi
printf 'Java: %s\nJava cacerts: %s\nDocelowy RootCA w Java cacerts: %s\nDocelowy SubCA TLS w Java cacerts: %s\nWynik audytu: %s\n' "$JAVA_LABEL" "${JAVA_CACERTS:-NIE WYKRYTO}" "$(yesno "$JAVA_TARGET_ROOT_PRESENT")" "$(yesno "$JAVA_TARGET_TLS_PRESENT")" "$AUDIT_RESULT"
