#!/bin/bash
# shellcheck shell=bash
# P1CERT ezdrowie privileged helper.
#
# Installed root-owned (0755) as
#   /usr/local/libexec/itgo-p1cert/p1cert-ezdrowie-helper
# and allowed for the P1CERT user through a dedicated /etc/sudoers.d entry.
# It is NOT a generic root shell: it implements a fixed set of operations and
# re-validates every argument, path, certificate and service relation on its
# own.  Nothing the unprivileged caller detected or decided is trusted.  It
# never sources or executes anything from the user-writable P1CERT directory.
#
# Operations:
#   ping
#   find-candidates
#   read           <cert-path>
#   apply          <cert-path> <old-fp> <new-fp> <old-file-sha256> <new-source-sha256>
#   apply-systemd  <cert-path> <old-fp> <new-fp> <old-file-sha256> <new-source-sha256> <unit.service>
#   apply-compose  <cert-path> <old-fp> <new-fp> <old-file-sha256> <new-source-sha256> <project-dir> <service>
#   apply-docker   <unit.service> <restart yes|no> <new-source-sha256> <new-fp>
#                  <path|PEM|DER|JKS|PKCS12|old-file-sha256|old-fp|alias|->...
#   recover
#   schedule       <YYYY-MM-DD> <HH:MM>
#   schedule-cancel
#
# <old-fp>/<new-fp> are the SHA-256 fingerprints (OpenSSL notation) of the
# current and the new leaf certificate.  <old-file-sha256> is the SHA-256 of
# the exact bytes of the current target file and <new-source-sha256> that of
# the exact bytes given on stdin, both as approved in the plan; any other
# bytes are refused.
#
# The new certificate is read from stdin by the apply operations.  A restart
# exists only as part of apply-systemd/apply-compose: one privileged operation
# that replaces exactly one certificate, restarts exactly the unit/service it
# has proven to use that certificate and, if the restart fails, restores the
# previous certificate from its own in-memory copy (never from a user supplied
# file) and restarts once more.  There is no standalone restart or restore.
#
# apply* print RESULT=<value> and exit with:
#   0 UPDATED | UPDATED_RESTARTED | NO_CHANGE
#   1 FAILED                   internal error, target not changed
#   2 REFUSED                  invalid request/target/certificate/binding, target not changed
#   3 REFUSED                  current fingerprint or file bytes differ from expected, target not changed
#   4 RESTORED                 replacement undone before any restart (verification
#                              failed or service binding changed), previous certificate verified
#   5 ROLLBACK                 restart failed, previous certificate restored and verified,
#                              single restart with it succeeded
#   6 ROLLBACK_RESTART_FAILED  as 5, but the single restart with it failed
#   7 ROLLBACK_FAILED          CRITICAL: previous certificate could not be restored
#
# apply-docker replaces the P1 certificate in all approved files of one
# Docker Compose application as one journaled operation and restarts its
# unit (see the section "Docker Compose applications"); same exit codes,
# plus 8 PENDING_RECOVERY.  recover undoes interrupted apply-docker
# operations.

set -u
set -f
umask 077
unset CDPATH ENV BASH_ENV GLOBIGNORE
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
TMPDIR=/tmp
export TMPDIR
LC_ALL=C
export LC_ALL

# Caller <-> helper contract version (not the P1CERT release version).
# Reported by "ping"; the caller and the installer require an exact match.
# 2: PEM certificate chains and the old/new file SHA-256 apply arguments.
# 3: target directory policy of the library (ez_target_dir_ok: root or
#    operator owned, group-writable for root/operator group) and the
#    descriptor/inode bound replacement; API 2 components are incompatible.
# 4: systemd binding through SSL.patch of the classic Integration Platform
#    (appConfig.properties of the installation the unit runs from, own
#    application tree policy); API 1-3 components are incompatible.
# 5: Docker Compose applications (apply-docker, recover, PKCS12 tool, plan
#    version 3); API 1-4 components are incompatible.
HELPER_API_VERSION=5

HELPER_DIR=/usr/local/libexec/itgo-p1cert
HELPER_SELF="$HELPER_DIR/p1cert-ezdrowie-helper"
HELPER_LIB="$HELPER_DIR/p1cert_ezdrowie_lib.sh"
HELPER_SYSTEMD_DIR=/etc/systemd/system
HELPER_SERVICE_UNIT=itgo-p1cert-ezdrowie.service
HELPER_TIMER_UNIT=itgo-p1cert-ezdrowie.timer
HELPER_DOCKER_SOCKET=/var/run/docker.sock
# apply operations are serialized through a lock in this root-only directory.
HELPER_LOCK_DIR=/run
# Fixed environment for every systemctl/docker call.
HELPER_SAFE_PATH=/usr/sbin:/usr/bin:/sbin:/bin
HELPER_TRUSTED_UID=0
HELPER_TRUSTED_GID=0
# Test fixtures may mirror the filesystem below a prefix; always empty when the
# helper is executed.
HELPER_FS_ROOT=""
HELPER_TMP=""
HELPER_WAIT_SECONDS=30
HELPER_SETTLE_SECONDS=3

# Per-operation state.
A_KIND=""; A_TARGET=""; A_UNIT=""; A_PROJECT=""; A_SERVICE=""; A_IDS=""; A_REASON=""
T_NAME=""; T_ID=""; T_UID=""; T_GID=""; T_MODE=""; T_CONTEXT=""; OLD_DIGEST=""; NEW_DIGEST=""; NEW_ID=""
# Replacement being prepared (open as fd 9) and the file last installed.
TMP_NAME=""; TMP_ID=""; INSTALLED_ID=""

helper_fail() {
  printf 'ERROR: %s\n' "$*" >&2
}

helper_info() {
  printf 'INFO: %s\n' "$*" >&2
}

helper_cleanup() {
  if [ -n "$HELPER_TMP" ] && [ -d "$HELPER_TMP" ]; then
    rm -rf -- "$HELPER_TMP"
  fi
}

helper_fs() {
  printf '%s%s' "$HELPER_FS_ROOT" "$1"
}

helper_require_root() {
  [ "$(id -u)" -eq 0 ] || {
    helper_fail 'helper must run as root'
    return 1
  }
}

# helper_node_trusted <path> <f|d> [required-gid]
# Regular file / directory (as requested), not a symlink, owned by root
# (HELPER_TRUSTED_UID), optionally group root, not group/world writable.
helper_node_trusted() {
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
  [ "$uid" = "$HELPER_TRUSTED_UID" ] || return 1
  [ -z "$want_gid" ] || [ "$gid" = "$want_gid" ] || return 1
  [ $((8#$mode & 8#022)) -eq 0 ]
}

# The helper, its library and every parent directory must be root-owned and
# not writable by anyone else; otherwise fail closed before loading anything.
helper_self_check() {
  local item

  for item in / /usr /usr/local /usr/local/libexec "$HELPER_DIR"; do
    helper_node_trusted "$(helper_fs "$item")" d || {
      helper_fail "unsafe helper directory (must be a root-owned directory, not a symlink, not group/world writable): $item"
      return 1
    }
  done
  for item in "$HELPER_SELF" "$HELPER_LIB"; do
    helper_node_trusted "$(helper_fs "$item")" f || {
      helper_fail "unsafe helper file (must be a root-owned regular file, not a symlink, not group/world writable): $item"
      return 1
    }
  done
}

helper_load_lib() {
  # shellcheck disable=SC1090
  . "$(helper_fs "$HELPER_LIB")"
}

helper_tmpdir() {
  [ -n "$HELPER_TMP" ] && return 0
  HELPER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/p1cert-ezdrowie-helper.XXXXXX")" || {
    helper_fail 'cannot create private temporary directory'
    return 1
  }
  chmod 0700 "$HELPER_TMP"
}

helper_systemctl() {
  env -i PATH="$HELPER_SAFE_PATH" LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0 systemctl "$@"
}

# Docker is always called with a clean environment: no DOCKER_HOST,
# DOCKER_CONTEXT, DOCKER_CONFIG, COMPOSE_* or anything else inherited from the
# operator, an empty private client config (no contexts, no plugins) and the
# local daemon socket given explicitly.  docker compose is never used.
helper_docker() {
  env -i PATH="$HELPER_SAFE_PATH" HOME=/root LC_ALL=C DOCKER_CONFIG="$HELPER_TMP/docker-config" \
    docker -H "unix://$HELPER_DOCKER_SOCKET" "$@"
}

# The standard socket (root:docker 0660) is accepted; a socket that is not
# owned by root or is writable by others is refused.
helper_docker_socket_ok() {
  local socket meta uid mode

  socket="$(helper_fs "$HELPER_DOCKER_SOCKET")"
  [ -S "$socket" ] && [ ! -L "$socket" ] || return 1
  meta="$(stat -c '%u %a' -- "$socket" 2>/dev/null)" || return 1
  uid="${meta%% *}"
  mode="${meta#* }"
  case "$uid:$mode" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  [ "$uid" = "$HELPER_TRUSTED_UID" ] && [ $((8#$mode & 8#002)) -eq 0 ]
}

helper_docker_ready() {
  helper_docker_socket_ok || {
    helper_fail "local Docker socket $HELPER_DOCKER_SOCKET is missing, not root-owned or writable by others"
    return 1
  }
  helper_tmpdir || return 1
  [ -d "$HELPER_TMP/docker-config" ] || mkdir -m 0700 -- "$HELPER_TMP/docker-config" || return 1
}

# Only one apply operation at a time (the caller's own lock lives in a
# user-writable directory and is not a guarantee for direct sudo calls).
helper_lock() {
  local dir

  dir="$(helper_fs "$HELPER_LOCK_DIR")"
  helper_node_trusted "$dir" d || {
    helper_fail "lock directory $HELPER_LOCK_DIR is not root-controlled"
    return 1
  }
  command -v flock >/dev/null 2>&1 || { helper_fail 'flock is unavailable'; return 1; }
  exec 8>>"$dir/itgo-p1cert-ezdrowie-helper.lock" || return 1
  flock -w 120 8 || {
    helper_fail 'another ezdrowie helper operation is still running'
    return 1
  }
}

helper_systemd_ready() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || {
    helper_fail 'systemd is not available'
    return 1
  }
}

helper_read_stdin_cert() {
  local destination="$1" size

  head -c $((EZ_MAX_CERT_BYTES + 1)) > "$destination" || return 1
  size="$(ez_file_size "$destination")"
  [ -n "$size" ] && [ "$size" -gt 0 ] && [ "$size" -le "$EZ_MAX_CERT_BYTES" ] || {
    helper_fail 'certificate on stdin is empty or too large'
    return 1
  }
}

helper_norm_fp() {
  printf '%s' "$1" | tr 'a-f' 'A-F'
}

helper_link_count() {
  stat -c '%h' -- "$1" 2>/dev/null
}

# Validates a certificate target path and that it currently is a regular,
# non-symlinked, single-link file.
helper_check_target() {
  local target="$1" fs

  ez_target_path_ok "$target" || {
    helper_fail "target path is not an allowed ezdrowie certificate path: $target"
    return 1
  }
  ez_path_no_symlinks "$HELPER_FS_ROOT" "$target" || {
    helper_fail "target path contains a symlink: $target"
    return 1
  }
  fs="$(helper_fs "$target")"
  [ -f "$fs" ] && [ ! -L "$fs" ] || {
    helper_fail "target is not a regular file: $target"
    return 1
  }
  [ "$(helper_link_count "$fs")" = 1 ] || {
    helper_fail "target has multiple hard links, refusing: $target"
    return 1
  }
}

# helper_entry_meta [-L] <path>
# One stat of <path> (lstat; with -L the file it resolves to).  Succeeds only
# for a regular file with exactly one hard link and sets E_ID ("dev:ino"),
# E_UID, E_GID and E_MODE.
helper_entry_meta() {
  local follow="" meta dev ino links raw

  if [ "$1" = -L ]; then
    follow=-L
    shift
  fi
  E_ID=""; E_UID=""; E_GID=""; E_MODE=""
  meta="$(stat $follow -c '%d %i %h %f %u %g %a' -- "$1" 2>/dev/null)" || return 1
  read -r dev ino links raw E_UID E_GID E_MODE <<EOF
$meta
EOF
  case "$dev:$ino:$links:$E_UID:$E_GID:$E_MODE" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  # %f is the raw st_mode in hex: S_IFREG is 0x8000.
  case "$raw" in
    8[0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  [ "$links" = 1 ] || return 1
  E_ID="$dev:$ino"
}

# Prints the identity of a regular, single-link directory entry (never
# follows a symlink); nothing for anything else.
helper_entry_id() {
  helper_entry_meta "$1" && printf '%s' "$E_ID"
}

# Identity of the replacement open as fd 9 (resolved through /proc, not by
# its name).
helper_temp_fd_id() {
  helper_entry_meta -L /proc/self/fd/9 && printf '%s' "$E_ID"
}

# helper_read_entry <name> <expected-id> <root-private-destination>
# Copies a file of the pinned directory without following a symlink
# (O_NOFOLLOW), blocking on a FIFO (O_NONBLOCK) or acquiring a terminal
# (O_NOCTTY).  The entry must be the expected regular single-link file right
# before and right after the copy.  At most twice EZ_MAX_CERT_BYTES are
# copied; larger files are rejected by the inspection anyway.
helper_read_entry() {
  local name="$1" id="$2" out="$3"

  [ -n "$id" ] && [ "$(helper_entry_id "$name")" = "$id" ] || return 1
  # Docker operations read keystores (HELPER_READ_BS up to their size limit).
  dd if="$name" of="$out" iflag=nofollow,nonblock,noctty bs="${HELPER_READ_BS:-$EZ_MAX_CERT_BYTES}" count=2 2>/dev/null || return 1
  [ "$(helper_entry_id "$name")" = "$id" ]
}

helper_selinux_enabled() {
  command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled
}

# SELinux context of a directory entry itself (lgetfilecon, no symlink).
helper_entry_context() {
  stat -c '%C' -- "$1" 2>/dev/null
}

# Pins the target directory as the working directory and verifies that it
# still is the expected path and that the target in it is a regular,
# single-link file.  All later file operations are relative to it.
helper_pin_target_dir() {
  local target="$1" dir

  dir="$(helper_fs "${target%/*}")"
  cd -P -- "$dir" 2>/dev/null || {
    helper_fail "cannot enter target directory: ${target%/*}"
    return 1
  }
  [ "$(pwd -P)" = "$dir" ] || {
    helper_fail "target directory changed during validation: ${target%/*}"
    return 1
  }
  T_NAME="${target##*/}"
  [ -n "$(helper_entry_id "$T_NAME")" ] || {
    helper_fail "target changed during validation: $target"
    return 1
  }
}

# Pins the target directory (above) for a replacement and applies the
# directory policy (ez_target_dir_ok): owned by root or by the operator, the
# P1CERT user that called the helper through sudo (SUDO_UID/SUDO_GID, set by
# sudo itself, also for the scheduled run), group write only for the root or
# the operator group, never world writable.  The owner and group members of
# such a directory can replace any entry in it at any time, so the helper
# never writes, chowns or chmods anything there by name (see
# helper_atomic_replace), reads only with O_NOFOLLOW and binds every step to
# the identity (device:inode) of the file it checked.  Records identity,
# owner, group, mode and SELinux context of the target.
helper_enter_target_dir() {
  local target="$1" op_uid="${SUDO_UID:-}" op_gid="${SUDO_GID:-}"

  helper_pin_target_dir "$target" || return 1
  case "$op_uid:$op_gid" in
    *[!0-9:]*|:*|*:) op_uid=""; op_gid="" ;;
  esac
  ez_target_dir_ok . "$HELPER_TRUSTED_UID" "$HELPER_TRUSTED_GID" "$op_uid" "$op_gid" || {
    helper_fail "target directory must be owned by root or by the P1CERT user, writable only by its owner and the root or P1CERT group, never by others (replace manually): ${target%/*}"
    return 1
  }
  helper_entry_meta "$T_NAME" || {
    helper_fail "target changed during validation: $target"
    return 1
  }
  T_ID="$E_ID"; T_UID="$E_UID"; T_GID="$E_GID"; T_MODE="$E_MODE"; T_CONTEXT=""
  if helper_selinux_enabled; then
    T_CONTEXT="$(helper_entry_context "$T_NAME")"
    case "$T_CONTEXT" in
      ''|*[!A-Za-z0-9_.:,-]*)
        helper_fail "cannot read the SELinux context of the target: $target"
        return 1
        ;;
    esac
    [ "$(helper_entry_id "$T_NAME")" = "$T_ID" ] || {
      helper_fail "target changed during validation: $target"
      return 1
    }
  fi
}

# helper_render_cert <in> <in-format> <in-count> <out-format> <out>
# Writes the inspected new certificate file in the target's format:
#   - a single certificate is re-encoded by OpenSSL (PEM <-> DER),
#   - a verified PEM chain (count > 1) is copied byte for byte, and only into
#     a PEM target ("openssl x509" would keep the first certificate only);
#     a chain is never converted to DER.
helper_render_cert() {
  local in="$1" in_format="$2" in_count="$3" out_format="$4" out="$5"

  case "$in_count" in
    1) openssl x509 -inform "$in_format" -in "$in" -outform "$out_format" -out "$out" 2>/dev/null ;;
    [2-9]|[1-9][0-9])
      [ "$in_format" = PEM ] && [ "$out_format" = PEM ] || return 1
      cat -- "$in" > "$out"
      ;;
    *) return 1 ;;
  esac
}

# Creates the replacement in the pinned directory and keeps it open as fd 9.
# The name is unpredictable (128 bits from /dev/urandom) and the file is
# created with O_CREAT|O_EXCL (bash noclobber), so fd 9 is always a new,
# empty file of this operation and never an existing file, symlink or
# device.  Sets TMP_NAME and TMP_ID.
helper_temp_create() {
  local rnd rc

  TMP_NAME=""; TMP_ID=""
  rnd="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  case "$rnd" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#rnd}" -eq 32 ] || return 1
  set -C
  { exec 9> ".p1cert-ezdrowie.$rnd"; } 2>/dev/null
  rc=$?
  set +C
  [ "$rc" -eq 0 ] || return 1
  TMP_NAME=".p1cert-ezdrowie.$rnd"
  TMP_ID="$(helper_temp_fd_id)"
  [ -n "$TMP_ID" ] && [ "$(helper_entry_id "$TMP_NAME")" = "$TMP_ID" ] || {
    helper_temp_drop
    return 1
  }
}

