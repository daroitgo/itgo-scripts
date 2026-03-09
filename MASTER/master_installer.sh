#!/usr/bin/env bash
# shellcheck shell=bash

# Re-exec in bash if started by sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

# ==========================================================
# ITGO Master Installer
# Version: 1.0.6
#
# HOME structure (itgo):
#   ~/UPG
#   ~/BACKUP
#   ~/UTILITY/
#     LOG/OTHER   (master + install logs)
#     LOG/UPDATE  (reserved for update scripts)
#     TMP         (downloaded installers)
#
# Modules:
# - server-status installer (downloaded via wget)
# - SSH history prompt (single block; removes old status-installer block)
# - cleanup installer (downloaded via wget)
# - tseq installer (downloaded via wget)
#
# NOTE:
# - Asks before each module.
# - BOOTSTRAP is one question (user + dirs + sudoers + ACL).
# - Cleans downloaded *.sh from TMP at the end (asks).
# ==========================================================

MASTER_VERSION="1.0.6"

STATUS_VERSION="3.12.7"
CLEANUP_VERSION="1.0.1"
TSEQ_VERSION="3.11"

TARGET_USER="${1:-itgo}"

# OLD Nextcloud distribution (deprecated)
#STATUS_URL='https://helpdesk.itgo.com.pl/nextcloud/index.php/s/Ti4PRnHQQJFXeyn/download'
#CLEANUP_URL='https://helpdesk.itgo.com.pl/nextcloud/index.php/s/WLFcGe3c92qnsfp/download'
#TSEQ_URL='https://helpdesk.itgo.com.pl/nextcloud/index.php/s/JGYMTmykH3aJoSC/download'

GITHUB_OWNER="daroitgo"
GITHUB_REPO="itgo-scripts"

STATUS_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/status-${STATUS_VERSION}/STATUS/status_installer_public.sh"
CLEANUP_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/cleanup-${CLEANUP_VERSION}/CLEANUP/cleanup_installer_public.sh"
TSEQ_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/tseq-${TSEQ_VERSION}/TSEQ/tseq_installer_public.sh"

TMP_LOG="/tmp/itgo-master-install.$(date +%Y%m%d_%H%M%S).log"

ts() { date "+%F %T"; }
prelog() { echo "[$(ts)] $*" | tee -a "$TMP_LOG" >/dev/null; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: uruchom jako root: sudo bash $0 [user]"
    exit 1
  fi
}

prompt_yn() {
  local q="${1:?}" def="${2:-N}" ans=""
  while true; do
    if [[ "$def" == "Y" ]]; then
      read -r -p "$q [Y/n]: " ans || true
      ans="${ans:-Y}"
    else
      read -r -p "$q [y/N]: " ans || true
      ans="${ans:-N}"
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Wpisz: y albo n." ;;
    esac
  done
}

have_user() { id "$TARGET_USER" >/dev/null 2>&1; }

resolve_home() {
  local h
  h="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}' || true)"
  [[ -n "${h:-}" ]] || return 1
  echo "$h"
}

# Derived globals (after home resolved)
ITGO_HOME=""
UTILITY_DIR=""
LOG_DIR=""
LOG_OTHER=""
LOG_UPDATE=""
TMP_DIR=""
FINAL_LOG=""

start_final_logging_if_possible() {
  [[ -n "${LOG_OTHER:-}" && -d "$LOG_OTHER" ]] || return 0
  [[ -n "${FINAL_LOG:-}" ]] && return 0

  FINAL_LOG="$LOG_OTHER/master-install_$(date +%Y%m%d_%H%M%S).log"
  touch "$FINAL_LOG"
  chown "$TARGET_USER:$TARGET_USER" "$FINAL_LOG" 2>/dev/null || true
  chmod 0644 "$FINAL_LOG" 2>/dev/null || true

  exec > >(tee -a "$FINAL_LOG") 2>&1

  echo "[$(ts)] ITGO Master Installer v$MASTER_VERSION"
  echo "[$(ts)] User: $TARGET_USER"
  echo "[$(ts)] Log file: $FINAL_LOG"

  if [[ -f "$TMP_LOG" ]]; then
    echo "[$(ts)] --- pre-log (from $TMP_LOG) ---"
    cat "$TMP_LOG" || true
    echo "[$(ts)] --- end pre-log ---"
  fi
}

