# Changelog

## Unreleased

- Added optional inventory upload to Nextcloud through WebDAV, with `configure-nextcloud` and `test-nextcloud` commands.
- Credentials prefer user-scoped `systemd-creds`, with a `0600` plaintext-file fallback when unavailable.
- Added WebDAV preflight before collection; local reports are removed only after `PUT` and a confirming `PROPFIND`, and remain local on errors.
- Retained reports after failed uploads are no longer automatically deleted; uploads prevent overwriting an existing remote report, and `client_code=unknown` disables upload.
- Added `curl` as an INVENTORY runtime dependency provided by MASTER.

## 0.1.3 - 2026-06-30

- Updated inventory collector to version 0.1.1.

## 0.1.2 - 2026-06-29

- Added Python 2.7 compatibility for the inventory collector on legacy Linux systems.
- Hardened interpreter selection in itgo-inv for mixed Python 2/Python 3 environments.

## 0.1.1 - 2026-06-29

- Fixed installer post-install version check to call the installed wrapper by absolute path instead of relying on PATH.

## 0.1.0

- Initial MVP Inventory Collector module.
- Offline JSON report generation via `itgo-inv`.