# Closes fd 9 and removes the temporary name (unlinking a name never touches
# the file another name or symlink in its place points to).
helper_temp_drop() {
  exec 9>&-
  [ -z "$TMP_NAME" ] || rm -f -- "$TMP_NAME"
  TMP_NAME=""; TMP_ID=""
}

# helper_atomic_replace <content> <expected-sha256> <expected-id>
# Atomically replaces T_NAME inside the pinned directory with the content of
# <content>, applying the original owner, group and mode (and SELinux
# context).  Content, owner, group, mode and context are applied only through
# fd 9 (/proc/self/fd/9), never through the temporary name, which the owner or
# group of the directory could replace with a symlink or hard link at any
# time.  The pre-rename validation requires the target to still be the same
# file (<expected-id>, dev:ino) with exactly the bytes <expected-sha256>, and
# the temporary name to still be the prepared file; a change detected there
# (including one made by someone else) is refused and not overwritten.  The
# final mv/rename itself is pathname-based and leaves the narrow final race
# window described in the README.  Sets INSTALLED_ID.
helper_atomic_replace() {
  local content="$1" expect="$2" expect_id="$3"

  INSTALLED_ID=""
  ez_digest_ok "$expect" && [ -n "$expect_id" ] || {
    helper_fail 'no valid expected digest or identity of the current target; nothing replaced'
    return 1
  }
  helper_temp_create || {
    helper_fail 'cannot create temporary file next to target'
    return 1
  }
  if ! cat -- "$content" >&9 ||
     ! chown -- "$T_UID:$T_GID" /proc/self/fd/9 ||
     ! chmod -- "$T_MODE" /proc/self/fd/9; then
    helper_temp_drop
    helper_fail 'cannot prepare replacement file with original owner/group/mode'
    return 1
  fi
  if helper_selinux_enabled; then
    if [ -z "$T_CONTEXT" ] || ! chcon -- "$T_CONTEXT" /proc/self/fd/9 2>/dev/null; then
      helper_temp_drop
      helper_fail 'cannot copy SELinux context to replacement file'
      return 1
    fi
  fi
  if ! helper_read_entry "$T_NAME" "$expect_id" "$HELPER_TMP/current" ||
     [ "$(ez_file_digest "$HELPER_TMP/current")" != "$expect" ]; then
    helper_temp_drop
    helper_fail 'target does not contain the expected bytes; nothing replaced'
    return 1
  fi
  if [ "$(helper_temp_fd_id)" != "$TMP_ID" ] || [ "$(helper_entry_id "$TMP_NAME")" != "$TMP_ID" ]; then
    helper_temp_drop
    helper_fail 'temporary file was replaced in the target directory; nothing replaced'
    return 1
  fi
  # -T: never move into a directory that appeared under the target name.
  if ! mv -f -T -- "$TMP_NAME" "$T_NAME"; then
    helper_temp_drop
    helper_fail 'atomic rename failed'
    return 1
  fi
  exec 9>&-
  INSTALLED_ID="$TMP_ID"
  TMP_NAME=""; TMP_ID=""
}

# Verifies the file on disk: still the file installed by this operation
# (<id>), a valid single certificate or complete chain, the leaf fingerprint
# and the exact bytes of the whole file.
helper_verify_disk() {
  local fp="$1" digest="$2" id="$3"

  ez_digest_ok "$digest" &&
    helper_read_entry "$T_NAME" "$id" "$HELPER_TMP/verify" &&
    ez_cert_inspect "$HELPER_TMP/verify" &&
    [ "$EZC_FP" = "$fp" ] &&
    [ "$(ez_file_digest "$HELPER_TMP/verify")" = "$digest" ]
}

# Puts back the exact previous certificate read by this operation, but only
# when the pre-rollback validation still sees the file this operation
# installed (NEW_ID) with exactly its bytes (NEW_DIGEST).  A change detected
# by that validation is not overwritten: the rollback then fails
# (ROLLBACK_FAILED, manual action).  The same narrow final race window
# between the last validation and the pathname-based rename remains.
helper_restore_old() {
  helper_atomic_replace "$HELPER_TMP/old" "$NEW_DIGEST" "$NEW_ID" &&
    helper_verify_disk "$OLD_FP" "$OLD_DIGEST" "$INSTALLED_ID"
}

# Undoes a replacement before any restart happened.
helper_undo() {
  helper_fail "$1; restoring the previous certificate"
  if helper_restore_old; then
    printf 'RESULT=RESTORED\nFP=%s\n' "$OLD_FP"
    return 4
  fi
  helper_fail "CRITICAL: previous certificate could not be restored: $A_TARGET"
  printf 'RESULT=ROLLBACK_FAILED\n'
  return 7
}

helper_refuse() {
  local rc="$1"

  shift
  helper_fail "$*"
  printf 'RESULT=REFUSED\n'
  return "$rc"
}

# --- systemd binding ---------------------------------------------------------

