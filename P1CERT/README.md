# P1CERT

P1CERT has two separate parts:

1. **P1 CA management** (`audit`, `verify`, `update`, `status`): a read-only
   audit of the P1 certificate configuration and the controlled addition of
   the target P1 CA certificates.
2. **ezdrowie.gov.pl certificates** (`p1cert ezdrowie ...`): an operator
   approved replacement of local ezdrowie.gov.pl certificate files with the
   source certificate published in the ITGO Nextcloud.

The two parts share only the installation directory and the launcher. The
`ezdrowie` namespace does not change the behaviour of the P1 CA commands.

## Install layout

The public installer places files under:

- `/home/itgo/UTILITY/P1CERT/bin`
- `/home/itgo/UTILITY/P1CERT/logs`
- `/home/itgo/UTILITY/P1CERT/state`
- `/home/itgo/UTILITY/P1CERT/certs`
- `/home/itgo/UTILITY/P1CERT/config` (0700, ezdrowie credentials)
- `/home/itgo/UTILITY/P1CERT/backups` (0700; `backups/ezdrowie/` for ezdrowie)

It also creates `/usr/local/bin/p1cert` as a symlink to the installed wrapper.

For the `ezdrowie` namespace the installer additionally installs the only
system components it needs (when run as root):

- `/usr/local/libexec/itgo-p1cert/p1cert-ezdrowie-helper` and
  `/usr/local/libexec/itgo-p1cert/p1cert_ezdrowie_lib.sh` - root-owned,
  not writable by the P1CERT user (installed only when `/`, `/usr`,
  `/usr/local` and `/usr/local/libexec` are root-owned and not group/world
  writable),
- `/etc/sudoers.d/itgo-p1cert-ezdrowie` - allows the P1CERT user to run only
  that helper without a password. Installed only when `/etc` and
  `/etc/sudoers.d` are trusted root directories and an existing fragment is a
  trusted root file (a symlink or anything else is never replaced). The
  fragment is validated with `visudo -cf`, then the complete configuration
  with `visudo -cf /etc/sudoers`; if that fails, the previous fragment is put
  back (or the new one removed),
- `/etc/systemd/system/itgo-p1cert-ezdrowie.service` - the service started by
  the one-shot timer; it runs `p1cert ezdrowie run --scheduled` as the P1CERT
  user, not as root. Installed only when `/etc`, `/etc/systemd` and
  `/etc/systemd/system` are trusted and an existing unit is a `root:root`
  regular file; the primary group name of the P1CERT user must consist of
  `A-Z a-z 0-9 . _ -`. `systemctl daemon-reload` follows.

All system files are written to a temporary file in the target directory,
set to `root:root` and the final mode and renamed with `mv -f -T`.

Caller, library and helper share a contract version (`HELPER API`, currently
`3`; independent of the P1CERT version). `helper ping` prints `HELPER=OK`
and `API_VERSION=3`; `p1cert ezdrowie` and the installer accept only exactly
this version, and the helper refuses a root library with another version
(API 1 and 2 components of earlier releases are incompatible).
After a partial upgrade (new scripts, old helper) `run`/`schedule` therefore
stop with "uprzywilejowany helper ma niezgodną wersję API" instead of using
an incompatible helper.

The installer ends with one of:

- `P1CERT ezdrowie system integration: READY` - the installed helper
  answers with the expected API version, `sudo -n` of the helper as the
  P1CERT user was verified (`sudo -u <user> sudo -n <helper> ping`) and the
  service unit is installed when systemd is available,
- `P1CERT ezdrowie system integration: INCOMPLETE` - followed by the reasons.
  `credentials`, `test`, `scan` and `plan` still work; `run` and `schedule`
  need a compatible helper and sudoers entry. If the passwordless sudo
  access cannot be verified from the installer (for example because root's
  own `sudo -u` is blocked by `requiretty`), the result is INCOMPLETE with
  the command to check it manually.

