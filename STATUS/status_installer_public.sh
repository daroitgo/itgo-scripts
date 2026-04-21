#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# ==========================================================
# server-status installer
# Version: 3.12.10
# Usage:
#   sudo bash status_installer_3.12.10.sh itgo
#
# Install:
#   <HOME>/UTILITY/STATUS/
#
# Cache:
#   <HOME>/UTILITY/STATUS/cache/system.txt   (hourly)
#   <HOME>/UTILITY/STATUS/cache/apps.txt     (nightly; discovery + logs sizes)
#
# Live:
#   - service state (systemctl is-active)
#   - logs size from nightly cache
#   - docker compose state only if docker exists
#   - status -r refreshes BOTH caches on demand
# ==========================================================

VERSION="3.12.12"
MODE="install"
TARGET_USER="itgo"

if [[ "${1:-}" == "--uninstall" ]]; then
  MODE="uninstall"
  TARGET_USER="${2:-itgo}"
else
  TARGET_USER="${1:-itgo}"
fi

CACHE_DIR=""
EOL_DB_DIR=""
EOL_DB_FILE=""

SYSTEMD_COLLECT=""
SYSTEMD_APPS_COLLECT=""

LEGACY_STATUS_CMD="/usr/local/bin/status"
LEGACY_SYSTEMD_COLLECT="/usr/local/sbin/system_inventory_collect"
LEGACY_SYSTEMD_APPS_COLLECT="/usr/local/sbin/apps_inventory_collect"

UNIT_SERVICE="/etc/systemd/system/server-status-collect.service"
UNIT_TIMER="/etc/systemd/system/server-status-collect.timer"

UNIT_APPS_SERVICE="/etc/systemd/system/server-status-apps-collect.service"
UNIT_APPS_TIMER="/etc/systemd/system/server-status-apps-collect.timer"

need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root: sudo bash $0 <user>" >&2; exit 1; }; }
ensure_user() { id "$TARGET_USER" >/dev/null 2>&1 || { echo "ERROR: user $TARGET_USER not found" >&2; exit 1; }; }

safe_backup() {
  local f="${1:?}"
  [[ -e "$f" ]] || return 0
  rm -f "${f}.bak" 2>/dev/null || true
  cp -a "$f" "${f}.bak"
}

cleanup_old_legacy_backups() {
  rm -f "$BASH_PROFILE".bak.* 2>/dev/null || true
}

resolve_home() {
  TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
  [[ -n "${TARGET_HOME:-}" ]] || { echo "ERROR: cannot resolve home for user $TARGET_USER" >&2; exit 1; }

  UTILITY_DIR="$TARGET_HOME/UTILITY"
  STATUS_DIR="$UTILITY_DIR/STATUS"
  STATUS_BIN_DIR="$STATUS_DIR/bin"
  CACHE_DIR="$STATUS_DIR/cache"
  EOL_DB_DIR="$STATUS_DIR/eol-db"
  EOL_DB_FILE="$EOL_DB_DIR/eol-db.tsv"
  VERSION_FILE="$STATUS_DIR/.status_installer_version"

  COLLECTOR_SRC="$STATUS_BIN_DIR/system_inventory_collect"
  APPS_COLLECTOR_SRC="$STATUS_BIN_DIR/apps_inventory_collect"
  SYSTEMD_COLLECT="$COLLECTOR_SRC"
  SYSTEMD_APPS_COLLECT="$APPS_COLLECTOR_SRC"
  STATUS_LAUNCHER="$STATUS_BIN_DIR/status"
  VIEWER="$STATUS_DIR/server_status_view.sh"

  BASH_PROFILE="$TARGET_HOME/.bash_profile"
}

setup_dirs() {
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$STATUS_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$STATUS_BIN_DIR"

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$CACHE_DIR"
  chmod 0755 "$CACHE_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$EOL_DB_DIR"
}

cleanup_legacy_global_artifacts() {
  rm -f "$LEGACY_STATUS_CMD" \
        "${LEGACY_STATUS_CMD}.bak" \
        "${LEGACY_STATUS_CMD}.bak."* \
        "$LEGACY_SYSTEMD_COLLECT" \
        "${LEGACY_SYSTEMD_COLLECT}.bak" \
        "${LEGACY_SYSTEMD_COLLECT}.bak."* \
        "$LEGACY_SYSTEMD_APPS_COLLECT" \
        "${LEGACY_SYSTEMD_APPS_COLLECT}.bak" \
        "${LEGACY_SYSTEMD_APPS_COLLECT}.bak."* 2>/dev/null || true
}

write_installer_version_file() {
  printf "%s\n" "$VERSION" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$VERSION_FILE"
}

write_eol_db() {
  {
    printf "# product\tmajor\teol_date\n"
    printf "rocky-linux\t8\t2029-05-31\n"
    printf "rocky-linux\t9\t2032-05-31\n"
    printf "oracle-linux\t7\t2028-12-31\n"
    printf "oracle-linux\t8\t2029-07-01\n"
    printf "oracle-linux\t9\t2032-06-01\n"
    printf "centos\t7\t2024-06-30\n"
    printf "centos-stream\t8\t2024-05-31\n"
    printf "centos-stream\t9\t2027-05-31\n"
  } > "$EOL_DB_FILE"
  chmod 0644 "$EOL_DB_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$EOL_DB_FILE" 2>/dev/null || true
  awk -F $'\t' 'BEGIN{ok=0} $0 ~ /^[[:space:]]*#/ {next} NF==3 {ok=1} END{exit ok?0:1}' "$EOL_DB_FILE" \
    || { echo "ERROR: EOL DB format broken" >&2; exit 1; }
}

write_collector_src() {
cat > "$COLLECTOR_SRC" <<'COL'
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

OUTDIR="__STATUS_CACHE_DIR__"
SYS="$OUTDIR/system.txt"
EOL_DB="__STATUS_EOL_DB_FILE__"

tmp_sys="$(mktemp)"
mkdir -p "$OUTDIR"

collected="$(date '+%Y-%m-%d %H:%M')"
host="$(hostname -f 2>/dev/null || hostname)"
kernel="$(uname -r)"

os_id="unknown"; os_ver="unknown"; os_pretty="UNKNOWN"
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-unknown}"
  os_ver="${VERSION_ID:-unknown}"
  os_pretty="${PRETTY_NAME:-UNKNOWN}"
