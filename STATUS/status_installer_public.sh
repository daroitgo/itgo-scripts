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

VERSION="3.12.14"
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

selinux_collectors() {
  printf "%s\n" "$COLLECTOR_SRC" "$APPS_COLLECTOR_SRC"
}

configure_collectors_selinux() {
  command -v getenforce >/dev/null 2>&1 || return 0

  local paths=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" && -e "$path" ]] && paths+=("$path")
  done < <(selinux_collectors)

  [[ "${#paths[@]}" -gt 0 ]] || return 0

  echo "INFO: SELinux executable context fix covers:"
  printf "INFO:   %s\n" "${paths[@]}"

  if command -v semanage >/dev/null 2>&1; then
    for path in "${paths[@]}"; do
      semanage fcontext -a -t bin_t "$path" 2>/dev/null || \
        semanage fcontext -m -t bin_t "$path" 2>/dev/null || true
    done

    if command -v restorecon >/dev/null 2>&1; then
      restorecon -v "${paths[@]}" 2>/dev/null || restorecon "${paths[@]}" 2>/dev/null || true
      echo "INFO: SELinux persistent fcontext applied with semanage + restorecon (type bin_t)."
    else
      chcon -t bin_t "${paths[@]}" 2>/dev/null || true
      echo "WARN: semanage is available, but restorecon is missing; applied temporary chcon -t bin_t fallback."
    fi
  else
    chcon -t bin_t "${paths[@]}" 2>/dev/null || true
    echo "WARN: semanage not found; applied chcon -t bin_t fallback. This is less persistent than semanage + restorecon."
  fi
}

remove_collectors_selinux_fcontext() {
  command -v semanage >/dev/null 2>&1 || return 0

  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    semanage fcontext -d "$path" 2>/dev/null || true
  done < <(selinux_collectors)

  echo "INFO: Removed STATUS SELinux fcontext entries for local collectors when present."
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
host_ip="$(
  {
    (hostname -I 2>/dev/null || true) | awk '{
      for (i=1; i<=NF; i++) {
        if (first == "" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^127\./) {
          first=$i
        }
      }
    } END{if (first != "") print first}'
    (ip -o -4 addr show scope global 2>/dev/null || true) | awk '{
      addr=$4
      sub(/\/.*/, "", addr)
      if (first == "" && addr !~ /^127\./) {
        first=addr
      }
    } END{if (first != "") print first}'
  } | awk 'NF && first == ""{first=$0} END{if (first != "") print first}'
)"
[[ -n "${host_ip:-}" ]] || host_ip="UNKNOWN"
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
echo "Host IP       : $host_ip"
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
hostip="$(getv "Host IP")"
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

fetch_github_tags() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --connect-timeout 3 --max-time 5 \
    "https://api.github.com/repos/daroitgo/itgo-scripts/git/matching-refs/tags/" 2>/dev/null
}

github_tags="$(fetch_github_tags || true)"
github_tags_ok="NO"
[[ -n "${github_tags:-}" ]] && github_tags_ok="YES"

github_latest_for() {
  local prefix="$1" latest
  if [[ "$github_tags_ok" != "YES" ]]; then
    echo "UNKNOWN"
    return
  fi

  latest="$(
    printf "%s\n" "$github_tags" \
    | sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"refs\/tags\/\([^"]*\)".*/\1/p' \
    | awk -v p="$prefix" 'index($0,p)==1 {print substr($0, length(p)+1)}' \
    | awk 'NF' \
    | sort -V \
    | tail -n1
  )"
  [[ -n "${latest:-}" ]] && echo "$latest" || echo "UNKNOWN"
}

