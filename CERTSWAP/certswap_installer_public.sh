#!/usr/bin/env bash
# shellcheck shell=bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

VERSION="0.1.3"

MODE="install"
TARGET_USER="${SUDO_USER:-${USER:-itgo}}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  certswap_installer_public.sh [target-user]
  certswap_installer_public.sh --uninstall [target-user]
  certswap_installer_public.sh --help
EOF_USAGE
}

while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      TARGET_USER="$1"
      shift
      ;;
  esac
done

target_home() {
  local home_dir
  home_dir="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}' || true)"
  [ -n "${home_dir:-}" ] || return 1
  printf '%s\n' "$home_dir"
}

target_group() {
  local group_name
  group_name="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
  [ -n "${group_name:-}" ] || group_name="$TARGET_USER"
  printf '%s\n' "$group_name"
}

require_target_user() {
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$TARGET_USER' does not exist" >&2
    exit 1
  fi
}

ensure_at_scheduler_backend() {
  local install_cmd=""

  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: CERTSWAP installer must run as root because it installs/enables at/atd for scheduled jobs" >&2
    return 1
  fi

  if command -v at >/dev/null 2>&1; then
    echo "OK: at command is available"
  else
    echo "ACTION: at command is missing; installing package 'at'"
    if command -v dnf >/dev/null 2>&1; then
      install_cmd="dnf -y install at"
    elif command -v yum >/dev/null 2>&1; then
      install_cmd="yum -y install at"
    elif command -v apt-get >/dev/null 2>&1; then
      install_cmd="apt-get update && apt-get install -y at"
    else
      echo "ERROR: cannot install 'at'; supported package managers are dnf, yum, and apt-get" >&2
      return 1
    fi

    echo "ACTION: running: $install_cmd"
    case "$install_cmd" in
      "dnf -y install at")
        dnf -y install at
        ;;
      "yum -y install at")
        yum -y install at
        ;;
      "apt-get update && apt-get install -y at")
        apt-get update && apt-get install -y at
        ;;
    esac
  fi

  if ! command -v at >/dev/null 2>&1; then
    echo "ERROR: at command is still unavailable after installation" >&2
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "ACTION: enabling and starting atd service"
    if systemctl enable --now atd >/dev/null 2>&1; then
      echo "OK: atd service enabled and started"
    else
      echo "WARN: systemctl enable --now atd failed; trying enable and start separately" >&2
      systemctl enable atd
      systemctl start atd
    fi

    if systemctl is-active --quiet atd; then
      echo "OK: atd service is active"
    else
      echo "ERROR: atd service is not active after start attempt" >&2
      return 1
    fi
  else
    echo "WARN: systemctl is not available; cannot enable or verify atd service" >&2
    return 1
  fi
}

install_certswap() {
  local home_dir group_name utility_dir module_dir tools_dir jobs_dir history_dir app_script launcher version_file

  require_target_user
  ensure_at_scheduler_backend

  home_dir="$(target_home)" || { echo "ERROR: cannot resolve HOME for '$TARGET_USER'" >&2; exit 1; }
  group_name="$(target_group)"

  utility_dir="$home_dir/UTILITY"
  module_dir="$utility_dir/CERTSWAP"
  tools_dir="$utility_dir/TOOLS"
  jobs_dir="$module_dir/jobs"
  history_dir="$module_dir/history"
  app_script="$module_dir/certswap.sh"
  launcher="$tools_dir/certswap"
  version_file="$module_dir/.certswap_version"

  install -d -m 0755 "$utility_dir" "$module_dir" "$tools_dir"
  install -d -m 0700 "$jobs_dir" "$history_dir"

  cat > "$app_script" <<'EOF_CERTSWAP'
#!/usr/bin/env bash
# shellcheck shell=bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

VERSION="__CERTSWAP_VERSION__"
MODULE_DIR="${CERTSWAP_MODULE_DIR:-$HOME/UTILITY/CERTSWAP}"
JOBS_DIR="$MODULE_DIR/jobs"
HISTORY_DIR="$MODULE_DIR/history"
NEW_CERT_DIR="${CERTSWAP_NEW_CERT_DIR:-$HOME/UPG/CERT}"
BACKUP_ROOT="${CERTSWAP_BACKUP_ROOT:-$HOME/BACKUP/CERT_OLD}"
DRY_RUN="0"

usage() {
  cat <<'EOF_USAGE'
Usage:
  certswap
  certswap file
  certswap jks
  certswap --dry-run
  certswap --list
  certswap --history
  certswap --version
  certswap --help
EOF_USAGE
}

ts() { date "+%Y%m%d_%H%M%S"; }
human_ts() { date "+%F %T"; }

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

read_prompt() {
  local prompt="${1:?}" answer
  printf '%s' "$prompt" >&2
  read -r answer || answer=""
  trim "$answer"
}

prompt_yn() {
  local question="${1:?}" default="${2:-N}" answer
  while true; do
    if [ "$default" = "Y" ]; then
      answer="$(read_prompt "$question [Y/n]: ")"
      answer="${answer:-Y}"
    else
      answer="$(read_prompt "$question [y/N]: ")"
      answer="${answer:-N}"
    fi

    case "${answer,,}" in
      y|yes|t|tak) return 0 ;;
      n|no|nie) return 1 ;;
      *) echo "Enter y or n." >&2 ;;
    esac
  done
}

