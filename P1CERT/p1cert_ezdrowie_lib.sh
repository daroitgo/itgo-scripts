#!/usr/bin/env bash
# shellcheck shell=bash
# Shared, side-effect free helpers for the P1CERT ezdrowie namespace.
#
# This file is sourced by two callers:
#   - p1cert_ezdrowie.sh (unprivileged, installed under UTILITY/P1CERT/bin),
#   - the root helper, from its root-owned copy under
#     /usr/local/libexec/itgo-p1cert/.
# It must therefore only define functions and constants: no I/O on load, no
# eval, no indirect execution.

# Contract version between p1cert_ezdrowie.sh, this library and the root
# helper (not the P1CERT release version).  The helper and the caller refuse
# a library with a different value.
EZ_LIB_API=1

EZ_ALLOWED_ROOTS='/srv /usr/local /opt'
EZ_MAX_CERT_BYTES=65536
EZ_IDENTITY_DOMAIN='ezdrowie.gov.pl'

# Lowercase without depending on bash 4 case modification (OL7 ships bash 4.2,
# but keep the helpers usable from any POSIX tr).
ez_lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# Supported certificate file extensions (case-insensitive).
ez_ext_supported() {
  case "$(ez_lower "$1")" in
    *.pem|*.crt|*.cer) return 0 ;;
    *) return 1 ;;
  esac
}

# A basename belongs to ezdrowie.gov.pl when, without its extension, lowercased
# and with ".", "_" and "-" removed, it contains "ezdrowiegovpl".
ez_name_matches() {
  local name="$1" stem

  ez_ext_supported "$name" || return 1
  stem="${name%.*}"
  stem="$(ez_lower "$stem" | tr -d '._-')"
  case "$stem" in
    *ezdrowiegovpl*) return 0 ;;
    *) return 1 ;;
  esac
}

# Logical paths handled by the namespace are deliberately restricted to a
# conservative character set.  This keeps plan records, sudo arguments and log
# lines unambiguous and excludes whitespace, quotes, "|" and control bytes.
ez_path_chars_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9._/@+-]*) return 1 ;;
  esac
  return 0
}

# Absolute, normalized path strictly below one of the allowed roots.
ez_path_under_roots() {
  local path="$1" root

  ez_path_chars_ok "$path" || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    */|*//*) return 1 ;;
  esac
  case "/$path/" in
    */../*|*/./*) return 1 ;;
  esac
  for root in $EZ_ALLOWED_ROOTS; do
    case "$path" in
      "$root"/?*) return 0 ;;
    esac
  done
  return 1
}

# A certificate target: allowed path whose basename matches the ezdrowie rule.
ez_target_path_ok() {
  ez_path_under_roots "$1" || return 1
  ez_name_matches "${1##*/}"
}

# Verifies that no component of a logical path is a symlink.  $1 is the
# filesystem prefix (empty in production, a fixture root in tests).
ez_path_no_symlinks() {
  local prefix="$1" path="$2" current="" part rest

  rest="${path#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    current="$current/$part"
    [ ! -L "$prefix$current" ] || return 1
  done
  return 0
}

# True when a directory is owned by the given uid (0 in production) and is not
# writable by group or others, i.e. no unprivileged user can swap entries in it
# while the root helper works there.
ez_dir_safe() {
  local dir="$1" uid="$2" meta owner mode

  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  meta="$(stat -c '%u %a' -- "$dir" 2>/dev/null)" || return 1
  owner="${meta%% *}"
  mode="${meta#* }"
  case "$owner:$mode" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  [ "$owner" = "$uid" ] && [ $((8#$mode & 8#022)) -eq 0 ]
}

ez_unit_name_ok() {
  case "$1" in
    ''|-*|*@.service|*[!A-Za-z0-9@._:-]*) return 1 ;;
    *.service) return 0 ;;
    *) return 1 ;;
  esac
}

