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
  serviceguard_installer_public.sh [target-user]
  serviceguard_installer_public.sh --uninstall [target-user]
  serviceguard_installer_public.sh --help
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

install_serviceguard() {
  local home_dir utility_dir module_dir tools_dir app_script launcher version_file group_name

  require_target_user
  home_dir="$(target_home)" || { echo "ERROR: cannot resolve HOME for '$TARGET_USER'" >&2; exit 1; }
  group_name="$(target_group)"

  utility_dir="$home_dir/UTILITY"
  module_dir="$utility_dir/SERVICEGUARD"
  tools_dir="$utility_dir/TOOLS"
  app_script="$module_dir/serviceguard.sh"
  launcher="$tools_dir/svcguard"
  version_file="$module_dir/.serviceguard_version"

  install -d -m 0755 "$utility_dir" "$module_dir" "$tools_dir"

  cat > "$app_script" <<'EOF_SERVICEGUARD'
#!/usr/bin/env bash
# shellcheck shell=bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

VERSION="__SERVICEGUARD_VERSION__"
MODE="scan"
ENABLE_SERVICE="0"
START_SERVICE="0"
ONLY="all"
SCAN_ROOTS=(/srv /opt)
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_SEARCH_DIRS=(/etc/systemd/system /usr/lib/systemd/system /lib/systemd/system)

APP_TYPES=()
APP_PATHS=()
APP_EXPECTED=()
APP_FOUND=()
APP_STATUS=()

usage() {
  cat <<'EOF_USAGE'
Usage:
  svcguard [--scan]
  svcguard --dry-run
  svcguard --apply [--enable] [--start]
  svcguard --only wildfly|pi|docker|all
  svcguard --version
  svcguard --help

Default mode is scan/report only. Systemd unit files are created only with --apply.
EOF_USAGE
}

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

trim_service_suffix() {
  local name="${1:-}"
  name="${name%.service}"
  printf '%s\n' "$name"
}

service_file_name() {
  local name="${1:-}"
  name="$(trim_service_suffix "$name")"
  printf '%s.service\n' "$name"
}

valid_service_name() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  case "$name" in
    */*|*" "*)
      return 1
      ;;
  esac
  [[ "$name" =~ ^[a-zA-Z0-9_.@-]+(\.service)?$ ]]
}

detect_user_for_path() {
  local path="${1:?}" owner
  owner="$(stat -c '%U' "$path" 2>/dev/null || true)"
  if [ -n "${owner:-}" ] && [ "$owner" != "UNKNOWN" ] && [[ "$owner" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]]; then
    printf '%s\n' "$owner"
  else
    printf '%s\n' "root"
  fi
}

compose_file_for_dir() {
  local dir="${1:?}"
  if [ -f "$dir/docker-compose.yml" ]; then
    printf '%s\n' "docker-compose.yml"
  elif [ -f "$dir/compose.yml" ]; then
    printf '%s\n' "compose.yml"
  elif [ -f "$dir/compose.yaml" ]; then
    printf '%s\n' "compose.yaml"
  fi
}

is_technical_shadow_dir_name() {
  local name="${1:-}" lower_name
  name="${name##*/}"
  lower_name="$(lower "$name")"

  case "$lower_name" in
    *_new|*_old)
      return 0
      ;;
  esac
  return 1
}

path_has_technical_shadow_component() {
  local path="${1:?}" part
  local -a path_parts
  IFS='/' read -r -a path_parts <<< "$path"

  for part in "${path_parts[@]}"; do
    [ -n "$part" ] || continue
    if is_technical_shadow_dir_name "$part"; then
      return 0
    fi
  done
  return 1
}

is_wildfly_hazelcast_helper_dir() {
  local path="${1:?}" base part has_wildfly_context
  local -a path_parts

  base="$(basename "$path")"
  [ "$(lower "$base")" = "hazelcast" ] || return 1

  has_wildfly_context="0"
  IFS='/' read -r -a path_parts <<< "$path"
  for part in "${path_parts[@]}"; do
    case "$(lower "$part")" in
      *wildfly*|*jboss*)
        has_wildfly_context="1"
        break
        ;;
    esac
  done

  [ "$has_wildfly_context" = "1" ]
}

find_scannable_app_dirs() {
  local root="${1:?}"
  find "$root" -maxdepth 4 \( -iname '*_NEW' -o -iname '*_OLD' \) -prune -o -type d -print0 2>/dev/null || true
}

