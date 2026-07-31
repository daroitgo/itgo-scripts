#!/usr/bin/env bash
# shellcheck shell=bash

# Re-exec in bash if started by sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

# ==========================================================
# ITGO Master Installer
#
# HOME structure (itgo):
#   ~/UPG
#   ~/BACKUP
#   ~/UTILITY/
#     LOG/OTHER   (master + install logs)
#     LOG/UPDATE  (reserved for update scripts)
#     TMP         (downloaded installers)
#
# Modules:
# - server-status installer (downloaded via wget)
# - SSH history prompt (single block; removes old status-installer block)
# - cleanup installer (downloaded via wget)
# - tseq installer (downloaded via wget)
# - downloader app installer deploy (downloaded via wget)
#
# Extra steps:
# - optional install/check of nano, mc, rsync, dos2unix, jq, wget
# - optional ~/.bash_logout history cleanup block
# - optional add user to docker group
#
# NOTE:
# - Asks before each module.
# - BOOTSTRAP is one question (user + dirs + sudoers + ACL + docker group).
# - Cleans downloaded *.sh from TMP at the end (asks).
# - Bash backups are kept as single .bak files (no timestamp pile-up).
# ==========================================================
MASTER_VERSION="1.2.74"

# >>> AUTO-MODULE-VERSIONS START >>>
STATUS_VERSION="3.12.19"
CLEANUP_VERSION="1.0.3"
TSEQ_VERSION="3.12.9"
DOWNLOADER_APP_VERSION="1.0.4"
UPGBUILDER_VERSION="0.1.12"
SERVICEGUARD_VERSION="0.1.6"
INVENTORY_VERSION="0.1.9"

MODE="install"
UPDATE_ONLY_MODE="0"

if [[ "${1:-}" == "--update-only" ]]; then
  MODE="update-only"
  UPDATE_ONLY_MODE="1"
  TARGET_USER="${2:-itgo}"
else
  TARGET_USER="${1:-itgo}"
fi

GITHUB_OWNER="daroitgo"
GITHUB_REPO="itgo-scripts"

STATUS_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/status-${STATUS_VERSION}/STATUS/status_installer_public.sh"
CLEANUP_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/cleanup-${CLEANUP_VERSION}/CLEANUP/cleanup_installer_public.sh"
TSEQ_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/tseq-${TSEQ_VERSION}/TSEQ/tseq_installer_public.sh"
DOWNLOADER_APP_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/downloader_app-${DOWNLOADER_APP_VERSION}/DOWNLOADER_APP/upg_installer.sh"
UPGBUILDER_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/upgbuilder-${UPGBUILDER_VERSION}/UPGBUILDER/upgbuilder.sh"
SERVICEGUARD_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/serviceguard-${SERVICEGUARD_VERSION}/SERVICEGUARD/serviceguard_installer_public.sh"
INVENTORY_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/inventory-${INVENTORY_VERSION}/INVENTORY/inventory_installer_public.sh"
# <<< AUTO-MODULE-VERSIONS END <<<
CLIENT_CATALOG_URL="https://helpdesk.itgo.com.pl/nextcloud/index.php/s/FFbZwPNHtegWXo4/download"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SOURCE_DIR:-}"

if [[ -z "$SOURCE_DIR" && -d "$SCRIPT_DIR/../STATUS" && -d "$SCRIPT_DIR/../UPGBUILDER" ]]; then
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

OFFLINE_MODE="0"
if [[ -n "$SOURCE_DIR" ]]; then
  OFFLINE_MODE="1"
fi

STATUS_LOCAL_PATH="${SOURCE_DIR}/STATUS/status_installer_public.sh"
CLEANUP_LOCAL_PATH="${SOURCE_DIR}/CLEANUP/cleanup_installer_public.sh"
TSEQ_LOCAL_PATH="${SOURCE_DIR}/TSEQ/tseq_installer_public.sh"
DOWNLOADER_APP_LOCAL_PATH="${SOURCE_DIR}/DOWNLOADER_APP/upg_installer.sh"
UPGBUILDER_LOCAL_PATH="${SOURCE_DIR}/UPGBUILDER/upgbuilder.sh"
SERVICEGUARD_LOCAL_PATH="${SOURCE_DIR}/SERVICEGUARD/serviceguard_installer_public.sh"
INVENTORY_LOCAL_DIR="${SOURCE_DIR}/INVENTORY"
INVENTORY_LOCAL_PATH="${INVENTORY_LOCAL_DIR}/inventory_installer_public.sh"
UPGBUILDER_LOCAL_MAP="${SOURCE_DIR}/UPGBUILDER/upgbuilder.map"
UPGBUILDER_LOCAL_TEMPLATE_DIR="${SOURCE_DIR}/UPGBUILDER/template"

TMP_LOG=""
OS_FAMILY=""

ts() { date "+%F %T"; }

init_tmp_log_if_needed() {
  [[ -n "${TMP_LOG:-}" ]] && return 0

  local target_home log_dir
  target_home="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}' || true)"
  if [[ -n "${target_home:-}" ]]; then
    log_dir="$target_home/UTILITY/LOG/OTHER"
  else
    log_dir="/root/UTILITY/LOG/OTHER"
  fi

  mkdir -p "$log_dir" 2>/dev/null || true
  if [[ -n "${target_home:-}" && -d "$log_dir" ]]; then
    chown "$TARGET_USER:$TARGET_USER" "$target_home/UTILITY" "$target_home/UTILITY/LOG" "$log_dir" 2>/dev/null || true
  fi
  chmod 0755 "$log_dir" 2>/dev/null || true

  TMP_LOG="$log_dir/master-install.prelog_$(date +%Y%m%d_%H%M%S).log"
  touch "$TMP_LOG" 2>/dev/null || true
  if [[ -n "${target_home:-}" && -f "$TMP_LOG" ]]; then
    chown "$TARGET_USER:$TARGET_USER" "$TMP_LOG" 2>/dev/null || true
  fi
  chmod 0644 "$TMP_LOG" 2>/dev/null || true
}

prelog() {
  init_tmp_log_if_needed
  echo "[$(ts)] $*" | tee -a "$TMP_LOG" >/dev/null
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: uruchom jako root: sudo bash $0 [user]"
    exit 1
  fi
}

prompt_yn() {
  local q="${1:?}" def="${2:-N}" ans=""
  while true; do
    if [[ "$def" == "Y" ]]; then
      printf "%s" "$q [Y/n]: " >&2
      read -r ans || true
      ans="${ans:-Y}"
    else
      printf "%s" "$q [y/N]: " >&2
      read -r ans || true
      ans="${ans:-N}"
    fi

    ans="${ans//$'\r'/}"
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    ans="${ans,,}"

    case "$ans" in
      y|yes|t|tak)   return 0 ;;
      n|no|nie)      return 1 ;;
      *) echo "Wpisz: y/yes/t/tak albo n/no/nie." >&2 ;;
    esac
  done
}

have_user() { id "$TARGET_USER" >/dev/null 2>&1; }

resolve_home() {
  local h
  h="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}' || true)"
  [[ -n "${h:-}" ]] || return 1
  echo "$h"
}

detect_os_family() {
  local ids="" lower=""

  if [[ -r /etc/os-release ]]; then
    ids="$(
      . /etc/os-release 2>/dev/null || true
      printf "%s %s\n" "${ID:-}" "${ID_LIKE:-}"
    )"
  fi

  lower="${ids,,}"
  case "$lower" in
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*' ol '*|ol\ *|*\ ol|*oracle*) printf "rhel_family\n" ;;
    *debian*|*ubuntu*) printf "debian_family\n" ;;
    *) printf "unknown\n" ;;
  esac
}

os_family() {
  if [[ -z "${OS_FAMILY:-}" ]]; then
    OS_FAMILY="$(detect_os_family)"
  fi
  printf "%s\n" "$OS_FAMILY"
}

has_package_manager() {
  command -v dnf >/dev/null 2>&1 \
    || command -v yum >/dev/null 2>&1 \
    || command -v apt-get >/dev/null 2>&1
}

pkg_is_installed() {
  local pkg="${1:?}"
  local family

  family="$(os_family)"
  case "$family" in
    rhel_family)
      if ! command -v rpm >/dev/null 2>&1; then
        echo "[$(ts)] WARN: rpm unavailable; cannot verify package: $pkg" >&2
        return 1
      fi
      rpm -q "$pkg" >/dev/null 2>&1
      ;;
    debian_family)
      if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q "install ok installed"
      elif command -v dpkg >/dev/null 2>&1; then
        dpkg -s "$pkg" >/dev/null 2>&1
      else
        echo "[$(ts)] WARN: dpkg/dpkg-query unavailable; cannot verify package: $pkg" >&2
        return 1
      fi
      ;;
    *)
      echo "[$(ts)] WARN: unknown OS family; cannot verify package: $pkg" >&2
      return 1
      ;;
  esac
}

pkg_installed() {
  pkg_is_installed "$@"
}

install_packages() {
  local missing=("$@")
  [[ "${#missing[@]}" -gt 0 ]] || return 0

  if command -v dnf >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: dnf -y install ${missing[*]}"
    dnf -y install "${missing[@]}"
  elif command -v yum >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: yum -y install ${missing[*]}"
    yum -y install "${missing[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: apt-get update"
    apt-get update
    echo "[$(ts)] ACTION: DEBIAN_FRONTEND=noninteractive apt-get install -y ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    echo "[$(ts)] ERROR: brak obsługiwanego package managera (dnf/yum/apt-get)."
    return 1
  fi
}

ensure_package_installed() {
  local pkg="${1:?}"

  if pkg_installed "$pkg"; then
    echo "[$(ts)] OK: package already installed: $pkg"
    return 0
  fi

  echo "[$(ts)] INFO: missing package: $pkg"
  install_packages "$pkg"
}

remove_packages() {
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0

  if command -v dnf >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: dnf -y remove ${pkgs[*]}"
    dnf -y remove "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: yum -y remove ${pkgs[*]}"
    yum -y remove "${pkgs[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: DEBIAN_FRONTEND=noninteractive apt-get remove -y ${pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkgs[@]}"
  else
    echo "[$(ts)] ERROR: brak obsługiwanego package managera (dnf/yum/apt-get)."
    return 1
  fi
}

get_command_invocation_path() {
  local cmd="${1:?}"
  command -v "$cmd" 2>/dev/null || true
}

get_active_command_path() {
  local cmd="${1:?}"
  local cmd_path=""

  cmd_path="$(get_command_invocation_path "$cmd")"
  [[ -n "$cmd_path" ]] || return 1

  readlink -f "$cmd_path" 2>/dev/null || printf "%s\n" "$cmd_path"
}

pkg_owner_of_path() {
  local path="${1:?}"
  local owner=""

  [[ -e "$path" ]] || return 0
  case "$(os_family)" in
    rhel_family)
      command -v rpm >/dev/null 2>&1 || return 0
      rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null | head -n 1 || true
      ;;
    debian_family)
      command -v dpkg-query >/dev/null 2>&1 || return 0
      owner="$(dpkg-query -S "$path" 2>/dev/null | head -n 1 || true)"
      owner="${owner%%:*}"
      printf "%s\n" "$owner"
      ;;
    *)
      return 0
      ;;
  esac
}

command_reports_java8() {
  local cmd="${1:?}"
  local out=""

  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 1
  fi

  out="$("$cmd" -version 2>&1 || true)"
  [[ "$out" == *' 1.8.'* || "$out" == *'"1.8.'* || "$out" == *'version "8.'* || "$out" == *'openjdk version "1.8.'* ]]
}

is_amcs_java_runtime_owner_compatible() {
  local owner="${1:-}"
  case "$owner" in
    java-1.8.0-openjdk|java-1.8.0-openjdk-headless|java-1.8.0-openjdk-devel) return 0 ;;
    *) return 1 ;;
  esac
}

is_amcs_javac_owner_compatible() {
  local owner="${1:-}"
  case "$owner" in
    java-1.8.0-openjdk-devel) return 0 ;;
    *) return 1 ;;
  esac
}