fi
major="${os_ver%%.*}"

java_ver="NOT_INSTALLED"
command -v java >/dev/null 2>&1 && java_ver="$(java -version 2>&1 | head -n1 | tr -d '\r')"

last_update="UNKNOWN"
if [[ -f /var/lib/dnf/history.sqlite ]]; then
  last_update="$(stat -c '%y' /var/lib/dnf/history.sqlite 2>/dev/null | cut -d'.' -f1 || echo UNKNOWN)"
elif ls /var/lib/yum/history/history-*.sqlite >/dev/null 2>&1; then
  f="$(ls -1t /var/lib/yum/history/history-*.sqlite 2>/dev/null | head -n1 || true)"
  [[ -n "${f:-}" ]] && last_update="$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1 || echo UNKNOWN)"
fi

UPDATE_WARN_DAYS=14
update_hint="UNKNOWN"
if [[ "$last_update" != "UNKNOWN" ]]; then
  now_epoch="$(date +%s)"
  upd_epoch="$(date -d "$last_update" +%s 2>/dev/null || echo 0)"
  if [[ "$upd_epoch" -gt 0 ]]; then
    age_days="$(( (now_epoch - upd_epoch) / 86400 ))"
    (( age_days > UPDATE_WARN_DAYS )) && update_hint="UPDATE REQUIRED (>${UPDATE_WARN_DAYS}d)" || update_hint="OK (<=${UPDATE_WARN_DAYS}d)"
  fi
fi

security_hint="UNKNOWN"
security_src="n/a"

count_security_lines() {
  awk '
    BEGIN{c=0}
    /^[[:space:]]*$/ {next}
    /^Last metadata expiration check:/ {next}
    /^Updating Subscription Management repositories/ {next}
    /^Unable to read consumer identity/ {next}
    /^This system is not registered/ {next}
    /^Loaded plugins:/ {next}
    /^Loaded plugins$/ {next}
    /^repo id/ {next}
    /^RHSA-|^RLSA-|^ELSA-|^FEDORA-|^ALAS-|^OVMSA-|^CVE-/ {c++}
    $0 ~ /^[A-Z]{2,}[0-9-]+/ {c++}
    END{print c}
  '
}

SEC_TIMEOUT="12s"

if command -v dnf >/dev/null 2>&1; then
  security_src="dnf:updateinfo:cacheonly"
  tmp="$(mktemp)"
  if timeout "$SEC_TIMEOUT" dnf -q --cacheonly updateinfo list --security --available >"$tmp" 2>/dev/null; then
    n="$(count_security_lines <"$tmp")"
    [[ "${n:-0}" -gt 0 ]] && security_hint="SECURITY UPDATES AVAILABLE (${n})" || security_hint="OK (none)"
  else
    security_hint="UNKNOWN (offline/timeout)"
  fi
  rm -f "$tmp"
elif command -v yum >/dev/null 2>&1; then
  security_src="yum:updateinfo"
  tmp="$(mktemp)"
  if timeout "$SEC_TIMEOUT" yum -q updateinfo list security >"$tmp" 2>/dev/null; then
    n="$(count_security_lines <"$tmp")"
    [[ "${n:-0}" -gt 0 ]] && security_hint="SECURITY UPDATES AVAILABLE (${n})" || security_hint="OK (none)"
  else
    security_hint="UNKNOWN (offline/timeout)"
  fi
  rm -f "$tmp"
else
  security_hint="UNKNOWN (no dnf/yum)"
  security_src="n/a"
fi

fw_state="UNKNOWN"
fw_default="UNKNOWN"
fw_active="UNKNOWN"
fw_ports_pm="UNKNOWN"
fw_services_pm="UNKNOWN"
fw_direct="UNKNOWN"

if command -v firewall-cmd >/dev/null 2>&1; then
  if firewall-cmd --state >/dev/null 2>&1; then
    fw_state="running"

    fw_default="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
    [[ -n "$fw_default" ]] || fw_default="UNKNOWN"

    active_raw="$(firewall-cmd --get-active-zones 2>/dev/null || true)"
    fw_active="$(echo "$active_raw" | awk '
      NF==1{zone=$1; next}
      $1=="interfaces:"{for(i=2;i<=NF;i++) printf "%s(%s) ", zone, $i}
      END{ }' | sed 's/[ ]*$//')"
    [[ -n "$fw_active" ]] || fw_active="(none)"

    zones="$(
      { echo "$active_raw" | awk 'NF==1{print $1}'; echo "$fw_default"; } \
      | awk 'NF && $1!="UNKNOWN"{print $1}' | sort -u
    )"
    [[ -n "$zones" ]] || zones="public"

    ports_out=""
    services_out=""
    for z in $zones; do
      z_all_p="$(firewall-cmd --permanent --zone="$z" --list-all 2>/dev/null || true)"
      pm_p="$(echo "$z_all_p" | awk -F': ' '/^[[:space:]]*ports:/{print $2}')"; [[ -n "$pm_p" ]] || pm_p="(none)"
      pm_s="$(echo "$z_all_p" | awk -F': ' '/^[[:space:]]*services:/{print $2}')"; [[ -n "$pm_s" ]] || pm_s="(none)"

      ports_out+="$z:$pm_p | "
      services_out+="$z:$pm_s | "
    done

    fw_ports_pm="$(echo "$ports_out" | sed 's/ | $//')"
    fw_services_pm="$(echo "$services_out" | sed 's/ | $//')"

    if firewall-cmd --direct --get-all-rules >/dev/null 2>&1; then
      fw_direct="$(firewall-cmd --direct --get-all-rules 2>/dev/null | wc -l | tr -d ' ')"
    else
      fw_direct="(n/a)"
    fi
  else
    fw_state="not running"
    fw_default="(firewalld down)"
    fw_active="(firewalld down)"
    fw_ports_pm="(firewalld down)"
    fw_services_pm="(firewalld down)"
    fw_direct="(firewalld down)"
  fi