module_state_text() {
  local inst="$1" local_ver="$2" github_ver="$3" highest
  if [[ "$inst" == "NO" ]]; then
    echo "NOT INSTALLED"
  elif [[ "$github_ver" == "UNKNOWN" ]]; then
    echo "CHECK FAILED"
  elif [[ "$local_ver" == "$github_ver" ]]; then
    echo "OK"
  elif [[ "$local_ver" == "UNKNOWN" ]]; then
    echo "CHECK MANUALLY"
  else
    highest="$(printf "%s\n%s\n" "$local_ver" "$github_ver" | sort -V | tail -n1)"
    if [[ "$highest" == "$github_ver" ]]; then
      echo "UPDATE REQUIRED"
    elif [[ "$highest" == "$local_ver" ]]; then
      echo "LOCAL NEWER"
    else
      echo "CHECK MANUALLY"
    fi
  fi
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

status_github_ver="$(github_latest_for "status-")"
upg_cleanup_github_ver="$(github_latest_for "cleanup-")"
tseq_github_ver="$(github_latest_for "tseq-")"
downloader_github_ver="$(github_latest_for "downloader_app-")"
upgbuilder_github_ver="$(github_latest_for "upgbuilder-")"

status_mod_state="$(module_state_text "$status_installed" "$inst_ver" "$status_github_ver")"
upg_cleanup_mod_state="$(module_state_text "$upg_cleanup_installed" "$upg_cleanup_ver" "$upg_cleanup_github_ver")"
tseq_mod_state="$(module_state_text "$tseq_installed" "$tseq_ver" "$tseq_github_ver")"
downloader_mod_state="$(module_state_text "$downloader_installed" "$downloader_ver" "$downloader_github_ver")"
upgbuilder_mod_state="$(module_state_text "$upgbuilder_installed" "$upgbuilder_ver" "$upgbuilder_github_ver")"

upg_cleanup_hook="NO"
if [[ -f "$HOME/.bashrc" ]] && grep -qF "# >>> UPG XML cleanup (auto) >>>" "$HOME/.bashrc" 2>/dev/null; then
  upg_cleanup_hook="YES"
fi

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

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

terminal_width() {
  local cols
  cols="$(tput cols 2>/dev/null || echo 100)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
  ((cols > 0)) || cols=100
  echo "$cols"
}

use_utf8_box() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*) return 0 ;;
    *) return 1 ;;
  esac
}

setup_box_chars() {
  if use_utf8_box; then
    BOX_TL="┌"; BOX_H="─"; BOX_TR="┐"; BOX_V="│"; BOX_BL="└"; BOX_BR="┘"
  else
    BOX_TL="+"; BOX_H="-"; BOX_TR="+"; BOX_V="|"; BOX_BL="+"; BOX_BR="+"
  fi
}

strip_ansi() {
  printf "%s" "$1" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'
}

visible_len() {
  local clean
  clean="$(strip_ansi "$1")"
  printf "%s" "${#clean}"
}

repeat_char() {
  local ch="$1" n="$2" out="" i
  ((n < 0)) && n=0
  for ((i=0; i<n; i++)); do out="${out}${ch}"; done
  printf "%s" "$out"
}

trim_visible() {
  local s="$1" w="$2" clean
  if (($(visible_len "$s") <= w)); then
    printf "%s" "$s"
    return
  fi
  clean="$(strip_ansi "$s")"
  if ((w <= 3)); then
    printf "%s" "${clean:0:w}"
  else
    printf "%s..." "${clean:0:$((w-3))}"
  fi
}

trim2(){ trim_visible "$1" "$2"; }

pad_visible() {
  local s="$1" w="$2" out len
  out="$(trim_visible "$s" "$w")"
  len="$(visible_len "$out")"
  printf "%s%s" "$out" "$(repeat_char " " "$((w-len))")"
}

color_state() {
  local state="$1"
  case "$state" in
    OK) printf "%s" "${GREEN}${state}${RESET}" ;;
    "UPDATE REQUIRED"|*"SECURITY"*UPDATE*) printf "%s" "${RED}${state}${RESET}" ;;
    "NOT INSTALLED"|"CHECK FAILED") printf "%s" "${YELLOW}${state}${RESET}" ;;
    *) printf "%s" "$state" ;;
  esac
}

color_update_value() {
  local value="$1"
  if [[ "$value" == "OK" ]]; then
    printf "%s" "${GREEN}${value}${RESET}"
  elif echo "$value" | grep -qi "UPDATE"; then
    printf "%s" "${RED}${value}${RESET}"
  else
    printf "%s" "$value"
  fi
}

