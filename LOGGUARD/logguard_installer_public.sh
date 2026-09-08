#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${1:-itgo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v getent >/dev/null 2>&1 || ! getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  printf 'ERROR: target user %s was not found via getent passwd.\n' "$TARGET_USER" >&2
  exit 1
fi

ITGO_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

if [[ -z "$ITGO_HOME" || ! -d "$ITGO_HOME" ]]; then
  printf 'ERROR: could not determine an existing home directory for user %s.\n' "$TARGET_USER" >&2
  exit 1
fi

INSTALL_DIR="${ITGO_HOME}/UTILITY/LOGGUARD"
BIN_DIR="${INSTALL_DIR}/bin"
CONFIG_DIR="${INSTALL_DIR}/config"
STATE_DIR="${INSTALL_DIR}/state"
LOGS_DIR="${INSTALL_DIR}/logs"
ARCHIVE_DIR="${INSTALL_DIR}/archive"

install -d -m 0700 "$INSTALL_DIR" "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOGS_DIR" "$ARCHIVE_DIR"
install -m 0700 "${SCRIPT_DIR}/logguard" "${BIN_DIR}/logguard"
install -m 0600 "${SCRIPT_DIR}/logguard.version" "${INSTALL_DIR}/logguard.version"

chown -R "${TARGET_USER}:${TARGET_GROUP}" "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 0700 {} +
find "$INSTALL_DIR" -type f -exec chmod 0600 {} +
chmod 0700 "${BIN_DIR}/logguard"

"${BIN_DIR}/logguard" version