elif command -v iptables >/dev/null 2>&1; then
  fw_state="iptables"
  fw_default="(n/a)"
  fw_active="(n/a)"
  fw_ports_pm="(n/a)"
  fw_services_pm="(n/a)"
  fw_direct="(n/a)"
fi

support_until="UNKNOWN"
support_src="local-db:missing"

detect_product_local() {
  case "$os_id" in
    rocky|rockylinux|rocky-linux) echo "rocky-linux" ;;
    ol|oracle|oraclelinux|oracle-linux) echo "oracle-linux" ;;
    centos)
      [[ -f /etc/centos-release ]] && grep -qi "stream" /etc/centos-release && echo "centos-stream" || echo "centos"
    ;;
    *)
      if echo "$os_pretty" | grep -qi "centos stream"; then echo "centos-stream"; return; fi
      if echo "$os_pretty" | grep -qi "centos"; then echo "centos"; return; fi
      if echo "$os_pretty" | grep -qi "oracle linux"; then echo "oracle-linux"; return; fi
      if echo "$os_pretty" | grep -qi "rocky"; then echo "rocky-linux"; return; fi
      echo ""
    ;;
  esac
}

product="$(detect_product_local)"
if [[ -n "$product" && -f "$EOL_DB" ]]; then
  dt="$(awk -F $'\t' -v p="$product" -v m="$major" '
    $0 ~ /^[[:space:]]*#/ {next}
    NF < 3 {next}
    $1==p && $2==m {print $3; exit}
  ' "$EOL_DB" 2>/dev/null || true)"
  if [[ -n "${dt:-}" ]]; then
    support_until="$dt"
    support_src="local-db:${product}:${major}"
  else
    support_until="UNKNOWN"
    support_src="local-db:no-entry:${product}:${major}"
  fi
else
  support_until="UNKNOWN"
  if [[ -z "$product" ]]; then
    support_src="local-db:unknown-distro"
  elif [[ ! -f "$EOL_DB" ]]; then
    support_src="local-db:missing-file"
  fi
fi

{
echo "Collected     : $collected"
echo "Host          : $host"
echo "OS            : $os_pretty"
echo "Kernel        : $kernel"
echo "Java          : $java_ver"
echo "Last update   : $last_update"
echo "Update status : $update_hint"
echo "Security upd  : $security_hint"
echo "Security src  : $security_src"
echo "Support until : $support_until"
echo "Support src   : $support_src"
echo "Firewall      : $fw_state"
echo "FW default    : $fw_default"
echo "FW active     : $fw_active"
echo "FW pm ports   : $fw_ports_pm"
echo "FW pm services: $fw_services_pm"
echo "FW directrules: $fw_direct"
} > "$tmp_sys"

mv "$tmp_sys" "$SYS"
chmod 0644 "$SYS"
chown root:root "$SYS"
COL
sed -i \
  -e "s|__STATUS_CACHE_DIR__|$CACHE_DIR|g" \
  -e "s|__STATUS_EOL_DB_FILE__|$EOL_DB_FILE|g" \
  "$COLLECTOR_SRC"
chmod 0755 "$COLLECTOR_SRC"
}

write_apps_collector_src() {
cat > "$APPS_COLLECTOR_SRC" <<'APPCOL'
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

OUTDIR="__STATUS_CACHE_DIR__"
APPS="$OUTDIR/apps.txt"
tmp="$(mktemp)"
mkdir -p "$OUTDIR"

collected="$(date '+%Y-%m-%d %H:%M')"
host="$(hostname -f 2>/dev/null || hostname)"

KW_REGEX='wildfly|integrationplatform|bank_krwi|bank-krwi|p1adapter|edm-amdx|mpi|start_docker|tomcat|catalina|ekrn|p1erej|p1rej|p1ser|sgds|edm|epn|erej|e-rej|p1-rej|p1-erej|zm'

is_blacklisted_unit() {
  case "${1:-}" in
    ledmon.service) return 0 ;;
    *) return 1 ;;
  esac
}

trim2(){ local s="$1" w="$2"; ((${#s}>w)) && echo "${s:0:$((w-3))}..." || echo "$s"; }

hint2prefix() {
  local p="${1:-}"
  [[ -z "$p" ]] && { echo "UNKNOWN"; return; }
  p="${p%%:*}"
  p="${p%%\"*}"; p="${p#\"}" 2>/dev/null || true
  p="${p%/}"
  [[ "$p" == "/" ]] && { echo "/"; return; }
  echo "$p" | awk -F/ '{
    n=0
    for(i=1;i<=NF;i++) if($i!="") a[++n]=$i
    if(n==0){print "/"; exit}
    s="/"
    end = (n>=2 ? 2 : 1)
    for(i=1;i<=end;i++){
      if(a[i]!=""){
        if(s!="/") s=s"/"
        s=s a[i]
      }
    }
    if(n>2) s=s"/..."
    print s
  }'
}

app_short_from_unit() {
  local u="$1"
  case "$u" in
    bk.service) echo "BANK_KRWI" ;;
    pi.service) echo "PI" ;;
    pi_adm.service) echo "PI_ADM" ;;
    pi_lic.service) echo "PI_LIC" ;;
    pi_sso.service) echo "PI_SSO" ;;
    pi_nfz.service) echo "PI_NFZ" ;;
    pi_erec.service) echo "PI_EREC" ;;
    pi_hl7.service) echo "PI_HL7" ;;
    pi_hl7_alab.service) echo "PI_HL7_ALAB" ;;
    pi_ts.service) echo "PI_TOPSOR" ;;
    pi_im.service) echo "PI_IM" ;;
    pi_zm.service) echo "PI_ZM" ;;
    pi_zdm.service) echo "PI_ZDM" ;;
    pi_zsmopl.service) echo "PI_ZSMOPL" ;;
    *bank_krwi*|*bank-krwi*|*bankkrwi*) echo "BANK_KRWI" ;;
    *p1adapter*) echo "P1ADAPTER" ;;
    *p1erej*|*p1-erej*) echo "P1EREJ" ;;
    *p1rej*|*p1-rej*) echo "P1REJ" ;;
    *erej*|*e-rej*) echo "EREJ" ;;
    *ekrn*) echo "EKRN" ;;
    *sgds*) echo "SGDS" ;;
    *epn*) echo "EPN" ;;
    *edm*|*edm-amdx*) echo "EDM" ;;
    *mpi*) echo "MPI" ;;
    *wildfly*) echo "WILDFLY" ;;
    *zm_start_docker*|*start_docker*|*start-docker*) echo "ZM" ;;
    *) echo "" ;;
  esac
}