require_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required for certificate file mode." >&2
    exit 1
  fi
}

ensure_runtime_dirs() {
  mkdir -p "$JOBS_DIR" "$HISTORY_DIR" "$BACKUP_ROOT"
  chmod 0700 "$MODULE_DIR" "$JOBS_DIR" "$HISTORY_DIR" 2>/dev/null || true
}

canonical_path() {
  local path="${1:?}"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

validate_cert_file() {
  local cert_path="${1:?}" label="${2:-certificate}"
  if [ ! -f "$cert_path" ]; then
    echo "ERROR: $label does not exist or is not a regular file: $cert_path" >&2
    return 1
  fi
  if ! openssl x509 -in "$cert_path" -noout >/dev/null 2>&1; then
    echo "ERROR: $label is not a valid x509 certificate: $cert_path" >&2
    return 1
  fi
}

show_cert_info() {
  local cert_path="${1:?}" label="${2:-Certificate}"
  echo
  echo "=== $label ==="
  echo "$cert_path"
  openssl x509 -in "$cert_path" -noout -subject -issuer -dates -serial
}

list_cert_candidates() {
  local candidate lower_name

  if [ ! -d "$NEW_CERT_DIR" ]; then
    echo "INFO: candidate directory does not exist: $NEW_CERT_DIR" >&2
    return 0
  fi

  while IFS= read -r candidate; do
    lower_name="$(basename "$candidate" | tr '[:upper:]' '[:lower:]')"
    case "$lower_name" in
      *.key)
        continue
        ;;
    esac

    if openssl x509 -in "$candidate" -noout >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
    fi
  done < <(find "$NEW_CERT_DIR" -maxdepth 1 -type f | sort)
}

list_keystore_candidates() {
  local candidate lower_name

  if [ ! -d "$NEW_CERT_DIR" ]; then
    echo "INFO: candidate directory does not exist: $NEW_CERT_DIR" >&2
    return 0
  fi

  while IFS= read -r candidate; do
    lower_name="$(basename "$candidate" | tr '[:upper:]' '[:lower:]')"
    case "$lower_name" in
      *.jks|*.keystore|*.truststore|*.p12|*.pfx)
        printf '%s\n' "$candidate"
        ;;
    esac
  done < <(find "$NEW_CERT_DIR" -maxdepth 1 -type f | sort)
}

choose_source_cert() {
  local -a candidates=()
  local candidate answer idx

  echo >&2
  echo "Candidate certificates from: $NEW_CERT_DIR" >&2
  while IFS= read -r candidate; do
    [ -n "${candidate:-}" ] || continue
    candidates+=("$candidate")
  done < <(list_cert_candidates)

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "  (none found)" >&2
  else
    for idx in "${!candidates[@]}"; do
      printf '  [%d] %s\n' "$((idx + 1))" "${candidates[$idx]}" >&2
    done
  fi

  while true; do
    answer="$(read_prompt "Choose new cert by number or enter full path: ")"
    if [ -z "$answer" ]; then
      echo "ERROR: path cannot be empty." >&2
      continue
    fi

    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#candidates[@]}" ]; then
      printf '%s\n' "${candidates[$((answer - 1))]}"
      return 0
    fi

    printf '%s\n' "$answer"
    return 0
  done
}