ensure_user_and_password_if_missing() {
  if have_user; then
    prelog "OK: user '$TARGET_USER' exists (skip create/passwd)."
    return 0
  fi

  echo "User '$TARGET_USER' nie istnieje."
  if ! prompt_yn "Utworzyć go (wheel) i ustawić hasło?" "Y"; then
    echo "ERROR: bez użytkownika '$TARGET_USER' nie da się kontynuować."
    exit 1
  fi

  prelog "ACTION: useradd -m -G wheel $TARGET_USER"
  useradd -m -G wheel "$TARGET_USER"

  prelog "ACTION: passwd $TARGET_USER (interactive)"
  passwd "$TARGET_USER"
}

ensure_home_dirs() {
  ITGO_HOME="$(resolve_home)" || { prelog "ERROR: cannot resolve home for $TARGET_USER"; exit 1; }

  UTILITY_DIR="$ITGO_HOME/UTILITY"
  LOG_DIR="$UTILITY_DIR/LOG"
  LOG_OTHER="$LOG_DIR/OTHER"
  LOG_UPDATE="$LOG_DIR/UPDATE"
  TMP_DIR="$UTILITY_DIR/TMP"

  prelog "ACTION: ensuring HOME structure under $ITGO_HOME"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$ITGO_HOME/UPG"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$ITGO_HOME/BACKUP"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$LOG_DIR"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$LOG_OTHER"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$LOG_UPDATE"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

  start_final_logging_if_possible
}

ensure_sudo_nopasswd_block() {
  local f="/etc/sudoers.d/itgo-nopasswd"
  if [[ -f "$f" ]]; then
    echo "[$(ts)] OK: sudoers drop-in exists ($f)."
    return 0
  fi

  if prompt_yn "Dodać sudo NOPASSWD dla '$TARGET_USER' (itgo ALL=(ALL) NOPASSWD: ALL)?" "N"; then
    echo "[$(ts)] ACTION: writing $f"
    cat > "$f" <<EOF_SUD
${TARGET_USER} ALL=(ALL) NOPASSWD: ALL
EOF_SUD
    chmod 0440 "$f"
    if visudo -cf "$f" >/dev/null; then
      echo "[$(ts)] OK: sudoers validated."
    else
      echo "[$(ts)] ERROR: sudoers validation failed, reverting."
      rm -f "$f"
      exit 1
    fi
  else
    echo "[$(ts)] SKIP: sudo NOPASSWD not set."
  fi
}

ensure_acls_block() {
  if ! command -v setfacl >/dev/null 2>&1; then
    echo "[$(ts)] WARN: setfacl not found. Skipping ACL."
    return 0
  fi

  if prompt_yn "Ustawić ACL-e dla /srv (rwx+default) oraz /etc/amms.conf (rw)?" "Y"; then
    echo "[$(ts)] ACTION: setfacl on /srv"
    setfacl -R -m "u:${TARGET_USER}:rwx" /srv
    setfacl -R -d -m "u:${TARGET_USER}:rwx" /srv

    if [[ -f /etc/amms.conf ]]; then
      echo "[$(ts)] ACTION: setfacl on /etc/amms.conf"
      setfacl -m "u:${TARGET_USER}:rw" /etc/amms.conf
    else
      echo "[$(ts)] WARN: /etc/amms.conf not found; skipped."
    fi

    echo "[$(ts)] OK: ACL block done."
  else
    echo "[$(ts)] SKIP: ACL block."
  fi
}