detect_appname_fallback() {
  local t="$1"
  echo "$t" | tr '[:upper:]' '[:lower:]' | grep -oE "$KW_REGEX" | head -n1 | tr -d '\r'
}

logs_dir_for_app_path() {
  local app="${1:-}"
  local p="${2:-}"
  local wdir="${3:-}"
  local probe="${p:-${wdir:-}}"

  case "$app" in
    EDM|MPI) echo "/var/log/asseco"; return ;;
    ZM|ZDA_MED|PI_ZM) echo "/usr/local/ZM/start_docker/log"; return ;;
    P1EREJ) echo "/srv/P1EREJ/docker-logs"; return ;;
  esac

  if echo "${probe:-}" | grep -qE '^/srv/IntegrationPlatform_[^/]+/apache-tomcat'; then
    base="$(echo "$probe" | sed -nE 's#^(/srv/IntegrationPlatform_[^/]+/apache-tomcat).*#\1#p')"
    [[ -n "${base:-}" ]] && { echo "$base/logs"; return; }
  fi

  if echo "${probe:-}" | grep -qE '^/srv/WildflyAMMS/wildfly-[^/]+'; then
    base="$(echo "$probe" | sed -nE 's#^(/srv/WildflyAMMS/wildfly-[^/]+).*#\1#p')"
    [[ -n "${base:-}" ]] && { echo "$base/standalone/log"; return; }
  fi

  if echo "${probe:-}" | grep -qE '^/srv/P1EREJ(/|$)'; then
    echo "/srv/P1EREJ/docker-logs"; return
  fi
  if echo "${probe:-}" | grep -qE '^/usr/local/ZM/start_docker(/|$)'; then
    echo "/usr/local/ZM/start_docker/log"; return
  fi

  if [[ -n "${probe:-}" ]]; then
    [[ -d "$probe/logs" ]] && { echo "$probe/logs"; return; }
    [[ -d "$probe/log"  ]] && { echo "$probe/log";  return; }
  fi

  echo ""
}

dir_size_bytes() {
  local d="$1"
  [[ -n "$d" && -d "$d" ]] || { echo ""; return; }
  if du -sb "$d" >/dev/null 2>&1; then
    du -sb "$d" 2>/dev/null | awk '{print $1}' || true
  else
    kb="$(du -sk "$d" 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "${kb:-}" ]] && echo "$((kb*1024))" || echo ""
  fi
}

system_from_path() {
  local p="${1:-}"
  local l; l="$(echo "$p" | tr '[:upper:]' '[:lower:]')"
  if echo "$l" | grep -qE "/srv/p1erej(/|$)"; then echo "P1EREJ"; return; fi
  if echo "$l" | grep -qE "/usr/local/zm/start_docker"; then echo "ZM"; return; fi
  if echo "$l" | grep -qE "/srv/integrationplatform_"; then echo "IP"; return; fi
  if echo "$l" | grep -qE "/srv/wildflyamms/wildfly-"; then echo "WILDFLY"; return; fi
  if echo "$l" | grep -q "p1adapter"; then echo "P1ADAPTER"; return; fi
  if echo "$l" | grep -q "mpi"; then echo "MPI"; return; fi
  if echo "$l" | grep -q "edm"; then echo "EDM"; return; fi
  echo "$(basename "$p" | tr '[:lower:]' '[:upper:]')"
}

compose_unit_for_path() {
  local needle="$1"
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
    s="$(systemctl show "$u" 2>/dev/null | awk -F= '$1=="ExecStart" || $1=="WorkingDirectory"{print $2}' | tr '\n' ' ')"
    echo "$u $s"
  done | grep -F -- "$needle" 2>/dev/null | head -n1 | awk '{print $1}' || true
}