module_state_color() {
  color_state "$1"
}

wrap_words() {
  local text="$1" width="$2" indent="${3:-0}" line="" prefix word
  prefix="$(repeat_char " " "$indent")"
  [[ -n "${text:-}" ]] || text="UNKNOWN"
  for word in $text; do
    if [[ -z "$line" ]]; then
      line="$word"
    elif ((${#line} + 1 + ${#word} > width)); then
      printf "%s\n" "$line"
      line="${prefix}${word}"
    else
      line="${line} ${word}"
    fi
  done
  [[ -n "$line" ]] && printf "%s\n" "$line"
}

kv_line() {
  local key="$1" value="$2" width="$3" key_w=10 avail
  avail="$((width - key_w - 1))"
  ((avail < 8)) && avail=8
  printf "%-${key_w}s %s" "$key" "$(trim_visible "${value:-UNKNOWN}" "$avail")"
}

render_box() {
  local title="$1" width="$2" body="$3" inner top_title top_fill line
  ((width < 24)) && width=24
  inner="$((width - 4))"
  top_title=" ${title} "
  top_fill="$((width - 2 - $(visible_len "$top_title")))"
  printf "%s%s%s%s\n" "$BOX_TL" "$top_title" "$(repeat_char "$BOX_H" "$top_fill")" "$BOX_TR"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf "%s %s %s\n" "$BOX_V" "$(pad_visible "$line" "$inner")" "$BOX_V"
  done <<< "$body"
  printf "%s%s%s\n" "$BOX_BL" "$(repeat_char "$BOX_H" "$((width - 2))")" "$BOX_BR"
}

box_to_array() {
  local arr_name="$1" title="$2" width="$3" body="$4" line
  if [[ "$arr_name" == "left_box" ]]; then
    left_box=()
  else
    right_box=()
  fi
  while IFS= read -r line; do
    if [[ "$arr_name" == "left_box" ]]; then
      left_box+=("$line")
    else
      right_box+=("$line")
    fi
  done < <(render_box "$title" "$width" "$body")
}

render_two_boxes() {
  local title1="$1" body1="$2" title2="$3" body2="$4" cols="$5"
  local gap=2 width left_count right_count max_lines i
  if ((cols >= 110)); then
    width="$(( (cols - gap) / 2 ))"
    ((width > 64)) && width=64
    box_to_array left_box "$title1" "$width" "$body1"
    box_to_array right_box "$title2" "$width" "$body2"
    left_count="${#left_box[@]}"
    right_count="${#right_box[@]}"
    max_lines="$left_count"
    ((right_count > max_lines)) && max_lines="$right_count"
    for ((i=0; i<max_lines; i++)); do
      printf "%s%s%s\n" "$(pad_visible "${left_box[$i]-}" "$width")" "$(repeat_char " " "$gap")" "${right_box[$i]-}"
    done
  else
    width="$cols"
    ((width > 90)) && width=90
    render_box "$title1" "$width" "$body1"
    echo
    render_box "$title2" "$width" "$body2"
  fi
}

update_short() {
  local st="${1:-UNKNOWN}" ts="${2:-UNKNOWN}" now upd age
  if echo "$st" | grep -qi "^OK"; then
    echo "OK"
  elif echo "$st" | grep -qi "UPDATE REQUIRED"; then
    now="$(date +%s 2>/dev/null || echo 0)"
    upd="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
    if [[ "$now" -gt 0 && "$upd" -gt 0 ]]; then
      age="$(( (now - upd) / 86400 ))"
      echo "${age}d UPDATE"
    else
      echo "UPDATE"
    fi
  else
    echo "${st:-UNKNOWN}"
  fi
}

security_short() {
  local st="${1:-UNKNOWN}" n
  if echo "$st" | grep -qi "^OK"; then
    echo "OK"
  elif echo "$st" | grep -qi "SECURITY UPDATES AVAILABLE"; then
    n="$(echo "$st" | sed -n 's/.*(\([0-9][0-9]*\)).*/\1/p')"
    [[ -n "${n:-}" ]] && echo "${n} UPDATE" || echo "UPDATE"
  else
    echo "${st:-UNKNOWN}"
  fi
}

firewall_ports_display() {
  local active="$1" ports="$2" zone
  [[ -n "${ports:-}" ]] || { echo "UNKNOWN"; return; }
  zone="${active%%(*}"
  if [[ "$ports" == "${zone}:"* && "$ports" != *" | "* ]]; then
    ports="${ports#${zone}:}"
  fi
  echo "$ports"
}

firewall_services_display() {
  local active="$1" services="$2" zone
  [[ -n "${services:-}" ]] || { echo "UNKNOWN"; return; }
  zone="${active%%(*}"
  if [[ "$services" == "${zone}:"* && "$services" != *" | "* ]]; then
    services="${services#${zone}:}"
  fi
  echo "$services"
}

module_local_display() {
  local inst="$1" local_ver="$2"
  if [[ "$inst" == "NO" && "$local_ver" == "UNKNOWN" ]]; then
    echo "-"
  else
    echo "$local_ver"
  fi
}

module_row() {
  local name="$1" inst="$2" local_ver="$3" github_ver="$4" state="$5"
  printf "%-11s %-4s %-8s %-8s %s" \
    "$name" "$inst" "$(module_local_display "$inst" "$local_ver")" "$github_ver" "$(module_state_color "$state")"
}

runtime_state_color() {
  local state="$1"
  case "$state" in
    active|running) printf "%s" "${GREEN}${state}${RESET}" ;;
    failed|dead) printf "%s" "${RED}${state}${RESET}" ;;
    inactive|stopped|unknown) printf "%s" "${YELLOW}${state}${RESET}" ;;
    *) printf "%s" "$state" ;;
  esac
}

