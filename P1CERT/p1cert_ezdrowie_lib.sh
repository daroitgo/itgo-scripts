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
# 2: PEM certificate chains; helper apply operations carry the SHA-256 of the
# exact old target and new source files (plan version 2).
# 3: ez_target_dir_ok (root or operator owned target directories, group write
# for the root or operator group) used by the helper's descriptor/inode bound
# replacement.  A helper of API 1 or 2 left with this library (interrupted
# upgrade) refuses to run.
# 4: classic Integration Platform binding (ez_systemd_bound rule C): an
# external certificate named by SSL.patch in the appConfig.properties of the
# IntegrationPlatform installation the unit runs from, with the application
# tree policy ez_pi_appconfig_trusted.  Helpers of API 1-3 refuse it.
# 5: Docker Compose applications: discovery, password binding, keystore
# staging/verification shared with the helper operations apply-docker and
# recover.  Helpers of API 1-4 refuse it.
EZ_LIB_API=5

EZ_ALLOWED_ROOTS='/srv /usr/local /opt'
EZ_MAX_CERT_BYTES=65536
# Upper bound for the number of certificates in one PEM chain file.
EZ_MAX_CHAIN_CERTS=10
EZ_IDENTITY_DOMAIN='ezdrowie.gov.pl'
# Configuration of the classic Integration Platform (Tomcat p1-war), relative
# to its IntegrationPlatform installation directory, and its size limit.
EZ_PI_APPCONFIG_REL='apache-tomcat/webapps/p1-war/WEB-INF/appConfig.properties'
EZ_PI_APPCONFIG_MAX_BYTES=262144

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

# True when any DIRECTORY component of a logical path is exactly "OLD"
# (case-insensitive).  Such directories are certificate archives (e.g.
# /srv/CERTYFIKATY/P1/OLD) and never take part in ezdrowie handling.  Only
# complete components count: /srv/oldcerts/... or a file name containing
# "old" are not affected.  The last component (file name) is not checked.
ez_path_in_old_dir() {
  local rest="${1#/}" part

  while :; do
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}" ;;
      *) return 1 ;;
    esac
    case "$part" in
      [Oo][Ll][Dd]) return 0 ;;
    esac
  done
}

# A certificate target: allowed path whose basename matches the ezdrowie rule
# and which is not inside an OLD archive directory.  Used by scan, the plan
# parser and every helper operation on a target.
ez_target_path_ok() {
  ez_path_under_roots "$1" || return 1
  ! ez_path_in_old_dir "$1" || return 1
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

# ez_target_dir_ok <dir> <trusted-uid> <trusted-gid> [<operator-uid> <operator-gid>]
# Policy for a directory in which the root helper replaces a certificate:
#   - a real directory, not a symlink,
#   - owned by the trusted uid (root) or by the operator (the P1CERT user that
#     calls the helper through sudo, also for the scheduled run),
#   - never writable by others,
#   - writable by its group only when that group is the trusted group (root)
#     or the operator's group.
# Without an operator only the trusted uid may own it.
ez_target_dir_ok() {
  local dir="$1" tuid="$2" tgid="$3" ouid="${4:-}" ogid="${5:-}" meta owner group mode

  case "$tuid:$tgid" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  case "$ouid:$ogid" in
    :) ;;
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  meta="$(stat -c '%u %g %a' -- "$dir" 2>/dev/null)" || return 1
  read -r owner group mode <<EOF
$meta
EOF
  case "$owner:$group:$mode" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  [ "$owner" = "$tuid" ] || { [ -n "$ouid" ] && [ "$owner" = "$ouid" ]; } || return 1
  [ $((8#$mode & 8#002)) -eq 0 ] || return 1
  if [ $((8#$mode & 8#020)) -ne 0 ]; then
    [ "$group" = "$tgid" ] || { [ -n "$ogid" ] && [ "$group" = "$ogid" ]; } || return 1
  fi
  return 0
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

# SHA-256 fingerprint (OpenSSL notation) of the first certificate of a file.
ez_x509_fp() {
  LC_ALL=C openssl x509 -inform "$2" -in "$1" -noout -fingerprint -sha256 2>/dev/null |
    awk -F= '{ field=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", field); if (tolower(field) == "sha256 fingerprint") { print toupper($2); exit } }'
}

# Prints one single-valued "openssl x509" field: subject_hash, issuer_hash,
# startdate or enddate (value only, without a "notBefore=" style prefix).
ez_x509_value() {
  LC_ALL=C openssl x509 -in "$1" -noout "-$2" 2>/dev/null | head -n 1 | sed 's/^[A-Za-z]*=//'
}

ez_x509_is_ca() {
  LC_ALL=C openssl x509 -in "$1" -noout -text 2>/dev/null | grep -q 'CA:TRUE'
}

# ez_x509_signed_by <subject.pem> <issuer.pem> <epoch> <empty-dir>
# Cryptographic proof that <issuer> issued <subject>: "openssl verify" with
# <issuer> as the ONLY trust anchor (-partial_chain, an empty -CApath instead
# of the system directory and, on OpenSSL 3, no default store), evaluated at
# a time inside both validity periods.  Works with OpenSSL 1.0.2 and 3.x.
ez_x509_signed_by() {
  local subject="$1" issuer="$2" at="$3" capath="$4" major out

  ez_epoch_ok "$at" || return 1
  major="$(openssl version 2>/dev/null | awk '{ split($2, v, "."); print v[1] + 0; exit }')"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$major" -ge 3 ]; then
    out="$(LC_ALL=C openssl verify -CAfile "$issuer" -CApath "$capath" -no-CAstore \
      -partial_chain -attime "$at" "$subject" 2>/dev/null)" || return 1
  else
    out="$(LC_ALL=C openssl verify -CAfile "$issuer" -CApath "$capath" \
      -partial_chain -attime "$at" "$subject" 2>/dev/null)" || return 1
  fi
  [ "$out" = "$subject: OK" ]
}

# Validates a PEM file with EZC_COUNT (>1) CERTIFICATE blocks as a real
# certificate chain and splits it into $EZC_WORK/cert-<n>.pem:
#   - only well-formed CERTIFICATE blocks (no nested/unterminated block),
#   - every block is a parsable X.509 certificate, no duplicates,
#   - certificate 1 is the end-entity (leaf): not a CA, not self-issued,
#   - certificates 2..n are CAs; each one is the issuer of the previous one,
#     proven by name (canonical hash) and by its signature,
#   - certificates 2..n-1 are not self-issued; certificate n is the
#     self-issued root that terminates the chain.
# Sets EZC_REASON on failure.  Returns 0, 1 (internal error), 2 (malformed
# PEM structure) or 5 (not a valid chain).
ez_pem_chain_check() {
  local file="$1" n i cert prev="" fp seen=" " sh ih nb na ca
  local p_ih="" p_nb=0 p_na=0 lo hi

  EZC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/p1cert-ezc.XXXXXX" 2>/dev/null)" || {
    EZC_WORK=""
    EZC_REASON='nie można utworzyć katalogu tymczasowego'
    return 1
  }
  mkdir -- "$EZC_WORK/capath" || return 1
  # Marker lines must be exact; text outside blocks is ignored (as by OpenSSL).
  n="$(LC_ALL=C awk -v prefix="$EZC_WORK/cert-" '
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    index(line, "-----BEGIN") > 0 {
      if (inblk || line != "-----BEGIN CERTIFICATE-----") { bad = 1; exit }
      n++; inblk = 1; out = prefix n ".pem"; print line > out; next
    }
    index(line, "-----END") > 0 {
      if (!inblk || line != "-----END CERTIFICATE-----") { bad = 1; exit }
      print line > out; close(out); inblk = 0; next
    }
    inblk { print line > out }
    END { if (bad || inblk) exit 1; print n + 0 }' "$file")" || {
    EZC_REASON='niepoprawna struktura bloków PEM'
    return 2
  }
  [ "$n" = "$EZC_COUNT" ] || { EZC_REASON='niepoprawna struktura bloków PEM'; return 2; }
  [ "$n" -le "$EZ_MAX_CHAIN_CERTS" ] || {
    EZC_REASON="łańcuch zawiera więcej niż $EZ_MAX_CHAIN_CERTS certyfikatów"
    return 5
  }

  i=1
  while [ "$i" -le "$n" ]; do
    cert="$EZC_WORK/cert-$i.pem"
    fp="$(ez_x509_fp "$cert" PEM)"
    sh="$(ez_x509_value "$cert" subject_hash)"
    ih="$(ez_x509_value "$cert" issuer_hash)"
    nb="$(ez_to_epoch "$(ez_x509_value "$cert" startdate)")"
    na="$(ez_to_epoch "$(ez_x509_value "$cert" enddate)")"
    if ! ez_fp_ok "$fp" || [ -z "$sh" ] || [ -z "$ih" ] || ! ez_epoch_ok "$nb" || ! ez_epoch_ok "$na"; then
      EZC_REASON="certyfikat $i w pliku nie jest poprawnym certyfikatem X.509"
      return 5
    fi
    case "$seen" in
      *" $fp "*) EZC_REASON="certyfikat $i powtarza się w pliku"; return 5 ;;
    esac
    seen="$seen$fp "
    ca=no
    ! ez_x509_is_ca "$cert" || ca=yes

    if [ "$i" -eq 1 ]; then
      [ "$ca" = no ] || { EZC_REASON='pierwszy certyfikat jest certyfikatem CA (wymagany certyfikat końcowy jako pierwszy)'; return 5; }
      [ "$sh" != "$ih" ] || { EZC_REASON='pierwszy certyfikat jest samopodpisany'; return 5; }
    else
      [ "$ca" = yes ] || { EZC_REASON="certyfikat $i nie jest certyfikatem CA (np. drugi certyfikat końcowy)"; return 5; }
      [ "$p_ih" = "$sh" ] || { EZC_REASON="certyfikat $i nie jest wystawcą certyfikatu $((i - 1)) (niezgodna nazwa)"; return 5; }
      if [ "$i" -lt "$n" ]; then
        [ "$sh" != "$ih" ] || { EZC_REASON="certyfikat $i jest samopodpisany, a nie jest ostatni"; return 5; }
      else
        [ "$sh" = "$ih" ] || { EZC_REASON='ostatni certyfikat nie jest certyfikatem głównym (root) kończącym łańcuch'; return 5; }
      fi
      lo="$p_nb"; [ "$nb" -le "$lo" ] || lo="$nb"
      hi="$p_na"; [ "$na" -ge "$hi" ] || hi="$na"
      [ "$lo" -lt "$hi" ] || { EZC_REASON="okresy ważności certyfikatów $((i - 1)) i $i są rozłączne"; return 5; }
      ez_x509_signed_by "$prev" "$cert" $((lo + (hi - lo) / 2)) "$EZC_WORK/capath" || {
        EZC_REASON="podpis certyfikatu $((i - 1)) nie weryfikuje się kluczem certyfikatu $i"
        return 5
      }
    fi
    prev="$cert"; p_ih="$ih"; p_nb="$nb"; p_na="$na"
    i=$((i + 1))
  done
  return 0
}

# Inspects a certificate file: exactly one X.509 certificate (PEM or DER) or
# a valid PEM certificate chain (leaf -> intermediate CA(s) -> root, see
# ez_pem_chain_check).  Sets EZC_* variables; for a chain they describe the
# FIRST certificate (the leaf), only EZC_COUNT counts the whole file:
#   EZC_SAN_DNS      syntactically valid DNS SAN entries,
#   EZC_HAS_DNS_SAN  yes when the certificate has at least one DNS SAN entry
#                    (valid or not),
#   EZC_NAMES        the authoritative identity names: the DNS SANs when any
#                    exist, otherwise the CN (legacy fallback only),
#   EZC_REASON       detail of a rejected chain (may be empty).
# Return codes: 0 valid certificate or chain, 1 not a certificate/unreadable,
# 2 PEM block other than CERTIFICATE, malformed PEM structure or data after a
# DER certificate, 3 private key material present, 4 too large, 5 several
# certificates that do not form a valid chain.
ez_cert_inspect() {
  local rc

  EZC_WORK=""
  ez_cert_inspect_file "$1"
  rc=$?
  if [ -n "$EZC_WORK" ]; then
    rm -rf -- "$EZC_WORK"
  fi
  EZC_WORK=""
  return "$rc"
}

ez_cert_inspect_file() {
  local file="$1" src="$1" inform data text san name san_names="" size begin_count orig_digest rt_digest rc

  EZC_FORMAT=""; EZC_COUNT=0; EZC_FP=""; EZC_SUBJECT=""; EZC_ISSUER=""
  EZC_NOT_BEFORE=""; EZC_NOT_AFTER=""; EZC_NB_EPOCH=""; EZC_NA_EPOCH=""
  EZC_CN=""; EZC_SAN_DNS=""; EZC_HAS_DNS_SAN=no; EZC_NAMES=""; EZC_IS_CA=no; EZC_SELF_SIGNED=no
  EZC_REASON=""

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
    # No other PEM block (parameters, CRL, key or anything else).
    [ "$begin_count" = "$EZC_COUNT" ] || {
      EZC_REASON='plik zawiera blok PEM inny niż CERTIFICATE'
      return 2
    }
    if [ "$EZC_COUNT" -gt 1 ]; then
      ez_pem_chain_check "$file" || return
      # Every EZC_* value below describes the leaf.
      src="$EZC_WORK/cert-1.pem"
    fi
  else
    [ "$begin_count" = 0 ] || return 1
    inform=DER
    EZC_FORMAT=DER
  fi

  data="$(LC_ALL=C openssl x509 -inform "$inform" -in "$src" -noout -fingerprint -sha256 -subject -issuer -startdate -enddate 2>/dev/null)" || return 1

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
  EZC_CN="$(LC_ALL=C openssl x509 -inform "$inform" -in "$src" -noout -subject -nameopt multiline 2>/dev/null |
    awk '/^[[:space:]]+commonName[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }')"
  EZC_CN="$(ez_lower "$EZC_CN")"

  text="$(LC_ALL=C openssl x509 -inform "$inform" -in "$src" -noout -text 2>/dev/null)" || return 1
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

# Decides whether a file with <new_format> <new_count> certificates may
# replace a file with <old_format> <old_count> (EZC_FORMAT / EZC_COUNT of
# inspected files):
#   - a chain (count > 1) is written unchanged and only into a PEM target;
#     it is never converted to DER,
#   - a target that holds a chain is never reduced to a single certificate.
# The chain length itself may change.  Prints a reason and returns non-zero
# if the replacement is not acceptable.
ez_replacement_format_ok() {
  local old_format="$1" old_count="$2" new_format="$3" new_count="$4"

  case "$old_count:$new_count" in
    *[!0-9:]*|:*|*:) printf 'nieznana liczba certyfikatów'; return 1 ;;
  esac
  if [ "$new_count" -gt 1 ] && [ "$new_format" != PEM ]; then
    printf 'łańcuch certyfikatów musi być w formacie PEM'
    return 1
  fi
  if [ "$new_count" -gt 1 ] && [ "$old_format" != PEM ]; then
    printf 'źródło jest łańcuchem PEM, a plik docelowy ma format %s - konwersja łańcucha nie jest obsługiwana' "$old_format"
    return 1
  fi
  if [ "$old_count" -gt 1 ] && [ "$new_count" -le 1 ]; then
    printf 'plik docelowy zawiera łańcuch %s certyfikatów, a źródło pojedynczy certyfikat - łańcuch nie zostanie usunięty' "$old_count"
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

# Paths a unit runs from, from "systemctl show" output: "W <dir>" for
# WorkingDirectory, "P <exe>" for the executable of EVERY ExecStart command
# and "A <path>" for what a shell runs (see below).
#
# Every ExecStart command counts: "systemctl show" prints one
# "ExecStart={ path=... ; argv[]=... ; ignore_errors=... ; ... }" line per
# command (argv joined with spaces, without quoting); several blocks on one
# line are accepted as well.  Further lines:
#   "R <path>"  every other absolute path in an argument (references, used
#               only to detect ambiguity, never as a run path),
#   "X <why>"   the command cannot be analysed safely; ez_systemd_ip_root
#               then refuses the unit.
# Shells (/bin/sh, /bin/bash, also below /usr): "<shell> <script> [args]"
# gives "A <script>" (absolute only).  "<shell> -c <command>" is accepted
# only in the narrow form of ONE simple command "[exec] /absolute/program
# [args]" made of the characters A-Z a-z 0-9 . _ / @ + = : , - space tab:
# the program is "A", every other absolute path "R".  No control operator
# (; & && || |), redirection, assignment, cd, builtin (set -e, false, ...),
# relative program, $, backtick, quote, parenthesis, brace, glob or
# backslash: the shell semantics of anything else are not modelled, so it
# gives "X" (false negatives accepted, no false positive).  Nothing is
# expanded or executed.  Other shell
# options, a block that cannot be parsed or an argument that names an
# IntegrationPlatform installation without an absolute path (e.g.
# "${APP}/IntegrationPlatform_X") give "X".  The values are not validated
# here.
ez_systemd_run_paths() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    function isshell(p) { return p ~ /^\/(usr\/)?bin\/(ba)?sh$/ }
    function refs(s,   t, p, hit) {
      t = " " s; hit = 0
      while (match(t, /[^A-Za-z0-9._\/@+-]\/[A-Za-z0-9._\/@+-]*/)) {
        p = substr(t, RSTART + 1, RLENGTH - 1)
        print "R " p
        if (tolower(p) ~ /integrationplatform/) hit = 1
        t = substr(t, RSTART + RLENGTH)
      }
      # Named without a plain absolute path, or next to variable, command
      # substitution or home syntax ("${APP}/IntegrationPlatform_X").
      if (tolower(s) ~ /integrationplatform/ && ((!hit && s ~ /\//) || s ~ /[$`~]/)) print "X unresolved-reference"
    }
    # "-c": only ONE simple command "[exec] /absolute/program [args]" of
    # plain words; everything else (control operators, assignments, cd,
    # builtins, relative programs, any other shell syntax) is X.
    function shc(cmd,   n, w, m, v, j) {
      if (cmd ~ /[^A-Za-z0-9._\/@+=:, \t-]/) { print "X shell-c-syntax"; return }
      n = split(cmd, w, /[ \t]+/); m = 0
      for (j = 1; j <= n; j++) if (w[j] != "") v[++m] = w[j]
      j = 1
      if (j <= m && v[j] == "exec") j++
      if (j > m || substr(v[j], 1, 1) != "/") { print "X shell-c-command"; return }
      print "A " v[j]
      for (j++; j <= m; j++) refs(v[j])
    }
    function block(exe, argv,   n, t, m, v, i, cmd) {
      print "P " exe
      n = split(argv, t, /[ \t]+/); m = 0
      for (i = 1; i <= n; i++) if (t[i] != "") v[++m] = t[i]
      if (isshell(exe)) {
        if (m < 2) return
        if (v[2] == "-c") {
          cmd = ""
          for (i = 3; i <= m; i++) cmd = cmd " " v[i]
          shc(cmd)
          return
        }
        if (substr(v[2], 1, 1) == "-") { print "X shell-option"; return }
        if (substr(v[2], 1, 1) == "/") print "A " v[2]; else refs(v[2])
        for (i = 3; i <= m; i++) refs(v[i])
        return
      }
      for (i = 2; i <= m; i++) refs(v[i])
    }
    /^ExecStart=/ {
      s = substr($0, 11); nb = 0
      while ((i = index(s, "{ path=")) > 0) {
        s = substr(s, i + 7)
        j = index(s, " ; argv[]=")
        if (j == 0) { print "X exec-block"; break }
        exe = substr(s, 1, j - 1)
        s = substr(s, j + 10)
        k = index(s, " ; ignore_errors=")
        if (k == 0) k = index(s, " ; flags=")
        if (k == 0) { print "X exec-block"; break }
        nb++
        block(exe, substr(s, 1, k - 1))
        s = substr(s, k + 3)
      }
      if (nb == 0 && substr($0, 11) !~ /^[ \t]*$/) print "X exec-block"
    }
    /^WorkingDirectory=/ { w = substr($0, 18); sub(/^[-!]/, "", w); print "W " w }'
}

# The one IntegrationPlatform installation directory a unit runs from
# (ez_systemd_run_paths), fail closed:
#   - any "X" line refuses the unit,
#   - every W/P/A path and every R path below an allowed root that names an
#     IntegrationPlatform component must resolve with ez_ip_root, and all of
#     them must give the SAME installation (IntegrationPlatform_PI and
#     IntegrationPlatform_PI2 are different installations),
#   - at least one of them must be a run path (W/P/A); a mere reference such
#     as "rsync /srv/IntegrationPlatform_PI/conf /backup" is not enough.
# Prints the installation directory or fails.
ez_systemd_ip_root() {
  local kind value root found="" run=no allowed under

  while IFS=' ' read -r kind value; do
    case "$kind" in
      X) return 1 ;;
      W|P|A|R) ;;
      *) continue ;;
    esac
    [ -n "$value" ] || continue
    case "$(ez_lower "$value")" in
      *integrationplatform*) ;;
      *) continue ;;
    esac
    if [ "$kind" = R ]; then
      # References outside the allowed roots cannot name an installation.
      under=no
      for allowed in $EZ_ALLOWED_ROOTS; do
        case "$value" in
          "$allowed"/*) under=yes ;;
        esac
      done
      [ "$under" = yes ] || continue
    fi
    root="$(ez_ip_root "$value")" || return 1
    if [ -z "$found" ]; then
      found="$root"
    elif [ "$found" != "$root" ]; then
      return 1
    fi
    [ "$kind" = R ] || run=yes
  done <<EOF
$(ez_systemd_run_paths "$1")
EOF
  [ -n "$found" ] && [ "$run" = yes ] || return 1
  printf '%s' "$found"
}

# "<uid> <gid>" (primary group) of the unit's User= from "systemctl show"
# output; the trusted ids $2/$3 (root) when User= is empty.  Only a plain
# user name or number that resolves through "id" is accepted.
ez_systemd_app_ids() {
  local user uid gid

  [ "$(printf '%s\n' "$1" | grep -c '^User=')" -le 1 ] || return 1
  user="$(printf '%s\n' "$1" | sed -n 's/^User=//p')"
  if [ -z "$user" ]; then
    printf '%s %s' "$2" "$3"
    return 0
  fi
  case "$user" in
    -*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#user}" -le 32 ] || return 1
  uid="$(id -u -- "$user" 2>/dev/null)" && gid="$(id -g -- "$user" 2>/dev/null)" || return 1
  case "$uid:$gid" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  printf '%s %s' "$uid" "$gid"
}

# ez_pi_parents_ok <fs-prefix> <ip-root> <trusted-uid> <trusted-gid>
# Every directory from / down to the parent of an IntegrationPlatform
# installation directory is root-controlled: ez_target_dir_ok without a
# second principal (owner root, group write only for the root group, never
# world writable, not a symlink), e.g. /srv as root:root 775.
ez_pi_parents_ok() {
  local prefix="$1" root="$2" tuid="$3" tgid="$4" current="" rest part

  ez_path_under_roots "$root" || return 1
  ez_target_dir_ok "$prefix/" "$tuid" "$tgid" || return 1
  rest="${root#/}"
  while :; do
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}" ;;
      *) return 0 ;;
    esac
    current="$current/$part"
    ez_target_dir_ok "$prefix$current" "$tuid" "$tgid" || return 1
  done
}

# ez_pi_tree_ok <fs-prefix> <ip-root> <trusted-uid> <trusted-gid> <app-uid> <app-gid>
# The installation directory, every directory below it down to WEB-INF and
# appConfig.properties itself belong to root or to the application user of
# the unit (User=): owner root or that user, group write only for the root
# group or the user's primary group, never world writable, no symlink.  The
# file is a regular file with one hard link and at most
# EZ_PI_APPCONFIG_MAX_BYTES bytes.  Matches the real model itgo:itgo 775.
ez_pi_tree_ok() {
  local prefix="$1" root="$2" tuid="$3" tgid="$4" auid="$5" agid="$6" file current rest part meta links owner group mode size

  case "$tuid:$tgid:$auid:$agid" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  ez_path_under_roots "$root" || return 1
  file="$root/$EZ_PI_APPCONFIG_REL"
  ez_path_under_roots "$file" || return 1
  ez_path_no_symlinks "$prefix" "$file" || return 1
  current="$root"
  rest="$EZ_PI_APPCONFIG_REL"
  while :; do
    ez_target_dir_ok "$prefix$current" "$tuid" "$tgid" "$auid" "$agid" || return 1
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}"; current="$current/$part" ;;
      *) break ;;
    esac
  done
  [ -f "$prefix$file" ] && [ ! -L "$prefix$file" ] || return 1
  meta="$(stat -c '%h %u %g %a %s' -- "$prefix$file" 2>/dev/null)" || return 1
  read -r links owner group mode size <<EOF
$meta
EOF
  case "$links:$owner:$group:$mode:$size" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  [ "$links" = 1 ] || return 1
  [ "$owner" = "$tuid" ] || [ "$owner" = "$auid" ] || return 1
  [ $((8#$mode & 8#002)) -eq 0 ] || return 1
  if [ $((8#$mode & 8#020)) -ne 0 ]; then
    [ "$group" = "$tgid" ] || [ "$group" = "$agid" ] || return 1
  fi
  [ "$size" -le "$EZ_PI_APPCONFIG_MAX_BYTES" ]
}

# ez_pi_appconfig_trusted <fs-prefix> <ip-root> <trusted-uid> <trusted-gid> <app-uid> <app-gid>
# Narrow trust policy for appConfig.properties of one IntegrationPlatform
# installation (ez_pi_parents_ok and ez_pi_tree_ok).  <ip-root> must itself be
# an installation directory (its own ez_ip_root).  Used only for SSL.patch
# evidence; helper_path_trusted / helper_node_trusted are not affected.
ez_pi_appconfig_trusted() {
  [ "$(ez_ip_root "$2")" = "$2" ] || return 1
  ez_pi_parents_ok "$1" "$2" "$3" "$4" && ez_pi_tree_ok "$@"
}

# Prints a file for SSL.patch evidence: at most EZ_PI_APPCONFIG_MAX_BYTES
# bytes and no NUL byte (a shell variable would silently drop it).
ez_pi_appconfig_load() {
  local size

  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  size="$(ez_file_size "$1")"
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$size" -le "$EZ_PI_APPCONFIG_MAX_BYTES" ] || return 1
  [ "$(tr -d '\000' < "$1" | wc -c | tr -d ' ')" = "$size" ] || return 1
  cat -- "$1"
}

# Reads appConfig.properties text on stdin; true when it has at least one
# active SSL.patch entry and every one of them is exactly the path $1.
# Only the line structure of java.util.Properties is followed, nothing is
# interpreted or expanded:
#   - leading whitespace (space, tab, form feed) is ignored, "#"/"!" lines
#     are comments (never continued), CRLF is accepted,
#   - the key is "SSL.patch" (case-sensitive), separated by "=", ":" or
#     whitespace; whitespace around the value is trimmed,
#   - a line continued from the previous one (odd number of trailing
#     backslashes) is never an entry,
#   - fail closed: an escaped key (backslash), an SSL.patch entry that is
#     continued, an SSL.patch-like continuation line or a bare CR (another
#     line terminator) make the whole file unusable as evidence.
# Commented, prefixed, suffixed (.bak) or escaped values never match.
ez_pi_ssl_patch_is() {
  ez_path_chars_ok "$1" || return 1
  LC_ALL=C awk -v want="$1" '
    function odd_bs(s) { return match(s, /\\+$/) && RLENGTH % 2 == 1 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (index(line, "\r") > 0) { bad = 1; exit }
      s = line
      sub(/^[ \t\f]+/, "", s)
      if (cont) {
        if (index(s, "SSL.patch") == 1) bad = 1
        cont = odd_bs(line)
        next
      }
      if (s == "" || s ~ /^[#!]/) next
      cont = odd_bs(line)
      match(s, /^[^ \t\f=:]*/)
      key = substr(s, 1, RLENGTH)
      rest = substr(s, RLENGTH + 1)
      if (index(key, "\\") > 0) { bad = 1; next }
      if (key != "SSL.patch") next
      n++
      if (cont) { bad = 1; next }
      sub(/^[ \t\f]+/, "", rest)
      c = substr(rest, 1, 1)
      if (c == "=" || c == ":") rest = substr(rest, 2)
      sub(/^[ \t\f]+/, "", rest)
      sub(/[ \t\f]+$/, "", rest)
      if (rest != want) bad = 1
    }
    END { exit (n > 0 && !bad) ? 0 : 1 }'
}

