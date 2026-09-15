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
systemctl enable --now logguard.timer
"$INSTALL_DIR/bin/logguard" version