mapped_name_for_basename() {
  local base="${1:?}" lower_base suffix
  lower_base="$(lower "$base")"

  case "$lower_base" in
    integrationplatform)
      printf '%s\n' "pi"
      return 0
      ;;
    integrationplatform_*)
      suffix="${base:20}"
      suffix="$(lower "$suffix" | tr -c 'a-z0-9_.@-' '_')"
      suffix="${suffix##_}"
      suffix="${suffix%%_}"
      [ -n "$suffix" ] || return 1
      printf 'pi_%s\n' "$suffix"
      return 0
      ;;
  esac

  if [[ "$lower_base" == *wildfly* || "$lower_base" == *jboss* ]]; then
    printf '%s\n' "wildfly"
    return 0
  fi

  if [[ "$lower_base" == edm || "$lower_base" == edm* || "$lower_base" == *edm-docker* ]]; then
    printf '%s\n' "amdx"
    return 0
  fi

  case "$lower_base" in
    *zm_docker*|*zm-docker*)
      printf '%s\n' "zm"
      return 0
      ;;
    *p1adapter*)
      printf '%s\n' "p1adapter"
      return 0
      ;;
    *p1erej*)
      printf '%s\n' "erej"
      return 0
      ;;
  esac

  if [[ "$lower_base" == mpi || "$lower_base" == mpi* || "$lower_base" == *mpi-docker* ]]; then
    printf '%s\n' "mpi"
    return 0
  fi

  case "$lower_base" in
    *ekrn*)
      printf '%s\n' "ekrn"
      return 0
      ;;
    *sgds*)
      printf '%s\n' "sgds"
      return 0
      ;;
    *bankkrwi*|*bank-krwi*|*bank_krwi*)
      printf '%s\n' "bk"
      return 0
      ;;
  esac

  return 1
}

expected_collision_exists() {
  local expected="${1:-}" app_path="${2:?}" idx
  [ -n "$expected" ] || return 1

  for idx in "${!APP_EXPECTED[@]}"; do
    if [ "${APP_EXPECTED[$idx]}" = "$expected" ] && [ "${APP_PATHS[$idx]}" != "$app_path" ]; then
      return 0
    fi
  done
  return 1
}

unit_file_contains_path() {
  local service="${1:?}" app_path="${2:?}" dir
  for dir in "${SYSTEMD_SEARCH_DIRS[@]}"; do
    if [ -f "$dir/$service" ] && grep -F -- "$app_path" "$dir/$service" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

append_app() {
  local app_type="${1:?}" app_path="${2:?}" expected="${3:-}" found status existing

  if path_has_technical_shadow_component "$app_path"; then
    return 0
  fi

  if [ "$app_type" = "docker-compose" ] && is_wildfly_hazelcast_helper_dir "$app_path"; then
    return 0
  fi

  existing="|${APP_PATHS[*]-}|"
  if [[ "$existing" == *"|$app_path|"* ]]; then
    return 0
  fi

  found="$(find_service_by_path "$app_path" || true)"
  if [ -z "$expected" ]; then
    status="UNKNOWN"
    expected="manual name required"
  elif [ -n "$found" ] && [ "$found" = "$expected" ]; then
    status="OK"
  elif [ -n "$found" ] && [ "$found" != "$expected" ]; then
    status="NAME MISMATCH"
  elif unit_file_contains_path "$expected" "$app_path"; then
    found="$expected"
    status="OK"
  elif unit_file_exists "$expected"; then
    found="$expected"
    status="NAME CONFLICT"
  elif expected_collision_exists "$expected" "$app_path"; then
    status="SERVICE NAME COLLISION"
  else
    status="MISSING"
  fi

  APP_TYPES+=("$app_type")
  APP_PATHS+=("$app_path")
  APP_EXPECTED+=("$expected")
  APP_FOUND+=("${found:-}")
  APP_STATUS+=("$status")
}

expected_for_app() {
  local app_type="${1:?}" app_path="${2:?}" base mapped
  base="$(basename "$app_path")"

  case "$app_type" in
    wildfly)
      printf '%s\n' "wildfly.service"
      ;;
    integration-platform)
      mapped="$(mapped_name_for_basename "$base" || true)"
      [ -n "${mapped:-}" ] || mapped="pi"
      service_file_name "$mapped"
      ;;
    docker-compose)
      mapped="$(mapped_name_for_basename "$base" || true)"
      [ -n "${mapped:-}" ] || return 1
      service_file_name "$mapped"
      ;;
    *)
      return 1
      ;;
  esac
}

