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
#   apply          <cert-path> <expected-old-sha256> <expected-new-sha256>
#   apply-systemd  <cert-path> <expected-old-sha256> <expected-new-sha256> <unit.service>
#   apply-compose  <cert-path> <expected-old-sha256> <expected-new-sha256> <project-dir> <service>
#   schedule       <YYYY-MM-DD> <HH:MM>
#   schedule-cancel
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
#   3 REFUSED                  current fingerprint differs from expected, target not changed
#   4 RESTORED                 replacement undone before any restart (verification
#                              failed or service binding changed), previous certificate verified
#   5 ROLLBACK                 restart failed, previous certificate restored and verified,
#                              single restart with it succeeded
#   6 ROLLBACK_RESTART_FAILED  as 5, but the single restart with it failed
#   7 ROLLBACK_FAILED          CRITICAL: previous certificate could not be restored

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
HELPER_API_VERSION=1

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
T_NAME=""; T_UID=""; T_GID=""; T_MODE=""; OLD_DIGEST=""; NEW_DIGEST=""

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

# Pins the target directory as the working directory and verifies that it
# still is the expected path and that only root can change its entries.  All
# later file operations are relative to this pinned directory.  A directory
# owned by another user or writable by group/others is refused: an
# unprivileged user could swap entries (symlinks, hard links) between the
# helper's checks and its root operations.
helper_enter_target_dir() {
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
  helper_node_trusted . d || {
    helper_fail "target directory must be owned by root and not writable by group/others (replace manually): ${target%/*}"
    return 1
  }
  T_NAME="${target##*/}"
  [ -f "$T_NAME" ] && [ ! -L "$T_NAME" ] && [ "$(helper_link_count "$T_NAME")" = 1 ] || {
    helper_fail "target changed during validation: $target"
    return 1
  }
}

# Writes a certificate in the given format to a file.
helper_render_cert() {
  openssl x509 -inform "$2" -in "$1" -outform "$3" -out "$4" 2>/dev/null
}

# Atomically replaces T_NAME inside the pinned directory with the content of
# $1, applying the original owner, group and mode (and SELinux context).  $2
# (mandatory) is the SHA-256 of the exact bytes the target must still contain
# right before the rename; anything else (including a change made by someone
# else) is never overwritten.
helper_atomic_replace() {
  local content="$1" expect="$2" tmp

  ez_digest_ok "$expect" || {
    helper_fail 'no valid expected digest of the current target; nothing replaced'
    return 1
  }
  tmp="$(mktemp ./.p1cert-ezdrowie.XXXXXX)" || {
    helper_fail 'cannot create temporary file next to target'
    return 1
  }
  if ! cat -- "$content" > "$tmp" ||
     ! chown -- "$T_UID:$T_GID" "$tmp" ||
     ! chmod -- "$T_MODE" "$tmp"; then
    rm -f -- "$tmp"
    helper_fail 'cannot prepare replacement file with original owner/group/mode'
    return 1
  fi
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    if ! chcon --reference="$T_NAME" -- "$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      helper_fail 'cannot copy SELinux context to replacement file'
      return 1
    fi
  fi
  if [ ! -f "$T_NAME" ] || [ -L "$T_NAME" ] || [ "$(helper_link_count "$T_NAME")" != 1 ] ||
     [ "$(ez_file_digest "$T_NAME")" != "$expect" ]; then
    rm -f -- "$tmp"
    helper_fail 'target does not contain the expected bytes; nothing replaced'
    return 1
  fi
  # -T: never move into a directory that appeared under the target name.
  if ! mv -f -T -- "$tmp" "$T_NAME"; then
    rm -f -- "$tmp"
    helper_fail 'atomic rename failed'
    return 1
  fi
}

# Verifies the file on disk: single certificate, fingerprint and exact bytes.
helper_verify_disk() {
  local fp="$1" digest="$2"

  ez_digest_ok "$digest" &&
    cat -- "$T_NAME" > "$HELPER_TMP/verify" 2>/dev/null &&
    ez_cert_inspect "$HELPER_TMP/verify" &&
    [ "$EZC_FP" = "$fp" ] &&
    [ "$(ez_file_digest "$HELPER_TMP/verify")" = "$digest" ]
}

