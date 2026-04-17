#!/usr/bin/env bash
set -euo pipefail

# ========= TSEQ (Tomcat Sequencer) Installer v3.12.3 =========
VERSION="3.12.3"
BASE_USER="itgo"
MODE="${1:-install}"

UTILITY_DIRNAME="UTILITY"
APP_DIRNAME="TSEQ"

SYSTEMD_UNIT="/etc/systemd/system/tseq.service"
WRAPPER_BIN="/usr/local/sbin/tseq"
WRAPPER_LINK="/usr/local/bin/tseq"

READY_REGEX_DEFAULT='Catalina\.start Server startup in \[[0-9]+\] milliseconds'
TIMEOUT_DEFAULT=0
ROTATE_LOGS_DEFAULT=1
POST_DELAY_DEFAULT=15
LOGS_PREV_KEEP_DEFAULT=1

need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "ERROR: uruchom jako root: sudo bash $0" >&2; exit 1; }; }

resolve_home() {
  local u="$1" h
  h="$(getent passwd "$u" | awk -F: '{print $6}')"
  [[ -n "${h:-}" ]] || { echo "ERROR: cannot resolve home for user '$u'" >&2; exit 1; }
  echo "$h"
}

BASE_HOME="$(resolve_home "$BASE_USER")"
BASE_DIR="${BASE_HOME}/${UTILITY_DIRNAME}/${APP_DIRNAME}"
BIN_DIR="$BASE_DIR/bin"
CFG_DIR="$BASE_DIR/config"
LOG_DIR="$BASE_DIR/logs"

REPORT_FILE="$LOG_DIR/tseq.log"
DISCOVERED_TSV="$CFG_DIR/discovered.tsv"
ORDER_FILE="$CFG_DIR/order.txt"
CONF_FILE="$CFG_DIR/tseq.conf"

SEQUENCER_SH="$BIN_DIR/tseq.sh"
BUILDER_SH="$BIN_DIR/tseq-build-conf.sh"
ORDER_TOOL_SH="$BIN_DIR/tseq-order.sh"

VERSION_FILE="$BASE_DIR/.tseq_version"

log() {
  mkdir -p "$LOG_DIR"
  printf "%s %s\n" "$(date "+%F %T")" "$*" | tee -a "$REPORT_FILE"
}

TTY="/dev/tty"
read_tty() {
  if [[ -r "$TTY" ]]; then
    read "$@" < "$TTY"
  else
    read "$@"
  fi
}

prompt_yn() {
  local q="${1:?}" def="${2:-N}" ans=""
  while true; do
    if [[ "$def" == "Y" ]]; then
      read_tty -r -p "$q [Y/n]: " ans || true
      ans="${ans:-Y}"
    else
      read_tty -r -p "$q [y/N]: " ans || true
      ans="${ans:-N}"
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Wpisz: y albo n." ;;
    esac
  done
}

prompt_int_default() {
  local q="${1:?}" def="${2:-0}" ans=""
  while true; do
    read_tty -r -p "$q [$def]: " ans || true
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]]; then
      echo "$ans"
      return 0
    fi
    echo "Podaj liczbę całkowitą (>=0)."
  done
}

ver_gt() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" == "$1" ]] && [[ "$1" != "$2" ]]
}

installed_version() {
  [[ -f "$VERSION_FILE" ]] && cat "$VERSION_FILE" || echo "0"
}

cleanup_old_legacy_backups() {
  rm -rf "${BASE_DIR}"_bak_* 2>/dev/null || true
  rm -f "${WRAPPER_BIN}.bak."* 2>/dev/null || true
  rm -f "${WRAPPER_LINK}.bak."* 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT}.bak."* 2>/dev/null || true
}

safe_backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  rm -f "${f}.bak" 2>/dev/null || true
  cp -a "$f" "${f}.bak"
}

pre_cleanup_if_newer() {
  local inst
  inst="$(installed_version)"

  if ver_gt "$VERSION" "$inst"; then
    local bk
    cleanup_old_legacy_backups

    systemctl stop tseq 2>/dev/null || true
    systemctl disable tseq 2>/dev/null || true
    systemctl reset-failed tseq 2>/dev/null || true

    safe_backup_file "$SYSTEMD_UNIT"
    safe_backup_file "$WRAPPER_BIN"
    safe_backup_file "$WRAPPER_LINK"

    rm -f "$SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "$WRAPPER_BIN" 2>/dev/null || true
    rm -f "$WRAPPER_LINK" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    if [[ -d "$BASE_DIR" ]]; then
      bk="${BASE_DIR}.bak"
      rm -rf "$bk" 2>/dev/null || true
      cp -a "$BASE_DIR" "$bk" 2>/dev/null || true
      rm -rf "$BASE_DIR"
    fi

    return 0
  fi

  echo "INFO: tseq already installed version=$inst, installer version=$VERSION -> no changes"
  return 1
}

