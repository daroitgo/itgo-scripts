#!/usr/bin/env bash
# shellcheck shell=bash

# Re-exec in bash if started by sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail 2>/dev/null || set -eu

# ==========================================================
# ITGO Master Installer
# Version: 1.1.1
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
# - downloader app installer deploy (downloaded via wget)
#
# Extra steps:
# - optional install/check of nano, mc, rsync, dos2unix, jq, wget
# - optional ~/.bash_logout history cleanup block
# - optional add user to docker group
#
# NOTE:
# - Asks before each module.
# - BOOTSTRAP is one question (user + dirs + sudoers + ACL + docker group).
# - Cleans downloaded *.sh from TMP at the end (asks).
# - Bash backups are kept as single .bak files (no timestamp pile-up).
# ==========================================================

MASTER_VERSION="1.1.2"

STATUS_VERSION="3.12.9"
CLEANUP_VERSION="1.0.2"
TSEQ_VERSION="3.12.1"
DOWNLOADER_APP_VERSION="1.0.1"
UPGBUILDER_VERSION="0.0.3"

TARGET_USER="${1:-itgo}"

GITHUB_OWNER="daroitgo"
GITHUB_REPO="itgo-scripts"

STATUS_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/status-${STATUS_VERSION}/STATUS/status_installer_public.sh"
CLEANUP_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/cleanup-${CLEANUP_VERSION}/CLEANUP/cleanup_installer_public.sh"
TSEQ_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/tseq-${TSEQ_VERSION}/TSEQ/tseq_installer_public.sh"
DOWNLOADER_APP_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/downloader_app-${DOWNLOADER_APP_VERSION}/DOWNLOADER_APP/upg_installer.sh"
UPGBUILDER_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/upgbuilder-${UPGBUILDER_VERSION}/UPGBUILDER/upgbuilder.sh"

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

pkg_installed() {
  local pkg="${1:?}"
  rpm -q "$pkg" >/dev/null 2>&1
}

install_packages() {
  local missing=("$@")
  [[ "${#missing[@]}" -gt 0 ]] || return 0

  if command -v dnf >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: dnf -y install ${missing[*]}"
    dnf -y install "${missing[@]}"
  elif command -v yum >/dev/null 2>&1; then
    echo "[$(ts)] ACTION: yum -y install ${missing[*]}"
    yum -y install "${missing[@]}"
  else
    echo "[$(ts)] ERROR: brak dnf/yum."
    return 1
  fi
}

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
  echo "[$(ts)] Module versions:"
  echo "[$(ts)]   STATUS         : $STATUS_VERSION"
  echo "[$(ts)]   CLEANUP       : $CLEANUP_VERSION"
  echo "[$(ts)]   TSEQ          : $TSEQ_VERSION"
  echo "[$(ts)]   DOWNLOADER_APP: $DOWNLOADER_APP_VERSION"
  echo "[$(ts)]   UPGBUILDER    : $UPGBUILDER_VERSION"

  if [[ -f "$TMP_LOG" ]]; then
    echo "[$(ts)] --- pre-log (from $TMP_LOG) ---"
    cat "$TMP_LOG" || true
    echo "[$(ts)] --- end pre-log ---"
  fi
}

safe_backup() {
  local f="${1:?}"
  [[ -e "$f" ]] || return 0
  rm -f "${f}.bak" 2>/dev/null || true
  cp -a "$f" "${f}.bak"
}

cleanup_old_bash_backups() {
  local files=(
    "$ITGO_HOME/.bash_profile"
    "$ITGO_HOME/.bashrc"
    "$ITGO_HOME/.bash_logout"
  )
  local f=""
  for f in "${files[@]}"; do
    rm -f "${f}.bak."* 2>/dev/null || true
  done
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

  cleanup_old_bash_backups
  start_final_logging_if_possible
}

