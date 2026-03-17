#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# UPGbuilder
# ==========================================================
# Builds or updates local update_*.sh helpers based on:
# - detection rules from GitHub map
# - templates from GitHub
# - local server paths detected from scan roots in map
# ==========================================================

# -------------------- CONFIG --------------------

MODULE_DIR="${HOME}/UTILITY/UPGbuilder"
TMP_DIR="${MODULE_DIR}/tmp"
BACKUP_DIR="${MODULE_DIR}/backup"
OUTPUT_DIR="${HOME}/UPG"
VERSION_FILE="${MODULE_DIR}/.upgbuilder_version"

MODE="${1:-normal}"

# Kolejność ma znaczenie.
RULE_ORDER=(
  "platforms_zm"
  "platforms"
  "wildfly"
  "bk"
  "amdx"
  "mpi"
  "p1adapter"
)

# -------------------- GLOBALS --------------------

UPGBUILDER_VERSION="0.0.5"
RAW_REPO_BASE="https://raw.githubusercontent.com/daroitgo/itgo-scripts"

GITHUB_TAG=""
GITHUB_BASE_URL=""
MAP_URL=""

SCAN_ROOTS=()

declare -A MAP_DATA
declare -a FOUND_DIRS=()
declare -a IGNORED_DIRS=()
declare -a MATCHED_PATHS=()

MATCHED_RULE=""
MATCHED_OUTPUT=""
MATCHED_TEMPLATE=""
MATCHED_VERSION=""
MATCHED_LOG_PATH=""

APP_DIR=""
PLATFORM_DIR=""
DOCKER_DIR=""
ZM_DOCKER_DIR=""
WEBAPPS_DIR=""
APP_LOG_DIR=""
ADM_DIR=""
ADM_NEW_DIR=""
ADM_JRXML_STEP=""

# -------------------- HELPERS --------------------