# ez_systemd_bound <cert-path> <systemctl-show-output> <config-text> [<pi-appconfig-text>]
# Proves a relation between a certificate file and a systemd unit:
#   A. the exact certificate path appears in the unit properties (ExecStart,
#      Environment, ...) or in the unit/drop-in/environment file contents
#      (comment lines ignored), or
#   B. the certificate lies in an IntegrationPlatform installation directory
#      and the unit runs from exactly that installation: ez_systemd_ip_root
#      (every ExecStart command, shell and WorkingDirectory; no X record, no
#      second installation) is that SAME directory.  Commands outside any
#      installation do not matter.  A common parent such as /srv is never
#      enough, or
#   C. classic Integration Platform: <pi-appconfig-text> is the content of
#      <ip-root>/$EZ_PI_APPCONFIG_REL of the one installation the unit runs
#      from (ez_systemd_ip_root: all ExecStart commands, shells and
#      WorkingDirectory unambiguous), read by the caller only after
#      ez_pi_appconfig_trusted, and its SSL.patch names exactly the
#      certificate (ez_pi_ssl_patch_is).  The certificate may lie anywhere
#      (e.g. /srv/CERTYFIKATY); its location alone is never evidence.
# Prints the reason and returns 0, or returns 1.
ez_systemd_bound() {
  local cert="$1" props="$2" config="$3" appcfg="${4:-}" root kind value

  ez_target_path_ok "$cert" || return 1
  if printf '%s\n' "$props" | ez_text_has_path "$cert"; then
    printf 'konfiguracja unitu wskazuje dokładną ścieżkę certyfikatu'
    return 0
  fi
  if printf '%s\n' "$config" | grep -v -E '^[[:space:]]*[#;]' | ez_text_has_path "$cert"; then
    printf 'plik unitu/drop-in/EnvironmentFile wskazuje dokładną ścieżkę certyfikatu'
    return 0
  fi
  if root="$(ez_ip_root "$cert")" && [ "$root" != "$cert" ] &&
     [ "$(ez_systemd_ip_root "$props")" = "$root" ]; then
    # The unambiguous installation is the certificate's: name the run path.
    while IFS=' ' read -r kind value; do
      case "$kind" in
        W|P|A) ;;
        *) continue ;;
      esac
      [ -n "$value" ] || continue
      if ez_path_within "$value" "$root"; then
        case "$kind" in
          W) printf 'WorkingDirectory w instalacji IntegrationPlatform %s' "$root" ;;
          *) printf 'ExecStart w instalacji IntegrationPlatform %s' "$root" ;;
        esac
        return 0
      fi
    done <<EOF
