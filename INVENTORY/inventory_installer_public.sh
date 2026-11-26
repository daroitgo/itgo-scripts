#!/usr/bin/env bash
set -euo pipefail

# --- Python 3 runtime of the inventory collector ------------------------------
# The collector needs Python 3.6 or newer: os.scandir() iterators are closed
# explicitly (ScandirIterator.close(), Python 3.6), and str.casefold(),
# os.cpu_count() and zipfile.BadZipFile are Python 3 only.  Python 2.7 cannot
# run it.  Keep the candidate list and the probe aligned with
# collector_python_command in itgo-inv and inventory_python_command in
# MASTER/master_installer.sh.
INV_PYTHON_MIN_LABEL="3.6"
INV_PYTHON_CANDIDATES="python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3.7 python3.6"
# Isolated mode (-I): the current directory and PYTHON* variables cannot
# change what the probe imports.  Python 2 rejects -I and is never selected.
INV_PYTHON_PROBE='import sys
if sys.version_info[:2] < (3, 6):
    sys.exit(1)
import argparse, errno, json, os, re, shlex, subprocess, tempfile, time, zipfile
sys.exit(0 if hasattr(os, "scandir") else 1)'
INV_OS_RELEASE="/etc/os-release"
INV_PYTHON=""
INV_PYTHON_VERSION=""
INV_PYTHON_SEEN=""
INV_APT_UPDATED=no

inv_error() { printf 'ERROR: %s\n' "$*" >&2; }
inv_warn() { printf 'WARNING: %s\n' "$*" >&2; }

# Version string of a working interpreter ("3.6.8"); fails when it does not run.
inv_python_version() {
  "$1" -c 'import sys; sys.stdout.write("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null
}

# The first compatible Python 3 in PATH: INV_PYTHON (absolute path) and
# INV_PYTHON_VERSION.  INV_PYTHON_SEEN lists interpreters found but rejected.
inv_find_python() {
  local candidate path version

  INV_PYTHON=""; INV_PYTHON_VERSION=""; INV_PYTHON_SEEN=""
  for candidate in $INV_PYTHON_CANDIDATES; do
    path="$(command -v "$candidate" 2>/dev/null)" || continue
    [ -n "$path" ] || continue
    if "$path" -I -c "$INV_PYTHON_PROBE" >/dev/null 2>&1; then
      INV_PYTHON="$path"
      INV_PYTHON_VERSION="$(inv_python_version "$path" || printf 'unknown')"
      return 0
    fi
    version="$(inv_python_version "$path" || printf 'does not run')"
    case " $INV_PYTHON_SEEN " in
      *" $path ("*) ;;
      *) INV_PYTHON_SEEN="${INV_PYTHON_SEEN:+$INV_PYTHON_SEEN, }$path ($version)" ;;
    esac
  done
  return 1
}

# Supported distribution family from os-release: rhel or debian (same rule as
# the MASTER installer: RHEL, Oracle Linux, Rocky, Alma, CentOS, Fedora /
# Debian, Ubuntu).
inv_os_family() {
  local ids

  ids="$(
    # shellcheck disable=SC1090
    [ -r "$INV_OS_RELEASE" ] && . "$INV_OS_RELEASE" 2>/dev/null
    printf ' %s %s ' "${ID:-}" "${ID_LIKE:-}"
  )"
  ids="$(printf '%s' "$ids" | tr 'A-Z' 'a-z')"
  case "$ids" in
    *' rhel '*|*' fedora '*|*' centos '*|*' rocky '*|*' almalinux '*|*' ol '*|*' oracle '*) printf 'rhel' ;;
    *' debian '*|*' ubuntu '*) printf 'debian' ;;
    *) return 1 ;;
  esac
}

# Python 3 package candidates in the distribution's own repositories.
# rhel: python3 (Oracle Linux 7 ol7_latest: 3.6.8; EL8/EL9 AppStream/BaseOS),
# python36 for older EL7/EL8 repository layouts.  debian: python3.
inv_python_packages() {
  case "$1" in
    rhel) printf '%s\n' python3 python36 ;;
    debian) printf '%s\n' python3 ;;
  esac
}

# Whether a package is already installed (it is then never upgraded here).
inv_pkg_installed() {
  case "$1" in
    rhel) command -v rpm >/dev/null 2>&1 && rpm -q "$2" >/dev/null 2>&1 ;;
    debian)
      command -v dpkg-query >/dev/null 2>&1 \
        && dpkg-query -W -f='${Status}\n' "$2" 2>/dev/null | grep -q 'install ok installed'
      ;;
    *) return 1 ;;
  esac
}

# inv_pkg_install <family> <package>: one non-interactive installation from the
# repositories already configured on the system (no repository changes).
inv_pkg_install() {
  case "$1" in
    debian)
      command -v apt-get >/dev/null 2>&1 || return 1
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$2"
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        dnf -y install "$2"
      elif command -v yum >/dev/null 2>&1; then
        yum -y install "$2"
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