apps_row() {
  local app="$1" state="$2" logs="$3" unit="$4" hint="$5"
  local app_w="$6" state_w="$7" logs_w="$8" unit_w="$9" hint_w="${10}"
  printf "%s %s %s %s %s" \
    "$(pad_visible "${app:-APP}" "$app_w")" \
    "$(pad_visible "$(runtime_state_color "${state:-unknown}")" "$state_w")" \
    "$(pad_visible "${logs:-n/a}" "$logs_w")" \
    "$(pad_visible "${unit:-unknown}" "$unit_w")" \
    "$(trim_visible "${hint:-UNKNOWN}" "$hint_w")"
}

docker_info_row() {
  local label="$1" value="$2" width="$3"
  printf "%-8s %s" "$label" "$(trim_visible "${value:-UNKNOWN}" "$((width - 9))")"
}

setup_box_chars
cols="$(terminal_width)"
dashboard_w="$cols"
((dashboard_w > 132)) && dashboard_w=132

host_value="${host:-UNKNOWN}"
if [[ -n "${hostip:-}" && "${hostip:-UNKNOWN}" != "UNKNOWN" ]]; then
  host_value="${host_value}  IP ${hostip}"
fi
os_update="$(update_short "$status" "$updated")"
sec_update="$(security_short "$secupd")"
updates_value="OS $(color_update_value "$os_update") | Security $(color_update_value "$sec_update")"
support_value="${support:-UNKNOWN} [${supportsrc:-local-db}]"

server_body=""
server_body+="$(kv_line "Host" "$host_value" 54)"$'\n'
server_body+="$(kv_line "OS" "${os:-UNKNOWN}" 54)"$'\n'
server_body+="$(kv_line "Kernel" "${kernel:-UNKNOWN}" 54)"$'\n'
server_body+="$(kv_line "Java" "${java:-UNKNOWN}" 54)"$'\n'
server_body+="$(kv_line "Updates" "$updates_value" 54)"$'\n'
server_body+="$(kv_line "Support" "$support_value" 54)"

