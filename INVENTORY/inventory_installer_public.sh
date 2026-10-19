#!/usr/bin/env bash
set -euo pipefail

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

SYSTEMD_UNIT_DIR="/etc/systemd/system"
SERVICE_UNIT_PATH="${SYSTEMD_UNIT_DIR}/itgo-inventory.service"
TIMER_UNIT_PATH="${SYSTEMD_UNIT_DIR}/itgo-inventory.timer"

install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR" "$REPORTS_DIR" "$LOGS_DIR" "$RUN_DIR"
install -d -m 0700 "$CONFIG_DIR"

install -m 0755 "${SCRIPT_DIR}/collect_inventory.py" "${BIN_DIR}/collect_inventory.py"
install -m 0755 "${SCRIPT_DIR}/itgo-inv" "${BIN_DIR}/itgo-inv"
install -m 0644 "${SCRIPT_DIR}/inventory.version" "${INSTALL_DIR}/inventory.version"

chown -R "${TARGET_USER}:${TARGET_USER}" "$INSTALL_DIR"

chmod 0755 "$INSTALL_DIR" "$BIN_DIR" "$REPORTS_DIR" "$LOGS_DIR" "$RUN_DIR"
chmod 0700 "$CONFIG_DIR"
chmod 0755 "${BIN_DIR}/itgo-inv" "${BIN_DIR}/collect_inventory.py"
chmod 0644 "${INSTALL_DIR}/inventory.version"

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

"${BIN_DIR}/itgo-inv" version