$(ez_systemd_run_paths "$props")
EOF
  fi
  [ -n "$appcfg" ] || return 1
  root="$(ez_systemd_ip_root "$props")" || return 1
  printf '%s\n' "$appcfg" | ez_pi_ssl_patch_is "$cert" || return 1
  printf '%s SSL.patch wskazuje certyfikat w instalacji IntegrationPlatform %s' \
    "${EZ_PI_APPCONFIG_REL#apache-tomcat/webapps/}" "$root"
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

# ---------------------------------------------------------------------------
# Docker Compose discovery (read-only).
#
# Static analysis of how a systemd unit runs Docker Compose (v1
# "docker-compose", v2 "docker compose", directly or through /usr/bin/env)
# and of the compose configuration it uses (compose files, .env, env_file,
# environment, bind mounts, named volumes with a bind device, file based
# secrets/configs).  Its result is the host path of every certificate or
# keystore a service references, independent of application and file names.
#
# Nothing is executed: no docker, no compose, no shell.  Values are expanded
# only by the compose interpolation rules implemented below ($$, $VAR,
# ${VAR}, ${VAR:-x}, ${VAR-x}, ${VAR:?x}, ${VAR?x}, ${VAR:+x}, ${VAR+x}).
# YAML is read in the block style used by compose files; anchors, aliases,
# merge keys (<<), extends, include, block scalars and other constructs that
# are not modelled make the affected service (or the whole project) ambiguous
# instead of being guessed.  Environment values are never printed: only
# names of password variables and values that are certificate/keystore paths
# leave the parser.
# ---------------------------------------------------------------------------

# Certificate and keystore file extensions considered by the discovery:
# .pem .crt .cer .der .jks .p12 .pfx (certext in EZ_DC_AWK and the directory
# listing of p1cert_ezdrowie.sh); other files count only when a variable
# that names a certificate/keystore points to them, and then their content
# decides.
# Upper bound for one compose, .env or env_file file read by the parser.
EZ_DC_MAX_CONFIG_BYTES=1048576
# Upper bound for a keystore file.
EZ_DC_MAX_STORE_BYTES=1048576

# Path character rule of the discovery (same conservative set as targets).
ez_dc_path_ok() {
  ez_path_chars_ok "$1" || return 1
  case "$1" in
    /*) return 0 ;;
  esac
  return 1
}

# Archive rule of the discovery: true when any DIRECTORY component of a
# logical path CONTAINS "old" in any case (/srv/OLD, /srv/oldcerts,
# /srv/app_Old, but also /srv/folder or /opt/gold); the file name itself is
# not checked.  Deliberately broader than ez_path_in_old_dir, which scan,
# plan, run and the helper keep using unchanged.
ez_dc_path_in_old_dir() {
  local rest="${1#/}" part

  while :; do
    case "$rest" in
      */*) part="${rest%%/*}"; rest="${rest#*/}" ;;
      *) return 1 ;;
    esac
    case "$part" in
      *[Oo][Ll][Dd]*) return 0 ;;
    esac
  done
}

