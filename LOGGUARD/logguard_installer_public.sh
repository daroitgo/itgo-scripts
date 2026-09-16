#!/usr/bin/env bash
set -euo pipefail
UNINSTALL=0
if [[ "${1:-}" == "--uninstall" ]]; then
  UNINSTALL=1
  TARGET_USER="${2:-itgo}"
else
  TARGET_USER="${1:-itgo}"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { printf 'ERROR: run installer as root.\n' >&2; exit 1; }
command -v getent >/dev/null 2>&1 && getent passwd "$TARGET_USER" >/dev/null 2>&1 || { printf 'ERROR: target user not found: %s\n' "$TARGET_USER" >&2; exit 1; }
ITGO_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d "$ITGO_HOME" ]] || { printf 'ERROR: home directory is unavailable.\n' >&2; exit 1; }
INSTALL_DIR="$ITGO_HOME/UTILITY/LOGGUARD"
SYSTEM_WRAPPER=/usr/local/sbin/itgo-logguard-run
PLATFORMS_FILE="$INSTALL_DIR/config/platforms.conf"
PLATFORMS_CONFIG_EXISTED=0
[[ -e "$PLATFORMS_FILE" ]] && PLATFORMS_CONFIG_EXISTED=1

platform_is_technical() {
  local component lower
  local -a components=()
  IFS=/ read -r -a components <<< "$1"
  for component in "${components[@]}"; do
    lower="${component,,}"
    [[ "$lower" == *_new || "$lower" == *_old ]] && return 0
  done
  return 1
}

