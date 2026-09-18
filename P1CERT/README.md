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
p1cert update
p1cert status
p1cert version
```

`AUDIT`/`VERIFY` inspect the detected P1 configuration and certificate targets.
`UPDATE` performs a controlled, idempotent CA update for supported profiles.
`SCHEDULE` is not implemented.

## Certificate payload

The versioned official production payload is
`certs/p1-production-certs.zip`; the installer places it at
`/home/itgo/UTILITY/P1CERT/certs/p1-production-certs.zip`.

The payload, not the P1CERT code, is the source of certificate targets. Its
`manifest.env` describes a concrete rotation and names the target RootCA, TLS
CA, and WSS CA files. AUDIT reads it as literal data (it never sources it), extracts only
the named files into a private temporary directory, and calculates SHA-256
fingerprints with `openssl`. The code therefore knows no CA generation.

`SERVER_CERT_MODE=preserve` keeps the service certificate and does not require a
target. A future `replace` payload can name `SERVER_CERT_FILE`, which AUDIT will
inspect ready for comparison. `PRESERVE_WSS=true` preserves the existing client
WSS certificate; it is independent of the target WSS CA defined by
`TARGET_WSS_FILE`. AUDIT checks RootCA, TLS CA, and WSS CA presence. UPDATE adds
missing target CA certificates for supported profiles. SCHEDULE remains
unimplemented.

The payload is versioned with the P1CERT release: any content change requires a
new P1CERT version and tag. A payload must never be changed under an existing tag.