# ez_dc_normpath <base-dir> <path>: absolute, normalized path ("." and ".."
# removed string-wise; ".." never goes above "/").
ez_dc_normpath() {
  local p="$2" part rest out="" n=0 i=0
  local -a stack=()

  case "$p" in
    /*) ;;
    *) p="$1/$p" ;;
  esac
  rest="$p"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    case "$part" in
      ''|.) ;;
      ..) [ "$n" -eq 0 ] || n=$((n - 1)) ;;
      *) stack[$n]="$part"; n=$((n + 1)) ;;
    esac
  done
  while [ "$i" -lt "$n" ]; do
    out="$out/${stack[$i]}"
    i=$((i + 1))
  done
  printf '%s' "${out:-/}"
}

# Docker Compose commands of a unit, from "systemctl show" output (same
# ExecStart block format as ez_systemd_run_paths).  For every block that
# runs compose:
#   "B <v1|v2> <program>"  start of a compose command,
#   "S <NAME=value>"       assignment made by /usr/bin/env before it,
#   "F <file>" "D <project-directory>" "E <env-file>" "N <project-name>"
#   "P <profile>"          global compose options,
#   "C <subcommand>"       the compose subcommand (up, start, ...).
# "X <why>" marks a command that may run compose but cannot be analysed
# (shell, env options, docker global options, remote daemon options,
# unknown compose options, systemd variables).  "W <dir>" is the unit's
# WorkingDirectory.  Blocks that do not run compose print nothing.
ez_dc_exec_parse() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    function base(p) { sub(/.*\//, "", p); return p }
    function isshell(p) { p = base(p); return p == "sh" || p == "bash" || p == "dash" }
    function block(exe, argv,   n, t, m, v, i, w, prog, b, ver, opt, val, eq, hasval, ns, senv) {
      n = split(argv, t, /[ \t]+/); m = 0
      for (i = 1; i <= n; i++) if (t[i] != "") v[++m] = t[i]
      i = 2; prog = exe; ns = 0
      if (base(exe) == "env") {
        while (i <= m && v[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) senv[++ns] = v[i++]
        if (i <= m && substr(v[i], 1, 1) == "-") { if (argv ~ /docker/) print "X env-option"; return }
        if (i > m) return
        prog = v[i++]
      }
      if (isshell(prog)) { if (argv ~ /docker/) print "X shell"; return }
      b = base(prog)
      if (b == "docker-compose") ver = "v1"
      else if (b == "docker") {
        if (i <= m && v[i] == "compose") { ver = "v2"; i++ }
        else { for (w = i; w <= m; w++) if (v[w] == "compose") { print "X docker-option"; return }; return }
      } else return
      if (prog ~ /\// && prog !~ /^\//) { print "X relative-program"; return }
      if (argv ~ /[$%]/) { print "X variable"; return }
      print "B " ver " " prog
      for (w = 1; w <= ns; w++) print "S " senv[w]
      while (i <= m) {
        opt = v[i]; val = ""; hasval = 0
        eq = index(opt, "=")
        if (substr(opt, 1, 2) == "--" && eq > 0) { val = substr(opt, eq + 1); opt = substr(opt, 1, eq - 1); hasval = 1 }
        if (substr(opt, 1, 1) != "-") { print "C " opt; return }
        if (opt == "-f" || opt == "--file" || opt == "-p" || opt == "--project-name" || opt == "--project-directory" ||
            opt == "--env-file" || opt == "--profile" || opt == "--ansi" || opt == "--progress" || opt == "--parallel" || opt == "--log-level") {
          if (!hasval) { i++; if (i > m) { print "X option-value"; return }; val = v[i] }
          if (opt == "-f" || opt == "--file") print "F " val
          else if (opt == "-p" || opt == "--project-name") print "N " val
          else if (opt == "--project-directory") print "D " val
          else if (opt == "--env-file") print "E " val
          else if (opt == "--profile") print "P " val
          i++
          continue
        }
        if (!hasval && (opt == "--verbose" || opt == "--no-ansi" || opt == "--compatibility" || opt == "--dry-run" || opt == "--all-resources")) { i++; continue }
        print "X option"
        return
      }
      print "X no-subcommand"
    }
    /^ExecStart=/ {
      s = substr($0, 11)
      while ((i = index(s, "{ path=")) > 0) {
        s = substr(s, i + 7)
        j = index(s, " ; argv[]=")
        if (j == 0) { if (s ~ /docker/) print "X exec-block"; break }
        exe = substr(s, 1, j - 1)
        s = substr(s, j + 10)
        k = index(s, " ; ignore_errors=")
        if (k == 0) k = index(s, " ; flags=")
        if (k == 0) { if (s ~ /docker/) print "X exec-block"; break }
        block(exe, substr(s, 1, k - 1))
        s = substr(s, k + 3)
      }
    }
    /^WorkingDirectory=/ { w = substr($0, 18); sub(/^[-!+]+/, "", w); print "W " w }'
}

# ez_dc_invocation <props>: the Docker Compose invocation of a unit.  Returns
# 1 when the unit does not run compose.  Otherwise sets
#   DCI_VERSION   v1 | v2 | ? (unanalysable command),
#   DCI_PROG      program (docker-compose, /usr/bin/docker, ...),
#   DCI_CWD       working directory of the command ("/" when not set),
#   DCI_FILES     -f files, absolute and normalized, newline separated,
#   DCI_PROJDIR   --project-directory (absolute) or empty,
#   DCI_ENVFILE   --env-file (absolute) or empty,
#   DCI_NAME      -p project name or empty,
#   DCI_PROFILES  --profile values (space separated),
#   DCI_SUB       compose subcommand,
#   DCI_ASSIGN    /usr/bin/env assignments, one "NAME=value" per line,
#   DCI_ERR       why the invocation is ambiguous/unsupported (empty: OK).
# Several compose commands in ExecStart are accepted only when they use the
# same configuration (files, directories, env file, name, profiles).
ez_dc_invocation() {
  local props="$1" line kind value blocks=0 sig="" first_sig="" found=no files="" file

  DCI_VERSION=""; DCI_PROG=""; DCI_CWD="/"; DCI_FILES=""; DCI_PROJDIR=""; DCI_ENVFILE=""
  DCI_NAME=""; DCI_PROFILES=""; DCI_SUB=""; DCI_ASSIGN=""; DCI_ERR=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="${line%% *}"
    value="${line#* }"
    [ "$value" != "$line" ] || value=""
    case "$kind" in
      W)
        case "$value" in
          '') ;;
          '~'*) DCI_ERR="${DCI_ERR:-WorkingDirectory względem katalogu domowego}" ;;
          *)
            if ez_dc_path_ok "$value"; then
              DCI_CWD="$(ez_dc_normpath / "$value")"
            else
              DCI_ERR="${DCI_ERR:-nieobsługiwany WorkingDirectory}"
            fi
            ;;
        esac
        ;;
      B)
        found=yes
        blocks=$((blocks + 1))
        if [ "$blocks" -eq 2 ]; then
          first_sig="$sig"
        fi
        [ "$blocks" -eq 1 ] || sig=""
        if [ "$blocks" -eq 1 ]; then
          DCI_VERSION="${value%% *}"
          DCI_PROG="${value#* }"
        elif [ "${value%% *}" != "$DCI_VERSION" ]; then
          DCI_ERR="${DCI_ERR:-polecenia Compose v1 i v2 w jednej jednostce}"
        fi
        ;;
      X)
        found=yes
        [ -n "$DCI_VERSION" ] || DCI_VERSION='?'
        case "$value" in
          shell) DCI_ERR="${DCI_ERR:-Compose uruchamiany przez powłokę (sh/bash) - składnia nieobsługiwana}" ;;
          env-option) DCI_ERR="${DCI_ERR:-opcje /usr/bin/env nieobsługiwane}" ;;
          docker-option) DCI_ERR="${DCI_ERR:-globalne opcje docker przed compose nieobsługiwane}" ;;
          variable) DCI_ERR="${DCI_ERR:-zmienne systemd w poleceniu Compose nieobsługiwane}" ;;
          option) DCI_ERR="${DCI_ERR:-nieobsługiwana opcja Compose (np. zdalny daemon)}" ;;
          relative-program) DCI_ERR="${DCI_ERR:-program Compose podany ścieżką względną}" ;;
          *) DCI_ERR="${DCI_ERR:-polecenie Compose nie może zostać przeanalizowane}" ;;
        esac
        ;;
      S|F|D|E|N|P|C)
        if [ "$kind" != C ]; then
          sig="$sig$kind:$value;"
        elif [ "$blocks" -gt 1 ] && [ "$sig" != "$first_sig" ]; then
          # Every further block must repeat the configuration of the first.
          DCI_ERR="${DCI_ERR:-kilka poleceń Compose z różną konfiguracją}"
        fi
        [ "$blocks" -le 1 ] || continue
        case "$kind" in
          S) DCI_ASSIGN="${DCI_ASSIGN:+$DCI_ASSIGN
}$value" ;;
          F) DCI_FILES="${DCI_FILES:+$DCI_FILES
}$value" ;;
          D) DCI_PROJDIR="$value" ;;
          E) DCI_ENVFILE="$value" ;;
          N) DCI_NAME="$value" ;;
          P) DCI_PROFILES="${DCI_PROFILES:+$DCI_PROFILES }$value" ;;
          C) DCI_SUB="$value" ;;
        esac
        ;;
    esac
  done <<EOF
$(ez_dc_exec_parse "$props")
EOF
  [ "$found" = yes ] || return 1
  # Relative options are relative to the working directory of the command.
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      '~'*) DCI_ERR="${DCI_ERR:-plik Compose względem katalogu domowego}"; continue ;;
    esac
    file="$(ez_dc_normpath "$DCI_CWD" "$file")"
    ez_dc_path_ok "$file" || { DCI_ERR="${DCI_ERR:-ścieżka pliku Compose zawiera nieobsługiwane znaki}"; continue; }
    files="${files:+$files
}$file"
  done <<EOF
$DCI_FILES
EOF
  DCI_FILES="$files"
  if [ -n "$DCI_PROJDIR" ]; then
    DCI_PROJDIR="$(ez_dc_resolve_opt "$DCI_PROJDIR")" ||
      DCI_ERR="${DCI_ERR:-nieobsługiwana ścieżka --project-directory}"
  fi
  if [ -n "$DCI_ENVFILE" ]; then
    DCI_ENVFILE="$(ez_dc_resolve_opt "$DCI_ENVFILE")" ||
      DCI_ERR="${DCI_ERR:-nieobsługiwana ścieżka --env-file}"
  fi
  return 0
}

# Resolves a --project-directory / --env-file value against DCI_CWD; fails
# for a home-relative path or unsupported characters.
ez_dc_resolve_opt() {
  case "$1" in
    '~'*) return 1 ;;
  esac
  local value
  value="$(ez_dc_normpath "$DCI_CWD" "$1")"
  ez_dc_path_ok "$value" || return 1
  printf '%s' "$value"
}

# Input for the compose model describing the environment of the compose
# process started by a unit, in systemd precedence order: "E <Environment=
# value>" lines, "F <EnvironmentFile>" (later wins), then "S NAME=value"
# from /usr/bin/env.  $2 are the DCI_ASSIGN lines.
ez_dc_unit_env_input() {
  local props="$1" assign="$2" kind path line

  printf '%s\n' "$props" | sed -n 's/^Environment=/E /p'
  while IFS=' ' read -r kind path; do
    [ "$kind" = E ] && [ -n "$path" ] || continue
    printf 'F %s\n' "$path"
  done <<EOF
$(ez_systemd_config_files "$props")
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'S %s\n' "$line"
  done <<EOF
$assign
EOF
}

# The awk program behind ez_dc_project/ez_dc_model/ez_dc_secret.  Variables:
# mode (env | model | value; value: qsvc, qvar), fsroot (test filesystem prefix), envfile, envexplicit (1:
# --env-file was given), files (newline separated absolute compose files),
# projdir, maxbytes.  stdin: ez_dc_unit_env_input.  Output records are
# separated by \034.  Values of password-like variables never leave it.
EZ_DC_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function rec(t, a, b, c, d) { if (!QUIET) print t SEP a SEP b SEP c SEP d }
function gerr(m) { rec("ERR", "-", m) }
function serr(s, m) { if (!((s SUBSEP m) in SERRSEEN)) { SERRSEEN[s, m] = 1; rec("SERR", s, m) } }
function swarn(s, m) { rec("SWARN", s, m) }
function secretkey(k) { k = toupper(k); return k ~ /PASS|PWD|SECRET|TOKEN|CREDENTIAL|PRIVATE|APIKEY|API_KEY/ }
function passkey(k) { k = toupper(k); return k ~ /PASS|PWD/ }
function certext(p) { p = tolower(p); sub(/.*\//, "", p); return p ~ /\.(pem|crt|cer|der|jks|p12|pfx)$/ }
# Variable names that point to a certificate or keystore even without a
# known extension (the content decides the type later).
function certkey(k) { k = toupper(k); return k ~ /CERT|TRUST|KEYSTORE|SSL|TLS|PEM|PKCS|P12|JKS|(^|_)CA(_|$)/ }
function certref(k, p) { return certext(p) || (certkey(k) && substr(p, 1, 1) == "/") }
# The only form in which a value may be printed (same set as ez_path_chars_ok).
function safepath(p) { return p ~ /^[A-Za-z0-9._\/@+-]+$/ }
function normpath(b, p,   n, parts, i, sp, stack, out) {
  if (substr(p, 1, 1) != "/") p = b "/" p
  n = split(p, parts, "/"); sp = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (sp > 0) sp--; continue }
    stack[++sp] = parts[i]
  }
  out = ""
  for (i = 1; i <= sp; i++) out = out "/" stack[i]
  return out == "" ? "/" : out
}
# Compose interpolation.  UNRES is set when a variable is missing without a
# default, required (${X:?}) but unset, or the syntax is not supported.
function interp(s,   out, i, n, c, depth, j, ch, inner, name, rest, isset, val, colon, arg) {
  out = ""; i = 1; n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c != "$") { out = out c; i++; continue }
    if (substr(s, i + 1, 1) == "$") { out = out "$"; i += 2; continue }
    if (substr(s, i + 1, 1) == "{") {
      depth = 1; j = i + 2
      while (j <= n && depth > 0) { ch = substr(s, j, 1); if (ch == "{") depth++; else if (ch == "}") depth--; j++ }
      if (depth > 0) { UNRES = 1; return out substr(s, i) }
      inner = substr(s, i + 2, j - i - 3); i = j
      if (!match(inner, /^[A-Za-z_][A-Za-z0-9_]*/)) { UNRES = 1; continue }
      name = substr(inner, 1, RLENGTH); rest = substr(inner, RLENGTH + 1)
      isset = (name in ENVV); val = isset ? ENVV[name] : ""
      if (rest == "") { if (!isset) UNRES = 1; out = out val; continue }
      colon = (substr(rest, 1, 1) == ":")
      ch = substr(rest, colon ? 2 : 1, 1)
      arg = substr(rest, colon ? 3 : 2)
      if (ch == "-") { if (isset && (!colon || val != "")) out = out val; else out = out interp(arg); continue }
      if (ch == "?") { if (isset && (!colon || val != "")) out = out val; else UNRES = 1; continue }
      if (ch == "+") { if (isset && (!colon || val != "")) out = out interp(arg); continue }
      UNRES = 1; continue
    }
    if (match(substr(s, i + 1), /^[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(s, i + 1, RLENGTH); i += RLENGTH + 1
      if (name in ENVV) out = out ENVV[name]; else UNRES = 1
      continue
    }
    out = out "$"; i++
  }
  return out
}
# systemd "Environment=" value: words separated by blanks, double quotes.
function unit_env(s,   i, n, ch, w, q, eq) {
  n = length(s); w = ""; q = 0
  for (i = 1; i <= n + 1; i++) {
    ch = (i <= n) ? substr(s, i, 1) : " "
    if (ch == "\"") { q = !q; continue }
    if (!q && (ch == " " || ch == "\t")) {
      eq = index(w, "=")
      if (eq > 1) SH[substr(w, 1, eq - 1)] = substr(w, eq + 1)
      w = ""; continue
    }
    w = w ch
  }
}
# Reads a KEY=VALUE file.  how: "shell" (systemd EnvironmentFile, no
# interpolation), "dotenv" (project .env: interpolated, the process
# environment wins), "cont" (env_file of a service, interpolated, source
# CURSRC).  Returns -1 when the file cannot be read, -2 when it is too
# large, otherwise the number of entries.
function kvfile(path, how,   line, r, n, k, v, q, j, ch, out, bytes, eq, ok) {
  n = 0; bytes = 0
  r = (getline line < (fsroot path))
  if (r < 0) return -1
  while (r > 0) {
    bytes += length(line) + 1
    if (bytes > maxbytes) { close(fsroot path); return -2 }
    sub(/\r$/, "", line)
    if (line !~ /^[ \t]*([#;]|$)/) {
      sub(/^[ \t]*export[ \t]+/, "", line)
      eq = index(line, "=")
      k = (eq > 0) ? trim(substr(line, 1, eq - 1)) : ""
      v = substr(line, eq + 1); sub(/^[ \t]+/, "", v)
      ok = (eq > 0 && k ~ /^[A-Za-z_][A-Za-z0-9_.-]*$/)
      UNRES = 0
      if (ok) {
        q = substr(v, 1, 1)
        if (q == "\047") {
          j = index(substr(v, 2), "\047")
          if (j == 0) ok = 0; else v = substr(v, 2, j - 1)
        } else if (q == "\"") {
          out = ""; ok = 0
          for (j = 2; j <= length(v); j++) {
            ch = substr(v, j, 1)
            if (ch == "\\" && j < length(v)) { j++; ch = substr(v, j, 1); if (ch == "n") ch = "\n"; out = out ch; continue }
            if (ch == "\"") { ok = 1; break }
            out = out ch
          }
          v = (how == "shell") ? out : interp(out)
        } else {
          sub(/[ \t]+#.*$/, "", v); v = trim(v)
          if (how != "shell") v = interp(v)
        }
      }
      if (ok) {
        n++
        if (how == "shell") SH[k] = v
        else if (how == "dotenv") { if (!(k in SH)) ENVV[k] = v }
        else setce(k, v, CURSRC, UNRES)
      }
    }
    r = (getline line < (fsroot path))
  }
  close(fsroot path)
  return n
}
function setce(k, v, src, u) {
  if (!(k in CE)) CEK[++CEN] = k
  CE[k] = v; CES[k] = src; CEU[k] = u
}
# Removes a comment outside quotes and trailing blanks.
function stripc(s,   i, n, ch, q, out, prev) {
  n = length(s); q = ""; out = ""
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1); prev = (i > 1) ? substr(s, i - 1, 1) : " "
    if (q == "") {
      if (ch == "#" && prev ~ /[ \t]/) break
      if ((ch == "\"" || ch == "\047") && prev ~ /[ \t:\[{,-]/) q = ch
    } else if (ch == q && !(q == "\"" && prev == "\\")) q = ""
    out = out ch
  }
  sub(/[ \t]+$/, "", out)
  return out
}
# "key: value" / "key:" (plain or quoted key) -> KK, KV.
function splitkv(c,   q, j, k) {
  KK = ""; KV = ""
  q = substr(c, 1, 1)
  if (q == "\"" || q == "\047") {
    j = index(substr(c, 2), q); if (j == 0) return 0
    k = substr(c, 2, j - 1); c = substr(c, j + 2)
    if (c !~ /^[ \t]*:([ \t]|$)/) return 0
    sub(/^[ \t]*:/, "", c); KK = k; KV = trim(c); return 1
  }
  if (match(c, /:([ \t]|$)/)) { KK = trim(substr(c, 1, RSTART - 1)); KV = trim(substr(c, RSTART + 1)); return KK != "" }
  return 0
}
# Scalar value; YANCH (anchor, alias, tag), YFLOW, YBLOCK and YBAD
# (unterminated quote) mark what is not modelled.
function yscalar(v,   q, out, i, ch) {
  YANCH = 0; YFLOW = 0; YBLOCK = 0; YBAD = 0
  v = trim(v); q = substr(v, 1, 1)
  if (q == "\047") {
    if (length(v) < 2 || substr(v, length(v)) != "\047") { YBAD = 1; return v }
    v = substr(v, 2, length(v) - 2); gsub(/\047\047/, "\047", v); return v
  }
  if (q == "\"") {
    if (length(v) < 2 || substr(v, length(v)) != "\"") { YBAD = 1; return v }
    v = substr(v, 2, length(v) - 2); out = ""
    for (i = 1; i <= length(v); i++) {
      ch = substr(v, i, 1)
      if (ch == "\\" && i < length(v)) { i++; ch = substr(v, i, 1); if (ch == "n") ch = "\n"; else if (ch == "t") ch = "\t" }
      out = out ch
    }
    return out
  }
  if (q == "&" || q == "*" || q == "!") YANCH = 1
  if (q == "[" || q == "{") YFLOW = 1
  if (q == "|" || q == ">") YBLOCK = 1
  return v
}
# Items of a one-line flow sequence; -1 when nested or malformed.
function flow_split(s, arr,   inner, i, n, ch, q, cur) {
  s = trim(s)
  if (substr(s, 1, 1) != "[" || substr(s, length(s)) != "]") return -1
  inner = substr(s, 2, length(s) - 2); n = 0; q = ""; cur = ""
  if (trim(inner) == "") return 0
  for (i = 1; i <= length(inner); i++) {
    ch = substr(inner, i, 1)
    if (q != "") { if (ch == q) q = ""; cur = cur ch; continue }
    if (ch == "\"" || ch == "\047") { q = ch; cur = cur ch; continue }
    if (ch == "[" || ch == "]" || ch == "{" || ch == "}") return -1
    if (ch == ",") { arr[++n] = trim(cur); cur = ""; continue }
    cur = cur ch
  }
  if (q != "") return -1
  if (trim(cur) != "") arr[++n] = trim(cur)
  return n
}
function relevant(p) { return p == "volumes" || p == "env_file" || p == "environment" || p == "secrets" || p == "configs" || p == "working_dir" }
function addsvc(s) { if (!(s in SVCIDX)) { SVCIDX[s] = ++SVCN; SVC[SVCN] = s } }
# Later compose files override environment entries and mounts (by target).
function setenv(s, k, raw, has) {
  if (!((s SUBSEP k) in ENVH)) ENVK[s, ++ENVKN[s]] = k
  ENVR[s, k] = raw; ENVH[s, k] = has
  if ((s SUBSEP k) in ENVBLK) delete ENVBLK[s, k]
}
function addmount(s, kind, src, tgt, u,   i) {
  if (tgt == "") return
  if ((s SUBSEP tgt) in MIDX) i = MIDX[s, tgt]
  else { i = ++MNN[s]; MIDX[s, tgt] = i }
  MK[s, i] = kind; MS[s, i] = src; MT[s, i] = tgt; MU[s, i] = u
}
function addshort(s, spec,   p, n, u) {
  UNRES = 0; spec = interp(spec); u = UNRES
  n = split(spec, p, ":")
  if (n < 2) return
  addmount(s, (p[1] ~ /^(\.|\/|~)/) ? "bind" : "volume", p[1], p[2], u)
}
function addef(s, path, req) { EFP[s, ++EFN[s]] = path; EFQ[s, EFN[s]] = req }
function addsec(s, sec, name, tgt) { SRS[s, ++SRN[s]] = sec; SRM[s, SRN[s]] = name; SRT[s, SRN[s]] = tgt }
function scalaritem(s, p, v,   eq) {
  if (p == "volumes") addshort(s, v)
  else if (p == "env_file") addef(s, v, 1)
  else if (p == "secrets" || p == "configs") addsec(s, p, v, "")
  else if (p == "environment") { eq = index(v, "="); if (eq > 1) setenv(s, substr(v, 1, eq - 1), substr(v, eq + 1), 1); else setenv(s, v, "", 0) }
}
# Long-syntax list item (volumes, env_file, secrets, configs).
function flushitem(   type, src, tgt, u) {
  if (itemkind == "map" && svc != "") {
    if (prop == "volumes") {
      UNRES = 0; type = interp(IT["type"]); src = interp(IT["source"]); tgt = interp(IT["target"]); u = UNRES
      if (type == "") type = (src ~ /^(\.|\/|~)/) ? "bind" : "volume"
      if (type == "bind" || type == "volume") addmount(svc, type, src, tgt, u)
    } else if (prop == "env_file") {
      if (IT["path"] == "") serr(svc, "env_file bez path"); else addef(svc, IT["path"], IT["required"] != "false")
    } else if (prop == "secrets" || prop == "configs") addsec(svc, prop, IT["source"], IT["target"])
  }
  itemkind = ""; delete IT
}
function top(c) {
  flushitem()
  section = ""; svc = ""; svcind = -1; propind = -1; prop = ""; subind = -1; defind = -1; def = ""; inopts = 0
  if (!splitkv(c)) { gerr("nieobsługiwana składnia YAML najwyższego poziomu"); return }
  section = KK
  yscalar(KV)
  if (section == "include" || section == "<<") { gerr("dyrektywa " section " (nieobsługiwana)"); section = ""; return }
  if (KV != "" && (section == "services" || section == "volumes" || section == "secrets" || section == "configs")) {
    if (KV !~ /^\{[ \t]*\}$/) gerr("nieobsługiwana wartość sekcji " section)
    section = ""
  }
}
function svcline(ind, c,   v, isitem, body, n, arr, i) {
  if (svcind < 0) svcind = ind
  if (ind <= svcind || ind <= propind || (subind >= 0 && ind <= subind)) flushitem()
  if (ind < svcind) { gerr("nieprawidłowe wcięcie w services"); svc = ""; return }
  if (ind == svcind) {
    prop = ""; propind = -1; subind = -1
    if (c ~ /^-/ || !splitkv(c)) { gerr("nieobsługiwana składnia services"); svc = ""; return }
    svc = KK; addsvc(svc)
    yscalar(KV)
    if (KV != "" && KV !~ /^\{[ \t]*\}$/) serr(svc, YANCH ? "kotwica/alias YAML w definicji usługi" : "nieobsługiwana definicja usługi")
    return
  }
  if (svc == "") return
  if (propind < 0) propind = ind
  if (ind < propind) { serr(svc, "nieprawidłowe wcięcie"); prop = ""; return }
  if (ind == propind) {
    subind = -1; prop = ""
    if (c ~ /^-/ || !splitkv(c)) { serr(svc, "nieobsługiwana składnia YAML"); return }
    prop = KK
    if (prop == "<<") { serr(svc, "scalanie YAML (<<)"); prop = ""; return }
    if (prop == "extends") { serr(svc, "extends (nieobsługiwane)"); prop = ""; return }
    v = yscalar(KV)
    if (YBLOCK) { skipind = ind; if (relevant(prop)) serr(svc, "blok tekstowy YAML w " prop); prop = ""; return }
    if (YANCH) { if (relevant(prop)) serr(svc, "kotwica/alias YAML w " prop); prop = ""; return }
    if (prop == "profiles") PROF[svc] = 1
    if (prop == "working_dir") { if (YBAD) serr(svc, "nieobsługiwana wartość working_dir"); else WD[svc] = v; prop = ""; return }
    if (!relevant(prop)) { prop = ""; return }
    if (KV == "") return
    if (YFLOW) {
      n = flow_split(KV, arr)
      if (n < 0) { serr(svc, "nieobsługiwana składnia flow YAML w " prop); prop = ""; return }
      for (i = 1; i <= n; i++) {
        v = yscalar(arr[i])
        if (YANCH || YFLOW || YBLOCK || YBAD) { serr(svc, "nieobsługiwany element " prop); continue }
        scalaritem(svc, prop, v)
      }
      prop = ""; return
    }
    if (prop == "env_file" && !YBAD) { addef(svc, v, 1); prop = ""; return }
    serr(svc, "nieobsługiwana wartość " prop); prop = ""; return
  }
  if (prop == "") return
  if (subind < 0) subind = ind
  if (ind < subind) { serr(svc, "nieprawidłowe wcięcie w " prop); return }
  isitem = (c ~ /^-([ \t]|$)/)
  if (ind == subind) {
    if (prop == "environment" && !isitem) {
      if (!splitkv(c)) { serr(svc, "nieobsługiwany wpis environment"); return }
      v = yscalar(KV)
      if (YANCH || YFLOW || YBAD) { serr(svc, "nieobsługiwana wartość environment " KK); return }
      if (YBLOCK) { skipind = ind; setenv(svc, KK, "", 0); ENVBLK[svc, KK] = 1; return }
      setenv(svc, KK, v, KV != "")
      return
    }
    if (!isitem) { serr(svc, "oczekiwano listy w " prop); return }
    match(c, /^-[ \t]*/); itemfield = ind + RLENGTH
    body = trim(substr(c, RLENGTH + 1))
    if (body == "") { serr(svc, "nieobsługiwany element listy w " prop); return }
    if (prop != "environment" && splitkv(body) && KK ~ /^[a-z_]+$/) {
      itemkind = "map"; v = yscalar(KV)
      if (YANCH || YFLOW || YBLOCK || YBAD) serr(svc, "nieobsługiwany element " prop); else IT[KK] = v
      return
    }
    v = yscalar(body)
    if (YANCH || YFLOW || YBLOCK || YBAD) { serr(svc, "nieobsługiwany element " prop); return }
    scalaritem(svc, prop, v)
    return
  }
  if (itemkind == "map" && ind == itemfield && !isitem && splitkv(c)) {
    v = yscalar(KV)
    if (YBLOCK) { skipind = ind; return }
    if (YANCH || YBAD) { serr(svc, "nieobsługiwany element " prop); return }
    if (KV != "" && !YFLOW) IT[KK] = v
    return
  }
  # Nested maps of a long-syntax item (bind:, volume:) are irrelevant; any
  # other deeper line is a multi-line scalar or unknown structure.
  if (itemkind == "map" && ind > itemfield) return
  serr(svc, "nieobsługiwana składnia YAML (wartość wieloliniowa) w " prop)
}
# Top-level named volumes: a bind device (driver_opts o: bind, device: ...).
function volline(ind, c,   v) {
  if (defind < 0) defind = ind
  if (ind == defind) { def = splitkv(c) ? KK : ""; inopts = 0; return }
  if (def == "" || !splitkv(c)) return
  if (inopts && ind <= optind) inopts = 0
  if (KK == "driver_opts" && KV == "") { inopts = 1; optind = ind; return }
  if (inopts) {
    v = yscalar(KV)
    if (YANCH || YBLOCK || YFLOW) VOLBAD[def] = 1
    else if (KK == "device") VOLDEV[def] = v
    else if (KK == "o") VOLO[def] = v
  }
}
# Top-level secrets/configs with a file.
function secline(ind, c,   v) {
  if (defind < 0) defind = ind
  if (ind == defind) { def = splitkv(c) ? KK : ""; return }
  if (def != "" && splitkv(c) && KK == "file") {
    v = yscalar(KV)
    if (YANCH || YBLOCK || YFLOW) SECBAD[section, def] = 1; else SECFILE[section, def] = v
  }
}
function parse_file(path,   line, r, ind, c, bytes, seen) {
  section = ""; svc = ""; skipind = -1; itemkind = ""; bytes = 0; seen = 0
  svcind = -1; propind = -1; subind = -1; prop = ""
  r = (getline line < (fsroot path))
  if (r < 0) { gerr("nie można odczytać pliku Compose " path); return }
  while (r > 0) {
    bytes += length(line) + 1
    if (bytes > maxbytes) { gerr("plik Compose jest zbyt duży: " path); break }
    sub(/\r$/, "", line)
    if (line !~ /^[ \t]*(#|$)/) {
      match(line, /^ */); ind = RLENGTH
      if (substr(line, ind + 1, 1) == "\t") { gerr("tabulator we wcięciu YAML: " path); break }
      if (skipind >= 0 && ind > skipind) { r = (getline line < (fsroot path)); continue }
      skipind = -1
      if (line ~ /^(---|\.\.\.)([ \t]|$)/) {
        if (seen) { gerr("kilka dokumentów YAML w pliku: " path); break }
      } else {
        c = stripc(substr(line, ind + 1))
        if (c != "") {
          seen = 1
          if (ind == 0) top(c)
          else if (section == "services") svcline(ind, c)
          else if (section == "volumes") volline(ind, c)
          else if (section == "secrets" || section == "configs") secline(ind, c)
        }
      }
    }
    r = (getline line < (fsroot path))
  }
  flushitem()
  close(fsroot path)
}
# Environment of service s inside its container (env_file, then
# environment) -> CE (value), CES (source), CEU (unresolved), CEK (order).
function buildenv(s,   i, p, rc, k, raw, v, src) {
  delete CE; delete CES; delete CEU; delete CEK; CEN = 0
  for (i = 1; i <= EFN[s]; i++) {
    UNRES = 0; p = interp(EFP[s, i])
    if (UNRES || p == "") { serr(s, "nierozwiązana zmienna w ścieżce env_file"); continue }
    if (p ~ /^~/) { serr(s, "env_file względem katalogu domowego (~)"); continue }
    p = normpath(projdir, p)
    if (!safepath(p)) { serr(s, "ścieżka env_file zawiera nieobsługiwane znaki"); continue }
    CURSRC = "env_file " p
    rc = kvfile(p, "cont")
    if (rc == -2) serr(s, "env_file jest zbyt duży: " p)
    else if (rc == -1 && EFQ[s, i]) serr(s, "brak wymaganego env_file: " p)
    rec("ENVFILE", s, p, rc >= 0 ? "used" : "absent")
  }
  for (i = 1; i <= ENVKN[s]; i++) {
    k = ENVK[s, i]; raw = ENVR[s, k]; UNRES = 0
    if ((s SUBSEP k) in ENVBLK) { setce(k, "", "environment", 1); continue }
    if (ENVH[s, k]) v = interp(raw)
    else if (k in ENVV) v = ENVV[k]
    else continue
    src = "environment"
    if (raw ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) { p = raw; gsub(/[${}]/, "", p); src = "environment <- " p }
    else if (!ENVH[s, k]) src = "environment <- " k
    setce(k, v, src, UNRES)
  }
}
function resolve(s,   i, nm, HM, TM, kind, src, tgt, host, dv, n, p, k, v, best, bl, rc, raw, wd) {
  rec("SVC", s, (s in PROF) ? "profiles" : "")
  nm = 0
  for (i = 1; i <= MNN[s]; i++) {
    kind = MK[s, i]; src = MS[s, i]; tgt = MT[s, i]
    # An unknown mount may hide the certificate: ambiguous, not a warning.
    if (MU[s, i]) { serr(s, "nierozwiązana zmienna w wolumenie" (safepath(tgt) ? " (cel " tgt ")" : "")); continue }
    if (kind == "bind") {
      if (src ~ /^~/) { serr(s, "wolumen względem katalogu domowego (~)"); continue }
      host = normpath(projdir, src)
    } else {
      if (src in VOLBAD) { serr(s, "nieobsługiwana definicja wolumenu " src); continue }
      if (!(src in VOLDEV) || VOLO[src] !~ /(^|,)r?bind(,|$)/) continue
      UNRES = 0; dv = interp(VOLDEV[src])
      if (UNRES) { serr(s, "nierozwiązana zmienna w wolumenie " src); continue }
      host = normpath(projdir, dv); kind = "volume:" src
    }
    if (tgt !~ /^\//) { serr(s, "cel wolumenu nie jest ścieżką bezwzględną"); continue }
    tgt = normpath("/", tgt)
    if (!safepath(host) || !safepath(tgt)) { serr(s, "ścieżka wolumenu zawiera nieobsługiwane znaki"); continue }
    HM[++nm] = host; TM[nm] = tgt
    rec("MOUNT", s, host, tgt, kind)
  }
  for (i = 1; i <= SRN[s]; i++) {
    kind = SRS[s, i]; src = SRM[s, i]; tgt = SRT[s, i]
    if ((kind SUBSEP src) in SECBAD) { serr(s, "nieobsługiwana definicja " kind " " src); continue }
    if (!((kind SUBSEP src) in SECFILE)) continue
    UNRES = 0; host = interp(SECFILE[kind, src])
    if (UNRES) { serr(s, "nierozwiązana zmienna w " kind " " src); continue }
    host = normpath(projdir, host)
    if (tgt == "") tgt = (kind == "secrets") ? "/run/secrets/" src : "/" src
    else if (tgt !~ /^\//) tgt = (kind == "secrets") ? "/run/secrets/" tgt : "/" tgt
    tgt = normpath("/", tgt)
    if (!safepath(host) || !safepath(tgt)) { serr(s, "ścieżka " kind " zawiera nieobsługiwane znaki"); continue }
    HM[++nm] = host; TM[nm] = tgt
    rec("MOUNT", s, host, tgt, kind)
  }
  buildenv(s)
  for (i = 1; i <= nm; i++) {
    if (certext(HM[i]) || certext(TM[i])) rec("REF", s, HM[i], TM[i], "mount")
    else rec("DIR", s, HM[i], TM[i])
  }
  UNRES = 0; wd = interp(WD[s])
  if (WD[s] == "" || UNRES || wd !~ /^\//) wd = ""
  for (i = 1; i <= CEN; i++) {
    k = CEK[i]
    if (secretkey(k)) {
      if (!passkey(k)) continue
      # NAME_FILE: the password is read from that file (container path),
      # reported as its host path.
      if (toupper(k) !~ /_FILE$/) { rec("PW", s, k, CES[k], ""); continue }
      p = CE[k]
      if (CEU[k] || !safepath(p) || substr(p, 1, 1) != "/") { rec("PW", s, k, CES[k], "file:"); continue }
      p = normpath("/", p); best = 0; bl = -1
      for (n = 1; n <= nm; n++) {
        if (p == TM[n] || index(p, TM[n] "/") == 1 || TM[n] == "/") {
          if (length(TM[n]) > bl) { best = n; bl = length(TM[n]) }
        }
      }
      host = !best ? "" : (p == TM[best]) ? HM[best] : normpath("/", HM[best] "/" substr(p, length(TM[best]) + 1))
      rec("PW", s, k, CES[k], "file:" host)
      continue
    }
    v = CE[k]
    p = v; sub(/^file:\/\//, "", p); sub(/^file:/, "", p)
    if (!certref(k, p)) continue
    if (CEU[k]) { serr(s, "nierozwiązana zmienna w " k); continue }
    # Values leave the parser only as plain paths: anything else (options,
    # URLs, embedded passwords) is reported by the variable name alone.
    if (!safepath(p)) { serr(s, "zmienna " k " wskazuje certyfikat lub magazyn w nieobsługiwanej postaci"); continue }
    if (substr(p, 1, 1) != "/") {
      if (wd == "") { rec("UNMAPPED", s, k, p, "relative"); continue }
      p = normpath(wd, p)
    } else p = normpath("/", p)
    best = 0; bl = -1
    for (n = 1; n <= nm; n++) {
      if (p == TM[n] || index(p, TM[n] "/") == 1 || TM[n] == "/") {
        if (length(TM[n]) > bl) { best = n; bl = length(TM[n]) }
      }
    }
    if (!best) { rec("UNMAPPED", s, k, p, "image"); continue }
    host = (p == TM[best]) ? HM[best] : normpath("/", HM[best] "/" substr(p, length(TM[best]) + 1))
    rec("REF", s, host, p, "env:" k)
  }
}
BEGIN {
  SEP = "\034"
  # value mode prints nothing but the one value asked for.
  QUIET = (mode == "value")
  while ((getline line < "/dev/stdin") > 0) {
    if (substr(line, 1, 2) == "E ") unit_env(substr(line, 3))
    else if (substr(line, 1, 2) == "F ") {
      p = substr(line, 3); opt = 0
      if (substr(p, 1, 1) == "-") { opt = 1; p = substr(p, 2) }
      if (kvfile(p, "shell") == -1 && !opt) gerr("nie można odczytać EnvironmentFile " p)
    } else if (substr(line, 1, 2) == "S ") {
      eq = index(line, "=")
      if (eq > 3) SH[substr(line, 3, eq - 3)] = substr(line, eq + 1)
    }
  }
  for (k in SH) ENVV[k] = SH[k]
  if (envfile != "") {
    rc = kvfile(envfile, "dotenv")
    if (rc == -2) gerr("plik zmiennych jest zbyt duży: " envfile)
    else if (rc == -1 && envexplicit == 1) gerr("brak pliku --env-file " envfile)
    rec("DOTENV", envfile, rc >= 0 ? "used" : "absent")
  }
  if (mode == "env") {
    if ("COMPOSE_FILE" in ENVV) rec("CF", ENVV["COMPOSE_FILE"])
    if ("COMPOSE_PATH_SEPARATOR" in ENVV) rec("CS", ENVV["COMPOSE_PATH_SEPARATOR"])
    if ("COMPOSE_PROFILES" in ENVV) rec("CP", ENVV["COMPOSE_PROFILES"])
    exit 0
  }
  nf = split(files, F, "\n")
  for (i = 1; i <= nf; i++) if (F[i] != "") { rec("FILE", F[i]); parse_file(F[i]) }
  if (mode == "value") {
    # Only the one value asked for, on stdout (never inside a record).
    if (!(qsvc in SVCIDX)) exit 3
    buildenv(qsvc)
    if (!(qvar in CE) || CEU[qvar]) exit 3
    printf "%s", CE[qvar]
    exit 0
  }
  for (i = 1; i <= SVCN; i++) resolve(SVC[i])
}'

# Compose file docker compose picks in a directory when no file is given:
# exactly one of compose.yaml, compose.yml, docker-compose.yaml,
# docker-compose.yml (several would make v1 and v2 disagree, so this is
# ambiguous), followed by the override file when one exists.  Prints the
# files (newline separated) or, on failure, the reason.
ez_dc_default_files() {
  local prefix="$1" dir="$2" name found="" count=0 over="" ocount=0

  for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$prefix$dir/$name" ]; then
      found="$dir/$name"
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 0 ]; then
    printf 'brak pliku Compose w %s' "$dir"
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    printf 'kilka domyślnych plików Compose w %s (niejednoznaczne)' "$dir"
    return 1
  fi
  for name in compose.override.yaml compose.override.yml docker-compose.override.yaml docker-compose.override.yml; do
    if [ -f "$prefix$dir/$name" ]; then
      over="$dir/$name"
      ocount=$((ocount + 1))
    fi
  done
  if [ "$ocount" -gt 1 ]; then
    printf 'kilka plików override Compose w %s (niejednoznaczne)' "$dir"
    return 1
  fi
  printf '%s' "$found"
  [ -z "$over" ] || printf '\n%s' "$over"
}

# ez_dc_project <fs-prefix> <env-input>: completes the DCI_* invocation (set
# by ez_dc_invocation, or by the caller for a project without a unit) with
# the configuration docker compose would use:
#   DCP_FILES     compose files (absolute, newline separated, in order),
#   DCP_PROJDIR   project directory,
#   DCP_ENVFILE   .env or --env-file used for interpolation,
#   DCP_PROFILES  active profiles (--profile, else COMPOSE_PROFILES),
#   DCP_ERR       why the configuration is ambiguous (empty: OK).
# COMPOSE_FILE (process environment, then .env) is used when no -f is given.
ez_dc_project() {
  local prefix="$1" input="$2" base explicit=0 cf="" cs=":" t a b c d file files="" reason

  DCP_FILES=""; DCP_PROJDIR=""; DCP_ENVFILE=""; DCP_PROFILES="$DCI_PROFILES"; DCP_ERR="$DCI_ERR"
  if [ -n "$DCI_FILES" ]; then
    base="${DCI_PROJDIR:-$(dirname -- "$(printf '%s\n' "$DCI_FILES" | head -n 1)")}"
  else
    base="${DCI_PROJDIR:-$DCI_CWD}"
  fi
  DCP_ENVFILE="${DCI_ENVFILE:-$base/.env}"
  [ -z "$DCI_ENVFILE" ] || explicit=1
  while IFS="$(printf '\034')" read -r t a b c d; do
    case "$t" in
      CF) cf="$a" ;;
      CS) cs="$a" ;;
      CP) [ -n "$DCP_PROFILES" ] || DCP_PROFILES="$(printf '%s' "$a" | tr ',' ' ')" ;;
    esac
  done <<EOF
$(printf '%s\n' "$input" | LC_ALL=C awk -v mode=env -v fsroot="$prefix" -v envfile="$DCP_ENVFILE" \
    -v envexplicit="$explicit" -v maxbytes="$EZ_DC_MAX_CONFIG_BYTES" "$EZ_DC_AWK" 2>/dev/null)
EOF
  if [ -n "$DCI_FILES" ]; then
    files="$DCI_FILES"
  elif [ -n "$cf" ]; then
    [ -n "$cs" ] || cs=":"
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      case "$file" in
        '~'*) DCP_ERR="${DCP_ERR:-COMPOSE_FILE względem katalogu domowego}"; continue ;;
      esac
      file="$(ez_dc_normpath "$base" "$file")"
      ez_dc_path_ok "$file" || { DCP_ERR="${DCP_ERR:-COMPOSE_FILE zawiera nieobsługiwane znaki}"; continue; }
      files="${files:+$files
}$file"
    done <<EOF
$(printf '%s\n' "$cf" | awk -v sep="$cs" '{ n = split($0, p, sep); for (i = 1; i <= n; i++) print p[i] }')
EOF
  elif files="$(ez_dc_default_files "$prefix" "$base")"; then
    :
  else
    reason="$files"
    files=""
    DCP_ERR="${DCP_ERR:-$reason}"
  fi
  DCP_FILES="$files"
  if [ -n "$DCI_PROJDIR" ]; then
    DCP_PROJDIR="$DCI_PROJDIR"
  elif [ -n "$files" ]; then
    DCP_PROJDIR="$(dirname -- "$(printf '%s\n' "$files" | head -n 1)")"
  else
    DCP_PROJDIR="$base"
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ ! -f "$prefix$file" ] || [ -L "$prefix$file" ]; then
      DCP_ERR="${DCP_ERR:-brak pliku Compose $file}"
    fi
  done <<EOF
$files
EOF
  return 0
}

# ez_dc_model <fs-prefix> <env-input>: records (fields separated by \034)
# of the compose configuration selected by ez_dc_project:
#   DOTENV <file> <used|absent>          FILE <compose file>
#   ERR - <reason>                       the project cannot be analysed
#   SVC <service> <profiles|>            SERR/SWARN <service> <reason>
#   MOUNT <service> <host> <target> <bind|volume:NAME|secrets|configs>
#   ENVFILE <service> <file> <used|absent>
#   REF <service> <host-path> <container-path> <mount|env:NAME>
#   DIR <service> <host-path> <container-path>   other mount
#   UNMAPPED <service> <NAME> <container-path> <image|relative>
#   PW <service> <NAME> <source> <|file:HOST>  password variable (name
#                                        only); NAME_FILE variables carry the
#                                        host path of the file (empty: unmapped)
ez_dc_model() {
  local prefix="$1" input="$2" explicit=0

  [ -z "$DCI_ENVFILE" ] || explicit=1
  printf '%s\n' "$input" | LC_ALL=C awk -v mode=model -v fsroot="$prefix" -v envfile="$DCP_ENVFILE" \
    -v envexplicit="$explicit" -v files="$DCP_FILES" -v projdir="$DCP_PROJDIR" \
    -v maxbytes="$EZ_DC_MAX_CONFIG_BYTES" "$EZ_DC_AWK"
}

# Content type of a certificate or keystore file, from its bytes (the name
# is irrelevant): JKS, JCEKS, PKCS12, DER, PEM or UNKNOWN.  PKCS12 is told
# apart from a DER certificate by its ASN.1 structure (PFX version 3); no
# password is needed.
ez_store_type() {
  local file="$1" magic

  [ -f "$file" ] && [ -r "$file" ] || { printf 'UNKNOWN'; return 1; }
  magic="$(LC_ALL=C od -An -tx1 -N4 -- "$file" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    feedfeed) printf 'JKS'; return 0 ;;
    cececece) printf 'JCEKS'; return 0 ;;
    30*)
      if LC_ALL=C openssl asn1parse -inform DER -in "$file" 2>/dev/null |
        awk 'NR == 2 { ok = ($0 ~ /d=1 .*prim: *INTEGER *:0*3[ \t]*$/) } END { exit !ok }'; then
        printf 'PKCS12'
      else
        printf 'DER'
      fi
      return 0
      ;;
  esac
  if LC_ALL=C grep -a -q -- '-----BEGIN ' "$file"; then
    printf 'PEM'
    return 0
  fi
  printf 'UNKNOWN'
  return 1
}