compose_project_name() {
  local f="$1"
  local d; d="$(dirname "$f")"

  if [[ -f "$d/.env" ]]; then
    n="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' "$d/.env" 2>/dev/null | tail -n1 | sed 's/^[^=]*=//; s/"//g; s/'"'"'//g')"
    [[ -n "${n:-}" ]] && { echo "$n"; return; }
  fi

  n2="$(awk '
    /^[[:space:]]*name:[[:space:]]*/{
      sub(/^[[:space:]]*name:[[:space:]]*/,"",$0);
      gsub(/["'\'']/, "", $0);
      print $0; exit
    }' "$f" 2>/dev/null || true)"
  [[ -n "${n2:-}" ]] && { echo "$n2"; return; }

  s1="$(awk '
    /^[[:space:]]*services:[[:space:]]*$/ {ins=1; next}
    ins==1 && /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      gsub(/^[[:space:]]*/,"",$0); sub(/:[[:space:]]*$/,"",$0);
      print $0; exit
    }
  ' "$f" 2>/dev/null || true)"
  [[ -n "${s1:-}" ]] && { echo "$s1"; return; }

  echo "$(basename "$d")"
}

{
  echo "# server-status apps inventory cache"
  echo "# Collected: $collected"
  echo "# Host: $host"
  echo
  echo "#SERVICES"
  echo "# format: SVC<TAB>APP<TAB>UNIT<TAB>HINT<TAB>FULLPATH<TAB>LOGSDIR<TAB>LOGSBYTES"
} > "$tmp"

systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | while read -r svc; do
  is_blacklisted_unit "$svc" && continue

  info="$(systemctl show "$svc" 2>/dev/null | egrep 'ExecStart=|WorkingDirectory=' || true)"
  wdir="$(echo "$info" | sed -n 's/WorkingDirectory=//p' | head -n1)"
  exec="$(echo "$info" | sed -n 's/ExecStart=//p' | head -n1)"
  combined="$svc $wdir $exec"

  if echo "$combined" | grep -qiE "$KW_REGEX"; then
    app="$(app_short_from_unit "$svc")"
    if [[ -z "$app" ]]; then
      fb="$(detect_appname_fallback "$combined")"
      app="${fb^^}"
      [[ -z "$app" ]] && app="APP"
    fi

    fullpath="$(echo "$combined" | grep -oE '/[^ ]+' | head -n1 || true)"
    [[ -n "${fullpath:-}" ]] || fullpath="${wdir:-}"

    hint_in="${fullpath:-${wdir:-UNKNOWN}}"
    hint="$(hint2prefix "$hint_in")"

    logsdir="$(logs_dir_for_app_path "$app" "$fullpath" "$wdir")"
    logsbytes="$(dir_size_bytes "$logsdir")"

    printf "SVC\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(trim2 "$app" 10)" \
      "$(trim2 "$svc" 72)" \
      "$hint" \
      "${fullpath:-}" \
      "${logsdir:-}" \
      "${logsbytes:-}"
  fi
done >> "$tmp"

{
  echo
  echo "#COMPOSE"
  echo "# format: CMP<TAB>SYSTEM<TAB>UNIT<TAB>HINT<TAB>DIR<TAB>PROJECTS(space-separated)<TAB>LOGSDIR<TAB>LOGSBYTES"
} >> "$tmp"

declare -A DIR_SYSTEM DIR_HINT DIR_UNIT DIR_PROJS DIR_LOGSDIR DIR_LOGSBYTES

roots=(/srv /usr/local/ZM/start_docker /root)
for r in "${roots[@]}"; do
  [[ -d "$r" ]] || continue

  while IFS= read -r f; do
    [[ -z "${f:-}" ]] && continue
    d="$(dirname "$f")"
    [[ -z "${d:-}" ]] && continue

    sys="$(system_from_path "$d")"
    unit="$(compose_unit_for_path "$d")"
    [[ -z "${unit:-}" ]] && unit="$(compose_unit_for_path "$f")"
    [[ -z "${unit:-}" ]] && unit="(no-unit)"

    proj="$(compose_project_name "$f")"
    [[ -z "${proj:-}" ]] && proj="unknown"

    DIR_SYSTEM["$d"]="$sys"
    DIR_HINT["$d"]="$(hint2prefix "$d")"
    DIR_UNIT["$d"]="$unit"

    cur="${DIR_PROJS["$d"]-}"
    if ! echo " $cur " | grep -q " $proj "; then
      DIR_PROJS["$d"]="${cur}${cur:+ }$proj"
    fi

    logsdir=""
    case "$sys" in
      EDM|MPI) logsdir="/var/log/asseco" ;;
      ZM) logsdir="/usr/local/ZM/start_docker/log" ;;
      P1EREJ) logsdir="/srv/P1EREJ/docker-logs" ;;
      WILDFLY) logsdir="$(logs_dir_for_app_path "WILDFLY" "$d" "$d")" ;;
      IP) logsdir="$(logs_dir_for_app_path "IP" "$d" "$d")" ;;
      *) logsdir="$(logs_dir_for_app_path "$sys" "$d" "$d")" ;;
    esac

    [[ -n "${logsdir:-}" ]] && DIR_LOGSDIR["$d"]="$logsdir"
    if [[ -n "${logsdir:-}" ]]; then
      logsbytes="$(dir_size_bytes "$logsdir")"
      [[ -n "${logsbytes:-}" ]] && DIR_LOGSBYTES["$d"]="$logsbytes"
    fi
  done < <(find "$r" -maxdepth 6 -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null)
done

for d in "${!DIR_SYSTEM[@]}"; do echo "$d"; done | sort | while read -r d; do
  sys="${DIR_SYSTEM["$d"]}"
  unit="${DIR_UNIT["$d"]}"
  hint="${DIR_HINT["$d"]}"
  projs="${DIR_PROJS["$d"]-}"
  [[ -z "${projs:-}" ]] && continue
  logsdir="${DIR_LOGSDIR["$d"]-}"
  logsbytes="${DIR_LOGSBYTES["$d"]-}"

  printf "CMP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(trim2 "$sys" 10)" \
    "$(trim2 "$unit" 72)" \
    "$hint" \
    "$d" \
    "$projs" \
    "${logsdir:-}" \
    "${logsbytes:-}"
done >> "$tmp"

mv "$tmp" "$APPS"
chmod 0644 "$APPS"
chown root:root "$APPS"
APPCOL
sed -i \
  -e "s|__STATUS_CACHE_DIR__|$CACHE_DIR|g" \
  "$APPS_COLLECTOR_SRC"
chmod 0755 "$APPS_COLLECTOR_SRC"
}