# Units that must never be restarted through P1CERT, regardless of detection.
ez_unit_denied() {
  case "$1" in
    sshd*|ssh.service|ssh@*|systemd-*|dbus*|getty*|serial-getty*|autovt*|network*|NetworkManager*|\
    firewalld*|iptables*|ip6tables*|nftables*|docker*|containerd*|podman*|crond*|cron.service|atd*|\
    auditd*|polkit*|rsyslog*|syslog*|chronyd*|ntpd*|sssd*|sudo*|user@*|user-runtime-dir@*|\
    emergency*|rescue*|kdump*|tuned*|itgo-p1cert-*|libvirtd*|lvm2*|multipathd*|nfs*|rpcbind*|\
    postfix*|sendmail*|irqbalance*|abrt*|gdm*|display-manager*)
      return 0
      ;;
  esac
  return 1
}

ez_compose_service_ok() {
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# SHA-256 fingerprint in OpenSSL notation: 32 colon-separated uppercase bytes.
ez_fp_ok() {
  printf '%s\n' "$1" | grep -E -q '^([0-9A-F]{2}:){31}[0-9A-F]{2}$'
}

ez_epoch_ok() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 12 ]
}

ez_file_size() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

# SHA-256 of a file's bytes (hex), using only openssl.
ez_file_digest() {
  openssl dgst -sha256 < "$1" 2>/dev/null | awk '{ print $NF }'
}

# A SHA-256 digest as printed by ez_file_digest: exactly 64 lowercase hex.
ez_digest_ok() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

ez_to_epoch() {
  LC_ALL=C date -u -d "$1" '+%s' 2>/dev/null
}

ez_is_ezdrowie_name() {
  case "$1" in
    "$EZ_IDENTITY_DOMAIN"|*."$EZ_IDENTITY_DOMAIN") return 0 ;;
    *) return 1 ;;
  esac
}

# Non-production environments use dedicated labels below ezdrowie.gov.pl
# (for example isus.ezdrowie.gov.pl).  Such names are never selected as the
# production source.
ez_is_nonprod_name() {
  local labels label

  ez_is_ezdrowie_name "$1" || return 1
  labels="${1%"$EZ_IDENTITY_DOMAIN"}"
  labels="${labels%.}"
  [ -n "$labels" ] || return 1
  # Names may contain "*" (wildcards): never let the shell glob them.
  while IFS= read -r label; do
    case "$label" in
      isus*|test*|tst*|int|int[0-9]*|integr*|uat*|dev*|demo*|stage*|staging*|preprod*|pre|pre[0-9-]*|sandbox*)
        return 0
        ;;
    esac
  done <<EOF
$(printf '%s\n' "$labels" | tr '.' '\n')
EOF
  return 1
}

# Space-separated list membership (no globbing, no word splitting).
ez_names_contain() {
  case " $1 " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# One DNS label: 1..63 characters a-z, 0-9 and "-", not starting or ending
# with "-".
ez_dns_label_ok() {
  case "$1" in
    ''|-*|*-|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 63 ]
}

# Syntax of a lowercase DNS name as accepted in certificate identities: either
# a plain host name, or a wildcard whose ONLY "*" is the complete left-most
# label ("*.ezdrowie.gov.pl").  Every other label must be a valid DNS label.
# Partial-label wildcards ("foo*.x", "*foo.x"), wildcards in other labels
# ("a.*.x"), "**" and wildcards directly above a single label ("*.pl") are
# rejected.
ez_dns_name_syntax_ok() {
  local name="$1" rest label

  case "$name" in
    ''|*[!a-z0-9.*-]*|.*|*.|*..*) return 1 ;;
  esac
  [ "${#name}" -le 253 ] || return 1
  case "$name" in
    \*.*)
      rest="${name#\*.}"
      # The wildcard must leave at least two labels (never "*.tld").
      case "$rest" in
        *.*) ;;
        *) return 1 ;;
      esac
      ;;
    *) rest="$name" ;;
  esac
  while :; do
    label="${rest%%.*}"
    ez_dns_label_ok "$label" || return 1
    [ "$label" != "$rest" ] || break
    rest="${rest#*.}"
  done
  return 0
}

