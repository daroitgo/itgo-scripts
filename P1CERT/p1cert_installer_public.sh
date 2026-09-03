#!/usr/bin/env bash
# shellcheck shell=bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -eu

TARGET_USER="${1:-${SUDO_USER:-itgo}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v getent >/dev/null 2>&1 && getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  ITGO_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
else
  ITGO_HOME="/home/${TARGET_USER}"
fi

if [ -z "$ITGO_HOME" ]; then
  printf 'error: could not determine home directory for user %s\n' "$TARGET_USER" >&2
  exit 1
fi

INSTALL_DIR="${ITGO_HOME}/UTILITY/P1CERT"
BIN_DIR="${INSTALL_DIR}/bin"
LOGS_DIR="${INSTALL_DIR}/logs"
STATE_DIR="${INSTALL_DIR}/state"
CERTS_DIR="${INSTALL_DIR}/certs"

install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR" "$LOGS_DIR" "$STATE_DIR" "$CERTS_DIR"
install -m 0755 "${SCRIPT_DIR}/p1cert" "${BIN_DIR}/p1cert"
install -m 0755 "${SCRIPT_DIR}/p1cert_audit.sh" "${BIN_DIR}/p1cert_audit.sh"
install -m 0755 "${SCRIPT_DIR}/p1cert_update.sh" "${BIN_DIR}/p1cert_update.sh"
install -m 0644 "${SCRIPT_DIR}/p1cert.version" "${INSTALL_DIR}/p1cert.version"
if [ -f "${SCRIPT_DIR}/certs/p1-production-certs.zip" ]; then
  install -m 0644 "${SCRIPT_DIR}/certs/p1-production-certs.zip" "${CERTS_DIR}/p1-production-certs.zip"
fi

if id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_GROUP="$(id -gn "$TARGET_USER")"
  chown -R "${TARGET_USER}:${TARGET_GROUP}" "$INSTALL_DIR"
fi

chmod 0755 "$INSTALL_DIR" "$BIN_DIR" "$LOGS_DIR" "$STATE_DIR" "$CERTS_DIR" "${BIN_DIR}/p1cert" "${BIN_DIR}/p1cert_audit.sh" "${BIN_DIR}/p1cert_update.sh"
chmod 0644 "${INSTALL_DIR}/p1cert.version"
ln -sfn "${BIN_DIR}/p1cert" /usr/local/bin/p1cert

"${BIN_DIR}/p1cert" version