An incomplete integration does not fail the installation of the P1 CA
commands. An upgrade keeps credentials, config, the accepted plan, schedule
state, last run, backups, logs and an armed timer (`config/` and `backups/`
are never changed recursively). The installer never creates, enables or
modifies `itgo-p1cert-ezdrowie.timer`.

### Uninstall

```bash
bash p1cert_installer_public.sh --uninstall [TARGET_USER]
```

(MASTER runs this from its root-only staging.) Order:

1. refuses to do anything while `itgo-p1cert-ezdrowie.service` is running
   (a scheduled replacement must not be interrupted),
2. `systemctl disable --now itgo-p1cert-ezdrowie.timer` (a missing timer is
   fine; no scheduled run is started),
3. removes the timer unit and the service unit, then `systemctl daemon-reload`,
4. removes `/etc/sudoers.d/itgo-p1cert-ezdrowie` and checks the complete
   configuration with `visudo -cf /etc/sudoers`,
5. removes the root helper and its library, then `rmdir`s
   `/usr/local/libexec/itgo-p1cert` only when it is empty,
6. removes `/usr/local/bin/p1cert` only when it is a symlink to this
   installation's launcher,
7. removes `~/UTILITY/P1CERT` including credentials, plan, schedule state,
   backups and logs (full uninstall; an upgrade keeps all of them).

System files are removed only when they are root-owned regular files (not
symlinks or directories, not group/world writable) that contain the markers
of the P1CERT-generated file (managed header, unit description, helper API
line). Anything else - for example a file an administrator replaced with
own content - is left in place and reported. The helper directory is never
removed recursively. If anything is left, the result is
`P1CERT uninstall: INCOMPLETE` with the list and a non-zero exit status;
otherwise `P1CERT uninstall: DONE`.

## P1 CA management

```bash
p1cert audit
p1cert verify
p1cert update
p1cert update --java-only
p1cert update --with-keystore
p1cert status
p1cert version
```

`AUDIT`/`VERIFY` inspect the detected P1 configuration and certificate targets.
Java trust inspection is host-only; Java runtimes and cacerts inside Docker
containers are ignored. `UPDATE` always updates the host Java cacerts. In
automatic mode it also updates a detected application JKS/PKCS12 truststore;
PEM/CER server-trust files are never modified. `--java-only` skips the
application store, while `--with-keystore` requires a detected application
JKS/PKCS12 before making any change. Docker Java cacerts are never modified.
`SCHEDULE` is not implemented for P1 CA management.

`p1cert update` never modifies Docker Java/cacerts, vendor PEM files, TLS/WSS
client certificates, docker-compose files, images or keystore passwords.

### Certificate payload

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
missing target CA certificates for supported profiles.

The payload is versioned with the P1CERT release: any content change requires a
new P1CERT version and tag. A payload must never be changed under an existing tag.

## ezdrowie.gov.pl certificates

The `ezdrowie` namespace is a deliberate, separate exception to the rules
above. It only replaces files that

- are located below `/srv`, `/usr/local` or `/opt`,
- are not inside a certificate archive: any directory component whose
  complete name is `OLD` (any case, at any depth and independent of the rest
  of the path, e.g. `/srv/CERTYFIKATY/P1/OLD/` or `/srv/a/b/old/c/`) marks an
  archive; it is never scanned or planned, and files below it are not
  eligible for an approved replacement (the plan, the run and the root helper
  refuse them); names that merely contain "old", such as `/srv/oldcerts/`,
  `/srv/backup_old/` or the file name `old-ezdrowie.gov.pl-2025.crt`, are not
  affected,
- have a `.pem`, `.crt` or `.cer` name that, without the extension,
  lowercased and with `.`, `_` and `-` removed, contains `ezdrowiegovpl`
  (e.g. `ezdrowiegovpl.pem`, `ezdrowie.gov.pl.pem`, `ezdrowie_gov_pl.crt`),
- contain either exactly one X.509 certificate (PEM or DER, no data after a
  DER certificate) or a valid PEM certificate chain (see below), never a
  private key or another PEM block, with an ezdrowie.gov.pl identity,