# helper_path_trusted <absolute-path> [parents]
# Every directory from / down to the parent of the path must be a root-owned,
# not group/world writable directory without symlinks, so that no
# unprivileged user can rename a different file into place; the file itself
# must be a root-owned, not group/world writable regular file.  With
# "parents" only the directories are checked (file may be absent).
helper_path_trusted() {
  local path="$1" mode="${2:-file}" current="" rest part

  ez_path_chars_ok "$path" || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    */|*//*) return 1 ;;
  esac
  case "/$path/" in
    */../*|*/./*) return 1 ;;
  esac
  helper_node_trusted "$(helper_fs /)" d || return 1
  rest="${path#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    current="$current/$part"
    if [ -n "$rest" ]; then
      helper_node_trusted "$(helper_fs "$current")" d || return 1
    elif [ "$mode" != parents ]; then
      helper_node_trusted "$(helper_fs "$current")" f || return 1
    fi
  done
}

# helper_pi_appconfig <ip-root> <systemctl-show-output>
# Prints appConfig.properties of the IntegrationPlatform installation
# <ip-root> (the one the unit runs from) for ez_systemd_bound rule C, or
# fails.  This file belongs to the application, not to root (real model:
# itgo:itgo 775), so helper_path_trusted does not apply; instead the narrow
# library policy ez_pi_appconfig_trusted is enforced with the unit's own
# User= as the only principal besides root: / up to the parent of <ip-root>
# root-controlled, the installation tree and the file owned by root or that
# user, group write only for root or the user's primary group, never world
# writable, no symlink, one hard link, size limit.  The file is then read in
# a subshell from its pinned directory (cd -P, policy re-checked on ".") by
# name with O_NOFOLLOW/O_NONBLOCK/O_NOCTTY (dd), so a symlink, FIFO or device
# swapped in is never followed or blocked on.  The entry must be the
# device:inode validated by path (regular, one link) right before the open
# and again after the read, and the copy must have the entry's size.  This is
# NOT a descriptor-bound read (Bash has no openat/fstat): a principal that can
# modify WEB-INF (by the policy above root, the unit user and, with group
# write, members of the root group or the user's primary group) can still swap
# another regular file in after the pre-open check and back before the
# post-read check (A-B-A); see README.  Needs HELPER_TMP.
helper_pi_appconfig() {
  local root="$1" props="$2" file ids auid agid fs dir copy id

  file="$root/$EZ_PI_APPCONFIG_REL"
  fs="$(helper_fs "$file")"
  ids="$(ez_systemd_app_ids "$props" "$HELPER_TRUSTED_UID" "$HELPER_TRUSTED_GID")" || {
    helper_info "User= of the unit cannot be resolved; $file is not used as evidence"
    return 1
  }
  read -r auid agid <<EOF
$ids
EOF
  ez_pi_appconfig_trusted "$HELPER_FS_ROOT" "$root" "$HELPER_TRUSTED_UID" "$HELPER_TRUSTED_GID" "$auid" "$agid" || {
    helper_info "$file or one of its directories is not controlled only by root and the unit user (uid $auid), is a symlink, has several links or is too large; not used as evidence"
    return 1
  }
  helper_entry_meta "$fs" || return 1
  id="$E_ID"
  dir="${fs%/*}"
  copy="$HELPER_TMP/pi-appconfig"
  rm -f -- "$copy"
  (
    cd -P -- "$dir" 2>/dev/null && [ "$(pwd -P)" = "$dir" ] || exit 1
    ez_target_dir_ok . "$HELPER_TRUSTED_UID" "$HELPER_TRUSTED_GID" "$auid" "$agid" || exit 1
    [ "$(helper_entry_id appConfig.properties)" = "$id" ] || exit 1
    dd if=appConfig.properties of="$copy" iflag=nofollow,nonblock,noctty bs="$EZ_PI_APPCONFIG_MAX_BYTES" count=2 2>/dev/null || exit 1
    [ "$(helper_entry_id appConfig.properties)" = "$id" ] || exit 1
    [ "$(stat -c '%s' -- appConfig.properties 2>/dev/null)" = "$(ez_file_size "$copy")" ]
  ) || {
    helper_info "$file changed while it was read; not used as evidence"
    rm -f -- "$copy"
    return 1
  }
  ez_pi_appconfig_load "$copy" || {
    helper_info "$file is too large or contains NUL bytes; not used as evidence"
    rm -f -- "$copy"
    return 1
  }
  rm -f -- "$copy"
}

# Proves, independently of the caller, that unit $2 uses certificate $1 (see
# ez_systemd_bound).  Only root-controlled unit, drop-in and environment
# files are read, plus appConfig.properties of the unit's IntegrationPlatform
# installation under its own narrow policy (helper_pi_appconfig).  Sets
# A_REASON.
helper_systemd_bound() {
  local target="$1" unit="$2" props load fragment kind file fs config="" reason root appcfg=""

  props="$(helper_systemctl show --no-pager -p LoadState -p FragmentPath -p DropInPaths \
    -p WorkingDirectory -p ExecStart -p Environment -p EnvironmentFiles -p User -- "$unit" 2>/dev/null)" || {
    helper_fail "cannot inspect unit: $unit"
    return 1
  }
  load="$(printf '%s\n' "$props" | sed -n 's/^LoadState=//p' | head -n 1)"
  fragment="$(printf '%s\n' "$props" | sed -n 's/^FragmentPath=//p' | head -n 1)"
  [ "$load" = loaded ] || { helper_fail "unit is not loaded: $unit"; return 1; }
  case "$fragment" in
    /etc/systemd/system/*|/usr/lib/systemd/system/*|/lib/systemd/system/*) ;;
    *) helper_fail "unit file location is not allowed: ${fragment:-none}"; return 1 ;;
  esac
  while IFS=' ' read -r kind file; do
    [ -n "$file" ] || continue
    case "$kind:$file" in
      F:/etc/systemd/system/*|F:/usr/lib/systemd/system/*|F:/lib/systemd/system/*|F:/run/systemd/system/*|E:/*) ;;
      *) helper_fail "unexpected unit configuration path: $file"; return 1 ;;
    esac
    ez_path_chars_ok "$file" || { helper_fail "unsupported unit configuration path: $file"; return 1; }
    fs="$(helper_fs "$file")"
    if [ "$kind" = E ] && [ ! -e "$fs" ] && [ ! -L "$fs" ]; then
      # An optional EnvironmentFile that does not exist yet could still be
      # created at restart time: its directory must be root-controlled too.
      helper_path_trusted "$file" parents || {
        helper_fail "directory of EnvironmentFile is not root-controlled: $file; automatic restart refused"
        return 1
      }
      continue
    fi
    helper_path_trusted "$file" || {
      helper_fail "unit configuration file or one of its directories is not root-controlled: $file; automatic restart refused"
      return 1
    }
    config="$config
$(cat -- "$fs" 2>/dev/null)"
  done <<EOF
$(ez_systemd_config_files "$props")
EOF
  # Classic Integration Platform: SSL.patch of the installation the unit
  # runs from (never of the installation the certificate lies in).
  if root="$(ez_systemd_ip_root "$props")"; then
    fs="$(helper_fs "$root/$EZ_PI_APPCONFIG_REL")"
    if [ -e "$fs" ] || [ -L "$fs" ]; then
      helper_tmpdir || return 1
      appcfg="$(helper_pi_appconfig "$root" "$props")" || appcfg=""
    fi
  fi
  reason="$(ez_systemd_bound "$target" "$props" "$config" "$appcfg")" || {
    helper_fail "no provable relation between $unit and $target; automatic restart refused"
    return 1
  }
  A_REASON="$reason"
}

# Success only when the unit has stayed "active" for HELPER_SETTLE_SECONDS.
# Leaving "active" during that period (failed, inactive, activating after an
# auto-restart, ...) is a failed restart.
helper_wait_systemd_active() {
  local unit="$1" waited=0 state active_since=-1

  while [ "$waited" -le "$HELPER_WAIT_SECONDS" ]; do
    state="$(helper_systemctl is-active -- "$unit" 2>/dev/null)" || true
    case "$state" in
      active)
        [ "$active_since" -ge 0 ] || active_since="$waited"
        [ $((waited - active_since)) -ge "$HELPER_SETTLE_SECONDS" ] && return 0
        ;;
      *)
        [ "$active_since" -lt 0 ] || return 1
        case "$state" in
          failed|inactive) [ "$waited" -ge "$HELPER_SETTLE_SECONDS" ] && return 1 ;;
        esac
        ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- Docker Compose binding --------------------------------------------------

# A compose project directory: allowed path without symlinks containing one of
# the standard compose file names.  The compose files are not parsed or used.
helper_compose_project_ok() {
  local project="$1" fsdir file

  ez_path_under_roots "$project" || return 1
  ez_path_no_symlinks "$HELPER_FS_ROOT" "$project" || return 1
  fsdir="$(helper_fs "$project")"
  [ -d "$fsdir" ] && [ ! -L "$fsdir" ] || return 1
  for file in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$fsdir/$file" ] && [ ! -L "$fsdir/$file" ] && return 0
  done
  return 1
}

# Proves, independently of the caller, that compose service $3 of project $2
# uses certificate $1: every running container labelled with exactly this
# project directory and service must bind-mount the certificate file or a
# directory containing it.  Sets A_IDS (newline separated container ids).
helper_compose_bound() {
  local target="$1" project="$2" service="$3" ids id info first type source bound count=0

  A_IDS=""
  ids="$(helper_docker ps -q --no-trunc \
    --filter "label=com.docker.compose.service=$service" \
    --filter "label=com.docker.compose.project.working_dir=$project" 2>/dev/null)" || {
    helper_fail 'cannot list Docker containers'
    return 1
  }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$id" | grep -E -q '^[0-9a-f]{64}$' || { helper_fail 'unexpected container id from Docker'; return 1; }
    info="$(helper_docker inspect --type container --format \
      '{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{.State.Running}}{{range .Mounts}}{{println}}{{.Type}}|{{.Source}}{{end}}' \
      "$id" 2>/dev/null)" || { helper_fail "cannot inspect container $id"; return 1; }
    first="$(printf '%s\n' "$info" | head -n 1)"
    [ "$first" = "$service|$project|true" ] || {
      helper_fail "container $id is not a running container of $service in $project"
      return 1
    }
    bound=no
    while IFS='|' read -r type source; do
      [ "$type" = bind ] || continue
      if ez_mount_covers "$target" "$source"; then
        bound=yes
      fi
    done <<EOF
$(printf '%s\n' "$info" | tail -n +2)
EOF
    [ "$bound" = yes ] || {
      helper_fail "container $id of service $service does not bind-mount $target; automatic restart refused"
      return 1
    }
    A_IDS="${A_IDS:+$A_IDS
}$id"
    count=$((count + 1))
  done <<EOF
$ids
EOF
  [ "$count" -gt 0 ] || {
    helper_fail "no running container of compose service $service in $project; relation to $target cannot be confirmed"
    return 1
  }
  A_REASON="bind mount certyfikatu w $count kontenerze/kontenerach usługi $service"
}

helper_wait_docker_running() {
  local waited=0 id state all_ok

  while [ "$waited" -le "$HELPER_WAIT_SECONDS" ]; do
    all_ok=yes
    for id in $A_IDS; do
      state="$(helper_docker inspect --type container --format \
        '{{.State.Running}} {{.State.Restarting}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$id" 2>/dev/null)" || state=""
      case "$state" in
        'true false healthy'|'true false none'|'true false starting') ;;
        *) all_ok=no ;;
      esac
    done
    [ "$all_ok" = yes ] && [ "$waited" -ge "$HELPER_SETTLE_SECONDS" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- restart of the bound unit/service ---------------------------------------

helper_binding_check() {
  case "$A_KIND" in
    systemd) helper_systemd_bound "$A_TARGET" "$A_UNIT" ;;
    compose) helper_compose_bound "$A_TARGET" "$A_PROJECT" "$A_SERVICE" ;;
    *) return 1 ;;
  esac
}

# One restart attempt of exactly the bound unit / verified containers.
helper_restart_once() {
  case "$A_KIND" in
    systemd)
      helper_info "systemctl restart $A_UNIT"
      helper_systemctl restart -- "$A_UNIT" || return 1
      helper_wait_systemd_active "$A_UNIT"
      ;;
    compose)
      helper_info "docker restart of service $A_SERVICE ($A_PROJECT): $(printf '%s' "$A_IDS" | tr '\n' ' ')"
      # shellcheck disable=SC2086 # validated hex ids, globbing is disabled
      helper_docker restart $A_IDS >/dev/null || return 1
      helper_wait_docker_running
      ;;
    *)
      return 1
      ;;
  esac
}

# --- operations --------------------------------------------------------------

op_ping() {
  printf 'HELPER=OK\nAPI_VERSION=%s\n' "$HELPER_API_VERSION"
  # PKCS12 support of apply-docker: Java runtime and the verified tool.
  helper_p12_ready || true
  printf 'P12_TOOL=%s\n' "$HELPER_P12_STATE"
  # Interrupted Docker operations waiting for "recover" (read only).
  printf 'DOCKER_PENDING=%s\n' "$(helper_journal_pending | grep -c . || true)"
}

op_find_candidates() {
  local root fsroot path logical

  for root in $EZ_ALLOWED_ROOTS; do
    fsroot="$(helper_fs "$root")"
    [ -d "$fsroot" ] && [ ! -L "$fsroot" ] || continue
    while IFS= read -r -d '' path; do
      logical="${path#"$HELPER_FS_ROOT"}"
      ez_target_path_ok "$logical" || continue
      printf '%s\n' "$logical"
    # OLD directories (any case) are certificate archives: not descended.
    done < <(find -P "$fsroot" \( -name node_modules -o -name .git -o \( -type d -iname old \) \) -prune -o \
      -type f \( -iname '*.pem' -o -iname '*.crt' -o -iname '*.cer' \) -size -1024k -print0 2>/dev/null)
  done
}

op_read() {
  local target="$1" rc

  helper_check_target "$target" || return 2
  helper_tmpdir || return 1
  # Reading needs no directory policy, but never follows a symlink swapped in.
  helper_pin_target_dir "$target" || return 2
  helper_read_entry "$T_NAME" "$(helper_entry_id "$T_NAME")" "$HELPER_TMP/read" || {
    helper_fail "cannot read target: $target"
    return 1
  }
  ez_cert_inspect "$HELPER_TMP/read"
  rc=$?
  [ "$rc" -eq 0 ] || {
    helper_fail "target is neither a single X.509 certificate nor a valid PEM certificate chain without private key (code $rc${EZC_REASON:+: $EZC_REASON}): $target"
    return 2
  }
  cat -- "$HELPER_TMP/read"
}

# helper_apply <none|systemd|compose> <cert-path> <old-fp> <new-fp>
#              <old-file-sha256> <new-source-sha256> [unit | project service]
helper_apply() {
  local expected_old expected_new expected_old_digest expected_new_digest source_digest now rc reason

  A_KIND="$1"; A_TARGET="$2"; A_UNIT=""; A_PROJECT=""; A_SERVICE=""; A_IDS=""; A_REASON=""
  expected_old="$(helper_norm_fp "$3")"
  expected_new="$(helper_norm_fp "$4")"
  expected_old_digest="$5"
  expected_new_digest="$6"
  ez_fp_ok "$expected_old" && ez_fp_ok "$expected_new" || helper_refuse 2 'invalid expected fingerprint' || return
  [ "$expected_old" != "$expected_new" ] || helper_refuse 2 'expected old and new fingerprints are identical' || return
  ez_digest_ok "$expected_old_digest" && ez_digest_ok "$expected_new_digest" ||
    helper_refuse 2 'invalid expected file SHA-256 (64 lowercase hex characters required)' || return
  helper_lock || helper_refuse 1 'cannot serialize the operation' || return

  # 1. The restart target and its relation to this certificate are proven
  #    before anything is changed.
  case "$A_KIND" in
    none) ;;
    systemd)
      A_UNIT="$7"
      ez_unit_name_ok "$A_UNIT" || helper_refuse 2 "invalid unit name: $A_UNIT" || return
      ! ez_unit_denied "$A_UNIT" || helper_refuse 2 "unit is not allowed: $A_UNIT" || return
      helper_systemd_ready || helper_refuse 1 'systemd unavailable' || return
      helper_check_target "$A_TARGET" || helper_refuse 2 'invalid target' || return
      helper_systemd_bound "$A_TARGET" "$A_UNIT" || helper_refuse 2 "unit $A_UNIT is not bound to $A_TARGET" || return
      ;;
    compose)
      A_PROJECT="$7"; A_SERVICE="$8"
      helper_compose_project_ok "$A_PROJECT" || helper_refuse 2 "invalid compose project directory: $A_PROJECT" || return
      ez_compose_service_ok "$A_SERVICE" || helper_refuse 2 "invalid compose service name: $A_SERVICE" || return
      helper_docker_ready || helper_refuse 1 'Docker unavailable' || return
      helper_check_target "$A_TARGET" || helper_refuse 2 'invalid target' || return
      helper_compose_bound "$A_TARGET" "$A_PROJECT" "$A_SERVICE" || helper_refuse 2 "service $A_SERVICE is not bound to $A_TARGET" || return
      ;;
    *)
      helper_refuse 2 'unsupported apply kind' || return
      ;;
  esac
  [ -z "$A_REASON" ] || helper_info "binding: $A_REASON"

  # 2. Target, new certificate and current certificate.
  helper_check_target "$A_TARGET" || helper_refuse 2 'invalid target' || return
  helper_tmpdir || { printf 'RESULT=FAILED\n'; return 1; }
  now="$(date -u '+%s')"

  helper_read_stdin_cert "$HELPER_TMP/new.in" || helper_refuse 2 'invalid certificate on stdin' || return
  # Exactly the approved source bytes, checked before they are interpreted.
  source_digest="$(ez_file_digest "$HELPER_TMP/new.in")"
  ez_digest_ok "$source_digest" || helper_refuse 1 'cannot compute a valid SHA-256 of the new source file' || return
  [ "$source_digest" = "$expected_new_digest" ] ||
    helper_refuse 2 "new source file SHA-256 $source_digest differs from the approved $expected_new_digest" || return
  ez_cert_inspect "$HELPER_TMP/new.in"
  rc=$?
  [ "$rc" -eq 0 ] || helper_refuse 2 "new certificate is neither a single X.509 certificate nor a valid PEM certificate chain (code $rc${EZC_REASON:+: $EZC_REASON})" || return
  ez_cert_save NEW
  [ "$NEW_FP" = "$expected_new" ] || helper_refuse 2 "new certificate fingerprint $NEW_FP differs from the expected $expected_new" || return

  # Pins the directory and records identity, owner, group, mode and context.
  helper_enter_target_dir "$A_TARGET" || helper_refuse 2 'unsafe target directory' || return

  # The exact bytes of the current certificate are kept in the root-private
  # temporary directory of this operation; they are the only rollback source.
  helper_read_entry "$T_NAME" "$T_ID" "$HELPER_TMP/old" || helper_refuse 2 'cannot read current certificate' || return
  OLD_DIGEST="$(ez_file_digest "$HELPER_TMP/old")"
  ez_digest_ok "$OLD_DIGEST" || helper_refuse 1 'cannot compute a valid SHA-256 of the current certificate' || return
  # The exact current bytes must be the ones approved in the plan (any change
  # of a chain's intermediates/root, line endings, ... included), checked on
  # this root-private copy before it is interpreted.  OLD_DIGEST is also what
  # helper_atomic_replace re-checks on the target right before the rename.
  [ "$OLD_DIGEST" = "$expected_old_digest" ] ||
    helper_refuse 3 "current file SHA-256 changed (expected $expected_old_digest, found $OLD_DIGEST)" || return
  ez_cert_inspect "$HELPER_TMP/old"
  rc=$?
  [ "$rc" -eq 0 ] || helper_refuse 2 "current file is neither a single X.509 certificate nor a valid PEM certificate chain (code $rc${EZC_REASON:+: $EZC_REASON})" || return
  ez_cert_save OLD

  if [ "$OLD_FP" = "$NEW_FP" ]; then
    printf 'RESULT=NO_CHANGE\nFP=%s\n' "$OLD_FP"
    return 0
  fi
  [ "$OLD_FP" = "$expected_old" ] || helper_refuse 3 "current certificate fingerprint changed (expected $expected_old, found $OLD_FP)" || return
  if [ "$NEW_NB_EPOCH" -gt "$now" ] || [ "$NEW_NA_EPOCH" -le "$now" ]; then
    helper_refuse 2 'new certificate is not currently valid' || return
  fi
  [ "$NEW_NA_EPOCH" -gt "$OLD_NA_EPOCH" ] || helper_refuse 3 'new certificate does not expire later than the current one' || return
  reason="$(ez_identity_compatible "$OLD_CN" "$OLD_NAMES" "$NEW_NAMES" "$NEW_IS_CA" "$NEW_SELF_SIGNED")" ||
    helper_refuse 2 "identity check failed: $reason" || return

  # A chain only replaces a PEM target and a chain is never reduced to a
  # single certificate (decisions above concern the leaf only).
  reason="$(ez_replacement_format_ok "$OLD_FORMAT" "$OLD_COUNT" "$NEW_FORMAT" "$NEW_COUNT")" ||
    helper_refuse 2 "certificate file format check failed (current $OLD_FORMAT/$OLD_COUNT, new $NEW_FORMAT/$NEW_COUNT): $reason" || return

  # Keep the encoding of the existing file (PEM stays PEM, DER stays DER); a
  # verified PEM chain is written byte for byte.
  helper_render_cert "$HELPER_TMP/new.in" "$NEW_FORMAT" "$NEW_COUNT" "$OLD_FORMAT" "$HELPER_TMP/new.out" ||
    helper_refuse 1 'cannot encode new certificate' || return
  ez_cert_inspect "$HELPER_TMP/new.out" && [ "$EZC_FP" = "$NEW_FP" ] && [ "$EZC_COUNT" = "$NEW_COUNT" ] ||
    helper_refuse 1 'encoded certificate verification failed' || return
  NEW_DIGEST="$(ez_file_digest "$HELPER_TMP/new.out")"
  ez_digest_ok "$NEW_DIGEST" && [ "$NEW_DIGEST" != "$OLD_DIGEST" ] ||
    helper_refuse 1 'cannot compute a valid SHA-256 of the new certificate' || return
  # A chain is written unchanged: the rendered bytes are the approved source.
  # (A single certificate may be re-encoded to the target's PEM/DER format.)
  if [ "$NEW_COUNT" -gt 1 ] && [ "$NEW_DIGEST" != "$source_digest" ]; then
    helper_refuse 1 'certificate chain was not preserved byte for byte' || return
  fi

  # 3. Transaction.  From here on the operation is completed (including any
  #    rollback) even if the caller disconnects.
  trap '' HUP INT TERM PIPE
  if ! helper_atomic_replace "$HELPER_TMP/new.out" "$OLD_DIGEST" "$T_ID"; then
    printf 'RESULT=FAILED\n'
    return 1
  fi
  NEW_ID="$INSTALLED_ID"
  if ! helper_verify_disk "$NEW_FP" "$NEW_DIGEST" "$NEW_ID"; then
    helper_undo 'post-install verification failed'
    return
  fi
  if [ "$A_KIND" = none ]; then
    printf 'RESULT=UPDATED\nOLD_FP=%s\nNEW_FP=%s\n' "$OLD_FP" "$NEW_FP"
    return 0
  fi

  # 4. The relation is proven again right before the restart.
  if ! helper_binding_check; then
    helper_undo 'service relation could not be confirmed again; no restart'
    return
  fi
  if helper_restart_once; then
    printf 'RESULT=UPDATED_RESTARTED\nOLD_FP=%s\nNEW_FP=%s\n' "$OLD_FP" "$NEW_FP"
    return 0
  fi

  # 5. Restart failed: restore exactly the previous certificate, verify it and
  #    restart exactly once with it.  Never more.
  helper_fail 'restart with the new certificate failed; rolling back'
  if ! helper_restore_old; then
    helper_fail "CRITICAL: previous certificate could not be restored: $A_TARGET"
    printf 'RESULT=ROLLBACK_FAILED\n'
    return 7
  fi
  if helper_restart_once; then
    printf 'RESULT=ROLLBACK\nFP=%s\n' "$OLD_FP"
    return 5
  fi
  helper_fail 'restart with the previous certificate failed too; manual action required'
  printf 'RESULT=ROLLBACK_RESTART_FAILED\nFP=%s\n' "$OLD_FP"
  return 6
}

op_schedule() {
  local day="$1" time="$2" when epoch now unit_file tmp

  printf '%s\n' "$day" | grep -E -q '^20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' || {
    helper_fail 'date must use YYYY-MM-DD'
    return 2
  }
  printf '%s\n' "$time" | grep -E -q '^([01][0-9]|2[0-3]):[0-5][0-9]$' || {
    helper_fail 'time must use HH:MM'
    return 2
  }
  when="$day $time:00"
  epoch="$(date -d "$when" '+%s' 2>/dev/null)" || { helper_fail 'invalid date/time'; return 2; }
  [ "$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S')" = "$when" ] || { helper_fail 'invalid or ambiguous local date/time'; return 2; }
  now="$(date '+%s')"
  [ "$epoch" -gt $((now + 60)) ] || { helper_fail 'scheduled time must be at least one minute in the future'; return 2; }
  [ "$epoch" -le $((now + 366 * 86400)) ] || { helper_fail 'scheduled time must be within one year'; return 2; }

  helper_systemd_ready || return 1
  helper_node_trusted "$(helper_fs "$HELPER_SYSTEMD_DIR")" d || {
    helper_fail "$HELPER_SYSTEMD_DIR is not a root-owned, non-writable directory"
    return 1
  }
  helper_node_trusted "$(helper_fs "$HELPER_SYSTEMD_DIR/$HELPER_SERVICE_UNIT")" f "$HELPER_TRUSTED_GID" || {
    helper_fail "$HELPER_SERVICE_UNIT is missing or not a root:root regular file without group/world write access; re-run the P1CERT installer"
    return 1
  }
  unit_file="$(helper_fs "$HELPER_SYSTEMD_DIR/$HELPER_TIMER_UNIT")"
  if [ -e "$unit_file" ] || [ -L "$unit_file" ]; then
    helper_node_trusted "$unit_file" f "$HELPER_TRUSTED_GID" || {
      helper_fail "existing $HELPER_TIMER_UNIT is not a root:root regular file without group/world write access; refusing to modify it"
      return 1
    }
  fi

  tmp="$(mktemp "$(helper_fs "$HELPER_SYSTEMD_DIR")/.itgo-p1cert-ezdrowie.XXXXXX")" || return 1
  # One-shot by construction: a fully specified calendar date elapses once.
  # Persistent=false: a run missed while the host was down is NOT caught up.
  if ! {
    printf '[Unit]\n'
    printf 'Description=ITGO P1CERT ezdrowie one-shot run of the accepted plan\n\n'
    printf '[Timer]\n'
    printf 'OnCalendar=%s\n' "$when"
    printf 'AccuracySec=1s\n'
    printf 'Persistent=false\n'
    printf 'Unit=%s\n\n' "$HELPER_SERVICE_UNIT"
    printf '[Install]\n'
    printf 'WantedBy=timers.target\n'
  } > "$tmp" || ! chmod 0644 "$tmp" || ! chown root:root "$tmp" || ! mv -f -T -- "$tmp" "$unit_file"; then
    rm -f -- "$tmp"
    helper_fail 'cannot write timer unit'
    return 1
  fi
  helper_systemctl daemon-reload || { helper_fail 'systemctl daemon-reload failed'; return 1; }
  # restart re-arms an already active timer with the new date.
  helper_systemctl enable "$HELPER_TIMER_UNIT" >/dev/null 2>&1 || { helper_fail 'cannot enable timer'; return 1; }
  helper_systemctl restart "$HELPER_TIMER_UNIT" || { helper_fail 'cannot start timer'; return 1; }
  printf 'RESULT=SCHEDULED\nSCHEDULED_AT=%s\nSCHEDULED_EPOCH=%s\n' "$when" "$epoch"
}

op_schedule_cancel() {
  local unit_file

  helper_systemd_ready || return 1
  unit_file="$(helper_fs "$HELPER_SYSTEMD_DIR/$HELPER_TIMER_UNIT")"
  # Disarming never depends on the unit file; removing it does.
  helper_systemctl disable --now "$HELPER_TIMER_UNIT" >/dev/null 2>&1 || true
  if [ -e "$unit_file" ] || [ -L "$unit_file" ]; then
    helper_node_trusted "$unit_file" f "$HELPER_TRUSTED_GID" || {
      helper_fail "$HELPER_TIMER_UNIT is not a root:root regular file without group/world write access; disabled but not removed"
      return 1
    }
    rm -f -- "$unit_file" || { helper_fail 'cannot remove timer unit'; return 1; }
  fi
  helper_systemctl daemon-reload || { helper_fail 'systemctl daemon-reload failed'; return 1; }
  printf 'RESULT=CANCELLED\n'
}


# --- Docker Compose applications (apply-docker, recover) -------------------
#
# One operation replaces the P1 certificate in ALL approved files of one
# compose application (PEM, DER, JKS, PKCS12) and restarts its systemd unit
# once.  Nothing the caller detected is trusted: the helper derives the
# compose configuration of the unit itself (unit, drop-ins and environment
# files must be root-controlled), requires every file to be referenced by
# that configuration (bind mount, secret or certificate variable), binds and
# reads the store passwords itself, checks the exact current bytes and the
# P1 entry of every file and the approved source bytes.  Files are written
# only with helper_atomic_replace (pinned directory, descriptor bound,
# original owner/mode/SELinux context).  A root-only journal records the
# operation before the first file changes, so that an interrupted operation
# (SIGKILL, power loss) is undone by "recover".

# Journal of Docker operations: root-only, holds the original bytes
# (keystores with encrypted private keys included) and the state.
HELPER_JOURNAL_PARENT=/var/lib/itgo-p1cert
HELPER_JOURNAL_DIR="$HELPER_JOURNAL_PARENT/ezdrowie-journal"
# Finished journals kept as root-only backups (oldest removed first).
HELPER_JOURNAL_KEEP=20
HELPER_DC_MAX_TARGETS=10
# PKCS12 tool shipped with P1CERT (java/P1certPkcs12.java) and its SHA-256;
# the installer refuses another file, the helper re-checks it before use.
HELPER_P12_JAR="$HELPER_DIR/p1cert-pkcs12.jar"
HELPER_P12_JAR_SHA256=8e439c107ace7e148153fb47a62ff3302ea5cf6d721413b57744aea16b762c9c
# Bytes read from a target (helper_read_entry); keystores may be larger
# than single certificates.
HELPER_READ_BS=""

# Java runtime 8+ for the PKCS12 tool, only from root-controlled locations
# (the resolved binary and every directory above it); never installed.
helper_java_find() {
  local c real major

  EZ_JAVA=""
  set +f
  for c in /usr/bin/java /usr/lib/jvm/*/bin/java /usr/lib/jvm/*/jre/bin/java /usr/java/*/bin/java; do
    set -f
    [ -e "$(helper_fs "$c")" ] || continue
    real="$(readlink -f -- "$(helper_fs "$c")" 2>/dev/null)" || continue
    real="${real#"$HELPER_FS_ROOT"}"
    helper_path_trusted "$real" || continue
    major="$(ez_java_major "$(helper_fs "$real")")" || continue
    [ "$major" -ge 8 ] || continue
    EZ_JAVA="$(helper_fs "$real")"
    set -f
    return 0
  done
  set -f
  return 1
}

