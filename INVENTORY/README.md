# INVENTORY

Inventory Collector installs a local command that generates a JSON inventory report on a client server. Reports are always generated locally; optionally, they can be uploaded automatically to Nextcloud through WebDAV. Nextcloud configuration is local to the server and is not stored in this repository.

## Install layout

The public installer places files under:

- `/home/itgo/UTILITY/INVENTORY/bin`
- `/home/itgo/UTILITY/INVENTORY/reports`
- `/home/itgo/UTILITY/INVENTORY/logs`
- `/home/itgo/UTILITY/INVENTORY/config`

Nextcloud configuration, when enabled, is stored locally as:

- `/home/itgo/UTILITY/INVENTORY/config/nextcloud.conf`
- `/home/itgo/UTILITY/INVENTORY/config/nextcloud.cred`

It also creates `/usr/local/bin/itgo-inv` as a symlink to the installed wrapper.

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

## Optional Nextcloud upload

The remote report path is:

```text
INVENTORY/<client_code>/<report_name>
```

`client_code` is read from `/home/itgo/UTILITY/ITGO-CONFIG/client-identity.json`. The remote directory `INVENTORY/<client_code>/` must already exist in Nextcloud; INVENTORY does not create it automatically.

For `collect`, INVENTORY:

1. runs a WebDAV preflight when Nextcloud is configured;
2. generates the local report even if Nextcloud communication fails;
3. uploads the report after a successful preflight;
4. confirms the uploaded file with WebDAV `PROPFIND` after `PUT`;
5. deletes the local report only after confirmed upload;
6. preserves the local report on any communication or upload failure;
7. does not automatically delete earlier reports retained after failed uploads;
8. uses a no-overwrite `PUT` safeguard for an existing remote report;
9. disables automatic upload when `client_code` is `unknown`.

If Nextcloud is not configured, `collect` remains backward-compatible and creates the report locally.

Reports are stored in `/home/itgo/UTILITY/INVENTORY/reports`.