uninstall_tseq() {
  need_root

  log "UNINSTALL v$VERSION: begin"
  log "USER: $BASE_USER"
  log "HOME: $BASE_HOME"
  log "BASE: $BASE_DIR"
  log "SERVICE: tseq.service"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop tseq 2>/dev/null || true
    systemctl disable tseq 2>/dev/null || true
    systemctl reset-failed tseq 2>/dev/null || true
  fi

  rm -f "$SYSTEMD_UNIT" 2>/dev/null || true
  rm -f "$WRAPPER_BIN" 2>/dev/null || true
  rm -f "$WRAPPER_LINK" 2>/dev/null || true
  rm -rf "$BASE_DIR" 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  echo "UNINSTALL: removed unit $SYSTEMD_UNIT (if present)"
  echo "UNINSTALL: removed wrapper $WRAPPER_BIN (if present)"
  echo "UNINSTALL: removed launcher link $WRAPPER_LINK (if present)"
  echo "UNINSTALL: removed base dir $BASE_DIR (if present)"
  echo "UNINSTALL: done"
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$BIN_DIR" "$CFG_DIR" "$LOG_DIR"
  chmod 0755 "$BASE_DIR" "$BIN_DIR" "$CFG_DIR" "$LOG_DIR" 2>/dev/null || true
}

list_services() {
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | sort -u
}

discover_tomcat_bases() {
  find /srv -maxdepth 10 -type f -name catalina.sh -path "/srv/IntegrationPlatform*/**/bin/catalina.sh" 2>/dev/null \
    | sed 's|/bin/catalina\.sh$||' \
    | sort -u
}

find_service_for_base() {
  local base="$1" svc
  while read -r svc; do
    if systemctl cat "$svc" 2>/dev/null | grep -Fq -- "$base"; then
      echo "$svc"
      return 0
    fi
  done < <(list_services)
  return 1
}

write_discovered_tsv() {
  echo -e "#service\ttomcat_base" >"$DISCOVERED_TSV"

  local mapped=0 base svc
  while read -r base; do
    [[ -n "${base:-}" ]] || continue

    if [[ -f "$base/.sequencer-ignore" ]]; then
      log "DISCOVER: IGNORED BY MARKER base=$base"
      continue
    fi

    if svc="$(find_service_for_base "$base")"; then
      echo -e "${svc}\t${base}" >>"$DISCOVERED_TSV"
      log "DISCOVER: OK service=${svc} base=${base}"
      mapped=1
    else
      log "DISCOVER: NO SERVICE MATCH base=${base}"
    fi
  done < <(discover_tomcat_bases)

  chmod 0644 "$DISCOVERED_TSV"
  [[ "$mapped" -eq 1 ]] || log "WARN: no Tomcat instances mapped to services."
}

platform_key_for_entry() {
  local svc="${1:-}" base="${2:-}" haystack
  haystack="$(printf '%s %s\n' "$svc" "$base" | tr '[:lower:]' '[:upper:]')"

  if [[ "$haystack" =~ INTEGRATIONPLATFORMNFZ|(^|[^A-Z0-9])NFZ([^A-Z0-9]|$) ]]; then
    echo "NFZ"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMPI|(^|[^A-Z0-9])PI([^A-Z0-9]|$) ]]; then
    echo "PI"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMADM|(^|[^A-Z0-9])ADM([^A-Z0-9]|$) ]]; then
    echo "ADM"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMSSO|(^|[^A-Z0-9])SSO([^A-Z0-9]|$) ]]; then
    echo "SSO"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMEUSL|(^|[^A-Z0-9])EUSL([^A-Z0-9]|$) ]]; then
    echo "EUSL"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMEREC|(^|[^A-Z0-9])EREC([^A-Z0-9]|$) ]]; then
    echo "EREC"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMMPI|(^|[^A-Z0-9])MPI([^A-Z0-9]|$) ]]; then
    echo "MPI"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMHL7([^A-Z0-9]|$)|(^|[^A-Z0-9])HL7([^A-Z0-9]|$) ]]; then
    echo "HL7"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMHL7[A-Z0-9]+|(^|[^A-Z0-9])HL7[A-Z0-9]+([^A-Z0-9]|$) ]]; then
    echo "HL7*"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMERP|(^|[^A-Z0-9])ERP([^A-Z0-9]|$) ]]; then
    echo "ERP"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMZSMOPL|(^|[^A-Z0-9])ZSMOPL([^A-Z0-9]|$) ]]; then
    echo "ZSMOPL"
  elif [[ "$haystack" =~ INTEGRATIONPLATFORMTS([^A-Z0-9]|$)|(^|[^A-Z0-9])TS([^A-Z0-9]|$) ]]; then
    echo "TS"
  else
    echo "OTHER"
  fi
}

