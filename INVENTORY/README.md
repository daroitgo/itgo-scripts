# INVENTORY

Inventory Collector installs a local command that generates a JSON inventory report on a client server. Reports are always generated locally; optionally, they can be uploaded automatically to Nextcloud through WebDAV. Nextcloud configuration is local to the server and is not stored in this repository.

## Install layout

The public installer places files under:

- `/home/itgo/UTILITY/INVENTORY/bin`
- `/home/itgo/UTILITY/INVENTORY/reports`
- `/home/itgo/UTILITY/INVENTORY/logs`
- `/home/itgo/UTILITY/INVENTORY/config`
- `/home/itgo/UTILITY/INVENTORY/run` (collect lock: `run/collect.lock`)

Nextcloud configuration, when enabled, is stored locally as:

- `/home/itgo/UTILITY/INVENTORY/config/nextcloud.conf`
- `/home/itgo/UTILITY/INVENTORY/config/nextcloud.cred`

It also creates `/usr/local/bin/itgo-inv` as a symlink to the installed wrapper.

On systemd hosts it also installs the technical units `/etc/systemd/system/itgo-inventory.service` and `/etc/systemd/system/itgo-inventory.timer` (see [Automatic inventory](#automatic-inventory)).

## Usage

Generate a local report:

```bash
itgo-inv
itgo-inv collect
```

Show the newest local report:

```bash
itgo-inv latest
```

Show installed versions:

```bash
itgo-inv version
```

Configure optional Nextcloud WebDAV upload:

```bash
itgo-inv configure-nextcloud
```

Test the configured Nextcloud WebDAV access without generating a report:

```bash
itgo-inv test-nextcloud
```

`configure-nextcloud` interactively asks for the Nextcloud URL, technical user and App Password. The App Password is never accepted as a CLI argument and is not written to logs. The configuration directory uses mode `0700`. Credential storage prefers user-scoped `systemd-creds`; when it is unavailable, the App Password falls back to a local file protected with mode `0600`.

`collect` holds an exclusive `flock` lock on `run/collect.lock` for the whole run, so a manual `itgo-inv collect` and the systemd timer never run the collector at the same time; a second run reports that a collect is already in progress and exits without starting the collector. If `flock` is unavailable, `collect` prints a warning and runs without this protection.

## Automatic inventory

Automatic inventory uses a systemd timer that runs the same `itgo-inv collect` as a manual run:

- `itgo-inventory.service` – `Type=oneshot`, runs `/usr/local/bin/itgo-inv collect` as the installation user (`itgo` by default, the installer's `TARGET_USER`), never as root, with `UMask=0077`;
- `itgo-inventory.timer` – default schedule weekly, Sunday 03:00, `RandomizedDelaySec=30m`, `Persistent=true` (a run missed while the server was off is executed after the next boot).

The timer is **not** enabled during installation. A module upgrade does not change the timer enable state and preserves the configured schedule. If systemd is unavailable, the installer prints a warning and manual `itgo-inv collect` keeps working.

```bash
itgo-inv schedule-configure
itgo-inv schedule-enable
itgo-inv schedule-disable
itgo-inv schedule-status
itgo-inv schedule-run-now
```

- `schedule-configure` – interactively sets `daily` (time, randomized delay) or `weekly` (day `Mon`–`Sun`, time, randomized delay) mode; time uses `HH:MM`, randomized delay is 0–1440 minutes. The canonical configuration is stored in `/home/itgo/UTILITY/INVENTORY/config/schedule.conf` (mode `0600`) and applied as the drop-in `/etc/systemd/system/itgo-inventory.timer.d/schedule.conf`. It does not enable the timer.
- `schedule-enable` – runs `systemctl enable --now itgo-inventory.timer`.
- `schedule-disable` – runs `systemctl disable --now itgo-inventory.timer`; the schedule configuration and drop-in are kept.
- `schedule-status` – read-only; shows the configured (or default) schedule, enabled/active state and the next timer run.
- `schedule-run-now` – runs `systemctl start itgo-inventory.service` once; the result is in `journalctl -u itgo-inventory.service`.

Commands that change systemd state run directly as root or through `sudo` otherwise.

## Collector scope

The current collector version is 0.1.13. It runs read-only and is compatible with Python 2.7 and Python 3.x.

The host section of the report includes:

- `cpu_logical_count` – number of logical CPUs;
- `memory_total_bytes` – total memory in bytes.

If either value cannot be read or parsed, the collector does not stop: the field is set to `null` and a warning is added to the report.

Application detection:

- Application candidates are scanned under the base locations `/srv`, `/usr/local` and `/opt`. Scanning of each base is limited to 1024 direct entries; when the limit is exceeded, the collector adds an `APPLICATION_BASE_CHILD_LIMIT` warning.
- EPN is recognized as an application candidate; PSIM2 EPN is identified only by an exactly allowlisted Compose image repository.
- EREJ recognizes the existing variant and PSIM2 EREJ. When both allowlisted repositories are present, the collector does not guess the product and reports an ambiguity warning.
- Directories named `p1erej`, `p1rej`, `p1cer`, `p1ser`, `erej`, `cer` or `ser` are identified as EREJ only after the allowlisted Compose repository `amms.asseco.pl/asseco-poz/pi-p1-erejestracja-provider` is recognized; otherwise they remain plain candidates without forced product identification.
- MPI and EDM can be recognized within any of the allowed base locations, not only directly under `/srv`.
- For EDM, the collector can additionally recognize PSIM2 EDM and collect the Eureka, API Gateway and Regional EDM Adapter versions. A legacy EDM candidate is emitted only when a legacy application version is available, so a PSIM2 EDM installation does not get an artificial, version-less legacy EDM candidate.
- Inactive archive/auxiliary application directories are skipped: names ending in `_new`, `_old`, `_backup` or `_bak`, optionally followed by digits (case-insensitive), e.g. `wildfly_old` or `edm_backup2`. Active directories without these suffixes are handled as before.

Data from `.env` and `docker-compose` files is read only from allowlisted keys and image repositories, within the existing file size limits.

## Optional Nextcloud upload

The remote report path is:

```text
INVENTORY/<client_code>/<report_name>
```

`client_code` is read from `/home/itgo/UTILITY/ITGO-CONFIG/client-identity.json`. The remote directory `INVENTORY/<client_code>/` must already exist in Nextcloud; INVENTORY does not create it automatically.

For `collect`, INVENTORY:

1. runs a WebDAV preflight when Nextcloud is configured;
2. after a successful preflight and before generating a new report, retries up to 20 pending local reports (`inventory_<client_code>_*.json`, oldest first) of the current `client_code` only; the report content must also carry the same `client_code`;
3. generates the local report even if Nextcloud communication fails or a pending report retry fails;
4. uploads the report after a successful preflight;
5. confirms the uploaded file with WebDAV `PROPFIND` after `PUT`;
6. deletes the local report – new or pending – only after confirmed upload;
7. preserves the local report on any communication or upload failure;
8. does not automatically delete earlier reports retained after failed uploads other than through a confirmed retry upload;
9. uses a no-overwrite `PUT` safeguard for an existing remote report;
10. disables automatic upload when `client_code` is `unknown`.

If Nextcloud is not configured, `collect` remains backward-compatible and creates the report locally.

Reports are stored in `/home/itgo/UTILITY/INVENTORY/reports`.