# ez_dns_name_covers <certificate-name> <required-name>
# True when a name presented by a certificate covers the required identity:
#   - identical names always match (this is also the only way a wildcard
#     identity, e.g. a wildcard local certificate, can be covered),
#   - "*.example.tld" covers exactly one additional left-most label:
#     "api.example.tld", but neither "example.tld" nor "a.b.example.tld".
ez_dns_name_covers() {
  local cert="$1" required="$2" base label rest

  ez_dns_name_syntax_ok "$cert" && ez_dns_name_syntax_ok "$required" || return 1
  [ "$cert" != "$required" ] || return 0
  case "$cert" in
    \*.*) ;;
    *) return 1 ;;
  esac
  case "$required" in
    *\**) return 1 ;;
  esac
  base="${cert#\*.}"
  label="${required%%.*}"
  rest="${required#*.}"
  [ "$label" != "$required" ] && [ -n "$label" ] && [ "$rest" = "$base" ]
}

# True when any name of a space-separated list covers the required identity.
ez_names_cover() {
  local names="$1" required="$2" name

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    ez_dns_name_covers "$name" "$required" && return 0
  done <<EOF
$(printf '%s\n' "$names" | tr ' ' '\n')
EOF
  return 1
}

# Reads "openssl x509 -text" output on stdin and prints every DNS entry of the
# Subject Alternative Name extension, lowercased, one per line.  The values
# are collected from all lines indented deeper than the extension header, so
# a list wrapped over several lines (or printed differently by OpenSSL 1.0.x
# and 3.x) is read completely.  Exit status 2 when the extension occurs more
# than once (malformed certificate).
ez_x509_text_san_dns() {
  awk '
    function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
    insan {
      if ($0 ~ /^[ \t]*$/ || indent($0) <= hind) insan = 0
      else { buf = buf "," $0; next }
    }
    /^[ \t]*X509v3 Subject Alternative Name[ \t]*:/ { count++; insan = 1; hind = indent($0); next }
    END {
      if (count > 1) exit 2
      n = split(buf, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (p ~ /^DNS:/) {
          p = substr(p, 5)
          gsub(/^[ \t]+|[ \t]+$/, "", p)
          print tolower(p)
        }
      }
    }'
}

