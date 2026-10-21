# Changelog

## Unreleased

- `p1cert ezdrowie`: directories whose complete component name is `OLD`
  (case-insensitive, at any depth, independent of the rest of the path) are
  treated as certificate archives. They are pruned from the scan (also in the
  helper's `find-candidates`), and every target below them is rejected by the
  shared path rule used by the plan parser and all helper operations, so such
  certificates are never scanned, planned or replaced. File and directory
  names that only contain "old" (`oldcerts`, `backup_old`,
  `old-ezdrowie.gov.pl-2025.crt`) are unchanged.

- Added the separate `p1cert ezdrowie` namespace for operator-approved
  replacement of local ezdrowie.gov.pl certificates (`/srv`, `/usr/local`,
  `/opt`) with the source certificate from Nextcloud `P1CERT_EZDROWIE`:
  `credentials`, `test`, `scan`, `plan`, `run`, `schedule`,
  `schedule-status` and `schedule-cancel`. Decisions use X.509 data only
  (validity, fingerprint, NotAfter, ezdrowie.gov.pl identity); the local path
  and file name are always preserved, every replacement is backed up and
  verified, and a failed restart rolls back with a single retry.
  Identity follows TLS semantics: DNS SANs are authoritative and the CN is
  only a fallback without DNS SAN; `*.ezdrowie.gov.pl` covers exactly one
  left-most label; the source is selected per local target. DER files must
  be exactly one certificate (no trailing data).
- Added the root-owned helper
  `/usr/local/libexec/itgo-p1cert/p1cert-ezdrowie-helper` with a dedicated
  `/etc/sudoers.d/itgo-p1cert-ezdrowie` entry and the
  `itgo-p1cert-ezdrowie.service` unit for the one-shot timer
  (`Persistent=false`, no catch-up after downtime). The helper offers only
  `apply`, `apply-systemd` and `apply-compose`: replacement, restart of a
  unit/compose service it proves to use the certificate, and rollback from
  its own copy of the old certificate happen in one privileged operation.
  There is no standalone restart or restore and no restart allowance. The
  helper fails closed when it, its library or their directories, the target
  directory, or the scheduler units are not root-controlled, and calls
  Docker with a clean environment (no `docker compose`). A rollback writes
  the old certificate back only over the exact bytes it installed; systemd
  restarts must stay active for a settle period; systemd binding evidence
  must come from root-controlled directories.
- `run` reports `PARTIAL` (non-zero exit) when some targets were skipped and
  `ROLLBACK_RESTART_FAILED` separately from `ROLLBACK`; a scheduled run never
  acts before the planned time; `plan`/`run`/`schedule` require `flock`;
  credential mode file and config directory permissions are enforced.
- The installer now creates `config/` and `backups/` with mode 0700 and no
  longer changes ownership of `config/` and `backups/` recursively; P1 CA
  commands (`audit`, `verify`, `update`, `status`) are unchanged.
- Caller, library and root helper share a contract version (helper API 1,
  reported by `helper ping`); a missing, older or newer helper is refused.
  The installer installs system files only into trusted root directories
  (`mv -f -T`, existing symlinks are never replaced), validates the complete
  sudoers configuration with revert, verifies `sudo -n` of the helper for the
  P1CERT user, validates the group name used in the service unit and reports
  `P1CERT ezdrowie system integration: READY` or `INCOMPLETE`.
- Added `p1cert_installer_public.sh --uninstall [user]`: disables and
  removes the one-shot timer, removes the service unit, the sudoers fragment,
  the root helper and library (directory only when empty), the own
  `/usr/local/bin/p1cert` link and the P1CERT directory. Only root-owned
  regular files with the P1CERT markers are removed; anything else is left
  and reported with a non-zero exit status.

- Added `update --java-only` and `update --with-keystore`. Automatic UPDATE
  now updates host Java cacerts and, when detected, an application JKS/PKCS12
  truststore; PEM/CER server-trust files remain untouched.
- Hardened UPDATE backups against path, scope and same-second collisions, and
  use a deterministic fingerprint-based alias when a preferred alias is
  already occupied by another certificate.
- UPDATE now returns a non-zero status for an incomplete or failed operation.
- Fixed preferred-alias selection so a free target alias is accepted correctly
  instead of being reported as unavailable during CA import.

- Java detection and Java cacerts handling are now host-only; container Java
  runtimes are ignored by both AUDIT and UPDATE.

- Added `CCP1SubCAWSS2025` as a third target CA alongside RootCA 2025 and
  SubCA TLS 2025.
- AUDIT now reports WSS CA presence in the application trust store and Java
  cacerts.
- UPDATE now imports the target WSS CA idempotently using alias
  `itgo-p1-subca-wss-2025`.
- Kept `PRESERVE_WSS=true` semantics unchanged: existing client WSS
  certificates are preserved.

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
