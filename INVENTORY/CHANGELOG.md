# Changelog

## Unreleased

- Added automatic inventory through systemd: the installer installs `itgo-inventory.service` (oneshot, runs `itgo-inv collect` as the installation user, not root) and `itgo-inventory.timer`. Fresh installations leave the timer disabled; upgrades preserve the existing timer enable state and configured schedule drop-in.
- Added `schedule-configure`, `schedule-enable`, `schedule-disable`, `schedule-status` and `schedule-run-now` commands. `schedule-configure` sets a validated daily or weekly schedule, time and randomized delay, stored in `config/schedule.conf`; the default is a persistent (`Persistent=true`) weekly schedule on Sunday at 03:00 with a 30-minute randomized delay.
- `collect` now uses a non-overlapping `flock` lock (`run/collect.lock`), so the timer and manual runs never collect concurrently.
- After a successful Nextcloud preflight, `collect` first retries at most 20 pending local reports (oldest first) whose content confirms the exact current `client_code`; a report is still deleted locally only after a verified upload.
- Added optional inventory upload to Nextcloud through WebDAV, with `configure-nextcloud` and `test-nextcloud` commands.
- Credentials prefer user-scoped `systemd-creds`, with a `0600` plaintext-file fallback when unavailable.
- Added WebDAV preflight before collection; local reports are removed only after `PUT` and a confirming `PROPFIND`, and remain local on errors.
- Retained reports after failed uploads are no longer automatically deleted; uploads prevent overwriting an existing remote report, and `client_code=unknown` disables upload.
- Added `curl` as an INVENTORY runtime dependency provided by MASTER.
- Updated inventory collector to version 0.1.10.
- Host inventory now includes the logical CPU count (`cpu_logical_count`) and total memory in bytes (`memory_total_bytes`); unavailable or unparsable values are reported as `null` with a warning.
- Added EPN detection as a supported application candidate, with PSIM2 EPN identified by an exactly allowlisted Compose image repository.
- Extended EREJ detection to recognize PSIM2 EREJ and distinguish it from the existing EREJ variant; when both allowlisted repositories are present, the collector reports an ambiguity warning instead of guessing the product.
- Extended EDM detection to recognize PSIM2 EDM and collect Eureka, API Gateway and Regional EDM Adapter versions from allowlisted `.env` keys.
- Kept the bounded, read-only approach to reading host and application data.
- Updated inventory collector to version 0.1.11 with corrected EDM detection: the legacy EDM candidate is reported only when a legacy application version was actually read, so a PSIM2 EDM installation no longer produces an extra version-less legacy EDM candidate just because its directory matches the `edm` prefix. The PSIM2 EDM candidate is reported as before; the change remains read-only and does not modify application data.
- Updated inventory collector to version 0.1.12 with corrected AMMS candidate filtering: inactive directories named `wildfly_new`, `wildfly_old`, `wildfly_backup`, `wildfly_bak`, `wildflyamms_new`, `wildflyamms_old`, `wildflyamms_backup` or `wildflyamms_bak`, including variants ending in digits, are skipped when collecting application candidates. Matching is case-insensitive; active `wildfly` / `wildflyamms` directories without these suffixes are handled as before. The change remains read-only.
- Updated inventory collector to version 0.1.13: application base locations now include `/usr/local` in addition to `/srv` and `/opt`; inactive application directories with names ending in `_new`, `_old`, `_backup` or `_bak`, optionally followed by digits, are skipped (case-insensitive); MPI and EDM version detection is no longer limited to installations located directly under `/srv`; EREJ directories named `p1erej`, `p1rej`, `p1cer`, `p1ser`, `erej`, `cer` or `ser` are identified as the EREJ product only after recognizing the allowlisted Compose repository `amms.asseco.pl/asseco-poz/pi-p1-erejestracja-provider`, otherwise they remain plain candidates without forced product identification; scanning of each application base is limited to 1024 direct entries, and exceeding the limit adds an `APPLICATION_BASE_CHILD_LIMIT` warning. The change remains read-only.

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