- were explicitly approved by an operator in `p1cert ezdrowie plan`.

The source is the Nextcloud WebDAV folder `P1CERT_EZDROWIE` of user `itgonc`
on `https://helpdesk.itgo.com.pl/nextcloud`. These values are built into the
application; the only local setting is the Nextcloud App Password.

All commands run as the P1CERT user (`itgo`) and refuse to run as root.

```bash
p1cert ezdrowie credentials
p1cert ezdrowie test
p1cert ezdrowie scan
p1cert ezdrowie plan
p1cert ezdrowie run [--yes]
p1cert ezdrowie schedule [YYYY-MM-DD HH:MM]
p1cert ezdrowie schedule-status
p1cert ezdrowie schedule-cancel
```

### credentials

Asks only for `Nextcloud App Password:`. The password is stored in
`config/ezdrowie-nextcloud.cred` (directory 0700, file 0600), encrypted with
`systemd-creds --user` when it is available and round-trips correctly,
otherwise as a plain 0600 file. The mode is recorded in
`config/ezdrowie-credential-mode`. The password is never written to logs and
never passed in process arguments (curl receives it through a config on
stdin). When the password is loaded, `config/` must be a directory (not a
symlink) owned by the current user without group/world write access, and
both files must be regular files (not symlinks) owned by the current user
with mode 0600; otherwise the credentials are rejected.

`plan`, `run`, `schedule` and `schedule-cancel` run under an exclusive
`flock` lock in `state/`. Without the `flock` command (util-linux) they
refuse to run.

### test

Performs an authenticated WebDAV `PROPFIND` of `P1CERT_EZDROWIE` and prints
the URL, user, remote folder, credential mode and `SUCCESS`/`ERROR`.

### scan

Read-only. Searches `/srv/`, `/usr/local/` and `/opt/` without following
symlinks, validates every candidate with `openssl x509` and prints the full
path, the exact file name, SHA-256 fingerprint, Subject, Issuer, Not Before,
Not After and validity status (for a PEM chain: of its leaf, plus the number
of certificates). Files that are neither a single certificate nor a valid
PEM chain are listed as skipped with the reason. Unreadable files are read
through the helper when it is installed.

#### PEM certificate chains

A local or source file may be a PEM bundle such as `ezdrowieGovPl.cer` or
`ezdrowiegovpl_2026.pem` (leaf, intermediate CA, root CA). It is accepted
only as a real chain:

- at least 2 and at most 10 `CERTIFICATE` blocks and nothing else (no
  private key, CRL, parameters or other PEM block; well-formed markers),
- every block is a valid X.509 certificate, none repeated,
- the first certificate is the leaf: not a CA, not self-signed,
- every following certificate is a CA and the issuer of the previous one,
  proven by name and cryptographically (`openssl verify` with only that CA
  as trust anchor, `-partial_chain`, no system trust store, at a time inside
  both validity periods - works with OpenSSL 1.0.2 and 3.x),
- intermediates are not self-signed and the last certificate is the
  self-signed root that terminates the chain.

Concatenated independent certificates (e.g. two leaf certificates), a leaf
with an unrelated CA, a wrong order, a missing root or a forged/damaged
intermediate are rejected with the concrete reason.

For a chain, every decision - identity, fingerprint, NotBefore/NotAfter,
"newer than" and the plan fingerprints - uses the leaf. The replacement,
however, writes the complete verified source file byte for byte
(intermediates and root included) and the post-write verification checks the
leaf fingerprint and the SHA-256 of the whole file. A chain is only written
into a PEM target (never converted to DER), and a local chain is never
replaced by a single certificate; a single PEM target may receive a chain.
The chain length may change.

### plan