choose_source_keystore() {
  local -a candidates=()
  local candidate answer idx

  echo >&2
  echo "Candidate keystores from: $NEW_CERT_DIR" >&2
  while IFS= read -r candidate; do
    [ -n "${candidate:-}" ] || continue
    candidates+=("$candidate")
  done < <(list_keystore_candidates)

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "  (none found)" >&2
  else
    for idx in "${!candidates[@]}"; do
      printf '  [%d] %s\n' "$((idx + 1))" "${candidates[$idx]}" >&2
    done
  fi

  while true; do
    answer="$(read_prompt "Choose source JKS/keystore by number or enter full path: ")"
    if [ -z "$answer" ]; then
      echo "ERROR: path cannot be empty." >&2
      continue
    fi

    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#candidates[@]}" ]; then
      printf '%s\n' "${candidates[$((answer - 1))]}"
      return 0
    fi

    printf '%s\n' "$answer"
    return 0
  done
}

validate_regular_file() {
  local path="${1:?}" label="${2:-file}"
  if [ ! -f "$path" ]; then
    echo "ERROR: $label does not exist or is not a regular file: $path" >&2
    return 1
  fi
}

artifact_metadata() {
  local path="${1:?}" mode owner group
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  owner="$(stat -c '%u' "$path" 2>/dev/null || true)"
  group="$(stat -c '%g' "$path" 2>/dev/null || true)"
  printf '%s|%s|%s\n' "$mode" "$owner" "$group"
}

write_log_line() {
  local log_file="${1:?}"
  shift
  printf '%s %s\n' "$(human_ts)" "$*" | tee -a "$log_file"
}

normalize_systemd_service() {
  local service_name="${1:?}"
  case "$service_name" in
    *.service) printf '%s\n' "$service_name" ;;
    *) printf '%s.service\n' "$service_name" ;;
  esac
}

detect_compose_file() {
  local project_dir="${1:?}" compose_file
  for compose_file in docker-compose.yml compose.yml compose.yaml; do
    if [ -f "$project_dir/$compose_file" ]; then
      printf '%s\n' "$project_dir/$compose_file"
      return 0
    fi
  done
  return 1
}

prompt_restart_config() {
  local choice service_name project_dir compose_file

  RESTART_KIND="none"
  RESTART_TARGET=""

  echo
  echo "Restart after replacement?"
  echo "[0] no restart"
  echo "[1] systemd service"
  echo "[2] Docker Compose project"
  while true; do
    choice="$(read_prompt "Choose [0-2]: ")"
    case "$choice" in
      0|"")
        return 0
        ;;
      1)
        service_name="$(read_prompt "Systemd service name (for example wfly.service): ")"
        if [ -z "$service_name" ]; then
          echo "ERROR: service name cannot be empty." >&2
          continue
        fi
        RESTART_KIND="systemd"
        RESTART_TARGET="$(normalize_systemd_service "$service_name")"
        return 0
        ;;
      2)
        project_dir="$(read_prompt "Docker Compose project directory: ")"
        if [ -z "$project_dir" ]; then
          echo "ERROR: project directory cannot be empty." >&2
          continue
        fi
        if [ ! -d "$project_dir" ]; then
          echo "ERROR: compose project directory does not exist: $project_dir" >&2
          continue
        fi
        if ! compose_file="$(detect_compose_file "$project_dir")"; then
          echo "ERROR: no compose file found in $project_dir (docker-compose.yml, compose.yml, compose.yaml)." >&2
          continue
        fi
        echo "Compose file detected: $compose_file"
        RESTART_KIND="compose"
        RESTART_TARGET="$project_dir"
        return 0
        ;;
      *)
        echo "Enter 0, 1, or 2." >&2
        ;;
    esac
  done
}

run_post_restart() {
  local restart_kind="${1:?}" restart_target="${2:-}" log_file="${3:?}"

  case "$restart_kind" in
    none|"")
      return 0
      ;;
    systemd)
      if sudo -n systemctl restart "$restart_target"; then
        write_log_line "$log_file" "SERVICE_RESTART_OK service=$restart_target"
        return 0
      fi
      echo "ERROR: systemd service restart failed: $restart_target" >&2
      write_log_line "$log_file" "SERVICE_RESTART_FAILED service=$restart_target"
      return 1
      ;;
    compose)
      if (cd "$restart_target" && docker compose restart); then
        write_log_line "$log_file" "COMPOSE_RESTART_OK path=$restart_target"
        return 0
      fi
      if (cd "$restart_target" && docker-compose restart); then
        write_log_line "$log_file" "COMPOSE_RESTART_OK path=$restart_target"
        return 0
      fi
      echo "ERROR: Docker Compose restart failed: $restart_target" >&2
      write_log_line "$log_file" "COMPOSE_RESTART_FAILED path=$restart_target"
      return 1
      ;;
    *)
      echo "ERROR: unknown restart kind: $restart_kind" >&2
      write_log_line "$log_file" "ERROR unknown restart kind=$restart_kind"
      return 1
      ;;
  esac
}