discover_platforms() {
  local base path
  local -a found=() sorted=()
  DISCOVERED_PLATFORMS=()
  for base in /srv /opt; do
    [[ -d "$base" && -r "$base" ]] || continue
    while IFS= read -r -d '' path; do
      [[ "$path" == /srv/BackupLog || "$path" == /srv/BackupLog/* ]] && continue
      platform_is_technical "$path" || found+=("$path")
    done < <(
      if [[ "$base" == /srv ]]; then
        find -P "$base" -xdev -maxdepth 5 \( -path /srv/BackupLog -prune \) -o \( -type d \( -iname integrationplatform -o -iname 'integrationplatform_*' \) -print0 \) 2>/dev/null || true
      else
        find -P "$base" -xdev -maxdepth 5 -type d \( -iname integrationplatform -o -iname 'integrationplatform_*' \) -print0 2>/dev/null || true
      fi
    )
  done
  if (( ${#found[@]} > 0 )); then
    while IFS= read -r -d '' path; do sorted+=("$path"); done < <(printf '%s\0' "${found[@]}" | sort -z -u)
    DISCOVERED_PLATFORMS=("${sorted[@]}")
  fi
}

select_initial_platforms() {
  local answer item index i selected duplicate
  SELECTED_PLATFORMS=()
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'WARNING: no interactive terminal; writing empty LOGGUARD platforms.conf and leaving monitoring inactive.\n' >&2
    return 0
  fi
  printf 'Detected Integration Platforms:\n'
  if (( ${#DISCOVERED_PLATFORMS[@]} == 0 )); then
    printf '  (none)\n'
  else
    for i in "${!DISCOVERED_PLATFORMS[@]}"; do printf '  [%s] %s\n' "$((i + 1))" "${DISCOVERED_PLATFORMS[$i]}"; done
  fi
  while :; do
    SELECTED_PLATFORMS=()
    printf 'Select monitored platforms (ENTER=all, numbers separated by spaces, NONE=none): '
    IFS= read -r answer || { printf 'WARNING: selection unavailable; writing empty configuration.\n' >&2; return 0; }
    answer="${answer#${answer%%[![:space:]]*}}"; answer="${answer%${answer##*[![:space:]]}}"
    if [[ -z "$answer" ]]; then SELECTED_PLATFORMS=("${DISCOVERED_PLATFORMS[@]}"); break; fi
    [[ "${answer^^}" == NONE ]] && break
    for item in $answer; do
      [[ "$item" =~ ^[0-9]+$ ]] || { printf 'ERROR: use ENTER, NONE, or valid numbers.\n' >&2; continue 2; }
      index=$((10#$item - 1))
      (( index >= 0 && index < ${#DISCOVERED_PLATFORMS[@]} )) || { printf 'ERROR: invalid platform number: %s\n' "$item" >&2; continue 2; }
      duplicate=0
      for selected in "${SELECTED_PLATFORMS[@]}"; do
        [[ "$selected" == "${DISCOVERED_PLATFORMS[$index]}" ]] && { duplicate=1; break; }
      done
      (( duplicate )) || SELECTED_PLATFORMS+=("${DISCOVERED_PLATFORMS[$index]}")
    done
    break
  done
  printf 'Selected monitored platforms:\n'
  if (( ${#SELECTED_PLATFORMS[@]} == 0 )); then printf '  (none)\n'; else printf '  %s\n' "${SELECTED_PLATFORMS[@]}"; fi
}

write_initial_platforms() {
  local temporary
  temporary="$(mktemp "${PLATFORMS_FILE}.tmp.XXXXXX")"
  printf '%s\n' "${SELECTED_PLATFORMS[@]}" > "$temporary"
  chown "$TARGET_USER:$TARGET_GROUP" "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$PLATFORMS_FILE"
}

if (( UNINSTALL )); then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now logguard.timer 2>/dev/null || true
    systemctl stop logguard.service 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/logguard.timer /etc/systemd/system/logguard.service "$SYSTEM_WRAPPER"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
  rm -rf -- "$INSTALL_DIR"
  printf 'LOGGUARD uninstalled for user: %s\n' "$TARGET_USER"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || { printf 'ERROR: systemctl is required.\n' >&2; exit 1; }
install -d -m 0700 "$INSTALL_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/config" "$INSTALL_DIR/state" "$INSTALL_DIR/logs" "$INSTALL_DIR/logs/runs" "$INSTALL_DIR/archive"
install -m 0700 "$SCRIPT_DIR/logguard" "$INSTALL_DIR/bin/logguard"
install -m 0600 "$SCRIPT_DIR/logguard.version" "$INSTALL_DIR/logguard.version"
[[ -e "$INSTALL_DIR/config/logguard.conf" ]] || install -m 0600 "$SCRIPT_DIR/logguard.conf" "$INSTALL_DIR/config/logguard.conf"
chown -R "$TARGET_USER:$TARGET_GROUP" "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 0700 {} +
find "$INSTALL_DIR" -type f -exec chmod 0600 {} +
chmod 0700 "$INSTALL_DIR/bin/logguard"
if (( ! PLATFORMS_CONFIG_EXISTED )); then
  discover_platforms
  select_initial_platforms
  write_initial_platforms
fi
install -o root -g root -m 0755 /dev/stdin "$SYSTEM_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail 2>/dev/null || set -eu
INSTALL_DIR="$INSTALL_DIR"
LAUNCHER="\$INSTALL_DIR/bin/logguard"
[[ "\$#" -eq 0 ]] || { printf 'ERROR: itgo-logguard-run does not accept arguments.\\n' >&2; exit 2; }
[[ -x "\$LAUNCHER" ]] || { printf 'ERROR: LOGGUARD launcher is unavailable or not executable: %s\\n' "\$LAUNCHER" >&2; exit 1; }
BASH_BIN="\$(command -v bash)"
[[ -x "\$BASH_BIN" ]] || { printf 'ERROR: bash is unavailable.\\n' >&2; exit 1; }
exec "\$BASH_BIN" "\$LAUNCHER" run
EOF
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/logguard.service <<EOF
[Unit]
Description=LOGGUARD Integration Platform log protection

[Service]
Type=oneshot
User=root
Group=root
ExecStart=$SYSTEM_WRAPPER
EOF
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/logguard.timer <<'EOF'
[Unit]
Description=Run LOGGUARD every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true
Unit=logguard.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
if (( ! PLATFORMS_CONFIG_EXISTED )); then
  if (( ${#SELECTED_PLATFORMS[@]} > 0 )); then
    systemctl enable --now logguard.timer
  else
    systemctl disable --now logguard.timer 2>/dev/null || true
  fi
fi
"$INSTALL_DIR/bin/logguard" version