ensure_wget() {
  if command -v wget >/dev/null 2>&1; then
    echo "[$(ts)] OK: wget present."
    return 0
  fi

  if ! prompt_yn "Brak wget. Zainstalować wget teraz (dnf/yum)?" "Y"; then
    echo "[$(ts)] ERROR: wget wymagany do pobrania modułów."
    return 1
  fi

  if command -v dnf >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: dnf -y install wget"
    dnf -y install wget
  elif command -v yum >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: yum -y install wget"
    yum -y install wget
  else
    echo "[$(ts)] ERROR: brak dnf/yum."
    return 1
  fi
}

download_to_tmp() {
  local url="${1:?}" out="${2:?}"
  [[ -d "$TMP_DIR" ]] || { echo "[$(ts)] ERROR: missing $TMP_DIR"; return 1; }

  echo "[$(ts)] DOWNLOAD: $url -> $out"
  wget -qO "$out" "$url"
  chmod 0755 "$out"
  chown "$TARGET_USER:$TARGET_USER" "$out" 2>/dev/null || true
}

run_module_root() {
  local script="${1:?}" args="${2:-}"
  echo "[$(ts)] RUN(root): bash $script $args"
  bash "$script" $args
}

run_module_as_itgo() {
  local script="${1:?}" args="${2:-}"
  echo "[$(ts)] RUN(itgo): sudo -u $TARGET_USER bash $script $args"
  sudo -u "$TARGET_USER" bash "$script" $args
}

