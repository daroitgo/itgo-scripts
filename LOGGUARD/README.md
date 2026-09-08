# LOGGUARD

LOGGUARD 0.1.0 is a discovery-only, read-only module for auditing log-growth candidates inside detected IntegrationPlatform installations.

## Scope of 0.1.0

The module scans only `/srv` and `/opt`, finds directories named `IntegrationPlatform` or `IntegrationPlatform_*` (case-insensitively), and ignores paths with a component ending in `_NEW` or `_OLD`.

Only inside a detected platform root it discovers `catalina.out`, `*.log`, and `logs` directories. Candidate files are reported deterministically with platform, path, size, owner and a proposed strategy:

- `catalina.out` → `COPYTRUNCATE`
- `*.log` → `ROTATE_CANDIDATE`

These are proposals only. Version 0.1.0 does not truncate, move, remove, gzip, archive, compress, change permissions, alter logrotate, interact with Docker, or stop/restart services.

## Installation

Run as a user allowed to create and own files for `itgo` (normally root):

```bash
sudo bash logguard_installer_public.sh
```

The installer creates only this private layout:

```text
/home/itgo/UTILITY/LOGGUARD/
├── archive/
├── bin/logguard
├── config/
├── logs/
├── state/
└── logguard.version
```

Directories and implementation are owned by `itgo` and private to that user. No systemd unit, cron job, logrotate configuration, `/etc` file, sudoers entry, or `/usr/local/bin` wrapper is created.

## Commands

Run the installed private launcher as `itgo`:

```bash
~/UTILITY/LOGGUARD/bin/logguard status
~/UTILITY/LOGGUARD/bin/logguard scan
~/UTILITY/LOGGUARD/bin/logguard version
~/UTILITY/LOGGUARD/bin/logguard help
```

The default command is `status`. Absence of IntegrationPlatform installations is reported as normal discovery output, not as an error.

## Future direction

The intended later stages are controlled log-growth handling, archival, compression, retention, and safe COPYTRUNCATE only for explicitly approved `catalina.out` files. They are intentionally inactive in 0.1.0: discovery and validation on real servers must precede any active rotation.