write_viewer() {
cat > "$VIEWER" <<'VIEW'
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SYS="__STATUS_CACHE_DIR__/system.txt"
APPS="__STATUS_CACHE_DIR__/apps.txt"
[[ -f "$SYS" ]] || exit 0

getv(){ local key="$1"; awk -v k="$key" '$0 ~ "^"k"[[:space:]]*:"{sub("^"k"[[:space:]]*:[[:space:]]*","",$0); print; exit}' "$SYS"; }

collected="$(getv "Collected")"
host="$(getv "Host")"
os="$(getv "OS")"
kernel="$(getv "Kernel")"
java="$(getv "Java")"
updated="$(getv "Last update")"
status="$(getv "Update status")"
secupd="$(getv "Security upd")"
secsrc="$(getv "Security src")"
support="$(getv "Support until")"
supportsrc="$(getv "Support src")"

fw="$(getv "Firewall")"
fw_default="$(getv "FW default")"
fw_active="$(getv "FW active")"
fw_pm_ports="$(getv "FW pm ports")"
fw_pm_services="$(getv "FW pm services")"
fw_direct="$(getv "FW directrules")"

read_version_file() {
  local vf="$1"
  if [[ -f "$vf" ]]; then
    head -n1 "$vf" 2>/dev/null | tr -d '\r'
  else
    echo ""
  fi
}

module_state() {
  local vf="$1"
  [[ -f "$vf" ]] && echo "YES" || echo "NO"
}

status_vf="$HOME/UTILITY/STATUS/.status_installer_version"
tseq_vf="$HOME/UTILITY/TSEQ/.tseq_version"
downloader_vf="$HOME/UTILITY/DOWNLOADER_APP/.downloader_version"
upgbuilder_vf="$HOME/UTILITY/UPGbuilder/.upgbuilder_version"
upg_cleanup_vf="$HOME/UTILITY/UPG_CLEANUP/.upg_cleanup_version"

status_installed="$(module_state "$status_vf")"
tseq_installed="$(module_state "$tseq_vf")"
downloader_installed="$(module_state "$downloader_vf")"
upgbuilder_installed="$(module_state "$upgbuilder_vf")"
upg_cleanup_installed="$(module_state "$upg_cleanup_vf")"

inst_ver="$(read_version_file "$status_vf")"
tseq_ver="$(read_version_file "$tseq_vf")"
downloader_ver="$(read_version_file "$downloader_vf")"
upgbuilder_ver="$(read_version_file "$upgbuilder_vf")"
upg_cleanup_ver="$(read_version_file "$upg_cleanup_vf")"

[[ -n "${inst_ver:-}" ]] || inst_ver="UNKNOWN"
[[ -n "${tseq_ver:-}" ]] || tseq_ver="UNKNOWN"
[[ -n "${downloader_ver:-}" ]] || downloader_ver="UNKNOWN"
[[ -n "${upgbuilder_ver:-}" ]] || upgbuilder_ver="UNKNOWN"
[[ -n "${upg_cleanup_ver:-}" ]] || upg_cleanup_ver="UNKNOWN"

upg_cleanup_hook="NO"
if [[ -f "$HOME/.bashrc" ]] && grep -qF "# >>> UPG XML cleanup (auto) >>>" "$HOME/.bashrc" 2>/dev/null; then
  upg_cleanup_hook="YES"
fi

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

badge="$status"
echo "$status" | grep -qi "UPDATE REQUIRED" && badge="${RED}${status}${RESET}" || badge="${GREEN}${status}${RESET}"

secbadge="${secupd:-UNKNOWN}"
if echo "${secupd:-}" | grep -qi "SECURITY UPDATES AVAILABLE"; then
  secbadge="${RED}${secupd}${RESET}"
elif echo "${secupd:-}" | grep -qi "^OK"; then
  secbadge="${GREEN}${secupd}${RESET}"
fi

hr_bytes() {
  local b="${1:-}"
  [[ -n "$b" ]] || { echo "n/a"; return; }
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1;
    while(b>=1024 && i<5){b/=1024; i++}
    printf "%.1f %s", b, u[i]
  }'
}

