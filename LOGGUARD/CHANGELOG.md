# Changelog

## Unreleased

- Prepared the 0.2.0 LOGGUARD functionality: typed discovery, safe dry-run plans, explicit archive handling, private run logs, configuration validation, and archive-root retention safeguards.
- Added protected COPYTRUNCATE for threshold-qualified `catalina.out`, archival of eligible access and dated logs, and monitor-only handling for active ordinary logs.

## 0.1.0

- Added the initial LOGGUARD foundation as a private, user-local module.
- Added deterministic discovery of IntegrationPlatform log candidates under `/srv` and `/opt`.
- Added read-only `status`, `scan`, `version`, and `help` commands.