# ez_dc_secret <fs-prefix> <env-input> <envfile> <explicit> <files> <projdir>
#   <service> <NAME>
# Prints the value of variable NAME inside the container of <service> (same
# rules as ez_dc_model) and nothing else; exit status 3 when it is not set or
# not resolvable.  The value only ever travels through this pipe: the caller
# captures it with $(...); it is never an argument, a record or a log line.
ez_dc_secret() {
  printf '%s\n' "$2" | LC_ALL=C awk -v mode=value -v fsroot="$1" -v envfile="$3" -v envexplicit="$4" \
    -v files="$5" -v projdir="$6" -v qsvc="$7" -v qvar="$8" \
    -v maxbytes="$EZ_DC_MAX_CONFIG_BYTES" "$EZ_DC_AWK" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Keystore inspection (read-only): JKS and PKCS12.
#
# The store password is taken from EZS_PASSWORD (a shell variable, never a
# function or program argument).  It reaches external programs only through
# a pipe on their standard input: "openssl pkcs12 -passin stdin" and, for
# the JKS integrity digest, "iconv" and "openssl dgst".  Nothing is written
# to disk and stores are never modified.
# ---------------------------------------------------------------------------

EZ_STORE_MAX_ENTRIES=500
EZ_STORE_PW_MAX=1024

# Reads "od -An -v -tu1" of a JKS file (version 1 or 2, the Java 8 format)
# and prints records separated by \034:
#   H <version> <entries> <body-bytes>
#   E <entry> <PrivateKeyEntry|trustedCertEntry> <alias>
#   C <entry> <position-in-chain> <offset>:<length>  followed by the
#                                   certificate as PEM lines; <offset> is the
#                                   0-based offset of its 4-byte length field
#   D <stored SHA-1 integrity digest, hex>
#   BAD <reason>                    malformed or unsupported (exit 1)
# Private key bytes are skipped, never decoded or printed.  Non-printable
# alias characters are replaced by "?".
EZ_JKS_AWK='
function rec(t, a, b, c) { print t SEP a SEP b SEP c }
function fail(m) { rec("BAD", m); exit 1 }
function need(n) { if (n < 0 || P + n - 1 > BODY) fail("niekompletny wpis (magazyn uszkodzony lub obcięty)") }
function u4(   v) { need(4); v = ((B[P] * 256 + B[P + 1]) * 256 + B[P + 2]) * 256 + B[P + 3]; P += 4; return v }
function u2(   v) { need(2); v = B[P] * 256 + B[P + 1]; P += 2; return v }
function utf(   n, i, c, s) {
  n = u2(); need(n); s = ""
  for (i = 0; i < n; i++) { c = B[P + i]; s = s ((c >= 32 && c < 127) ? sprintf("%c", c) : "?") }
  P += n
  return s
}
function pem(p, n,   i, x, y, z, v, line) {
  print "-----BEGIN CERTIFICATE-----"; line = ""
  for (i = 0; i < n; i += 3) {
    x = B[p + i]; y = (i + 1 < n) ? B[p + i + 1] : 0; z = (i + 2 < n) ? B[p + i + 2] : 0
    v = (x * 256 + y) * 256 + z
    line = line substr(A64, int(v / 262144) % 64 + 1, 1) substr(A64, int(v / 4096) % 64 + 1, 1)
    line = line ((i + 1 < n) ? substr(A64, int(v / 64) % 64 + 1, 1) : "=") ((i + 2 < n) ? substr(A64, v % 64 + 1, 1) : "=")
    if (length(line) == 64) { print line; line = "" }
  }
  if (line != "") print line
  print "-----END CERTIFICATE-----"
}
function cert(e, pos,   t, n) {
  if (VER == 2) { t = utf(); if (t != "X.509") fail("nieobsługiwany typ certyfikatu " t) }
  n = u4(); if (n < 1) fail("pusty certyfikat we wpisie " e)
  need(n); rec("C", e, pos, (P - 5) ":" n); pem(P, n); P += n
}
BEGIN { SEP = "\034"; A64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
{ for (i = 1; i <= NF; i++) B[++N] = $i + 0 }
END {
  if (N < 32 || B[1] != 254 || B[2] != 237 || B[3] != 254 || B[4] != 237) fail("brak nagłówka JKS")
  BODY = N - 20; P = 5
  VER = u4(); if (VER != 1 && VER != 2) fail("nieobsługiwana wersja JKS " VER)
  cnt = u4(); if (cnt > maxent) fail("magazyn zawiera więcej niż " maxent " wpisów")
  rec("H", VER, cnt, BODY)
  for (e = 1; e <= cnt; e++) {
    tag = u4(); alias = utf(); need(8); P += 8
    if (tag == 1) {
      n = u4(); need(n); P += n
      nc = u4(); if (nc < 1 || nc > maxchain) fail("niepoprawna długość łańcucha we wpisie " alias)
      rec("E", e, "PrivateKeyEntry", alias)
      for (c = 1; c <= nc; c++) cert(e, c)
    } else if (tag == 2) {
      rec("E", e, "trustedCertEntry", alias)
      cert(e, 1)
    } else fail("nieobsługiwany typ wpisu " tag " (" alias ")")
  }
  if (P != BODY + 1) fail("dane po ostatnim wpisie (magazyn uszkodzony)")
  d = ""
  for (i = BODY + 1; i <= N; i++) d = d sprintf("%02x", B[i])
  rec("D", d)
}'

# Reads "openssl pkcs12 -nokeys" output and prints, for every certificate
# bag, "C <kind> <alias> <localKeyID>" (\034 separated) followed by its PEM
# lines.  kind: PrivateKeyEntry (localKeyID: the certificate of a key entry),
# trustedCertEntry (Oracle trusted attribute) or chain (neither: a chain
# certificate, which Java does not list as an entry).  The Oracle trusted
# attribute is printed as its OID by OpenSSL 1.0.x/1.1.x, by name by 3.x.
EZ_P12_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
BEGIN { SEP = "\034" }
/^Bag Attributes/ { fn = ""; kid = ""; tr = 0; next }
/^[ \t]+friendlyName:/ { fn = $0; sub(/^[ \t]+friendlyName:/, "", fn); fn = trim(fn); next }
/^[ \t]+localKeyID:/ { kid = $0; sub(/^[ \t]+localKeyID:/, "", kid); kid = trim(kid); gsub(/ /, "", kid); next }
/2\.16\.840\.1\.113894\.746875\.1\.1|Trusted key usage \(Oracle\)|oracle-jdk-trustedkeyusage/ { tr = 1; next }
/^-----BEGIN CERTIFICATE-----/ {
  print "C" SEP (kid != "" ? "PrivateKeyEntry" : tr ? "trustedCertEntry" : "chain") SEP fn SEP kid
  inb = 1
}
inb { print trim($0) }
/^-----END CERTIFICATE-----/ { inb = 0; fn = ""; kid = ""; tr = 0 }'

ez_store_reset_rows() {
  ES_COUNT=0; ES_ALIAS=(); ES_KIND=(); ES_ENTRY=(); ES_POS=(); ES_FP=(); ES_SUBJECT=(); ES_NOT_AFTER=()
  ES_NAMES=(); ES_ID=(); ES_NONPROD=(); ES_CA=(); ES_SELF=(); ES_OK=(); ES_OFF=(); ES_LEN=()
}

ez_store_reset() {
  EZS_STATUS=""; EZS_REASON=""; EZS_FORMAT=""; EZS_ENTRIES=0; EZS_KEYS=0; EZS_NOTE=""; EZS_P12_INFO=""
  EZS_P1=""; EZS_P1_WHY=""; EZS_P1_ROW=""
  ez_store_reset_rows
}

# Certificate given as PEM text (one CERTIFICATE block) -> EZX_* (same
# meaning as the EZC_* values of ez_cert_inspect_file).  Works on a pipe,
# without a temporary file.
ez_x509_pem_info() {
  local pem="$1" data text san name names="" rc

  EZX_FP=""; EZX_SUBJECT=""; EZX_ISSUER=""; EZX_NOT_AFTER=""; EZX_CN=""; EZX_NAMES=""
  EZX_HAS_DNS_SAN=no; EZX_IS_CA=no; EZX_SELF_SIGNED=no
  data="$(printf '%s\n' "$pem" | LC_ALL=C openssl x509 -noout -fingerprint -sha256 -subject -issuer -enddate 2>/dev/null)" || return 1
  EZX_FP="$(printf '%s\n' "$data" | awk -F= '{ field=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", field); if (tolower(field) == "sha256 fingerprint") { print toupper($2); exit } }')"
  EZX_SUBJECT="$(printf '%s\n' "$data" | sed -n 's/^subject= *//p' | head -n 1)"
  EZX_ISSUER="$(printf '%s\n' "$data" | sed -n 's/^issuer= *//p' | head -n 1)"
  EZX_NOT_AFTER="$(printf '%s\n' "$data" | sed -n 's/^notAfter=//p' | head -n 1)"
  ez_fp_ok "$EZX_FP" && [ -n "$EZX_SUBJECT" ] && [ -n "$EZX_NOT_AFTER" ] || return 1
  EZX_CN="$(printf '%s\n' "$pem" | LC_ALL=C openssl x509 -noout -subject -nameopt multiline 2>/dev/null |
    awk '/^[[:space:]]+commonName[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }')"
  EZX_CN="$(ez_lower "$EZX_CN")"
  text="$(printf '%s\n' "$pem" | LC_ALL=C openssl x509 -noout -text 2>/dev/null)" || return 1
  san="$(printf '%s\n' "$text" | ez_x509_text_san_dns)"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  ! printf '%s\n' "$text" | grep -q 'CA:TRUE' || EZX_IS_CA=yes
  [ "$EZX_SUBJECT" != "$EZX_ISSUER" ] || EZX_SELF_SIGNED=yes
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    EZX_HAS_DNS_SAN=yes
    ez_dns_name_syntax_ok "$name" || continue
    ez_names_contain "$names" "$name" || names="${names:+$names }$name"
  done <<EOF