svc_state() { systemctl is-active "$1" 2>/dev/null || echo "unknown"; }
trim2(){ local s="$1" w="$2"; ((${#s}>w)) && echo "${s:0:$((w-3))}..." || echo "$s"; }

echo
echo "== SERVER STATUS (${collected:-UNKNOWN}) =="
printf "%-10s %s\n" "Host"       "${host:-UNKNOWN}"
printf "%-10s %s\n" "OS"         "${os:-UNKNOWN}"
printf "%-10s %s\n" "Kernel"     "${kernel:-UNKNOWN}"
printf "%-10s %s\n" "Java"       "${java:-UNKNOWN}"
printf "%-10s %s   [%b]\n" "Updated" "${updated:-UNKNOWN}" "$badge"
printf "%-10s %b\n" "SecUpd"     "${secbadge}"
printf "%-10s %s\n" "SecSrc"     "${secsrc:-UNKNOWN}"
printf "%-10s %s\n" "Support"    "${support:-UNKNOWN}"
printf "%-10s %s\n" "SupportSrc" "${supportsrc:-local-db}"

echo
echo "== MODULES =="
printf "%-12s %-5s %s\n" "MODULE" "INST" "VERSION / INFO"
printf "%-12s %-5s %s\n" "------------" "-----" "------------------------------"
printf "%-12s %-5s %s\n" "StatusInst" "${status_installed:-NO}" "${inst_ver:-UNKNOWN}"
printf "%-12s %-5s %s\n" "UPGclean"   "${upg_cleanup_installed:-NO}" "${upg_cleanup_ver:-UNKNOWN} (bashrc:${upg_cleanup_hook})"
printf "%-12s %-5s %s\n" "TSEQ"       "${tseq_installed:-NO}" "${tseq_ver:-UNKNOWN}"
printf "%-12s %-5s %s\n" "Downloader" "${downloader_installed:-NO}" "${downloader_ver:-UNKNOWN}"
printf "%-12s %-5s %s\n" "UPGbuilder" "${upgbuilder_installed:-NO}" "${upgbuilder_ver:-UNKNOWN}"

echo
echo "== FIREWALL (permanent) =="
printf "%-10s %s\n" "State"    "${fw:-UNKNOWN}"
printf "%-10s %s\n" "Default"  "${fw_default:-UNKNOWN}"
printf "%-10s %s\n" "Active"   "${fw_active:-UNKNOWN}"
printf "%-10s %s\n" "PM Ports" "${fw_pm_ports:-UNKNOWN}"
printf "%-10s %s\n" "PM Svcs"  "${fw_pm_services:-UNKNOWN}"
printf "%-10s %s\n" "Direct"   "${fw_direct:-UNKNOWN}"

echo
echo "== APPS (live state, cached logs size) =="

printf "%-10s %-10s %-10s %-24s %s\n" "APP" "STATE" "LOGS" "UNIT" "HINT"
printf "%-10s %-10s %-10s %-24s %s\n" "---------" "---------" "----------" "------------------------" "----------------------------------------"

if [[ -f "$APPS" ]]; then
  awk -F'\t' '$1=="SVC"{print $2 "\t" $3 "\t" $4 "\t" $7}' "$APPS" 2>/dev/null \
  | while IFS=$'\t' read -r app unit hint logsbytes; do
      st="$(svc_state "$unit")"
      logs="$(hr_bytes "${logsbytes:-}")"
      printf "%-10s %-10s %-10s %-24s %s\n" \
        "$(trim2 "${app:-APP}" 10)" \
        "$(trim2 "${st:-unknown}" 10)" \
        "$(trim2 "${logs:-n/a}" 10)" \
        "$(trim2 "${unit:-unknown}" 24)" \
        "${hint:-UNKNOWN}"
    done
else
  echo "(no apps cache; run: status -r)"
fi

command -v docker >/dev/null 2>&1 || { echo; exit 0; }

echo
echo "== DOCKER / COMPOSE =="

dockerv="$(docker --version 2>/dev/null | tr -d '\r' || echo UNKNOWN)"
composev="NOT_INSTALLED"
if docker compose version >/dev/null 2>&1; then
  composev="$(docker compose version 2>/dev/null | head -n1 | tr -d '\r' || echo UNKNOWN)"
elif command -v docker-compose >/dev/null 2>&1; then
  composev="$(docker-compose --version 2>/dev/null | tr -d '\r' || echo UNKNOWN)"
fi
printf "%-10s %s\n" "Docker" "$dockerv"
printf "%-10s %s\n" "Compose" "$composev"

echo
echo "== DOCKER COMPOSE PROJECTS (grouped) =="

compose_proj_counts() {
  local proj="$1"
  local running=0 all=0
  running="$(docker ps --filter "label=com.docker.compose.project=$proj" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  all="$(docker ps -a --filter "label=com.docker.compose.project=$proj" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  echo "$running $all"
}

declare -A G_PROJS G_HINT G_LOGS

if [[ -f "$APPS" ]]; then
  while IFS=$'\t' read -r tag sys unit hint dir projs logsdir logsbytes; do
    [[ "$tag" == "CMP" ]] || continue
    key="${sys}|||${unit}"
    cur="${G_PROJS[$key]-}"
    for p in $projs; do
      if ! echo " $cur " | grep -q " $p "; then
        cur="${cur}${cur:+ }$p"
      fi
    done
    G_PROJS["$key"]="$cur"
    G_HINT["$key"]="$hint"
    if [[ -n "${logsbytes:-}" ]]; then
      old="${G_LOGS[$key]-}"
      if [[ -z "${old:-}" || "${logsbytes:-0}" -gt "${old:-0}" ]]; then
        G_LOGS["$key"]="$logsbytes"
      fi
    fi
  done < <(awk -F'\t' '$1=="CMP"{print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8}' "$APPS" 2>/dev/null)
fi

printf "%-10s %-10s %-10s %-24s %s\n" "SYSTEM" "STATE" "LOGS" "UNIT" "HINT"
printf "%-10s %-10s %-10s %-24s %s\n" "---------" "---------" "----------" "------------------------" "----------------------------------------"

for key in "${!G_PROJS[@]}"; do
  sys="${key%%|||*}"
  unit="${key##*|||}"
  hint="${G_HINT[$key]-UNKNOWN}"
  projs="${G_PROJS[$key]-}"
  logs="$(hr_bytes "${G_LOGS[$key]-}")"

  state="unknown"
  any_all=0
  any_running=0
  for p in $projs; do
    read -r rcount acount < <(compose_proj_counts "$p")
    [[ "${acount:-0}" -gt 0 ]] && any_all=1
    [[ "${rcount:-0}" -gt 0 ]] && any_running=1
  done
  if [[ "$any_running" -eq 1 ]]; then
    state="running"
  elif [[ "$any_all" -eq 1 ]]; then
    state="stopped"
  else
    state="unknown"
  fi

  printf "%-10s %-10s %-10s %-24s %s\n" \
    "$(trim2 "${sys:-UNKNOWN}" 10)" \
    "$(trim2 "${state:-unknown}" 10)" \
    "$(trim2 "${logs:-n/a}" 10)" \
    "$(trim2 "${unit:-unknown}" 24)" \
    "${hint:-UNKNOWN}"
done | sort

echo
VIEW
sed -i \
  -e "s|__STATUS_CACHE_DIR__|$CACHE_DIR|g" \
  "$VIEWER"
chmod 0755 "$VIEWER"
}

install_collectors_local() {
  chown "$TARGET_USER:$TARGET_USER" "$COLLECTOR_SRC" "$APPS_COLLECTOR_SRC" 2>/dev/null || true
  chmod 0755 "$COLLECTOR_SRC" "$APPS_COLLECTOR_SRC" 2>/dev/null || true
  cleanup_legacy_global_artifacts
}

install_systemd_units() {
  cat > "$UNIT_SERVICE" <<EOF_SVC
[Unit]
Description=Collect server status inventory (system)
After=network.target

[Service]
Type=oneshot
ExecStart=$SYSTEMD_COLLECT
EOF_SVC

  cat > "$UNIT_TIMER" <<'EOF_TMR'
[Unit]
Description=Hourly server status inventory collection

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF_TMR

  systemctl daemon-reload
  systemctl enable --now server-status-collect.timer
  systemctl start server-status-collect.service || true

  chmod 0755 "$CACHE_DIR"
  chmod 0644 "$CACHE_DIR/system.txt" 2>/dev/null || true
}

install_apps_systemd_units() {
  cat > "$UNIT_APPS_SERVICE" <<EOF_SVC
[Unit]
Description=Collect server status inventory (apps discovery + logs size)
After=network.target

[Service]
Type=oneshot
ExecStart=$SYSTEMD_APPS_COLLECT
EOF_SVC

  cat > "$UNIT_APPS_TIMER" <<'EOF_TMR'
[Unit]
Description=Nightly server status apps discovery

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_TMR

  systemctl daemon-reload
  systemctl enable --now server-status-apps-collect.timer
  systemctl start server-status-apps-collect.service || true

  chmod 0644 "$CACHE_DIR/apps.txt" 2>/dev/null || true
}

install_status_command() {
  cat > "$STATUS_LAUNCHER" <<'EOF_CMD'
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SYS="__STATUS_CACHE_DIR__/system.txt"
APPS="__STATUS_CACHE_DIR__/apps.txt"

TTL_SYS=600
TTL_APPS=86400

refresh=0
if [[ "${1:-}" == "--refresh" || "${1:-}" == "-r" ]]; then
  refresh=1
  shift || true
fi

need_refresh_sys=0
need_refresh_apps=0
now="$(date +%s)"

if (( refresh == 1 )); then
  need_refresh_sys=1
  need_refresh_apps=1
else
  if [[ ! -f "$SYS" ]]; then
    need_refresh_sys=1
  else
    mtime_sys="$(stat -c %Y "$SYS" 2>/dev/null || echo 0)"
    (( now - mtime_sys > TTL_SYS )) && need_refresh_sys=1
  fi

  if [[ ! -f "$APPS" ]]; then
    need_refresh_apps=1
  else
    mtime_apps="$(stat -c %Y "$APPS" 2>/dev/null || echo 0)"
    (( now - mtime_apps > TTL_APPS )) && need_refresh_apps=1
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  if (( need_refresh_sys == 1 )); then
    (sudo -n systemctl start server-status-collect.service >/dev/null 2>&1 || true)
  fi
  if (( need_refresh_apps == 1 )); then
    (sudo -n systemctl start server-status-apps-collect.service >/dev/null 2>&1 || true)
  fi
fi

viewer="__STATUS_VIEWER__"
if [[ -x "$viewer" ]]; then
  exec "$viewer"
fi

echo "ERROR: __STATUS_VIEWER__ not found/executable" >&2
exit 1
EOF_CMD
  sed -i \
    -e "s|__STATUS_CACHE_DIR__|$CACHE_DIR|g" \
    -e "s|__STATUS_VIEWER__|$VIEWER|g" \
    "$STATUS_LAUNCHER"
  chown "$TARGET_USER:$TARGET_USER" "$STATUS_LAUNCHER" 2>/dev/null || true
  chmod 0755 "$STATUS_LAUNCHER"
  cleanup_legacy_global_artifacts
}

remove_block_from_file() {
  local file="${1:?}" start_marker="${2:?}" end_marker="${3:?}"
  local tmp

  [[ -f "$file" ]] || return 0

  tmp="$(mktemp)"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0==start {inside=1; next}
    $0==end   {inside=0; next}
    !inside   {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

patch_bash_profile() {
  local start_marker="# --- system-audit on SSH login (background) ---"
  local end_marker="# --- /system-audit ---"

  touch "$BASH_PROFILE"
  chown "$TARGET_USER:$TARGET_USER" "$BASH_PROFILE"
  chmod 0644 "$BASH_PROFILE" 2>/dev/null || true

  cleanup_old_legacy_backups
  safe_backup "$BASH_PROFILE"

  remove_block_from_file "$BASH_PROFILE" "$start_marker" "$end_marker"

  cat >> "$BASH_PROFILE" <<'EOF_BP'

# --- system-audit on SSH login (background) ---
case "$-" in *i*) : ;; *) return 0 ;; esac
[[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]] || return 0

sleep 0.05
if [[ -x "__STATUS_LAUNCHER__" ]]; then
  "__STATUS_LAUNCHER__" 2>/dev/null || true
fi
# --- /system-audit ---
EOF_BP
  sed -i -e "s|__STATUS_LAUNCHER__|$STATUS_LAUNCHER|g" "$BASH_PROFILE"
}

remove_status_profile_block() {
  local start_marker="# --- system-audit on SSH login (background) ---"
  local end_marker="# --- /system-audit ---"

  [[ -f "$BASH_PROFILE" ]] || return 0

  remove_block_from_file "$BASH_PROFILE" "$start_marker" "$end_marker"
}

uninstall_status() {
  need_root
  ensure_user
  resolve_home

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop server-status-collect.timer 2>/dev/null || true
    systemctl stop server-status-collect.service 2>/dev/null || true
    systemctl stop server-status-apps-collect.timer 2>/dev/null || true
    systemctl stop server-status-apps-collect.service 2>/dev/null || true

    systemctl disable server-status-collect.timer 2>/dev/null || true
    systemctl disable server-status-apps-collect.timer 2>/dev/null || true

    systemctl reset-failed server-status-collect.service 2>/dev/null || true
    systemctl reset-failed server-status-apps-collect.service 2>/dev/null || true
    systemctl reset-failed server-status-collect.timer 2>/dev/null || true
    systemctl reset-failed server-status-apps-collect.timer 2>/dev/null || true
  fi

  rm -f "$UNIT_SERVICE" "$UNIT_TIMER" "$UNIT_APPS_SERVICE" "$UNIT_APPS_TIMER" 2>/dev/null || true
  rm -f "$SYSTEMD_COLLECT" "$SYSTEMD_APPS_COLLECT" "$STATUS_LAUNCHER" 2>/dev/null || true
  cleanup_legacy_global_artifacts
  rm -rf "$STATUS_DIR" 2>/dev/null || true

  if [[ -d "$CACHE_DIR" && ! -L "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR" 2>/dev/null || true
  fi

  if [[ -d "$EOL_DB_DIR" && ! -L "$EOL_DB_DIR" ]]; then
    rm -rf "$EOL_DB_DIR" 2>/dev/null || true
  fi

  remove_status_profile_block

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  echo "OK: STATUS uninstall finished for user $TARGET_USER"
}

main() {
  need_root
  ensure_user
  resolve_home

  if [[ "$MODE" == "uninstall" ]]; then
    uninstall_status
    exit 0
  fi

  setup_dirs
  write_installer_version_file
  write_eol_db
  write_collector_src
  write_apps_collector_src
  write_viewer

  chown "$TARGET_USER:$TARGET_USER" "$COLLECTOR_SRC" "$APPS_COLLECTOR_SRC" "$VIEWER"

  install_collectors_local
  install_systemd_units
  install_apps_systemd_units
  install_status_command
  patch_bash_profile

  echo "OK"
}
main "$@"