platform_rank_for_key() {
  case "${1:-OTHER}" in
    NFZ) echo "010" ;;
    PI) echo "020" ;;
    ADM) echo "030" ;;
    SSO) echo "040" ;;
    EUSL) echo "050" ;;
    EREC) echo "060" ;;
    MPI) echo "070" ;;
    HL7) echo "080" ;;
    "HL7*") echo "090" ;;
    ERP) echo "100" ;;
    ZSMOPL) echo "110" ;;
    TS) echo "120" ;;
    *) echo "999" ;;
  esac
}

write_order_header() {
  cat <<EOF_ORDER_HEADER
# Kolejność: mniejszy numer = wcześniej
# Format: <NUMER> <USŁUGA> [POST_DELAY_S]
# lub: - <USŁUGA> (wyłączone)   lub # komentarz
# POST_DELAY_S = ile sekund czekać po markerze READY zanim odpali następną usługę
# Domyślna kolejność platform: NFZ, PI, ADM, SSO, EUSL, EREC, MPI, HL7, HL7*, ERP, ZSMOPL, TS

EOF_ORDER_HEADER
}

collect_sorted_discovered_entries() {
  [[ -f "$DISCOVERED_TSV" ]] || return 1

  local tmp svc base platform rank
  tmp="$(mktemp)"

  while IFS=$'\t' read -r svc base; do
    [[ -n "${svc:-}" ]] || continue
    [[ "$svc" =~ ^# ]] && continue
    [[ -d "${base:-}" ]] || { log "ORDER: missing tomcat base skipped: service=$svc base=${base:-?}"; continue; }
    platform="$(platform_key_for_entry "$svc" "$base")"
    rank="$(platform_rank_for_key "$platform")"
    printf "%s\t%s\t%s\t%s\n" "$rank" "$platform" "$svc" "$base" >>"$tmp"
  done < "$DISCOVERED_TSV"

  sort -t $'\t' -k1,1 -k2,2 -k3,3 "$tmp"
  rm -f "$tmp"
}

show_existing_order() {
  [[ -f "$ORDER_FILE" ]] || return 1

  echo
  echo "Aktualna kolejność:"
  awk 'NF && $0 !~ /^[[:space:]]*#/' "$ORDER_FILE" || true
  echo
}

interactive_configure_order() {
  [[ -t 0 || -r "$TTY" ]] || { log "ORDER: no TTY -> skip interactive"; return 0; }
  [[ -f "$DISCOVERED_TSV" ]] || { log "ORDER: missing discovered.tsv -> skip"; return 0; }

  log "ORDER: interactive setup started"

  if [[ -f "$ORDER_FILE" ]]; then
    show_existing_order
    if ! prompt_yn "TSEQ: order.txt już istnieje. Ustawić kolejność ponownie?" "N"; then
      log "ORDER: user kept existing order"
      return 0
    fi
  elif ! prompt_yn "TSEQ: Ustawić teraz kolejność i delay w order.txt (interaktywnie)?" "Y"; then
    log "ORDER: user skipped interactive setup"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  write_order_header >"$tmp"

  local n_default num delay svc base platform
  n_default=10

  while IFS=$'\t' read -r _rank platform svc base; do
    echo
    echo "Znaleziono: $svc"
    echo "Base:       $base"
    echo "Platforma:  $platform"

    if prompt_yn "Uwzględnić tę usługę w order.txt?" "Y"; then
      num="$(prompt_int_default "NUM (kolejność)" "$n_default")"
      delay="$(prompt_int_default "POST_DELAY_S (sekundy po READY)" "$POST_DELAY_DEFAULT")"
      printf "%s %s %s\n" "$num" "$svc" "$delay" >>"$tmp"
      log "ORDER: add $num $svc $delay"
      n_default=$((n_default+10))
    else
      printf -- "- %s\n" "$svc" >>"$tmp"
      log "ORDER: disabled $svc"
    fi
  done < <(collect_sorted_discovered_entries)

  mv "$tmp" "$ORDER_FILE"
  chmod 0644 "$ORDER_FILE"
  log "ORDER: written $ORDER_FILE"
}

write_builder() {
  cat >"$BUILDER_SH" <<EOF_BUILDER
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR}"
CFG_DIR="\$BASE_DIR/config"
LOG_DIR="\$BASE_DIR/logs"

DISCOVERED_TSV="\$CFG_DIR/discovered.tsv"
ORDER_FILE="\$CFG_DIR/order.txt"
CONF_FILE="\$CFG_DIR/tseq.conf"

REPORT_FILE="\$LOG_DIR/tseq.log"

READY_REGEX_DEFAULT='${READY_REGEX_DEFAULT}'
TIMEOUT_DEFAULT=${TIMEOUT_DEFAULT}
ROTATE_LOGS_DEFAULT=${ROTATE_LOGS_DEFAULT}
POST_DELAY_DEFAULT=${POST_DELAY_DEFAULT}
LOGS_PREV_KEEP_DEFAULT=${LOGS_PREV_KEEP_DEFAULT}

log() {
  mkdir -p "\$LOG_DIR"
  printf "%s %s\\n" "\$(date "+%F %T")" "\$*" | tee -a "\$REPORT_FILE"
}

[[ -f "\$DISCOVERED_TSV" ]] || { echo "ERROR: missing \$DISCOVERED_TSV" >&2; exit 1; }
[[ -f "\$ORDER_FILE" ]] || { echo "ERROR: missing \$ORDER_FILE" >&2; exit 1; }

declare -A MAP
while IFS=\$'\\t' read -r svc base; do
  [[ -n "\${svc:-}" ]] || continue
  [[ "\$svc" =~ ^# ]] && continue
  MAP["\$svc"]="\$base"
done <"\$DISCOVERED_TSV"

tmp="\$(mktemp)"
trap 'rm -f "\$tmp"' EXIT

while read -r line; do
  line="\${line//\$'\\r'/}"
  [[ -n "\$line" ]] || continue
  [[ "\$line" =~ ^[[:space:]]*# ]] && continue
  line="\${line#"\${line%%[![:space:]]*}"}"
  [[ -n "\$line" ]] || continue

  first="\$(awk '{print \$1}' <<<"\$line")"
  svc="\$(awk '{print \$2}' <<<"\$line")"
  delay="\$(awk '{print \$3}' <<<"\$line")"
  [[ -n "\${svc:-}" ]] || continue
  [[ -n "\${delay:-}" ]] || delay="\$POST_DELAY_DEFAULT"

  if [[ "\$first" == "-" ]]; then
    log "ORDER: disabled: \$svc"
    continue
  fi

    if [[ "\$first" =~ ^[0-9]+\$ ]]; then
      if [[ "\$svc" != *.service ]]; then
        try="\$svc.service"
        if [[ -n "\${MAP[\$try]:-}" ]]; then svc="\$try"; fi
      fi

      if [[ -n "\${MAP[\$svc]:-}" ]] && [[ -d "\${MAP[\$svc]}" ]]; then
        if [[ ! "\$delay" =~ ^[0-9]+\$ ]]; then
          log "ORDER: bad delay (using default=\$POST_DELAY_DEFAULT): \$svc delay='\$delay'"
          delay="\$POST_DELAY_DEFAULT"
        fi
        printf "%s\\t%s\\t%s\\n" "\$first" "\$svc" "\$delay" >>"\$tmp"
      else
        log "ORDER: listed but not mapped or base missing (ignored): \$svc"
      fi
    else
      log "ORDER: bad line ignored: \$line"
  fi
done <"\$ORDER_FILE"

sorted="\$(sort -n -k1,1 "\$tmp")"

mkdir -p "\$CFG_DIR"
{
  echo "# AUTO-GENERATED by tseq-build-conf.sh"
  echo "# Edit order: \$ORDER_FILE"
  echo "# Discovered map: \$DISCOVERED_TSV"
  echo
  echo "REPORT=\\"\$REPORT_FILE\\""
  echo "TIMEOUT=\$TIMEOUT_DEFAULT"
  echo "READY_REGEX='\$READY_REGEX_DEFAULT'"
  echo "ROTATE_LOGS=\$ROTATE_LOGS_DEFAULT"
  echo "POST_DELAY_DEFAULT=\$POST_DELAY_DEFAULT"
  echo "LOGS_PREV_KEEP=\$LOGS_PREV_KEEP_DEFAULT"
  echo
  echo "INSTANCES=("
  while IFS=\$'\\t' read -r num svc delay; do
    [[ -n "\$svc" ]] || continue
    printf '  "%s|%s|%s"\\n' "\$svc" "\${MAP[\$svc]}" "\$delay"
  done <<<"\$sorted"
  echo ")"
} >"\$CONF_FILE"

chmod 0644 "\$CONF_FILE"
log "CONF: generated \$CONF_FILE"
EOF_BUILDER

  chmod 0755 "$BUILDER_SH"
  log "OK: wrote builder $BUILDER_SH"
}

write_order_tool() {
  cat >"$ORDER_TOOL_SH" <<EOF_ORDER
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR}"
CFG_DIR="\$BASE_DIR/config"
LOG_DIR="\$BASE_DIR/logs"

DISCOVERED_TSV="\$CFG_DIR/discovered.tsv"
ORDER_FILE="\$CFG_DIR/order.txt"
REPORT_FILE="\$LOG_DIR/tseq.log"
BUILDER="\$BASE_DIR/bin/tseq-build-conf.sh"
POST_DELAY_DEFAULT=${POST_DELAY_DEFAULT}
TTY="/dev/tty"

log() {
  mkdir -p "\$LOG_DIR"
  printf "%s %s\\n" "\$(date "+%F %T")" "\$*" | tee -a "\$REPORT_FILE"
}

read_tty() {
  if [[ -r "\$TTY" ]]; then
    read "\$@" < "\$TTY"
  else
    read "\$@"
  fi
}

prompt_yn() {
  local q="\${1:?}" def="\${2:-N}" ans=""
  while true; do
    if [[ "\$def" == "Y" ]]; then
      read_tty -r -p "\$q [Y/n]: " ans || true
      ans="\${ans:-Y}"
    else
      read_tty -r -p "\$q [y/N]: " ans || true
      ans="\${ans:-N}"
    fi
    case "\${ans,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Wpisz: y albo n." ;;
    esac
  done
}

prompt_int_default() {
  local q="\${1:?}" def="\${2:-0}" ans=""
  while true; do
    read_tty -r -p "\$q [\$def]: " ans || true
    ans="\${ans:-\$def}"
    if [[ "\$ans" =~ ^[0-9]+\$ ]]; then
      echo "\$ans"
      return 0
    fi
    echo "Podaj liczbę całkowitą (>=0)."
  done
}

list_services() {
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print \$1}' | sort -u
}

discover_tomcat_bases() {
  find /srv -maxdepth 10 -type f -name catalina.sh -path "/srv/IntegrationPlatform*/**/bin/catalina.sh" 2>/dev/null \
    | sed 's|/bin/catalina\.sh$||' \
    | sort -u
}

find_service_for_base() {
  local base="\$1" svc
  while read -r svc; do
    if systemctl cat "\$svc" 2>/dev/null | grep -Fq -- "\$base"; then
      echo "\$svc"
      return 0
    fi
  done < <(list_services)
  return 1
}

write_discovered_tsv() {
  mkdir -p "\$CFG_DIR"
  echo -e "#service\ttomcat_base" >"\$DISCOVERED_TSV"

  local mapped=0 base svc
  while read -r base; do
    [[ -n "\${base:-}" ]] || continue

    if [[ -f "\$base/.sequencer-ignore" ]]; then
      log "DISCOVER: IGNORED BY MARKER base=\$base"
      continue
    fi

    if svc="\$(find_service_for_base "\$base")"; then
      echo -e "\${svc}\t\${base}" >>"\$DISCOVERED_TSV"
      log "DISCOVER: OK service=\${svc} base=\${base}"
      mapped=1
    else
      log "DISCOVER: NO SERVICE MATCH base=\$base"
    fi
  done < <(discover_tomcat_bases)

  chmod 0644 "\$DISCOVERED_TSV"
  [[ "\$mapped" -eq 1 ]] || log "WARN: no Tomcat instances mapped to services."
}

platform_key_for_entry() {
  local svc="\${1:-}" base="\${2:-}" haystack
  haystack="\$(printf '%s %s\\n' "\$svc" "\$base" | tr '[:lower:]' '[:upper:]')"

  if [[ "\$haystack" =~ INTEGRATIONPLATFORMNFZ|(^|[^A-Z0-9])NFZ([^A-Z0-9]|$) ]]; then
    echo "NFZ"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMPI|(^|[^A-Z0-9])PI([^A-Z0-9]|$) ]]; then
    echo "PI"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMADM|(^|[^A-Z0-9])ADM([^A-Z0-9]|$) ]]; then
    echo "ADM"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMSSO|(^|[^A-Z0-9])SSO([^A-Z0-9]|$) ]]; then
    echo "SSO"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMEUSL|(^|[^A-Z0-9])EUSL([^A-Z0-9]|$) ]]; then
    echo "EUSL"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMEREC|(^|[^A-Z0-9])EREC([^A-Z0-9]|$) ]]; then
    echo "EREC"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMMPI|(^|[^A-Z0-9])MPI([^A-Z0-9]|$) ]]; then
    echo "MPI"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMHL7([^A-Z0-9]|$)|(^|[^A-Z0-9])HL7([^A-Z0-9]|$) ]]; then
    echo "HL7"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMHL7[A-Z0-9]+|(^|[^A-Z0-9])HL7[A-Z0-9]+([^A-Z0-9]|$) ]]; then
    echo "HL7*"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMERP|(^|[^A-Z0-9])ERP([^A-Z0-9]|$) ]]; then
    echo "ERP"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMZSMOPL|(^|[^A-Z0-9])ZSMOPL([^A-Z0-9]|$) ]]; then
    echo "ZSMOPL"
  elif [[ "\$haystack" =~ INTEGRATIONPLATFORMTS([^A-Z0-9]|$)|(^|[^A-Z0-9])TS([^A-Z0-9]|$) ]]; then
    echo "TS"
  else
    echo "OTHER"
  fi
}