# Puts back the exact previous certificate read by this operation, but only
# while the target still contains exactly the certificate this operation
# installed (NEW_DIGEST).  A later change by anybody else is never
# overwritten: the rollback then fails (ROLLBACK_FAILED, manual action).
helper_restore_old() {
  helper_atomic_replace "$HELPER_TMP/old" "$NEW_DIGEST" && helper_verify_disk "$OLD_FP" "$OLD_DIGEST"
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

# Proves, independently of the caller, that unit $2 uses certificate $1 (see
# ez_systemd_bound).  Only root-controlled unit, drop-in and environment
# files are read.  Sets A_REASON.
helper_systemd_bound() {
  local target="$1" unit="$2" props load fragment kind file fs config="" reason

  props="$(helper_systemctl show --no-pager -p LoadState -p FragmentPath -p DropInPaths \
    -p WorkingDirectory -p ExecStart -p Environment -p EnvironmentFiles -- "$unit" 2>/dev/null)" || {
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
  reason="$(ez_systemd_bound "$target" "$props" "$config")" || {
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
    done < <(find -P "$fsroot" \( -name node_modules -o -name .git \) -prune -o \
      -type f \( -iname '*.pem' -o -iname '*.crt' -o -iname '*.cer' \) -size -1024k -print0 2>/dev/null)
  done
}

op_read() {
  local target="$1" fs rc

  helper_check_target "$target" || return 2
  helper_tmpdir || return 1
  fs="$(helper_fs "$target")"
  cat -- "$fs" > "$HELPER_TMP/read" 2>/dev/null || {
    helper_fail "cannot read target: $target"
    return 1
  }
  ez_cert_inspect "$HELPER_TMP/read"
  rc=$?
  [ "$rc" -eq 0 ] || {
    helper_fail "target is not a single X.509 certificate without private key (code $rc): $target"
    return 2
  }
  cat -- "$HELPER_TMP/read"
}

# helper_apply <none|systemd|compose> <cert-path> <old-fp> <new-fp> [unit | project service]
helper_apply() {
  local expected_old expected_new now rc reason meta

  A_KIND="$1"; A_TARGET="$2"; A_UNIT=""; A_PROJECT=""; A_SERVICE=""; A_IDS=""; A_REASON=""
  expected_old="$(helper_norm_fp "$3")"
  expected_new="$(helper_norm_fp "$4")"
  ez_fp_ok "$expected_old" && ez_fp_ok "$expected_new" || helper_refuse 2 'invalid expected fingerprint' || return
  [ "$expected_old" != "$expected_new" ] || helper_refuse 2 'expected old and new fingerprints are identical' || return
  helper_lock || helper_refuse 1 'cannot serialize the operation' || return

  # 1. The restart target and its relation to this certificate are proven
  #    before anything is changed.
  case "$A_KIND" in
    none) ;;
    systemd)
      A_UNIT="$5"
      ez_unit_name_ok "$A_UNIT" || helper_refuse 2 "invalid unit name: $A_UNIT" || return
      ! ez_unit_denied "$A_UNIT" || helper_refuse 2 "unit is not allowed: $A_UNIT" || return
      helper_systemd_ready || helper_refuse 1 'systemd unavailable' || return
      helper_check_target "$A_TARGET" || helper_refuse 2 'invalid target' || return
      helper_systemd_bound "$A_TARGET" "$A_UNIT" || helper_refuse 2 "unit $A_UNIT is not bound to $A_TARGET" || return
      ;;
    compose)
      A_PROJECT="$5"; A_SERVICE="$6"
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
  ez_cert_inspect "$HELPER_TMP/new.in"
  rc=$?
  [ "$rc" -eq 0 ] || helper_refuse 2 "new certificate is not exactly one X.509 certificate (code $rc)" || return
  ez_cert_save NEW
  [ "$NEW_FP" = "$expected_new" ] || helper_refuse 2 "new certificate fingerprint $NEW_FP differs from the expected $expected_new" || return

  helper_enter_target_dir "$A_TARGET" || helper_refuse 2 'unsafe target directory' || return
  meta="$(stat -c '%u %g %a' -- "$T_NAME" 2>/dev/null)" || helper_refuse 2 'cannot read target metadata' || return
  read -r T_UID T_GID T_MODE <<EOF
$meta
EOF
  case "$T_UID:$T_GID:$T_MODE" in
    *[!0-9:]*|:*|*::*|*:) helper_refuse 2 'unexpected target metadata' || return ;;
  esac

  # The exact bytes of the current certificate are kept in the root-private
  # temporary directory of this operation; they are the only rollback source.
  cat -- "$T_NAME" > "$HELPER_TMP/old" 2>/dev/null || helper_refuse 2 'cannot read current certificate' || return
  ez_cert_inspect "$HELPER_TMP/old"
  rc=$?
  [ "$rc" -eq 0 ] || helper_refuse 2 "current file is not exactly one X.509 certificate (code $rc)" || return
  ez_cert_save OLD
  OLD_DIGEST="$(ez_file_digest "$HELPER_TMP/old")"
  ez_digest_ok "$OLD_DIGEST" || helper_refuse 1 'cannot compute a valid SHA-256 of the current certificate' || return

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

  # Keep the encoding of the existing file (PEM stays PEM, DER stays DER).
  helper_render_cert "$HELPER_TMP/new.in" "$NEW_FORMAT" "$OLD_FORMAT" "$HELPER_TMP/new.out" ||
    helper_refuse 1 'cannot encode new certificate' || return
  ez_cert_inspect "$HELPER_TMP/new.out" && [ "$EZC_FP" = "$NEW_FP" ] ||
    helper_refuse 1 'encoded certificate verification failed' || return
  NEW_DIGEST="$(ez_file_digest "$HELPER_TMP/new.out")"
  ez_digest_ok "$NEW_DIGEST" && [ "$NEW_DIGEST" != "$OLD_DIGEST" ] ||
    helper_refuse 1 'cannot compute a valid SHA-256 of the new certificate' || return

  # 3. Transaction.  From here on the operation is completed (including any
  #    rollback) even if the caller disconnects.
  trap '' HUP INT TERM PIPE
  if ! helper_atomic_replace "$HELPER_TMP/new.out" "$OLD_DIGEST"; then
    printf 'RESULT=FAILED\n'
    return 1
  fi
  if ! helper_verify_disk "$NEW_FP" "$NEW_DIGEST"; then
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

helper_dispatch() {
  local op="${1:-}"

  [ "$#" -gt 0 ] && shift
  case "$op:$#" in
    ping:0) op_ping ;;
    find-candidates:0) op_find_candidates ;;
    read:1) op_read "$1" ;;
    apply:3) helper_apply none "$1" "$2" "$3" ;;
    apply-systemd:4) helper_apply systemd "$1" "$2" "$3" "$4" ;;
    apply-compose:5) helper_apply compose "$1" "$2" "$3" "$4" "$5" ;;
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
