# LOGGUARD

LOGGUARD protects `catalina.out` only for explicitly configured `IntegrationPlatform` and `IntegrationPlatform_*` installations. The first installation discovers candidates under `/srv` and `/opt` and asks the administrator to select them; the resulting list is stored in `config/platforms.conf`. Normal `status`, `scan`, `plan`, and `run` use only that list. Discovery uses `find -P`, does not follow symlinks, ignores `_NEW` and `_OLD` path components, and always excludes `/srv/BackupLog` and its subtree.

## Installation and layout

The installer creates the private `$HOME/UTILITY/LOGGUARD` layout: `bin`, `config`, `state`, `logs/runs`, and the technical `archive` directory. It preserves `config/logguard.conf` and `config/platforms.conf` during updates. On a first interactive installation it saves the selected platform paths with mode `0600`; without an interactive terminal it saves an empty list, warns the administrator, and leaves the timer disabled. The installer also installs root-owned `logguard.service`, `logguard.timer`, and the technical `/usr/local/sbin/itgo-logguard-run` wrapper. The timer runs five minutes after boot and then every 30 minutes.

The default `CATALINA_THRESHOLD_MIB` is 512 MiB. `/srv/BackupLog` is created only when a run needs it; `--uninstall` removes the LOGGUARD installation, systemd units, and wrapper, but never `/srv/BackupLog` or its archives.

## Commands

```bash
~/UTILITY/LOGGUARD/bin/logguard status
~/UTILITY/LOGGUARD/bin/logguard scan
~/UTILITY/LOGGUARD/bin/logguard plan
~/UTILITY/LOGGUARD/bin/logguard run
~/UTILITY/LOGGUARD/bin/logguard platforms
~/UTILITY/LOGGUARD/bin/logguard platforms-rescan
~/UTILITY/LOGGUARD/bin/logguard version
~/UTILITY/LOGGUARD/bin/logguard help
```

`status` reports version, configuration, privilege mode, timer state, and monitored-platform count. `scan` is entirely read-only and prints platform, type, path, size, owner, and strategy for configured platforms only. `plan` is dry-run: it changes nothing and records `WOULD_*` actions. `run` remains available for manual operation; the systemd service runs it as root automatically. `platforms` prints the saved list. `platforms-rescan` requires an interactive terminal, discovers candidates for administrator selection, atomically rewrites `config/platforms.conf`, and enables or disables the timer according to whether the final list is non-empty.

## Handling and safety

`catalina.out` is `ACTIVE_CATALINA` and uses COPYTRUNCATE only after its configured threshold. LOGGUARD copies it to a temporary uncompressed snapshot under `/srv/BackupLog/<platform>/catalina`, validates that snapshot, and immediately truncates the source. A successful `truncate` is sufficient: the active application may immediately start writing new bytes. LOGGUARD keeps the raw snapshot until gzip, `gzip -t`, uncompressed-size verification, and archive publication all succeed. A copy failure never truncates the source; a truncate failure stops the rotation and removes the temporary snapshot. After a successful truncate, gzip, verification, or publication failure preserves the raw recovery snapshot and logs `RECOVERY_REQUIRED` with its path for manual recovery.

Older `localhost_access_log.*.txt` files are archived under `access`; dated `*.log` files go under `application` (or `catalina` for `catalina.*.log`). Current-day files are skipped. Ordinary active `*.log` files are `MONITOR_ONLY`: they are never truncated, moved, compressed, or removed. Existing `.zip` and `.gz` files are `RETENTION_ONLY` and are not repacked or removed from platform directories.

Archive retention applies only inside `ARCHIVE_ROOT`, with configured age limits and a per-platform size limit. Deletes are restricted to canonical, verified regular files below `ARCHIVE_ROOT`; the root and platform directories are never deleted. The default configuration documents thresholds, retention, archive root, and dry-run mode, and is parsed as data rather than sourced as code.

Operational metadata is logged to `logs/logguard.log`; every plan/run has `logs/runs/logguard-run-YYYYMMDDTHHMMSS.log`, retained for the configured number of days. Manual non-root execution still requires sudo for privileged work; service execution as root does not invoke sudo.