replace_artifact_now() {
  local target="${1:?}" source="${2:?}" dry_run="${3:?}" log_file="${4:?}" artifact_label="${5:?}" restart_kind="${6:-none}" restart_target="${7:-}"
  local target_dir target_name backup_dir temp_file metadata mode owner group

  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  backup_dir="$BACKUP_ROOT/$(ts)"
  temp_file="$target_dir/.${target_name}.certswap.$$.$(ts).tmp"
  metadata="$(artifact_metadata "$target")"
  mode="${metadata%%|*}"
  metadata="${metadata#*|}"
  owner="${metadata%%|*}"
  group="${metadata#*|}"

  if [ "$dry_run" = "1" ]; then
    echo
    echo "DRY RUN: would create backup directory: $backup_dir"
    echo "DRY RUN: would copy old $artifact_label to: $backup_dir/$target_name"
    echo "DRY RUN: would copy source $artifact_label to temporary file: $temp_file"
    echo "DRY RUN: would preserve mode=${mode:-UNKNOWN} owner=${owner:-UNKNOWN} group=${group:-UNKNOWN}"
    echo "DRY RUN: would move temporary file to final destination: $target"
    if [ "${restart_kind:-none}" != "none" ]; then
      echo "DRY RUN: would restart $restart_kind target: $restart_target"
    fi
    return 0
  fi

  write_log_line "$log_file" "TARGET=$target"
  write_log_line "$log_file" "SOURCE=$source"
  write_log_line "$log_file" "BACKUP_DIR=$backup_dir"

  mkdir -p "$backup_dir"
  chmod 0700 "$backup_dir" 2>/dev/null || true

  if ! cp -a -- "$target" "$backup_dir/$target_name"; then
    echo "ERROR: backup failed; replacement aborted." >&2
    write_log_line "$log_file" "ERROR backup failed"
    return 1
  fi
  write_log_line "$log_file" "BACKUP_OK=$backup_dir/$target_name"

  rm -f -- "$temp_file" 2>/dev/null || true
  if ! cp -- "$source" "$temp_file"; then
    rm -f -- "$temp_file" 2>/dev/null || true
    echo "ERROR: cannot prepare temporary $artifact_label in target directory." >&2
    write_log_line "$log_file" "ERROR temp copy failed"
    return 1
  fi

  if [ -n "${mode:-}" ]; then
    chmod "$mode" "$temp_file" 2>/dev/null || echo "WARN: failed to preserve mode $mode on $temp_file" >&2
  fi

  if [ -n "${owner:-}" ] && [ -n "${group:-}" ]; then
    if ! chown "$owner:$group" "$temp_file" 2>/dev/null; then
      echo "WARN: failed to preserve owner/group ${owner}:${group}; continuing with current ownership." >&2
      write_log_line "$log_file" "WARN chown failed owner=$owner group=$group"
    fi
  fi

  if ! mv -f -- "$temp_file" "$target"; then
    rm -f -- "$temp_file" 2>/dev/null || true
    echo "ERROR: final move failed; backup is available at $backup_dir/$target_name" >&2
    write_log_line "$log_file" "ERROR final move failed"
    return 1
  fi

  write_log_line "$log_file" "REPLACED_OK"
  echo
  echo "$artifact_label replaced."

  if ! run_post_restart "$restart_kind" "$restart_target" "$log_file"; then
    return 1
  fi
}

shell_quote() {
  local value="${1:-}"
  printf '%q' "$value"
}