# Refreshes the apt package lists once per installer run (Debian/Ubuntu).
inv_apt_update() {
  [ "$INV_APT_UPDATED" = no ] || return 0
  INV_APT_UPDATED=yes
  command -v apt-get >/dev/null 2>&1 || return 0
  apt-get update >/dev/null 2>&1 || inv_warn 'apt-get update failed; using the cached package lists'
}

# A compatible Python 3 is used as it is (nothing installed or upgraded).
# Without one, the distribution's Python 3 package is installed side by side
# with any existing Python 2: /usr/bin/python, alternatives and Python 2 are
# never touched by this installer.
inventory_ensure_python3() {
  local family pkg attempted=""

  if inv_find_python; then
    printf 'Python runtime for the inventory collector: %s (Python %s)\n' "$INV_PYTHON" "$INV_PYTHON_VERSION"
    return 0
  fi

  printf 'No compatible Python %s+ found for the inventory collector%s.\n' \
    "$INV_PYTHON_MIN_LABEL" "${INV_PYTHON_SEEN:+ (rejected: $INV_PYTHON_SEEN)}"

  if ! family="$(inv_os_family)"; then
    inv_error "Python ${INV_PYTHON_MIN_LABEL}+ is missing and the distribution is not supported for automatic installation (RHEL/Oracle Linux/Rocky/AlmaLinux or Debian/Ubuntu family required); install Python ${INV_PYTHON_MIN_LABEL}+ (python3) manually and run the installer again."
    return 1
  fi

  [ "$family" != debian ] || inv_apt_update
  for pkg in $(inv_python_packages "$family"); do
    if inv_pkg_installed "$family" "$pkg"; then
      printf 'Package %s is already installed but provides no compatible interpreter; it is not upgraded.\n' "$pkg"
      continue
    fi
    attempted="${attempted:+$attempted }$pkg"
    printf 'Installing %s from the configured system repositories\n' "$pkg"
    if inv_pkg_install "$family" "$pkg"; then
      hash -r 2>/dev/null || true
      if inv_find_python; then
        printf 'Python runtime installed for the inventory collector: %s (Python %s, package %s)\n' "$INV_PYTHON" "$INV_PYTHON_VERSION" "$pkg"
        return 0
      fi
      inv_error "package $pkg was installed, but no compatible Python ${INV_PYTHON_MIN_LABEL}+ interpreter was found afterwards${INV_PYTHON_SEEN:+ (found: $INV_PYTHON_SEEN)}."
      return 1
    fi
    inv_warn "installation of package $pkg failed"
  done

  if [ -z "$attempted" ]; then
    inv_error "Python ${INV_PYTHON_MIN_LABEL}+ is required, but the installed Python 3 packages do not provide it${INV_PYTHON_SEEN:+ (found: $INV_PYTHON_SEEN)}; install Python ${INV_PYTHON_MIN_LABEL}+ manually and run the installer again."
  else
    inv_error "could not install Python ${INV_PYTHON_MIN_LABEL}+ (tried: $attempted); check that the configured package repositories provide python3 and are reachable, then run the installer again."
  fi
  return 1
}

# The installed collector must start (imports, syntax, argument parsing) with
# the selected interpreter; --help writes no report and reads no system data.
inventory_verify_collector() {
  "$1" "$2" --help >/dev/null 2>&1
}

