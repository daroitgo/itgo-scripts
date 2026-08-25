#!/usr/bin/env bash
# shellcheck shell=bash
# Read-only P1 certificate audit. Configuration passwords are only passed in memory.

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

# shellcheck disable=SC1090
[ -r "$VERSION_FILE" ] && . "$VERSION_FILE"
P1CERT_VERSION="${P1CERT_VERSION:-UNKNOWN}"

OLD_ROOT="99:4F:28:C4:3C:14:C8:F2:F4:58:32:B0:BC:86:73:63:90:AE:CB:DA:3E:C0:01:A5:2A:18:89:37:E5:69:80:9A"
OLD_TLS="E8:89:09:36:20:E6:94:88:91:EB:7E:C4:D8:55:7D:68:12:3C:E9:5D:4B:CB:47:51:11:62:B5:1E:B0:C0:67:0A"
OLD_WSS="A5:E9:3B:48:BB:93:64:52:35:B4:07:42:63:F8:11:EB:E9:7C:81:6D:AB:09:B3:97:00:CF:7F:65:8F:86:45:C5"
NEW_ROOT="AC:81:66:C6:28:72:12:B6:81:37:3C:73:C1:0F:39:8C:6C:AB:A2:1D:96:80:3E:27:4C:1C:0C:3E:65:5C:9D:71"
NEW_TLS="71:E9:50:33:45:D9:76:50:8C:B2:22:66:A8:11:E1:FC:66:B9:7D:DF:FA:3C:20:BF:D0:97:11:34:01:0E:3C:18"
NEW_WSS="CD:FF:4A:A7:5E:6F:A0:67:AE:5D:F4:22:20:72:AE:79:D3:3A:81:4F:2D:79:2D:C1:F3:9E:A8:1B:90:63:B7:C8"

P1_USED="no"
SOURCE_TYPE="UNKNOWN"
SOURCE_PATH=""
SOURCE_PASSWORD=""
SOURCE_CONTAINER=""
APP_DIR=""
OLD_ROOT_PRESENT="UNKNOWN"
OLD_TLS_PRESENT="UNKNOWN"
OLD_WSS_PRESENT="UNKNOWN"
NEW_ROOT_PRESENT="UNKNOWN"
NEW_TLS_PRESENT="UNKNOWN"
NEW_WSS_PRESENT="UNKNOWN"
JAVA_DETECTED="no"
JAVA_LABEL="NIE WYKRYTO"
JAVA_CACERTS=""
JAVA_P1="UNKNOWN"
AUDIT_RESULT="OK"

log() {
  # Arguments must never contain configuration values or passwords.
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

config_value() {
  # Read only a literal KEY=value entry; never source application configuration.
  local file="$1" key="$2" value
  [ -r "$file" ] || return 0
  value="$(awk -v wanted="$key" '
    $0 ~ "^[[:space:]]*(-[[:space:]]+)?(export[[:space:]]+)?" wanted "[[:space:]]*=" {
      sub("^[[:space:]]*(-[[:space:]]+)?(export[[:space:]]+)?" wanted "[[:space:]]*=[[:space:]]*", "")
      print; exit
    }' "$file")"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

resolve_config_path() {
  local base_dir="$1" value="$2"
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *)
      while [ "${value#./}" != "$value" ]; do value="${value#./}"; done
      printf '%s/%s\n' "${base_dir%/}" "$value"
      ;;
  esac
}

docker_backend() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s\n' 'docker-compose-plugin'
  elif command -v docker-compose >/dev/null 2>&1; then
    printf '%s\n' 'docker-compose-legacy'
  elif command -v docker >/dev/null 2>&1; then
    printf '%s\n' 'docker-without-compose'
  else
    printf '%s\n' 'docker-unavailable'
  fi
}

