#!/usr/bin/env bash
# shellcheck shell=bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Caller <-> root helper contract version expected from "helper ping".  Must
# match HELPER_API_VERSION in p1cert_ezdrowie_helper.sh and EZ_HELPER_API in
# p1cert_ezdrowie.sh (this is not the P1CERT release version).
EZ_HELPER_API=2

# Test fixtures may mirror the system paths below a prefix and use their own
# uid/gid as "root"; always empty/0 when the installer is executed.
SYS_ROOT=""
INSTALL_TRUSTED_UID=0
INSTALL_TRUSTED_GID=0

# Logical system paths (written into sudoers/units as they are).
HELPER_PARENT_DIR="/usr/local/libexec"
HELPER_DIR="${HELPER_PARENT_DIR}/itgo-p1cert"
HELPER_PATH="${HELPER_DIR}/p1cert-ezdrowie-helper"
HELPER_LIB_PATH="${HELPER_DIR}/p1cert_ezdrowie_lib.sh"
SUDOERS_MAIN="/etc/sudoers"
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS_FILE="${SUDOERS_DIR}/itgo-p1cert-ezdrowie"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
EZ_SERVICE_PATH="${SYSTEMD_UNIT_DIR}/itgo-p1cert-ezdrowie.service"
P1CERT_LINK="/usr/local/bin/p1cert"

INTEGRATION_ISSUES=""

inst_fs() {
  printf '%s%s' "$SYS_ROOT" "$1"
}

inst_warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

inst_issue() {
  INTEGRATION_ISSUES="${INTEGRATION_ISSUES}  - $*
"
}

# Conservative user/group names: no whitespace, "=", "%", "\", control bytes
# or a leading "-" (they end up in sudoers and in a systemd unit).
inst_name_ok() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# inst_node_trusted <fs-path> <f|d> [required-gid]
# Regular file / directory (as requested), not a symlink, owned by root, not
# group/world writable, optionally group root.
inst_node_trusted() {
  local path="$1" kind="$2" want_gid="${3:-}" meta uid gid mode

  [ ! -L "$path" ] || return 1
  case "$kind" in
    f) [ -f "$path" ] ;;
    d) [ -d "$path" ] ;;
    *) false ;;
  esac || return 1
  meta="$(stat -c '%u %g %a' -- "$path" 2>/dev/null)" || return 1
  read -r uid gid mode <<EOF