# P1CERT_P12: OK (runtime and the integrity-checked tool), NO_JAVA, NO_JAR
# or BAD_JAR.  Sets EZ_JAVA and EZ_P12_TOOL for ez_p12_tool.
helper_p12_ready() {
  local jar

  EZ_P12_TOOL=""
  jar="$(helper_fs "$HELPER_P12_JAR")"
  if ! helper_node_trusted "$jar" f; then
    HELPER_P12_STATE=NO_JAR
    return 1
  fi
  if [ "$(ez_file_digest "$jar")" != "$HELPER_P12_JAR_SHA256" ]; then
    HELPER_P12_STATE=BAD_JAR
    return 1
  fi
  if ! helper_java_find; then
    HELPER_P12_STATE=NO_JAVA
    return 1
  fi
  EZ_P12_TOOL="$jar"
  HELPER_P12_STATE=OK
}

# A Docker target: allowed path without symlinks, a regular single-link file.
helper_dc_check_target() {
  local target="$1" fs

  ez_dc_target_path_ok "$target" || { helper_fail "not an allowed Docker target path: $target"; return 1; }
  ez_path_no_symlinks "$HELPER_FS_ROOT" "$target" || { helper_fail "target path contains a symlink: $target"; return 1; }
  fs="$(helper_fs "$target")"
  [ -f "$fs" ] && [ ! -L "$fs" ] || { helper_fail "target is not a regular file: $target"; return 1; }
  [ "$(helper_link_count "$fs")" = 1 ] || { helper_fail "target has multiple hard links, refusing: $target"; return 1; }
}