write_job_script() {
  local target="${1:?}" source="${2:?}" artifact_kind="${3:?}" restart_kind="${4:?}" restart_target="${5:-}" job_stamp="${6:?}" scheduled_time_display="${7:?}" scheduled_at_value="${8:?}" job_file log_file at_cmd at_output
  local q_module q_backup q_target q_source q_history q_artifact_kind q_restart_kind q_restart_target

  job_file="$JOBS_DIR/certswap_${job_stamp}.sh"
  log_file="$HISTORY_DIR/certswap_job_${job_stamp}.log"
  at_cmd="at -t $scheduled_at_value -f $job_file"

  q_module="$(shell_quote "$MODULE_DIR")"
  q_backup="$(shell_quote "$BACKUP_ROOT")"
  q_target="$(shell_quote "$target")"
  q_source="$(shell_quote "$source")"
  q_history="$(shell_quote "$log_file")"
  q_artifact_kind="$(shell_quote "$artifact_kind")"
  q_restart_kind="$(shell_quote "$restart_kind")"
  q_restart_target="$(shell_quote "$restart_target")"

  cat > "$job_file" <<EOF_JOB
#!/usr/bin/env bash
set -euo pipefail 2>/dev/null || set -eu

MODULE_DIR=$q_module
BACKUP_ROOT=$q_backup
TARGET_ARTIFACT=$q_target
SOURCE_ARTIFACT=$q_source
ARTIFACT_KIND=$q_artifact_kind
RESTART_KIND=$q_restart_kind
RESTART_TARGET=$q_restart_target
LOG_FILE=$q_history

ts() { date "+%Y%m%d_%H%M%S"; }
human_ts() { date "+%F %T"; }
write_log_line() {
  local log_file="\${1:?}"
  shift
  mkdir -p "\$(dirname "\$log_file")"
  printf '%s %s\\n' "\$(human_ts)" "\$*" | tee -a "\$log_file"
}
artifact_metadata() {
  local path="\${1:?}" mode owner group
  mode="\$(stat -c '%a' "\$path" 2>/dev/null || true)"
  owner="\$(stat -c '%u' "\$path" 2>/dev/null || true)"
  group="\$(stat -c '%g' "\$path" 2>/dev/null || true)"
  printf '%s|%s|%s\\n' "\$mode" "\$owner" "\$group"
}

run_post_restart() {
  local restart_kind="\${1:?}" restart_target="\${2:-}" log_file="\${3:?}"

  case "\$restart_kind" in
    none|"")
      return 0
      ;;
    systemd)
      if sudo -n systemctl restart "\$restart_target"; then
        write_log_line "\$log_file" "SERVICE_RESTART_OK service=\$restart_target"
        return 0
      fi
      echo "ERROR: systemd service restart failed: \$restart_target" >&2
      write_log_line "\$log_file" "SERVICE_RESTART_FAILED service=\$restart_target"
      return 1
      ;;
    compose)
      if (cd "\$restart_target" && docker compose restart); then
        write_log_line "\$log_file" "COMPOSE_RESTART_OK path=\$restart_target"
        return 0
      fi
      if (cd "\$restart_target" && docker-compose restart); then
        write_log_line "\$log_file" "COMPOSE_RESTART_OK path=\$restart_target"
        return 0
      fi
      echo "ERROR: Docker Compose restart failed: \$restart_target" >&2
      write_log_line "\$log_file" "COMPOSE_RESTART_FAILED path=\$restart_target"
      return 1
      ;;
    *)
      echo "ERROR: unknown restart kind: \$restart_kind" >&2
      write_log_line "\$log_file" "ERROR unknown restart kind=\$restart_kind"
      return 1
      ;;
  esac
}

fail_job() {
  write_log_line "\$LOG_FILE" "FAILED"
  exit 1
}

target_dir="\$(dirname "\$TARGET_ARTIFACT")"
target_name="\$(basename "\$TARGET_ARTIFACT")"
backup_dir="\$BACKUP_ROOT/\$(ts)"
temp_file="\$target_dir/.\${target_name}.certswap.\$\$.\$(ts).tmp"
metadata="\$(artifact_metadata "\$TARGET_ARTIFACT")"
mode="\${metadata%%|*}"
metadata="\${metadata#*|}"
owner="\${metadata%%|*}"
group="\${metadata#*|}"

mkdir -p "\$(dirname "\$LOG_FILE")"
write_log_line "\$LOG_FILE" "JOB_START kind=\$ARTIFACT_KIND target=\$TARGET_ARTIFACT source=\$SOURCE_ARTIFACT restart_kind=\$RESTART_KIND restart_target=\$RESTART_TARGET"

if [ ! -f "\$TARGET_ARTIFACT" ]; then
  echo "ERROR: target artifact is missing: \$TARGET_ARTIFACT" >&2
  write_log_line "\$LOG_FILE" "ERROR target missing"
  fail_job