ensure_sudo_nopasswd_block() {
  local f="/etc/sudoers.d/itgo-nopasswd"
  if [[ -f "$f" ]]; then
    echo "[$(ts)] OK: sudoers drop-in exists ($f)."
    return 0
  fi

  if prompt_yn "Dodać sudo NOPASSWD dla '$TARGET_USER' (${TARGET_USER} ALL=(ALL) NOPASSWD: ALL)?" "N"; then
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

ensure_docker_group_membership() {
  if ! have_user; then
    echo "[$(ts)] WARN: user '$TARGET_USER' nie istnieje. Pomijam docker group."
    return 0
  fi

  if ! getent group docker >/dev/null 2>&1; then
    echo "[$(ts)] WARN: grupa 'docker' nie istnieje. Pomijam dopięcie użytkownika."
    return 0
  fi

  if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    echo "[$(ts)] OK: user '$TARGET_USER' już jest w grupie docker."
    return 0
  fi

  if prompt_yn "Dodać użytkownika '$TARGET_USER' do grupy docker?" "Y"; then
    echo "[$(ts)] ACTION: usermod -aG docker $TARGET_USER"
    usermod -aG docker "$TARGET_USER"
    echo "[$(ts)] OK: user '$TARGET_USER' dodany do grupy docker."
    echo "[$(ts)] INFO: zmiana zadziała po ponownym logowaniu użytkownika."
  else
    echo "[$(ts)] SKIP: dopięcie do grupy docker."
  fi
}

ensure_basic_tools_step() {
  local wanted=(nano mc rsync dos2unix jq wget)
  local missing=()
  local p=""

  for p in "${wanted[@]}"; do
    if pkg_installed "$p"; then
      echo "[$(ts)] OK: pakiet '$p' już zainstalowany."
    else
      echo "[$(ts)] WARN: pakiet '$p' nie jest zainstalowany."
      missing+=("$p")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "[$(ts)] OK: wszystkie pakiety bazowe są już obecne."
    return 0
  fi

  if prompt_yn "Brakuje: ${missing[*]}. Zainstalować teraz?" "Y"; then
    install_packages "${missing[@]}"
    echo "[$(ts)] OK: pakiety bazowe zainstalowane."
  else
    echo "[$(ts)] SKIP: instalacja pakietów bazowych."
  fi
}

install_bash_logout_history_clear() {
  local bl="$ITGO_HOME/.bash_logout"

  local START="# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>"
  local END="# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<"

  local BLOCK
  BLOCK=$(cat <<'BEOF'
# >>> ITGO HISTORY CLEAR ON LOGOUT (auto) >>>
history -c && history -w
# <<< ITGO HISTORY CLEAR ON LOGOUT (auto) <<<
BEOF
)

  echo "[$(ts)] ACTION: patch $bl (history clear on logout)"
  touch "$bl"
  chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
  chmod 0644 "$bl" 2>/dev/null || true
  safe_backup "$bl"

  if grep -qF "$START" "$bl" 2>/dev/null; then
    awk -v start="$START" -v end="$END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bl" > "${bl}.tmp"
    mv "${bl}.tmp" "$bl"
    chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
    chmod 0644 "$bl" 2>/dev/null || true
  fi

  printf "\n%s\n" "$BLOCK" >> "$bl"
  chown "$TARGET_USER:$TARGET_USER" "$bl" 2>/dev/null || true
  chmod 0644 "$bl" 2>/dev/null || true

  echo "[$(ts)] OK: ~/.bash_logout updated. Backup: ${bl}.bak"
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

install_downloader_app_script() {
  local src="${1:?}"
  local app_dir="$UTILITY_DIR/DOWNLOADER_APP"
  local dst="$app_dir/upg_installer.sh"
  local link="/usr/local/bin/dwupg"
  local version_file="$app_dir/.downloader_version"

  echo "[$(ts)] ACTION: install downloader app into $app_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$app_dir"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$src" "$dst"

  printf "%s\n" "$DOWNLOADER_APP_VERSION" > "$version_file"
  chown "$TARGET_USER:$TARGET_USER" "$version_file" 2>/dev/null || true
  chmod 0644 "$version_file" 2>/dev/null || true

  if [[ -L "$link" || -e "$link" ]]; then
    echo "[$(ts)] ACTION: remove existing $link"
    rm -f "$link"
  fi

  ln -s "$dst" "$link"
  chmod 0755 "$dst" 2>/dev/null || true

  echo "[$(ts)] OK: downloader app installed:"
  echo "[$(ts)]   script : $dst"
  echo "[$(ts)]   symlink: $link"
  echo "[$(ts)]   verfile: $version_file"
  echo "[$(ts)]   usage  : dwupg"
}

install_upgbuilder_script() {
  local src="${1:?}"
  local app_dir="$UTILITY_DIR/UPGbuilder"
  local dst="$app_dir/upgbuilder.sh"
  local link="/usr/local/bin/upgbuilder"
  local version_file="$app_dir/.upgbuilder_version"

  echo "[$(ts)] ACTION: install upgbuilder into $app_dir"
  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$app_dir"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$src" "$dst"

  printf "%s\n" "$UPGBUILDER_VERSION" > "$version_file"
  chown "$TARGET_USER:$TARGET_USER" "$version_file" 2>/dev/null || true
  chmod 0644 "$version_file" 2>/dev/null || true

  if [[ -L "$link" || -e "$link" ]]; then
    echo "[$(ts)] ACTION: remove existing $link"
    rm -f "$link"
  fi

  ln -s "$dst" "$link"
  chmod 0755 "$dst" 2>/dev/null || true

  echo "[$(ts)] OK: upgbuilder installed:"
  echo "[$(ts)]   script : $dst"
  echo "[$(ts)]   symlink: $link"
  echo "[$(ts)]   verfile: $version_file"
  echo "[$(ts)]   usage  : upgbuilder"
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

install_ssh_history_prompt_block() {
  local bp="$ITGO_HOME/.bash_profile"

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
  chmod 0644 "$bp" 2>/dev/null || true
  safe_backup "$bp"

  if grep -qF "$START" "$bp" 2>/dev/null; then
    awk -v start="$START" -v end="$END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bp" > "${bp}.tmp"
    mv "${bp}.tmp" "$bp"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
    chmod 0644 "$bp" 2>/dev/null || true
  fi

  if grep -qF "$OLD_START" "$bp" 2>/dev/null; then
    awk -v start="$OLD_START" -v end="$OLD_END" '
      $0==start {inside=1; next}
      $0==end   {inside=0; next}
      !inside   {print}
    ' "$bp" > "${bp}.tmp"
    mv "${bp}.tmp" "$bp"
    chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
    chmod 0644 "$bp" 2>/dev/null || true
  fi

  printf "\n%s\n" "$BLOCK" >> "$bp"
  chown "$TARGET_USER:$TARGET_USER" "$bp" 2>/dev/null || true
  chmod 0644 "$bp" 2>/dev/null || true

  echo "[$(ts)] OK: installed single SSH prompt+status block. Backup: ${bp}.bak"
}

bootstrap_block() {
  ensure_user_and_password_if_missing
  ensure_home_dirs
  ensure_sudo_nopasswd_block
  ensure_acls_block
  ensure_docker_group_membership
}

prepare_dirs_after_skip_bootstrap() {
  if have_user; then
    ITGO_HOME="$(resolve_home)" || true
    UTILITY_DIR="$ITGO_HOME/UTILITY"
    LOG_DIR="$UTILITY_DIR/LOG"
    LOG_OTHER="$LOG_DIR/OTHER"
    LOG_UPDATE="$LOG_DIR/UPDATE"
    TMP_DIR="$UTILITY_DIR/TMP"
    cleanup_old_bash_backups
    start_final_logging_if_possible
  fi
}

section() {
  echo
  echo "===================================================="
  echo "[$(ts)] $*"
  echo "===================================================="
}

main() {
  need_root
  prelog "BEGIN: ITGO Master Installer v$MASTER_VERSION user=$TARGET_USER"

  section "SEKCJA 1/6 - BOOTSTRAP"
  if prompt_yn "BOOTSTRAP: user '$TARGET_USER' + katalogi HOME + (opcjonalnie) sudoers + ACL + docker group?" "Y"; then
    bootstrap_block
  else
    echo "[$(ts)] SKIP: bootstrap."
    prepare_dirs_after_skip_bootstrap
  fi

  section "SEKCJA 2/6 - NARZĘDZIA SYSTEMOWE"
  if prompt_yn "KROK: sprawdzić nano, mc, rsync, dos2unix, jq, wget i doinstalować brakujące?" "Y"; then
    ensure_basic_tools_step
  else
    echo "[$(ts)] SKIP: pakiety bazowe."
  fi

  section "SEKCJA 3/6 - ZACHOWANIE SHELLA"
  if prompt_yn "KROK: ustawić w ~/.bash_logout: history -c && history -w ?" "Y"; then
    if ! have_user; then
      echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
      exit 1
    fi
    ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
    [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }
    install_bash_logout_history_clear
  else
    echo "[$(ts)] SKIP: ~/.bash_logout history clear."
  fi

  if [[ -z "${TMP_DIR:-}" || ! -d "${TMP_DIR:-/nonexistent}" ]]; then
    if have_user; then
      ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
      UTILITY_DIR="$ITGO_HOME/UTILITY"
      LOG_DIR="$UTILITY_DIR/LOG"
      LOG_OTHER="$LOG_DIR/OTHER"
      LOG_UPDATE="$LOG_DIR/UPDATE"
      TMP_DIR="$UTILITY_DIR/TMP"
      [[ -d "$TMP_DIR" ]] || echo "[$(ts)] WARN: $TMP_DIR missing; modules download may fail."
    fi
  fi

  local status_sh="$TMP_DIR/status_installer_public.sh"
  local cleanup_sh="$TMP_DIR/cleanup_installer_public.sh"
  local tseq_sh="$TMP_DIR/tseq_installer_public.sh"
  local downloader_app_sh="$TMP_DIR/upg_installer.sh"
  local upgbuilder_sh="$TMP_DIR/upgbuilder.sh"

  section "SEKCJA 4/6 - MODUŁY CORE"
  if prompt_yn "MODUŁ: Server-Status (systemd + /usr/local + /var/cache)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
    download_to_tmp "$STATUS_URL" "$status_sh"
    run_module_root "$status_sh" "$TARGET_USER"
    echo "[$(ts)] OK: Server-Status done."
  else
    echo "[$(ts)] SKIP: Server-Status."
  fi

  if prompt_yn "MODUŁ: TSEQ (systemd + /usr/local/sbin/tseq + ~/UTILITY/TSEQ)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }
    download_to_tmp "$TSEQ_URL" "$tseq_sh"
    run_module_root "$tseq_sh"
    echo "[$(ts)] OK: TSEQ done."
  else
    echo "[$(ts)] SKIP: TSEQ."
  fi

  section "SEKCJA 5/6 - HOOKI I NARZĘDZIA UŻYTKOWE"
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

  if prompt_yn "MODUŁ: DOWNLOADER_APP (zainstalować ~/UTILITY/DOWNLOADER_APP/upg_installer.sh i symlink /usr/local/bin/dwupg)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

    if ! have_user; then
      echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
      exit 1
    fi

    ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
    [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

    UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
    TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

    [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
    [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

    download_to_tmp "$DOWNLOADER_APP_URL" "$downloader_app_sh"
    install_downloader_app_script "$downloader_app_sh"
    echo "[$(ts)] OK: DOWNLOADER_APP done."
  else
    echo "[$(ts)] SKIP: DOWNLOADER_APP."
  fi

  if prompt_yn "MODUŁ: UPGbuilder (zainstalować ~/UTILITY/UPGbuilder/upgbuilder.sh i symlink /usr/local/bin/upgbuilder)?" "Y"; then
    ensure_wget || { echo "[$(ts)] ERROR: wget missing; cannot run module."; exit 1; }

    if ! have_user; then
      echo "[$(ts)] ERROR: user '$TARGET_USER' missing."
      exit 1
    fi

    ITGO_HOME="${ITGO_HOME:-$(resolve_home)}"
    [[ -n "${ITGO_HOME:-}" ]] || { echo "[$(ts)] ERROR: cannot resolve home"; exit 1; }

    UTILITY_DIR="${UTILITY_DIR:-$ITGO_HOME/UTILITY}"
    TMP_DIR="${TMP_DIR:-$UTILITY_DIR/TMP}"

    [[ -d "$UTILITY_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$UTILITY_DIR"
    [[ -d "$TMP_DIR" ]] || install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_DIR"

    download_to_tmp "$UPGBUILDER_URL" "$upgbuilder_sh"
    install_upgbuilder_script "$upgbuilder_sh"

    if prompt_yn "Uruchomić teraz: upgbuilder --detect jako $TARGET_USER?" "Y"; then
      echo "[$(ts)] RUN(itgo): sudo -u $TARGET_USER /usr/local/bin/upgbuilder --detect"
      sudo -u "$TARGET_USER" /usr/local/bin/upgbuilder --detect
    else
      echo "[$(ts)] SKIP: upgbuilder --detect."
    fi

    echo "[$(ts)] OK: UPGbuilder done."
  else
    echo "[$(ts)] SKIP: UPGbuilder."
  fi

  section "SEKCJA 6/6 - PORZĄDKI KOŃCOWE"
  cleanup_downloaded_installers

  echo "[$(ts)] DONE."
  [[ -n "${FINAL_LOG:-}" ]] && echo "[$(ts)] Master log: $FINAL_LOG"
}

main "$@"