# Inspects exactly one X.509 certificate.  Sets EZC_* variables:
#   EZC_SAN_DNS      syntactically valid DNS SAN entries,
#   EZC_HAS_DNS_SAN  yes when the certificate has at least one DNS SAN entry
#                    (valid or not),
#   EZC_NAMES        the authoritative identity names: the DNS SANs when any
#                    exist, otherwise the CN (legacy fallback only).
# Return codes: 0 valid certificate, 1 not a certificate/unreadable,
# 2 more than one certificate or trailing data, 3 private key material
# present, 4 too large.
ez_cert_inspect() {
  local file="$1" inform data text san name san_names="" size begin_count orig_digest rt_digest rc

  EZC_FORMAT=""; EZC_COUNT=0; EZC_FP=""; EZC_SUBJECT=""; EZC_ISSUER=""
  EZC_NOT_BEFORE=""; EZC_NOT_AFTER=""; EZC_NB_EPOCH=""; EZC_NA_EPOCH=""
  EZC_CN=""; EZC_SAN_DNS=""; EZC_HAS_DNS_SAN=no; EZC_NAMES=""; EZC_IS_CA=no; EZC_SELF_SIGNED=no

  [ -f "$file" ] && [ -r "$file" ] || return 1
  size="$(ez_file_size "$file")"
  [ -n "$size" ] && [ "$size" -gt 0 ] || return 1
  [ "$size" -le "$EZ_MAX_CERT_BYTES" ] || return 4

  if LC_ALL=C grep -a -q -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "$file"; then
    return 3
  fi

  begin_count="$(LC_ALL=C grep -a -c -- '-----BEGIN ' "$file" || true)"
  if LC_ALL=C grep -a -q -- '-----BEGIN CERTIFICATE-----' "$file"; then
    inform=PEM
    EZC_FORMAT=PEM
    EZC_COUNT="$(LC_ALL=C grep -a -c -- '-----BEGIN CERTIFICATE-----' "$file")"
    [ "$EZC_COUNT" = 1 ] || return 2
    # No other PEM block (parameters, CRL, second certificate in any form).
    [ "$begin_count" = 1 ] || return 2
  else
    [ "$begin_count" = 0 ] || return 1
    inform=DER
    EZC_FORMAT=DER
  fi

  data="$(LC_ALL=C openssl x509 -inform "$inform" -in "$file" -noout -fingerprint -sha256 -subject -issuer -startdate -enddate 2>/dev/null)" || return 1

  if [ "$inform" = DER ]; then
    # OpenSSL reads one DER object and silently ignores anything after it.
    # The file must be exactly one certificate: its canonical re-encoding has
    # to be byte-identical to the file (no trailing or concatenated data).
    orig_digest="$(ez_file_digest "$file")"
    rt_digest="$(LC_ALL=C openssl x509 -inform DER -in "$file" -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{ print $NF }')"
    [ -n "$orig_digest" ] && [ "$orig_digest" = "$rt_digest" ] || return 2
    EZC_COUNT=1
  fi

  EZC_FP="$(printf '%s\n' "$data" | awk -F= '{ field=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", field); if (tolower(field) == "sha256 fingerprint") { print toupper($2); exit } }')"
  EZC_SUBJECT="$(printf '%s\n' "$data" | sed -n 's/^subject= *//p' | head -n 1)"
  EZC_ISSUER="$(printf '%s\n' "$data" | sed -n 's/^issuer= *//p' | head -n 1)"
  EZC_NOT_BEFORE="$(printf '%s\n' "$data" | sed -n 's/^notBefore=//p' | head -n 1)"
  EZC_NOT_AFTER="$(printf '%s\n' "$data" | sed -n 's/^notAfter=//p' | head -n 1)"
  ez_fp_ok "$EZC_FP" || return 1
  [ -n "$EZC_SUBJECT" ] && [ -n "$EZC_ISSUER" ] && [ -n "$EZC_NOT_BEFORE" ] && [ -n "$EZC_NOT_AFTER" ] || return 1

  EZC_NB_EPOCH="$(ez_to_epoch "$EZC_NOT_BEFORE")"
  EZC_NA_EPOCH="$(ez_to_epoch "$EZC_NOT_AFTER")"
  ez_epoch_ok "$EZC_NB_EPOCH" && ez_epoch_ok "$EZC_NA_EPOCH" || return 1

  # multiline name output is stable across OpenSSL 1.0.x (OL7) and 3.x.
  EZC_CN="$(LC_ALL=C openssl x509 -inform "$inform" -in "$file" -noout -subject -nameopt multiline 2>/dev/null |
    awk '/^[[:space:]]+commonName[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }')"
  EZC_CN="$(ez_lower "$EZC_CN")"

  text="$(LC_ALL=C openssl x509 -inform "$inform" -in "$file" -noout -text 2>/dev/null)" || return 1
  san="$(printf '%s\n' "$text" | ez_x509_text_san_dns)"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  if printf '%s\n' "$text" | grep -q 'CA:TRUE'; then
    EZC_IS_CA=yes
  fi
  [ "$EZC_SUBJECT" != "$EZC_ISSUER" ] || EZC_SELF_SIGNED=yes

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Any DNS SAN, even one we cannot use, disables the CN fallback.
    EZC_HAS_DNS_SAN=yes
    ez_dns_name_syntax_ok "$name" || continue
    ez_names_contain "$san_names" "$name" || san_names="${san_names:+$san_names }$name"
  done <<EOF
$san
EOF
  EZC_SAN_DNS="$san_names"
  if [ "$EZC_HAS_DNS_SAN" = yes ]; then
    EZC_NAMES="$san_names"
  elif ez_dns_name_syntax_ok "$EZC_CN"; then
    EZC_NAMES="$EZC_CN"
  fi
  return 0
}