fi
if [ ! -f "\$SOURCE_ARTIFACT" ]; then
  echo "ERROR: source artifact is missing: \$SOURCE_ARTIFACT" >&2
  write_log_line "\$LOG_FILE" "ERROR source missing"
  fail_job
fi
if [ "\$ARTIFACT_KIND" = "cert" ]; then
  if ! command -v openssl >/dev/null 2>&1 || ! openssl x509 -in "\$TARGET_ARTIFACT" -noout >/dev/null 2>&1 || ! openssl x509 -in "\$SOURCE_ARTIFACT" -noout >/dev/null 2>&1; then
    echo "ERROR: certificate validation failed." >&2
    write_log_line "\$LOG_FILE" "ERROR certificate validation failed"
    fail_job
  fi
fi

mkdir -p "\$backup_dir"
chmod 0700 "\$backup_dir" 2>/dev/null || true
if ! cp -a -- "\$TARGET_ARTIFACT" "\$backup_dir/\$target_name"; then
  echo "ERROR: backup failed; replacement aborted." >&2
  write_log_line "\$LOG_FILE" "ERROR backup failed"
  fail_job
fi

rm -f -- "\$temp_file" 2>/dev/null || true
if ! cp -- "\$SOURCE_ARTIFACT" "\$temp_file"; then
  rm -f -- "\$temp_file" 2>/dev/null || true
  echo "ERROR: temporary copy failed." >&2
  write_log_line "\$LOG_FILE" "ERROR temp copy failed"
  fail_job
fi
[ -n "\${mode:-}" ] && chmod "\$mode" "\$temp_file" 2>/dev/null || true
if [ -n "\${owner:-}" ] && [ -n "\${group:-}" ]; then
  chown "\$owner:\$group" "\$temp_file" 2>/dev/null || echo "WARN: failed to preserve owner/group \${owner}:\${group}; continuing." >&2
fi
if ! mv -f -- "\$temp_file" "\$TARGET_ARTIFACT"; then
  rm -f -- "\$temp_file" 2>/dev/null || true
  echo "ERROR: final move failed; backup is available at \$backup_dir/\$target_name" >&2
  write_log_line "\$LOG_FILE" "ERROR final move failed"
  fail_job
fi
write_log_line "\$LOG_FILE" "REPLACED_OK backup=\$backup_dir/\$target_name"
echo "Artifact replaced."
if ! run_post_restart "\$RESTART_KIND" "\$RESTART_TARGET" "\$LOG_FILE"; then
  fail_job
fi
EOF_JOB

  chmod 0700 "$job_file"
  echo
  echo "Job script created:"
  echo "  $job_file"
  echo
  echo "Selected execution time:"
  echo "  $scheduled_time_display"
  echo
  echo "Exact at command:"
  echo "  $at_cmd"

  if ! command -v at >/dev/null 2>&1; then
    echo "ERROR: at is not available; job was NOT scheduled." >&2
    echo "Emergency manual fallback after fixing scheduler backend:" >&2
    echo "  $at_cmd" >&2
    echo "Direct manual execution fallback:" >&2
    echo "  bash $job_file" >&2
    return 1
  fi

  if at_output="$(at -t "$scheduled_at_value" -f "$job_file" 2>&1)"; then
    echo "OK: job registered with at."
    [ -n "${at_output:-}" ] && printf '%s\n' "$at_output"
  else
    echo "ERROR: at registration failed; job was NOT scheduled." >&2
    [ -n "${at_output:-}" ] && printf '%s\n' "$at_output" >&2
    echo "Emergency manual fallback after fixing scheduler backend:" >&2
    echo "  $at_cmd" >&2
    echo "Direct manual execution fallback:" >&2
    echo "  bash $job_file" >&2
    return 1
  fi
}