fw_ports="$(firewall_ports_display "${fw_active:-UNKNOWN}" "${fw_pm_ports:-UNKNOWN}")"
fw_services="$(firewall_services_display "${fw_active:-UNKNOWN}" "${fw_pm_services:-UNKNOWN}")"
firewall_body=""
firewall_body+="$(kv_line "Zone" "${fw_active:-UNKNOWN}" 54)"$'\n'
firewall_body+="Ports"$'\n'
while IFS= read -r line; do
  firewall_body+="  ${line}"$'\n'
done < <(wrap_words "$fw_ports" 48 2)
if [[ -n "$fw_services" && "$fw_services" != "UNKNOWN" && "$fw_services" != "(none)" ]]; then
  firewall_body+="Services"$'\n'
  while IFS= read -r line; do
    firewall_body+="  ${line}"$'\n'
  done < <(wrap_words "$fw_services" 48 2)
fi
firewall_body="${firewall_body%$'\n'}"

echo
render_two_boxes "SERVER ${collected:-UNKNOWN}" "$server_body" "FIREWALL" "$firewall_body" "$cols"

modules_w="$dashboard_w"
((modules_w > 76)) && modules_w=76
modules_body=""
modules_body+="$(printf "%-11s %-4s %-8s %-8s %s" "MODULE" "INST" "LOCAL" "GITHUB" "STATE")"$'\n'
modules_body+="$(printf "%-11s %-4s %-8s %-8s %s" "-----------" "----" "--------" "--------" "----------------")"$'\n'
modules_body+="$(module_row "StatusInst" "${status_installed:-NO}" "${inst_ver:-UNKNOWN}" "${status_github_ver:-UNKNOWN}" "$status_mod_state")"$'\n'
modules_body+="$(module_row "UPGclean" "${upg_cleanup_installed:-NO}" "${upg_cleanup_ver:-UNKNOWN}" "${upg_cleanup_github_ver:-UNKNOWN}" "$upg_cleanup_mod_state")"$'\n'
modules_body+="$(module_row "TSEQ" "${tseq_installed:-NO}" "${tseq_ver:-UNKNOWN}" "${tseq_github_ver:-UNKNOWN}" "$tseq_mod_state")"$'\n'
modules_body+="$(module_row "Downloader" "${downloader_installed:-NO}" "${downloader_ver:-UNKNOWN}" "${downloader_github_ver:-UNKNOWN}" "$downloader_mod_state")"$'\n'
modules_body+="$(module_row "UPGbuilder" "${upgbuilder_installed:-NO}" "${upgbuilder_ver:-UNKNOWN}" "${upgbuilder_github_ver:-UNKNOWN}" "$upgbuilder_mod_state")"$'\n'
modules_body+="${DIM}UPGclean hook: bashrc:${upg_cleanup_hook}${RESET}"

echo
render_box "MODULES" "$modules_w" "$modules_body"

echo
apps_w="$dashboard_w"
((apps_w > 100)) && apps_w=100
apps_inner="$((apps_w - 4))"
app_w=10
app_state_w=8
app_logs_w=8
app_unit_w=20
app_hint_w="$((apps_inner - app_w - app_state_w - app_logs_w - app_unit_w - 4))"
if ((app_hint_w < 10)); then
  app_unit_w=16
  app_hint_w="$((apps_inner - app_w - app_state_w - app_logs_w - app_unit_w - 4))"
fi
if ((app_hint_w < 8)); then
  app_w=8
  app_state_w=7
  app_logs_w=7
  app_unit_w=12
  app_hint_w="$((apps_inner - app_w - app_state_w - app_logs_w - app_unit_w - 4))"
fi
((app_hint_w < 6)) && app_hint_w=6