if [ "${INVENTORY_INSTALLER_LIB_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

TARGET_USER="${1:-itgo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  printf 'error: invalid target user name: %s\n' "$TARGET_USER" >&2
  exit 1
fi

if command -v getent >/dev/null 2>&1 && getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  ITGO_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
  ITGO_HOME="/home/${TARGET_USER}"
fi

if [ -z "$ITGO_HOME" ]; then
  printf 'error: could not determine home directory for user %s\n' "$TARGET_USER" >&2
  exit 1
fi

INSTALL_DIR="${ITGO_HOME}/UTILITY/INVENTORY"
BIN_DIR="${INSTALL_DIR}/bin"
REPORTS_DIR="${INSTALL_DIR}/reports"
LOGS_DIR="${INSTALL_DIR}/logs"
CONFIG_DIR="${INSTALL_DIR}/config"
RUN_DIR="${INSTALL_DIR}/run"
COLLECTOR_SLOTS_DIR="${INSTALL_DIR}/collector-slots"

SYSTEMD_UNIT_DIR="/etc/systemd/system"
SERVICE_UNIT_PATH="${SYSTEMD_UNIT_DIR}/itgo-inventory.service"
TIMER_UNIT_PATH="${SYSTEMD_UNIT_DIR}/itgo-inventory.timer"

# Fresh installation and upgrade alike: the Python 3 runtime is ensured before
# anything is changed, so a failure leaves an existing installation, its
# configuration, schedule and reports exactly as they were.
if ! inventory_ensure_python3; then
  inv_error 'INVENTORY installation aborted: the inventory collector requires Python 3.6 or newer. Existing INVENTORY files, configuration, schedule and reports were not changed.'
  exit 1
fi

install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR" "$REPORTS_DIR" "$LOGS_DIR" "$RUN_DIR" "$COLLECTOR_SLOTS_DIR"
install -d -m 0700 "$CONFIG_DIR"

install -m 0755 "${SCRIPT_DIR}/collect_inventory.py" "${BIN_DIR}/collect_inventory.py"
install -m 0755 "${SCRIPT_DIR}/itgo-inv" "${BIN_DIR}/itgo-inv"
install -m 0644 "${SCRIPT_DIR}/inventory.version" "${INSTALL_DIR}/inventory.version"

chown -R "${TARGET_USER}:${TARGET_USER}" "$INSTALL_DIR"

chmod 0755 "$INSTALL_DIR" "$BIN_DIR" "$REPORTS_DIR" "$LOGS_DIR" "$RUN_DIR" "$COLLECTOR_SLOTS_DIR"
chmod 0700 "$CONFIG_DIR"
chmod 0755 "${BIN_DIR}/itgo-inv" "${BIN_DIR}/collect_inventory.py"
chmod 0644 "${INSTALL_DIR}/inventory.version"

# A production public key is deliberately not stored in this repository.  The
# trusted release installer may provision config/collector-update-public.pem;
# preserve it across upgrades.  Without that regular, local file itgo-inv
# keeps using the installed collector and never accepts network updates.
if [ -e "${CONFIG_DIR}/collector-update-public.pem" ] && { [ ! -f "${CONFIG_DIR}/collector-update-public.pem" ] || [ -L "${CONFIG_DIR}/collector-update-public.pem" ]; }; then
  inv_warn "collector update public key is not a regular file; automatic Collector updates remain disabled"
elif [ -f "${CONFIG_DIR}/collector-update-public.pem" ]; then
  chmod 0644 "${CONFIG_DIR}/collector-update-public.pem"
fi

ln -sfn "${BIN_DIR}/itgo-inv" /usr/local/bin/itgo-inv

# Writes stdin to a systemd unit file through a temp file and an atomic rename.
install_systemd_unit_file() {
  local dest="$1" tmp

  tmp="$(mktemp "${SYSTEMD_UNIT_DIR}/.itgo-inventory.XXXXXX")" || return 1
  if ! cat > "$tmp" || ! chmod 0644 "$tmp" || ! chown root:root "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# The timer is never enabled or started here; an existing enable state and the
# itgo-inventory.timer.d/schedule.conf drop-in are left untouched on upgrade.
install_systemd_units() {
  install_systemd_unit_file "$SERVICE_UNIT_PATH" <<EOF || return 1
[Unit]
Description=ITGO Service Toolkit inventory collection
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${TARGET_USER}
Group=${TARGET_USER}
UMask=0077
ExecStart=/usr/local/bin/itgo-inv collect
EOF

  install_systemd_unit_file "$TIMER_UNIT_PATH" <<'EOF' || return 1
[Unit]
Description=ITGO Service Toolkit periodic inventory collection

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=30m
Persistent=true
Unit=itgo-inventory.service

[Install]
WantedBy=timers.target
EOF
}

if command -v systemctl >/dev/null 2>&1 && [ -d "$SYSTEMD_UNIT_DIR" ]; then
  if install_systemd_units; then
    if [ -d /run/systemd/system ]; then
      systemctl daemon-reload || printf 'WARNING: systemctl daemon-reload failed; automatic inventory units may not be loaded yet.\n' >&2
    else
      printf 'WARNING: systemd is not running; skipped systemctl daemon-reload.\n' >&2
    fi
    printf 'Automatic inventory units installed: itgo-inventory.service, itgo-inventory.timer\n'
    printf 'The timer enable state was not changed; see itgo-inv schedule-status / itgo-inv schedule-enable.\n'
  else
    printf 'WARNING: could not install automatic inventory systemd units; manual itgo-inv collect still works.\n' >&2
  fi
else
  printf 'WARNING: systemd is unavailable; automatic inventory scheduling was not installed. Manual itgo-inv collect still works.\n' >&2
fi

if ! inventory_verify_collector "$INV_PYTHON" "${BIN_DIR}/collect_inventory.py"; then
  inv_error "the installed inventory collector does not start with ${INV_PYTHON} (Python ${INV_PYTHON_VERSION}); INVENTORY is not operational."
  exit 1
fi
printf 'Inventory collector verified with %s (Python %s)\n' "$INV_PYTHON" "$INV_PYTHON_VERSION"

"${BIN_DIR}/itgo-inv" version