prompt_schedule_time() {
  local answer at_value
  while true; do
    answer="$(read_prompt "Execution time [YYYY-MM-DD HH:MM]: ")"
    if [[ "$answer" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
      at_value="${answer:0:4}${answer:5:2}${answer:8:2}${answer:11:2}${answer:14:2}"
      printf '%s|%s\n' "$answer" "$at_value"
      return 0
    fi
    echo "ERROR: expected format YYYY-MM-DD HH:MM, for example 2026-05-18 23:30." >&2
  done
}

show_preview() {
  local target="${1:?}" source="${2:?}" source_label="${3:-source artifact}"
  echo
  echo "=== Preview ==="
  echo "target path       : $target"
  echo "target filename   : $(basename "$target")"
  printf '%-18s: %s\n' "$source_label" "$source"
  echo "final destination : $target"
  echo "backup directory  : $BACKUP_ROOT/<timestamp>/"
}

file_flow() {
  local target source target_real source_real choice run_mode schedule_stamp log_file schedule_input scheduled_time_display scheduled_at_value

  require_openssl

  target="$(read_prompt "Current/old certificate path: ")"
  if [ -z "$target" ]; then
    echo "ERROR: target path cannot be empty." >&2
    exit 1
  fi
  validate_cert_file "$target" "current certificate"
  show_cert_info "$target" "Current certificate"

  source="$(choose_source_cert)"
  if [ -z "$source" ]; then
    echo "ERROR: source path cannot be empty." >&2
    exit 1
  fi
  validate_cert_file "$source" "new certificate"

  target_real="$(canonical_path "$target")"
  source_real="$(canonical_path "$source")"
  if [ "$target_real" = "$source_real" ]; then
    echo "ERROR: source cert and target cert are the same file." >&2
    exit 1
  fi

  show_cert_info "$source" "New certificate"
  show_preview "$target" "$source" "source cert"

  if [ "$DRY_RUN" != "1" ] && prompt_yn "Dry-run only?" "N"; then
    DRY_RUN="1"
  fi

  schedule_stamp="$(ts)"
  log_file="$HISTORY_DIR/certswap_${schedule_stamp}.log"

  if [ "$DRY_RUN" != "1" ]; then
    prompt_restart_config
  else
    RESTART_KIND="none"
    RESTART_TARGET=""
  fi

  if [ "$DRY_RUN" = "1" ]; then
    replace_artifact_now "$target" "$source" "$DRY_RUN" "$log_file" "CERT" "$RESTART_KIND" "$RESTART_TARGET"
    return 0
  fi

  ensure_runtime_dirs

  echo
  echo "Execute now or schedule?"
  echo "[1] now"
  echo "[2] schedule"
  while true; do
    choice="$(read_prompt "Choose [1-2]: ")"
    case "$choice" in
      1)
        run_mode="now"
        break
        ;;
      2)
        run_mode="schedule"
        break
        ;;
      *)
        echo "Enter 1 or 2." >&2
        ;;
    esac
  done

  if [ "$run_mode" = "schedule" ]; then
    schedule_input="$(prompt_schedule_time)"
    scheduled_time_display="${schedule_input%%|*}"
    scheduled_at_value="${schedule_input#*|}"
    if ! write_job_script "$target" "$source" "cert" "$RESTART_KIND" "$RESTART_TARGET" "$schedule_stamp" "$scheduled_time_display" "$scheduled_at_value"; then
      return 1
    fi
    return 0
  fi

  replace_artifact_now "$target" "$source" "$DRY_RUN" "$log_file" "CERT" "$RESTART_KIND" "$RESTART_TARGET"
}

jks_flow() {
  local target source target_real source_real choice run_mode schedule_stamp log_file schedule_input scheduled_time_display scheduled_at_value

  target="$(read_prompt "Current/old JKS/keystore path: ")"
  if [ -z "$target" ]; then
    echo "ERROR: target path cannot be empty." >&2
    exit 1
  fi
  validate_regular_file "$target" "current JKS/keystore"

  source="$(choose_source_keystore)"
  if [ -z "$source" ]; then
    echo "ERROR: source path cannot be empty." >&2
    exit 1
  fi
  validate_regular_file "$source" "source JKS/keystore"

  target_real="$(canonical_path "$target")"
  source_real="$(canonical_path "$source")"
  if [ "$target_real" = "$source_real" ]; then
    echo "ERROR: source JKS/keystore and target JKS/keystore are the same file." >&2
    exit 1
  fi

  show_preview "$target" "$source" "source artifact"

  if [ "$DRY_RUN" != "1" ] && prompt_yn "Dry-run only?" "N"; then
    DRY_RUN="1"
  fi

  schedule_stamp="$(ts)"
  log_file="$HISTORY_DIR/certswap_${schedule_stamp}.log"

  if [ "$DRY_RUN" != "1" ]; then
    prompt_restart_config
  else
    RESTART_KIND="none"
    RESTART_TARGET=""
  fi

  if [ "$DRY_RUN" = "1" ]; then
    replace_artifact_now "$target" "$source" "$DRY_RUN" "$log_file" "JKS/keystore" "$RESTART_KIND" "$RESTART_TARGET"
    return 0
  fi

  ensure_runtime_dirs

  echo
  echo "Execute now or schedule?"
  echo "[1] now"
  echo "[2] schedule"
  while true; do
    choice="$(read_prompt "Choose [1-2]: ")"
    case "$choice" in
      1)
        run_mode="now"
        break
        ;;
      2)
        run_mode="schedule"
        break
        ;;
      *)
        echo "Enter 1 or 2." >&2
        ;;
    esac
  done

  if [ "$run_mode" = "schedule" ]; then
    schedule_input="$(prompt_schedule_time)"
    scheduled_time_display="${schedule_input%%|*}"
    scheduled_at_value="${schedule_input#*|}"
    if ! write_job_script "$target" "$source" "jks" "$RESTART_KIND" "$RESTART_TARGET" "$schedule_stamp" "$scheduled_time_display" "$scheduled_at_value"; then
      return 1
    fi
    return 0
  fi

  replace_artifact_now "$target" "$source" "$DRY_RUN" "$log_file" "JKS/keystore" "$RESTART_KIND" "$RESTART_TARGET"
}