platform_rank_for_key() {
  case "\${1:-OTHER}" in
    NFZ) echo "010" ;;
    PI) echo "020" ;;
    ADM) echo "030" ;;
    SSO) echo "040" ;;
    EUSL) echo "050" ;;
    EREC) echo "060" ;;
    MPI) echo "070" ;;
    HL7) echo "080" ;;
    "HL7*") echo "090" ;;
    ERP) echo "100" ;;
    ZSMOPL) echo "110" ;;
    TS) echo "120" ;;
    *) echo "999" ;;
  esac
}

write_order_header() {
  cat <<'EOF_ORDER_HEADER'
# Kolejność: mniejszy numer = wcześniej
# Format: <NUMER> <USŁUGA> [POST_DELAY_S]
# lub: - <USŁUGA> (wyłączone)   lub # komentarz
# POST_DELAY_S = ile sekund czekać po markerze READY zanim odpali następną usługę
# Domyślna kolejność platform: NFZ, PI, ADM, SSO, EUSL, EREC, MPI, HL7, HL7*, ERP, ZSMOPL, TS

EOF_ORDER_HEADER
}

collect_sorted_discovered_entries() {
  [[ -f "\$DISCOVERED_TSV" ]] || return 1

  local tmp svc base platform rank
  tmp="\$(mktemp)"

  while IFS=\$'\\t' read -r svc base; do
    [[ -n "\${svc:-}" ]] || continue
    [[ "\$svc" =~ ^# ]] && continue
    [[ -d "\${base:-}" ]] || { log "ORDER: missing tomcat base skipped: service=\$svc base=\${base:-?}"; continue; }
    platform="\$(platform_key_for_entry "\$svc" "\$base")"
    rank="\$(platform_rank_for_key "\$platform")"
    printf "%s\\t%s\\t%s\\t%s\\n" "\$rank" "\$platform" "\$svc" "\$base" >>"\$tmp"
  done < "\$DISCOVERED_TSV"

  sort -t \$'\\t' -k1,1 -k2,2 -k3,3 "\$tmp"
  rm -f "\$tmp"
}

show_existing_order() {
  [[ -f "\$ORDER_FILE" ]] || return 1
  echo
  echo "Aktualna kolejność:"
  awk 'NF && \$0 !~ /^[[:space:]]*#/' "\$ORDER_FILE" || true
  echo
}

interactive_configure_order() {
  [[ -t 0 || -r "\$TTY" ]] || { echo "ERROR: brak TTY do interaktywnej konfiguracji" >&2; exit 1; }

  write_discovered_tsv

  if [[ ! -s "\$DISCOVERED_TSV" ]]; then
    echo "ERROR: brak wykrytych platform do ustawienia kolejności" >&2
    exit 1
  fi

  if [[ -f "\$ORDER_FILE" ]]; then
    show_existing_order
    if ! prompt_yn "TSEQ: order.txt już istnieje. Ustawić kolejność ponownie?" "N"; then
      log "ORDER: user kept existing order"
      exit 0
    fi
  fi

  local tmp n_default num delay svc base platform
  tmp="\$(mktemp)"
  write_order_header >"\$tmp"
  n_default=10

  while IFS=\$'\\t' read -r _rank platform svc base; do
    echo
    echo "Znaleziono: \$svc"
    echo "Base:       \$base"
    echo "Platforma:  \$platform"

    if prompt_yn "Uwzględnić tę usługę w order.txt?" "Y"; then
      num="\$(prompt_int_default "NUM (kolejność)" "\$n_default")"
      delay="\$(prompt_int_default "POST_DELAY_S (sekundy po READY)" "\$POST_DELAY_DEFAULT")"
      printf "%s %s %s\\n" "\$num" "\$svc" "\$delay" >>"\$tmp"
      log "ORDER: add \$num \$svc \$delay"
      n_default=\$((n_default+10))
    else
      printf -- "- %s\\n" "\$svc" >>"\$tmp"
      log "ORDER: disabled \$svc"
    fi
  done < <(collect_sorted_discovered_entries)

  mv "\$tmp" "\$ORDER_FILE"
  chmod 0644 "\$ORDER_FILE"
  log "ORDER: written \$ORDER_FILE"

  if [[ -x "\$BUILDER" ]]; then
    "\$BUILDER" >/dev/null || true
    log "ORDER: rebuilt config via \$BUILDER"
  fi
}

interactive_configure_order
EOF_ORDER

  chmod 0755 "$ORDER_TOOL_SH"
  log "OK: wrote order tool $ORDER_TOOL_SH"
}

write_sequencer() {
  cat >"$SEQUENCER_SH" <<EOF_SEQ
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR}"
CFG_DIR="\$BASE_DIR/config"
LOG_DIR="\$BASE_DIR/logs"

BUILDER="\$BASE_DIR/bin/tseq-build-conf.sh"
CONF="\${CONF:-\$CFG_DIR/tseq.conf}"

[[ -x "\$BUILDER" ]] || { echo "ERROR: missing builder: \$BUILDER" >&2; exit 1; }

"\$BUILDER" >/dev/null

[[ -f "\$CONF" ]] || { echo "ERROR: missing config: \$CONF" >&2; exit 1; }
source "\$CONF"

: "\${REPORT:=\$LOG_DIR/tseq.log}"
: "\${TIMEOUT:=0}"
: "\${READY_REGEX:=Server startup in}"
: "\${ROTATE_LOGS:=1}"
: "\${POST_DELAY_DEFAULT:=15}"
: "\${LOGS_PREV_KEEP:=1}"
: "\${INSTANCES:?INSTANCES not set}"

mkdir -p "\$(dirname "\$REPORT")"
log() { printf "%s %s\\n" "\$(date "+%F %T")" "\$*" | tee -a "\$REPORT"; }

wait_for_file() {
  local file="\$1" timeout_s="\$2"
  if [[ "\$timeout_s" -gt 0 ]]; then
    local t=0
    while (( t < timeout_s )); do
      [[ -f "\$file" ]] && return 0
      sleep 1; t=\$((t+1))
    done
    return 1
  else
    while [[ ! -f "\$file" ]]; do sleep 1; done
    return 0
  fi
}

purge_old_logs_prev() {
  local base="\$1" keep="\${2:-1}"
  local parent="\${base%/}"
  [[ "\$keep" -ge 1 ]] || keep=1

  mapfile -t arr < <(ls -1d "\${parent}"/logs.prev-* 2>/dev/null | sort -r || true)
  local count="\${#arr[@]}"
  if (( count <= keep )); then return 0; fi

  local i
  for (( i=keep; i<count; i++ )); do
    rm -rf -- "\${arr[\$i]}" 2>/dev/null || true
    log "LOGS: purged old backup \${arr[\$i]}"
  done
}

rotate_logs_dir() {
  local base="\$1"
  local logs_dir="\${base%/}/logs"
  local ts; ts="\$(date "+%Y%m%d_%H%M%S")"
  local bak="\${base%/}/logs.prev-\${ts}"

  [[ "\$ROTATE_LOGS" == "1" ]] || return 0

  if [[ -L "\$logs_dir" ]]; then
    log "LOGS: WARN logs is symlink, skip rotate: \$logs_dir"
    return 0
  fi

  purge_old_logs_prev "\$base" "\$LOGS_PREV_KEEP"

  local og
  og="\$(stat -c "%u:%g" "\$base" 2>/dev/null || echo "0:0")"

  if [[ -d "\$logs_dir" ]]; then
    mv "\$logs_dir" "\$bak"
    log "LOGS: rotated \$logs_dir -> \$bak"
  fi

  mkdir -p "\$logs_dir"
  chown "\$og" "\$logs_dir" 2>/dev/null || true
  chmod 0755 "\$logs_dir" 2>/dev/null || true

  purge_old_logs_prev "\$base" "\$LOGS_PREV_KEEP"
}

wait_for_marker_poll() {
  local logfile="\$1" regex="\$2" timeout_s="\$3"

  if [[ "\$timeout_s" -gt 0 ]]; then
    local t=0
    while (( t < timeout_s )); do
      if grep -E -m1 -- "\$regex" "\$logfile" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1; t=\$((t+1))
    done
    return 1
  else
    while true; do
      if grep -E -m1 -- "\$regex" "\$logfile" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
  fi
}

log "START tseq (manual)"
log "CONF  \$CONF"

for item in "\${INSTANCES[@]}"; do
  svc="\${item%%|*}"
  rest="\${item#*|}"
  base="\${rest%%|*}"
  delay="\${rest##*|}"
  [[ -n "\${delay:-}" ]] || delay="\$POST_DELAY_DEFAULT"
  [[ "\$delay" =~ ^[0-9]+\$ ]] || delay="\$POST_DELAY_DEFAULT"

  logfile="\${base%/}/logs/catalina.out"

  if systemctl is-active --quiet "\$svc"; then
    log "SKIP: \$svc already active (no start, no wait)"
    continue
  fi

  log "Starting: \$svc (base: \$base)"
  rotate_logs_dir "\$base"

  systemctl start "\$svc" || { log "FAIL: systemctl start failed for \$svc"; exit 1; }

  wait_for_file "\$logfile" "\$TIMEOUT" || { log "FAIL: \$svc did not create catalina.out"; exit 1; }

  if wait_for_marker_poll "\$logfile" "\$READY_REGEX" "\$TIMEOUT"; then
    log "OK: \$svc ready (marker)"
    if [[ "\$delay" -gt 0 ]]; then
      log "WAIT: post-ready delay \${delay}s for \$svc"
      sleep "\$delay"
    fi
  else
    log "FAIL: \$svc not ready (marker not seen). Stop chain."
    exit 1
  fi
done

log "DONE all instances started"
EOF_SEQ

  chmod 0755 "$SEQUENCER_SH"
  log "OK: wrote sequencer $SEQUENCER_SH"
}

