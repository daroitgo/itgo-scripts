#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${1:-itgo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR" "$REPORTS_DIR" "$LOGS_DIR"
install -d -m 0700 "$CONFIG_DIR"

install -m 0755 "${SCRIPT_DIR}/collect_inventory.py" "${BIN_DIR}/collect_inventory.py"
install -m 0755 "${SCRIPT_DIR}/itgo-inv" "${BIN_DIR}/itgo-inv"
install -m 0644 "${SCRIPT_DIR}/inventory.version" "${INSTALL_DIR}/inventory.version"

chown -R "${TARGET_USER}:${TARGET_USER}" "$INSTALL_DIR"

chmod 0755 "$INSTALL_DIR" "$BIN_DIR" "$REPORTS_DIR" "$LOGS_DIR"
chmod 0700 "$CONFIG_DIR"
chmod 0755 "${BIN_DIR}/itgo-inv" "${BIN_DIR}/collect_inventory.py"
chmod 0644 "${INSTALL_DIR}/inventory.version"

ln -sfn "${BIN_DIR}/itgo-inv" /usr/local/bin/itgo-inv

itgo-inv version