list_jobs() {
  echo "Job scripts: $JOBS_DIR"
  if [ ! -d "$JOBS_DIR" ]; then
    echo "  (jobs directory does not exist)"
    return 0
  fi
  if ! find "$JOBS_DIR" -maxdepth 1 -type f -name 'certswap_*.sh' -print | sort; then
    return 0
  fi
}

show_history() {
  echo "History logs: $HISTORY_DIR"
  if [ ! -d "$HISTORY_DIR" ]; then
    echo "  (history directory does not exist)"
    return 0
  fi
  if ! find "$HISTORY_DIR" -maxdepth 1 -type f -name '*.log' -print | sort; then
    return 0
  fi
}

cmd="${1:-file}"
case "$cmd" in
  file|"")
    file_flow
    ;;
  jks)
    jks_flow
    ;;
  --dry-run)
    DRY_RUN="1"
    file_flow
    ;;
  --list)
    list_jobs
    ;;
  --history)
    show_history
    ;;
  --version)
    printf '%s\n' "$VERSION"
    ;;
  --help|-h)
    usage
    ;;
  *)
    echo "ERROR: unknown argument: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
EOF_CERTSWAP

  cat > "$launcher" <<EOF_LAUNCHER
#!/usr/bin/env bash
exec "$app_script" "\$@"
EOF_LAUNCHER

  sed -i -e "s|__CERTSWAP_VERSION__|$VERSION|g" "$app_script"
  printf '%s\n' "$VERSION" > "$version_file"

  chmod 0755 "$app_script" "$launcher"
  chmod 0644 "$version_file"
  chown -R "$TARGET_USER:$group_name" "$module_dir"
  chown "$TARGET_USER:$group_name" "$tools_dir" "$launcher" 2>/dev/null || true

  echo "OK: installed CERTSWAP $VERSION"
  echo "OK: module: $module_dir"
  echo "OK: launcher: $launcher"
  echo "OK: jobs: $jobs_dir"
  echo "OK: history: $history_dir"
  echo "INFO: no files were created in /usr/local/bin"
}

uninstall_certswap() {
  local home_dir utility_dir module_dir tools_dir launcher jobs_dir app_script version_file

  require_target_user
  home_dir="$(target_home)" || { echo "ERROR: cannot resolve HOME for '$TARGET_USER'" >&2; exit 1; }
  utility_dir="$home_dir/UTILITY"
  module_dir="$utility_dir/CERTSWAP"
  tools_dir="$utility_dir/TOOLS"
  launcher="$tools_dir/certswap"
  jobs_dir="$module_dir/jobs"
  app_script="$module_dir/certswap.sh"
  version_file="$module_dir/.certswap_version"

  rm -f "$launcher" "$app_script" "$version_file"
  rm -rf "$jobs_dir"

  echo "OK: removed CERTSWAP launcher: $launcher"
  echo "OK: removed CERTSWAP runtime files from: $module_dir"
  echo "INFO: retained operation history under: $module_dir/history"
  echo "INFO: retained certificate backups under: $home_dir/BACKUP/CERT_OLD"
}

case "$MODE" in
  install)
    install_certswap
    ;;
  uninstall)
    uninstall_certswap
    ;;
esac
