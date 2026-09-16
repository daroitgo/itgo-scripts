# Changelog

## Unreleased

- Added persistent `config/platforms.conf`: first installation requires administrator selection, while normal LOGGUARD commands operate only on the saved platform list.
- Added interactive `platforms-rescan` and read-only `platforms` commands; an empty configured list keeps the timer inactive.
- Restricted discovery to first setup and explicit rescan, and excluded `/srv/BackupLog` plus its entire subtree from discovery.

- Prepared the 0.2.0 LOGGUARD functionality: typed discovery, safe dry-run plans, explicit archive handling, private run logs, configuration validation, and archive-root retention safeguards.
- Added protected COPYTRUNCATE for threshold-qualified `catalina.out`, archival of eligible access and dated logs, and monitor-only handling for active ordinary logs.
- Restricted active `catalina.out` handling to the current `apache-tomcat/logs` directory and excluded non-log archives such as Tomcat binaries from discovery.

## 0.1.0

- Added the initial LOGGUARD foundation as a private, user-local module.
- Added deterministic discovery of IntegrationPlatform log candidates under `/srv` and `/opt`.
- Added read-only `status`, `scan`, `version`, and `help` commands.