1. runs the scan,
2. downloads every `.pem`/`.crt`/`.cer` from `P1CERT_EZDROWIE` to a private
   temporary directory and validates it (single X.509 or valid PEM chain
   whose leaf is checked: NotBefore <= now < NotAfter,
   fingerprint, ezdrowie.gov.pl identity, not a CA, not self-signed, not a
   non-production name such as `isus.ezdrowie.gov.pl`); the remote file name,
   modification time and Nextcloud timestamps are ignored; remote entries
   with malformed percent-encoding (every `%` must be `%HH`) or unsupported
   characters are skipped,
3. selects, separately for every local certificate, the currently valid
   source that covers that certificate's primary identity and has the latest
   NotAfter (never one global "newest" source for all targets),
4. decides:

| Source state                        | Decision         |
|-------------------------------------|------------------|
| absent                              | SKIP             |
| invalid / incompatible / ambiguous  | SKIP + WARNING   |
| same fingerprint as local           | NO CHANGE        |
| NotAfter <= local NotAfter          | NO CHANGE        |
| NotAfter > local NotAfter           | UPDATE CANDIDATE |

5. for every UPDATE CANDIDATE shows the local certificate, both NotAfter
   values, both fingerprints, the detected application/service and the
   expected restart, and asks the operator separately to approve the
   replacement and the restart.

Identity rules (X.509 data only):

- If the certificate has DNS Subject Alternative Names, they are the
  authoritative set of names; the CN is ignored (a CN cannot "rescue" a
  certificate whose SANs do not cover the required name). The CN is used only
  when there is no DNS SAN at all.
- The primary identity of the local certificate is its CN when the CN is one
  of those names, otherwise the first ezdrowie.gov.pl name. Local
  certificates with a non-production primary identity (labels such as
  `isus`, `test`, `tst`, `int`, `integr*`, `uat`, `dev`, `demo`, `stage`,
  `staging`, `preprod`, `pre`, `sandbox`) are never replaced, and such
  sources are never used.
- The source must cover the local primary identity. `*.ezdrowie.gov.pl`
  covers exactly one additional left-most label (`api.ezdrowie.gov.pl`), but
  neither `ezdrowie.gov.pl` nor `foo.bar.ezdrowie.gov.pl`. Only a wildcard
  that is the complete left-most label is accepted (`foo*.x`, `*foo.x`,
  `a.*.x`, `**`, `*.pl` are invalid). Every other label must be 1-63
  characters `a-z`, `0-9`, `-`, not starting or ending with `-`. A wildcard
  local identity requires the same wildcard in the source.
- SAN entries are read from the complete `openssl x509 -text` block, also
  when OpenSSL wraps them over several lines (OpenSSL 1.0.x and 3.x).

Service detection offers only restarts the root helper can prove later:

- a systemd unit whose configuration (`ExecStart`, `Environment`, unit file,
  drop-ins, `EnvironmentFile`) names the exact certificate path, or whose
  `WorkingDirectory`, `ExecStart` executable (or the script started by
  `/bin/sh`/`/bin/bash`) lies in the same IntegrationPlatform installation
  directory as the certificate (e.g. certificate
  `/srv/IntegrationPlatform_PI/conf/ezdrowiegovpl.pem` and
  `ExecStart=/srv/IntegrationPlatform_PI/apache-tomcat/bin/startup.sh`);
  a common parent such as `/srv` is not enough; system units on a deny-list
  (sshd, systemd-*, docker, network, cron, ...) are never offered,
- Docker Compose services whose volumes, configs, secrets, `env_file`,
  environment or `.env` variables cover the file (static analysis of the
  compose file). Before a restart the helper additionally requires that the
  running containers of the service bind-mount the certificate.

An ambiguous result lists all candidates; the operator picks one or rejects
the restart. Nothing is approved automatically. A target whose directory is
not owned by root or is writable by group/others is skipped with a warning:
the helper would refuse to replace it (manual replacement required).