cleanup_downloaded_installers() {
  if [[ -d "$TMP_DIR" ]]; then
    if prompt_yn "Usunąć pobrane instalery (*.sh) z $TMP_DIR?" "Y"; then
      echo "[$(ts)] ACTION: rm -f $TMP_DIR/*.sh"
      rm -f -- "$TMP_DIR"/*.sh 2>/dev/null || true
      echo "[$(ts)] OK: installers removed."
    else
      echo "[$(ts)] SKIP: keeping downloaded installers."
    fi
  fi
}

# --- SINGLE BLOCK installer: ask history, then run status ONCE
# Also removes old status-installer block so we don't get double status.
install_ssh_history_prompt_block() {
  local bp="$ITGO_HOME/.bash_profile"
  local bak="$bp.bak.$(date +%Y%m%d_%H%M%S)"

  local START="# >>> ITGO SSH HISTORY PROMPT (auto) >>>"
  local END="# <<< ITGO SSH HISTORY PROMPT (auto) <<<"

  local OLD_START="# --- system-audit on SSH login (background) ---"
  local OLD_END="# --- /system-audit ---"

  local BLOCK
  BLOCK=$(cat <<'BEOF'
# >>> ITGO SSH HISTORY PROMPT (auto) >>>
case "$-" in *i*) : ;; *) return 0 ;; esac
[[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]] || return 0

if [[ -z "${ITGO_ASKED_HISTORY:-}" ]]; then
  export ITGO_ASKED_HISTORY=1

  echo
  read -r -p "Zapisywać historię bash dla tej sesji? [y/N]: " __ans
  case "${__ans,,}" in
    y|yes)
      echo "OK: historia będzie zapisywana (ta sesja)."
      ;;
    *)
      echo "OK: historia NIE będzie zapisywana (ta sesja)."
      unset HISTFILE
      export HISTSIZE=0
      export HISTFILESIZE=0
      set +o history 2>/dev/null || true
      history -c 2>/dev/null || true
      ;;
  esac
fi

sleep 0.05
command -v status >/dev/null 2>&1 && status 2>/dev/null || true
# <<< ITGO SSH HISTORY PROMPT (auto) <<<
BEOF
)

  echo "[$(ts)] ACTION: patch $bp (replace old status block + ensure single prompt+status)"
  touch "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  cp -a "$bp" "$bak"

  # remove our previous block if exists
  if grep -qF "$START" "$bp" 2>/dev/null; then
    awk -v start="$START" -v end="$END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bp" > "${bp}.tmp"
    mv "${bp}.tmp" "$bp"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  fi

  # remove old status-installer block if exists
  if grep -qF "$OLD_START" "$bp" 2>/dev/null; then
    awk -v start="$OLD_START" -v end="$OLD_END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bp" > "${bp}.tmp"
    mv "${bp}.tmp" "$bp"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  fi

  # append fresh single block
  printf "\n%s\n" "$BLOCK" >> "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true

  echo "[$(ts)] OK: installed single SSH prompt+status block. Backup: $bak"
}

bootstrap_block() {
  ensure_user_and_password_if_missing
  ensure_home_dirs
  ensure_sudo_nopasswd_block
  ensure_acls_block
}

main() {
  need_root
  prelog "BEGIN: ITGO Master Installer v$MASTER_VERSION user=$TARGET_USER"

  if prompt_yn "BOOTSTRAP: user '$TARGET_USER' + katalogi HOME + (opcjonalnie) sudoers + ACL?" "Y"; then
    bootstrap_block
  else
    echo "[$(ts)] SKIP: bootstrap."
    if have_user; then
      ITGO_HOME="$(resolve_home)" || true
      UTILITY_DIR="$ITGO_HOME/UTILITY"
      LOG_DIR="$UTILITY_DIR/LOG"
      LOG_OTHER="$LOG_DIR/OTHER"
      LOG_UPDATE="$LOG_DIR/UPDATE"
      TMP_DIR="$UTILITY_DIR/TMP"
      start_final_logging_if_possible
    fi
  fi

  # Must have dirs if we want to download installers
  if [[ -z "${TMP_DIR:-}" || ! -d "${TMP_DIR:-/nonexistent}" ]]; then
    # try to resolve if user exists
    if have_user; then
      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      UTILITY_DIR="$ITGO_HOME/UTILITY"
      LOG_DIR="$UTILITY_DIR/LOG"
      LOG_OTHER="$LOG_DIR/OTHER"
      LOG_UPDATE="$LOG_DIR/UPDATE"
      TMP_DIR="$UTILITY_DIR/TMP"
      # if still missing, warn
      [[ -d "$TMP_DIR" ]] || echo "[$(ts)] WARN: $TMP_DIR missing; modules download may fail."
    fi
  fi

  local status_sh="$TMP_DIR/status_installer_public.sh"
  local cleanup_sh="$TMP_DIR/cleanup_installer_public.sh"
  local tseq_sh="$TMP_DIR/tseq_installer_public.sh"

  if prompt_yn "MODUŁ: Server-Status (systemd + /usr/local + /var/cache)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
    download_to_tmp "$STATUS_URL" "$status_sh"
    run_module_root "$status_sh" "$TARGET_USER"
    echo "[$(ts)] OK: Server-Status done."
  else
    echo "[$(ts)] SKIP: Server-Status."
  fi

  if prompt_yn "MODUŁ: SSH login prompt: pytać czy zapisywać historię + potem status (bez dubli)?" "Y"; then
    if ! have_user; then
      echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
      exit 1
    fi
    ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
    [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }
    install_ssh_history_prompt_block
  else
    echo "[$(ts)] SKIP: SSH history prompt."
  fi

  if prompt_yn "MODUŁ: Cleanup (usuń ~/UPG/*.xml + czyść ~/.cache przy wylogowaniu z SSH)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
    download_to_tmp "$CLEANUP_URL" "$cleanup_sh"
    run_module_as_itgo "$cleanup_sh"
    echo "[$(ts)] OK: Cleanup done."
  else
    echo "[$(ts)] SKIP: Cleanup."
  fi

  if prompt_yn "MODUŁ: TSEQ (systemd + /usr/local/sbin/tseq + ~/UTILITY/TSEQ)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
    download_to_tmp "$TSEQ_URL" "$tseq_sh"
    run_module_root "$tseq_sh"
    echo "[$(ts)] OK: TSEQ done."
  else
    echo "[$(ts)] SKIP: TSEQ."
  fi

  cleanup_downloaded_installers

  echo "[$(ts)] DONE."
  [[ -n "${FINAL_LOG:-}" ]] && echo "[$(ts)] Master log: $FINAL_LOG"
}

main "$@"