# Copies the EZC_* result of the last inspection to one of the fixed variable
# sets OLD_*, NEW_* or CUR_* (explicit assignments, no eval).
ez_cert_save() {
  case "$1" in
    OLD)
      OLD_FORMAT="$EZC_FORMAT"; OLD_COUNT="$EZC_COUNT"; OLD_FP="$EZC_FP"
      OLD_SUBJECT="$EZC_SUBJECT"; OLD_ISSUER="$EZC_ISSUER"
      OLD_NOT_BEFORE="$EZC_NOT_BEFORE"; OLD_NOT_AFTER="$EZC_NOT_AFTER"
      OLD_NB_EPOCH="$EZC_NB_EPOCH"; OLD_NA_EPOCH="$EZC_NA_EPOCH"
      OLD_CN="$EZC_CN"; OLD_SAN_DNS="$EZC_SAN_DNS"; OLD_HAS_DNS_SAN="$EZC_HAS_DNS_SAN"; OLD_NAMES="$EZC_NAMES"
      OLD_IS_CA="$EZC_IS_CA"; OLD_SELF_SIGNED="$EZC_SELF_SIGNED"
      ;;
    NEW)
      NEW_FORMAT="$EZC_FORMAT"; NEW_COUNT="$EZC_COUNT"; NEW_FP="$EZC_FP"
      NEW_SUBJECT="$EZC_SUBJECT"; NEW_ISSUER="$EZC_ISSUER"
      NEW_NOT_BEFORE="$EZC_NOT_BEFORE"; NEW_NOT_AFTER="$EZC_NOT_AFTER"
      NEW_NB_EPOCH="$EZC_NB_EPOCH"; NEW_NA_EPOCH="$EZC_NA_EPOCH"
      NEW_CN="$EZC_CN"; NEW_SAN_DNS="$EZC_SAN_DNS"; NEW_HAS_DNS_SAN="$EZC_HAS_DNS_SAN"; NEW_NAMES="$EZC_NAMES"
      NEW_IS_CA="$EZC_IS_CA"; NEW_SELF_SIGNED="$EZC_SELF_SIGNED"
      ;;
    CUR)
      CUR_FORMAT="$EZC_FORMAT"; CUR_COUNT="$EZC_COUNT"; CUR_FP="$EZC_FP"
      CUR_SUBJECT="$EZC_SUBJECT"; CUR_ISSUER="$EZC_ISSUER"
      CUR_NOT_BEFORE="$EZC_NOT_BEFORE"; CUR_NOT_AFTER="$EZC_NOT_AFTER"
      CUR_NB_EPOCH="$EZC_NB_EPOCH"; CUR_NA_EPOCH="$EZC_NA_EPOCH"
      CUR_CN="$EZC_CN"; CUR_SAN_DNS="$EZC_SAN_DNS"; CUR_HAS_DNS_SAN="$EZC_HAS_DNS_SAN"; CUR_NAMES="$EZC_NAMES"
      CUR_IS_CA="$EZC_IS_CA"; CUR_SELF_SIGNED="$EZC_SELF_SIGNED"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# ez_schedule_window_ok <now> <scheduled-epoch> <grace-seconds>
# A scheduled run may act only from the planned second up to grace seconds
# later: never before the planned time.
ez_schedule_window_ok() {
  ez_epoch_ok "$1" && ez_epoch_ok "$2" && ez_epoch_ok "$3" || return 1
  [ "$1" -ge "$2" ] && [ "$1" -le $(($2 + $3)) ]
}

ez_validity_status() {
  local nb="$1" na="$2" now="$3"

  if [ "$nb" -gt "$now" ]; then
    printf 'NOT_YET_VALID'
  elif [ "$na" -le "$now" ]; then
    printf 'EXPIRED'
  elif [ "$na" -le $((now + 30 * 86400)) ]; then
    printf 'EXPIRES_SOON'
  else
    printf 'VALID'
  fi
}