$san
EOF
  if [ "$EZX_HAS_DNS_SAN" = yes ]; then
    EZX_NAMES="$names"
  elif ez_dns_name_syntax_ok "$EZX_CN"; then
    EZX_NAMES="$EZX_CN"
  fi
  return 0
}

# ez_store_row <alias> <kind> <entry> <position> <pem>: one certificate of
# the store -> ES_*.  ES_ID is its ezdrowie.gov.pl identity (empty: none).
ez_store_row() {
  local i="$ES_COUNT" id=""

  ES_ALIAS[$i]="$1"; ES_KIND[$i]="$2"; ES_ENTRY[$i]="$3"; ES_POS[$i]="$4"
  ES_FP[$i]=""; ES_SUBJECT[$i]=""; ES_NOT_AFTER[$i]=""; ES_NAMES[$i]=""; ES_ID[$i]=""
  ES_NONPROD[$i]=no; ES_CA[$i]=no; ES_SELF[$i]=no; ES_OK[$i]=no
  ES_COUNT=$((ES_COUNT + 1))
  ez_x509_pem_info "$5" || return 0
  ES_OK[$i]=yes; ES_FP[$i]="$EZX_FP"; ES_SUBJECT[$i]="$EZX_SUBJECT"; ES_NOT_AFTER[$i]="$EZX_NOT_AFTER"
  ES_NAMES[$i]="$EZX_NAMES"; ES_CA[$i]="$EZX_IS_CA"; ES_SELF[$i]="$EZX_SELF_SIGNED"
  if id="$(ez_primary_identity "$EZX_CN" "$EZX_NAMES")"; then
    ES_ID[$i]="$id"
    ! ez_is_nonprod_name "$id" || ES_NONPROD[$i]=yes
  fi
}