write_wrapper_and_unit() {
  cat >"$WRAPPER_BIN" <<EOF_WR
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
  --order)
    shift
    exec "$ORDER_TOOL_SH" "\$@"
    ;;
  *)
    exec "$SEQUENCER_SH" "\$@"
    ;;
esac
EOF_WR
  chmod 0755 "$WRAPPER_BIN"
  ln -sfn "$WRAPPER_BIN" "$WRAPPER_LINK"

  cat >"$SYSTEMD_UNIT" <<EOF_UNIT
[Unit]
Description=Start Tomcats sequentially (wait for catalina.out marker)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$WRAPPER_BIN

[Install]
WantedBy=multi-user.target
EOF_UNIT

  chmod 0644 "$SYSTEMD_UNIT"
  systemctl daemon-reload
  log "OK: installed unit $SYSTEMD_UNIT"
  log "OK: installed launcher $WRAPPER_BIN"
  log "OK: installed launcher link $WRAPPER_LINK -> $WRAPPER_BIN"
}

restore_preserved_config() {
  local backup_dir="${BASE_DIR}.bak"

  [[ -d "$backup_dir" ]] || return 0
  mkdir -p "$CFG_DIR"

  if [[ ! -f "$ORDER_FILE" && -f "$backup_dir/config/order.txt" ]]; then
    cp -a "$backup_dir/config/order.txt" "$ORDER_FILE"
    chmod 0644 "$ORDER_FILE" 2>/dev/null || true
    log "CONFIG: restored order.txt from $backup_dir/config/order.txt"
  fi
}
fix_permissions() {
  if id "$BASE_USER" >/dev/null 2>&1; then
    chown -R "$BASE_USER:$BASE_USER" "$BASE_DIR"
    chmod -R u+rwX,go+rX "$BASE_DIR"
    log "PERMS: ownership set to $BASE_USER:$BASE_USER for $BASE_DIR"
  else
    log "PERMS: user '$BASE_USER' not found — ownership unchanged"
  fi
}