# Unit, drop-in and environment files of the unit decide the compose
# configuration: they must be root-controlled (as for the systemd binding).
helper_dc_unit_files_ok() {
  local props="$1" kind file fs

  while IFS=' ' read -r kind file; do
    [ -n "$file" ] || continue
    case "$kind:$file" in
      F:/etc/systemd/system/*|F:/usr/lib/systemd/system/*|F:/lib/systemd/system/*|F:/run/systemd/system/*|E:/*) ;;
      *) helper_fail "unexpected unit configuration path: $file"; return 1 ;;
    esac
    ez_path_chars_ok "$file" || { helper_fail "unsupported unit configuration path: $file"; return 1; }
    fs="$(helper_fs "$file")"
    if [ "$kind" = E ] && [ ! -e "$fs" ] && [ ! -L "$fs" ]; then
      helper_path_trusted "$file" parents || { helper_fail "directory of EnvironmentFile is not root-controlled: $file"; return 1; }
      continue
    fi
    helper_path_trusted "$file" || { helper_fail "unit configuration file or one of its directories is not root-controlled: $file"; return 1; }
  done <<EOF
$(ez_systemd_config_files "$props")
EOF
}

helper_dc_unit_show() {
  helper_systemctl show --no-pager -p LoadState -p ActiveState -p FragmentPath -p DropInPaths \
    -p WorkingDirectory -p ExecStart -p Environment -p EnvironmentFiles -- "$1" 2>/dev/null
}

# Derives the compose application run by <unit> (as discover does):
# H_PROPS, H_INPUT, H_ACTIVE, DCI_*, DCP_* and H_MODEL (ez_dc_model records).
# Refuses a unit that does not run compose unambiguously, a configuration
# with errors or ambiguous services, and a project in an "old" directory.
helper_dc_app() {
  local unit="$1" load fragment t a b c d

  H_PROPS="$(helper_dc_unit_show "$unit")" || { helper_fail "cannot inspect unit: $unit"; return 1; }
  load="$(printf '%s\n' "$H_PROPS" | sed -n 's/^LoadState=//p' | head -n 1)"
  fragment="$(printf '%s\n' "$H_PROPS" | sed -n 's/^FragmentPath=//p' | head -n 1)"
  H_ACTIVE="$(printf '%s\n' "$H_PROPS" | sed -n 's/^ActiveState=//p' | head -n 1)"
  [ "$load" = loaded ] || { helper_fail "unit is not loaded: $unit"; return 1; }
  case "$fragment" in
    /etc/systemd/system/*|/usr/lib/systemd/system/*|/lib/systemd/system/*) ;;
    *) helper_fail "unit file location is not allowed: ${fragment:-none}"; return 1 ;;
  esac
  helper_dc_unit_files_ok "$H_PROPS" || return 1
  ez_dc_invocation "$H_PROPS" || { helper_fail "unit $unit does not run docker compose"; return 1; }
  case "$DCI_VERSION" in
    v1|v2) ;;
    *) helper_fail "compose invocation of $unit cannot be analysed: ${DCI_ERR:-unknown}"; return 1 ;;
  esac
  [ -z "$DCI_ERR" ] || { helper_fail "compose invocation of $unit is ambiguous: $DCI_ERR"; return 1; }
  H_INPUT="$(ez_dc_unit_env_input "$H_PROPS" "$DCI_ASSIGN")"
  ez_dc_project "$HELPER_FS_ROOT" "$H_INPUT"
  [ -z "$DCP_ERR" ] && [ -n "$DCP_FILES" ] || { helper_fail "compose configuration of $unit is ambiguous: ${DCP_ERR:-no compose file}"; return 1; }
  ez_dc_path_ok "$DCP_PROJDIR" && ! ez_dc_path_in_old_dir "$DCP_PROJDIR/x" || {
    helper_fail "unsupported compose project directory: $DCP_PROJDIR"
    return 1
  }
  H_MODEL="$(ez_dc_model "$HELPER_FS_ROOT" "$H_INPUT" 2>/dev/null)"
  while IFS="$(printf '\034')" read -r t a b c d; do
    case "$t" in
      ERR) helper_fail "compose configuration of $unit cannot be analysed: $b"; return 1 ;;
      SERR) helper_fail "compose service $a of $unit is ambiguous: $b"; return 1 ;;
    esac
  done <<EOF
$H_MODEL
EOF
}

# No other unit may run the same compose project: the restart target must
# be unambiguous.  Only unit files mentioning compose are inspected.
helper_dc_single_unit() {
  local unit="$1" projdir="$2" dir file other props

  set +f
  for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    for file in "$(helper_fs "$dir")"/*.service; do
      set -f
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      other="${file##*/}"
      [ "$other" != "$unit" ] || continue
      ez_unit_name_ok "$other" && ! ez_unit_denied "$other" || continue
      grep -q -i compose -- "$file" 2>/dev/null || continue
      props="$(helper_dc_unit_show "$other")" || continue
      printf '%s\n' "$props" | grep -F -x -q 'LoadState=loaded' || continue
      ez_dc_invocation "$props" || continue
      case "$DCI_VERSION" in v1|v2) ;; *) continue ;; esac
      ez_dc_project "$HELPER_FS_ROOT" "$(ez_dc_unit_env_input "$props" "$DCI_ASSIGN")"
      if [ "$DCP_PROJDIR" = "$projdir" ]; then
        helper_fail "compose project $projdir is also run by $other; the restart target is ambiguous"
        set -f
        return 1
      fi
      set +f
    done
  done
  set -f
  return 0
}

# Services referencing <path> explicitly in H_MODEL:
# "svc<TAB>container-path<TAB>origin" lines.
helper_dc_refs() {
  local path="$1" t a b c d

  while IFS="$(printf '\034')" read -r t a b c d; do
    [ "$t" = REF ] && [ "$b" = "$path" ] || continue
    printf '%s\t%s\t%s\n' "$a" "$c" "$d"
  done <<EOF
$H_MODEL
EOF
}

# First line of a password file named by a NAME_FILE variable (host path
# from the model), read without following a symlink.
helper_dc_pw_file() {
  local path="$1" fs line

  ez_dc_path_ok "$path" && ez_path_no_symlinks "$HELPER_FS_ROOT" "$path" || return 1
  fs="$(helper_fs "$path")"
  helper_entry_meta "$fs" || return 1
  [ "$(stat -c '%s' -- "$fs" 2>/dev/null)" -le 4096 ] || return 1
  line="$(dd if="$fs" iflag=nofollow,nonblock,noctty bs=4096 count=1 2>/dev/null | head -n 1)"
  printf '%s' "${line%"$(printf '\r')"}"
}