unit_file_exists() {
  local service="${1:?}" dir
  for dir in "${SYSTEMD_SEARCH_DIRS[@]}"; do
    if [ -f "$dir/$service" ]; then
      return 0
    fi
  done
  return 1
}

find_service_by_path() {
  local app_path="${1:?}" dir file base
  for dir in "${SYSTEMD_SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
      if grep -F -- "$app_path" "$file" >/dev/null 2>&1; then
        base="$(basename "$file")"
        printf '%s\n' "$base"
        return 0
      fi
    done < <(find "$dir" -maxdepth 2 -type f -name '*.service' -print0 2>/dev/null || true)
  done
  return 1
}

scan_integration_platforms() {
  local root dir expected base lower_base
  for root in "${SCAN_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' dir; do
      base="$(basename "$dir")"
      lower_base="$(lower "$base")"
      case "$lower_base" in
        integrationplatform|integrationplatform_*)
          expected="$(expected_for_app "integration-platform" "$dir" || true)"
          append_app "integration-platform" "$dir" "$expected"
          ;;
      esac
    done < <(find_scannable_app_dirs "$root")
  done
}

scan_wildfly() {
  local root dir expected
  for root in "${SCAN_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' dir; do
      if [ -x "$dir/bin/standalone.sh" ]; then
        expected="$(expected_for_app "wildfly" "$dir" || true)"
        append_app "wildfly" "$dir" "$expected"
      fi
    done < <(find_scannable_app_dirs "$root")
  done
}

scan_docker_compose() {
  local root dir expected compose_file
  for root in "${SCAN_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' dir; do
      compose_file="$(compose_file_for_dir "$dir" || true)"
      [ -n "${compose_file:-}" ] || continue
      expected="$(expected_for_app "docker-compose" "$dir" || true)"
      append_app "docker-compose" "$dir" "$expected"
    done < <(find_scannable_app_dirs "$root")
  done
}

scan_apps() {
  case "$ONLY" in
    all)
      scan_integration_platforms
      scan_wildfly
      scan_docker_compose
      ;;
    pi)
      scan_integration_platforms
      ;;
    wildfly)
      scan_wildfly
      ;;
    docker)
      scan_docker_compose
      ;;
  esac
}

print_report() {
  local idx count
  count="${#APP_PATHS[@]}"
  printf '%-22s | %-48s | %-24s | %-24s | %s\n' "TYPE" "APP PATH" "EXPECTED" "FOUND" "STATUS"
  printf '%-22s-+-%-48s-+-%-24s-+-%-24s-+-%s\n' "----------------------" "------------------------------------------------" "------------------------" "------------------------" "---------------"
  if [ "$count" -eq 0 ]; then
    printf '%-22s | %-48s | %-24s | %-24s | %s\n' "-" "no supported apps found" "-" "-" "SKIPPED"
    return 0
  fi
  for idx in "${!APP_PATHS[@]}"; do
    printf '%-22s | %-48s | %-24s | %-24s | %s\n' \
      "${APP_TYPES[$idx]}" "${APP_PATHS[$idx]}" "${APP_EXPECTED[$idx]}" "${APP_FOUND[$idx]:--}" "${APP_STATUS[$idx]}"
  done
}

unit_content() {
  local app_type="${1:?}" app_path="${2:?}" service_user compose_file
  service_user="$(detect_user_for_path "$app_path")"

  case "$app_type" in
    wildfly)
      cat <<EOF_UNIT
[Unit]
Description=WildFly application server
After=network.target

[Service]
Type=simple
User=$service_user
WorkingDirectory=$app_path
ExecStart=$app_path/bin/standalone.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF_UNIT
      ;;
    integration-platform)
      cat <<EOF_UNIT
[Unit]
Description=IntegrationPlatform Tomcat service
After=network.target

[Service]
Type=forking
User=$service_user
WorkingDirectory=$app_path
ExecStart=$app_path/bin/startup.sh
ExecStop=$app_path/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF_UNIT
      ;;
    docker-compose)
      compose_file="$(compose_file_for_dir "$app_path" || true)"
      [ -n "${compose_file:-}" ] || compose_file="compose.yml"
      cat <<EOF_UNIT
[Unit]
Description=Docker Compose project $(basename "$app_path")
Requires=docker.service
After=docker.service network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$service_user
WorkingDirectory=$app_path
ExecStart=/usr/bin/env docker compose up -d
ExecStop=/usr/bin/env docker compose down

