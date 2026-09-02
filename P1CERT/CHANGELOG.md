# Changelog

## 0.1.3 - 2026-09-02

- Fixed certificate payload parsing compatibility across RHEL-family OpenSSL
  versions (including Oracle Linux 7.x/OpenSSL 1.0.x and Rocky Linux 9.x): the
  SHA-256 fingerprint field name is now matched case-insensitively.
- Made target certificate reading format-agnostic by trying PEM first and DER
  second, independently of the filename extension.

## 0.1.2 - 2026-09-02

- Fixed manifest.env line endings in p1-production-certs.zip from CRLF to LF so Linux validation works correctly.
## 0.1.1 - 2026-08-26

- Made AUDIT/VERIFY payload-driven: fingerprints are calculated from the
  versioned ZIP instead of stored in code.
- Added strict non-evaluating manifest parsing and safe ZIP path checks.
- Fixed wrapper operation through `/usr/local/bin/p1cert` symlinks.
- Added payload-aware RootCA, TLS CA, Java cacerts, server-certificate policy,
  and WSS policy reporting. UPDATE and SCHEDULE remain unimplemented.

## 0.1.0 - 2026-08-25

- Initial P1CERT module.
- Added read-only AUDIT/VERIFY for P1ADAPTER and P1CER certificate sources.
- UPDATE and SCHEDULE are not implemented.