# Binds and reads the password of keystore <path> exactly like discover
# (ez_dc_pw_stem/ez_dc_pw_base/ez_dc_pw_match over the password variables of
# the services that reference it): no reference may bind several variables,
# at least one must bind one, and all bound values must be equal.  Sets
# EZS_PASSWORD.
helper_dc_password() {
  local path="$1" svc cont origin t a b c d stem base cbase n cands bound="" value first=yes upper explicit=0 nl

  nl='
'
  EZS_PASSWORD=""
  [ -z "$DCI_ENVFILE" ] || explicit=1
  while IFS="$(printf '\t')" read -r svc cont origin; do
    [ -n "$svc" ] || continue
    cands=""
    if stem="$(ez_dc_pw_stem "$origin")"; then
      while IFS="$(printf '\034')" read -r t a b c d; do
        [ "$t" = PW ] && [ "$a" = "$svc" ] || continue
        upper="$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')"
        ! ez_dc_pw_match "$upper" "$c" "$stem" || cands="$cands$a|$b|$d$nl"
      done <<EOF
$H_MODEL
EOF
    fi
    if [ -z "$cands" ]; then
      base="$(ez_dc_pw_base "$path")"
      cbase="$(ez_dc_pw_base "$cont")"
      while IFS="$(printf '\034')" read -r t a b c d; do
        [ "$t" = PW ] && [ "$a" = "$svc" ] || continue
        upper="$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')"
        ez_dc_pw_match "$upper" "$c" "$base" suffix || ez_dc_pw_match "$upper" "$c" "$cbase" suffix ||
          continue
        cands="$cands$a|$b|$d$nl"
      done <<EOF
$H_MODEL
EOF
    fi
    # As discover (ez_dc_store_pw): a reference that binds no variable (a
    # mount next to the path variable) adds nothing; several are ambiguous.
    n="$(printf '%s' "$cands" | grep -c '|' || true)"
    [ "$n" -le 1 ] || { helper_fail "password of $path is not bound unambiguously for service $svc ($n candidates)"; return 1; }
    case "$bound" in *"$cands"*) ;; *) bound="$bound$cands" ;; esac
  done <<EOF
$(helper_dc_refs "$path")
EOF
  [ -n "$bound" ] || { helper_fail "no password bound to $path"; return 1; }
  while IFS='|' read -r svc b d; do
    [ -n "$svc" ] || continue
    case "$d" in
      '') value="$(ez_dc_secret "$HELPER_FS_ROOT" "$H_INPUT" "$DCP_ENVFILE" "$explicit" "$DCP_FILES" "$DCP_PROJDIR" "$svc" "$b")" || {
            helper_fail "password variable $b of service $svc cannot be read"
            return 1
          } ;;
      file:?*) value="$(helper_dc_pw_file "${d#file:}")" || { helper_fail "password file of $b cannot be read"; return 1; } ;;
      *) helper_fail "password file of $b is not mounted from the host"; return 1 ;;
    esac
    if [ "$first" = yes ]; then
      EZS_PASSWORD="$value"
      first=no
    elif [ "$value" != "$EZS_PASSWORD" ]; then
      value=""
      EZS_PASSWORD=""
      helper_fail "password variables bound to $path have different values"
      return 1
    fi
  done <<EOF
$bound
EOF
  value=""
  return 0
}

# --- journal -------------------------------------------------------------

helper_journal_root() {
  local dir

  helper_node_trusted "$(helper_fs /var)" d && helper_node_trusted "$(helper_fs /var/lib)" d || {
    helper_fail '/var/lib is not root-controlled; journal unavailable'
    return 1
  }
  for dir in "$HELPER_JOURNAL_PARENT" "$HELPER_JOURNAL_DIR"; do
    if [ ! -e "$(helper_fs "$dir")" ] && [ ! -L "$(helper_fs "$dir")" ]; then
      ( umask 077 && mkdir -- "$(helper_fs "$dir")" ) || return 1
    fi
    helper_node_trusted "$(helper_fs "$dir")" d || { helper_fail "journal directory is not root-controlled: $dir"; return 1; }
    chmod 0700 "$(helper_fs "$dir")" || return 1
  done
}

helper_journal_state() {
  printf '%s\n' "$2" > "$1/state.tmp" && mv -f -T -- "$1/state.tmp" "$1/state" && sync
}

# Journals not finished (any state but DONE, ROLLED_BACK, RECOVERED).
helper_journal_pending() {
  local root j state

  root="$(helper_fs "$HELPER_JOURNAL_DIR")"
  [ -d "$root" ] || return 0
  set +f
  for j in "$root"/*; do
    set -f
    [ -d "$j" ] && [ ! -L "$j" ] || continue
    state="$(head -n 1 -- "$j/state" 2>/dev/null)"
    case "$state" in
      DONE|ROLLED_BACK|RECOVERED) ;;
      *) printf '%s\n' "$j" ;;
    esac
  done
  set -f
}

# Keeps the newest HELPER_JOURNAL_KEEP finished journals.
helper_journal_prune() {
  local root n=0 j state

  root="$(helper_fs "$HELPER_JOURNAL_DIR")"
  [ -d "$root" ] || return 0
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    state="$(head -n 1 -- "$root/$j/state" 2>/dev/null)"
    case "$state" in
      DONE|ROLLED_BACK|RECOVERED) n=$((n + 1)); [ "$n" -le "$HELPER_JOURNAL_KEEP" ] || rm -rf -- "${root:?}/$j" ;;
    esac
  done <<EOF
$(ls -1 -- "$root" 2>/dev/null | grep -E '^[0-9]{14}-[0-9]+$' | LC_ALL=C sort -r)
EOF
}

# --- one file of the operation (HT_* arrays) -----------------------------

# Installs <content> as target <i> when it still holds <expect-sha> as the
# entry <expect-id> (helper_atomic_replace with the original owner, group,
# mode and SELinux context) and checks the bytes on disk.  HT_ID[i] becomes
# the installed entry.
helper_dc_install() {
  local i="$1" content="$2" expect="$3" expect_id="$4" want

  helper_pin_target_dir "${HT_PATH[$i]}" || return 1
  T_UID="${HT_UID[$i]}"; T_GID="${HT_GID[$i]}"; T_MODE="${HT_MODE[$i]}"; T_CONTEXT="${HT_CTX[$i]}"
  helper_atomic_replace "$content" "$expect" "$expect_id" || return 1
  HT_ID[$i]="$INSTALLED_ID"
  want="$(ez_file_digest "$content")"
  helper_read_entry "$T_NAME" "$INSTALLED_ID" "$HELPER_TMP/installed" &&
    [ "$(ez_file_digest "$HELPER_TMP/installed")" = "$want" ]
}

# Content check of target <i> on disk after the commit.
helper_dc_verify() {
  local i="$1" copy="$HELPER_TMP/verify-$1" rc=0

  helper_pin_target_dir "${HT_PATH[$i]}" &&
    helper_read_entry "$T_NAME" "${HT_ID[$i]}" "$copy" &&
    [ "$(ez_file_digest "$copy")" = "${HT_NEWSHA[$i]}" ] || return 1
  case "${HT_TYPE[$i]}" in
    PEM|DER)
      ez_cert_inspect "$copy" && [ "$EZC_FP" = "$H_NEWFP" ] && [ "$EZC_FORMAT" = "${HT_TYPE[$i]}" ]
      ;;
    *)
      EZS_PASSWORD="${HT_PW[$i]}"
      ez_dc_verify_store "$copy" "${HT_TYPE[$i]}" "${HT_ALIAS[$i]}" "$H_NEWFP" "${HT_EXPECT[$i]}" "$H_J/old-$i" || rc=1
      EZS_PASSWORD=""
      return "$rc"
      ;;
  esac
}

# Puts the original bytes back into every committed target (newest first).
# 0 all restored and verified, 1 at least one could not be restored.
helper_dc_rollback() {
  local i rc=0

  i=$((HT_COUNT - 1))
  while [ "$i" -ge 0 ]; do
    if [ "${HT_STATE[$i]}" = committed ]; then
      if helper_dc_install "$i" "$H_J/old-$i" "${HT_NEWSHA[$i]}" "${HT_ID[$i]}"; then
        HT_STATE[$i]=restored
      else
        helper_fail "CRITICAL: original bytes of ${HT_PATH[$i]} could not be restored (copy: $HELPER_JOURNAL_DIR/${H_J##*/}/old-$i)"
        rc=1
      fi
    fi
    i=$((i - 1))
  done
  return "$rc"
}

# --- restart and its verification ------------------------------------------

# Services of H_MODEL (SVC records), space separated; 1 when a name has
# characters compose labels cannot be compared with safely.
helper_dc_model_services() {
  local t a b c d out=""

  while IFS="$(printf '\034')" read -r t a b c d; do
    [ "$t" = SVC ] || continue
    printf '%s\n' "$a" | grep -E -x -q '[A-Za-z0-9][A-Za-z0-9_.-]{0,127}' || return 1
    out="${out:+$out }$a"
  done <<EOF
$H_MODEL
EOF
  printf '%s' "$out"
}

# Inspects container <id> of compose project <projdir>: C_RUNNING,
# C_RESTARTING, C_EPOCH (StartedAt), C_CODE, C_HEALTH, C_SVC.  Fails for an
# unexpected id, label or date.
helper_dc_container() {
  local id="$1" projdir="$2" info started label

  printf '%s\n' "$id" | grep -E -q '^[0-9a-f]{64}$' || return 1
  info="$(helper_docker inspect --type container --format \
    '{{.State.Running}}|{{.State.Restarting}}|{{.State.StartedAt}}|{{.State.ExitCode}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}' \
    "$id" 2>/dev/null)" || return 1
  IFS='|' read -r C_RUNNING C_RESTARTING started C_CODE C_HEALTH label C_SVC <<EOF
$info
EOF
  [ "$label" = "$projdir" ] || return 1
  C_EPOCH="$(date -u -d "$started" '+%s' 2>/dev/null)" || return 1
}

helper_dc_project_ids() {
  helper_docker ps -a -q --no-trunc --filter "label=com.docker.compose.project.working_dir=$1" 2>/dev/null
}

# Services out of <services> that have a running container of the project
# now (space separated).  1 when docker cannot be read.
helper_dc_running_services() {
  local projdir="$1" services="$2" ids id out=""

  ids="$(helper_dc_project_ids "$projdir")" || return 1
  for id in $ids; do
    helper_dc_container "$id" "$projdir" || return 1
    [ "$C_RUNNING" = true ] || continue
    case " $services " in *" $C_SVC "*) ;; *) continue ;; esac
    case " $out " in *" $C_SVC "*) ;; *) out="${out:+$out }$C_SVC" ;; esac
  done
  printf '%s' "$out"
}

# True when a container of the project was started at or after <epoch>
# (it may have loaded files changed by the operation).
helper_dc_started_since() {
  local projdir="$1" epoch="$2" ids id

  ids="$(helper_dc_project_ids "$projdir")" || return 0
  for id in $ids; do
    helper_dc_container "$id" "$projdir" || return 0
    [ "$C_EPOCH" -lt "$epoch" ] || return 0
  done
  return 1
}

# The project after a restart started at <since>: every service of
# <services> (the services that ran before the operation) runs again in a
# container (re)started after <since>, not restarting and not unhealthy (a
# health check still "starting" is waited for); a stopped container of such
# a service only when it exited 0 after <since>.  Containers of other
# services (not running before, orphans, inactive profiles) are not judged.
# 0 ok, 1 not (yet).
helper_dc_containers_ok() {
  local projdir="$1" since="$2" services="$3" ids id seen=" " svc

  [ -n "$services" ] || return 1
  ids="$(helper_dc_project_ids "$projdir")" || return 1
  for id in $ids; do
    helper_dc_container "$id" "$projdir" || return 1
    case " $services " in *" $C_SVC "*) ;; *) continue ;; esac
    if [ "$C_RUNNING" = true ]; then
      [ "$C_RESTARTING" = false ] && [ "$C_EPOCH" -ge "$since" ] || return 1
      case "$C_HEALTH" in healthy|none) ;; *) return 1 ;; esac
      seen="$seen$C_SVC "
    else
      [ "$C_CODE" = 0 ] && [ "$C_EPOCH" -ge "$since" ] || return 1
    fi
  done
  for svc in $services; do
    case "$seen" in *" $svc "*) ;; *) return 1 ;; esac
  done
}

# One restart of the unit: systemctl restart, the unit stays active
# (helper_wait_systemd_active) and the services that ran before really run
# again (the exit code of systemctl alone proves nothing for "docker compose
# up -d").
helper_dc_restart() {
  local unit="$1" projdir="$2" services="$3" since waited=0

  since="$(date -u '+%s')"
  helper_info "systemctl restart $unit"
  helper_systemctl restart -- "$unit" || return 1
  helper_wait_systemd_active "$unit" || { helper_fail "$unit did not stay active after the restart"; return 1; }
  while [ "$waited" -le "$HELPER_WAIT_SECONDS" ]; do
    helper_dc_containers_ok "$projdir" "$since" "$services" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  helper_fail "services $services of $projdir were not restarted or do not run correctly after restarting $unit"
  return 1
}

# True when the copy of target <i> already holds the new P1 certificate
# (H_NEWFP): the certificate itself, or the P1 entry of the store opened with
# its configured password.
helper_dc_is_current() {
  local i="$1" copy="$HELPER_TMP/old-$1" rc=1

  case "${HT_TYPE[$i]}" in
    PEM|DER) ez_cert_inspect "$copy" && [ "$EZC_FP" = "$H_NEWFP" ] ;;
    *)
      helper_dc_password "${HT_PATH[$i]}" 2>/dev/null || { EZS_PASSWORD=""; return 1; }
      if ez_store_open "$copy" "${HT_TYPE[$i]}" yes; then
        ez_store_p1
        [ "$EZS_P1" = PEWNA ] && [ "${ES_ALIAS[$EZS_P1_ROW]}" = "${HT_ALIAS[$i]}" ] &&
          [ "${ES_FP[$EZS_P1_ROW]}" = "$H_NEWFP" ] && rc=0
      fi
      EZS_PASSWORD=""
      return "$rc"
      ;;
  esac
}