$meta
EOF
  case "$uid:$gid:$mode" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  [ "$uid" = "$INSTALL_TRUSTED_UID" ] || return 1
  [ -z "$want_gid" ] || [ "$gid" = "$want_gid" ] || return 1
  [ $((8#$mode & 8#022)) -eq 0 ]
}

# All given logical directories must be trusted root directories.
inst_dirs_trusted() {
  local dir

  for dir in "$@"; do
    inst_node_trusted "$(inst_fs "$dir")" d || {
      inst_warn "$dir is not a root-owned directory without group/world write access (or is a symlink)"
      return 1
    }
  done
}

# An existing destination must be a trusted root regular file; a symlink,
# directory or anything else is never replaced or followed.
inst_dest_ok() {
  local fs

  fs="$(inst_fs "$1")"
  if [ -e "$fs" ] || [ -L "$fs" ]; then
    inst_node_trusted "$fs" f "${2:-}" || {
      inst_warn "existing $1 is not a root-owned regular file without group/world write access (symlink/directory?); not replaced"
      return 1
    }
  fi
}

# install_root_file <source-file> <logical-destination> <mode> [required-gid]
# Temporary file in the destination directory, root:root, mode, then an
# atomic "mv -f -T" (never into a directory, never through a symlink).  The
# caller has verified the destination directory.
install_root_file() {
  local source="$1" destination="$2" mode="$3" gid="${4:-}" fs tmp

  inst_dest_ok "$destination" "$gid" || return 1
  fs="$(inst_fs "$destination")"
  tmp="$(mktemp "${fs%/*}/.p1cert-install.XXXXXX")" || return 1
  if ! cat -- "$source" > "$tmp" || ! chown root:root "$tmp" || ! chmod "$mode" "$tmp" ||
     ! mv -f -T -- "$tmp" "$fs"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- user part (unchanged behaviour of the P1CERT installation) -------------

installer_validate_user() {
  case "$TARGET_USER" in
    ''|-*|*[!A-Za-z0-9._-]*)
      printf 'error: invalid target user name: %s\n' "$TARGET_USER" >&2
      return 1
      ;;
  esac
  if command -v getent >/dev/null 2>&1 && getent passwd "$TARGET_USER" >/dev/null 2>&1; then
    ITGO_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
  else
    ITGO_HOME="/home/${TARGET_USER}"
  fi
  if [ -z "$ITGO_HOME" ]; then
    printf 'error: could not determine home directory for user %s\n' "$TARGET_USER" >&2
    return 1
  fi
}

installer_paths() {
  INSTALL_DIR="${ITGO_HOME}/UTILITY/P1CERT"
  BIN_DIR="${INSTALL_DIR}/bin"
  LOGS_DIR="${INSTALL_DIR}/logs"
  STATE_DIR="${INSTALL_DIR}/state"
  CERTS_DIR="${INSTALL_DIR}/certs"
  # ezdrowie: operator data (credentials, plan, backups) is preserved on
  # upgrade and never changed recursively.
  CONFIG_DIR="${INSTALL_DIR}/config"
  BACKUPS_DIR="${INSTALL_DIR}/backups"
  EZ_BACKUPS_DIR="${BACKUPS_DIR}/ezdrowie"
}

installer_user_install() {
  local dir link

  for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$BACKUPS_DIR" "$EZ_BACKUPS_DIR"; do
    if [ -L "$dir" ]; then
      printf 'error: refusing to install into a symlinked directory: %s\n' "$dir" >&2
      return 1
    fi
  done

  install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR" "$LOGS_DIR" "$STATE_DIR" "$CERTS_DIR" || return 1
  install -d -m 0700 "$CONFIG_DIR" "$BACKUPS_DIR" "$EZ_BACKUPS_DIR" || return 1
  install -m 0755 "${SCRIPT_DIR}/p1cert" "${BIN_DIR}/p1cert" || return 1
  install -m 0755 "${SCRIPT_DIR}/p1cert_audit.sh" "${BIN_DIR}/p1cert_audit.sh" || return 1
  install -m 0755 "${SCRIPT_DIR}/p1cert_update.sh" "${BIN_DIR}/p1cert_update.sh" || return 1
  install -m 0755 "${SCRIPT_DIR}/p1cert_ezdrowie.sh" "${BIN_DIR}/p1cert_ezdrowie.sh" || return 1
  install -m 0644 "${SCRIPT_DIR}/p1cert_ezdrowie_lib.sh" "${BIN_DIR}/p1cert_ezdrowie_lib.sh" || return 1
  install -m 0644 "${SCRIPT_DIR}/p1cert.version" "${INSTALL_DIR}/p1cert.version" || return 1
  if [ -f "${SCRIPT_DIR}/certs/p1-production-certs.zip" ]; then
    install -m 0644 "${SCRIPT_DIR}/certs/p1-production-certs.zip" "${CERTS_DIR}/p1-production-certs.zip" || return 1
  fi

  TARGET_GROUP=""
  if id "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_GROUP="$(id -gn "$TARGET_USER")" || return 1
    # -P (default for -R) never follows symlinks.  config/ and backups/ hold
    # operator data and are not changed recursively; nothing outside
    # INSTALL_DIR (helper, sudoers, units) is affected.
    chown -h "${TARGET_USER}:${TARGET_GROUP}" "$INSTALL_DIR" "$CONFIG_DIR" "$BACKUPS_DIR" "$EZ_BACKUPS_DIR" "${INSTALL_DIR}/p1cert.version" || return 1
    chown -R -P "${TARGET_USER}:${TARGET_GROUP}" "$BIN_DIR" "$LOGS_DIR" "$STATE_DIR" "$CERTS_DIR" || return 1
  fi

  chmod 0755 "$INSTALL_DIR" "$BIN_DIR" "$LOGS_DIR" "$STATE_DIR" "$CERTS_DIR" "${BIN_DIR}/p1cert" "${BIN_DIR}/p1cert_audit.sh" "${BIN_DIR}/p1cert_update.sh" "${BIN_DIR}/p1cert_ezdrowie.sh" || return 1
  chmod 0700 "$CONFIG_DIR" "$BACKUPS_DIR" "$EZ_BACKUPS_DIR" || return 1
  chmod 0644 "${INSTALL_DIR}/p1cert.version" "${BIN_DIR}/p1cert_ezdrowie_lib.sh" || return 1

  # -T: the link name is never treated as a directory (GNU ln -n alone would
  # still create the link inside a real directory of that name).
  link="$(inst_fs "$P1CERT_LINK")"
  if [ -d "$link" ] && [ ! -L "$link" ]; then
    inst_warn "$P1CERT_LINK is a directory; the p1cert command link was not created"
  else
    ln -sfnT "${BIN_DIR}/p1cert" "$link" || return 1
  fi
}

# --- ezdrowie system integration --------------------------------------------

install_ezdrowie_helper() {
  local dir

  # The helper refuses to run (fail closed) unless every parent directory is
  # root-owned and not writable by group/others; do not install it otherwise.
  inst_dirs_trusted / /usr /usr/local || return 1
  for dir in "$HELPER_PARENT_DIR" "$HELPER_DIR"; do
    if [ -L "$(inst_fs "$dir")" ]; then
      inst_warn "$dir is a symlink; ezdrowie helper not installed"
      return 1
    fi
    if [ ! -d "$(inst_fs "$dir")" ]; then
      install -d -m 0755 -o root -g root "$(inst_fs "$dir")" || return 1
    fi
  done
  inst_dirs_trusted "$HELPER_PARENT_DIR" || return 1
  chown root:root "$(inst_fs "$HELPER_DIR")" && chmod 0755 "$(inst_fs "$HELPER_DIR")" || return 1
  inst_dirs_trusted "$HELPER_DIR" || return 1
  # Library first: an interrupted upgrade leaves an old helper with a new
  # library, which the helper itself refuses (library API check).
  install_root_file "${SCRIPT_DIR}/p1cert_ezdrowie_lib.sh" "$HELPER_LIB_PATH" 0644 || return 1
  install_root_file "${SCRIPT_DIR}/p1cert_ezdrowie_helper.sh" "$HELPER_PATH" 0755 || return 1
}

# True when helper "ping" output reports exactly the expected API version.
inst_ping_api_ok() {
  local out="$1" ok="" api="" line

  while IFS= read -r line; do
    case "$line" in
      HELPER=OK) ok=yes ;;
      API_VERSION=*) [ -z "$api" ] || return 1; api="${line#API_VERSION=}" ;;
    esac
  done <<EOF
$out
EOF
  [ "$ok" = yes ] && [ "$api" = "$EZ_HELPER_API" ]
}

# The installed helper, run as root (it performs its own integrity checks).
inst_helper_ping() {
  "$(inst_fs "$HELPER_PATH")" ping 2>/dev/null
}

inst_helper_compatible() {
  local out

  out="$(inst_helper_ping)" || return 1
  inst_ping_api_ok "$out"
}

# Only the helper is allowed, without a password, for the P1CERT user.  The
# helper validates every operation and argument itself.
install_ezdrowie_sudoers() {
  local fs tmp prev="" restored=yes

  command -v visudo >/dev/null 2>&1 || {
    inst_warn 'visudo is unavailable; ezdrowie sudoers entry not installed'
    return 1
  }
  inst_dirs_trusted /etc "$SUDOERS_DIR" || {
    inst_warn "ezdrowie sudoers entry not installed"
    return 1
  }
  inst_dest_ok "$SUDOERS_FILE" || return 1
  fs="$(inst_fs "$SUDOERS_FILE")"
  # Names containing "." are ignored by #includedir: temporary files and the
  # saved previous fragment are never active.
  if [ -f "$fs" ]; then
    prev="$(mktemp "$(inst_fs "$SUDOERS_DIR")/.itgo-p1cert-ezdrowie.prev.XXXXXX")" || return 1
    if ! cat -- "$fs" > "$prev" || ! chown root:root "$prev" || ! chmod 0440 "$prev"; then
      rm -f -- "$prev"
      return 1
    fi
  fi
  tmp="$(mktemp "$(inst_fs "$SUDOERS_DIR")/.itgo-p1cert-ezdrowie.XXXXXX")" || { [ -z "$prev" ] || rm -f -- "$prev"; return 1; }
  if ! {
    printf '# Managed by the P1CERT installer (p1cert ezdrowie). Do not edit.\n'
    printf 'Cmnd_Alias P1CERT_EZDROWIE_HELPER = %s\n' "$HELPER_PATH"
    printf 'Defaults!P1CERT_EZDROWIE_HELPER !requiretty\n'
    printf '%s ALL=(root) NOPASSWD: P1CERT_EZDROWIE_HELPER\n' "$TARGET_USER"
  } > "$tmp" || ! chown root:root "$tmp" || ! chmod 0440 "$tmp"; then
    rm -f -- "$tmp"
    [ -z "$prev" ] || rm -f -- "$prev"
    return 1
  fi
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    [ -z "$prev" ] || rm -f -- "$prev"
    inst_warn 'generated sudoers entry failed visudo validation; not installed'
    return 1
  fi
  if ! mv -f -T -- "$tmp" "$fs"; then
    rm -f -- "$tmp"
    [ -z "$prev" ] || rm -f -- "$prev"
    return 1
  fi
  # The complete configuration must still be valid; otherwise put the
  # previous state back (previous fragment, or no fragment).
  if [ -f "$(inst_fs "$SUDOERS_MAIN")" ]; then
    if ! visudo -cf "$(inst_fs "$SUDOERS_MAIN")" >/dev/null 2>&1; then
      inst_warn "the complete sudoers configuration is invalid with the new fragment; reverting $SUDOERS_FILE"
      if [ -n "$prev" ]; then
        mv -f -T -- "$prev" "$fs" || restored=no
        prev=""
      else
        rm -f -- "$fs" || restored=no
      fi
      if [ "$restored" = yes ] && visudo -cf "$(inst_fs "$SUDOERS_MAIN")" >/dev/null 2>&1; then
        inst_warn 'previous sudoers state restored and valid'
      else
        inst_warn "CHECK SUDOERS MANUALLY: visudo -c still fails after reverting $SUDOERS_FILE"
      fi
      return 1
    fi
  else
    inst_warn "$SUDOERS_MAIN not found; only the fragment itself was validated"
  fi
  [ -z "$prev" ] || rm -f -- "$prev"
}

# Verifies that TARGET_USER can really run the helper with "sudo -n".
# Returns 0 verified, 1 refused, 2 could not be verified from here (e.g. the
# outer "sudo -u" is blocked by requiretty).  No shell, no string commands.
inst_verify_sudo() {
  local out

  command -v sudo >/dev/null 2>&1 || return 2
  if out="$(sudo -n -u "$TARGET_USER" -- sudo -n -- "$HELPER_PATH" ping 2>/dev/null)"; then
    inst_ping_api_ok "$out" && return 0
    return 1
  fi
  # Can root switch to the user at all?  If not, the result says nothing.
  sudo -n -u "$TARGET_USER" -- true >/dev/null 2>&1 || return 2
  return 1
}

install_ezdrowie_service() {
  local tmp fs

  case "$BIN_DIR" in
    /*) ;;
    *) inst_warn "unsupported $BIN_DIR; ezdrowie service not installed"; return 1 ;;
  esac
  case "$BIN_DIR" in
    *[!A-Za-z0-9._/-]*)
      inst_warn "unsupported characters in $BIN_DIR; ezdrowie service not installed"
      return 1
      ;;
  esac
  inst_name_ok "$TARGET_USER" && inst_name_ok "$TARGET_GROUP" || {
    inst_warn "unsupported user/group name; ezdrowie service not installed"
    return 1
  }
  inst_dirs_trusted /etc /etc/systemd "$SYSTEMD_UNIT_DIR" || {
    inst_warn 'ezdrowie service not installed'
    return 1
  }
  inst_dest_ok "$EZ_SERVICE_PATH" "$INSTALL_TRUSTED_GID" || return 1
  fs="$(inst_fs "$EZ_SERVICE_PATH")"
  tmp="$(mktemp "$(inst_fs "$SYSTEMD_UNIT_DIR")/.itgo-p1cert-ezdrowie.XXXXXX")" || return 1
  # No NoNewPrivileges: the service must be able to "sudo -n" the helper.
  # Persistent=false belongs to the timer, which only the helper creates.
  if ! cat > "$tmp" <<EOF || ! chown root:root "$tmp" || ! chmod 0644 "$tmp" || ! mv -f -T -- "$tmp" "$fs"; then
[Unit]
Description=ITGO P1CERT ezdrowie one-shot run of the accepted plan
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${TARGET_USER}
Group=${TARGET_GROUP}
UMask=0077
TimeoutStartSec=30min
ExecStart=${BIN_DIR}/p1cert ezdrowie run --scheduled
EOF
    rm -f -- "$tmp"
    return 1
  fi
}

inst_systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [ -d "$(inst_fs "$SYSTEMD_UNIT_DIR")" ]
}

inst_systemd_running() {
  [ -d "$(inst_fs /run/systemd/system)" ]
}

# Installs helper, sudoers entry and service.  Existing operator data and an
# armed timer are never touched.  Prints READY or INCOMPLETE.
installer_system_integration() {
  local helper_ok=no rc

  INTEGRATION_ISSUES=""
  if [ "$(id -u)" -ne 0 ]; then
    inst_issue 'the installer did not run as root'
  elif [ -z "${TARGET_GROUP:-}" ]; then
    inst_issue "user $TARGET_USER does not exist"
  elif ! inst_name_ok "$TARGET_GROUP"; then
    inst_warn "unsupported primary group name of $TARGET_USER; ezdrowie system components not installed"
    inst_issue "unsupported primary group name of $TARGET_USER"
  else
    if install_ezdrowie_helper; then
      printf 'ezdrowie helper installed: %s\n' "$HELPER_PATH"
    else
      inst_issue "helper not installed (an older helper may still be present)"
    fi
    if inst_helper_compatible; then
      helper_ok=yes
    else
      inst_issue "installed helper does not answer ping with API_VERSION=$EZ_HELPER_API"
    fi
    if [ "$helper_ok" = yes ]; then
      if install_ezdrowie_sudoers; then
        printf 'ezdrowie sudoers entry installed: %s\n' "$SUDOERS_FILE"
      else
        inst_issue "sudoers entry $SUDOERS_FILE not installed or reverted"
      fi
      inst_verify_sudo
      rc=$?
      case "$rc" in
        0) printf 'ezdrowie sudo access verified for %s\n' "$TARGET_USER" ;;
        1) inst_issue "$TARGET_USER cannot run the helper with sudo -n" ;;
        *)
          inst_warn "passwordless sudo of $TARGET_USER could not be verified from the installer; check: sudo -u $TARGET_USER sudo -n $HELPER_PATH ping"
          inst_issue "sudo access of $TARGET_USER not verified"
          ;;
      esac
    else
      inst_issue 'sudoers entry not changed because the helper is not usable'
    fi
    if inst_systemd_available; then
      if install_ezdrowie_service; then
        printf 'ezdrowie service installed: %s (the one-shot timer state was not changed)\n' "$EZ_SERVICE_PATH"
        if inst_systemd_running && ! systemctl daemon-reload; then
          inst_warn 'systemctl daemon-reload failed'
          inst_issue 'systemctl daemon-reload failed'
        fi
      else
        inst_issue "$EZ_SERVICE_PATH not installed"
      fi
    else
      inst_warn 'systemd is unavailable; p1cert ezdrowie schedule will be unavailable'
    fi
  fi

  if [ -z "$INTEGRATION_ISSUES" ]; then
    printf 'P1CERT ezdrowie system integration: READY\n'
    return 0
  fi
  printf 'P1CERT ezdrowie system integration: INCOMPLETE\n'
  printf '%s' "$INTEGRATION_ISSUES"
  printf '  p1cert ezdrowie credentials/test/scan/plan remain usable; run/schedule need a compatible helper and sudoers entry.\n'
  return 1
}

# --- uninstall --------------------------------------------------------------

# inst_remove_managed <logical-path> <label> <marker>...
# Removes a system file only when it is a root-owned regular file (not a
# symlink, directory or writable file) that contains every marker of the
# P1CERT-generated artifact.  Anything else is left in place and reported.
# An absent file is fine.
inst_remove_managed() {
  local path="$1" label="$2" fs marker

  shift 2
  fs="$(inst_fs "$path")"
  if [ ! -e "$fs" ] && [ ! -L "$fs" ]; then
    return 0
  fi
  if ! inst_node_trusted "$fs" f; then
    inst_warn "$path is not a root-owned regular file without group/world write access (symlink/directory?); left in place"
    inst_issue "$label left in place: $path"
    return 1
  fi
  for marker in "$@"; do
    if ! grep -F -q -- "$marker" "$fs"; then
      inst_warn "$path does not look like the P1CERT-managed $label (administrator content?); left in place"
      inst_issue "$label left in place (not P1CERT-managed): $path"
      return 1
    fi
  done
  if ! rm -f -- "$fs"; then
    inst_issue "$label could not be removed: $path"
    return 1
  fi
  printf 'removed: %s\n' "$path"
}

# Full uninstall of P1CERT for TARGET_USER: system integration first (timer,
# service, sudoers, helper), then the command link and the P1CERT directory
# (including credentials, plan, backups and logs, as before).
installer_uninstall() {
  local state link helper_dir

  INTEGRATION_ISSUES=""
  if [ "$(id -u)" -ne 0 ]; then
    printf 'error: P1CERT uninstall requires root\n' >&2
    return 1
  fi

  # 1. Never interrupt a scheduled run that is replacing a certificate.
  if inst_systemd_available; then
    state="$(systemctl is-active itgo-p1cert-ezdrowie.service 2>/dev/null)" || true
    case "$state" in
      active|activating|deactivating|reloading)
        printf 'error: itgo-p1cert-ezdrowie.service is running (%s); nothing removed, retry after it has finished\n' "$state" >&2
        return 1
        ;;
    esac
    # A missing timer is the normal state.
    systemctl disable --now itgo-p1cert-ezdrowie.timer >/dev/null 2>&1 || true
  fi

  # 2.-3. Managed units.
  inst_remove_managed "$SYSTEMD_UNIT_DIR/itgo-p1cert-ezdrowie.timer" 'timer unit' \
    'Description=ITGO P1CERT ezdrowie one-shot run of the accepted plan' 'Unit=itgo-p1cert-ezdrowie.service' || true
  inst_remove_managed "$EZ_SERVICE_PATH" 'service unit' \
    'Description=ITGO P1CERT ezdrowie one-shot run of the accepted plan' 'ezdrowie run --scheduled' || true

  # 4. daemon-reload.
  if inst_systemd_available && inst_systemd_running; then
    if ! systemctl daemon-reload; then
      inst_warn 'systemctl daemon-reload failed'
      inst_issue 'systemctl daemon-reload failed'
    fi
  fi

  # 5. sudoers fragment, then the complete configuration.
  if inst_remove_managed "$SUDOERS_FILE" 'sudoers fragment' \
    '# Managed by the P1CERT installer (p1cert ezdrowie). Do not edit.' 'Cmnd_Alias P1CERT_EZDROWIE_HELPER'; then
    if [ -f "$(inst_fs "$SUDOERS_MAIN")" ] && command -v visudo >/dev/null 2>&1 &&
       ! visudo -cf "$(inst_fs "$SUDOERS_MAIN")" >/dev/null 2>&1; then
      printf 'ERROR: visudo -c reports an invalid sudoers configuration after removing %s\n' "$SUDOERS_FILE" >&2
      inst_issue 'sudoers configuration invalid after removal (check with visudo -c)'
    fi
  fi

  # 6. Helper and its library; the directory only when it is empty.
  helper_dir="$(inst_fs "$HELPER_DIR")"
  if [ -e "$helper_dir" ] || [ -L "$helper_dir" ]; then
    if inst_node_trusted "$helper_dir" d; then
      inst_remove_managed "$HELPER_PATH" 'root helper' '# P1CERT ezdrowie privileged helper.' 'HELPER_API_VERSION=' || true
      inst_remove_managed "$HELPER_LIB_PATH" 'root helper library' \
        '# Shared, side-effect free helpers for the P1CERT ezdrowie namespace.' 'EZ_LIB_API=' || true
      if rmdir -- "$helper_dir" 2>/dev/null; then
        printf 'removed: %s\n' "$HELPER_DIR"
      elif [ -d "$helper_dir" ]; then
        inst_warn "$HELPER_DIR is not empty; left in place"
      fi
    else
      inst_warn "$HELPER_DIR is not a root-owned directory (symlink?); left in place"
      inst_issue "helper directory left in place: $HELPER_DIR"
    fi
  fi

  # 7. The p1cert command link, only when it is our link.
  link="$(inst_fs "$P1CERT_LINK")"
  if [ -L "$link" ]; then
    if [ "$(readlink -- "$link")" = "${BIN_DIR}/p1cert" ]; then
      rm -f -- "$link" && printf 'removed: %s\n' "$P1CERT_LINK"
    else
      inst_warn "$P1CERT_LINK points elsewhere; left in place"
    fi
  elif [ -e "$link" ]; then
    inst_warn "$P1CERT_LINK is not a symlink; left in place"
  fi

  # 8. The P1CERT directory (full uninstall semantics: operator data too).
  case "$ITGO_HOME:$INSTALL_DIR" in
    /?*:"$ITGO_HOME/UTILITY/P1CERT") ;;
    *) inst_issue "unexpected P1CERT directory: $INSTALL_DIR"; INSTALL_DIR="" ;;
  esac
  if [ -n "$INSTALL_DIR" ]; then
    if [ -L "$ITGO_HOME/UTILITY" ] || [ -L "$INSTALL_DIR" ]; then
      inst_warn "$INSTALL_DIR or its parent is a symlink; left in place"
      inst_issue "P1CERT directory left in place: $INSTALL_DIR"
    elif [ -e "$INSTALL_DIR" ]; then
      if rm -rf -- "$INSTALL_DIR"; then
        printf 'removed: %s\n' "$INSTALL_DIR"
      else
        inst_issue "P1CERT directory could not be removed completely: $INSTALL_DIR"
      fi
    fi
  fi

  if [ -z "$INTEGRATION_ISSUES" ]; then
    printf 'P1CERT uninstall: DONE\n'
    return 0
  fi
  printf 'P1CERT uninstall: INCOMPLETE - left in place:\n'
  printf '%s' "$INTEGRATION_ISSUES"
  return 1
}

installer_usage() {
  printf 'usage: %s [TARGET_USER]\n       %s --uninstall [TARGET_USER]\n' "${0##*/}" "${0##*/}" >&2
}

installer_main() {
  local action=install

  set -eu
  case "${1:-}" in
    --uninstall) action=uninstall; shift ;;
    -*) installer_usage; return 2 ;;
  esac
  [ "$#" -le 1 ] || { installer_usage; return 2; }
  TARGET_USER="${1:-${SUDO_USER:-itgo}}"
  installer_validate_user
  installer_paths
  if [ "$action" = uninstall ]; then
    installer_uninstall
    return
  fi
  installer_user_install
  # An incomplete ezdrowie integration does not fail the P1CERT installation
  # (P1 CA commands do not need it); the status line says what is missing.
  installer_system_integration || true
  "${BIN_DIR}/p1cert" version
}

if [ "${P1CERT_INSTALLER_LIB_ONLY:-0}" != 1 ]; then
  installer_main "$@"
  exit $?
fi