remove_unmanaged_local_java_wrappers() {
  local cmd raw_path resolved_path owner

  for cmd in java javac; do
    raw_path="$(get_command_invocation_path "$cmd")"
    [[ -n "$raw_path" ]] || continue

    if [[ "$raw_path" != "/usr/local/bin/$cmd" ]]; then
      continue
    fi

    resolved_path="$(readlink -f "$raw_path" 2>/dev/null || printf "%s\n" "$raw_path")"
    owner="$(pkg_owner_of_path "$raw_path" 2>/dev/null || true)"
    if [[ -z "$owner" && "$resolved_path" != /usr/bin/* ]]; then
      echo "[$(ts)] ACTION: removing unmanaged local $cmd wrapper: $raw_path"
      rm -f "$raw_path"
    fi
  done
}

collect_amcs_java_state() {
  local java_raw_path="" javac_raw_path="" java_path="" javac_path="" java_owner="" javac_owner=""
  local java_ok="0" javac_ok="0"

  java_raw_path="$(get_command_invocation_path java)"
  javac_raw_path="$(get_command_invocation_path javac)"
  java_path="$(get_active_command_path java 2>/dev/null || true)"
  javac_path="$(get_active_command_path javac 2>/dev/null || true)"

  if [[ -n "$java_path" ]]; then
    java_owner="$(pkg_owner_of_path "$java_path" 2>/dev/null || true)"
  fi
  if [[ -n "$javac_path" ]]; then
    javac_owner="$(pkg_owner_of_path "$javac_path" 2>/dev/null || true)"
  fi

  if command_reports_java8 java && is_amcs_java_runtime_owner_compatible "$java_owner"; then
    java_ok="1"
  fi
  if command_reports_java8 javac && is_amcs_javac_owner_compatible "$javac_owner"; then
    javac_ok="1"
  fi

  printf "java_raw_path=%s\n" "${java_raw_path:-}"
  printf "java_path=%s\n" "${java_path:-}"
  printf "java_owner=%s\n" "${java_owner:-}"
  printf "java_ok=%s\n" "$java_ok"
  printf "javac_raw_path=%s\n" "${javac_raw_path:-}"
  printf "javac_path=%s\n" "${javac_path:-}"
  printf "javac_owner=%s\n" "${javac_owner:-}"
  printf "javac_ok=%s\n" "$javac_ok"
}

ensure_amcs_java_runtime() {
  local target_pkg="java-1.8.0-openjdk-devel"
  local state="" line=""
  local java_raw_path="" javac_raw_path="" java_path="" javac_path="" java_owner="" javac_owner=""
  local java_ok="0" javac_ok="0"
  local remove_list=()

  if [[ "$(os_family)" != "rhel_family" ]]; then
    echo "[$(ts)] SKIP: AMCS Java 8 package enforcement is currently implemented for RHEL/RPM package names only."
    echo "[$(ts)] INFO: Debian/Ubuntu AMCS Java package naming is not enforced by MASTER yet."
    add_summary "AMCS Java runtime: SKIP (non-RHEL package naming not enforced)"
    return 0
  fi

  remove_unmanaged_local_java_wrappers

  state="$(collect_amcs_java_state)"
  while IFS= read -r line; do
    case "$line" in
      java_raw_path=*) java_raw_path="${line#java_raw_path=}" ;;
      java_path=*)  java_path="${line#java_path=}" ;;
      java_owner=*) java_owner="${line#java_owner=}" ;;
      java_ok=*)    java_ok="${line#java_ok=}" ;;
      javac_raw_path=*) javac_raw_path="${line#javac_raw_path=}" ;;
      javac_path=*) javac_path="${line#javac_path=}" ;;
      javac_owner=*) javac_owner="${line#javac_owner=}" ;;
      javac_ok=*)   javac_ok="${line#javac_ok=}" ;;
    esac
  done <<< "$state"

  echo "[$(ts)] INFO: active java command path: ${java_raw_path:-MISSING}"
  echo "[$(ts)] INFO: active java path: ${java_path:-MISSING}"
  echo "[$(ts)] INFO: active java package owner: ${java_owner:-UNKNOWN}"
  echo "[$(ts)] INFO: active javac command path: ${javac_raw_path:-MISSING}"
  echo "[$(ts)] INFO: active javac path: ${javac_path:-MISSING}"
  echo "[$(ts)] INFO: active javac package owner: ${javac_owner:-UNKNOWN}"

  if pkg_installed "$target_pkg" && [[ "$java_ok" == "1" && "$javac_ok" == "1" ]]; then
    echo "[$(ts)] OK: active java and javac already match Java 8 from $target_pkg"
    add_summary "AMCS Java runtime: OK ($target_pkg already active)"
    return 0
  fi

  if [[ -n "$java_owner" ]] && ! is_amcs_java_runtime_owner_compatible "$java_owner"; then
    remove_list+=("$java_owner")
  fi
  if [[ -n "$javac_owner" ]] && ! is_amcs_javac_owner_compatible "$javac_owner" && [[ "$javac_owner" != "$java_owner" ]]; then
    remove_list+=("$javac_owner")
  fi

  if [[ "${#remove_list[@]}" -gt 0 ]]; then
    echo "[$(ts)] INFO: removing incompatible active Java package(s): ${remove_list[*]}"
    remove_packages "${remove_list[@]}"
  fi

  ensure_package_installed "$target_pkg"
  remove_unmanaged_local_java_wrappers

  state="$(collect_amcs_java_state)"
  java_raw_path=""
  java_path=""
  javac_raw_path=""
  javac_path=""
  java_owner=""
  javac_owner=""
  java_ok="0"
  javac_ok="0"
  while IFS= read -r line; do
    case "$line" in
      java_raw_path=*) java_raw_path="${line#java_raw_path=}" ;;
      java_path=*)  java_path="${line#java_path=}" ;;
      java_owner=*) java_owner="${line#java_owner=}" ;;
      java_ok=*)    java_ok="${line#java_ok=}" ;;
      javac_raw_path=*) javac_raw_path="${line#javac_raw_path=}" ;;
      javac_path=*) javac_path="${line#javac_path=}" ;;
      javac_owner=*) javac_owner="${line#javac_owner=}" ;;
      javac_ok=*)   javac_ok="${line#javac_ok=}" ;;
    esac
  done <<< "$state"

  echo "[$(ts)] INFO: post-install active java command path: ${java_raw_path:-MISSING}"
  echo "[$(ts)] INFO: post-install active java path: ${java_path:-MISSING}"
  echo "[$(ts)] INFO: post-install active java package owner: ${java_owner:-UNKNOWN}"
  echo "[$(ts)] INFO: post-install active javac command path: ${javac_raw_path:-MISSING}"
  echo "[$(ts)] INFO: post-install active javac path: ${javac_path:-MISSING}"
  echo "[$(ts)] INFO: post-install active javac package owner: ${javac_owner:-UNKNOWN}"

  if ! pkg_installed "$target_pkg" || [[ "$java_ok" != "1" || "$javac_ok" != "1" ]]; then
    echo "[$(ts)] ERROR: AMCS requires installed $target_pkg plus active Java 8 java/javac from compatible OpenJDK 8 packages."
    echo "[$(ts)] ERROR: active java command=${java_raw_path:-MISSING} resolved=${java_path:-MISSING} owner=${java_owner:-UNKNOWN}"
    echo "[$(ts)] ERROR: active javac command=${javac_raw_path:-MISSING} resolved=${javac_path:-MISSING} owner=${javac_owner:-UNKNOWN}"
    exit 1
  fi

  add_summary "AMCS Java runtime: OK ($target_pkg active for java and javac)"
}

install_master_launcher() {
  local launcher_dir install_launcher update_launcher bp
  local legacy_install_launcher="/usr/local/bin/master-install"
  local legacy_update_launcher="/usr/local/bin/master-update"
  local legacy_path_start="# >>> ITGO MASTER PATH (auto) >>>"
  local legacy_path_end="# <<< ITGO MASTER PATH (auto) <<<"
  local path_start="# >>> ITGO LOCAL MODULE PATHS (auto) >>>"
  local path_end="# <<< ITGO LOCAL MODULE PATHS (auto) <<<"

  if ! have_user; then
    add_summary "MASTER launcher installed: SKIP (user missing)"
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { add_summary "MASTER launcher installed: SKIP (cannot resolve home)"; return 0; }

  launcher_dir="$ITGO_HOME/UTILITY/MASTER"
  install_launcher="$launcher_dir/master-install"
  update_launcher="$launcher_dir/master-update"
  bp="$ITGO_HOME/.bash_profile"

  if [[ -e "$legacy_install_launcher" || -L "$legacy_install_launcher" ]]; then
    rm -f "$legacy_install_launcher" 2>/dev/null || true
    add_summary "MASTER legacy launcher removed: $legacy_install_launcher"
  else
    add_summary "MASTER legacy launcher removed: SKIP ($legacy_install_launcher not present)"
  fi

  if [[ -e "$legacy_update_launcher" || -L "$legacy_update_launcher" ]]; then
    rm -f "$legacy_update_launcher" 2>/dev/null || true
    add_summary "MASTER legacy launcher removed: $legacy_update_launcher"
  else
    add_summary "MASTER legacy launcher removed: SKIP ($legacy_update_launcher not present)"
  fi

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$launcher_dir"

  cat > "$install_launcher" <<'EOF_MASTER_INSTALL_LAUNCHER'
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

target_user="${1:-itgo}"
repo_api="https://api.github.com/repos/daroitgo/itgo-scripts/git/matching-refs/tags/master-"
tmp_script="$(mktemp)"

cleanup() {
  rm -f "$tmp_script" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! command -v wget >/dev/null 2>&1; then
  echo "ERROR: wget is required for master-install" >&2
  exit 1
fi

latest_tag="$(
  wget -qO- "$repo_api" \
    | grep -o '"ref":[[:space:]]*"refs/tags/master-[^"]*"' \
    | sed 's#.*"ref":[[:space:]]*"refs/tags/\(master-[^"]*\)".*#\1#' \
    | sort -V \
    | tail -n1
)"

if [[ -z "${latest_tag:-}" ]]; then
  echo "ERROR: cannot determine latest master-* tag from daroitgo/itgo-scripts" >&2
  exit 1
fi

script_url="https://raw.githubusercontent.com/daroitgo/itgo-scripts/${latest_tag}/MASTER/master_installer.sh"

if ! wget -qO "$tmp_script" "$script_url"; then
  echo "ERROR: cannot download MASTER/master_installer.sh from tag ${latest_tag}" >&2
  exit 1
fi

chmod 0755 "$tmp_script" 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  bash "$tmp_script" "$target_user"
else
  sudo bash "$tmp_script" "$target_user"
fi
EOF_MASTER_INSTALL_LAUNCHER

  cat > "$update_launcher" <<'EOF_MASTER_UPDATE_LAUNCHER'
#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

target_user="${1:-itgo}"
repo_api="https://api.github.com/repos/daroitgo/itgo-scripts/git/matching-refs/tags/master-"
tmp_script="$(mktemp)"

cleanup() {
  rm -f "$tmp_script" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! command -v wget >/dev/null 2>&1; then
  echo "ERROR: wget is required for master-update" >&2
  exit 1
fi

latest_tag="$(
  wget -qO- "$repo_api" \
    | grep -o '"ref":[[:space:]]*"refs/tags/master-[^"]*"' \
    | sed 's#.*"ref":[[:space:]]*"refs/tags/\(master-[^"]*\)".*#\1#' \
    | sort -V \
    | tail -n1
)"

if [[ -z "${latest_tag:-}" ]]; then
  echo "ERROR: cannot determine latest master-* tag from daroitgo/itgo-scripts" >&2
  exit 1
fi

script_url="https://raw.githubusercontent.com/daroitgo/itgo-scripts/${latest_tag}/MASTER/master_installer.sh"

if ! wget -qO "$tmp_script" "$script_url"; then
  echo "ERROR: cannot download MASTER/master_installer.sh from tag ${latest_tag}" >&2
  exit 1
fi

chmod 0755 "$tmp_script" 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  bash "$tmp_script" --update-only "$target_user"
else
  sudo bash "$tmp_script" --update-only "$target_user"
fi
EOF_MASTER_UPDATE_LAUNCHER

  chown "$TARGET_USER:$TARGET_USER" "$install_launcher" "$update_launcher" 2>/dev/null || true
  chmod 0755 "$install_launcher" "$update_launcher"

  touch "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  chmod 0644 "$bp" 2>/dev/null || true
  safe_backup "$bp"
  remove_block_from_file "$bp" "$legacy_path_start" "$legacy_path_end"
  remove_block_from_file "$bp" "$path_start" "$path_end"
  printf "\n%s\nexport PATH=\"\$HOME/UTILITY/MASTER:\$HOME/UTILITY/STATUS/bin:\$HOME/UTILITY/TSEQ/bin:\$HOME/UTILITY/DOWNLOADER_APP/bin:\$HOME/UTILITY/UPGbuilder/bin:\$HOME/UTILITY/INVENTORY/bin:\$HOME/UTILITY/AMCS:\$HOME/UTILITY/TOOLS:\$PATH\"\n%s\n" "$path_start" "$path_end" >> "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  chmod 0644 "$bp" 2>/dev/null || true

  add_summary "MASTER launcher installed: ~/UTILITY/MASTER/master-install"
  add_summary "MASTER launcher installed: ~/UTILITY/MASTER/master-update"
  add_summary "User-local PATH updated for MASTER, STATUS, TSEQ, DOWNLOADER_APP, UPGbuilder, INVENTORY, AMCS, TOOLS"
}

ITGO_HOME=""
UTILITY_DIR=""
LOG_DIR=""
LOG_OTHER=""
LOG_UPDATE=""
TMP_DIR=""
FINAL_LOG=""
MODULE_DECISION=""
HISTORY_CLEAR_ON_LOGOUT_ENABLED=0
SUMMARY_ITEMS=()

start_final_logging_if_possible() {
  [[ -n "${LOG_OTHER:-}" && -d "$LOG_OTHER" ]] || return 0
  [[ -n "${FINAL_LOG:-}" ]] && return 0

  FINAL_LOG="$LOG_OTHER/master-install_$(date +%Y%m%d_%H%M%S).log"
  touch "$FINAL_LOG"
  chown "$TARGET_USER:$TARGET_USER" "$FINAL_LOG" 2>/dev/null || true
  chmod 0644 "$FINAL_LOG" 2>/dev/null || true

  exec > >(tee -a "$FINAL_LOG") 2>&1

  echo "[$(ts)] ITGO Master Installer v$MASTER_VERSION"
  echo "[$(ts)] User: $TARGET_USER"
  echo "[$(ts)] Log file: $FINAL_LOG"
  echo "[$(ts)] Module versions:"
  echo "[$(ts)]   STATUS         : $STATUS_VERSION"
  echo "[$(ts)]   CLEANUP       : $CLEANUP_VERSION"
  echo "[$(ts)]   TSEQ          : $TSEQ_VERSION"
  echo "[$(ts)]   DOWNLOADER_APP: $DOWNLOADER_APP_VERSION"
  echo "[$(ts)]   UPGBUILDER    : $UPGBUILDER_VERSION"
  echo "[$(ts)]   SERVICEGUARD  : $SERVICEGUARD_VERSION"
  echo "[$(ts)]   INVENTORY     : $INVENTORY_VERSION"

  if [[ -f "$TMP_LOG" ]]; then
    echo "[$(ts)] --- pre-log (from $TMP_LOG) ---"
    cat "$TMP_LOG" || true
    echo "[$(ts)] --- end pre-log ---"
  fi
}

add_summary() {
  local item="${1:-}"
  [[ -n "$item" ]] || return 0
  SUMMARY_ITEMS+=("$item")
}

print_summary() {
  local item

  echo
  echo "===================================================="
  echo "[$(ts)] PODSUMOWANIE MASTER"
  echo "===================================================="

  if [[ "${#SUMMARY_ITEMS[@]}" -eq 0 ]]; then
    echo "[$(ts)] Brak wpisów podsumowania."
    return 0
  fi

  for item in "${SUMMARY_ITEMS[@]}"; do
    echo "[$(ts)] - $item"
  done
}

read_version_file() {
  local version_file="${1:?}"
  if [[ -f "$version_file" ]]; then
    head -n1 "$version_file" 2>/dev/null | tr -d '\r'
  else
    echo ""
  fi
}

read_inventory_version_file() {
  local version_file="${1:?}" version=""
  if [[ -f "$version_file" ]]; then
    version="$(sed -n 's/^INVENTORY_VERSION=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' "$version_file" 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  printf "%s\n" "$version"
}

version_file_for_module() {
  local module="${1:?}"

  [[ -n "${ITGO_HOME:-}" ]] || return 1

  case "$module" in
    STATUS)         printf "%s\n" "$ITGO_HOME/UTILITY/STATUS/.status_installer_version" ;;
    CLEANUP)        printf "%s\n" "$ITGO_HOME/UTILITY/UPG_CLEANUP/.upg_cleanup_version" ;;
    TSEQ)           printf "%s\n" "$ITGO_HOME/UTILITY/TSEQ/.tseq_version" ;;
    DOWNLOADER_APP) printf "%s\n" "$ITGO_HOME/UTILITY/DOWNLOADER_APP/.downloader_version" ;;
    UPGBUILDER)     printf "%s\n" "$ITGO_HOME/UTILITY/UPGbuilder/.upgbuilder_version" ;;
    SERVICEGUARD)   printf "%s\n" "$ITGO_HOME/UTILITY/SERVICEGUARD/.serviceguard_version" ;;
    INVENTORY)      printf "%s\n" "$ITGO_HOME/UTILITY/INVENTORY/inventory.version" ;;
    *) return 1 ;;
  esac
}

target_version_for_module() {
  local module="${1:?}"

  case "$module" in
    STATUS)         printf "%s\n" "$STATUS_VERSION" ;;
    CLEANUP)        printf "%s\n" "$CLEANUP_VERSION" ;;
    TSEQ)           printf "%s\n" "$TSEQ_VERSION" ;;
    DOWNLOADER_APP) printf "%s\n" "$DOWNLOADER_APP_VERSION" ;;
    UPGBUILDER)     printf "%s\n" "$UPGBUILDER_VERSION" ;;
    SERVICEGUARD)   printf "%s\n" "$SERVICEGUARD_VERSION" ;;
    INVENTORY)      printf "%s\n" "$INVENTORY_VERSION" ;;
    *) return 1 ;;
  esac
}

installed_version_for_module() {
  local module="${1:?}" version_file
  version_file="$(version_file_for_module "$module")" || return 1
  if [[ "$module" == "INVENTORY" ]]; then
    read_inventory_version_file "$version_file"
    return 0
  fi
  read_version_file "$version_file"
}

module_is_installed() {
  local module="${1:?}" version_file
  version_file="$(version_file_for_module "$module")" || return 1
  [[ -f "$version_file" ]]
}

module_health_for_module() {
  local module="${1:?}" version_file

  if [[ -z "${ITGO_HOME:-}" ]]; then
    echo "UNKNOWN"
    return 0
  fi

  version_file="$(version_file_for_module "$module")" || {
    echo "UNKNOWN"
    return 0
  }

  if [[ ! -f "$version_file" ]]; then
    echo "UNKNOWN"
    return 0
  fi

  case "$module" in
    STATUS)
      [[ -d "$ITGO_HOME/UTILITY/STATUS" \
        && -f "$version_file" \
        && -x "$ITGO_HOME/UTILITY/STATUS/bin/status" \
        && -x "$ITGO_HOME/UTILITY/STATUS/bin/system_inventory_collect" \
        && -x "$ITGO_HOME/UTILITY/STATUS/bin/apps_inventory_collect" \
        && -d "$ITGO_HOME/UTILITY/STATUS/cache" \
        && -f "$ITGO_HOME/UTILITY/STATUS/eol-db/eol-db.tsv" ]] && echo "OK" || echo "BROKEN"
      ;;
    TSEQ)
      [[ -d "$ITGO_HOME/UTILITY/TSEQ" && -f "$version_file" && -x "$ITGO_HOME/UTILITY/TSEQ/bin/tseq" && -f /etc/systemd/system/tseq.service ]] && echo "OK" || echo "BROKEN"
      ;;
    CLEANUP)
      [[ -d "$ITGO_HOME/UTILITY/UPG_CLEANUP" ]] && echo "OK" || echo "BROKEN"
      ;;
    DOWNLOADER_APP)
      [[ -d "$ITGO_HOME/UTILITY/DOWNLOADER_APP" && -f "$version_file" && -x "$ITGO_HOME/UTILITY/DOWNLOADER_APP/upg_installer.sh" && -x "$ITGO_HOME/UTILITY/DOWNLOADER_APP/bin/dwupg" ]] && echo "OK" || echo "BROKEN"
      ;;
    UPGBUILDER)
      [[ -d "$ITGO_HOME/UTILITY/UPGbuilder" && -f "$version_file" && -x "$ITGO_HOME/UTILITY/UPGbuilder/upgbuilder.sh" && -x "$ITGO_HOME/UTILITY/UPGbuilder/bin/upgbuilder" ]] && echo "OK" || echo "BROKEN"
      ;;
    SERVICEGUARD)
      [[ -d "$ITGO_HOME/UTILITY/SERVICEGUARD" && -f "$version_file" && -x "$ITGO_HOME/UTILITY/SERVICEGUARD/serviceguard.sh" && -x "$ITGO_HOME/UTILITY/TOOLS/svcguard" ]] && echo "OK" || echo "BROKEN"
      ;;
    INVENTORY)
      [[ -d "$ITGO_HOME/UTILITY/INVENTORY" \
        && -f "$version_file" \
        && -x "$ITGO_HOME/UTILITY/INVENTORY/bin/itgo-inv" \
        && -x "$ITGO_HOME/UTILITY/INVENTORY/bin/collect_inventory.py" \
        && -d "$ITGO_HOME/UTILITY/INVENTORY/reports" \
        && -d "$ITGO_HOME/UTILITY/INVENTORY/logs" \
        && -L /usr/local/bin/itgo-inv ]] && echo "OK" || echo "BROKEN"
      ;;
    *)
      echo "UNKNOWN"
      ;;
  esac
}

module_is_healthy() {
  [[ "$(module_health_for_module "${1:?}")" == "OK" ]]
}

compare_versions() {
  local installed="${1:-}" target="${2:-}"

  if [[ -z "$installed" || -z "$target" ]]; then
    echo "unknown"
  elif [[ "$installed" == "$target" ]]; then
    echo "eq"
  elif [[ "$(printf '%s\n%s\n' "$installed" "$target" | sort -V | tail -n 1)" == "$target" ]]; then
    echo "lt"
  else
    echo "gt"
  fi
}

detect_installed_modules() {
  local modules=(STATUS CLEANUP TSEQ DOWNLOADER_APP UPGBUILDER SERVICEGUARD INVENTORY)
  local module installed_version target_version health

  for module in "${modules[@]}"; do
    if module_is_installed "$module"; then
      installed_version="$(installed_version_for_module "$module")"
      target_version="$(target_version_for_module "$module")"
      health="$(module_health_for_module "$module")"
      echo "${module}|${installed_version:-UNKNOWN}|${target_version:-UNKNOWN}|${health:-UNKNOWN}"
    fi
  done
}

any_itgo_module_installed() {
  local modules=(STATUS CLEANUP TSEQ DOWNLOADER_APP UPGBUILDER SERVICEGUARD INVENTORY)
  local module

  for module in "${modules[@]}"; do
    if module_is_installed "$module"; then
      return 0
    fi
  done
  return 1
}

print_detected_modules_summary() {
  local rows="${1:-}"
  local line module installed_version target_version health

  [[ -n "$rows" ]] || return 0

  echo "[$(ts)] Wykryte moduły ITGO:"
  printf "%-16s %-18s %-18s %s\n" "MODULE" "INSTALLED" "TARGET" "HEALTH"
  printf "%-16s %-18s %-18s %s\n" "----------------" "------------------" "------------------" "--------"

  while IFS= read -r line; do
    [[ -n "${line:-}" ]] || continue
    IFS='|' read -r module installed_version target_version health <<< "$line"
    printf "%-16s %-18s %-18s %s\n" \
      "$module" "${installed_version:-UNKNOWN}" "${target_version:-UNKNOWN}" "${health:-UNKNOWN}"
    add_summary "Wykryto na starcie: $module installed=${installed_version:-UNKNOWN} target=${target_version:-UNKNOWN} health=${health:-UNKNOWN}"
  done <<< "$rows"
}

should_install_or_update_module() {
  local module="${1:?}"
  local installed_version target_version health version_cmp

  MODULE_DECISION="install"

  if ! module_is_installed "$module"; then
    if [[ "$UPDATE_ONLY_MODE" == "1" ]]; then
      add_summary "$module: skip (not installed in update-only mode)"
      return 1
    fi
    add_summary "$module: install (brak instalacji)"
    return 0
  fi

  installed_version="$(installed_version_for_module "$module")"
  target_version="$(target_version_for_module "$module")"
  health="$(module_health_for_module "$module")"
  version_cmp="$(compare_versions "$installed_version" "$target_version")"

  if [[ "$version_cmp" == "eq" && "$health" == "OK" ]]; then
    MODULE_DECISION="skip"
    add_summary "$module: skip (version=$target_version, health=OK)"
    echo "[$(ts)] SKIP: $module już zainstalowany w wersji docelowej $target_version i health=OK."
    return 1
  fi

  if [[ "$version_cmp" == "eq" && "$health" == "BROKEN" ]]; then
    if prompt_yn "MODUŁ: $module ma wersję $target_version, ale health=BROKEN. Wykonać repair/reinstall?" "Y"; then
      MODULE_DECISION="repair"
      add_summary "$module: repair/reinstall"
      return 0
    fi
    MODULE_DECISION="skip"
    add_summary "$module: skip (health=BROKEN, repair skipped)"
    echo "[$(ts)] SKIP: repair/reinstall $module."
    return 1
  fi

  if [[ "$version_cmp" == "lt" || "$version_cmp" == "gt" || "$version_cmp" == "unknown" ]]; then
    if prompt_yn "MODUŁ: $module ma wersję '${installed_version:-UNKNOWN}', docelowa to '${target_version:-UNKNOWN}'. Aktualizować?" "Y"; then
      MODULE_DECISION="update"
      add_summary "$module: update (${installed_version:-UNKNOWN} -> ${target_version:-UNKNOWN})"
      return 0
    fi
    MODULE_DECISION="skip"
    add_summary "$module: skip update (${installed_version:-UNKNOWN} -> ${target_version:-UNKNOWN})"
    echo "[$(ts)] SKIP: update $module."
    return 1
  fi

  return 0
}

safe_backup() {
  local f="${1:?}"
  [[ -e "$f" ]] || return 0
  rm -f "${f}.bak" 2>/dev/null || true
  cp -a "$f" "${f}.bak"
}

cleanup_old_bash_backups() {
  local files=(
    "$ITGO_HOME/.bash_profile"
    "$ITGO_HOME/.bashrc"
    "$ITGO_HOME/.bash_logout"
  )
  local f=""
  for f in "${files[@]}"; do
    rm -f "${f}.bak."* 2>/dev/null || true
  done
}

is_safe_itgo_home_child_path() {
  local path="${1:-}" home="${ITGO_HOME:-}"

  [[ -n "$path" && -n "$home" ]] || return 1
  [[ "$path" != "/" && "$home" != "/" ]] || return 1
  [[ "$home" != "/root" ]] || return 1
  [[ "$path" != "/root" ]] || return 1
  [[ "$path" == "$home/"* ]] || return 1
  return 0
}

is_safe_itgo_utility_path() {
  local path="${1:-}" home="${ITGO_HOME:-}"

  [[ -n "$path" && -n "$home" ]] || return 1
  [[ "$path" != "/" && "$home" != "/" ]] || return 1
  [[ "$home" != "/root" ]] || return 1
  [[ "$path" == "$home/UTILITY" ]] || return 1
  return 0
}

is_safe_itgo_upg_path() {
  local path="${1:-}" home="${ITGO_HOME:-}"

  [[ -n "$path" && -n "$home" ]] || return 1
  [[ "$path" != "/" && "$home" != "/" ]] || return 1
  [[ "$home" != "/root" ]] || return 1
  [[ "$path" == "$home/UPG" ]] || return 1
  return 0
}

file_has_itgo_shell_marker() {
  local file="${1:?}"

  [[ -f "$file" ]] || return 1
  grep -Eq 'ITGO LOCAL MODULE PATHS|ITGO HISTORY CLEAR ON LOGOUT|UPG XML cleanup|UTILITY/(MASTER|STATUS|TSEQ|DOWNLOADER_APP|UPGbuilder|INVENTORY|AMCS)|/home/itgo/UPG' "$file" 2>/dev/null \
    || { [[ -n "${ITGO_HOME:-}" ]] && grep -Fq "$ITGO_HOME/UPG" "$file" 2>/dev/null; }
}

ensure_user_and_password_if_missing() {
  if have_user; then
    prelog "OK: user '$TARGET_USER' exists (skip create/passwd)."
    return 0
  fi

  echo "User '$TARGET_USER' nie istnieje."
  if ! prompt_yn "Utworzyć go (wheel) i ustawić hasło?" "Y"; then
    echo "ERROR: bez użytkownika '$TARGET_USER' nie da się kontynuować."
    exit 1
  fi

  prelog "ACTION: useradd -m -G wheel $TARGET_USER"
  useradd -m -G wheel "$TARGET_USER"

  prelog "ACTION: passwd $TARGET_USER (interactive)"
  passwd "$TARGET_USER"
}

ensure_home_dirs() {
  ITGO_HOME="$(resolve_home)" || { prelog "ERROR: cannot resolve home for $TARGET_USER"; exit 1; }

  UTILITY_DIR="$ITGO_HOME/UTILITY"
  LOG_DIR="$UTILITY_DIR/LOG"
  LOG_OTHER="$LOG_DIR/OTHER"
  LOG_UPDATE="$LOG_DIR/UPDATE"
  TMP_DIR="$UTILITY_DIR/TMP"

  prelog "ACTION: ensuring HOME structure under $ITGO_HOME"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$ITGO_HOME/UPG"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$ITGO_HOME/BACKUP"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR/ITGO-CONFIG"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR/AMCS"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR/AMCS/resources"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$LOG_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$LOG_OTHER"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$LOG_UPDATE"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

  cleanup_old_bash_backups
  start_final_logging_if_possible
}

json_escape_string() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ }"
  printf "%s" "$s"
}

client_catalog_python_command() {
  local candidate
  for candidate in python3 python3.11 python3.9 python3.8 python3.7 python3.6 python python2 python2.7; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json, sys; sys.exit(0)' >/dev/null 2>&1; then
      printf "%s" "$candidate"
      return 0
    fi
  done
  return 1
}

download_client_catalog() {
  local output=""
  CLIENT_CATALOG_JSON=""

  if command -v wget >/dev/null 2>&1; then
    output="$(wget -qO- "$CLIENT_CATALOG_URL" 2>/dev/null)" || output=""
    if [[ -n "$output" ]]; then
      CLIENT_CATALOG_JSON="$output"
      CLIENT_CATALOG_LOADED_FROM="$CLIENT_CATALOG_URL via wget"
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    output="$(curl -fsSL "$CLIENT_CATALOG_URL" 2>/dev/null)" || output=""
    if [[ -n "$output" ]]; then
      CLIENT_CATALOG_JSON="$output"
      CLIENT_CATALOG_LOADED_FROM="$CLIENT_CATALOG_URL via curl"
      return 0
    fi
  fi

  CLIENT_CATALOG_JSON=""
  CLIENT_CATALOG_LOADED_FROM=""
  return 1
}

prompt_client_identity_manual() {
  local code="" name=""

  while true; do
    printf "%s" "client_code [a-z0-9_-]: " >&2
    read -r code || true
    code="${code//$'\r'/}"
    code="${code#"${code%%[![:space:]]*}"}"
    code="${code%"${code##*[![:space:]]}"}"

    if [[ "$code" =~ ^[a-z0-9_-]+$ ]]; then
      break
    fi
    echo "Wpisz client_code zgodny z regex: ^[a-z0-9_-]+$" >&2
  done

  while true; do
    printf "%s" "client_name: " >&2
    read -r name || true
    name="${name//$'\r'/}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"

    if [[ -n "$name" ]]; then
      break
    fi
    echo "client_name nie może być pusty." >&2
  done

  CLIENT_IDENTITY_CODE="$code"
  CLIENT_IDENTITY_NAME="$name"
}

select_client_identity_from_catalog() {
  local catalog_json="" catalog_lines="" py_cmd="" ans="" idx="" line="" code="" name="" prompt_out="/dev/stderr"
  local codes=() names=()

  CLIENT_CATALOG_JSON=""
  CLIENT_CATALOG_LOADED_FROM=""

  py_cmd="$(client_catalog_python_command)" || return 1
  download_client_catalog || return 1
  catalog_json="$CLIENT_CATALOG_JSON"

  if ! catalog_lines="$(printf "%s" "$catalog_json" | "$py_cmd" -c '
import json
import re
import sys

try:
    string_types = (basestring,)
except NameError:
    string_types = (str,)

def clean_text(value):
    if value is None:
        return u""
    if not isinstance(value, string_types):
        value = str(value)
    return value.strip()

try:
    data = json.load(sys.stdin)
    clients = data.get("clients", [])
    if not isinstance(clients, list):
        raise ValueError("clients must be a list")

    for client in clients:
        if not isinstance(client, dict):
            continue
        code = clean_text(client.get("client_code", ""))
        name = clean_text(client.get("client_name", ""))
        if re.match(r"^[a-z0-9_-]+$", code) and name:
            line = u"%s\t%s\n" % (code, name)
            if sys.version_info[0] < 3:
                line = line.encode("utf-8")
            sys.stdout.write(line)
except Exception:
    sys.exit(1)
')"; then
    return 1
  fi

  [[ -n "$catalog_lines" ]] || return 1

  while IFS=$'\t' read -r code name; do
    [[ -n "$code" && -n "$name" ]] || continue
    codes+=("$code")
    names+=("$name")
  done <<< "$catalog_lines"

  [[ "${#codes[@]}" -gt 0 ]] || return 1
  CLIENT_CATALOG_LOADED_FROM="$CLIENT_CATALOG_LOADED_FROM; parser: $py_cmd"

  [[ -w /dev/tty ]] && prompt_out="/dev/tty"

  echo "Dostępni klienci z katalogu publicznego:" > "$prompt_out"
  for idx in "${!codes[@]}"; do
    printf "%2d) %s - %s\n" "$((idx + 1))" "${codes[$idx]}" "${names[$idx]}" > "$prompt_out"
  done
  echo " m) wpisz klienta ręcznie" > "$prompt_out"

  while true; do
    printf "%s" "Wybierz klienta [1-${#codes[@]}/m]: " > "$prompt_out"
    read -r ans || true
    ans="${ans//$'\r'/}"
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"

    case "${ans,,}" in
      m|manual|r|recznie|ręcznie)
        return 1
        ;;
      ''|*[!0-9]*)
        echo "Wpisz numer klienta albo m." > "$prompt_out"
        ;;
      *)
        if (( ans >= 1 && ans <= ${#codes[@]} )); then
          line=$((ans - 1))
          CLIENT_IDENTITY_CODE="${codes[$line]}"
          CLIENT_IDENTITY_NAME="${names[$line]}"
          return 0
        fi
        echo "Numer poza zakresem." > "$prompt_out"
        ;;
    esac
  done
}

write_client_identity_file() {
  local identity_file="${1:?}" code name
  code="$(json_escape_string "$CLIENT_IDENTITY_CODE")"
  name="$(json_escape_string "$CLIENT_IDENTITY_NAME")"

  cat > "$identity_file" <<EOF_CLIENT_IDENTITY
{
  "schema_version": "1.0",
  "client_code": "$code",
  "client_name": "$name",
  "managed_by": "ITGO",
  "created_by": "itgo-installer"
}
EOF_CLIENT_IDENTITY

  chown "$TARGET_USER:$TARGET_USER" "$identity_file" 2>/dev/null || true
  chmod 0644 "$identity_file" 2>/dev/null || true
}

ensure_client_identity_file() {
  local config_dir identity_file
  CLIENT_IDENTITY_CODE=""
  CLIENT_IDENTITY_NAME=""

  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' missing. Pomijam client-identity.json."
    add_summary "Client identity: SKIP (user missing)"
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] WARN: cannot resolve HOME. Pomijam client-identity.json."; add_summary "Client identity: SKIP (cannot resolve home)"; return 0; }

  UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
  config_dir="$UTILITY_DIR/ITGO-CONFIG"
  identity_file="$config_dir/client-identity.json"

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$config_dir"

  if [[ -f "$identity_file" ]]; then
    echo "[$(ts)] INFO: istnieje $identity_file"
    echo "----- current client-identity.json -----"
    cat "$identity_file" || true
    echo "----- end current client-identity.json -----"

    if ! prompt_yn "Nadpisać istniejący client-identity.json?" "N"; then
      echo "[$(ts)] SKIP: client-identity.json pozostawiony bez zmian."
      add_summary "Client identity: kept existing ~/UTILITY/ITGO-CONFIG/client-identity.json"
      return 0
    fi
  fi

  echo "[$(ts)] INFO: konfiguracja lokalnej identyfikacji klienta dla InfoCenter."
  if ! select_client_identity_from_catalog; then
    echo "[$(ts)] INFO: katalog klientów niedostępny albo wybrano wpis ręczny."
    add_summary "Client catalog: not loaded from $CLIENT_CATALOG_URL"
    prompt_client_identity_manual
  else
    echo "[$(ts)] OK: katalog klientów wczytany z $CLIENT_CATALOG_LOADED_FROM"
    add_summary "Client catalog: loaded from $CLIENT_CATALOG_LOADED_FROM"
  fi

  write_client_identity_file "$identity_file"
  echo "[$(ts)] OK: zapisano ~/UTILITY/ITGO-CONFIG/client-identity.json"
  add_summary "Client identity: written ~/UTILITY/ITGO-CONFIG/client-identity.json ($CLIENT_IDENTITY_CODE)"
}

ensure_sudo_nopasswd_block() {
  local f="/etc/sudoers.d/itgo-nopasswd"
  if [[ -f "$f" ]]; then
    echo "[$(ts)] OK: sudoers drop-in exists ($f)."
    return 0
  fi

  if prompt_yn "Dodać sudo NOPASSWD dla '$TARGET_USER' (${TARGET_USER} ALL=(ALL) NOPASSWD: ALL)?" "N"; then
    echo "[$(ts)] ACTION: writing $f"
    cat > "$f" <<EOF_SUD
${TARGET_USER} ALL=(ALL) NOPASSWD: ALL
EOF_SUD
    chmod 0440 "$f"
    if visudo -cf "$f" >/dev/null; then
      echo "[$(ts)] OK: sudoers validated."
    else
      echo "[$(ts)] ERROR: sudoers validation failed, reverting."
      rm -f "$f"
      exit 1
    fi
  else
    echo "[$(ts)] SKIP: sudo NOPASSWD not set."
  fi
}

ensure_acls_block() {
  if ! command -v setfacl >/dev/null 2>&1; then
    echo "[$(ts)] WARN: setfacl not found. Skipping ACL."
    return 0
  fi

  if prompt_yn "Ustawić ACL-e dla /srv (rwx+default) oraz /etc/amms.conf (rw)?" "Y"; then
    echo "[$(ts)] ACTION: setfacl on /srv"
    setfacl -R -m "u:${TARGET_USER}:rwx" /srv
    setfacl -R -d -m "u:${TARGET_USER}:rwx" /srv

    if [[ -f /etc/amms.conf ]]; then
      echo "[$(ts)] ACTION: setfacl on /etc/amms.conf"
      setfacl -m "u:${TARGET_USER}:rw" /etc/amms.conf
    else
      echo "[$(ts)] WARN: /etc/amms.conf not found; skipped."
    fi

    echo "[$(ts)] OK: ACL block done."
  else
    echo "[$(ts)] SKIP: ACL block."
  fi
}

ensure_docker_group_membership() {
  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' nie istnieje. Pomijam docker group."
    return 0
  fi

  if ! getent group docker >/dev/null 2>&1; then
    echo "[$(ts)] WARN: grupa 'docker' nie istnieje. Pomijam dopięcie użytkownika."
    return 0
  fi

  if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    echo "[$(ts)] OK: user '$TARGET_USER' już jest w grupie docker."
    return 0
  fi

  if prompt_yn "Dodać użytkownika '$TARGET_USER' do grupy docker?" "Y"; then
    echo "[$(ts)] ACTION: usermod -aG docker $TARGET_USER"
    usermod -aG docker "$TARGET_USER"
    echo "[$(ts)] OK: user '$TARGET_USER' dodany do grupy docker."
    echo "[$(ts)] INFO: zmiana zadziała po ponownym logowaniu użytkownika."
  else
    echo "[$(ts)] SKIP: dopięcie do grupy docker."
  fi
}

get_target_user_home() {
  resolve_home
}

get_amms_secret_file_path() {
  local target_home
  target_home="$(get_target_user_home)" || return 1
  printf "%s\n" "${target_home}/.config/itgo/amms_registry_password"
}

validate_amms_secret_file() {
  local secret_file="${1:?}"
  local config_dir expected_owner dir_mode file_mode dir_owner file_owner

  config_dir="$(dirname "$secret_file")"
  expected_owner="$TARGET_USER"

  if [[ ! -d "$config_dir" ]]; then
    echo "[$(ts)] WARN: katalog sekretu nie istnieje: $config_dir"
    return 1
  fi

  if [[ ! -f "$secret_file" ]]; then
    echo "[$(ts)] WARN: plik sekretu nie istnieje: $secret_file"
    return 1
  fi

  if [[ ! -s "$secret_file" ]]; then
    echo "[$(ts)] WARN: plik sekretu jest pusty: $secret_file"
    return 1
  fi

  dir_mode="$(stat -c '%a' "$config_dir" 2>/dev/null || echo "")"
  if [[ "$dir_mode" != "700" ]]; then
    echo "[$(ts)] WARN: katalog $config_dir ma mode ${dir_mode:-UNKNOWN}, oczekiwano 700."
    return 1
  fi

  file_mode="$(stat -c '%a' "$secret_file" 2>/dev/null || echo "")"
  if [[ "$file_mode" != "600" ]]; then
    echo "[$(ts)] WARN: plik $secret_file ma mode ${file_mode:-UNKNOWN}, oczekiwano 600."
    return 1
  fi

  dir_owner="$(stat -c '%U' "$config_dir" 2>/dev/null || echo "")"
  if [[ "$dir_owner" != "$expected_owner" ]]; then
    echo "[$(ts)] WARN: owner katalogu $config_dir to ${dir_owner:-UNKNOWN}, oczekiwano $expected_owner."
    return 1
  fi

  file_owner="$(stat -c '%U' "$secret_file" 2>/dev/null || echo "")"
  if [[ "$file_owner" != "$expected_owner" ]]; then
    echo "[$(ts)] WARN: owner pliku $secret_file to ${file_owner:-UNKNOWN}, oczekiwano $expected_owner."
    return 1
  fi

  return 0
}

print_amms_secret_instructions() {
  local secret_file="${1:?}"
  local config_dir

  config_dir="$(dirname "$secret_file")"

  echo "[$(ts)] INFO: nie znaleziono pliku sekretu: $secret_file"
  echo "[$(ts)] INFO: aby włączyć docker login do amms.asseco.pl, utwórz sekret jako user '$TARGET_USER':"
  echo "[$(ts)] INFO:   mkdir -p \"$config_dir\""
  echo "[$(ts)] INFO:   chmod 700 \"$config_dir\""
  echo "[$(ts)] INFO:   printf '%s\\n' '<HASLO>' > \"$secret_file\""
  echo "[$(ts)] INFO:   chmod 600 \"$secret_file\""
  echo "[$(ts)] INFO:   chown -R \"$TARGET_USER:$TARGET_USER\" \"$config_dir\""
}

create_amms_secret_file() {
  local secret_file="${1:?}"
  local config_dir password=""

  config_dir="$(dirname "$secret_file")"

  echo "[$(ts)] INFO: sekret AMMS docker registry zostanie zapisany do: $secret_file"
  if ! prompt_yn "Utworzyć teraz sekret AMMS docker registry dla user '$TARGET_USER'?" "Y"; then
    add_summary "Docker login: secret creation skipped"
    return 1
  fi

  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$config_dir"

  printf "%s" "Hasło do amms.asseco.pl dla usera wdrozenia: " >&2
  read -r -s password || true
  printf "\n" >&2

  if [[ -z "${password:-}" ]]; then
    echo "[$(ts)] WARN: puste hasło. Pomijam utworzenie sekretu i docker login."
    add_summary "Docker login: empty secret skipped"
    return 1
  fi

  printf "%s\n" "$password" > "$secret_file"
  chown "$TARGET_USER:$TARGET_USER" "$secret_file" 2>/dev/null || true
  chmod 0600 "$secret_file" 2>/dev/null || true
  unset password

  add_summary "Docker login: secret created"
  return 0
}

docker_login_amms_registry() {
  local secret_file config_dir registry username

  registry="amms.asseco.pl"
  username="wdrozenia"

  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' nie istnieje. Pomijam docker login do $registry."
    add_summary "Docker login: SKIP (user missing)"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "[$(ts)] SKIP: docker CLI nie istnieje. Pomijam docker login do $registry."
    add_summary "Docker login: SKIP (docker CLI missing)"
    return 0
  fi

  secret_file="$(get_amms_secret_file_path)" || {
    echo "[$(ts)] WARN: nie udało się ustalić HOME dla '$TARGET_USER'. Pomijam docker login do $registry."
    add_summary "Docker login: WARN (cannot resolve HOME)"
    return 0
  }
  config_dir="$(dirname "$secret_file")"

  if [[ ! -f "$secret_file" ]]; then
    echo "[$(ts)] INFO: nie znaleziono pliku sekretu: $secret_file"
    if ! create_amms_secret_file "$secret_file"; then
      print_amms_secret_instructions "$secret_file"
      echo "[$(ts)] SKIP: docker login do $registry."
      return 0
    fi
  fi

  if ! prompt_yn "Wykonać docker login do $registry jako user '$TARGET_USER'?" "Y"; then
    echo "[$(ts)] SKIP: docker login do $registry."
    add_summary "Docker login: SKIP (user declined)"
    return 0
  fi

  if ! validate_amms_secret_file "$secret_file"; then
    echo "[$(ts)] ERROR: walidacja sekretu nie powiodła się. Pomijam docker login do $registry."
    echo "[$(ts)] INFO: oczekiwano katalogu $config_dir z mode 700 i pliku $secret_file z mode 600, owner $TARGET_USER."
    add_summary "Docker login: WARN (secret validation failed)"
    return 0
  fi

  echo "[$(ts)] ACTION: docker login --username $username --password-stdin $registry (sudo -H -u $TARGET_USER)"
  if sudo -H -u "$TARGET_USER" sh -c 'cat "$1" | docker login --username "$2" --password-stdin "$3"' _ "$secret_file" "$username" "$registry"; then
    echo "[$(ts)] OK: docker login do $registry wykonany jako '$TARGET_USER'."
    echo "[$(ts)] INFO: jeśli użytkownik został dopiero co dodany do grupy docker, może być wymagana nowa sesja."
    add_summary "Docker login: OK"
  else
    echo "[$(ts)] WARN: docker login do $registry nie powiódł się dla usera '$TARGET_USER'."
    echo "[$(ts)] INFO: jeśli użytkownik został dopiero co dodany do grupy docker, może być wymagana nowa sesja."
    add_summary "Docker login: WARN (login failed)"
  fi
}

ensure_basic_tools_step() {
  local wanted=(nano mc rsync dos2unix jq wget)
  local missing=()
  local p=""

  for p in "${wanted[@]}"; do
    if pkg_installed "$p"; then
      echo "[$(ts)] OK: pakiet '$p' już zainstalowany."
    else
      echo "[$(ts)] WARN: pakiet '$p' nie jest zainstalowany."
      missing+=("$p")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "[$(ts)] OK: wszystkie pakiety bazowe są już obecne."
    return 0
  fi

  if prompt_yn "Brakuje: ${missing[*]}. Zainstalować teraz?" "Y"; then
    install_packages "${missing[@]}"
    echo "[$(ts)] OK: pakiety bazowe zainstalowane."
  else
    echo "[$(ts)] SKIP: instalacja pakietów bazowych."
  fi
}

install_bash_logout_history_clear() {
  local bl="$ITGO_HOME/.bash_logout"

  local START="# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>"
  local END="# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<"

  local BLOCK
  BLOCK=$(cat <<'BEOF'
# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>
history -c 2>/dev/null || true
history -w 2>/dev/null || true
: > "$HOME/.bash_history" 2>/dev/null || true
# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<
BEOF
)

  echo "[$(ts)] ACTION: patch $bl (history clear on logout)"
  touch "$bl"
  chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
  chmod 0644 "$bl" 2>/dev/null || true
  safe_backup "$bl"

  if grep -qF "$START" "$bl" 2>/dev/null; then
    awk -v start="$START" -v end="$END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bl" > "${bl}.tmp"
    mv "${bl}.tmp" "$bl"
    chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
    chmod 0644 "$bl" 2>/dev/null || true
  fi

  printf "\n%s\n" "$BLOCK" >> "$bl"
  chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
  chmod 0644 "$bl" 2>/dev/null || true

  echo "[$(ts)] OK: ~/.bash_logout updated. Backup: ${bl}.bak"
}

ensure_wget() {
  if [[ "$OFFLINE_MODE" == "1" ]]; then
    echo "[$(ts)] OK: offline mode - wget not required."
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    echo "[$(ts)] OK: wget present."
    return 0
  fi

  if ! prompt_yn "Brak wget. Zainstalować wget teraz (dnf/yum/apt-get)?" "Y"; then
    echo "[$(ts)] ERROR: wget wymagany do pobrania modułów."
    return 1
  fi

  install_packages wget
}

download_to_tmp() {
  local url="${1:?}" out="${2:?}" local_src="${3:-}"
  [[ -d "$TMP_DIR" ]] || { echo "[$(ts)] ERROR: missing $TMP_DIR"; return 1; }

  if [[ "$OFFLINE_MODE" == "1" ]]; then
    [[ -n "$local_src" ]] || { echo "[$(ts)] ERROR: local source not provided for offline mode."; return 1; }
    [[ -f "$local_src" ]] || { echo "[$(ts)] ERROR: local source missing: $local_src"; return 1; }

    echo "[$(ts)] COPY(local): $local_src -> $out"
    cp "$local_src" "$out"
  else
    echo "[$(ts)] DOWNLOAD: $url -> $out"
    wget -qO "$out" "$url"
  fi

  chmod 0755 "$out"
  chown "$TARGET_USER:$TARGET_USER" "$out" 2>/dev/null || true
}

download_inventory_payload() {
  local out_dir="${1:?}"
  local item source_path out_path url
  local items=(
    "inventory_installer_public.sh"
    "collect_inventory.py"
    "itgo-inv"
    "inventory.version"
    "README.md"
    "CHANGELOG.md"
  )

  [[ -d "$TMP_DIR" ]] || { echo "[$(ts)] ERROR: missing $TMP_DIR"; return 1; }

  rm -rf "$out_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$out_dir"

  for item in "${items[@]}"; do
    out_path="$out_dir/$item"
    if [[ "$OFFLINE_MODE" == "1" ]]; then
      source_path="$INVENTORY_LOCAL_DIR/$item"
      [[ -f "$source_path" ]] || { echo "[$(ts)] ERROR: local source missing: $source_path"; return 1; }
      echo "[$(ts)] COPY(local): $source_path -> $out_path"
      cp "$source_path" "$out_path"
    else
      if [[ "$item" == "inventory_installer_public.sh" ]]; then
        url="$INVENTORY_URL"
      else
        url="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/inventory-${INVENTORY_VERSION}/INVENTORY/${item}"
      fi
      echo "[$(ts)] DOWNLOAD: $url -> $out_path"
      wget -qO "$out_path" "$url"
    fi
  done

  chmod 0755 "$out_dir/inventory_installer_public.sh" "$out_dir/collect_inventory.py" "$out_dir/itgo-inv"
  chmod 0644 "$out_dir/inventory.version" "$out_dir/README.md" "$out_dir/CHANGELOG.md"
  chown -R "$TARGET_USER:$TARGET_USER" "$out_dir" 2>/dev/null || true
}

run_module_root() {
  local script="${1:?}"
  shift || true
  echo "[$(ts)] RUN(root): bash $script $*"
  bash "$script" "$@"
}

run_module_as_itgo() {
  local script="${1:?}"
  shift || true
  echo "[$(ts)] RUN(itgo): sudo -H -u $TARGET_USER bash $script $*"
  sudo -H -u "$TARGET_USER" bash "$script" "$@"
}

is_valid_amcs_ipv4() {
  local ip="${1:-}"
  local a b c d part

  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1

  IFS='.' read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    ((part >= 0 && part <= 255)) || return 1
  done

  return 0
}

prompt_amcs_node_master_host() {
  local config_file="$UTILITY_DIR/AMCS/amcs-node-master.host"
  local current="" ans=""

  if [[ -f "$config_file" ]]; then
    current="$(head -n 1 "$config_file" 2>/dev/null | tr -d '[:space:]' || true)"
  fi

  while true; do
    if [[ -n "$current" ]]; then
      printf "AMCS node/slave: IP instalacji MASTER [%s] (Enter = zostaw): " "$current" >&2
    else
      printf "AMCS node/slave: podaj IP instalacji MASTER (Enter = pomiń, później użyj: AMCS -S <IP>): " >&2
    fi

    read -r ans || true
    ans="${ans//$'\r'/}"
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"

    if [[ -z "$ans" ]]; then
      printf "%s\n" "$current"
      return 0
    fi

    if is_valid_amcs_ipv4 "$ans"; then
      printf "%s\n" "$ans"
      return 0
    fi

    echo "[$(ts)] WARN: podaj poprawny adres IPv4, np. 10.10.10.150, albo Enter żeby pominąć." >&2
  done
}

install_amcs_local_launchers() {
  local node_master_host="${1:-}"
  local app_dir="$UTILITY_DIR/AMCS"
  local resources_dir="$app_dir/resources"
  local launcher="$app_dir/AMCS"
  local node_master_host_file="$app_dir/amcs-node-master.host"

  echo "[$(ts)] ACTION: install AMCS launchers into $app_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$app_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$resources_dir"

  if [[ -n "$node_master_host" ]]; then
    printf "%s\n" "$node_master_host" > "$node_master_host_file"
    chown "$TARGET_USER:$TARGET_USER" "$node_master_host_file" 2>/dev/null || true
    chmod 0600 "$node_master_host_file" 2>/dev/null || true
    add_summary "AMCS node/slave master host: $node_master_host"
  else
    add_summary "AMCS node/slave master host: not configured"
  fi

  cat > "$launcher" <<'EOF_AMCS_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail 2>/dev/null || set -eu

APP_DIR="${HOME}/UTILITY/AMCS"
RESOURCES_DIR="${APP_DIR}/resources"
NODE_MASTER_HOST_FILE="${APP_DIR}/amcs-node-master.host"

usage() {
  cat <<'EOF_USAGE'
Usage:
  AMCS
      Run AMCS installer in main mode.

  AMCS -S [MASTER_IP]
  AMCS --slave [MASTER_IP]
  AMCS --node [MASTER_IP]
      Run AMCS installer in node/slave mode.
      MASTER_IP can be provided as an argument or stored in:
      ~/UTILITY/AMCS/amcs-node-master.host
EOF_USAGE
}

is_valid_ipv4() {
  local ip="${1:-}"
  local a b c d part

  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1

  IFS='.' read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    ((part >= 0 && part <= 255)) || return 1
  done

  return 0
}

cd "$APP_DIR"

mode="${1:-}"
case "$mode" in
  -h|--help)
    usage
    exit 0
    ;;

  -S|--slave|--node)
    shift || true
    master_host=""

    if [[ -n "${1:-}" && "${1:-}" != -* ]]; then
      master_host="$1"
      shift || true
    elif [[ -f "$NODE_MASTER_HOST_FILE" ]]; then
      master_host="$(head -n 1 "$NODE_MASTER_HOST_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    fi

    if [[ -z "$master_host" ]]; then
      echo "[ERROR] Brak IP instalacji MASTER dla trybu node/slave." >&2
      echo "[INFO] Podaj IP jako argument, np.: AMCS -S 10.10.10.150" >&2
      echo "[INFO] Albo zapisz IP w: $NODE_MASTER_HOST_FILE" >&2
      exit 1
    fi

    if ! is_valid_ipv4 "$master_host"; then
      echo "[ERROR] Niepoprawny adres IPv4 instalacji MASTER dla trybu node/slave: $master_host" >&2
      echo "[INFO] Podaj IP jako argument, np.: AMCS -S 10.10.10.150" >&2
      echo "[INFO] Albo popraw IP w: $NODE_MASTER_HOST_FILE" >&2
      exit 1
    fi

    exec java \
      -Dspring.profiles.active=node \
      -Dapplication.installer.resources.dir="$RESOURCES_DIR" \
      -Dapplication.installer.master.host="$master_host" \
      -Dapplication.installer.master.cluster-port=5701 \
      -Dapplication.installer.master.resources-port=8090 \
      -jar amcs-installer.jar \
      "$@"
    ;;

  *)
    exec java \
      -Dspring.profiles.active=main \
      -Dapplication.installer.resources.dir="$RESOURCES_DIR" \
      -Dapplication.installer.master.cluster-port=5701 \
      -Dserver.port=8090 \
      -jar amcs-installer.jar \
      "$@"
    ;;
esac
EOF_AMCS_LAUNCHER

  chown "$TARGET_USER:$TARGET_USER" "$launcher" 2>/dev/null || true
  chmod 0700 "$launcher" 2>/dev/null || true

  add_summary "AMCS launcher installed: ~/UTILITY/AMCS/AMCS"
}

install_cp_upg_helper() {
  local tools_dir="$UTILITY_DIR/TOOLS"
  local copy_prod_launcher="$tools_dir/cp-upg"

  echo "[$(ts)] ACTION: install TOOLS launcher into $tools_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$tools_dir"

  cat > "$copy_prod_launcher" <<'EOF_AMCS_COPY_PROD'
#!/usr/bin/env bash
set -euo pipefail 2>/dev/null || set -eu

SUPPORTED_TYPES=(edm zm mpi p1adapter)

ts() { date "+%F %T"; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  cp-upg
      Detect and copy all supported UPG production types found in /srv.

  cp-upg <type>
      Copy only the selected type.

  cp-upg --list
      Show supported types, source patterns, and target directories.

Supported types:
  edm
  zm
  mpi
  p1adapter
EOF_USAGE
}

type_pattern() {
  case "$1" in
    edm) printf "/srv/edm*\n" ;;
    zm) printf "/srv/*zm_docker*\n" ;;
    mpi) printf "/srv/*mpi*\n" ;;
    p1adapter) printf "/srv/*p1adapter*\n" ;;
    *) return 1 ;;
  esac
}

type_target() {
  case "$1" in
    edm) printf "%s/UPG/EDM\n" "$HOME" ;;
    zm) printf "%s/UPG/ZM\n" "$HOME" ;;
    mpi) printf "%s/UPG/MPI\n" "$HOME" ;;
    p1adapter) printf "%s/UPG/P1ADAPTER\n" "$HOME" ;;
    *) return 1 ;;
  esac
}

print_supported_types() {
  local type pattern target

  printf "%-10s %-22s %s\n" "TYPE" "SOURCE_PATTERN" "TARGET_DIR"
  for type in "${SUPPORTED_TYPES[@]}"; do
    pattern="$(type_pattern "$type")"
    target="$(type_target "$type")"
    printf "%-10s %-22s %s\n" "$type" "$pattern" "$target"
  done
}

is_supported_type() {
  local requested="${1:-}" type

  for type in "${SUPPORTED_TYPES[@]}"; do
    [[ "$requested" == "$type" ]] && return 0
  done

  return 1
}

collect_sources() {
  local type="${1:?}"
  local find_pattern candidate
  sources=()

  case "$type" in
    edm) find_pattern="edm*" ;;
    zm) find_pattern="*zm_docker*" ;;
    mpi) find_pattern="*mpi*" ;;
    p1adapter) find_pattern="*p1adapter*" ;;
    *) return 1 ;;
  esac

  [[ -d /srv ]] || return 0

  while IFS= read -r candidate; do
    sources+=("$candidate")
  done < <(find /srv -mindepth 1 -maxdepth 1 -type d -iname "$find_pattern" -print 2>/dev/null | sort)
}

copy_type() {
  local type="${1:?}"
  local missing_is_error="${2:-1}"
  local pattern target src
  local sources=()

  pattern="$(type_pattern "$type")"
  target="$(type_target "$type")"
  collect_sources "$type"

  if [[ "${#sources[@]}" -eq 0 ]]; then
    if [[ "$missing_is_error" == "1" ]]; then
      echo "[$(ts)] ERROR: no sources found for type '$type' using pattern $pattern." >&2
      echo "[$(ts)] INFO: target was not cleaned: $target" >&2
    else
      echo "[$(ts)] INFO: no sources found for type '$type' using pattern $pattern; skipping."
    fi
    return 1
  fi

  echo "[$(ts)] INFO: starting UPG production copy for $type to $target"
  mkdir -p "$target"

  echo "[$(ts)] INFO: cleaning contents of $target"
  find "$target" -mindepth 1 -exec rm -rf -- {} +

  for src in "${sources[@]}"; do
    echo "[$(ts)] INFO: copying contents of $src -> $target/"
    cp -a "$src"/. "$target"/
  done

  echo "[$(ts)] OK: UPG production copy for $type completed successfully."
}

main() {
  local arg="${1:-}"
  local type
  local copied=0

  case "$arg" in
    -h|--help)
      usage
      return 0
      ;;
    --list)
      print_supported_types
      return 0
      ;;
    "")
      for type in "${SUPPORTED_TYPES[@]}"; do
        if copy_type "$type" 0; then
          copied=$((copied + 1))
        fi
      done

      if [[ "$copied" -eq 0 ]]; then
        echo "[$(ts)] ERROR: no supported UPG production sources found in /srv." >&2
        return 1
      fi
      ;;
    *)
      type="${arg,,}"
      if [[ "$#" -gt 1 ]]; then
        echo "[$(ts)] ERROR: too many arguments." >&2
        usage >&2
        return 1
      fi

      if ! is_supported_type "$type"; then
        echo "[$(ts)] ERROR: unsupported type '$arg'." >&2
        echo "[$(ts)] INFO: use 'cp-upg --list' to show supported types." >&2
        return 1
      fi

      copy_type "$type"
      ;;
  esac
}

main "$@"
EOF_AMCS_COPY_PROD

  chown "$TARGET_USER:$TARGET_USER" "$copy_prod_launcher" 2>/dev/null || true
  chmod 0700 "$copy_prod_launcher" 2>/dev/null || true

  add_summary "TOOLS launcher installed: ~/UTILITY/TOOLS/cp-upg"
}

install_cp_upg_step() {
  if ! have_user; then
    echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
    exit 1
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

  UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
  install_cp_upg_helper
}

configure_amcs_firewall_public() {
  local firewall_cmd=""
  local port changed=0
  local ports=("8090/tcp" "5701/tcp")
  local query_rc=0
  local add_rc=0
  local reload_rc=0

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "[$(ts)] SKIP: firewall-cmd not found."
    add_summary "AMCS firewall public: SKIP (firewall-cmd missing)"
    return 0
  fi

  firewall_cmd="$(command -v firewall-cmd)"

  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "[$(ts)] SKIP: firewalld inactive or unavailable."
    add_summary "AMCS firewall public: SKIP (firewalld inactive/unavailable)"
    return 0
  fi

  for port in "${ports[@]}"; do
    if "$firewall_cmd" --permanent --zone=public --query-port="$port" >/dev/null 2>&1; then
      query_rc=0
    else
      query_rc=$?
    fi

    if [[ "$query_rc" -eq 0 ]]; then
      echo "[$(ts)] OK: firewalld public already allows $port"
    elif [[ "$query_rc" -eq 1 ]]; then
      echo "[$(ts)] ACTION: firewall-cmd --permanent --zone=public --add-port=$port"
      if "$firewall_cmd" --permanent --zone=public --add-port="$port" >/dev/null 2>&1; then
        add_rc=0
      else
        add_rc=$?
      fi
      if [[ "$add_rc" -ne 0 ]]; then
        echo "[$(ts)] SKIP: firewalld add-port failed for $port."
        add_summary "AMCS firewall public: SKIP (firewalld inactive/unavailable)"
        return 0
      fi
      changed=1
    else
      echo "[$(ts)] SKIP: firewalld query failed for $port."
      add_summary "AMCS firewall public: SKIP (firewalld inactive/unavailable)"
      return 0
    fi
  done

  if [[ "$changed" -eq 1 ]]; then
    echo "[$(ts)] ACTION: firewall-cmd --reload"
    if "$firewall_cmd" --reload >/dev/null 2>&1; then
      reload_rc=0
    else
      reload_rc=$?
    fi
    if [[ "$reload_rc" -ne 0 ]]; then
      echo "[$(ts)] SKIP: firewalld reload failed."
      add_summary "AMCS firewall public: SKIP (firewalld inactive/unavailable)"
      return 0
    fi
    add_summary "AMCS firewall public: ports added successfully (8090/tcp + 5701/tcp)"
  else
    add_summary "AMCS firewall public: ports already set (8090/tcp + 5701/tcp)"
  fi
}

install_amcs_step() {
  if [[ "$UPDATE_ONLY_MODE" == "1" ]]; then
    add_summary "AMCS: skip (update-only mode)"
    return 0
  fi

  if ! have_user; then
    echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
    exit 1
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

  UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
  TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

  if prompt_yn "MODUŁ: AMCS (~/UTILITY/AMCS + resources + launcher AMCS/main+slave + firewall public 8090/5701)?" "Y"; then
    local amcs_node_master_host=""
    ensure_amcs_java_runtime
    amcs_node_master_host="$(prompt_amcs_node_master_host)"
    install_amcs_local_launchers "$amcs_node_master_host"
    configure_amcs_firewall_public
    echo "[$(ts)] OK: AMCS done."
  else
    echo "[$(ts)] SKIP: AMCS."
    add_summary "AMCS: skipped by user"
  fi
}

install_downloader_app_script() {
  local src="${1:?}"
  local app_dir="$UTILITY_DIR/DOWNLOADER_APP"
  local bin_dir="$app_dir/bin"
  local dst="$app_dir/upg_installer.sh"
  local launcher="$bin_dir/dwupg"
  local legacy_link="/usr/local/bin/dwupg"
  local version_file="$app_dir/.downloader_version"

  echo "[$(ts)] ACTION: install downloader app into $app_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$app_dir"
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$bin_dir"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$src" "$dst"

  printf "%s\n" "$DOWNLOADER_APP_VERSION" > "$version_file"
  chown "$TARGET_USER:$TARGET_USER" "$version_file" 2>/dev/null || true
  chmod 0644 "$version_file" 2>/dev/null || true

  cat > "$launcher" <<EOF_DOWNLOADER_APP_LAUNCHER
#!/usr/bin/env bash
exec "$dst" "\$@"
EOF_DOWNLOADER_APP_LAUNCHER
  chown "$TARGET_USER:$TARGET_USER" "$launcher" 2>/dev/null || true
  chmod 0700 "$launcher" 2>/dev/null || true

  echo "[$(ts)] ACTION: cleanup legacy $legacy_link and backups"
  rm -f "$legacy_link" "${legacy_link}.bak" "${legacy_link}.bak."* 2>/dev/null || true

  echo "[$(ts)] OK: downloader app installed:"
  echo "[$(ts)]   script : $dst"
  echo "[$(ts)]   launcher: $launcher"
  echo "[$(ts)]   verfile: $version_file"
  echo "[$(ts)]   usage  : $launcher"
}

install_upgbuilder_script() {
  local src="${1:?}"
  local app_dir="$UTILITY_DIR/UPGbuilder"
  local bin_dir="$app_dir/bin"
  local dst="$app_dir/upgbuilder.sh"
  local launcher="$bin_dir/upgbuilder"
  local legacy_link="/usr/local/bin/upgbuilder"
  local version_file="$app_dir/.upgbuilder_version"
  local map_dst="$app_dir/upgbuilder.map"
  local template_dst="$app_dir/template"

  echo "[$(ts)] ACTION: install upgbuilder into $app_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$app_dir"
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$bin_dir"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$src" "$dst"

  if [[ -f "$UPGBUILDER_LOCAL_MAP" ]]; then
    echo "[$(ts)] ACTION: install local upgbuilder.map"
    install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" "$UPGBUILDER_LOCAL_MAP" "$map_dst"
  fi

  if [[ -d "$UPGBUILDER_LOCAL_TEMPLATE_DIR" ]]; then
    echo "[$(ts)] ACTION: install local template directory"
    rm -rf "$template_dst"
    cp -R "$UPGBUILDER_LOCAL_TEMPLATE_DIR" "$template_dst"
    chown -R "$TARGET_USER:$TARGET_USER" "$template_dst" 2>/dev/null || true
    find "$template_dst" -type d -exec chmod 0755 {} \; 2>/dev/null || true
    find "$template_dst" -type f -exec chmod 0644 {} \; 2>/dev/null || true
    find "$template_dst" -type f -name "*.sh" -exec chmod 0755 {} \; 2>/dev/null || true
  fi

  printf "%s\n" "$UPGBUILDER_VERSION" > "$version_file"
  chown "$TARGET_USER:$TARGET_USER" "$version_file" 2>/dev/null || true
  chmod 0644 "$version_file" 2>/dev/null || true

  cat > "$launcher" <<EOF_UPGBUILDER_LAUNCHER
#!/usr/bin/env bash
exec "$dst" "\$@"
EOF_UPGBUILDER_LAUNCHER
  chown "$TARGET_USER:$TARGET_USER" "$launcher" 2>/dev/null || true
  chmod 0700 "$launcher" 2>/dev/null || true

  echo "[$(ts)] ACTION: cleanup legacy $legacy_link and backups"
  rm -f "$legacy_link" "${legacy_link}.bak" "${legacy_link}.bak."* 2>/dev/null || true

  echo "[$(ts)] OK: upgbuilder installed:"
  echo "[$(ts)]   script   : $dst"
  echo "[$(ts)]   launcher : $launcher"
  echo "[$(ts)]   map      : $map_dst"
  echo "[$(ts)]   template : $template_dst"
  echo "[$(ts)]   verfile  : $version_file"
  echo "[$(ts)]   usage    : $launcher"
}

cleanup_downloaded_installers() {
  if [[ -d "$TMP_DIR" ]]; then
    if prompt_yn "Usunąć pobrane instalery (*.sh) z $TMP_DIR?" "Y"; then
      echo "[$(ts)] ACTION: rm -f $TMP_DIR/*.sh; rm -rf $TMP_DIR/INVENTORY"
      rm -f -- "$TMP_DIR"/*.sh 2>/dev/null || true
      rm -rf -- "$TMP_DIR/INVENTORY" 2>/dev/null || true
      echo "[$(ts)] OK: installers removed."
    else
      echo "[$(ts)] SKIP: keeping downloaded installers."
    fi
  fi
}

cleanup_tmp_installers_after_uninstall() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -f -- "$TMP_DIR"/*.sh 2>/dev/null || true
    rm -rf -- "$TMP_DIR/INVENTORY" 2>/dev/null || true
    add_summary "TMP cleanup po uninstall: wykonane ($TMP_DIR/*.sh, $TMP_DIR/INVENTORY)"
  else
    add_summary "TMP cleanup po uninstall: SKIP (TMP_DIR unavailable)"
  fi
}

cleanup_tmp_installers_no_prompt() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -f -- "$TMP_DIR"/*.sh 2>/dev/null || true
    rm -rf -- "$TMP_DIR/INVENTORY" 2>/dev/null || true
    add_summary "TMP cleanup: wykonane ($TMP_DIR/*.sh, $TMP_DIR/INVENTORY)"
  else
    add_summary "TMP cleanup: SKIP (TMP_DIR unavailable)"
  fi
}

remove_block_from_file() {
  local file="${1:?}" start="${2:?}" end="${3:?}"
  local tmp

  [[ -f "$file" ]] || return 0
  tmp="$(mktemp)"
  awk -v start="$start" -v end="$end" '
    $0==start {inside=1; next}
    $0==end   {inside=0; next}
    !inside   {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

retain_bash_logout_history_clear_no_backup() {
  local bl=""
  local bl_start="# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>"
  local bl_end="# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<"
  local block

  if [[ -z "${ITGO_HOME:-}" || "$ITGO_HOME" == "/" || "$ITGO_HOME" == "/root" ]]; then
    add_summary "MASTER purge residual cleanup: SKIP history clear retain unsafe path"
    return 0
  fi

  bl="$ITGO_HOME/.bash_logout"
  if ! is_safe_itgo_home_child_path "$bl"; then
    add_summary "MASTER purge residual cleanup: SKIP history clear retain unsafe path"
    return 0
  fi

  block=$(cat <<'BEOF'
# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>
history -c 2>/dev/null || true
history -w 2>/dev/null || true
: > "$HOME/.bash_history" 2>/dev/null || true
# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<
BEOF
)

  touch "$bl"
  remove_block_from_file "$bl" "$bl_start" "$bl_end"
  printf "\n%s\n" "$block" >> "$bl"
  chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
  chmod 0644 "$bl" 2>/dev/null || true
}

restore_master_shell_settings() {
  local bp br bl launcher_dir install_launcher update_launcher
  local legacy_install_launcher="/usr/local/bin/master-install"
  local legacy_update_launcher="/usr/local/bin/master-update"
  local bp_start="# >>> ITGO SSH HISTORY PROMPT (auto) >>>"
  local bp_end="# <<< ITGO SSH HISTORY PROMPT (auto) <<<"
  local legacy_path_start="# >>> ITGO MASTER PATH (auto) >>>"
  local legacy_path_end="# <<< ITGO MASTER PATH (auto) <<<"
  local path_start="# >>> ITGO LOCAL MODULE PATHS (auto) >>>"
  local path_end="# <<< ITGO LOCAL MODULE PATHS (auto) <<<"
  local upg_xml_start="# >>> UPG XML cleanup (auto) >>>"
  local upg_xml_end="# <<< UPG XML cleanup (auto) <<<"
  local bl_start="# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>"
  local bl_end="# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<"

  if ! have_user; then
    add_summary "Restore shell settings MASTER: SKIP (user missing)"
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  if [[ -z "${ITGO_HOME:-}" ]]; then
    add_summary "Restore shell settings MASTER: SKIP (cannot resolve home)"
    return 0
  fi

  bp="$ITGO_HOME/.bash_profile"
  br="$ITGO_HOME/.bashrc"
  bl="$ITGO_HOME/.bash_logout"
  launcher_dir="$ITGO_HOME/UTILITY/MASTER"
  install_launcher="$launcher_dir/master-install"
  update_launcher="$launcher_dir/master-update"

  if [[ -f "$bp" ]]; then
    safe_backup "$bp"
    remove_block_from_file "$bp" "$bp_start" "$bp_end"
    remove_block_from_file "$bp" "$legacy_path_start" "$legacy_path_end"
    remove_block_from_file "$bp" "$path_start" "$path_end"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
    chmod 0644 "$bp" 2>/dev/null || true
  fi

  if [[ -f "$br" ]]; then
    safe_backup "$br"
    remove_block_from_file "$br" "$upg_xml_start" "$upg_xml_end"
    chown "$TARGET_USER:$TARGET_USER" "$br" 2>/dev/null || true
    chmod 0644 "$br" 2>/dev/null || true
  fi

  if [[ -f "$bl" ]]; then
    safe_backup "$bl"
    remove_block_from_file "$bl" "$bl_start" "$bl_end"
    chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
    chmod 0644 "$bl" 2>/dev/null || true
  fi

  if [[ -f "$install_launcher" ]]; then
    rm -f "$install_launcher" 2>/dev/null || true
    add_summary "MASTER launcher removed: master-install"
  else
    add_summary "MASTER launcher removed: SKIP (master-install not present)"
  fi

  if [[ -f "$update_launcher" ]]; then
    rm -f "$update_launcher" 2>/dev/null || true
    add_summary "MASTER launcher removed: master-update"
  else
    add_summary "MASTER launcher removed: SKIP (master-update not present)"
  fi

  if [[ -d "$launcher_dir" ]]; then
    rmdir "$launcher_dir" 2>/dev/null || true
  fi

  if [[ -e "$legacy_install_launcher" || -L "$legacy_install_launcher" ]]; then
    rm -f "$legacy_install_launcher" 2>/dev/null || true
    add_summary "MASTER legacy launcher removed: $legacy_install_launcher"
  else
    add_summary "MASTER legacy launcher removed: SKIP ($legacy_install_launcher not present)"
  fi

  if [[ -e "$legacy_update_launcher" || -L "$legacy_update_launcher" ]]; then
    rm -f "$legacy_update_launcher" 2>/dev/null || true
    add_summary "MASTER legacy launcher removed: $legacy_update_launcher"
  else
    add_summary "MASTER legacy launcher removed: SKIP ($legacy_update_launcher not present)"
  fi

  add_summary "Restore shell settings MASTER: wykonane"
}

purge_master_residual_cleanup_all() {
  local utility_dir upg_dir config_dir config_parent backup_file backup_match
  local shell_bases=(
    "$ITGO_HOME/.bashrc"
    "$ITGO_HOME/.bash_profile"
    "$ITGO_HOME/.bash_logout"
    "$ITGO_HOME/.profile"
    "$ITGO_HOME/.zshrc"
  )
  local removed_any_backup=0

  if ! have_user; then
    add_summary "MASTER purge residual cleanup: SKIP (user missing)"
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  if [[ -z "${ITGO_HOME:-}" ]]; then
    add_summary "MASTER purge residual cleanup: SKIP (cannot resolve home)"
    return 0
  fi
  if [[ "$ITGO_HOME" == "/" || "$ITGO_HOME" == "/root" ]]; then
    add_summary "MASTER purge residual cleanup: SKIP unsafe target home ($ITGO_HOME)"
    return 0
  fi

  utility_dir="$ITGO_HOME/UTILITY"
  if [[ -d "$utility_dir" ]]; then
    if is_safe_itgo_utility_path "$utility_dir"; then
      rm -rf -- "$utility_dir"
      add_summary "MASTER purge residual cleanup: removed ~/UTILITY"
    else
      add_summary "MASTER purge residual cleanup: SKIP unsafe ~/UTILITY path"
    fi
  else
    add_summary "MASTER purge residual cleanup: SKIP ~/UTILITY not present"
  fi

  upg_dir="$ITGO_HOME/UPG"
  if [[ -d "$upg_dir" ]]; then
    if is_safe_itgo_upg_path "$upg_dir"; then
      rm -rf -- "$upg_dir"
      add_summary "MASTER purge residual cleanup: removed ~/UPG"
    else
      add_summary "MASTER purge residual cleanup: SKIP unsafe ~/UPG path"
    fi
  else
    add_summary "MASTER purge residual cleanup: SKIP ~/UPG not present"
  fi

  config_dir="$ITGO_HOME/.config/itgo"
  config_parent="$ITGO_HOME/.config"
  if [[ -d "$config_dir" ]]; then
    if is_safe_itgo_home_child_path "$config_dir"; then
      rm -rf -- "$config_dir"
      add_summary "MASTER purge residual cleanup: removed ~/.config/itgo"
    else
      add_summary "MASTER purge residual cleanup: SKIP unsafe ~/.config/itgo path"
    fi
  else
    add_summary "MASTER purge residual cleanup: SKIP ~/.config/itgo not present"
  fi

  if [[ -d "$config_parent" ]]; then
    if is_safe_itgo_home_child_path "$config_parent" && rmdir -- "$config_parent" 2>/dev/null; then
      add_summary "MASTER purge residual cleanup: removed empty ~/.config"
    else
      add_summary "MASTER purge residual cleanup: retained ~/.config"
    fi
  fi

  for backup_file in "${shell_bases[@]}"; do
    backup_file="${backup_file}.bak"
    if file_has_itgo_shell_marker "$backup_file"; then
      rm -f -- "$backup_file"
      add_summary "MASTER purge residual cleanup: removed shell backup ~/${backup_file#$ITGO_HOME/}"
      removed_any_backup=1
    fi
  done

  for backup_file in "${shell_bases[@]}"; do
    for backup_match in "${backup_file}.bak."*; do
      [[ -e "$backup_match" || -L "$backup_match" ]] || continue
      if file_has_itgo_shell_marker "$backup_match"; then
        rm -f -- "$backup_match"
        add_summary "MASTER purge residual cleanup: removed shell backup ~/${backup_match#$ITGO_HOME/}"
        removed_any_backup=1
      fi
    done
  done

  if [[ "$removed_any_backup" -eq 0 ]]; then
    add_summary "MASTER purge residual cleanup: no ITGO shell backups found"
  fi

  retain_bash_logout_history_clear_no_backup
  add_summary "MASTER purge residual cleanup: history clear retained"
}

install_ssh_history_prompt_block() {
  local bp="$ITGO_HOME/.bash_profile"
  local status_launcher="$ITGO_HOME/UTILITY/STATUS/bin/status"

  local START="# >>> ITGO SSH HISTORY PROMPT (auto) >>>"
  local END="# <<< ITGO SSH HISTORY PROMPT (auto) <<<"

  local OLD_START="# --- system-audit on SSH login (background) ---"
  local OLD_END="# --- /system-audit ---"

  local BLOCK
  BLOCK=$(cat <<'BEOF'
# >>> ITGO SSH HISTORY PROMPT (auto) >>>
case "$-" in *i*) : ;; *) return 0 ;; esac
[[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]] || return 0

if [[ -z "${ITGO_ASKED_HISTORY:-}" ]]; then
  export ITGO_ASKED_HISTORY=1

  echo
  read -r -p "Zapisywać historię bash dla tej sesji? [y/N]: " __ans
  case "${__ans,,}" in
    y|yes)
      echo "OK: historia będzie zapisywana (ta sesja)."
      ;;
    *)
      echo "OK: historia NIE będzie zapisywana (ta sesja)."
      unset HISTFILE
      export HISTSIZE=0
      export HISTFILESIZE=0
      set +o history 2>/dev/null || true
      history -c 2>/dev/null || true
      ;;
  esac
fi

sleep 0.05
if [[ -x "__STATUS_LAUNCHER__" ]]; then
  "__STATUS_LAUNCHER__" 2>/dev/null || true
fi
# <<< ITGO SSH HISTORY PROMPT (auto) <<<
BEOF
)
  BLOCK="${BLOCK//__STATUS_LAUNCHER__/$status_launcher}"

  echo "[$(ts)] ACTION: patch $bp (replace old status block + ensure single prompt+status)"
  touch "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  chmod 0644 "$bp" 2>/dev/null || true
  safe_backup "$bp"

  if grep -qF "$START" "$bp" 2>/dev/null; then
    awk -v start="$START" -v end="$END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bp" > "${bp}.tmp"
    mv "${bp}.tmp" "$bp"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
    chmod 0644 "$bp" 2>/dev/null || true
  fi

  if grep -qF "$OLD_START" "$bp" 2>/dev/null; then
    awk -v start="$OLD_START" -v end="$OLD_END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bp" > "${bp}.tmp"
    mv "${bp}.tmp" "$bp"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
    chmod 0644 "$bp" 2>/dev/null || true
  fi

  printf "\n%s\n" "$BLOCK" >> "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  chmod 0644 "$bp" 2>/dev/null || true

  echo "[$(ts)] OK: installed single SSH prompt+status block. Backup: ${bp}.bak"
}

install_status_step() {
  local status_sh="${1:?}"

  if should_install_or_update_module "STATUS"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "MODUŁ: Server-Status (lokalny launcher + lokalne collectory/cache; systemd jako wyjątek techniczny)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
        download_to_tmp "$STATUS_URL" "$status_sh" "$STATUS_LOCAL_PATH"
        run_module_root "$status_sh" "$TARGET_USER"
        echo "[$(ts)] OK: Server-Status done."
      else
        echo "[$(ts)] SKIP: Server-Status."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
      download_to_tmp "$STATUS_URL" "$status_sh" "$STATUS_LOCAL_PATH"
      run_module_root "$status_sh" "$TARGET_USER"
      echo "[$(ts)] OK: Server-Status done."
    fi
  fi
}

install_tseq_step() {
  local tseq_sh="${1:?}"

  if should_install_or_update_module "TSEQ"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "MODUŁ: TSEQ (systemd + ~/UTILITY/TSEQ/bin/tseq + ~/UTILITY/TSEQ)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
        download_to_tmp "$TSEQ_URL" "$tseq_sh" "$TSEQ_LOCAL_PATH"
        run_module_root "$tseq_sh"
        echo "[$(ts)] OK: TSEQ done."
      else
        echo "[$(ts)] SKIP: TSEQ."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
      download_to_tmp "$TSEQ_URL" "$tseq_sh" "$TSEQ_LOCAL_PATH"
      run_module_root "$tseq_sh"
      echo "[$(ts)] OK: TSEQ done."
    fi
  fi
}

install_cleanup_step() {
  local cleanup_sh="${1:?}"

  if should_install_or_update_module "CLEANUP"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "MODUŁ: Cleanup (usuń ~/UPG/*.xml + czyść ~/.cache przy wylogowaniu z SSH)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
        download_to_tmp "$CLEANUP_URL" "$cleanup_sh" "$CLEANUP_LOCAL_PATH"
        run_module_as_itgo "$cleanup_sh"
        echo "[$(ts)] OK: Cleanup done."
      else
        echo "[$(ts)] SKIP: Cleanup."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
      download_to_tmp "$CLEANUP_URL" "$cleanup_sh" "$CLEANUP_LOCAL_PATH"
      run_module_as_itgo "$cleanup_sh"
      echo "[$(ts)] OK: Cleanup done."
    fi
  fi
}

install_downloader_app_step() {
  local downloader_app_sh="${1:?}"

  if should_install_or_update_module "DOWNLOADER_APP"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "MODUŁ: DOWNLOADER_APP (lokalnie: ~/UTILITY/DOWNLOADER_APP/upg_installer.sh + ~/UTILITY/DOWNLOADER_APP/bin/dwupg)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

        if ! have_user; then
          echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
          exit 1
        fi

        ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
        [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

        UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
        TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

        [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
        [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

        download_to_tmp "$DOWNLOADER_APP_URL" "$downloader_app_sh" "$DOWNLOADER_APP_LOCAL_PATH"
        install_downloader_app_script "$downloader_app_sh"
        echo "[$(ts)] OK: DOWNLOADER_APP done."
      else
        echo "[$(ts)] SKIP: DOWNLOADER_APP."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

      if ! have_user; then
        echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
        exit 1
      fi

      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

      UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
      TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

      [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
      [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

      download_to_tmp "$DOWNLOADER_APP_URL" "$downloader_app_sh" "$DOWNLOADER_APP_LOCAL_PATH"
      install_downloader_app_script "$downloader_app_sh"
      echo "[$(ts)] OK: DOWNLOADER_APP done."
    fi
  fi
}

install_upgbuilder_step() {
  local upgbuilder_sh="${1:?}"
  local upgbuilder_launcher

  if should_install_or_update_module "UPGBUILDER"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "MODUŁ: UPGbuilder (lokalnie: ~/UTILITY/UPGbuilder/upgbuilder.sh + ~/UTILITY/UPGbuilder/bin/upgbuilder)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

        if ! have_user; then
          echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
          exit 1
        fi

        ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
        [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

        UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
        TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

        [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
        [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

        download_to_tmp "$UPGBUILDER_URL" "$upgbuilder_sh" "$UPGBUILDER_LOCAL_PATH"
        install_upgbuilder_script "$upgbuilder_sh"
        upgbuilder_launcher="$UTILITY_DIR/UPGbuilder/bin/upgbuilder"

        if prompt_yn "Uruchomić teraz: $upgbuilder_launcher --detect jako $TARGET_USER?" "Y"; then
          echo "[$(ts)] RUN(itgo): sudo -H -u $TARGET_USER $upgbuilder_launcher --detect"
          sudo -H -u "$TARGET_USER" "$upgbuilder_launcher" --detect
        else
          echo "[$(ts)] SKIP: upgbuilder --detect."
        fi

        echo "[$(ts)] OK: UPGbuilder done."
      else
        echo "[$(ts)] SKIP: UPGbuilder."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

      if ! have_user; then
        echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
        exit 1
      fi

      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

      UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
      TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

      [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
      [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

      download_to_tmp "$UPGBUILDER_URL" "$upgbuilder_sh" "$UPGBUILDER_LOCAL_PATH"
      install_upgbuilder_script "$upgbuilder_sh"
      upgbuilder_launcher="$UTILITY_DIR/UPGbuilder/bin/upgbuilder"

      if prompt_yn "Uruchomić teraz: $upgbuilder_launcher --detect jako $TARGET_USER?" "Y"; then
        echo "[$(ts)] RUN(itgo): sudo -H -u $TARGET_USER $upgbuilder_launcher --detect"
        sudo -H -u "$TARGET_USER" "$upgbuilder_launcher" --detect
      else
        echo "[$(ts)] SKIP: upgbuilder --detect."
      fi

      echo "[$(ts)] OK: UPGbuilder done."
    fi
  fi
}

install_serviceguard_step() {
  local serviceguard_sh="${1:?}"

  if should_install_or_update_module "SERVICEGUARD"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "MODUŁ: SERVICEGUARD (lokalny svcguard + tworzenie systemd usług tylko po jawnym --apply)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

        if ! have_user; then
          echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
          exit 1
        fi

        ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
        [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

        UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
        TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

        [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
        [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

        download_to_tmp "$SERVICEGUARD_URL" "$serviceguard_sh" "$SERVICEGUARD_LOCAL_PATH"
        run_module_root "$serviceguard_sh" "$TARGET_USER"
        echo "[$(ts)] OK: SERVICEGUARD done."
      else
        echo "[$(ts)] SKIP: SERVICEGUARD."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

      if ! have_user; then
        echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
        exit 1
      fi

      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

      UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
      TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

      [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
      [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

      download_to_tmp "$SERVICEGUARD_URL" "$serviceguard_sh" "$SERVICEGUARD_LOCAL_PATH"
      run_module_root "$serviceguard_sh" "$TARGET_USER"
      echo "[$(ts)] OK: SERVICEGUARD done."
    fi
  fi
}

install_inventory_step() {
  local inventory_dir="${1:?}"
  local inventory_sh="$inventory_dir/inventory_installer_public.sh"

  if should_install_or_update_module "INVENTORY"; then
    if [[ "$MODULE_DECISION" == "install" ]]; then
      if prompt_yn "KROK: zainstalować Inventory Collector (itgo-inv)?" "Y"; then
        ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

        if ! have_user; then
          echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
          exit 1
        fi

        ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
        [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

        UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
        TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

        [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
        [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

        download_inventory_payload "$inventory_dir"
        run_module_root "$inventory_sh" "$TARGET_USER"
        echo "[$(ts)] OK: INVENTORY done."
      else
        echo "[$(ts)] SKIP: INVENTORY."
      fi
    else
      ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

      if ! have_user; then
        echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
        exit 1
      fi

      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

      UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
      TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

      [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
      [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

      download_inventory_payload "$inventory_dir"
      run_module_root "$inventory_sh" "$TARGET_USER"
      echo "[$(ts)] OK: INVENTORY done."
    fi
  fi
}

bootstrap_block() {
  ensure_user_and_password_if_missing
  ensure_home_dirs
  ensure_sudo_nopasswd_block
  ensure_acls_block
  ensure_docker_group_membership
  docker_login_amms_registry
}

prepare_dirs_after_skip_bootstrap() {
  if have_user; then
    ITGO_HOME="$(resolve_home)" || true
    UTILITY_DIR="$ITGO_HOME/UTILITY"
    LOG_DIR="$UTILITY_DIR/LOG"
    LOG_OTHER="$LOG_DIR/OTHER"
    LOG_UPDATE="$LOG_DIR/UPDATE"
    TMP_DIR="$UTILITY_DIR/TMP"
    cleanup_old_bash_backups
    start_final_logging_if_possible
  fi
}

prepare_user_paths_if_possible() {
  if have_user; then
    ITGO_HOME="$(resolve_home)" || true
    if [[ -n "${ITGO_HOME:-}" ]]; then
      UTILITY_DIR="$ITGO_HOME/UTILITY"
      LOG_DIR="$UTILITY_DIR/LOG"
      LOG_OTHER="$LOG_DIR/OTHER"
      LOG_UPDATE="$LOG_DIR/UPDATE"
      TMP_DIR="$UTILITY_DIR/TMP"
    fi
  fi
}

ensure_tmp_dir_for_module_actions() {
  [[ -n "${TMP_DIR:-}" ]] || return 1

  if [[ ! -d "$TMP_DIR" ]]; then
    install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"
  fi
}

prompt_uninstall_scope() {
  local ans=""

  echo "Wybierz zakres uninstall:" >&2
  echo "1) Odinstaluj wszystkie moduły + przywróć ustawienia MASTER" >&2
  echo "2) Odinstaluj pojedynczy moduł" >&2
  echo "3) Przywróć tylko ustawienia shell dodane przez MASTER" >&2
  echo "q) Anuluj uninstall" >&2

  while true; do
    printf "%s" "Wybierz [1-3/q]: " >&2
    read -r ans || true
    case "${ans,,}" in
      1) echo "all"; return 0 ;;
      2) echo "single"; return 0 ;;
      3) echo "master-shell"; return 0 ;;
      q) echo "cancel"; return 0 ;;
      *) echo "Wpisz: 1, 2, 3 albo q." >&2 ;;
    esac
  done
}

prompt_uninstall_module_choice() {
  local ans=""

  echo "Wybierz moduł do odinstalowania:" >&2
  echo "1) STATUS" >&2
  echo "2) CLEANUP" >&2
  echo "3) TSEQ" >&2
  echo "4) DOWNLOADER_APP" >&2
  echo "5) UPGBUILDER" >&2
  echo "6) SERVICEGUARD" >&2
  echo "7) INVENTORY" >&2
  echo "q) Anuluj uninstall" >&2

  while true; do
    printf "%s" "Wybierz [1-7/q]: " >&2
    read -r ans || true
    case "$ans" in
      1) echo "STATUS"; return 0 ;;
      2) echo "CLEANUP"; return 0 ;;
      3) echo "TSEQ"; return 0 ;;
      4) echo "DOWNLOADER_APP"; return 0 ;;
      5) echo "UPGBUILDER"; return 0 ;;
      6) echo "SERVICEGUARD"; return 0 ;;
      7) echo "INVENTORY"; return 0 ;;
      q|Q) echo "cancel"; return 0 ;;
      *) echo "Wpisz liczbę od 1 do 7 albo q." >&2 ;;
    esac
  done
}

uninstall_status_step() {
  local status_sh="${1:?}"

  ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module uninstall."; exit 1; }
  download_to_tmp "$STATUS_URL" "$status_sh" "$STATUS_LOCAL_PATH"
  run_module_root "$status_sh" --uninstall "$TARGET_USER"
  echo "[$(ts)] OK: STATUS uninstall done."
  add_summary "Uninstall: STATUS"
}

uninstall_tseq_step() {
  local tseq_sh="${1:?}"

  ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module uninstall."; exit 1; }
  download_to_tmp "$TSEQ_URL" "$tseq_sh" "$TSEQ_LOCAL_PATH"
  run_module_root "$tseq_sh" --uninstall
  echo "[$(ts)] OK: TSEQ uninstall done."
  add_summary "Uninstall: TSEQ"
}

uninstall_cleanup_step() {
  local cleanup_sh="${1:?}"

  ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module uninstall."; exit 1; }
  download_to_tmp "$CLEANUP_URL" "$cleanup_sh" "$CLEANUP_LOCAL_PATH"
  run_module_as_itgo "$cleanup_sh" --uninstall
  echo "[$(ts)] OK: CLEANUP uninstall done."
  add_summary "Uninstall: CLEANUP"
}

uninstall_downloader_app_step() {
  local app_dir legacy_link

  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' missing. Pomijam DOWNLOADER_APP uninstall."
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] WARN: cannot resolve home for '$TARGET_USER'. Pomijam DOWNLOADER_APP uninstall."; return 0; }

  app_dir="$ITGO_HOME/UTILITY/DOWNLOADER_APP"
  legacy_link="/usr/local/bin/dwupg"

  rm -f "$legacy_link" "${legacy_link}.bak" "${legacy_link}.bak."* 2>/dev/null || true
  rm -rf "$app_dir" 2>/dev/null || true

  echo "[$(ts)] OK: DOWNLOADER_APP uninstall done."
  add_summary "Uninstall: DOWNLOADER_APP"
}

uninstall_upgbuilder_step() {
  local app_dir legacy_link

  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' missing. Pomijam UPGbuilder uninstall."
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] WARN: cannot resolve home for '$TARGET_USER'. Pomijam UPGbuilder uninstall."; return 0; }

  app_dir="$ITGO_HOME/UTILITY/UPGbuilder"
  legacy_link="/usr/local/bin/upgbuilder"

  rm -f "$legacy_link" "${legacy_link}.bak" "${legacy_link}.bak."* 2>/dev/null || true
  rm -rf "$app_dir" 2>/dev/null || true

  echo "[$(ts)] OK: UPGbuilder uninstall done."
  add_summary "Uninstall: UPGBUILDER"
}

uninstall_serviceguard_step() {
  local serviceguard_sh="${1:?}"

  ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module uninstall."; exit 1; }
  download_to_tmp "$SERVICEGUARD_URL" "$serviceguard_sh" "$SERVICEGUARD_LOCAL_PATH"
  run_module_root "$serviceguard_sh" --uninstall "$TARGET_USER"
  echo "[$(ts)] OK: SERVICEGUARD uninstall done."
  add_summary "Uninstall: SERVICEGUARD"
}

uninstall_inventory_step() {
  local app_dir legacy_link

  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' missing. Pomijam INVENTORY uninstall."
    return 0
  fi

  ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
  [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] WARN: cannot resolve home for '$TARGET_USER'. Pomijam INVENTORY uninstall."; return 0; }

  app_dir="$ITGO_HOME/UTILITY/INVENTORY"
  legacy_link="/usr/local/bin/itgo-inv"

  rm -f "$legacy_link" "${legacy_link}.bak" "${legacy_link}.bak."* 2>/dev/null || true
  rm -rf "$app_dir" 2>/dev/null || true

  echo "[$(ts)] OK: INVENTORY uninstall done."
  add_summary "Uninstall: INVENTORY"
}

run_single_module_uninstall() {
  local module="${1:?}" status_sh="${2:?}" cleanup_sh="${3:?}" tseq_sh="${4:?}" serviceguard_sh="${5:?}"

  case "$module" in
    STATUS)         uninstall_status_step "$status_sh" ;;
    CLEANUP)        uninstall_cleanup_step "$cleanup_sh" ;;
    TSEQ)           uninstall_tseq_step "$tseq_sh" ;;
    DOWNLOADER_APP) uninstall_downloader_app_step ;;
    UPGBUILDER)     uninstall_upgbuilder_step ;;
    SERVICEGUARD)   uninstall_serviceguard_step "$serviceguard_sh" ;;
    INVENTORY)      uninstall_inventory_step ;;
    *) echo "[$(ts)] ERROR: unknown module for uninstall: $module"; exit 1 ;;
  esac
}

run_all_module_uninstalls() {
  local status_sh="${1:?}" cleanup_sh="${2:?}" tseq_sh="${3:?}" serviceguard_sh="${4:?}"

  uninstall_status_step "$status_sh"
  uninstall_cleanup_step "$cleanup_sh"
  uninstall_tseq_step "$tseq_sh"
  uninstall_downloader_app_step
  uninstall_upgbuilder_step
  uninstall_serviceguard_step "$serviceguard_sh"
  uninstall_inventory_step
}

section() {
  echo
  echo "===================================================="
  echo "[$(ts)] $*"
  echo "===================================================="
}

main() {
  local detected_modules="" uninstall_scope="" uninstall_module=""
  local status_sh cleanup_sh tseq_sh downloader_app_sh upgbuilder_sh serviceguard_sh inventory_dir

  need_root
  prelog "BEGIN: ITGO Master Installer v$MASTER_VERSION user=$TARGET_USER"

  if [[ "$UPDATE_ONLY_MODE" == "1" ]]; then
    add_summary "MODE: update-only"
    if ! have_user; then
      echo "[$(ts)] WARN: user '$TARGET_USER' nie istnieje. Pomijam update-only."
      add_summary "Update-only: SKIP (user missing: $TARGET_USER)"
      print_summary
      exit 0
    fi

    prepare_user_paths_if_possible
    if [[ -z "${ITGO_HOME:-}" ]]; then
      echo "[$(ts)] WARN: nie udało się ustalić HOME dla '$TARGET_USER'. Pomijam update-only."
      add_summary "Update-only: SKIP (cannot resolve home)"
      print_summary
      exit 0
    fi

    detected_modules="$(detect_installed_modules)"
    print_detected_modules_summary "$detected_modules"

    install_cp_upg_helper

    if ! ensure_tmp_dir_for_module_actions; then
      echo "[$(ts)] WARN: nie udało się przygotować TMP_DIR dla update-only. Pomijam update-only."
      add_summary "Update-only: SKIP (cannot prepare TMP_DIR)"
      print_summary
      exit 0
    fi

    status_sh="$TMP_DIR/status_installer_public.sh"
    cleanup_sh="$TMP_DIR/cleanup_installer_public.sh"
    tseq_sh="$TMP_DIR/tseq_installer_public.sh"
    downloader_app_sh="$TMP_DIR/upg_installer.sh"
    upgbuilder_sh="$TMP_DIR/upgbuilder.sh"
    serviceguard_sh="$TMP_DIR/serviceguard_installer_public.sh"
    inventory_dir="$TMP_DIR/INVENTORY"

    section "UPDATE-ONLY - MODUŁY"
    install_status_step "$status_sh"
    install_tseq_step "$tseq_sh"
    install_cleanup_step "$cleanup_sh"
    install_downloader_app_step "$downloader_app_sh"
    install_upgbuilder_step "$upgbuilder_sh"
    install_serviceguard_step "$serviceguard_sh"
    install_inventory_step "$inventory_dir"
    install_amcs_step

    cleanup_tmp_installers_no_prompt
    echo "[$(ts)] DONE."
    print_summary
    exit 0
  fi

  prepare_user_paths_if_possible

  detected_modules="$(detect_installed_modules)"
  if any_itgo_module_installed; then
    print_detected_modules_summary "$detected_modules"
    if prompt_yn "Wykryto istniejącą instalację ITGO. Czy chcesz odinstalować?" "N"; then
      [[ -n "${TMP_DIR:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve TMP_DIR for uninstall."; exit 1; }
      ensure_tmp_dir_for_module_actions

      status_sh="$TMP_DIR/status_installer_public.sh"
      cleanup_sh="$TMP_DIR/cleanup_installer_public.sh"
      tseq_sh="$TMP_DIR/tseq_installer_public.sh"
      downloader_app_sh="$TMP_DIR/upg_installer.sh"
      upgbuilder_sh="$TMP_DIR/upgbuilder.sh"
      serviceguard_sh="$TMP_DIR/serviceguard_installer_public.sh"
      inventory_dir="$TMP_DIR/INVENTORY"

      uninstall_scope="$(prompt_uninstall_scope)"
      if [[ "$uninstall_scope" == "all" ]]; then
        add_summary "Wybrany uninstall scope: all"
        run_all_module_uninstalls "$status_sh" "$cleanup_sh" "$tseq_sh" "$serviceguard_sh"
        restore_master_shell_settings
        cleanup_tmp_installers_after_uninstall
        purge_master_residual_cleanup_all
        print_summary
        exit 0
      elif [[ "$uninstall_scope" == "single" ]]; then
        add_summary "Wybrany uninstall scope: single"
        uninstall_module="$(prompt_uninstall_module_choice)"
        if [[ "$uninstall_module" == "cancel" ]]; then
          echo "[$(ts)] SKIP: uninstall cancelled."
          add_summary "Uninstall: cancelled at module selection"
        else
          run_single_module_uninstall "$uninstall_module" "$status_sh" "$cleanup_sh" "$tseq_sh" "$serviceguard_sh"
          cleanup_tmp_installers_after_uninstall
          print_summary
          exit 0
        fi
      elif [[ "$uninstall_scope" == "master-shell" ]]; then
        add_summary "Wybrany uninstall scope: master-shell"
        restore_master_shell_settings
        cleanup_tmp_installers_after_uninstall
        print_summary
        exit 0
      else
        echo "[$(ts)] SKIP: uninstall cancelled."
        add_summary "Uninstall: cancelled at scope selection"
      fi
    fi
  fi

  section "SEKCJA 1/8 - BOOTSTRAP"
  if prompt_yn "BOOTSTRAP: user '$TARGET_USER' + katalogi HOME + (opcjonalnie) sudoers + ACL + docker group?" "Y"; then
    bootstrap_block
  else
    echo "[$(ts)] SKIP: bootstrap."
    prepare_dirs_after_skip_bootstrap
  fi

  install_master_launcher

  section "SEKCJA 2/8 - NARZĘDZIA SYSTEMOWE"
  if prompt_yn "KROK: sprawdzić nano, mc, rsync, dos2unix, jq, wget i doinstalować brakujące?" "Y"; then
    ensure_basic_tools_step
  else
    echo "[$(ts)] SKIP: pakiety bazowe."
  fi

  ensure_client_identity_file

  section "SEKCJA 3/8 - ZACHOWANIE SHELLA"
  if prompt_yn "KROK: ustawić w ~/.bash_logout: history -c && history -w ?" "Y"; then
    if ! have_user; then
      echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
      exit 1
    fi
    ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
    [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }
    install_bash_logout_history_clear
    HISTORY_CLEAR_ON_LOGOUT_ENABLED=1
    add_summary "Shell: history clear on logout enabled"
  else
    echo "[$(ts)] SKIP: ~/.bash_logout history clear."
    add_summary "Shell: history clear on logout skipped"
  fi

  if [[ -z "${TMP_DIR:-}" || ! -d "${TMP_DIR:-/nonexistent}" ]]; then
    if have_user; then
      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      UTILITY_DIR="$ITGO_HOME/UTILITY"
      LOG_DIR="$UTILITY_DIR/LOG"
      LOG_OTHER="$LOG_DIR/OTHER"
      LOG_UPDATE="$LOG_DIR/UPDATE"
      TMP_DIR="$UTILITY_DIR/TMP"
      [[ -d "$TMP_DIR" ]] || echo "[$(ts)] WARN: $TMP_DIR missing; modules download may fail."
    fi
  fi

  status_sh="$TMP_DIR/status_installer_public.sh"
  cleanup_sh="$TMP_DIR/cleanup_installer_public.sh"
  tseq_sh="$TMP_DIR/tseq_installer_public.sh"
  downloader_app_sh="$TMP_DIR/upg_installer.sh"
  upgbuilder_sh="$TMP_DIR/upgbuilder.sh"
  serviceguard_sh="$TMP_DIR/serviceguard_installer_public.sh"
  inventory_dir="$TMP_DIR/INVENTORY"

  section "SEKCJA 4/8 - MODUŁY CORE"
  install_status_step "$status_sh"
  install_tseq_step "$tseq_sh"

  section "SEKCJA 5/8 - HOOKI I NARZĘDZIA UŻYTKOWE"
  if [[ "$HISTORY_CLEAR_ON_LOGOUT_ENABLED" == "1" ]]; then
    echo "[$(ts)] SKIP: SSH history prompt pominięty, bo włączono czyszczenie historii przy wylogowaniu."
    add_summary "Shell: SSH history prompt skipped because history clear on logout is enabled"
  else
    if prompt_yn "MODUŁ: SSH login prompt: pytać czy zapisywać historię + potem lokalny STATUS/bin/status (bez dubli)?" "Y"; then
      if ! have_user; then
        echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
        exit 1
      fi
      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }
      install_ssh_history_prompt_block
      add_summary "Shell: SSH history prompt installed"
    else
      echo "[$(ts)] SKIP: SSH history prompt."
      add_summary "Shell: SSH history prompt skipped"
    fi
  fi

  install_cleanup_step "$cleanup_sh"
  install_downloader_app_step "$downloader_app_sh"
  install_upgbuilder_step "$upgbuilder_sh"
  install_serviceguard_step "$serviceguard_sh"
  install_inventory_step "$inventory_dir"

  section "SEKCJA 6/8 - TOOLS"
  if prompt_yn "MODUŁ: TOOLS/cp-upg (lokalny helper kopiowania produkcji do ~/UPG/EDM, ZM, MPI, P1ADAPTER)?" "Y"; then
    install_cp_upg_step
  else
    echo "[$(ts)] SKIP: TOOLS/cp-upg."
    add_summary "TOOLS/cp-upg: skipped by user"
  fi

  section "SEKCJA 7/8 - AMCS"
  install_amcs_step

  section "SEKCJA 8/8 - PORZĄDKI KOŃCOWE"
  cleanup_downloaded_installers

  echo "[$(ts)] DONE."
  [[ -n "${FINAL_LOG:-}" ]] && echo "[$(ts)] Master log: $FINAL_LOG"
  print_summary
}

main "$@"