# --- apply-docker ------------------------------------------------------------

helper_dc_result() {
  printf 'RESULT=%s\nUNIT_STATE_BEFORE=%s\nJOURNAL=%s\n' "$1" "${H_ACTIVE:-unknown}" "${H_J##*/}"
}

helper_dc_finish() {
  local i=0

  while [ "$i" -lt "${HT_COUNT:-0}" ]; do
    HT_PW[$i]=""
    i=$((i + 1))
  done
  EZS_PASSWORD=""
}


# helper_apply_docker <unit> <restart yes|no> <source-sha256> <new-fp>
#                     <path|type|old-file-sha256|old-fp|alias>...
# The new certificate (exactly the approved source bytes) is read from stdin.
# Prints RESULT=, UNIT_STATE_BEFORE=, JOURNAL= and exits with the codes of
# helper_apply (0 UPDATED/UPDATED_RESTARTED/NO_CHANGE, 1 FAILED, 2/3
# REFUSED, 4 RESTORED, 5 ROLLBACK, 6 ROLLBACK_RESTART_FAILED, 7
# ROLLBACK_FAILED) and 8 PENDING_RECOVERY (an interrupted operation must be
# recovered first).
helper_apply_docker() {
  local unit="$1" restart="$2" src_sha="$3" now i spec path type sha fp alias reason rc props
  local seen=" " names cn na nochange=0

  H_NEWFP="$(helper_norm_fp "$4")"
  shift 4
  H_J=""; H_ACTIVE=""; HT_COUNT=0
  HT_PATH=(); HT_TYPE=(); HT_OLDSHA=(); HT_OLDFP=(); HT_ALIAS=(); HT_ID=(); HT_UID=(); HT_GID=(); HT_MODE=(); HT_CTX=()
  HT_NEWSHA=(); HT_EXPECT=(); HT_STATE=(); HT_PW=()
  HELPER_READ_BS="$EZ_DC_MAX_STORE_BYTES"

  # 1. Request syntax.
  ez_unit_name_ok "$unit" && ! ez_unit_denied "$unit" || helper_refuse 2 "invalid or not allowed unit: $unit" || return
  case "$restart" in yes|no) ;; *) helper_refuse 2 'restart must be yes or no' || return ;; esac
  ez_digest_ok "$src_sha" && ez_fp_ok "$H_NEWFP" || helper_refuse 2 'invalid source SHA-256 or fingerprint' || return
  [ "$#" -ge 1 ] && [ "$#" -le "$HELPER_DC_MAX_TARGETS" ] || helper_refuse 2 'invalid number of targets' || return
  for spec in "$@"; do
    ez_dc_target_spec_ok "$spec" || helper_refuse 2 "invalid target specification: $spec" || return
    IFS='|' read -r path type sha fp alias <<EOF
$spec
EOF
    case "$seen" in *" $path "*) helper_refuse 2 "target given twice: $path" || return ;; esac
    seen="$seen$path "
    fp="$(helper_norm_fp "$fp")"
    [ "$fp" != "$H_NEWFP" ] || helper_refuse 2 "old and new fingerprints are identical: $path" || return
    HT_PATH[$HT_COUNT]="$path"; HT_TYPE[$HT_COUNT]="$type"; HT_OLDSHA[$HT_COUNT]="$sha"; HT_OLDFP[$HT_COUNT]="$fp"
    HT_ALIAS[$HT_COUNT]="$alias"; HT_STATE[$HT_COUNT]=prepared; HT_PW[$HT_COUNT]=""
    HT_COUNT=$((HT_COUNT + 1))
  done
  helper_lock || helper_refuse 1 'cannot serialize the operation' || return
  helper_journal_root || helper_refuse 1 'journal unavailable' || return
  if [ -n "$(helper_journal_pending)" ]; then
    helper_fail 'an interrupted Docker operation is not recovered yet; run "p1cert ezdrowie recover" first'
    printf 'RESULT=PENDING_RECOVERY\n'
    return 8
  fi
  helper_systemd_ready || helper_refuse 1 'systemd unavailable' || return
  helper_tmpdir || { printf 'RESULT=FAILED\n'; return 1; }

  # 2. The application, derived from the unit by the helper itself.
  helper_dc_app "$unit" || helper_refuse 2 "the compose application of $unit cannot be verified" || return
  helper_dc_single_unit "$unit" "$DCP_PROJDIR" || helper_refuse 2 'restart target is ambiguous' || return
  # helper_dc_single_unit changes DCI_*/DCP_*: derive the application again.
  helper_dc_app "$unit" || helper_refuse 2 "the compose application of $unit cannot be verified" || return
  props="$H_PROPS"
  # The state decides the restart: a unit in transition (starting,
  # stopping, reloading) is not guessed about.
  case "$H_ACTIVE" in
    active|inactive|failed) ;;
    *) helper_refuse 2 "unit $unit is in state ${H_ACTIVE:-unknown}; nothing changed, run again later" || return ;;
  esac
  H_SERVICES=""
  if [ "$restart" = yes ] && [ "$H_ACTIVE" = active ]; then
    helper_docker_ready || helper_refuse 1 'Docker unavailable: the restart could not be verified' || return
    # The services running now must run again after the restart.
    names="$(helper_dc_model_services)" || helper_refuse 2 'compose service names cannot be verified' || return
    H_SERVICES="$(helper_dc_running_services "$DCP_PROJDIR" "$names")" ||
      helper_refuse 1 'containers of the project cannot be inspected: the restart could not be verified' || return
    [ -n "$H_SERVICES" ] ||
      helper_refuse 2 "$unit is active but no container of $DCP_PROJDIR runs; the restart could not be verified" || return
  fi

  # 3. The approved source bytes.
  now="$(date -u '+%s')"
  helper_read_stdin_cert "$HELPER_TMP/new.in" || helper_refuse 2 'invalid certificate on stdin' || return
  [ "$(ez_file_digest "$HELPER_TMP/new.in")" = "$src_sha" ] ||
    helper_refuse 2 'new source file differs from the approved one (SHA-256)' || return
  ez_cert_inspect "$HELPER_TMP/new.in"
  rc=$?
  [ "$rc" -eq 0 ] || helper_refuse 2 "new certificate is neither a single X.509 certificate nor a valid PEM chain (code $rc)" || return
  ez_cert_save NEW
  [ "$NEW_FP" = "$H_NEWFP" ] || helper_refuse 2 "new certificate fingerprint $NEW_FP differs from the expected $H_NEWFP" || return
  if [ "$NEW_NB_EPOCH" -gt "$now" ] || [ "$NEW_NA_EPOCH" -le "$now" ]; then
    helper_refuse 2 'new certificate is not currently valid' || return
  fi

  # 4. Every file: referenced by the application, exactly the approved bytes
  #    and P1 entry, new content prepared and verified (root-private copies).
  i=0
  while [ "$i" -lt "$HT_COUNT" ]; do
    path="${HT_PATH[$i]}"
    helper_dc_check_target "$path" || helper_refuse 2 "invalid target: $path" || return
    [ -n "$(helper_dc_refs "$path")" ] ||
      helper_refuse 2 "$path is not referenced by the compose configuration of $unit (mount, secret or certificate variable)" || return
    helper_enter_target_dir "$path" || helper_refuse 2 "unsafe target directory: $path" || return
    HT_ID[$i]="$T_ID"; HT_UID[$i]="$T_UID"; HT_GID[$i]="$T_GID"; HT_MODE[$i]="$T_MODE"; HT_CTX[$i]="$T_CONTEXT"
    helper_read_entry "$T_NAME" "$T_ID" "$HELPER_TMP/old-$i" || helper_refuse 2 "cannot read $path" || return
    [ "$(ez_store_type "$HELPER_TMP/old-$i")" = "${HT_TYPE[$i]}" ] ||
      helper_refuse 2 "$path is not a ${HT_TYPE[$i]} file" || return
    if [ "$(ez_file_digest "$HELPER_TMP/old-$i")" != "${HT_OLDSHA[$i]}" ]; then
      # Other bytes: fine only when the file already holds the new P1
      # certificate (a second run of the same plan); anything else is a
      # change since the plan.
      if helper_dc_is_current "$i"; then
        nochange=$((nochange + 1))
        HT_STATE[$i]=current
        i=$((i + 1))
        continue
      fi
      helper_refuse 3 "current bytes of $path differ from the approved plan" || return
    fi
    case "${HT_TYPE[$i]}" in
      PEM|DER)
        ez_cert_inspect "$HELPER_TMP/old-$i" || helper_refuse 2 "$path is not a single certificate or valid chain" || return
        ez_cert_save OLD
        [ "$OLD_FP" = "${HT_OLDFP[$i]}" ] || {
          if [ "$OLD_FP" = "$H_NEWFP" ]; then
            nochange=$((nochange + 1))
            HT_STATE[$i]=current
            i=$((i + 1))
            continue
          fi
          helper_refuse 3 "certificate in $path differs from the approved plan" || return
        }
        reason="$(ez_identity_compatible "$OLD_CN" "$OLD_NAMES" "$NEW_NAMES" "$NEW_IS_CA" "$NEW_SELF_SIGNED")" ||
          helper_refuse 2 "$path: identity check failed: $reason" || return
        [ "$NEW_NA_EPOCH" -gt "$OLD_NA_EPOCH" ] || helper_refuse 3 "$path: new certificate does not expire later" || return
        reason="$(ez_replacement_format_ok "$OLD_FORMAT" "$OLD_COUNT" "$NEW_FORMAT" "$NEW_COUNT")" ||
          helper_refuse 2 "$path: $reason" || return
        helper_render_cert "$HELPER_TMP/new.in" "$NEW_FORMAT" "$NEW_COUNT" "$OLD_FORMAT" "$HELPER_TMP/new-$i" ||
          helper_refuse 1 "$path: cannot encode the new certificate" || return
        ez_cert_inspect "$HELPER_TMP/new-$i" && [ "$EZC_FP" = "$NEW_FP" ] && [ "$EZC_COUNT" = "$NEW_COUNT" ] ||
          helper_refuse 1 "$path: encoded certificate verification failed" || return
        ;;
      JKS|PKCS12)
        if [ "${HT_TYPE[$i]}" = PKCS12 ] && ! helper_p12_ready; then
          helper_refuse 2 "$path: PKCS12 needs a Java 8+ runtime and the verified PKCS12 tool ($HELPER_P12_STATE); P1CERT never installs Java" || return
        fi
        helper_dc_password "$path" || helper_refuse 2 "$path: store password cannot be bound from the configuration" || return
        HT_PW[$i]="$EZS_PASSWORD"
        ez_store_open "$HELPER_TMP/old-$i" "${HT_TYPE[$i]}" yes || true
        ez_store_p1
        if [ "$EZS_STATUS" != OK ] || [ "$EZS_P1" != PEWNA ] || [ "${ES_ALIAS[$EZS_P1_ROW]}" != "${HT_ALIAS[$i]}" ]; then
          helper_dc_finish
          helper_refuse 3 "$path: store does not open with its configured password or has no unambiguous P1 entry ${HT_ALIAS[$i]}" || return
        fi
        if [ "${ES_FP[$EZS_P1_ROW]}" != "${HT_OLDFP[$i]}" ]; then
          helper_dc_finish
          helper_refuse 3 "$path: P1 entry differs from the approved plan" || return
        fi
        names="${ES_NAMES[$EZS_P1_ROW]}"; cn=""
        na="$(ez_to_epoch "${ES_NOT_AFTER[$EZS_P1_ROW]}")"
        reason="$(ez_identity_compatible "$cn" "$names" "$NEW_NAMES" "$NEW_IS_CA" "$NEW_SELF_SIGNED")" || {
          helper_dc_finish
          helper_refuse 2 "$path: identity check failed: $reason" || return
        }
        ez_epoch_ok "$na" && [ "$NEW_NA_EPOCH" -gt "$na" ] || { helper_dc_finish; helper_refuse 3 "$path: new certificate does not expire later" || return; }
        if ! ez_dc_stage_store "$HELPER_TMP/old-$i" "${HT_TYPE[$i]}" "${HT_ALIAS[$i]}" "${HT_OLDFP[$i]}" \
          "$HELPER_TMP/new.in" "$NEW_FORMAT" "$H_NEWFP" "$HELPER_TMP/new-$i"; then
          helper_dc_finish
          helper_refuse 2 "$path: $EZDS_REASON" || return
        fi
        HT_EXPECT[$i]="$EZDS_EXPECT"
        EZS_PASSWORD=""
        ;;
    esac
    HT_NEWSHA[$i]="$(ez_file_digest "$HELPER_TMP/new-$i")"
    i=$((i + 1))
  done
  if [ "$nochange" -eq "$HT_COUNT" ]; then
    helper_dc_finish
    helper_dc_result NO_CHANGE
    return 0
  fi
  [ "$nochange" -eq 0 ] || { helper_dc_finish; helper_refuse 3 'some files already hold the new certificate; create a new plan' || return; }

  # 5. Journal, written and synced before the first file changes.
  H_J="$(helper_fs "$HELPER_JOURNAL_DIR")/$(date '+%Y%m%d%H%M%S')-$$"
  if ! ( umask 077 && mkdir -- "$H_J" ); then
    helper_dc_finish
    helper_refuse 1 'cannot create the journal' || return
  fi
  {
    printf 'UNIT=%s\nPROJECT_DIR=%s\nUNIT_STATE_BEFORE=%s\nRESTART=%s\nSERVICES=%s\nSTARTED=%s\nNEW_FP=%s\nCOUNT=%s\n' \
      "$unit" "$DCP_PROJDIR" "$H_ACTIVE" "$restart" "$H_SERVICES" "$now" "$H_NEWFP" "$HT_COUNT"
    i=0
    while [ "$i" -lt "$HT_COUNT" ]; do
      printf 'TARGET_%s=%s|%s|%s|%s\n' "$i" "${HT_PATH[$i]}" "${HT_TYPE[$i]}" "${HT_OLDSHA[$i]}" "${HT_NEWSHA[$i]}"
      i=$((i + 1))
    done
  } > "$H_J/manifest" || { helper_dc_finish; helper_refuse 1 'cannot write the journal' || return; }
  i=0
  while [ "$i" -lt "$HT_COUNT" ]; do
    cp -- "$HELPER_TMP/old-$i" "$H_J/old-$i" && cp -- "$HELPER_TMP/new-$i" "$H_J/new-$i" &&
      [ "$(ez_file_digest "$H_J/old-$i")" = "${HT_OLDSHA[$i]}" ] || { helper_dc_finish; helper_refuse 1 'cannot write the journal' || return; }
    i=$((i + 1))
  done
  chmod 0600 "$H_J"/* 2>/dev/null
  helper_journal_state "$H_J" PREPARED || { helper_dc_finish; helper_refuse 1 'cannot write the journal' || return; }

  # 6. Commit.  From here on the operation completes (including any
  #    rollback) even if the caller disconnects.
  trap '' HUP INT TERM PIPE
  helper_journal_state "$H_J" COMMITTING
  i=0
  while [ "$i" -lt "$HT_COUNT" ]; do
    if ! helper_dc_install "$i" "$H_J/new-$i" "${HT_OLDSHA[$i]}" "${HT_ID[$i]}"; then
      helper_fail "replacement of ${HT_PATH[$i]} failed"
      # A failed rename leaves the original; installed but wrong bytes are
      # undone with the others.
      [ -z "$INSTALLED_ID" ] || HT_STATE[$i]=committed
      helper_journal_state "$H_J" ROLLING_BACK
      if helper_dc_rollback; then
        helper_journal_state "$H_J" ROLLED_BACK
        helper_dc_finish
        helper_dc_result RESTORED
        return 4
      fi
      helper_journal_state "$H_J" FAILED
      helper_dc_finish
      helper_dc_result ROLLBACK_FAILED
      return 7
    fi
    HT_STATE[$i]=committed
    i=$((i + 1))
  done
  helper_journal_state "$H_J" COMMITTED
  i=0
  while [ "$i" -lt "$HT_COUNT" ]; do
    if ! helper_dc_verify "$i"; then
      helper_fail "verification of ${HT_PATH[$i]} on disk failed; restoring all files"
      helper_journal_state "$H_J" ROLLING_BACK
      if helper_dc_rollback; then
        helper_journal_state "$H_J" ROLLED_BACK
        helper_dc_finish
        helper_dc_result RESTORED
        return 4
      fi
      helper_journal_state "$H_J" FAILED
      helper_dc_finish
      helper_dc_result ROLLBACK_FAILED
      return 7
    fi
    i=$((i + 1))
  done
  helper_dc_finish

  # 7. Restart: only the unit of this application, only when it was running
  #    and the operator approved it; never a stopped unit.
  if [ "$restart" != yes ] || [ "$H_ACTIVE" != active ]; then
    helper_journal_state "$H_J" DONE
    helper_journal_prune
    helper_dc_result UPDATED
    return 0
  fi
  if [ "$(helper_dc_unit_show "$unit")" != "$props" ]; then
    helper_fail "unit $unit changed during the operation; no restart, restoring all files"
    helper_journal_state "$H_J" ROLLING_BACK
    if helper_dc_rollback; then
      helper_journal_state "$H_J" ROLLED_BACK
      helper_dc_result RESTORED
      return 4
    fi
    helper_journal_state "$H_J" FAILED
    helper_dc_result ROLLBACK_FAILED
    return 7
  fi
  # From here on the containers may run with the new files: "recover"
  # restarts the unit once after restoring them.
  : > "$H_J/restarted" && helper_journal_state "$H_J" RESTARTING
  if helper_dc_restart "$unit" "$DCP_PROJDIR" "$H_SERVICES"; then
    helper_journal_state "$H_J" DONE
    helper_journal_prune
    helper_dc_result UPDATED_RESTARTED
    return 0
  fi
  helper_fail 'restart with the new certificate failed; restoring all files'
  helper_journal_state "$H_J" ROLLING_BACK
  if ! helper_dc_rollback; then
    helper_journal_state "$H_J" FAILED
    helper_dc_result ROLLBACK_FAILED
    return 7
  fi
  if helper_dc_restart "$unit" "$DCP_PROJDIR" "$H_SERVICES"; then
    helper_journal_state "$H_J" ROLLED_BACK
    helper_dc_result ROLLBACK
    return 5
  fi
  helper_journal_state "$H_J" ROLLED_BACK
  helper_fail 'restart with the original files failed too; manual action required'
  helper_dc_result ROLLBACK_RESTART_FAILED
  return 6
}

# --- recover -----------------------------------------------------------------

# Undoes every unfinished Docker operation from its journal: a file that
# holds the new bytes gets its original bytes back, a file with the original
# bytes stays, a file with any other bytes is NOT touched (critical, manual
# action).  When files were restored, the containers may have loaded the new
# files (the restart of the operation had begun, or a container started
# after the operation began: reboot, restart policy) and the unit is running
# now, it is restarted once (and verified) - only when the operator had
# approved the restart and the unit was running before the operation; a unit
# that is not running is never started, an unapproved restart is only
# reported.  Prints RECOVERY=NONE or one RECOVERY=RECOVERED|<id>|<detail> /
# RECOVERY=FAILED|<id>|<detail> line per operation; exit 0 or 7 (at least
# one failed).
op_recover() {
  local j id state line key value unit projdir before restart services started count i path type old new cur restored failed detail loaded rc=0 any=no

  helper_lock || return 1
  helper_journal_root || return 1
  helper_tmpdir || return 1
  HELPER_READ_BS="$EZ_DC_MAX_STORE_BYTES"
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    any=yes
    id="${j##*/}"
    state="$(head -n 1 -- "$j/state" 2>/dev/null)"
    unit=""; projdir=""; before=""; restart=no; services=""; started=""; count=0
    HT_COUNT=0; HT_PATH=(); HT_TYPE=(); HT_OLDSHA=(); HT_NEWSHA=(); HT_ID=(); HT_UID=(); HT_GID=(); HT_MODE=(); HT_CTX=(); HT_STATE=()
    while IFS= read -r line; do
      key="${line%%=*}"; value="${line#*=}"
      case "$key" in
        UNIT) unit="$value" ;;
        PROJECT_DIR) projdir="$value" ;;
        UNIT_STATE_BEFORE) before="$value" ;;
        RESTART) restart="$value" ;;
        SERVICES) services="$value" ;;
        STARTED) started="$value" ;;
        COUNT) count="$value" ;;
        TARGET_*)
          i="${key#TARGET_}"
          IFS='|' read -r path type old new <<EOF
