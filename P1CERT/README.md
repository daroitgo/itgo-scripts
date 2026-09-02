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

Version 0.1.1 supports only `AUDIT`/`VERIFY`. `UPDATE` and `SCHEDULE` are intentionally not implemented yet.

## Certificate payload

The versioned official production payload is
`certs/p1-production-certs.zip`; the installer places it at
`/home/itgo/UTILITY/P1CERT/certs/p1-production-certs.zip`.

The payload, not the P1CERT code, is the source of certificate targets. Its
`manifest.env` describes a concrete rotation and names the target RootCA and TLS
CA files. AUDIT reads it as literal data (it never sources it), extracts only
the named files into a private temporary directory, and calculates SHA-256
fingerprints with `openssl`. The code therefore knows no CA generation.

`SERVER_CERT_MODE=preserve` keeps the service certificate and does not require a
target. A future `replace` payload can name `SERVER_CERT_FILE`, which AUDIT will
inspect ready for comparison. `PRESERVE_WSS=true` is the present WSS keep policy;
AUDIT does not classify or compare WSS certificates. UPDATE and SCHEDULE remain
unimplemented.

The payload is versioned with the P1CERT release: any content change requires a
new P1CERT version and tag. A payload must never be changed under an existing tag.
