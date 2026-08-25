# P1CERT

P1CERT installs a local, read-only audit command for P1 certificate configuration.

## Install layout

The public installer places files under:

- `/home/itgo/UTILITY/P1CERT/bin`
- `/home/itgo/UTILITY/P1CERT/logs`
- `/home/itgo/UTILITY/P1CERT/state`
- `/home/itgo/UTILITY/P1CERT/certs`

It also creates `/usr/local/bin/p1cert` as a symlink to the installed wrapper.

## Usage

```bash
p1cert audit
p1cert verify
p1cert status
p1cert version
```

Version 0.1.0 supports only `AUDIT`/`VERIFY`. `UPDATE` and `SCHEDULE` are intentionally not implemented yet.

## Certificate payload

The optional, versioned official production payload is reserved as
`certs/p1-production-certs.zip`. When it is included in a release, the installer
places it at `/home/itgo/UTILITY/P1CERT/certs/p1-production-certs.zip`. It is
prepared for future VERIFY/UPDATE work and is not used to modify anything in 0.1.0.
The payload is versioned with the P1CERT release: any content change requires a
new P1CERT version and tag. A payload must never be changed under an existing tag.