$value
EOF
          HT_PATH[$i]="$path"; HT_TYPE[$i]="$type"; HT_OLDSHA[$i]="$old"; HT_NEWSHA[$i]="$new"; HT_STATE[$i]=unknown
          ;;
      esac
    done < "$j/manifest"
    H_J="$j"
    restored=0; failed=""
    i=0
    while [ "$i" -lt "$count" ]; do
      path="${HT_PATH[$i]:-}"
      if [ -z "$path" ] || ! ez_dc_target_path_ok "$path" || ! helper_enter_target_dir "$path"; then
        failed="${failed:+$failed, }${path:-?}"
        i=$((i + 1))
        continue
      fi
      HT_ID[$i]="$T_ID"; HT_UID[$i]="$T_UID"; HT_GID[$i]="$T_GID"; HT_MODE[$i]="$T_MODE"; HT_CTX[$i]="$T_CONTEXT"
      cur=""
      ! helper_read_entry "$T_NAME" "$T_ID" "$HELPER_TMP/recover-$i" || cur="$(ez_file_digest "$HELPER_TMP/recover-$i")"
      if [ "$cur" = "${HT_OLDSHA[$i]}" ]; then
        :
      elif [ "$cur" = "${HT_NEWSHA[$i]}" ] && helper_dc_install "$i" "$j/old-$i" "${HT_NEWSHA[$i]}" "${HT_ID[$i]}"; then
        restored=$((restored + 1))
      else
        failed="${failed:+$failed, }$path"
      fi
      i=$((i + 1))
    done
    HT_COUNT="$count"
    if [ -n "$failed" ]; then
      helper_journal_state "$j" FAILED
      printf 'RECOVERY=FAILED|%s|%s: original bytes NOT restored: %s (copies in %s)\n' "$id" "$unit" "$failed" "$HELPER_JOURNAL_DIR/$id"
      rc=7
      continue
    fi
    detail="$unit: state $state, $restored file(s) restored"
    if [ "$restored" -gt 0 ]; then
      # Could the running containers hold the new files?
      loaded=no
      if [ -e "$j/restarted" ]; then
        loaded=yes
      elif ! ez_epoch_ok "$started" || ! helper_docker_ready || helper_dc_started_since "$projdir" "$started"; then
        loaded=maybe
      fi
      if [ "$loaded" = no ]; then
        detail="$detail, containers were not restarted during the operation (no restart needed)"
      elif ! helper_systemctl is-active --quiet -- "$unit" 2>/dev/null; then
        detail="$detail, $unit is not running and was not started"
      elif [ "$restart" != yes ] || [ "$before" != active ] || [ -z "$services" ]; then
        detail="$detail, containers may have loaded the new files; restart of $unit not approved - restart it manually"
      elif helper_docker_ready && helper_dc_restart "$unit" "$projdir" "$services"; then
        detail="$detail, $unit restarted with the original files"
      else
        detail="$detail, restart of $unit with the original files FAILED - manual check required"
        rc=7
      fi
    fi
    helper_journal_state "$j" RECOVERED
    printf 'RECOVERY=RECOVERED|%s|%s\n' "$id" "$detail"
  done <<EOF
$(helper_journal_pending | LC_ALL=C sort)
EOF
  [ "$any" = yes ] || printf 'RECOVERY=NONE\n'
  return "$rc"
}

helper_dispatch() {
  local op="${1:-}"

  [ "$#" -gt 0 ] && shift
  case "$op:$#" in
    ping:0) op_ping ;;
    find-candidates:0) op_find_candidates ;;
    read:1) op_read "$1" ;;
    apply:5) helper_apply none "$1" "$2" "$3" "$4" "$5" ;;
    apply-systemd:6) helper_apply systemd "$1" "$2" "$3" "$4" "$5" "$6" ;;
    apply-compose:7) helper_apply compose "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
    apply-docker:[5-9]|apply-docker:1[0-4]) helper_apply_docker "$@" ;;
    recover:0) op_recover ;;
    schedule:2) op_schedule "$1" "$2" ;;
    schedule-cancel:0) op_schedule_cancel ;;
    *)
      helper_fail 'unsupported operation or wrong number of arguments'
      return 2
      ;;
  esac
}

helper_main() {
  local rc

  helper_require_root || return 1
  helper_self_check || return 1
  helper_load_lib || return 1
  # Helper and root library are installed together; a mix of two releases
  # (partial upgrade) is refused.
  [ "${EZ_LIB_API:-}" = "$HELPER_API_VERSION" ] || {
    helper_fail "helper library API ${EZ_LIB_API:-none} does not match helper API $HELPER_API_VERSION; re-run the P1CERT installer"
    return 1
  }
  trap helper_cleanup EXIT
  trap 'helper_cleanup; exit 130' HUP INT TERM
  helper_dispatch "$@"
  rc=$?
  helper_cleanup
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  helper_main "$@"
  exit $?
fi