[Install]
WantedBy=multi-user.target
EOF_UNIT
      ;;
  esac
}

ask_service_name() {
  local prompt="${1:?}" ans
  while true; do
    printf '%s' "$prompt" >&2
    read -r ans || ans=""
    if valid_service_name "$ans"; then
      service_file_name "$ans"
      return 0
    fi
    echo "Invalid service name. Use only [a-zA-Z0-9_.@-], no spaces or slashes." >&2
  done
}

resolve_apply_service() {
  local idx="${1:?}" expected="${2:?}" found="${3:-}" status="${4:?}" choice custom

  if [ "$status" = "UNKNOWN" ]; then
    ask_service_name "Service name for ${APP_PATHS[$idx]}: "
    return 0
  fi

  if [ "$status" = "NAME CONFLICT" ]; then
    echo "NAME CONFLICT for ${APP_PATHS[$idx]}" >&2
    echo "Existing service file: $expected" >&2
    echo "The existing file does not reference this app path." >&2
    echo "[1] keep existing service file and skip" >&2
    echo "[2] enter custom service name" >&2
    echo "[3] skip" >&2
    printf 'Choose [1-3]: ' >&2
    read -r choice || choice="3"
    case "$choice" in
      2)
        custom="$(ask_service_name "Custom service name: ")"
        printf '%s\n' "$custom"
        ;;
      *)
        printf '%s\n' ""
        ;;
    esac
    return 0
  fi

  if [ "$status" = "SERVICE NAME COLLISION" ]; then
    echo "SERVICE NAME COLLISION for ${APP_PATHS[$idx]}" >&2
    echo "Requested service name is already claimed in this scan: $expected" >&2
    echo "[1] enter custom service name" >&2
    echo "[2] skip" >&2
    printf 'Choose [1-2]: ' >&2
    read -r choice || choice="2"
    case "$choice" in
      1)
        custom="$(ask_service_name "Custom service name: ")"
        printf '%s\n' "$custom"
        ;;
      *)
        printf '%s\n' ""
        ;;
    esac
    return 0
  fi

  if [ "$status" != "NAME MISMATCH" ]; then
    printf '%s\n' "$expected"
    return 0
  fi

  echo "NAME MISMATCH for ${APP_PATHS[$idx]}" >&2
  echo "Current : ${found:-none}" >&2
  echo "Proposed: $expected" >&2
  echo "[1] use standard/proposed name" >&2
  echo "[2] keep existing name" >&2
  echo "[3] enter custom name" >&2
  echo "[4] skip" >&2
  printf 'Choose [1-4]: ' >&2
  read -r choice || choice="4"
  case "$choice" in
    1)
      printf '%s\n' "$expected"
      ;;
    2)
      printf '%s\n' "$found"
      ;;
    3)
      custom="$(ask_service_name "Custom service name: ")"
      printf '%s\n' "$custom"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

write_unit() {
  local service="${1:?}" app_type="${2:?}" app_path="${3:?}" target_file
  target_file="$SYSTEMD_DIR/$service"
  install -d -m 0755 "$SYSTEMD_DIR"
  unit_content "$app_type" "$app_path" > "$target_file"
  chmod 0644 "$target_file"
  systemctl daemon-reload
}

