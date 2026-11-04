#!/usr/bin/env bash
# shellcheck shell=bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Caller <-> root helper contract version expected from "helper ping".  Must
# match HELPER_API_VERSION in p1cert_ezdrowie_helper.sh and EZ_HELPER_API in
# p1cert_ezdrowie.sh (this is not the P1CERT release version).  3 since the
# target directory policy (ez_target_dir_ok); 4 since the classic Integration
# Platform SSL.patch binding; 5 since Docker Compose applications
# (apply-docker, recover); 6 since several P1 entries per keystore and the
# Tomcat instance binding; helpers of API 1-5 are incompatible.
EZ_HELPER_API=6
# PKCS12 tool of the helper (built by java/build.sh): installed only with
# exactly these bytes; the helper checks the same SHA-256 before each use.
EZ_P12_JAR_SHA256=385c8d32d494ac07bcfe536c41c19255deac32b212ba327e27618a76e2fc4e95

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
HELPER_P12_JAR_PATH="${HELPER_DIR}/p1cert-pkcs12.jar"
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
  install_ezdrowie_p12_tool
}

# PKCS12 tool for Docker applications: installed root-owned next to the
# helper only when its SHA-256 is exactly EZ_P12_JAR_SHA256.  Without it (or
# without a Java 8+ runtime, see installer_java) the helper refuses
# applications with PKCS12 keystores; everything else works.  A missing or
# damaged tool is reported as an integration issue.
install_ezdrowie_p12_tool() {
  local source="${SCRIPT_DIR}/p1cert-pkcs12.jar" digest

  if [ ! -f "$source" ] || [ -L "$source" ]; then
    inst_warn 'p1cert-pkcs12.jar missing from the package; PKCS12 keystores in Docker applications will not be updated'
    inst_issue 'PKCS12 tool: p1cert-pkcs12.jar missing from the package (incomplete payload)'
    return 0
  fi
  digest="$(openssl dgst -sha256 < "$source" 2>/dev/null | awk '{ print $NF }')"
  if [ "$digest" != "$EZ_P12_JAR_SHA256" ]; then
    inst_warn "p1cert-pkcs12.jar has an unexpected SHA-256 ($digest); not installed"
    inst_issue 'PKCS12 tool: p1cert-pkcs12.jar failed its integrity check and was not installed'
    return 0
  fi
  install_root_file "$source" "$HELPER_P12_JAR_PATH" 0644 || {
    inst_issue "PKCS12 tool: p1cert-pkcs12.jar could not be installed: $HELPER_P12_JAR_PATH"
    return 0
  }
}

# --- Java runtime and required tools -----------------------------------------