path_from_p1adapter() {
  local env_file="$1" folder file
  folder="$(config_value "$env_file" KEYSTORES_FOLDER)"
  file="$(config_value "$env_file" KEYSTORE_FILE)"
  SOURCE_TYPE="$(config_value "$env_file" KEYSTORE_TYPE)"
  SOURCE_PASSWORD="$(config_value "$env_file" KEYSTORE_PASSWORD)"
  [ -n "$SOURCE_TYPE" ] || SOURCE_TYPE="JKS"
  if [ -n "$file" ]; then
    case "$file" in
      /*) SOURCE_PATH="$file" ;;
      *) SOURCE_PATH="$(resolve_config_path /srv/P1ADAPTER "${folder%/}/$file")" ;;
    esac
  fi
}

detect_source() {
  local env_file compose_file value
  if [ -d /srv/P1ADAPTER ]; then
    APP_DIR=/srv/P1ADAPTER
    env_file=/srv/P1ADAPTER/.env
    path_from_p1adapter "$env_file"
    if [ -n "$SOURCE_PATH" ]; then
      P1_USED="yes"
      log 'P1ADAPTER active source found in .env'
      return 0
    fi
    # Some deployments keep values directly in the compose environment block.
    for compose_file in /srv/P1ADAPTER/docker-compose.yml /srv/P1ADAPTER/compose.yml /srv/P1ADAPTER/compose.yaml; do
      [ -r "$compose_file" ] || continue
      value="$(config_value "$compose_file" KEYSTORE_FILE)"
      if [ -n "$value" ]; then
        SOURCE_PATH="$(resolve_config_path "$APP_DIR" "$value")"
        SOURCE_TYPE="$(config_value "$compose_file" KEYSTORE_TYPE)"
        [ -n "$SOURCE_TYPE" ] || SOURCE_TYPE="JKS"
        P1_USED="yes"
        log 'P1ADAPTER active source found in compose configuration'
        return 0
      fi
    done
    P1_USED="unknown"
    AUDIT_RESULT="UNKNOWN"
    log 'P1ADAPTER directory present but no active keystore configuration found'
    return 0
  fi

  if [ -d /srv/P1CER ]; then
    APP_DIR=/srv/P1CER
    for compose_file in /srv/P1CER/docker-compose.yml /srv/P1CER/compose.yml /srv/P1CER/compose.yaml; do
      [ -r "$compose_file" ] || continue
      SOURCE_PATH="$(config_value "$compose_file" CSIOZ_EREJESTRACJA_TRUSTSTORE_PATH)"
      SOURCE_PASSWORD="$(config_value "$compose_file" CSIOZ_EREJESTRACJA_TRUSTSTORE_PASSWORD)"
      SOURCE_TYPE="$(config_value "$compose_file" CSIOZ_EREJESTRACJA_TRUSTSTORE_TYPE)"
      if [ -n "$SOURCE_PATH" ]; then
        SOURCE_PATH="$(resolve_config_path "$APP_DIR" "$SOURCE_PATH")"
        [ -n "$SOURCE_TYPE" ] || SOURCE_TYPE="PKCS12"
        P1_USED="yes"
        log 'P1CER active truststore found in compose configuration'
        return 0
      fi
      # A directly configured TLS/WSS certificate is still an active P1 source.
      for value in CSIOZ_EREJESTRACJA_SSL_KEYSTORE_PATH CSIOZ_EREJESTRACJA_TLS_KEYSTORE_PATH CSIOZ_EREJESTRACJA_WSS_KEYSTORE_PATH; do
        SOURCE_PATH="$(config_value "$compose_file" "$value")"
        case "$SOURCE_PATH" in
          *.pem|*.PEM|*.cer|*.CER|*.crt|*.CRT)
            SOURCE_PATH="$(resolve_config_path "$APP_DIR" "$SOURCE_PATH")"
            SOURCE_TYPE="PEM"
            P1_USED="yes"
            log 'P1CER active certificate source found in compose configuration'
            return 0
            ;;
        esac
      done
    done
    P1_USED="unknown"
    AUDIT_RESULT="UNKNOWN"
    log 'P1CER directory present but no active certificate configuration found'
  fi
}

find_container() {
  local container project_dir
  command -v docker >/dev/null 2>&1 || return 0
  # Prefer an exact bind-mount mapping; it identifies the application without
  # relying on a container name.
  for container in $(docker ps --format '{{.ID}}' 2>/dev/null); do
    if container_path "$container" >/dev/null 2>&1; then
      printf '%s\n' "$container"
      return 0
    fi
  done
  # Compose labels cover names such as pi-p1-erejestracja-provider.
  if [ -n "$APP_DIR" ]; then
    for container in $(docker ps --format '{{.ID}}' 2>/dev/null); do
      project_dir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container" 2>/dev/null || true)"
      if [ "$project_dir" = "$APP_DIR" ]; then
        printf '%s\n' "$container"
        return 0
      fi
    done
  fi
  # Last fallback is deliberately limited to an explicitly P1-named container.
  for container in $(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | awk '/p1adapter|p1cer|P1ADAPTER|P1CER/ {print $1}'); do
    printf '%s\n' "$container"
    return 0
  done
}

map_mounts_to_container_path() {
  local mounts="$1" source destination best_source="" best_destination="" candidate
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
  done <<EOF_MOUNTS
$mounts
EOF_MOUNTS
  [ -n "$best_source" ] || return 1
  candidate="${best_destination%/}${SOURCE_PATH#$best_source}"
  printf '%s\n' "$candidate"
}

container_path() {
  local container="$1" mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' "$container" 2>/dev/null || true)"
  map_mounts_to_container_path "$mounts"
}

mark_fingerprints() {
  local data="$1" fp
  for fp in "$OLD_ROOT" "$OLD_TLS" "$OLD_WSS" "$NEW_ROOT" "$NEW_TLS" "$NEW_WSS"; do
    if printf '%s\n' "$data" | grep -F -q "$fp"; then
      case "$fp" in
        "$OLD_ROOT") OLD_ROOT_PRESENT=yes ;; "$OLD_TLS") OLD_TLS_PRESENT=yes ;; "$OLD_WSS") OLD_WSS_PRESENT=yes ;;
        "$NEW_ROOT") NEW_ROOT_PRESENT=yes ;; "$NEW_TLS") NEW_TLS_PRESENT=yes ;; "$NEW_WSS") NEW_WSS_PRESENT=yes ;;
      esac
    else
      case "$fp" in
        "$OLD_ROOT") OLD_ROOT_PRESENT=no ;; "$OLD_TLS") OLD_TLS_PRESENT=no ;; "$OLD_WSS") OLD_WSS_PRESENT=no ;;
        "$NEW_ROOT") NEW_ROOT_PRESENT=no ;; "$NEW_TLS") NEW_TLS_PRESENT=no ;; "$NEW_WSS") NEW_WSS_PRESENT=no ;;
      esac
    fi
  done
}

audit_pem() {
  local output
  if ! command -v openssl >/dev/null 2>&1 || [ ! -r "$SOURCE_PATH" ]; then
    return 1
  fi
  output="$(openssl x509 -in "$SOURCE_PATH" -noout -fingerprint -sha256 2>/dev/null || true)"
  [ -n "$output" ] || return 1
  mark_fingerprints "$output"
}

audit_store() {
  local keytool_bin="" store_path="$SOURCE_PATH" output
  if command -v keytool >/dev/null 2>&1 && [ -r "$SOURCE_PATH" ]; then
    keytool_bin=keytool
  else
    SOURCE_CONTAINER="$(find_container)"
    if [ -n "$SOURCE_CONTAINER" ] && docker exec "$SOURCE_CONTAINER" sh -c 'command -v keytool >/dev/null 2>&1' >/dev/null 2>&1; then
      store_path="$(container_path "$SOURCE_CONTAINER")"
      output="$(printf '%s\n' "$SOURCE_PASSWORD" | docker exec -i "$SOURCE_CONTAINER" keytool -list -v -keystore "$store_path" -storetype "$SOURCE_TYPE" 2>/dev/null || true)"
      [ -n "$output" ] || return 1
      mark_fingerprints "$output"
      return 0
    fi
    return 1
  fi
  output="$(printf '%s\n' "$SOURCE_PASSWORD" | $keytool_bin -list -v -keystore "$store_path" -storetype "$SOURCE_TYPE" 2>/dev/null || true)"
  [ -n "$output" ] || return 1
  mark_fingerprints "$output"
}

detect_java() {
  local java_bin="" settings="" container=""
  # A discovered P1 container is authoritative; do not substitute a random
  # host JVM when the application is containerised.
  container="${SOURCE_CONTAINER:-$(find_container)}"
  if [ -n "$container" ] && docker exec "$container" sh -c 'command -v java >/dev/null 2>&1' >/dev/null 2>&1; then
    settings="$(docker exec "$container" java -XshowSettings:properties -version 2>&1 || true)"
    JAVA_DETECTED=yes
    JAVA_LABEL="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*java.vendor[[:space:]]*=/{v=$2} /^[[:space:]]*java.version[[:space:]]*=/{ver=$2} END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", ver); if (v != "" || ver != "") print v " " ver}')"
    JAVA_CACERTS="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*java.home[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 "/lib/security/cacerts"; exit}')"
    SOURCE_CONTAINER="$container"
    return 0
  fi
  java_bin="$(ps -eo pid=,args= 2>/dev/null | awk '/[j]ava/ && /\/srv\/P1(ADAPTER|CER)/ {print $1; exit}')"
  if [ -n "$java_bin" ] && [ -r "/proc/$java_bin/exe" ]; then
    java_bin="$(readlink -f "/proc/$java_bin/exe" 2>/dev/null || true)"
  else
    java_bin=""
  fi
  # Use PATH Java only when no P1 container was found; it is a host-only
  # diagnostic fallback for non-container deployments.
  if [ -z "$java_bin" ] && [ -z "$container" ] && command -v java >/dev/null 2>&1; then java_bin=java; fi
  if [ -n "$java_bin" ]; then
    settings="$($java_bin -XshowSettings:properties -version 2>&1 || true)"
    JAVA_DETECTED=yes
    JAVA_LABEL="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*java.vendor[[:space:]]*=/{v=$2} /^[[:space:]]*java.version[[:space:]]*=/{ver=$2} END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", ver); if (v != "" || ver != "") print v " " ver}')"
    JAVA_CACERTS="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*java.home[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 "/lib/security/cacerts"; exit}')"
    [ -f "$JAVA_CACERTS" ] || JAVA_CACERTS=""
    return 0
  fi
}

audit_java_cacerts() {
  local output
  [ "$JAVA_DETECTED" = yes ] && [ -n "$JAVA_CACERTS" ] || return 0
  if [ -n "$SOURCE_CONTAINER" ]; then
    docker exec "$SOURCE_CONTAINER" sh -c 'command -v keytool >/dev/null 2>&1' >/dev/null 2>&1 || return 0
    output="$(printf '%s\n' changeit | docker exec -i "$SOURCE_CONTAINER" keytool -list -v -keystore "$JAVA_CACERTS" 2>/dev/null || true)"
  elif command -v keytool >/dev/null 2>&1; then
    output="$(printf '%s\n' changeit | keytool -list -v -keystore "$JAVA_CACERTS" 2>/dev/null || true)"
  else
    return 0
  fi
  [ -n "$output" ] || return 0
  if printf '%s\n' "$output" | grep -F -e "$OLD_ROOT" -e "$OLD_TLS" -e "$OLD_WSS" -e "$NEW_ROOT" -e "$NEW_TLS" -e "$NEW_WSS" >/dev/null 2>&1; then
    JAVA_P1=yes
  else
    JAVA_P1=no
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
    [ "$P1_USED" = yes ] && {
      printf 'OLD_ROOT_PRESENT=%s\nOLD_TLS_PRESENT=%s\nOLD_WSS_PRESENT=%s\n' "$OLD_ROOT_PRESENT" "$OLD_TLS_PRESENT" "$OLD_WSS_PRESENT"
      printf 'NEW_ROOT_PRESENT=%s\nNEW_TLS_PRESENT=%s\nNEW_WSS_PRESENT=%s\n' "$NEW_ROOT_PRESENT" "$NEW_TLS_PRESENT" "$NEW_WSS_PRESENT"
    }
    printf 'JAVA_DETECTED=%s\n' "$JAVA_DETECTED"
    [ -n "$JAVA_CACERTS" ] && printf 'JAVA_CACERTS=%s\n' "$JAVA_CACERTS"
    printf 'AUDIT_RESULT=%s\nAUDIT_TIMESTAMP=%s\n' "$AUDIT_RESULT" "$(date '+%FT%T%z')"
  } > "$temp_file"
  mv -f "$temp_file" "$STATE_FILE"
  chmod 0644 "$STATE_FILE"
}

yesno() { case "$1" in yes) printf TAK;; no) printf NIE;; *) printf NIEZNANE;; esac; }

if [ "${P1CERT_LIB_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/p1cert-audit-$(date '+%Y%m%d_%H%M%S').log"
log 'audit started'
log "docker_backend=$(docker_backend)"
detect_source
if [ "$P1_USED" = yes ]; then SOURCE_CONTAINER="$(find_container)"; fi
if [ "$P1_USED" = yes ]; then
  case "$SOURCE_TYPE" in
    PEM|pem|CER|cer|CRT|crt)
      audit_pem || { AUDIT_RESULT=UNKNOWN; log 'active PEM source could not be inspected'; }
      ;;
    *)
      audit_store || { AUDIT_RESULT=UNKNOWN; log 'active keystore could not be inspected with available keytool'; }
      ;;
  esac
fi
detect_java
audit_java_cacerts
write_state
log "audit finished result=$AUDIT_RESULT p1_used=$P1_USED"

printf 'P1CERT %s\n' "$P1CERT_VERSION"
printf 'Host: %s\n' "$(hostname 2>/dev/null || printf UNKNOWN)"
printf 'P1: %s\n' "$(yesno "$P1_USED")"
if [ "$P1_USED" = yes ]; then
  printf 'Typ: %s\nŹródło: %s\n' "$SOURCE_TYPE" "$SOURCE_PATH"
  printf 'Stary RootCA: %s\nStary SubCA TLS: %s\nStary SubCA WSS: %s\n' "$(yesno "$OLD_ROOT_PRESENT")" "$(yesno "$OLD_TLS_PRESENT")" "$(yesno "$OLD_WSS_PRESENT")"
  printf 'Nowy RootCA 2025: %s\nNowy SubCA TLS 2025: %s\nNowy SubCA WSS 2025: %s\n' "$(yesno "$NEW_ROOT_PRESENT")" "$(yesno "$NEW_TLS_PRESENT")" "$(yesno "$NEW_WSS_PRESENT")"
fi
printf 'Java: %s\n' "$JAVA_LABEL"
printf 'Java cacerts: %s\n' "${JAVA_CACERTS:-NIE WYKRYTO}"
printf 'P1 w Java cacerts: %s\n' "$(yesno "$JAVA_P1")"
printf 'Wynik audytu: %s\n' "$AUDIT_RESULT"