# Splits one \034 separated record into EZR_T EZR_A EZR_B EZR_C.
ez_store_fields() {
  local s rest
  s="$(printf '\034')"
  EZR_T="${1%%"$s"*}"; rest="${1#*"$s"}"
  EZR_A="${rest%%"$s"*}"; rest="${rest#*"$s"}"
  EZR_B="${rest%%"$s"*}"; EZR_C="${rest#*"$s"}"
}

# Parses a JKS file (structure only, no password needed) into ES_* and
# EZS_FORMAT/EZS_ENTRIES/EZS_KEYS; EZS_JKS_BODY and EZS_JKS_DIGEST keep what
# ez_jks_verify needs.  Returns 1 with EZS_STATUS/EZS_REASON when the file
# is malformed or unsupported.
ez_jks_read() {
  local file="$1" line entry="" kind="" alias="" pos="" span="" pem="" inpem=0 bad=""

  EZS_JKS_BODY=""; EZS_JKS_DIGEST=""
  while IFS= read -r line; do
    if [ "$inpem" -eq 1 ]; then
      pem="$pem$line
"
      if [ "$line" = '-----END CERTIFICATE-----' ]; then
        inpem=0
        ez_store_row "$alias" "$kind" "$entry" "$pos" "$pem"
        ES_OFF[$((ES_COUNT - 1))]="${span%%:*}"; ES_LEN[$((ES_COUNT - 1))]="${span#*:}"
      fi
      continue
    fi
    ez_store_fields "$line"
    case "$EZR_T" in
      H) EZS_FORMAT="JKS v$EZR_A"; EZS_ENTRIES="$EZR_B"; EZS_JKS_BODY="$EZR_C" ;;
      E)
        entry="$EZR_A"; kind="$EZR_B"; alias="$EZR_C"
        [ "$kind" != PrivateKeyEntry ] || EZS_KEYS=$((EZS_KEYS + 1))
        ;;
      C) pos="$EZR_B"; span="$EZR_C"; pem=""; inpem=1 ;;
      D) EZS_JKS_DIGEST="$EZR_A" ;;
      BAD) bad="$EZR_A" ;;
    esac
  done <<EOF
$(LC_ALL=C od -An -v -tu1 -- "$file" 2>/dev/null | LC_ALL=C awk -v maxent="$EZ_STORE_MAX_ENTRIES" \
    -v maxchain="$EZ_MAX_CHAIN_CERTS" "$EZ_JKS_AWK" 2>/dev/null)
EOF
  if [ -n "$bad" ] || [ -z "$EZS_JKS_BODY" ] || [ "${#EZS_JKS_DIGEST}" -ne 40 ]; then
    case "$bad" in
      *nieobsługiwan*) EZS_STATUS=NIEOBSLUGIWANY ;;
      *) EZS_STATUS=USZKODZONY ;;
    esac
    EZS_REASON="${bad:-niepoprawna struktura JKS}"
    return 1
  fi
  return 0
}

# JKS integrity check with EZS_PASSWORD: SHA-1 over the password (UTF-16BE,
# as Java chars), the text "Mighty Aphrodite" and the store body must equal
# the stored digest.  A mismatch cannot tell a wrong password from changed
# bytes.  0 match, 1 mismatch, 2 the check cannot be run.
ez_jks_verify() {
  local file="$1" calc

  command -v iconv >/dev/null 2>&1 || return 2
  printf '%s' "$EZS_PASSWORD" | LC_ALL=C iconv -f UTF-8 -t UTF-16BE >/dev/null 2>&1 || return 2
  calc="$( { printf '%s' "$EZS_PASSWORD" | LC_ALL=C iconv -f UTF-8 -t UTF-16BE 2>/dev/null; \
    printf 'Mighty Aphrodite'; head -c "$EZS_JKS_BODY" -- "$file"; } | openssl dgst -sha1 2>/dev/null | awk '{ print $NF }')"
  [ "${#calc}" -eq 40 ] || return 2
  [ "$calc" = "$EZS_JKS_DIGEST" ] || return 1
  return 0
}

# One "openssl pkcs12" run with EZS_PASSWORD on stdin.  $1: legacy (yes|no),
# then the openssl options.
ez_p12_run() {
  local legacy="$1"
  shift
  if [ "$legacy" = yes ]; then
    printf '%s\n' "$EZS_PASSWORD" | LC_ALL=C openssl pkcs12 -legacy -passin stdin "$@"
  else
    printf '%s\n' "$EZS_PASSWORD" | LC_ALL=C openssl pkcs12 -passin stdin "$@"
  fi
}

# Opens a PKCS12 file with EZS_PASSWORD into ES_*: MAC (password and
# integrity) check, then the certificate bags.  Older stores (Java 8:
# RC2-40/3DES) need the OpenSSL 3 legacy provider; OpenSSL 1.x reads them
# directly.  Sets EZS_STATUS (OK or the error) and EZS_REASON.
ez_p12_read() {
  local file="$1" legacy=no major info out rc kids="" nkids=0 line pem="" inpem=0 kind="" alias="" kid

  major="$(openssl version 2>/dev/null | awk '{ split($2, v, "."); print v[1] + 0; exit }')"
  rc=0
  info="$(ez_p12_run no -in "$file" -info -nocerts -nokeys 2>&1 >/dev/null)" || rc=$?
  # OpenSSL 3 without -legacy verifies the MAC (password), then cannot
  # decrypt RC2/3DES bags.
  if [ "$rc" -ne 0 ] && [ "${major:-0}" -ge 3 ]; then
    case "$info" in
      *'Mac verify error'*) ;;
      *[Uu]nsupported*) legacy=yes ;;
    esac
  fi
  if [ "$legacy" = yes ]; then
    rc=0
    info="$(ez_p12_run yes -in "$file" -info -nocerts -nokeys 2>&1 >/dev/null)" || rc=$?
    case "$rc:$info" in
      0:*) ;;
      *[Pp]rovider*)
        EZS_STATUS=NIEOBSLUGIWANY
        EZS_REASON='starszy format PKCS12 (np. Java 8: RC2/3DES) wymaga dostawcy "legacy" OpenSSL, którego brak'
        return 1
        ;;
    esac
  fi
  if [ "$rc" -ne 0 ]; then
    case "$info" in
      *'Mac verify error'*|*'invalid password'*)
        EZS_STATUS=HASLO_NIEPOPRAWNE
        EZS_REASON='hasło niepoprawne (weryfikacja MAC nie powiodła się)'
        ;;
      *)
        EZS_STATUS=USZKODZONY
        EZS_REASON='nie można odczytać zawartości PKCS12 (plik uszkodzony lub nieobsługiwany algorytm)'
        ;;
    esac
    return 1
  fi
  EZS_FORMAT=PKCS12
  EZS_P12_INFO="$info"
  [ "$legacy" = no ] || EZS_FORMAT='PKCS12 (starszy format, odczyt przez OpenSSL legacy)'
  EZS_KEYS="$(printf '%s\n' "$info" | awk '/^(Shrouded Keybag|Key bag)/ { n++ } END { print n + 0 }')"
  rc=0
  out="$(ez_p12_run "$legacy" -in "$file" -nokeys 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    EZS_STATUS=USZKODZONY
    EZS_REASON='nie można odczytać certyfikatów PKCS12'
    return 1
  fi
  EZS_ENTRIES=0
  while IFS= read -r line; do
    if [ "$inpem" -eq 1 ]; then
      pem="$pem$line
"
      if [ "$line" = '-----END CERTIFICATE-----' ]; then
        inpem=0
        if [ "$kind" = chain ]; then
          ez_store_row "$alias" chain 0 1 "$pem"
        else
          EZS_ENTRIES=$((EZS_ENTRIES + 1))
          ez_store_row "$alias" "$kind" "$EZS_ENTRIES" 1 "$pem"
        fi
      fi
      continue
    fi
    ez_store_fields "$line"
    [ "$EZR_T" = C ] || continue
    kind="$EZR_A"; alias="$EZR_B"; kid="$EZR_C"; pem=""; inpem=1
    if [ -n "$kid" ] && ! ez_names_contain "$kids" "$kid"; then
      kids="$kids $kid"
      nkids=$((nkids + 1))
    fi
  done <<EOF
$(printf '%s\n' "$out" | LC_ALL=C awk "$EZ_P12_AWK")
EOF
  [ "$nkids" -eq "$EZS_KEYS" ] ||
    EZS_NOTE="liczba kluczy prywatnych ($EZS_KEYS) różni się od liczby certyfikatów z localKeyID ($nkids)"
  if ! printf '%s\n' "$info" | awk '/^MAC/ { m = 1 } /MAC is absent/ { a = 1 } END { exit !(m && !a) }'; then
    EZS_STATUS=BRAK_INTEGRALNOSCI
    EZS_REASON='magazyn PKCS12 bez MAC - nie można potwierdzić hasła i integralności'
    return 1
  fi
  EZS_STATUS=OK
  return 0
}

# ez_store_open <file> <JKS|PKCS12> <have-password yes|no>
# Fills ES_* and EZS_*.  EZS_STATUS: OK (password correct, integrity
# verified), BRAK_HASLA (no password; JKS entries are still listed from the
# structure, unverified), HASLO_NIEPOPRAWNE, USZKODZONY, NIEOBSLUGIWANY or
# BRAK_INTEGRALNOSCI.  Returns 0 only for OK.
ez_store_open() {
  local file="$1" type="$2" have="$3" rc nl

  ez_store_reset
  nl='
'
  if [ "$have" = yes ]; then
    case "$EZS_PASSWORD" in
      *"$nl"*) EZS_STATUS=NIEOBSLUGIWANY; EZS_REASON='hasło zawiera znak nowej linii'; have=no ;;
    esac
    if [ "${#EZS_PASSWORD}" -gt "$EZ_STORE_PW_MAX" ]; then
      EZS_STATUS=NIEOBSLUGIWANY; EZS_REASON='hasło jest zbyt długie'; have=no
    fi
  fi
  case "$type" in
    JKS)
      if ! ez_jks_read "$file"; then
        ez_store_reset_rows
        return 1
      fi
      if [ "$have" != yes ]; then
        [ -n "$EZS_STATUS" ] || {
          EZS_STATUS=BRAK_HASLA
          EZS_REASON='brak hasła - wpisy odczytane ze struktury, integralność niezweryfikowana'
        }
        return 1
      fi
      rc=0
      ez_jks_verify "$file" || rc=$?
      case "$rc" in
        0) EZS_STATUS=OK ;;
        1) EZS_STATUS=HASLO_NIEPOPRAWNE; EZS_REASON='hasło niepoprawne lub magazyn zmieniony (suma kontrolna JKS niezgodna)' ;;
        *) EZS_STATUS=NIEOBSLUGIWANY; EZS_REASON='nie można obliczyć sumy kontrolnej JKS (brak iconv lub openssl, hasło nie w UTF-8)' ;;
      esac
      [ "$rc" -eq 0 ] || return 1
      ;;
    PKCS12)
      if [ "$have" != yes ]; then
        [ -n "$EZS_STATUS" ] || { EZS_STATUS=BRAK_HASLA; EZS_REASON='brak hasła - zawartość PKCS12 jest zaszyfrowana'; }
        return 1
      fi
      if ! ez_p12_read "$file"; then
        [ "$EZS_STATUS" = BRAK_INTEGRALNOSCI ] || ez_store_reset_rows
        return 1
      fi
      ;;
    *) EZS_STATUS=NIEOBSLUGIWANY; EZS_REASON="typ $type nie jest obsługiwany"; return 1 ;;
  esac
  return 0
}