The accepted plan is stored in `state/ezdrowie-plan` (0600) as plain
`KEY=VALUE` lines. It is parsed strictly, never sourced, and records for each
target the exact path, the local (leaf) fingerprint and NotAfter at
acceptance time, the SHA-256 of the exact bytes of the whole local file, the
approved source (leaf) fingerprint and NotAfter, the SHA-256 of the exact
bytes of the whole source file and the approved restart (`none`, a systemd
unit, or a compose project directory plus service):

```text
PLAN_VERSION=2
TARGET=<path>|<local-fp>|<local-notafter>|<local-file-sha256>|<source-fp>|<source-notafter>|<source-file-sha256>|<none|systemd|compose>|<unit|project|->|<service|->
```

The operator therefore approves exact files, not only leaf certificates:
any later change of the local or the source file - another intermediate or
root in a chain, other line endings, a leaf delivered without its chain -
requires a new plan, also when the leaf certificate is identical. Plans of
the previous format (`PLAN_VERSION=1`) are rejected; after the upgrade run
`p1cert ezdrowie plan` again.

### run

Executes only the accepted plan. For each target it reads the current source
from Nextcloud and validates it again, re-reads the local certificate, and:

- skips the target if the local fingerprint differs from the plan (a new plan
  is required) or the source differs from the approved source, and also when
  the SHA-256 of the whole local file or of the whole source file differs
  from the plan ("file changed since the accepted plan"; a new plan is
  required),
- reports NO CHANGE if the local file is already identical or not older,
- otherwise backs up the old file to
  `backups/ezdrowie/<timestamp>/` (copy plus a manifest with original path and
  name, old/new fingerprint, old/new NotAfter, owner, group, mode, SELinux
  context and timestamp; existing backups are never overwritten),
- calls exactly one helper operation for the target: `apply` (no restart
  approved), `apply-systemd` or `apply-compose` (approved restart), with the
  target path, the old and new fingerprints and the old-file and source-file
  SHA-256 from the plan. The helper checks the exact bytes again inside its
  own operation: the stdin bytes must match the source digest before they are
  interpreted, its root-private copy of the current target must match the
  old digest, and the target is compared with those same bytes once more
  right before the atomic rename. A change after the plan is therefore
  detected and refused, up to that last check; the rename itself is
  pathname-based and leaves a narrow final window (see Limitations).

Inside that single privileged operation the helper replaces the file (same
path and file name as before - the remote file name is irrelevant -, same
encoding PEM/DER, owner, group, mode and SELinux context, temporary file in
the same directory, atomic rename; a PEM chain is written unchanged, byte for
byte), verifies it again (X.509 or complete chain, leaf fingerprint, exact
bytes of the whole file) and, for an approved restart, proves the unit/service relation
again and restarts only that unit (`systemctl restart <unit>`) or only the
verified containers of that compose service (`docker restart <ids>`, never
the whole project). A systemd restart counts as successful only when the
unit stays `active` for a short settle period (3 s); leaving `active` in that
time is a failed restart. If the restart fails, the helper restores exactly
the previous certificate it read itself at the beginning of the same
operation, verifies its fingerprint and bytes and restarts once more with it.
There are no further retries. The previous certificate is written back only
while the target still contains exactly the bytes installed by this
operation (SHA-256 `NEW_DIGEST`); if anybody changed the file in the
meantime, that change is not overwritten and the result is
`ROLLBACK_FAILED` (manual intervention). The replacement does not start
unless valid SHA-256 digests of the old and new bytes are available.

Two different copies of the old certificate exist:

- **audit/operator backup** - `backups/ezdrowie/<timestamp>/` with a
  manifest, written by `run` (as the P1CERT user) before the helper is
  called. It is for the operator (manual restore, audit) and is never read
  by the helper,
- **rollback copy** - the exact bytes the helper itself reads from the target
  inside the same privileged operation, kept in the helper's root-private
  temporary directory and deleted when the operation ends. Only this copy is
  used for an automatic rollback.

Per-target results:

