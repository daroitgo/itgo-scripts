# P1CERT certificate payload

This directory contains the versioned official production P1 certificate payload
used by read-only `VERIFY`/`AUDIT`.

Its release filename is `p1-production-certs.zip`. The ZIP must contain
`manifest.env` and the certificate files named by that manifest. P1CERT does not
embed certificate fingerprints and does not make certificate changes.

The ZIP is versioned together with its P1CERT release. Changing its contents requires a new P1CERT version and tag; it must never be replaced under an existing tag.
