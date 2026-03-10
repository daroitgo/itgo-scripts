#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# TSEQ Installer
# Version: 3.12
#
# Instaluje:
# - /usr/local/sbin/tseq
# - ~/UTILITY/TSEQ
# - systemd service tseq.service
#
# zapis wersji:
#   ~/UTILITY/TSEQ/.tseq_version
# ==========================================================

VERSION="3.12"
TARGET_USER="${1:-itgo}"

need_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    echo "ERROR: uruchom jako root"
    exit 1
  }
}

ensure_user() {
  id "$TARGET_USER" >/dev/null 2>&1 || {
    echo "ERROR: user $TARGET_USER nie istnieje"
    exit 1
  }
}

resolve_home() {
  TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
}

UTILITY_DIR=""
TSEQ_DIR=""
VERSION_FILE=""

setup_paths() {
  UTILITY_DIR="${TARGET_HOME}/UTILITY"
  TSEQ_DIR="${UTILITY_DIR}/TSEQ"
  VERSION_FILE="${TSEQ_DIR}/.tseq_version"
}

ensure_dirs() {
  mkdir -p "$UTILITY_DIR"
  mkdir -p "$TSEQ_DIR"

  chown "$TARGET_USER:$TARGET_USER" "$UTILITY_DIR"
  chown "$TARGET_USER:$TARGET_USER" "$TSEQ_DIR"
}

write_version() {
  echo "$VERSION" > "$VERSION_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$VERSION_FILE"
}

cleanup_old_backups() {
  rm -f /usr/local/sbin/tseq.bak.* 2>/dev/null || true
}

safe_backup() {
  if [[ -f /usr/local/sbin/tseq ]]; then
    rm -f /usr/local/sbin/tseq.bak
    cp -a /usr/local/sbin/tseq /usr/local/sbin/tseq.bak
  fi
}

install_tseq_script() {

cat > /usr/local/sbin/tseq <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

case "$ACTION" in

status)
  echo "TSEQ running status"
  systemctl status tseq.service --no-pager
;;

start)
  sudo systemctl start tseq.service
;;

stop)
  sudo systemctl stop tseq.service
;;

restart)
  sudo systemctl restart tseq.service
;;

*)
  echo "Usage: tseq {status|start|stop|restart}"
  exit 1
;;

esac
EOF

chmod 0755 /usr/local/sbin/tseq
}

install_systemd_service() {

cat > /etc/systemd/system/tseq.service <<EOF
[Unit]
Description=Tomcat Sequential Starter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/tseq status
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tseq.service
}

main() {

need_root
ensure_user
resolve_home
setup_paths

echo "INSTALL v${VERSION}: begin"
echo "USER: $TARGET_USER"
echo "HOME: $TARGET_HOME"
echo "BASE: $TSEQ_DIR"

cleanup_old_backups
safe_backup

ensure_dirs
install_tseq_script
install_systemd_service
write_version

echo "INSTALL v${VERSION}: done"

}

main "$@"