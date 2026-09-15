# LOGGUARD

LOGGUARD autonomously protects `catalina.out` for every detected `IntegrationPlatform` and `IntegrationPlatform_*` installation. Discovery scans only `/srv` and `/opt`, uses `find -P`, does not follow symlinks, and ignores any `_NEW` or `_OLD` path component.

## Installation and layout

The installer creates the private `$HOME/UTILITY/LOGGUARD` layout: `bin`, `config`, `state`, `logs/runs`, and the technical `archive` directory. It preserves an existing `config/logguard.conf` during updates. It also installs root-owned `logguard.service`, `logguard.timer`, and the technical `/usr/local/sbin/itgo-logguard-run` wrapper, enabling the timer immediately. The wrapper is the systemd execution entry point and calls the installed launcher. The timer runs five minutes after boot and then every 30 minutes.

The default `CATALINA_THRESHOLD_MIB` is 512 MiB. `/srv/BackupLog` is created only when a run needs it; `--uninstall` removes the LOGGUARD installation, systemd units, and wrapper, but never `/srv/BackupLog` or its archives.

## Commands

```bash
~/UTILITY/LOGGUARD/bin/logguard status
~/UTILITY/LOGGUARD/bin/logguard scan
~/UTILITY/LOGGUARD/bin/logguard plan
~/UTILITY/LOGGUARD/bin/logguard run
~/UTILITY/LOGGUARD/bin/logguard version
~/UTILITY/LOGGUARD/bin/logguard help
```

`status` reports version, configuration, privilege mode, timer state, and discovered-platform count. `scan` is entirely read-only and prints platform, type, path, size, owner, and strategy. `plan` is dry-run: it changes nothing and records `WOULD_*` actions. `run` remains available for manual operation; the systemd service runs it as root automatically.

## Handling and safety

`catalina.out` is `ACTIVE_CATALINA` and uses COPYTRUNCATE only after its configured threshold. LOGGUARD copies to a temporary archive under `/srv/BackupLog/<platform>/catalina`, gzips it, runs `gzip -t`, verifies uncompressed snapshot size, publishes the archive, and only then truncates the source. A copy, gzip, or verification failure never truncates the source.

Older `localhost_access_log.*.txt` files are archived under `access`; dated `*.log` files go under `application` (or `catalina` for `catalina.*.log`). Current-day files are skipped. Ordinary active `*.log` files are `MONITOR_ONLY`: they are never truncated, moved, compressed, or removed. Existing `.zip` and `.gz` files are `RETENTION_ONLY` and are not repacked or removed from platform directories.

Archive retention applies only inside `ARCHIVE_ROOT`, with configured age limits and a per-platform size limit. Deletes are restricted to canonical, verified regular files below `ARCHIVE_ROOT`; the root and platform directories are never deleted. The default configuration documents thresholds, retention, archive root, and dry-run mode, and is parsed as data rather than sourced as code.

Operational metadata is logged to `logs/logguard.log`; every plan/run has `logs/runs/logguard-run-YYYYMMDDTHHMMSS.log`, retained for the configured number of days. Manual non-root execution still requires sudo for privileged work; service execution as root does not invoke sudo.