log() {
  printf '%s\n' "$*"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "${TMP_DIR:?}"/*
}
trap cleanup EXIT

ensure_dirs() {
  mkdir -p "$MODULE_DIR" "$TMP_DIR" "$BACKUP_DIR" "$OUTPUT_DIR"
}

set_github_urls() {
  GITHUB_TAG="upgbuilder-${UPGBUILDER_VERSION}"
  GITHUB_BASE_URL="${RAW_REPO_BASE}/${GITHUB_TAG}/UPGBUILDER"
  MAP_URL="${GITHUB_BASE_URL}/upgbuilder.map"
}

load_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    local file_version
    file_version="$(tr -d '[:space:]' < "$VERSION_FILE")"

    if [[ "$file_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      UPGBUILDER_VERSION="$file_version"
    else
      log "[WARN] Nieprawidłowa zawartość $VERSION_FILE: $file_version"
      log "[WARN] Używam wersji wbudowanej: $UPGBUILDER_VERSION"
    fi
  fi

  set_github_urls
}

download_file() {
  local url="$1"
  local dst="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  else
    die "Brak curl i wget."
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

array_clear_by_name() {
  local arr_name="$1"
  eval "$arr_name=()"
}

array_append_by_name() {
  local arr_name="$1"
  local value="$2"
  local value_q

  printf -v value_q '%q' "$value"
  eval "$arr_name+=($value_q)"
}

array_length_by_name() {
  local arr_name="$1"
  local len

  eval 'len=${#'"$arr_name"'[@]}'
  printf '%s\n' "$len"
}

array_copy_by_name() {
  local src_name="$1"
  local dst_name="$2"
  local len i item

  array_clear_by_name "$dst_name"
  len="$(array_length_by_name "$src_name")"

  for ((i=0; i<len; i++)); do
    eval 'item=${'"$src_name"'[$i]}'
    array_append_by_name "$dst_name" "$item"
  done
}

read_map() {
  local map_file="$1"
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    key="$(trim "$key")"
    value="$(trim "$value")"

    MAP_DATA["$key"]="$value"
  done < "$map_file"

  [[ -n "${MAP_DATA[scan.roots]:-}" ]] || die "Brak scan.roots w mapie."
}

split_csv() {
  local input="$1"
  local out_name="$2"
  local old_ifs="$IFS"
  local -a tmp_arr=()
  local item

  IFS=',' read -r -a tmp_arr <<< "$input"
  IFS="$old_ifs"

  array_clear_by_name "$out_name"

  for item in "${tmp_arr[@]}"; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue
    array_append_by_name "$out_name" "$item"
  done
}

scan_dirs() {
  local roots_csv root dir base

  roots_csv="${MAP_DATA[scan.roots]}"
  split_csv "$roots_csv" SCAN_ROOTS

  FOUND_DIRS=()
  IGNORED_DIRS=()

  for root in "${SCAN_ROOTS[@]}"; do
    root="$(trim "$root")"
    [[ -d "$root" ]] || continue

    for dir in "$root"/*; do
      [[ -d "$dir" ]] || continue
      base="$(basename "$dir")"

      if [[ "$base" == *OLD* ]]; then
        IGNORED_DIRS+=("$dir")
        continue
      fi

      FOUND_DIRS+=("$dir")
    done
  done
}

match_name() {
  local mode="$1"
  local value="$2"
  local name="$3"
  local v lowered_name item
  local -a items=()

  lowered_name="$(lower "$name")"

  case "$mode" in
    prefix)
      [[ "$name" == "$value"* ]]
      ;;
    contains)
      split_csv "$value" items
      for item in "${items[@]}"; do
        item="$(trim "$item")"
        v="$(lower "$item")"
        [[ -z "$v" ]] && continue
        if [[ "$lowered_name" == *"$v"* ]]; then
          return 0
        fi
      done
      return 1
      ;;
    exact)
      [[ "$name" == "$value" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

find_matches_for_condition() {
  local mode="$1"
  local value="$2"
  local out_name="$3"
  local dir name

  array_clear_by_name "$out_name"

  for dir in "${FOUND_DIRS[@]}"; do
    name="$(basename "$dir")"
    if match_name "$mode" "$value" "$name"; then
      array_append_by_name "$out_name" "$dir"
    fi
  done
}

evaluate_rule() {
  local rule="$1"
  local mode1 value1 mode2 value2
  local -a hits1=() hits2=()

  mode1="${MAP_DATA[$rule.detect_mode]:-}"
  value1="${MAP_DATA[$rule.detect_value]:-}"

  [[ -n "$mode1" && -n "$value1" ]] || return 1

  find_matches_for_condition "$mode1" "$value1" hits1
  ((${#hits1[@]} > 0)) || return 1

  mode2="${MAP_DATA[$rule.detect_mode_2]:-}"
  value2="${MAP_DATA[$rule.detect_value_2]:-}"

  if [[ -n "$mode2" && -n "$value2" ]]; then
    find_matches_for_condition "$mode2" "$value2" hits2
    ((${#hits2[@]} > 0)) || return 1
  fi

  MATCHED_RULE="$rule"
  MATCHED_OUTPUT="${MAP_DATA[$rule.output]:-}"
  MATCHED_TEMPLATE="${MAP_DATA[$rule.template]:-}"
  MATCHED_VERSION="${MAP_DATA[$rule.version]:-}"
  MATCHED_LOG_PATH="${MAP_DATA[$rule.log_path]:-}"

  [[ -n "$MATCHED_OUTPUT" ]]   || die "Brak ${rule}.output w mapie."
  [[ -n "$MATCHED_TEMPLATE" ]] || die "Brak ${rule}.template w mapie."
  [[ -n "$MATCHED_VERSION" ]]  || die "Brak ${rule}.version w mapie."

  MATCHED_PATHS=("${hits1[@]}")
  if ((${#hits2[@]} > 0)); then
    MATCHED_PATHS+=("${hits2[@]}")
  fi

  assign_rule_paths "$rule" hits1 hits2
  build_special_steps "$rule" hits1
  render_log_path

  return 0
}

assign_rule_paths() {
  local rule="$1"
  local hits1_name="$2"
  local hits2_name="$3"
  local -a hits1_ref=() hits2_ref=()

  array_copy_by_name "$hits1_name" hits1_ref
  array_copy_by_name "$hits2_name" hits2_ref

  APP_DIR=""
  PLATFORM_DIR=""
  DOCKER_DIR=""
  ZM_DOCKER_DIR=""
  WEBAPPS_DIR=""
  APP_LOG_DIR=""
  ADM_DIR=""
  ADM_NEW_DIR=""
  ADM_JRXML_STEP=""

  case "$rule" in
    platforms)
      APP_DIR="${hits1_ref[0]}"
      ;;
    platforms_zm)
      PLATFORM_DIR="${hits1_ref[0]}"
      APP_DIR="$PLATFORM_DIR"
      ZM_DOCKER_DIR="${hits2_ref[0]}"
      ;;
    wildfly)
      APP_DIR="${hits1_ref[0]}"
      ;;
    bk)
      APP_DIR="${hits1_ref[0]}"
      WEBAPPS_DIR="${APP_DIR}/webapps"
      ;;
    amdx|mpi|p1adapter)
      APP_DIR="${hits1_ref[0]}"
      DOCKER_DIR="$APP_DIR"
      ;;
  esac
}

build_special_steps() {
  local rule="$1"
  local hits1_name="$2"
  local dir base
  local -a hits1_ref=()

  array_copy_by_name "$hits1_name" hits1_ref

  ADM_DIR=""
  ADM_NEW_DIR=""
  ADM_JRXML_STEP=""

  [[ "$rule" == "platforms" ]] || return 0

  for dir in "${hits1_ref[@]}"; do
    base="$(basename "$dir")"
    if [[ "$base" == "IntegrationPlatform_ADM" ]]; then
      ADM_DIR="$dir"
      ADM_NEW_DIR="${dir}_NEW"
      ADM_JRXML_STEP="$(cat <<'EOF'
step_copy_adm_jrxml() {
  echo "[0a] Kopiowanie plików JRXML z ADM -> ADM_NEW (przed zmianami)..."

  local JRXML_SRC_DIR JRXML_DST_DIR
  JRXML_SRC_DIR="${ADM_DIR}/apache-tomcat/webapps/DocumentationArchive/WEB-INF/classes"
  JRXML_DST_DIR="${ADM_NEW_DIR}/apache-tomcat/webapps/DocumentationArchive/WEB-INF/classes"

  local JRXML_FILES=(
    "AD_spis_zdawczo_odbiorczy_zm4.jrxml"
    "AD_spis_zdawczo_odbiorczy_zm6.jrxml"
  )

  if [[ -d "$JRXML_SRC_DIR" ]]; then
    mkdir -p "$JRXML_DST_DIR"
    local f
    for f in "${JRXML_FILES[@]}"; do
      if [[ -f "$JRXML_SRC_DIR/$f" ]]; then
        echo "    cp $JRXML_SRC_DIR/$f -> $JRXML_DST_DIR/"
        cp -f "$JRXML_SRC_DIR/$f" "$JRXML_DST_DIR/"
      else
        echo "    [WARN] Brak pliku źródłowego: $JRXML_SRC_DIR/$f (pomijam)"
      fi
    done
  else
    echo "    [WARN] Brak katalogu źródłowego: $JRXML_SRC_DIR (pomijam kopię JRXML)"
  fi
}

run_step "Kopiowanie plików JRXML z ADM -> ADM_NEW (KROK 0A)" step_copy_adm_jrxml
EOF
)"
      return 0
    fi
  done
}

render_log_path() {
  APP_LOG_DIR="$MATCHED_LOG_PATH"

  APP_LOG_DIR="${APP_LOG_DIR//\{\{APP_DIR\}\}/$APP_DIR}"
  APP_LOG_DIR="${APP_LOG_DIR//\{\{PLATFORM_DIR\}\}/$PLATFORM_DIR}"
  APP_LOG_DIR="${APP_LOG_DIR//\{\{DOCKER_DIR\}\}/$DOCKER_DIR}"
  APP_LOG_DIR="${APP_LOG_DIR//\{\{ZM_DOCKER_DIR\}\}/$ZM_DOCKER_DIR}"
  APP_LOG_DIR="${APP_LOG_DIR//\{\{WEBAPPS_DIR\}\}/$WEBAPPS_DIR}"
}

find_rule() {
  local rule
  MATCHED_RULE=""
  for rule in "${RULE_ORDER[@]}"; do
    if evaluate_rule "$rule"; then
      return 0
    fi
  done
  return 1
}

version_cmp() {
  # echo: lt / eq / gt
  local a="$1" b="$2"
  local IFS='.'
  local -a va vb
  local i max ai bi

  read -r -a va <<< "$a"
  read -r -a vb <<< "$b"

  max="${#va[@]}"
  (( ${#vb[@]} > max )) && max="${#vb[@]}"

  for ((i=0; i<max; i++)); do
    ai="${va[i]:-0}"
    bi="${vb[i]:-0}"
    ((10#$ai < 10#$bi)) && { echo "lt"; return; }
    ((10#$ai > 10#$bi)) && { echo "gt"; return; }
  done

  echo "eq"
}

get_local_template_version() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -E '^# TEMPLATE_VERSION=' "$file" | head -n1 | cut -d'=' -f2 | tr -d '[:space:]'
}

ask_yes_no_default_yes() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [Y/n]: " ans || true
  ans="$(trim "$ans")"
  [[ -z "$ans" ]] && return 0
  [[ "$ans" =~ ^[YyTt]$ ]]
}

backup_existing_output() {
  local src="$1"
  local ts dst

  [[ -f "$src" ]] || return 0

  ts="$(date +%Y%m%d_%H%M%S)"
  dst="${BACKUP_DIR}/$(basename "$src").${ts}.bak"
  cp -f "$src" "$dst"
  log "[INFO] Backup starego updatera: $dst"
}

escape_sed_repl() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

render_template() {
  local template_file="$1"
  local output_file="$2"
  local tmp_out="$TMP_DIR/rendered.tmp"
  local rendered_text

  cp "$template_file" "$tmp_out"

  sed -i \
    -e "s/{{UPGBUILDER_VERSION}}/$(escape_sed_repl "$UPGBUILDER_VERSION")/g" \
    -e "s/{{GENERATED_AT}}/$(escape_sed_repl "$(date '+%F %T')")/g" \
    -e "s/{{HOSTNAME}}/$(escape_sed_repl "$(hostname -s 2>/dev/null || hostname)")/g" \
    -e "s/{{TARGET_USER}}/$(escape_sed_repl "${USER:-itgo}")/g" \
    -e "s/{{APP_DIR}}/$(escape_sed_repl "$APP_DIR")/g" \
    -e "s/{{PLATFORM_DIR}}/$(escape_sed_repl "$PLATFORM_DIR")/g" \
    -e "s/{{DOCKER_DIR}}/$(escape_sed_repl "$DOCKER_DIR")/g" \
    -e "s/{{ZM_DOCKER_DIR}}/$(escape_sed_repl "$ZM_DOCKER_DIR")/g" \
    -e "s/{{WEBAPPS_DIR}}/$(escape_sed_repl "$WEBAPPS_DIR")/g" \
    -e "s/{{APP_LOG_DIR}}/$(escape_sed_repl "$APP_LOG_DIR")/g" \
    -e "s/{{ADM_DIR}}/$(escape_sed_repl "$ADM_DIR")/g" \
    -e "s/{{ADM_NEW_DIR}}/$(escape_sed_repl "$ADM_NEW_DIR")/g" \
    "$tmp_out"

  if grep -q '{{ADM_JRXML_STEP}}' "$tmp_out"; then
    rendered_text="$(cat "$tmp_out")"
    rendered_text="${rendered_text//\{\{ADM_JRXML_STEP\}\}/$ADM_JRXML_STEP}"
    printf '%s' "$rendered_text" > "$tmp_out"
  fi

  mv "$tmp_out" "$output_file"
  chmod +x "$output_file"
}

print_detect_summary() {
  local dir

  log "[DETECT] Scan roots: ${MAP_DATA[scan.roots]}"
  log

  log "[DETECT] Found:"
  if ((${#FOUND_DIRS[@]} == 0)); then
    log "- brak"
  else
    for dir in "${FOUND_DIRS[@]}"; do
      log "- $dir"
    done
  fi
  log

  log "[DETECT] Ignored (OLD):"
  if ((${#IGNORED_DIRS[@]} == 0)); then
    log "- brak"
  else
    for dir in "${IGNORED_DIRS[@]}"; do
      log "- $dir"
    done
  fi
  log

  if [[ -z "$MATCHED_RULE" ]]; then
    log "[DETECT] No matching rule."
    return 0
  fi

  log "[DETECT] Matched rule:"
  log "- ${MATCHED_RULE}"
  log
  log "[DETECT] Output:"
  log "- ${MATCHED_OUTPUT}"
  log
  log "[DETECT] Template:"
  log "- ${MATCHED_TEMPLATE}"
  log
  log "[DETECT] Version:"
  log "- ${MATCHED_VERSION}"
  log
  log "[DETECT] Matched paths:"
  for dir in "${MATCHED_PATHS[@]}"; do
    log "- $dir"
  done
}

print_generate_summary() {
  local output_file="$1"
  local dir

  log
  log "UPGbuilder result"
  log "-----------------"
  log "Detected:"
  for dir in "${MATCHED_PATHS[@]}"; do
    log "- $dir"
  done
  log
  log "Rule:"
  log "- ${MATCHED_RULE}"
  log
  log "Template:"
  log "- ${MATCHED_TEMPLATE}"
  log "- version: ${MATCHED_VERSION}"
  log
  log "Generated:"
  log "- ${output_file}"
}

main() {
  local map_local template_local output_file local_version cmp_result

  ensure_dirs
  load_version
  cleanup

  map_local="${TMP_DIR}/upgbuilder.map"
  log "[INFO] Pobieram mapę: ${MAP_URL}"
  download_file "$MAP_URL" "$map_local"
  read_map "$map_local"

  scan_dirs

  if ! find_rule; then
    if [[ "$MODE" == "--detect" ]]; then
      print_detect_summary
    else
      log "[INFO] Nie znaleziono pasującej reguły / aplikacji. Nic nie robię."
    fi
    exit 0
  fi

  if [[ "$MODE" == "--detect" ]]; then
    print_detect_summary
    exit 0
  fi

  output_file="${OUTPUT_DIR}/${MATCHED_OUTPUT}"

  if [[ -f "$output_file" ]]; then
    local_version="$(get_local_template_version "$output_file" || true)"
    if [[ -n "$local_version" ]]; then
      cmp_result="$(version_cmp "$local_version" "$MATCHED_VERSION")"
      case "$cmp_result" in
        eq)
          log "[INFO] $(basename "$output_file") jest aktualny (${local_version}) — nic do zrobienia."
          exit 0
          ;;
        gt)
          log "[WARN] Lokalny updater ma wyższą wersję (${local_version}) niż mapa (${MATCHED_VERSION}). Nic nie robię."
          exit 0
          ;;
        lt)
          log "[INFO] Znaleziono nowszą wersję template:"
          log "       serwer : ${local_version}"
          log "       github : ${MATCHED_VERSION}"
          if ! ask_yes_no_default_yes "Czy zaktualizować updater?"; then
            log "[INFO] Aktualizacja anulowana."
            exit 0
          fi
          backup_existing_output "$output_file"
          ;;
      esac
    else
      log "[WARN] Nie udało się odczytać lokalnej TEMPLATE_VERSION z ${output_file}."
      if ask_yes_no_default_yes "Czy nadpisać istniejący updater nową wersją?"; then
        backup_existing_output "$output_file"
      else
        log "[INFO] Aktualizacja anulowana."
        exit 0
      fi
    fi
  else
    log "[INFO] Nie znaleziono ${output_file} — generuję nowy updater."
  fi

  template_local="${TMP_DIR}/$(basename "$MATCHED_TEMPLATE")"
  log "[INFO] Pobieram template: ${GITHUB_BASE_URL}/${MATCHED_TEMPLATE}"
  download_file "${GITHUB_BASE_URL}/${MATCHED_TEMPLATE}" "$template_local"

  render_template "$template_local" "$output_file"
  print_generate_summary "$output_file"
}

case "$MODE" in
  ""|normal)
    main
    ;;
  --detect)
    main
    ;;
  *)
    die "Nieznany parametr: $MODE. Dozwolone: --detect"
    ;;
esac