# Primary ezdrowie identity of a certificate, chosen from its authoritative
# names (EZC_NAMES: DNS SANs, or the CN only when there is no DNS SAN): the CN
# when it is one of those names, otherwise the first ezdrowie name.  A CN that
# is not covered by the SAN list is never used.  Empty if none.
ez_primary_identity() {
  local cn="$1" names="$2" name

  if [ -n "$cn" ] && ez_is_ezdrowie_name "$cn" && ez_dns_name_syntax_ok "$cn" && ez_names_contain "$names" "$cn"; then
    printf '%s' "$cn"
    return 0
  fi
  while IFS= read -r name; do
    if [ -n "$name" ] && ez_is_ezdrowie_name "$name" && ez_dns_name_syntax_ok "$name"; then
      printf '%s' "$name"
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$names" | tr ' ' '\n')
EOF
  return 1
}

# Decides whether a source certificate may replace a local one, based only on
# X.509 data.  Arguments (names are the authoritative EZC_NAMES lists):
#   local_cn local_names remote_names remote_is_ca remote_self_signed
# Prints a reason and returns non-zero if the identity is not acceptable.
ez_identity_compatible() {
  local local_cn="$1" local_names="$2" remote_names="$3" remote_is_ca="$4" remote_self_signed="$5" primary

  primary="$(ez_primary_identity "$local_cn" "$local_names")" || {
    printf 'lokalny certyfikat nie ma tożsamości ezdrowie.gov.pl'
    return 1
  }
  if ez_is_nonprod_name "$primary"; then
    printf 'lokalny certyfikat jest nieprodukcyjny (%s)' "$primary"
    return 1
  fi
  if [ "$remote_is_ca" = yes ]; then
    printf 'certyfikat źródłowy jest certyfikatem CA'
    return 1
  fi
  if [ "$remote_self_signed" = yes ]; then
    printf 'certyfikat źródłowy jest samopodpisany'
    return 1
  fi
  if ! ez_names_cover "$remote_names" "$primary"; then
    printf 'certyfikat źródłowy nie obejmuje tożsamości %s' "$primary"
    return 1
  fi
  return 0
}

# Comparison rule for one local certificate.  Arguments:
#   remote_state (ABSENT|INVALID|VALID) local_fp local_na remote_fp remote_na
# Prints UPDATE, NO_CHANGE, SKIP or SKIP_WARNING.
ez_decide() {
  local remote_state="$1" local_fp="$2" local_na="$3" remote_fp="$4" remote_na="$5"

  case "$remote_state" in
    ABSENT) printf 'SKIP'; return 0 ;;
    VALID) ;;
    *) printf 'SKIP_WARNING'; return 0 ;;
  esac
  if [ "$remote_fp" = "$local_fp" ]; then
    printf 'NO_CHANGE'
  elif [ "$remote_na" -le "$local_na" ]; then
    printf 'NO_CHANGE'
  else
    printf 'UPDATE'
  fi
}

# ---------------------------------------------------------------------------
# Certificate -> service binding rules (used by the plan for detection and,
# independently, by the root helper before any restart).
# ---------------------------------------------------------------------------

# Reads text on stdin; true when it contains the path $1 as a whole token
# (not as a prefix of a longer path or name).  No regular expressions.
ez_text_has_path() {
  [ -n "$1" ] || return 1
  awk -v needle="$1" '
    function isp(c) { return c ~ /[A-Za-z0-9._\/@+-]/ }
    {
      line = $0; off = 0
      while ((pos = index(substr(line, off + 1), needle)) > 0) {
        start = off + pos
        before = (start > 1) ? substr(line, start - 1, 1) : ""
        after = substr(line, start + length(needle), 1)
        if ((before == "" || !isp(before)) && (after == "" || !isp(after))) { found = 1; exit }
        off = start
      }
    }
    END { exit found ? 0 : 1 }'
}