write_version_file() {
  printf "%s\n" "$VERSION" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE" 2>/dev/null || true
  chown "$BASE_USER:$BASE_USER" "$VERSION_FILE" 2>/dev/null || true
}

write_default_order_if_missing() {
  [[ -f "$ORDER_FILE" ]] && return 0

  log "ORDER: missing -> creating default order.txt"
  local n=10
  {
    write_order_header
    echo
    while IFS=$'\t' read -r _rank _platform svc _base; do
      [[ -n "${svc:-}" ]] || continue
      printf "%d %s %d\n" "$n" "$svc" "$POST_DELAY_DEFAULT"
      n=$((n+10))
    done < <(collect_sorted_discovered_entries)
  } >"$ORDER_FILE"
  chmod 0644 "$ORDER_FILE"
}

main() {
  need_root

  if [[ "$MODE" == "--uninstall" ]]; then
    uninstall_tseq
    exit 0
  fi

  if ! pre_cleanup_if_newer; then
    exit 0
  fi

  ensure_dirs

  log "INSTALL v$VERSION: begin"
  log "USER: $BASE_USER"
  log "HOME: $BASE_HOME"
  log "BASE: $BASE_DIR"
  log "SERVICE: tseq.service"
  log "DISCOVERY: /srv/IntegrationPlatform*/**/bin/catalina.sh"
  log "IGNORE: create <tomcat_base>/.sequencer-ignore"
  log "ORDER: supports third column POST_DELAY_S"
  log "ORDER: default platform order NFZ, PI, ADM, SSO, EUSL, EREC, MPI, HL7, HL7*, ERP, ZSMOPL, TS"
  log "LOGS: keeps only one logs.prev-* per tomcat base"

  restore_preserved_config
  write_discovered_tsv
  interactive_configure_order
  write_default_order_if_missing

  write_builder
  write_order_tool
  write_sequencer
  write_wrapper_and_unit
  "$BUILDER_SH" >/dev/null || true
  write_version_file
  fix_permissions

  echo
  echo "=== GOTOWE (v$VERSION) ==="
  echo "User:      $BASE_USER"
  echo "Base:      $BASE_DIR"
  echo "Service:   tseq"
  echo "Wrapper:   $WRAPPER_BIN"
  echo "Launcher:  $WRAPPER_LINK -> $WRAPPER_BIN"
  echo "Mapowanie: $DISCOVERED_TSV"
  echo "Kolejność: $ORDER_FILE"
  echo "Config:    $CONF_FILE (auto)"
  echo "Log:       $REPORT_FILE"
  echo "Version:   $(cat "$VERSION_FILE" 2>/dev/null || echo "?")"
  echo
  echo "Uruchomienie:"
  echo "  sudo tseq"
  echo "  sudo tseq --order"
  echo "  sudo systemctl start tseq --no-block"
  echo
}

main "$@"