apply_apps() {
  local idx service target_file status

  if [ "$MODE" = "apply" ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: --apply requires root because it writes to $SYSTEMD_DIR" >&2
    exit 1
  fi

  for idx in "${!APP_PATHS[@]}"; do
    status="${APP_STATUS[$idx]}"
    if [ "$status" = "OK" ]; then
      continue
    fi

    if [ "$MODE" = "dry-run" ]; then
      case "$status" in
        MISSING)
          echo "DRY RUN: would create $SYSTEMD_DIR/${APP_EXPECTED[$idx]} for ${APP_PATHS[$idx]}"
          ;;
        UNKNOWN)
          echo "DRY RUN: manual service name required for ${APP_PATHS[$idx]}"
          ;;
        NAME\ MISMATCH)
          echo "DRY RUN: --apply would ask how to handle ${APP_FOUND[$idx]:-unknown} vs ${APP_EXPECTED[$idx]}"
          ;;
        NAME\ CONFLICT|SERVICE\ NAME\ COLLISION)
          echo "DRY RUN: --apply would require a custom service name or skip for ${APP_PATHS[$idx]}"
          ;;
      esac
      APP_STATUS[$idx]="DRY RUN"
      continue
    fi

    service="$(resolve_apply_service "$idx" "${APP_EXPECTED[$idx]}" "${APP_FOUND[$idx]:-}" "$status")"
    if [ -z "${service:-}" ]; then
      APP_STATUS[$idx]="SKIPPED"
      continue
    fi
    if ! valid_service_name "$service"; then
      APP_STATUS[$idx]="SKIPPED"
      continue
    fi
    service="$(service_file_name "$service")"

    if [ "$status" = "NAME MISMATCH" ] && [ "$service" = "${APP_FOUND[$idx]:-}" ]; then
      APP_EXPECTED[$idx]="$service"
      APP_STATUS[$idx]="OK"
      if [ "$MODE" = "apply" ] && [ "$ENABLE_SERVICE" = "1" ]; then
        systemctl enable "$service"
      fi
      if [ "$MODE" = "apply" ] && [ "$START_SERVICE" = "1" ]; then
        systemctl start "$service"
      fi
      continue
    fi

    if unit_file_exists "$service" && ! unit_file_contains_path "$service" "${APP_PATHS[$idx]}"; then
      echo "SKIP: $service already exists and does not reference ${APP_PATHS[$idx]}" >&2
      APP_EXPECTED[$idx]="$service"
      APP_FOUND[$idx]="$service"
      APP_STATUS[$idx]="NAME CONFLICT"
      continue
    fi

    target_file="$SYSTEMD_DIR/$service"

    write_unit "$service" "${APP_TYPES[$idx]}" "${APP_PATHS[$idx]}"
    APP_EXPECTED[$idx]="$service"
    APP_FOUND[$idx]="$service"
    APP_STATUS[$idx]="CREATED"

    if [ "$ENABLE_SERVICE" = "1" ]; then
      systemctl enable "$service"
    fi
    if [ "$START_SERVICE" = "1" ]; then
      systemctl start "$service"
    fi
  done
}

while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --scan)
      MODE="scan"
      shift
      ;;
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --enable)
      ENABLE_SERVICE="1"
      shift
      ;;
    --start)
      START_SERVICE="1"
      shift
      ;;
    --only)
      ONLY="${2:-all}"
      shift 2
      ;;
    --version)
      printf '%s\n' "$VERSION"
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$ONLY" in
  all|wildfly|pi|docker) ;;
  *)
    echo "ERROR: --only must be wildfly, pi, docker, or all" >&2
    exit 1
    ;;
esac

if [ "$MODE" != "apply" ]; then
  ENABLE_SERVICE="0"
  START_SERVICE="0"
fi

scan_apps
print_report

if [ "$MODE" = "dry-run" ] || [ "$MODE" = "apply" ]; then
  echo
  apply_apps
  echo
  print_report
fi
EOF_SERVICEGUARD

  cat > "$launcher" <<EOF_LAUNCHER
#!/usr/bin/env bash
exec "$app_script" "\$@"
EOF_LAUNCHER

  sed -i -e "s|__SERVICEGUARD_VERSION__|$VERSION|g" "$app_script"
  printf '%s\n' "$VERSION" > "$version_file"

  chmod 0755 "$app_script" "$launcher"
  chmod 0644 "$version_file"
  chown -R "$TARGET_USER:$group_name" "$module_dir"
  chown "$TARGET_USER:$group_name" "$tools_dir" "$launcher" 2>/dev/null || true

  echo "OK: installed SERVICEGUARD $VERSION"
  echo "OK: module: $module_dir"
  echo "OK: launcher: $launcher"
  echo "INFO: no systemd units were created during installation"
}

uninstall_serviceguard() {
  local home_dir utility_dir module_dir tools_dir launcher

  require_target_user
  home_dir="$(target_home)" || { echo "ERROR: cannot resolve HOME for '$TARGET_USER'" >&2; exit 1; }
  utility_dir="$home_dir/UTILITY"
  module_dir="$utility_dir/SERVICEGUARD"
  tools_dir="$utility_dir/TOOLS"
  launcher="$tools_dir/svcguard"

  rm -rf "$module_dir"
  rm -f "$launcher"

  echo "OK: removed SERVICEGUARD local module: $module_dir"
  echo "OK: removed local launcher: $launcher"
  echo "INFO: application systemd services were not removed"
}

case "$MODE" in
  install)
    install_serviceguard
    ;;
  uninstall)
    uninstall_serviceguard
    ;;
esac