| Helper result             | target result           | Meaning                                                    |
|---------------------------|-------------------------|------------------------------------------------------------|
| `UPDATED`                 | UPDATED                 | replaced and verified, no restart approved (restart manually if needed) |
| `UPDATED_RESTARTED`       | UPDATED                 | replaced, verified, approved unit/service restarted        |
| `NO_CHANGE`               | NO_CHANGE               | already identical                                          |
| `REFUSED` (rc 2)          | REFUSED                 | validation or service relation failed; nothing changed     |
| `REFUSED` (rc 3)          | SKIP                    | fingerprint guard (target changed); nothing changed        |
| `RESTORED`                | ERROR                   | replacement undone before any restart                      |
| `ROLLBACK`                | ROLLBACK                | restart failed, previous certificate restored, restart with it succeeded |
| `ROLLBACK_RESTART_FAILED` | ROLLBACK_RESTART_FAILED | previous certificate restored, but the application/service still does not start - manual intervention |
| `ROLLBACK_FAILED`         | CRITICAL                | previous certificate could not be restored - restore manually from the audit backup |

Overall `run` result (`LAST_RUN_RESULT`), most severe first:

| Result                    | When                                                        | Exit |
|---------------------------|-------------------------------------------------------------|------|
| `CRITICAL`                | any target CRITICAL                                         | 1    |
| `ROLLBACK_RESTART_FAILED` | any target ROLLBACK_RESTART_FAILED                          | 1    |
| `ROLLBACK`                | any target ROLLBACK                                         | 1    |
| `ERROR`                   | any target ERROR or REFUSED                                 | 1    |
| `PARTIAL`                 | some targets SKIP, the others UPDATED or NO_CHANGE          | 1    |
| `SKIPPED`                 | all targets SKIP                                            | 3    |
| `OK`                      | all targets UPDATED or NO_CHANGE, at least one UPDATED      | 0    |
| `NO_CHANGE`               | all targets NO_CHANGE                                       | 0    |

Two targets that share the same unit/service are handled as two separate
operations, i.e. the unit is restarted once per replaced certificate. A
manual `run` asks for confirmation (`--yes` for non-interactive use). A
scheduled run executes exactly the accepted plan and cannot extend it.

### schedule, schedule-status, schedule-cancel

`schedule` arms `itgo-p1cert-ezdrowie.timer` for exactly one local date and
time. The timer uses a fully specified `OnCalendar=` date with
`Persistent=false`: a run missed while the server was down is **not** caught
up later. In addition the scheduled run acts only from the planned second up
to 15 minutes later: it refuses to act when it starts before the planned time
(e.g. after a clock change) or more than 15 minutes after it, when the plan
changed after
scheduling (SHA-256 of the plan file), or when no schedule state exists.
After a scheduled run the timer is disabled and removed.

`schedule-status` shows the plan, the scheduled time and its consistency with
the plan, the timer state and the last run result (`state/ezdrowie-last-run`).
`schedule-cancel` disarms the pending timer; the plan and backups are kept.

### Privileged helper

The scripts under `/home/itgo/UTILITY/P1CERT/` are never run as root. The
root-owned helper is a separate security boundary and implements only:

```
ping
find-candidates
read           <cert-path>
apply          <cert-path> <old-fp> <new-fp> <old-file-sha256> <new-source-sha256>
apply-systemd  <cert-path> <old-fp> <new-fp> <old-file-sha256> <new-source-sha256> <unit.service>
apply-compose  <cert-path> <old-fp> <new-fp> <old-file-sha256> <new-source-sha256> <project-dir> <service>
schedule       <YYYY-MM-DD> <HH:MM>
schedule-cancel
```

`<old-fp>`/`<new-fp>` are leaf fingerprints; `<old-file-sha256>` and
`<new-source-sha256>` are the SHA-256 (64 lowercase hex) of the exact current
target file and of the exact stdin bytes approved in the plan. For a single
certificate the source digest binds the file passed on stdin; the helper may
still re-encode it to the target's PEM/DER format. A PEM chain is written
unchanged, so the installed file has exactly the source digest. The
caller <-> helper <-> library contract is API version 3; any other version on
either side is refused before any certificate operation.