# Identification of the P1 certificate (the production *.ezdrowie.gov.pl
# server certificate) among ES_*: a row with a production ezdrowie.gov.pl
# identity that is neither a CA nor self-signed, told apart by SHA-256.
#   EZS_P1  PEWNA      exactly one trustedCertEntry holds it (EZS_P1_ROW),
#           NIEPEWNA   several different ones, one certificate under several
#                      aliases, one outside any entry (PKCS12 chain bag) or
#                      a store not verified with its password,
#           CHRONIONY  only inside PrivateKeyEntry chains (never modified),
#           BRAK       none (EZS_P1_WHY may name non-production ones),
#           NIEZNANA   the content could not be read.
ez_store_p1() {
  local i trusted="" keyed="" chain="" fps="" nfps=0 ntrusted=0 aliases="" other=""

  EZS_P1=""; EZS_P1_WHY=""; EZS_P1_ROW=""
  if [ "$ES_COUNT" -eq 0 ] && [ "$EZS_STATUS" != OK ]; then
    EZS_P1=NIEZNANA
    EZS_P1_WHY='zawartość magazynu nie została odczytana'
    return 0
  fi
  i=0
  while [ "$i" -lt "$ES_COUNT" ]; do
    if [ -n "${ES_ID[$i]}" ]; then
      if [ "${ES_NONPROD[$i]}" = yes ] || [ "${ES_CA[$i]}" = yes ] || [ "${ES_SELF[$i]}" = yes ]; then
        other="${other:+$other, }${ES_ALIAS[$i]:-bez aliasu} (${ES_ID[$i]})"
      else
        case "${ES_KIND[$i]}" in
          trustedCertEntry)
            trusted="$trusted $i"
            ntrusted=$((ntrusted + 1))
            if ! ez_names_contain "$fps" "${ES_FP[$i]}"; then
              fps="$fps ${ES_FP[$i]}"
              nfps=$((nfps + 1))
            fi
            aliases="${aliases:+$aliases, }${ES_ALIAS[$i]}"
            ;;
          PrivateKeyEntry) keyed="$keyed $i" ;;
          *) chain="$chain $i" ;;
        esac
      fi
    fi
    i=$((i + 1))
  done
  if [ -n "$chain" ]; then
    EZS_P1=NIEPEWNA
    EZS_P1_WHY='certyfikat ezdrowie.gov.pl poza wpisem magazynu (certyfikat łańcucha PKCS12 bez atrybutu zaufania)'
  elif [ "$ntrusted" -eq 0 ] && [ -n "$keyed" ]; then
    EZS_P1=CHRONIONY
    EZS_P1_WHY='certyfikat ezdrowie.gov.pl tylko we wpisie z kluczem prywatnym - nie będzie modyfikowany'
  elif [ "$ntrusted" -eq 0 ]; then
    EZS_P1=BRAK
    [ -z "$other" ] || EZS_P1_WHY="tylko nieprodukcyjne, CA lub samopodpisane certyfikaty ezdrowie.gov.pl: $other"
  elif [ "$ntrusted" -eq 1 ]; then
    EZS_P1=PEWNA
    EZS_P1_ROW="${trusted# }"
  elif [ "$nfps" -eq 1 ]; then
    EZS_P1=NIEPEWNA
    EZS_P1_WHY="ten sam certyfikat pod kilkoma aliasami: $aliases"
  else
    EZS_P1=NIEPEWNA
    EZS_P1_WHY="kilka różnych certyfikatów ezdrowie.gov.pl: $aliases"
  fi
  if [ "$ntrusted" -gt 0 ] && [ -n "$keyed" ]; then
    EZS_P1_WHY="${EZS_P1_WHY:+$EZS_P1_WHY; }certyfikat ezdrowie.gov.pl także we wpisie z kluczem prywatnym (chroniony)"
  fi
  if [ "$EZS_STATUS" != OK ] && [ "$EZS_P1" = PEWNA ]; then
    EZS_P1=NIEPEWNA
    EZS_P1_WHY='magazyn nie został zweryfikowany hasłem'
  fi
  # A certificate OpenSSL cannot read may be another P1 entry.
  i=0
  while [ "$i" -lt "$ES_COUNT" ]; do
    if [ "${ES_OK[$i]}" != yes ]; then
      [ "$EZS_P1" != PEWNA ] || EZS_P1=NIEPEWNA
      EZS_P1_WHY="${EZS_P1_WHY:+$EZS_P1_WHY; }nieczytelny certyfikat we wpisie ${ES_ALIAS[$i]:-bez aliasu}"
    fi
    i=$((i + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Docker targets: replacement building blocks (used by the root helper).
# ---------------------------------------------------------------------------

# ez_jks_replace_cert <jks> <row> <source-cert> <PEM|DER> <out>
# Writes to <out> the JKS <jks> (already read by ez_jks_read, so ES_OFF,
# ES_LEN and EZS_JKS_BODY describe it) with the certificate of ES_* row
# <row> replaced by the first certificate of <source-cert>.  Every other
# byte (header, aliases, dates, all other entries including the protected
# private keys) is copied unchanged; only the 4-byte length, the
# certificate and the integrity digest (recomputed with EZS_PASSWORD, which
# reaches iconv on stdin only) change.
ez_jks_replace_cert() {
  local file="$1" row="$2" src="$3" inform="$4" out="$5" off len n rest digest

  off="${ES_OFF[$row]:-}"; len="${ES_LEN[$row]:-}"
  case "$off:$len:$EZS_JKS_BODY" in
    *[!0-9:]*|:*|*::*|*:) return 1 ;;
  esac
  n="$(LC_ALL=C openssl x509 -inform "$inform" -in "$src" -outform DER 2>/dev/null | wc -c | tr -d ' ')"
  case "$n" in ''|*[!0-9]*|0) return 1 ;; esac
  rest=$((EZS_JKS_BODY - off - 4 - len))
  [ "$rest" -ge 0 ] || return 1
  {
    head -c "$off" -- "$file" &&
      ez_hex_bytes "$(printf '%02x%02x%02x%02x' $((n >> 24 & 255)) $((n >> 16 & 255)) $((n >> 8 & 255)) $((n & 255)))" &&
      LC_ALL=C openssl x509 -inform "$inform" -in "$src" -outform DER 2>/dev/null &&
      tail -c "+$((off + 4 + len + 1))" -- "$file" | head -c "$rest"
  } > "$out" || return 1
  [ "$(ez_file_size "$out")" = $((EZS_JKS_BODY - len + n)) ] || return 1
  digest="$( { printf '%s' "$EZS_PASSWORD" | LC_ALL=C iconv -f UTF-8 -t UTF-16BE 2>/dev/null; \
    printf 'Mighty Aphrodite'; cat -- "$out"; } | openssl dgst -sha1 2>/dev/null | awk '{ print $NF }')"
  [ "${#digest}" -eq 40 ] || return 1
  ez_hex_bytes "$digest" >> "$out"
}

# Writes the bytes of a lowercase hex string.
ez_hex_bytes() {
  local h="$1" esc="" i=0

  case "$h" in *[!0-9a-f]*) return 1 ;; esac
  while [ "$i" -lt "${#h}" ]; do
    esc="$esc\\x${h:$i:2}"
    i=$((i + 2))
  done
  printf "$esc"
}

# SHA-256 of <length> bytes of <file> starting at 0-based <offset>.
ez_file_range_digest() {
  tail -c "+$(($2 + 1))" -- "$1" | head -c "$3" | openssl dgst -sha256 2>/dev/null | awk '{ print $NF }'
}

# One line per ES_* row (kind, entry, position, alias, fingerprint): the
# structure of the last opened store, compared before and after a change.
ez_store_rows_text() {
  local i=0
  while [ "$i" -lt "$ES_COUNT" ]; do
    printf '%s|%s|%s|%s|%s\n' "${ES_KIND[$i]}" "${ES_ENTRY[$i]}" "${ES_POS[$i]}" "${ES_ALIAS[$i]}" "${ES_FP[$i]}"
    i=$((i + 1))
  done
}

# --- shared by the caller (plan) and the root helper (apply-docker) ---------

# A Docker target path: plain characters, below the allowed roots, not in an
# "old" directory.  The file name is free (keystores, any certificate name).
ez_dc_target_path_ok() {
  ez_dc_path_ok "$1" && ez_path_under_roots "$1" && ! ez_dc_path_in_old_dir "$1"
}

# One file of a Docker application in plan records and helper arguments:
# path|type|old-file-sha256|old-fp|alias ("-" for PEM/DER).
ez_dc_target_spec_ok() {
  local path type sha fp alias separators

  separators="${1//[!|]/}"
  [ "${#separators}" -eq 4 ] || return 1
  # One line: "read" below would silently drop everything after a newline.
  ! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' && [ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = 0 ] || return 1
  IFS='|' read -r path type sha fp alias <<EOF
$1
EOF
  ez_dc_target_path_ok "$path" && ez_digest_ok "$sha" && ez_fp_ok "$fp" || return 1
  case "$type:$alias" in
    PEM:-|DER:-) ;;
    JKS:*|PKCS12:*) ez_dc_alias_ok "$alias" || return 1 ;;
    *) return 1 ;;
  esac
}

# An alias that may travel in plan records and helper arguments (always as
# one quoted value or argv element, compared literally, never evaluated):
# printable ASCII as Java writes it, spaces, brackets and "*" included
# ("*.ezdrowie.gov.pl (certum ov tls g2 r39 ca)").  Refused: empty, "-" first
# (the PEM/DER placeholder), the record separator "|", control characters
# (newline, CR, tab), bytes outside ASCII, "?" (the JKS reader shows a
# non-ASCII byte as "?": ambiguous), a space first or last, more than 128
# characters.
ez_dc_alias_ok() {
  case "$1" in
    ''|-*|' '*|*' '|*'|'*|*'?'*) return 1 ;;
  esac
  [ "${#1}" -le 128 ] || return 1
  # One line of printable ASCII only (0x20-0x7E).
  [ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = 0 ] || return 1
  ! printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'
}

# True when password variable name $1 (uppercase) belongs to stem $2: STEM
# followed by PASSWORD, PASSWD, PASS, PWD or PASSPHRASE (with or without "_",
# optionally "_FILE").  $3 = suffix also accepts a prefix ("X_<STEM>_PASS").
ez_dc_pw_named() {
  local n="${1%_FILE}" s="$2" w

  [ -n "$s" ] || return 1
  for w in PASSWORD PASSWD PASS PWD PASSPHRASE; do
    case "$n" in
      "$s$w"|"${s}_$w") return 0 ;;
    esac
    if [ "${3:-}" = suffix ]; then
      case "$n" in
        *"_$s$w"|*"_${s}_$w") return 0 ;;
      esac
    fi
  done
  return 1
}

# Binding rule 1: stem of the variable that names the store (origin env:K),
# K without _FILE/_PATH/_LOCATION/_LOC/_NAME, uppercase.  Fails for mounts.
ez_dc_pw_stem() {
  local stem

  case "$1" in
    env:*) stem="${1#env:}" ;;
    *) return 1 ;;
  esac
  case "$stem" in
    *_FILE|*_PATH|*_LOCATION|*_LOC|*_NAME) stem="${stem%_*}" ;;
  esac
  printf '%s' "$stem" | tr '[:lower:]' '[:upper:]'
}

# Binding rule 2: the store file name without extension, uppercase, other
# characters as "_".
ez_dc_pw_base() {
  local base="${1##*/}"

  case "$base" in
    ?*.*) base="${base%.*}" ;;
  esac
  printf '%s' "$base" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_'
}

# Rows of ez_store_rows_text without the entry number, sorted: the content
# of a store independent of the order in which it is written (a PKCS12
# store rewritten by Java may order its bags differently).
ez_dc_rows_norm() {
  printf '%s\n' "$1" | awk -F'|' 'NF { print $1 "|" $3 "|" $4 "|" $5 }' | LC_ALL=C sort
}

# Expected rows of a store after its P1 row $2 gets fingerprint $3; $1 =
# rows before.
ez_dc_rows_expected() {
  printf '%s\n' "$1" | awk -F'|' -v row="$2" -v fp="$3" 'BEGIN { OFS = "|" } NR == row + 1 { $5 = fp } { print }'
}

# Checks the store ES_* just opened (EZS_*) against the expected result:
# password and integrity OK, unambiguous P1 entry with alias $1 and
# fingerprint $2, and exactly the rows $3 (JKS: also in this order).
ez_dc_store_expected() {
  [ "$EZS_STATUS" = OK ] || return 1
  ez_store_p1
  [ "$EZS_P1" = PEWNA ] && [ "${ES_ALIAS[$EZS_P1_ROW]}" = "$1" ] && [ "${ES_FP[$EZS_P1_ROW]}" = "$2" ] || return 1
  case "$EZS_FORMAT" in
    JKS*) [ "$(ez_store_rows_text)" = "$3" ] ;;
    *) [ "$(ez_dc_rows_norm "$(ez_store_rows_text)")" = "$(ez_dc_rows_norm "$3")" ] ;;
  esac
}

# Algorithms of the PKCS12 just opened (ez_p12_read), without iteration
# counts: certificate encryption, key protection and MAC.
ez_dc_p12_algs() {
  printf '%s\n' "$EZS_P12_INFO" | awk '/^(PKCS7 Encrypted data|Shrouded Keybag|MAC):/ { sub(/, Iteration.*/, ""); print }' |
    LC_ALL=C sort -u
}

# Major version of a Java runtime ("8" for 1.8.x); empty when unknown.
ez_java_major() {
  local v

  v="$(env -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS "$1" -version 2>&1 |
    awk -F'"' '/ version "/ { print $2; exit }')"
  case "$v" in
    1.*) v="${v#1.}" ;;
  esac
  v="${v%%[!0-9]*}"
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$v"
}

# ez_p12_tool <replace|verify> <args>: runs the PKCS12 tool (EZ_P12_TOOL,
# with the runtime EZ_JAVA) with EZS_PASSWORD on its standard input only;
# variables that could inject code into the JVM are removed from its
# environment.  EZ_P12_MSG: its first message line (no secrets).
ez_p12_tool() {
  local rc=0

  [ -n "${EZ_JAVA:-}" ] && [ -n "${EZ_P12_TOOL:-}" ] || { EZ_P12_MSG='brak środowiska Java lub narzędzia PKCS12'; return 1; }
  EZ_P12_MSG="$(printf '%s\n' "$EZS_PASSWORD" | env -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS -u CLASSPATH \
    "$EZ_JAVA" -jar "$EZ_P12_TOOL" "$@" 2>&1 >/dev/null)" || rc=$?
  EZ_P12_MSG="$(printf '%s' "$EZ_P12_MSG" | head -n 1)"
  return "$rc"
}

# ez_dc_stage_store <current> <JKS|PKCS12> <alias> <old-fp> <source>
#   <source-format> <new-fp> <out>
# Writes to <out> the store <current> with only the certificate of its P1
# trustedCertEntry <alias> replaced by the first certificate of <source>,
# and proves it (EZS_PASSWORD must be set):
#   - <current> opens with the password and holds exactly that P1 entry,
#   - JKS: byte surgery (ez_jks_replace_cert); every byte outside the
#     certificate is unchanged,
#   - PKCS12: the Java KeyStore API tool; encrypted private keys byte for
#     byte, attributes and algorithms unchanged (checked by the tool and
#     here),
#   - <out> opens with the same password and has the same entries with only
#     the P1 fingerprint changed.
# EZDS_EXPECT: the expected rows of <out>; EZDS_REASON on failure.
ez_dc_stage_store() {
  local cur="$1" type="$2" alias="$3" oldfp="$4" src="$5" inform="$6" newfp="$7" out="$8"
  local row off len newlen olddig newdig algs

  EZDS_REASON=""; EZDS_EXPECT=""
  if ! ez_store_open "$cur" "$type" yes || ! ez_dc_store_expected "$alias" "$oldfp" "$(ez_store_rows_text)"; then
    EZDS_REASON="magazyn nie otwiera się hasłem z konfiguracji albo nie zawiera oczekiwanego wpisu P1 $alias (${EZS_STATUS:-?})"
    return 1
  fi
  row="$EZS_P1_ROW"
  EZDS_EXPECT="$(ez_dc_rows_expected "$(ez_store_rows_text)" "$row" "$newfp")"
  case "$type" in
    JKS)
      off="${ES_OFF[$row]}"; len="${ES_LEN[$row]}"
      olddig="$(ez_file_range_digest "$cur" 0 "$off")|$(ez_file_range_digest "$cur" $((off + 4 + len)) $((EZS_JKS_BODY - off - 4 - len)))"
      ez_jks_replace_cert "$cur" "$row" "$src" "$inform" "$out" || { EZDS_REASON='nie można przygotować magazynu JKS'; return 1; }
      if ! ez_store_open "$out" JKS yes || ! ez_dc_store_expected "$alias" "$newfp" "$EZDS_EXPECT"; then
        EZDS_REASON='przygotowany magazyn JKS nie przeszedł weryfikacji'
        return 1
      fi
      newlen="${ES_LEN[$EZS_P1_ROW]}"
      newdig="$(ez_file_range_digest "$out" 0 "$off")|$(ez_file_range_digest "$out" $((off + 4 + newlen)) $((EZS_JKS_BODY - off - 4 - newlen)))"
      [ "$newdig" = "$olddig" ] || { EZDS_REASON='zmieniłyby się inne bajty magazynu JKS'; return 1; }
      ;;
    PKCS12)
      algs="$(ez_dc_p12_algs)"
      ez_p12_tool replace "$cur" "$out" "$alias" "$oldfp" "$src" || {
        EZDS_REASON="${EZ_P12_MSG:-narzędzie PKCS12 zakończyło się błędem}"
        return 1
      }
      if ! ez_store_open "$out" PKCS12 yes || ! ez_dc_store_expected "$alias" "$newfp" "$EZDS_EXPECT"; then
        EZDS_REASON='przygotowany magazyn PKCS12 nie przeszedł weryfikacji'
        return 1
      fi
      [ "$(ez_dc_p12_algs)" = "$algs" ] || { EZDS_REASON='zmieniłyby się algorytmy magazynu PKCS12'; return 1; }
      ;;
    *) EZDS_REASON="nieobsługiwany typ magazynu $type"; return 1 ;;
  esac
}

# ez_dc_verify_store <file> <type> <alias> <new-fp> <expected-rows> <original>
# The store on disk after the replacement: password, integrity, entries and
# (PKCS12) the tool's full comparison with the original bytes.
ez_dc_verify_store() {
  ez_store_open "$1" "$2" yes || return 1
  if [ "$2" = PKCS12 ]; then
    ez_p12_tool verify "$6" "$1" "$3" "$4" || return 1
    ez_store_open "$1" PKCS12 yes || return 1
  fi
  ez_dc_store_expected "$3" "$4" "$5"
}