# Java locations the helper accepts (helper_java_find): root-controlled only.
INST_JAVA_CANDIDATES='/usr/bin/java
/usr/lib/jvm/*/bin/java
/usr/lib/jvm/*/jre/bin/java
/usr/java/*/bin/java'
INST_JAVA=""
INST_JAVA_MAJOR=""

# Major version of a Java runtime ("8" for 1.8.x); fails when it does not run.
inst_java_major() {
  local v

  v="$(env -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS "$1" -version 2>&1 |
    awk -F'"' '/ version "/ { print $2; exit }')"
  case "$v" in
    1.*) v="${v#1.}" ;;
  esac
  v="${v%%[!0-9]*}"
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$v"
}

# Every component of a resolved (logical) path is root-owned and not
# group/world writable, as helper_path_trusted requires.
inst_path_trusted() {
  local rest="${1#/}" current="" part

  inst_node_trusted "$(inst_fs /)" d || return 1
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    current="$current/$part"
    if [ -n "$rest" ]; then
      inst_node_trusted "$(inst_fs "$current")" d || return 1
    else
      inst_node_trusted "$(inst_fs "$current")" f || return 1
    fi
  done
}

# The Java 8+ runtime the helper will use (same locations and trust rule as
# helper_java_find): INST_JAVA / INST_JAVA_MAJOR.  INST_JAVA_SEEN lists every
# Java found, also unusable ones ("<path> (<why>)").
inst_java_find() {
  local fs real major

  INST_JAVA=""; INST_JAVA_MAJOR=""; INST_JAVA_SEEN=""
  for fs in $(inst_java_globs); do
    [ -e "$fs" ] || continue
    real="$(readlink -f -- "$fs" 2>/dev/null)" || continue
    real="${real#"$SYS_ROOT"}"
    if ! major="$(inst_java_major "$(inst_fs "$real")")"; then
      INST_JAVA_SEEN="${INST_JAVA_SEEN:+$INST_JAVA_SEEN, }$real (does not run)"
      continue
    fi
    if [ "$major" -lt 8 ]; then
      INST_JAVA_SEEN="${INST_JAVA_SEEN:+$INST_JAVA_SEEN, }$real (Java $major)"
      continue
    fi
    if ! inst_path_trusted "$real"; then
      INST_JAVA_SEEN="${INST_JAVA_SEEN:+$INST_JAVA_SEEN, }$real (Java $major, path not controlled by root only)"
      continue
    fi
    INST_JAVA="$real"; INST_JAVA_MAJOR="$major"
    return 0
  done
  return 1
}

# Any Java at all on the system: one of the helper locations exists or a
# "java" is in PATH.  Such a runtime belongs to the operator or a vendor and is
# never updated, replaced or switched (no alternatives) by P1CERT.
inst_java_present() {
  local fs

  for fs in $(inst_java_globs); do
    if [ -e "$fs" ] || [ -L "$fs" ]; then
      return 0
    fi
  done
  command -v java >/dev/null 2>&1
}

# The candidate locations below SYS_ROOT, glob patterns expanded there (one
# per line; an unmatched pattern stays as it is and does not exist).
inst_java_globs() {
  local pat

  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2086 # the glob is expanded on purpose
    printf '%s
' $(inst_fs "$pat")
  done <<EOF
$INST_JAVA_CANDIDATES
EOF
}

# Supported distribution family from /etc/os-release: debian or rhel.
inst_os_family() {
  local ids

  ids="$(
    # shellcheck disable=SC1090
    [ -r "$(inst_fs /etc/os-release)" ] && . "$(inst_fs /etc/os-release)" 2>/dev/null
    printf ' %s %s ' "${ID:-}" "${ID_LIKE:-}"
  )"
  ids="$(printf '%s' "$ids" | tr 'A-Z' 'a-z')"
  case "$ids" in
    *' rhel '*|*' fedora '*|*' centos '*|*' rocky '*|*' almalinux '*|*' ol '*|*' oracle '*) printf 'rhel' ;;
    *' debian '*|*' ubuntu '*) printf 'debian' ;;
    *) return 1 ;;
  esac
}

# Package candidates of a headless Java runtime, newest first (the first one
# the repositories know is installed).
inst_java_packages() {
  case "$1" in
    debian) printf '%s\n' default-jre-headless openjdk-21-jre-headless openjdk-17-jre-headless openjdk-11-jre-headless openjdk-8-jre-headless ;;
    rhel) printf '%s\n' java-21-openjdk-headless java-17-openjdk-headless java-11-openjdk-headless java-1.8.0-openjdk-headless ;;
  esac
}

# inst_pkg_install <family> <package>: one non-interactive installation.
inst_pkg_install() {
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

INST_APT_UPDATED=no

# Refreshes the apt package lists once per installer run (Debian/Ubuntu).
inst_apt_update() {
  [ "$INST_APT_UPDATED" = no ] || return 0
  INST_APT_UPDATED=yes
  command -v apt-get >/dev/null 2>&1 || return 0
  apt-get update >/dev/null 2>&1 || inst_warn 'apt-get update failed; using the cached package lists'
}

# Java 8+ for the PKCS12 tool of the helper.  A usable runtime is kept as it
# is; an existing but unusable one (too old, outside root-controlled
# locations, broken) is reported and never changed; only a system without
# any Java gets the distribution's headless OpenJDK package.
# P1CERT_JAVA_INSTALL=no skips the installation (only the check is done).
installer_java() {
  local family pkg

  if inst_java_find; then
    printf 'Java runtime for the PKCS12 tool: %s (Java %s)\n' "$INST_JAVA" "$INST_JAVA_MAJOR"
    return 0
  fi
  if inst_java_present; then
    inst_warn "an existing Java runtime cannot be used by the helper: ${INST_JAVA_SEEN:-$(command -v java 2>/dev/null)}; it is not changed by P1CERT"
    inst_issue "Java: no usable Java 8+ in a root-controlled location (${INST_JAVA_SEEN:-java in PATH only: $(command -v java 2>/dev/null)}); existing Java left unchanged - install Java 8+ below /usr/lib/jvm or /usr/java manually; PKCS12 keystores are not updated until then"
    return 1
  fi
  if [ "${P1CERT_JAVA_INSTALL:-yes}" = no ]; then
    inst_issue 'Java: no Java runtime; installation skipped (P1CERT_JAVA_INSTALL=no); PKCS12 keystores are not updated'
    return 1
  fi
  if ! family="$(inst_os_family)"; then
    inst_issue 'Java: no Java runtime and unsupported distribution (Debian/Ubuntu or RHEL/Oracle Linux family required); install Java 8+ manually'
    return 1
  fi
  [ "$family" != debian ] || inst_apt_update
  for pkg in $(inst_java_packages "$family"); do
    printf 'Java runtime missing: installing %s\n' "$pkg"
    if inst_pkg_install "$family" "$pkg"; then
      if inst_java_find; then
        printf 'Java runtime installed: %s (Java %s, package %s)\n' "$INST_JAVA" "$INST_JAVA_MAJOR" "$pkg"
        return 0
      fi
      inst_issue "Java: package $pkg installed, but no usable Java 8+ was found afterwards (${INST_JAVA_SEEN:-nothing})"
      return 1
    fi
  done
  inst_issue "Java: none of the packages could be installed ($(inst_java_packages "$family" | tr '\n' ' ')); check the package repositories"
  return 1
}

# Commands the ezdrowie integration needs: "<command> <debian-package>
# <rhel-package>".  flock comes from util-linux, iconv from the C library.
INST_TOOLS='openssl openssl openssl
curl curl curl
unzip unzip unzip
sudo sudo sudo
visudo sudo sudo
flock util-linux util-linux
iconv libc-bin glibc-common
od coreutils coreutils
stat coreutils coreutils
awk gawk gawk
sed sed sed
grep grep grep
find findutils findutils
dd coreutils coreutils'

# Missing required commands are installed from the distribution packages;
# what is still missing afterwards is an integration issue.
installer_tools() {
  local cmd deb rpm family="" missing="" pkgs="" pkg

  while read -r cmd deb rpm; do
    [ -n "$cmd" ] || continue
    command -v "$cmd" >/dev/null 2>&1 && continue
    missing="${missing:+$missing }$cmd"
    family="${family:-$(inst_os_family || true)}"
    case "$family" in
      debian) pkg="$deb" ;;
      rhel) pkg="$rpm" ;;
      *) pkg="" ;;
    esac
    case " $pkgs " in
      *" $pkg "*) ;;
      *) [ -z "$pkg" ] || pkgs="${pkgs:+$pkgs }$pkg" ;;
    esac
  done <<EOF
$INST_TOOLS
EOF
  [ -n "$missing" ] || return 0
  printf 'missing commands: %s\n' "$missing"
  if [ -n "$pkgs" ]; then
    [ "$family" != debian ] || inst_apt_update
    for pkg in $pkgs; do
      printf 'installing package %s\n' "$pkg"
      inst_pkg_install "$family" "$pkg" || inst_warn "package $pkg could not be installed"
    done
  fi
  for cmd in $missing; do
    command -v "$cmd" >/dev/null 2>&1 || inst_issue "required command missing: $cmd"
  done
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

# The installed helper, run as root (it performs its own integrity checks);
# its diagnostics are part of the output.
inst_helper_ping() {
  "$(inst_fs "$HELPER_PATH")" ping 2>&1
}

# The installed helper answers ping with exactly EZ_HELPER_API.  On failure
# INST_HELPER_PROBLEM says why: missing, wrong owner/mode, refused to start
# (its own integrity check) or another API.  INST_PING keeps the answer.
inst_helper_compatible() {
  local fs api

  INST_HELPER_PROBLEM=""; INST_PING=""
  fs="$(inst_fs "$HELPER_PATH")"
  if [ ! -e "$fs" ] && [ ! -L "$fs" ]; then
    INST_HELPER_PROBLEM="helper missing: $HELPER_PATH"
    return 1
  fi
  if ! inst_node_trusted "$fs" f || [ ! -x "$fs" ]; then
    INST_HELPER_PROBLEM="helper has a wrong owner or mode (must be a root-owned 0755 regular file, not a symlink): $HELPER_PATH ($(stat -c '%U:%G %a %F' -- "$fs" 2>/dev/null))"
    return 1
  fi
  if ! INST_PING="$(inst_helper_ping)"; then
    INST_HELPER_PROBLEM="helper refused to start: $(printf '%s\n' "$INST_PING" | grep -m 1 . || printf 'no message')"
    return 1
  fi
  if ! inst_ping_api_ok "$INST_PING"; then
    api="$(printf '%s\n' "$INST_PING" | sed -n 's/^API_VERSION=//p' | head -n 1)"
    INST_HELPER_PROBLEM="installed helper does not answer ping with API_VERSION=$EZ_HELPER_API (reported: ${api:-none})"
    return 1
  fi
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
# Returns 0 verified, 1 refused by sudo, 2 could not be verified from here
# (e.g. the outer "sudo -u" is blocked by requiretty), 3 sudo missing, 4 the
# helper answers through sudo with another API.  INST_SUDO_DETAIL: the first
# message line.  No shell, no string commands.
inst_verify_sudo() {
  local out

  INST_SUDO_DETAIL=""
  command -v sudo >/dev/null 2>&1 || return 3
  if out="$(sudo -n -u "$TARGET_USER" -- sudo -n -- "$HELPER_PATH" ping 2>&1)"; then
    inst_ping_api_ok "$out" && return 0
    INST_SUDO_DETAIL="API_VERSION=$(printf '%s\n' "$out" | sed -n 's/^API_VERSION=//p' | head -n 1)"
    return 4
  fi
  INST_SUDO_DETAIL="$(printf '%s\n' "$out" | grep -m 1 . || true)"
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

# Installs required tools, Java (when missing), helper, sudoers entry and
# service, then verifies them.  Existing operator data, an existing Java and
# an armed timer are never touched.  Prints READY or INCOMPLETE with one line
# per problem (helper missing / wrong owner or mode / refused to start / API,
# sudo missing / refused / not verifiable, PKCS12 tool or Java).
installer_system_integration() {
  local helper_ok=no rc p12

  INTEGRATION_ISSUES=""
  if [ "$(id -u)" -ne 0 ]; then
    inst_issue 'the installer did not run as root'
  elif [ -z "${TARGET_GROUP:-}" ]; then
    inst_issue "user $TARGET_USER does not exist"
  elif ! inst_name_ok "$TARGET_GROUP"; then
    inst_warn "unsupported primary group name of $TARGET_USER; ezdrowie system components not installed"
    inst_issue "unsupported primary group name of $TARGET_USER"
  else
    installer_tools
    installer_java || true
    if install_ezdrowie_helper; then
      printf 'ezdrowie helper installed: %s\n' "$HELPER_PATH"
    else
      inst_issue "helper not installed (an older helper may still be present)"
    fi
    if inst_helper_compatible; then
      helper_ok=yes
      p12="$(printf '%s\n' "$INST_PING" | sed -n 's/^P12_TOOL=//p' | head -n 1)"
      case "$p12" in
        OK) printf 'ezdrowie PKCS12 tool ready (Java %s)\n' "${INST_JAVA_MAJOR:-8+}" ;;
        NO_JAVA) inst_issue 'PKCS12 tool: the helper finds no Java 8+ runtime in a root-controlled location (P12_TOOL=NO_JAVA)' ;;
        NO_JAR) inst_issue "PKCS12 tool: $HELPER_P12_JAR_PATH missing or not root-owned (P12_TOOL=NO_JAR)" ;;
        BAD_JAR) inst_issue "PKCS12 tool: $HELPER_P12_JAR_PATH has an unexpected SHA-256 (P12_TOOL=BAD_JAR)" ;;
        *) inst_issue "PKCS12 tool: state not reported by the helper (P12_TOOL=${p12:-none})" ;;
      esac
    else
      inst_issue "$INST_HELPER_PROBLEM"
    fi
    if [ "$helper_ok" = yes ]; then
      if install_ezdrowie_sudoers; then
        printf 'ezdrowie sudoers entry installed: %s\n' "$SUDOERS_FILE"
      else
        inst_issue "sudoers entry $SUDOERS_FILE not installed or reverted"
      fi
      rc=0
      inst_verify_sudo || rc=$?
      case "$rc" in
        0) printf 'ezdrowie sudo access verified for %s\n' "$TARGET_USER" ;;
        1) inst_issue "sudo refused: $TARGET_USER cannot run the helper with sudo -n (${INST_SUDO_DETAIL:-no message}); check $SUDOERS_FILE and #includedir in $SUDOERS_MAIN" ;;
        3) inst_issue 'sudo missing: the sudo command is not installed' ;;
        4) inst_issue "the helper answers through sudo with another API (${INST_SUDO_DETAIL}); another helper path in sudoers?" ;;
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
  printf '  p1cert ezdrowie credentials/test/scan/plan remain usable; run/schedule need a compatible helper and sudoers entry\n'
  printf '  (PKCS12 keystores also Java 8+ and the PKCS12 tool).  Diagnosis as %s: p1cert ezdrowie check\n' "$TARGET_USER"
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
      inst_remove_managed "$HELPER_P12_JAR_PATH" 'PKCS12 tool' 'P1certPkcs12.class' || true
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
  local action=install rc

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
  # The P1CERT files are installed either way (P1 CA commands do not need the
  # ezdrowie integration), but an incomplete integration is not a success:
  # exit status 3 tells the caller (MASTER) what the status lines say.
  rc=0
  installer_system_integration || rc=3
  "${BIN_DIR}/p1cert" version
  if [ "$rc" -ne 0 ]; then
    printf 'ERROR: P1CERT installed, but the ezdrowie system integration is INCOMPLETE (exit status 3); see the lines above\n' >&2
  fi
  return "$rc"
}

if [ "${P1CERT_INSTALLER_LIB_ONLY:-0}" != 1 ]; then
  installer_main "$@"
  exit $?
fi