The new certificate is passed on stdin. There is no standalone restart,
restore or install operation and no restart "allowance": a restart exists
only inside `apply-systemd`/`apply-compose`, bound to one target path, its
expected old fingerprint, the expected new fingerprint and one unit or one
compose service. A certificate supplied by the caller can therefore never be
installed as a "backup", and a replacement of certificate A never enables a
restart of an unrelated service B.

On start the helper verifies (fail closed) that it, its library and every
parent directory (`/`, `/usr`, `/usr/local`, `/usr/local/libexec`,
`/usr/local/libexec/itgo-p1cert`) are root-owned, not symlinks and not
group/world writable. It then re-validates every argument on its own:

- target: allowed roots and file-name rule, no symlink in the path, regular
  file with a single hard link; the target directory is pinned as working
  directory and must be owned by root or by the P1CERT user that called the
  helper through sudo (`SUDO_UID`, also for the scheduled run), may be
  writable by its group only when that group is `root` or the P1CERT user's
  group (`SUDO_GID`), and must never be writable by others (e.g.
  `root:root 775` and `itgo:itgo 775` are accepted, `777` is refused). In a
  directory that a non-root user can modify, the privileged operations on
  the temporary file (content write, chown, chmod, chcon) are performed only
  through the helper's own `O_EXCL` descriptor, never through a name; the
  target pre-check, the verification and the rollback use the device:inode
  identity checked before. The final `mv`/rename is still pathname-based:
  the portable Bash/coreutils implementation has no compare-and-swap
  rename, so a minimal final race window remains between the last target
  check and the rename. It concerns only a principal that can already change
  entries in that directory and cannot redirect a root write, chown, chmod
  or chcon to another file. `fs.protected_hardlinks` is therefore not
  required; `fs.protected_hardlinks=1` (default on the supported
  distributions) is still recommended as optional system hardening,
- certificates: exactly one certificate or a valid PEM chain (rules above,
  leaf used for all checks), expected new fingerprint, expected current
  fingerprint, validity, later NotAfter, identity rules above; a chain only
  into a PEM target and never a single certificate over a chain,
- systemd: valid unit name, deny-list, loaded unit from `/etc/systemd/system`,
  `/usr/lib/systemd/system` or `/lib/systemd/system`; unit, drop-in and
  environment files used as evidence must be root-owned, not group/world
  writable, and every directory from `/` down to them must be root-owned,
  not group/world writable and not a symlink (an `EnvironmentFile` in an
  application directory that a user can modify makes the helper refuse the
  automatic restart; this applies also to an optional `EnvironmentFile`
  that does not exist yet); the
  relation to the certificate must satisfy the rules described under *plan*
  (exact path in the unit configuration, or the same IntegrationPlatform
  installation directory). It is checked before the replacement and again
  right before the restart,
- Docker Compose: the project directory must contain a standard compose file
  (`compose.yaml`, `compose.yml`, `docker-compose.yaml`,
  `docker-compose.yml`); the compose files themselves are not parsed and
  `docker compose` is not run. The helper lists the running containers
  labelled with exactly that project directory and service and requires that
  each of them bind-mounts the certificate file or a directory containing it
  (below `/srv`, `/opt` or `/usr/local`; a bind of `/` or `/srv` does not
  count). Only these container ids are restarted. Docker is always called with
  an empty environment (`env -i`, fixed `PATH`, empty private
  `DOCKER_CONFIG`) and `-H unix:///var/run/docker.sock`, so `DOCKER_HOST`,
  `DOCKER_CONTEXT`, `DOCKER_CONFIG`, `COMPOSE_*` and similar variables of the
  operator are never used. The socket must be owned by root and must not be
  writable by others (the standard `root:docker 0660` is accepted),
- timer: strict date/time format; `itgo-p1cert-ezdrowie.service` and an
  existing timer must be `root:root` regular files without group/world write
  access, otherwise they are not used, replaced or removed.