apps_body=""
apps_body+="$(apps_row "APP" "STATE" "LOGS" "UNIT" "HINT" "$app_w" "$app_state_w" "$app_logs_w" "$app_unit_w" "$app_hint_w")"$'\n'
apps_body+="$(apps_row "--------" "--------" "------" "----------------" "----------------" "$app_w" "$app_state_w" "$app_logs_w" "$app_unit_w" "$app_hint_w")"
if [[ -f "$APPS" ]]; then
  apps_count=0
  while IFS=$'\t' read -r app unit hint logsbytes; do
    apps_count="$((apps_count + 1))"
    st="$(svc_state "$unit")"
    logs="$(hr_bytes "${logsbytes:-}")"
    apps_body+=$'\n'
    apps_body+="$(apps_row "${app:-APP}" "${st:-unknown}" "${logs:-n/a}" "${unit:-unknown}" "${hint:-UNKNOWN}" "$app_w" "$app_state_w" "$app_logs_w" "$app_unit_w" "$app_hint_w")"
  done < <(awk -F'\t' '$1=="SVC"{print $2 "\t" $3 "\t" $4 "\t" $7}' "$APPS" 2>/dev/null)
  if [[ "${apps_count:-0}" -eq 0 ]]; then
    apps_body="no app services in cache; run: status -r"
  fi
else
  apps_body="no apps cache; run: status -r"
fi
render_box "APPS" "$apps_w" "$apps_body"

command -v docker >/dev/null 2>&1 || { echo; exit 0; }

dockerv="$(docker --version 2>/dev/null | tr -d '\r' || echo UNKNOWN)"
composev="NOT_INSTALLED"
if docker compose version >/dev/null 2>&1; then
  composev="$(docker compose version 2>/dev/null | head -n1 | tr -d '\r' || echo UNKNOWN)"
elif command -v docker-compose >/dev/null 2>&1; then
  composev="$(docker-compose --version 2>/dev/null | tr -d '\r' || echo UNKNOWN)"
fi

docker_w="$dashboard_w"
((docker_w > 90)) && docker_w=90
docker_body=""
docker_body+="$(docker_info_row "Docker" "$dockerv" "$((docker_w - 4))")"$'\n'
docker_body+="$(docker_info_row "Compose" "$composev" "$((docker_w - 4))")"

echo
render_box "DOCKER / COMPOSE" "$docker_w" "$docker_body"

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

compose_w="$dashboard_w"
((compose_w > 100)) && compose_w=100
compose_inner="$((compose_w - 4))"
compose_sys_w=10
compose_state_w=8
compose_logs_w=8
compose_unit_w=20
compose_hint_w="$((compose_inner - compose_sys_w - compose_state_w - compose_logs_w - compose_unit_w - 4))"
if ((compose_hint_w < 10)); then
  compose_unit_w=16
  compose_hint_w="$((compose_inner - compose_sys_w - compose_state_w - compose_logs_w - compose_unit_w - 4))"
fi
if ((compose_hint_w < 8)); then
  compose_sys_w=8
  compose_state_w=7
  compose_logs_w=7
  compose_unit_w=12
  compose_hint_w="$((compose_inner - compose_sys_w - compose_state_w - compose_logs_w - compose_unit_w - 4))"
fi
((compose_hint_w < 6)) && compose_hint_w=6

compose_body=""
compose_body+="$(apps_row "SYSTEM" "STATE" "LOGS" "UNIT" "HINT" "$compose_sys_w" "$compose_state_w" "$compose_logs_w" "$compose_unit_w" "$compose_hint_w")"$'\n'
compose_body+="$(apps_row "--------" "--------" "------" "----------------" "----------------" "$compose_sys_w" "$compose_state_w" "$compose_logs_w" "$compose_unit_w" "$compose_hint_w")"

if ((${#G_PROJS[@]} > 0)); then
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
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

    compose_body+=$'\n'
    compose_body+="$(apps_row "${sys:-UNKNOWN}" "${state:-unknown}" "${logs:-n/a}" "${unit:-unknown}" "${hint:-UNKNOWN}" "$compose_sys_w" "$compose_state_w" "$compose_logs_w" "$compose_unit_w" "$compose_hint_w")"
  done < <(printf "%s\n" "${!G_PROJS[@]}" | sort)
else
  compose_body="no compose projects in cache; run: status -r"
fi

echo
render_box "DOCKER COMPOSE PROJECTS" "$compose_w" "$compose_body"

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
  configure_collectors_selinux
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
  remove_collectors_selinux_fcontext
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
