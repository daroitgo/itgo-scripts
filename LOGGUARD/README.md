# LOGGUARD

LOGGUARD 0.1.0 provides controlled log discovery, dry-run planning, and explicit archive handling for detected IntegrationPlatform installations. Discovery scans only `/srv` and `/opt`, uses `find -P`, does not follow symlinks, and ignores any `_NEW` or `_OLD` path component.

## Installation and layout

The installer creates the private `$HOME/UTILITY/LOGGUARD` layout: `bin`, `config`, `state`, `logs/runs`, and the technical `archive` directory. It installs the default `config/logguard.conf` only when it does not already exist, so updates preserve local configuration. It does not create `/srv/BackupLog`; that root is created only by an explicit `run` when needed.

No service unit, scheduled task, operating-system rotation configuration, privilege-policy change, system configuration file, or global wrapper is created.

## Commands

```bash
~/UTILITY/LOGGUARD/bin/logguard status
~/UTILITY/LOGGUARD/bin/logguard scan
~/UTILITY/LOGGUARD/bin/logguard plan
~/UTILITY/LOGGUARD/bin/logguard run
```

`status` reports version, configuration, sudo availability, and discovered-platform count. `scan` is entirely read-only and prints platform, type, path, size, owner, and strategy. `plan` is dry-run: it changes nothing and records `WOULD_*` actions. Only the explicitly invoked `run` can modify files.

## Handling and safety

`catalina.out` is `ACTIVE_CATALINA` and uses COPYTRUNCATE only after its configured threshold. LOGGUARD copies to a temporary archive under `/srv/BackupLog/<platform>/catalina`, gzips it, runs `gzip -t`, verifies uncompressed snapshot size, publishes the archive, and only then truncates the source. A copy, gzip, or verification failure never truncates the source.

Older `localhost_access_log.*.txt` files are archived under `access`; dated `*.log` files go under `application` (or `catalina` for `catalina.*.log`). Current-day files are skipped. Ordinary active `*.log` files are `MONITOR_ONLY`: they are never truncated, moved, compressed, or removed. Existing `.zip` and `.gz` files are `RETENTION_ONLY` and are not repacked or removed from platform directories.

Archive retention applies only inside `ARCHIVE_ROOT`, with configured age limits and a per-platform size limit. Deletes are restricted to canonical, verified regular files below `ARCHIVE_ROOT`; the root and platform directories are never deleted. The default configuration documents thresholds, retention, archive root, and dry-run mode, and is parsed as data rather than sourced as code.

Operational metadata is logged to `logs/logguard.log`; every plan/run has `logs/runs/logguard-run-YYYYMMDDTHHMMSS.log`, retained for the configured number of days. Sudo is detected and used only for individual operations that need it; LOGGUARD is not launched wholesale through sudo.