Apply operations are serialized with a root-owned lock in `/run`. Once the
replacement starts, the helper ignores SIGHUP/SIGINT/SIGTERM/SIGPIPE
so that a disconnected caller cannot interrupt it between replacement,
restart and rollback. It never executes code from the P1CERT directory.

### Security model

The supported operator workflow is `scan` -> `plan` -> `run` or `schedule`.
The helper is an internal interface of `p1cert ezdrowie`, not a user
command. Because the P1CERT user has a passwordless sudo entry for it, that
user can technically call the helper directly; this is a deliberate
limitation of the model. A direct call bypasses the accepted plan, the audit
backup and the `run` logic (results, last-run state, logs) and is therefore
not a supported way of operating P1CERT. Even then the helper gives no
shell, runs no arbitrary command, validates target, certificates and service
relation itself, and offers no generic restart or restore.

If the P1CERT user is a member of the `docker` group, it can already control
the Docker daemon directly, which is practically equivalent to root. P1CERT
cannot isolate that; do not add the P1CERT user to the `docker` group unless
this is accepted.

### Limitations

- The helper is written in Bash and cannot use `openat`. Because the owner
  and group members of an accepted target directory can rename, replace or
  link any entry in it at any time, the helper never writes, chowns, chmods
  or relabels anything there by name: the replacement is created under an
  unpredictable name with `O_CREAT|O_EXCL` and kept open, and its content,
  owner, group, mode and SELinux context are applied only through that
  descriptor (`/proc/self/fd`). The target is read only with `O_NOFOLLOW`
  and `O_NONBLOCK` (`dd`). Pre-rename validation, verification and rollback
  are bound to device/inode; the final rename is pathname-based. A swap
  detected by these checks makes the operation fail.
- Final race window: there is no compare-and-swap rename in this
  implementation, so between the last target check and `mv -f -T` the owner
  or a group member of the directory can still replace the target; that
  concurrent change is then overwritten by the rename (and the following
  verification or rollback fails). Such a user can also make the operation
  fail or change the certificate after it, exactly as they could without
  P1CERT, but cannot redirect the helper's privileged content write, chown,
  chmod or SELinux relabel to another inode. The helper works only relative
  to the pinned target directory. Parent directories above it are only
  checked for symlinks; the operation itself does not depend on them after
  the directory is pinned.
- Targets in directories owned by another user, group-writable by a group
  other than `root` or the P1CERT user's group, or world writable are
  skipped and must be replaced manually. POSIX ACLs on the target directory
  are not evaluated: grant write access through them only to principals
  that may change the certificate anyway.
- The old certificate used for rollback lives only in the helper's private
  temporary directory for the duration of the operation. If the helper is
  killed with SIGKILL (or the host crashes) between replacement and rollback,
  the operator backup under `backups/ezdrowie/<timestamp>/` must be used
  manually.
- Compose restarts require the container label
  `com.docker.compose.project.working_dir` (set by Compose v2 and recent
  docker-compose v1 releases) and running containers; otherwise the helper
  refuses and the target is not changed.
- The installer copies the helper from its own source directory, so that
  directory must not be writable by the P1CERT user while the installer runs
  as root. MASTER guarantees this by staging the payload in a fresh root-only
  `/run/itgo-p1cert-stage.XXXXXX` (root `wget` from GitHub HTTPS, or a root
  copy of the offline source) and running the installer from there. A manual
  installation must likewise run from a root-owned directory. An offline
  source must be a trusted artifact: the staging prevents substitution after
  the copy, but does not prove the authenticity of the bundle itself.
- SAN parsing relies on the text output of `openssl x509 -text`; exotic SAN
  types whose printed value contains `, DNS:` could be misread. Sources are
  expected to be CA-issued ezdrowie.gov.pl certificates.

### Logs

Every command writes `logs/p1cert-ezdrowie-<command>-<timestamp>-<pid>.log`
(0600): scan, plan, run, decisions, backup, replacement, restart, rollback and
errors. The App Password is never logged.
