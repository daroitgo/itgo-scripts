#!/usr/bin/env bash
set -euo pipefail
TARGET_USER="${1:-itgo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v getent >/dev/null 2>&1 && getent passwd "$TARGET_USER" >/dev/null 2>&1 || { printf 'ERROR: target user not found: %s\n' "$TARGET_USER" >&2; exit 1; }
ITGO_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d "$ITGO_HOME" ]] || { printf 'ERROR: home directory is unavailable.\n' >&2; exit 1; }
INSTALL_DIR="$ITGO_HOME/UTILITY/LOGGUARD"
install -d -m 0700 "$INSTALL_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/config" "$INSTALL_DIR/state" "$INSTALL_DIR/logs" "$INSTALL_DIR/logs/runs" "$INSTALL_DIR/archive"
install -m 0700 "$SCRIPT_DIR/logguard" "$INSTALL_DIR/bin/logguard"
install -m 0600 "$SCRIPT_DIR/logguard.version" "$INSTALL_DIR/logguard.version"
[[ -e "$INSTALL_DIR/config/logguard.conf" ]] || install -m 0600 "$SCRIPT_DIR/logguard.conf" "$INSTALL_DIR/config/logguard.conf"
chown -R "$TARGET_USER:$TARGET_GROUP" "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 0700 {} +
find "$INSTALL_DIR" -type f -exec chmod 0600 {} +
chmod 0700 "$INSTALL_DIR/bin/logguard"
"$INSTALL_DIR/bin/logguard" version