# IntegrationPlatform installation directory of a path: the prefix up to and
# including the first component whose name contains "integrationplatform"
# (case-insensitive), e.g.
#   /srv/IntegrationPlatform_PI/conf/x.pem -> /srv/IntegrationPlatform_PI
# The directory must lie strictly below an allowed root.
ez_ip_root() {
  local path="$1" rest part current=""

  ez_path_under_roots "$path" || return 1
  rest="${path#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    current="$current/$part"
    case "$(ez_lower "$part")" in
      *integrationplatform*)
        ez_path_under_roots "$current" || return 1
        printf '%s' "$current"
        return 0
        ;;
    esac
  done
  return 1
}

# True when $1 equals directory $2 or lies below it (string-wise, normalized).
ez_path_within() {
  ez_path_under_roots "$1" || return 1
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

# Configuration files of a unit from "systemctl show" output (properties
# FragmentPath, DropInPaths, EnvironmentFiles).  Prints "F <path>" for unit
# and drop-in files and "E <path>" for environment files.
ez_systemd_config_files() {
  printf '%s\n' "$1" | awk '
    /^FragmentPath=./ { print "F " substr($0, 14) }
    /^DropInPaths=./ { n = split(substr($0, 13), p, /[ \t]+/); for (i = 1; i <= n; i++) if (p[i] != "") print "F " p[i] }
    /^EnvironmentFiles=./ { v = substr($0, 18); sub(/[ \t].*$/, "", v); if (v != "") print "E " v }'
}

# ez_systemd_bound <cert-path> <systemctl-show-output> <config-text>
# Proves a relation between a certificate file and a systemd unit:
#   A. the exact certificate path appears in the unit properties (ExecStart,
#      Environment, ...) or in the unit/drop-in/environment file contents
#      (comment lines ignored), or
#   B. the certificate lies in an IntegrationPlatform installation directory
#      and the unit runs from that SAME directory: its WorkingDirectory, its
#      ExecStart executable, or the script started by /bin/sh|bash, lies in
#      it.  A common parent such as /srv is never enough.
# Prints the reason and returns 0, or returns 1.
ez_systemd_bound() {
  local cert="$1" props="$2" config="$3" root kind value

  ez_target_path_ok "$cert" || return 1
  if printf '%s\n' "$props" | ez_text_has_path "$cert"; then
    printf 'konfiguracja unitu wskazuje dokładną ścieżkę certyfikatu'
    return 0
  fi
  if printf '%s\n' "$config" | grep -v -E '^[[:space:]]*[#;]' | ez_text_has_path "$cert"; then
    printf 'plik unitu/drop-in/EnvironmentFile wskazuje dokładną ścieżkę certyfikatu'
    return 0
  fi
  root="$(ez_ip_root "$cert")" || return 1
  [ "$root" != "$cert" ] || return 1
  while IFS=' ' read -r kind value; do
    [ -n "$value" ] || continue
    if ez_path_within "$value" "$root"; then
      case "$kind" in
        W) printf 'WorkingDirectory w instalacji IntegrationPlatform %s' "$root" ;;
        *) printf 'ExecStart w instalacji IntegrationPlatform %s' "$root" ;;
      esac
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$props" | awk '
  /^ExecStart=/ {
    s = $0; exe = ""
    if (match(s, /path=[^ ;]+/)) { exe = substr(s, RSTART + 5, RLENGTH - 5); print "P " exe }
    if (exe ~ /^\/(usr\/)?bin\/(ba)?sh$/ && match(s, /argv\[\]=[^;]*/)) {
      n = split(substr(s, RSTART + 7, RLENGTH - 7), t, /[ \t]+/); k = 0
      for (i = 1; i <= n; i++) if (t[i] != "") { k++; if (k == 2) { print "A " t[i]; break } }
    }
  }
  /^WorkingDirectory=/ { w = substr($0, 18); sub(/^[-!]/, "", w); print "W " w }')
EOF
  return 1
}

# ez_mount_covers <cert-path> <bind-source>: a Docker bind mount source covers
# the certificate when it is the file itself or a directory containing it.
# The source must lie strictly below an allowed root (a bind of "/" or "/srv"
# is not accepted as evidence).
ez_mount_covers() {
  ez_path_under_roots "$2" || return 1
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}
