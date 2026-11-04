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
`4`; independent of the P1CERT version). `helper ping` prints `HELPER=OK`
and `API_VERSION=4`; `p1cert ezdrowie` and the installer accept only exactly
this version, and the helper refuses a root library with another version
(API 1, 2 and 3 components of earlier releases, as well as unknown future or
malformed versions, are incompatible).
After a partial upgrade (new scripts, old helper) `run`/`schedule` therefore
stop with "uprzywilejowany helper ma niezgodną wersję API" instead of using
an incompatible helper.

The installer ends with one of:

- `P1CERT ezdrowie system integration: READY` - the installed helper
  answers with the expected API version, `sudo -n` of the helper as the
  P1CERT user was verified (`sudo -u <user> sudo -n <helper> ping`) and the
  service unit is installed when systemd is available,
- `P1CERT ezdrowie system integration: INCOMPLETE` - followed by one line
  per problem: required command missing (installed from the distribution
  packages when possible), Java/PKCS12 tool (`P12_TOOL=NO_JAVA|NO_JAR|BAD_JAR`),
  helper missing, helper with a wrong owner or mode, helper refused to start
  (its own integrity check, with its message), another helper API (with the
  reported version), sudo missing, sudo refused (with sudo's message),
  another API through sudo, sudoers entry not installed or reverted.
  `credentials`, `test`, `scan` and `plan` still work; `run` and `schedule`
  need a compatible helper and sudoers entry. If the passwordless sudo
  access cannot be verified from the installer (for example because root's
  own `sudo -u` is blocked by `requiretty`), the result is INCOMPLETE with
  the command to check it manually.

The P1CERT files (P1 CA commands) are installed either way, but an
incomplete integration is not reported as success: the installer exits with
status 3 (other failures: 1). MASTER reports it as `P1CERT: ERROR
(installed, ezdrowie integration INCOMPLETE ...)` in the summary, still
handles the remaining modules and exits non-zero; a P1CERT installation
without the root helper or its sudoers entry counts as `BROKEN` for MASTER
and is repaired by the installer. `p1cert ezdrowie check` (as the P1CERT
user) shows the same diagnosis at any time: helper missing / wrong owner or
mode / refused to start / API, sudo missing / refused, PKCS12 tool and Java.

Java: the PKCS12 tool of the helper needs a Java runtime 8+ in a
root-controlled location (`/usr/bin/java`, `/usr/lib/jvm/*`, `/usr/java/*`,
the same rule as the helper). The installer (directly and through MASTER)
keeps a usable runtime as it is; an existing but unusable Java (older than 8,
in a location writable by others, broken) is reported and never updated,
replaced or switched (no alternatives); only a system without any Java gets
the distribution's headless OpenJDK (Debian/Ubuntu: `default-jre-headless`,
then `openjdk-21/17/11/8-jre-headless`; RHEL/Oracle Linux:
`java-21/17/11-openjdk-headless`, then `java-1.8.0-openjdk-headless`; the
first package the repositories know). `P1CERT_JAVA_INSTALL=no` only checks. An upgrade keeps credentials, config, the accepted plan, schedule
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
  lowercased and with `.`, `_` and `-` removed, contains `ezdrowie` (pattern
  `*ezdrowie*` in any case, e.g. `ezdrowiegovpl_2026.pem`, `EZdrowie.cer`,
  `e-zdrowie-p1.crt`); the name only selects candidates, every decision is
  taken from the X.509 content,
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
p1cert ezdrowie discover
p1cert ezdrowie plan
p1cert ezdrowie run [--yes]
p1cert ezdrowie schedule [YYYY-MM-DD HH:MM]
p1cert ezdrowie schedule-status
p1cert ezdrowie schedule-cancel
p1cert ezdrowie recover
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

### discover

Read-only report of Docker Compose applications and the certificates and
Java keystores they use. `discover` itself changes nothing; `plan` and `run`
use the same analysis to replace the P1 certificate of unambiguous
applications (see "Docker applications in plan and run" below).

Applications are found in two ways:

- systemd units (`/etc/systemd/system`, `/usr/lib/systemd/system`,
  `/lib/systemd/system`; deny-listed units excluded) whose `ExecStart` runs
  Docker Compose v1 (`docker-compose ...`) or v2 (`docker compose ...`),
  directly or through `/usr/bin/env` (`/usr/bin/env docker compose up`,
  `/usr/bin/env NAME=value docker-compose up`). Global options `-f/--file`,
  `-p`, `--project-directory`, `--env-file` and `--profile` are evaluated;
  relative values are relative to `WorkingDirectory` (`/` when not set),
- compose projects below `/srv`, `/usr/local` and `/opt` (depth 4) that no
  unit runs. They are listed with `Jednostka: BRAK`: P1CERT will never
  restart them.

The compose configuration is selected like docker compose does: `-f` files,
otherwise `COMPOSE_FILE` (unit environment, then `.env`;
`COMPOSE_PATH_SEPARATOR`), otherwise exactly one of `compose.yaml`,
`compose.yml`, `docker-compose.yaml`, `docker-compose.yml` plus its override
file. Later files override environment entries and mounts (by container
path). Interpolation uses the unit environment (`Environment=`,
`EnvironmentFile=`, `/usr/bin/env` assignments) before `.env`/`--env-file`
and supports `$VAR`, `${VAR}`, `${VAR:-x}`, `${VAR-x}`, `${VAR:?x}`,
`${VAR?x}`, `${VAR:+x}`, `${VAR+x}` and `$$`. Nothing is executed: no docker,
no compose, no shell.

For every service the container environment (`env_file` in order, then
`environment`) and the mounts (bind mounts in short and long syntax, named
volumes with a bind `device`, file based `secrets`/`configs`) are resolved to
host paths:

- a mount whose host or container path is a `.pem/.crt/.cer/.der/.jks/.p12/
  .pfx` file, or a mounted file whose content is a certificate or keystore,
- a variable whose value (also `file:` URLs) is such a file, or an absolute
  path in a variable whose name names a certificate or keystore (`CERT`,
  `TRUST`, `KEYSTORE`, `SSL`, `TLS`, `PEM`, `PKCS`, `P12`, `JKS`, `CA`),
  mapped through the longest matching mount; relative values use the
  service `working_dir`; without `working_dir` a relative value is resolved
  only when exactly one existing host file is reachable through a mount of
  that service (the mount target itself or a parent of it whose remaining
  components start the value: target `/app/conf/tls`, value
  `conf/tls/store.jks`), otherwise it is reported as unmapped; a path
  without a host mount is reported as inside the image,
- certificate/keystore files in mounted directories (depth 3, at most 50
  per directory).

The file name never decides the type: the content is classified as PEM/DER
X.509 (fingerprint, Subject, Not After, `ezdrowie: TAK` for an
ezdrowie.gov.pl identity such as `*.ezdrowie.gov.pl`), JKS, PKCS12 (told
from DER by its ASN.1 version, no password needed), JCEKS (not supported)
or unknown. PEM files with a private key are client material and are never
targets.

JKS and PKCS12 keystores are opened read-only (see "Keystores" below).

`discover` skips every directory whose name CONTAINS `old` in any case
(`/srv/OLD`, `/srv/oldcerts`, `/srv/app_Old`, and also names such as
`folder` or `gold`): such files are listed as skipped, such directories are
not descended and compose projects in them are not listed. The file name
itself does not count. This rule is deliberately broader than the one of
`scan`/`plan`/`run`, which still skip only components named exactly `OLD`.

A project or service is reported as
ambiguous (`NIEJEDNOZNACZNA KONFIGURACJA` / `NIEJEDNOZNACZNE`) - and will be
refused by any later replacement - when compose is started through a shell,
with `docker` global options (`-H`, `--context`), remote daemon or unknown
compose options, systemd variables in the command, several different
compose commands, several units for one project, several default compose
files, YAML anchors/aliases/merge keys, `extends`, `include`, block scalars
or flow mappings in relevant keys, multi-line values, tabs, several YAML
documents, a missing required `env_file`, an unresolved variable in a mount
or in a certificate variable, or a certificate variable whose value is not
a plain path (options, URLs, embedded passwords). One ambiguous service
makes the whole project ambiguous.

Every certificate or keystore gets `Wynik: PEWNY` only when exactly one
systemd unit runs the project(s) naming it, these projects are unambiguous
and a service names the file explicitly (mount or variable). Otherwise it is
`Wynik: NIEPEWNY` with the reasons (ambiguous project, no unit, several
units, file only present in a mounted directory).

Environment values are evaluated only inside the parser: the output, the
log and process arguments contain plain paths (characters
`A-Z a-z 0-9 . _ / @ + -`) and variable names, never other values;
`discover` writes no temporary files.

#### Keystores (JKS, PKCS12)

The store password is taken from the configuration of the service that
uses the store and bound to that store by the configuration only (never by
the order of variables, and never because a service has a single password):

1. the store is named by variable `K`: the password variable is `K` without
   a `_FILE`, `_PATH`, `_LOCATION`, `_LOC` or `_NAME` suffix, followed by
   `PASSWORD`, `PASSWD`, `PASS`, `PWD` or `PASSPHRASE` with or without `_`
   (`P1_KEYSTORE_PATH` -> `P1_KEYSTORE_PASSWORD`, `KEYSTORE_FILE` ->
   `KEYSTORE_PASS`, `JAVAX_NET_SSL_TRUSTSTORE` ->
   `JAVAX_NET_SSL_TRUSTSTOREPASSWORD`, `SERVER_SSL_KEY_STORE` ->
   `SERVER_SSL_KEY_STORE_PASSWORD`),
2. otherwise the file name without extension on the host or in the
   container, optionally with a prefix (`truststore.p12` ->
   `TRUSTSTORE_PASSWORD`, `P1_TRUSTSTORE_PASS`).

A password variable also matches by the variable it is set from
(`KS_SECRET: ${P1_KEYSTORE_PASSWORD}` matches `P1_KEYSTORE_PATH`).

The value comes from `environment`/`env_file` with the same interpolation as
above (`.env`, unit environment), or from the file named by a `<NAME>_FILE`
variable (for example a compose secret `/run/secrets/...`; its first line).
Several matching variables, different values for one store or an unreadable
value give `HASLO_NIEJEDNOZNACZNE`; no matching variable gives `BRAK_HASLA`.

- JKS (versions 1 and 2, as written by Java 8) is parsed by P1CERT itself
  (no keytool, no Java): aliases, entry types and certificates. The
  password and the integrity are verified with the JKS digest (SHA-1 over
  the password as UTF-16, the Java salt and the store); a wrong password and
  changed bytes both give `HASLO_NIEPOPRAWNE`. Without a password the
  entries are still listed, marked as not verified. Secret key entries
  (JCEKS) are not supported.
- PKCS12 is read with `openssl pkcs12 -nokeys` (private keys are never
  decrypted or printed): the MAC verifies password and integrity; stores of
  Java 8 (RC2-40/3DES) are read with `-legacy` on OpenSSL 3 and directly on
  OpenSSL 1.x. A certificate with `localKeyID` belongs to a
  `PrivateKeyEntry`, one with the Oracle trusted attribute is a
  `trustedCertEntry`, any other is a chain certificate (not a Java entry).
  A store without MAC gives `BRAK_INTEGRALNOSCI`.

Store states: `OK`, `BRAK_HASLA`, `HASLO_NIEJEDNOZNACZNE`,
`HASLO_NIEPOPRAWNE`, `USZKODZONY`, `NIEOBSLUGIWANY`, `BRAK_INTEGRALNOSCI`.

The P1 certificate is a certificate with a production ezdrowie.gov.pl
identity (DNS SANs, CN only without SANs; e.g. `*.ezdrowie.gov.pl`) that is
neither a CA nor self-signed, identified by its SHA-256 fingerprint:

- `P1: PEWNA` - one `trustedCertEntry` is the current P1 entry (alias,
  SHA-256, Not After are shown): the only one, or - with several P1 entries
  in one store - the only one still valid, or, when all have expired, the
  one with the latest Not After. The other P1 `trustedCertEntry` entries have
  all expired: the plan lists them (`usuwane wygasłe wpisy ezdrowie.gov.pl`)
  and the approved update removes exactly those (optional 6th field of
  `APP_TARGET`: their SHA-256); the helper proves before the change that they
  still are expired P1 entries of exactly the approved bytes. Private keys
  (TLS/WSS), CA, non-production and every other entry are never removed or
  changed,
- `P1: NIEPEWNA` - several P1 certificates that are still valid (also one
  under several aliases; valid entries are never removed; when one of them
  already is the selected source certificate the application is `NO
  CHANGE`, otherwise a manual decision is required), a P1 certificate
  outside any entry, an unreadable certificate or a store not verified with
  its password,
- `P1: CHRONIONY` - only inside a `PrivateKeyEntry`; entries with private
  keys are never modified,
- `P1: BRAK` - none (non-production identities such as
  `isus.ezdrowie.gov.pl` do not count).

A store is `Wynik: PEWNY` only when the configuration is certain (above),
the store is `OK` and `P1: PEWNA`; a verified store without a P1
certificate is `Wynik: NIE DOTYCZY`. The summary lists the SHA-256 of every
production ezdrowie.gov.pl certificate found in files and stores.

Passwords exist only in shell variables of the `discover` process: they
reach `openssl`, `iconv` and `openssl dgst` on standard input (`-passin
stdin`), never as an argument, an environment variable, a temporary file, a
log line or report text. `discover` never modifies keystores.

#### Docker applications in plan and run

`plan` and `run` handle Docker Compose applications next to the classic
targets. The unprivileged side only decides and reports; files are written
and units restarted exclusively by the root helper (`apply-docker`), which
derives everything again on its own.

`plan`:

- runs the discovery above and, for every application with P1 files,
  selects the source certificate from Nextcloud (`ez_fetch_remote`,
  `ez_select_remote`; one source for all files of the application) and
  compares it by SHA-256 and Not After (`ez_decide`);
- offers an application only when it has exactly one systemd unit, an
  unambiguous configuration and every P1 file `Wynik: PEWNY` (PEM/DER with a
  production ezdrowie.gov.pl identity, JKS/PKCS12 with `P1: PEWNA`); client
  keystores, `PrivateKeyEntry` entries and other certificates are never
  targets. A PKCS12 file needs the helper's Java runtime and tool (`ping`
  reports `P12_TOOL=OK`), otherwise the application is not offered;
- a file of such an application is not offered again as a classic target
  (it would split the application); files of applications that are refused
  keep the classic handling;
- shows the unit, its state, the project, all files (keystores with the P1
  alias) and the predicted restart, and asks once per application for the
  replacement of ALL its files and, only when the unit is active, for
  `systemctl restart <unit>`;
- writes `APP=<unit>|<restart yes|no>|<source fp>|<source NotAfter>|<source
  file SHA-256>` and one `APP_TARGET=<unit>|<path>|<PEM|DER|JKS|PKCS12>|<file
  SHA-256>|<old fp>|<alias|->` per file (`PLAN_VERSION=3`; a plan without
  Docker applications stays `PLAN_VERSION=2`, and version 2 plans keep
  working). The alias is the one in the store, unchanged: printable ASCII
  including spaces, brackets and `*` (`*.ezdrowie.gov.pl (certum ov tls g2
  r39 ca)`); an alias with `|`, control characters, non-ASCII bytes, `?`, a
  leading `-` or space, a trailing space or more than 128 characters is
  refused (the application is not offered).

`run` (also scheduled, with the same lock and one-shot timer):

1. asks the helper to recover interrupted Docker operations (`recover`, see
   below) and reports them;
2. runs the classic targets exactly as before;
3. for every application: the source file must be exactly the approved one
   (fingerprint and SHA-256), then one helper call
   `apply-docker <unit> <restart> <source sha256> <new fp> <file>...` with the
   source on stdin; afterwards the PEM/DER files are checked again as the
   P1CERT user.

Results per application: `UPDATED`, `NO_CHANGE`, `SKIP` (a file changed
since the plan), `REFUSED`, `ERROR` (undone before a restart), `ROLLBACK`,
`ROLLBACK_RESTART_FAILED`, `CRITICAL` (not restored or an unrecovered
operation).

#### Root helper: apply-docker

The helper trusts nothing from the caller. Before any change it:

- reads the unit with `systemctl show` and requires root-controlled unit,
  drop-in and environment files, a compose invocation it can analyse
  (`ez_dc_invocation`), an unambiguous compose configuration (`ez_dc_project`,
  `ez_dc_model`, no ambiguous service) and no other unit running the same
  project;
- requires every requested file to be referenced explicitly by that
  configuration (mount, secret or certificate variable), below the allowed
  roots, outside `old` directories, without symlinks, a single hard link, in
  a directory owned by root or the P1CERT user (`ez_target_dir_ok`);
- reads every file without following symlinks into its private directory,
  requires exactly the approved bytes (SHA-256), type and P1 certificate
  (fingerprint; keystores: the P1 alias, opened with the password it binds
  and reads itself from the compose configuration with the rules of
  `discover`), the approved source bytes, a valid, later-expiring source
  with a compatible identity and a format the target can keep;
- prepares and verifies every new file privately (`ez_dc_stage_store`: JKS
  byte surgery, PKCS12 through the tool; PEM/DER as for classic targets).

Then, as one operation:

1. a journal in `/var/lib/itgo-p1cert/ezdrowie-journal/<id>/` (root, 0700;
   files 0600, keystores included) gets the original and the new bytes and
   the state, synced before the first file changes;
2. every file is replaced with `helper_atomic_replace` (pinned directory,
   descriptor-bound write, original owner, group, mode and SELinux context),
   then all files are verified from disk (stores: password, entries, P1,
   PKCS12 compared with the original by the tool); any failure restores all
   files (`RESTORED`, exit 4) before any restart;
3. the unit is restarted only when it was `active` before the operation and
   the restart was approved; a stopped unit is never started, and a unit in
   transition (`activating`, `deactivating`, `reloading`, ...) is refused
   before any change. Before the change the helper records which services
   of the compose model have a running container of the project (label
   `com.docker.compose.project.working_dir`); an active unit without any is
   refused (the restart could not be verified). The restart counts only when
   the unit stays active and every one of these services runs again in a
   container started after the restart, not restarting and not unhealthy
   (stopped containers of these services must have exited 0 after the
   restart): the exit code of `systemctl restart` alone proves nothing for
   `docker compose up -d`. Containers of other services (orphans, inactive
   profiles, services not running before) are not judged. Only this unit is
   restarted; docker is only read (`ps`, `inspect`), never started or
   stopped directly;
4. if the restart is not effective, all files get their original bytes back
   and the unit is restarted once more (`ROLLBACK`, exit 5, or
   `ROLLBACK_RESTART_FAILED`, exit 6); a file that cannot be restored is
   `ROLLBACK_FAILED` (exit 7).

`recover` undoes every unfinished journal (SIGKILL, power loss, reboot): a
file with the new bytes gets its original bytes back, a file with the
original bytes stays, a file with other bytes is left alone and reported
(`RECOVERY=FAILED`, critical, manual action). After restoring files the unit
is restarted once (and verified like above) only when the containers may
have loaded the new files (the restart of the operation had begun, or a
container of the project started after the operation began: reboot, restart
policy), the restart had been approved, the unit was running before the
operation and is running now. A unit that is not running is never started;
when the restart was not approved this is only reported. While a journal is
unfinished, `apply-docker` refuses (exit 8); `run` calls `recover` first
(also with a plan without Docker applications: `ping` reports
`DOCKER_PENDING=<n>`), and the operator can run `p1cert ezdrowie recover`.
Recovery is not started automatically at boot. The newest 20 finished
journals stay as root-only backups.

#### PKCS12 tool

PKCS12 uses the Java KeyStore API through `p1cert-pkcs12.jar` (source
`java/P1certPkcs12.java`), because an OpenSSL export/import does not keep
the store (tested: OpenSSL 3 writes PBES2/AES that Java 8 cannot open; with
`-legacy` the Oracle trusted attribute, and with it the `trustedCertEntry`,
is lost, and friendly names, MAC parameters and the encryption of private
keys change). The tool:

- reads the store password from standard input (never an argument or an
  environment variable) and replaces only the certificate of the P1
  `trustedCertEntry`, keeping its attributes;
- never decrypts private keys: the PKCS12 provider writes the encrypted key
  bags it read back unchanged, so no key password is needed (keys with
  their own password are carried over too) and none is guessed;
- asks the runtime for the algorithms of the original (certificate
  encryption, MAC; honoured by Java 8u301+, 11.0.12+ and 17+) and proves the
  result: same aliases and entry types, same certificate chains and
  attributes, the encrypted private key bags and their attributes byte for
  byte, same algorithms. Otherwise it refuses (a secret key entry, key bags
  inside an encrypted part, BER encoding, a runtime that would change the
  algorithms or cannot open the store).

Delivery: the jar is built once with `java/build.sh` (any JDK 8+, Java 8
class files; a JDK is never needed on a server), committed as
`p1cert-pkcs12.jar`, listed in `p1cert.payload` and `release.manifest.psd1`
and pinned by its SHA-256 in the installer (`EZ_P12_JAR_SHA256`) and the
helper (`HELPER_P12_JAR_SHA256`). The installer installs it root-owned as
`/usr/local/libexec/itgo-p1cert/p1cert-pkcs12.jar` only with exactly these
bytes; the helper checks the file (root-owned, not writable by others) and
its SHA-256 before every use, and uses a Java runtime 8+ only from
root-controlled locations (`/usr/bin/java` and `/usr/lib/jvm`, `/usr/java`).
The installer installs Java only on a system without any Java (see
Install layout). Without a runtime or with another jar,
`ping` reports `P12_TOOL=NO_JAVA|NO_JAR|BAD_JAR` and applications with a
PKCS12 file are refused as a whole. Rebuilding the jar changes its SHA-256:
both pins must be updated (the tests refuse a mismatch).

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
  one unambiguous IntegrationPlatform installation (same rule as below:
  `WorkingDirectory`, every `ExecStart` command, what `/bin/sh`/`/bin/bash`
  runs) is the installation directory that contains the certificate (e.g.
  certificate `/srv/IntegrationPlatform_PI/conf/ezdrowiegovpl.pem` and
  `ExecStart=/srv/IntegrationPlatform_PI/apache-tomcat/bin/startup.sh`);
  commands outside any installation do not matter, but a unit that also
  runs or references `IntegrationPlatform_PI2`, or a command that cannot be
  analysed, is not bound; a common parent such as `/srv` is not enough;
  system units on a deny-list
  (sshd, systemd-*, docker, network, cron, ...) are never offered,
- a systemd unit of the classic Integration Platform (Tomcat `p1-war`) when
  the certificate lies outside the installation (e.g.
  `/srv/CERTYFIKATY/ezdrowieGovPl.cer`) and is named by `SSL.patch` in
  `<tomcat>/webapps/p1-war/WEB-INF/appConfig.properties` of the Tomcat
  instance the unit runs (`CATALINA_BASE`/`CATALINA_HOME` of `Environment=`,
  or the directory above `bin` of an `ExecStart` `startup.sh`, `catalina.sh`
  or `daemon.sh`; all must agree, e.g. `apache-tomcat-9.0.85`; without an
  instance `<installation>/apache-tomcat`) of exactly the installation the
  unit runs from. An installation named freely (no `IntegrationPlatform` in
  the path, e.g. `/srv/PI_EUSL/apache-tomcat`) is the directory above the
  Tomcat instance. Every service systemd knows is examined (`systemctl
  list-units`/`list-unit-files` and the unit directories), whatever its name
  (e.g. `pi_eusl.service` with
  `ExecStart=/srv/IntegrationPlatform_EUSL/apache-tomcat/bin/startup.sh` and
  `SSL.patch=/srv/CERTYFIKATY/P1/ezdrowiegovpl_2026.pem`). The installation
  tree and `appConfig.properties` may belong to root, the unit's `User=` or
  the P1CERT user (an owner of the installation the unit runs from already
  controls what it executes). A bound unit whose unit files the helper would
  not accept as root-controlled (unit file outside the systemd directories,
  symlink, writable by others) is shown as `restart ręczny` without an
  automatic restart. The binding holds for exactly the installation
  (`WorkingDirectory` / `ExecStart`, e.g.
  `WorkingDirectory=/srv/IntegrationPlatform_TST/apache-tomcat` and
  `ExecStart=/srv/IntegrationPlatform_TST/apache-tomcat/bin/startup.sh`).
  The plan then shows, for example,
  `systemctl restart pi_tst.service - p1-war/WEB-INF/appConfig.properties
  SSL.patch wskazuje certyfikat w instalacji IntegrationPlatform
  /srv/IntegrationPlatform_TST`. Rules:
  - only an active entry counts whose value, after trimming the usual
    properties whitespace (`SSL.patch=...`, `SSL.patch = ...`,
    `SSL.patch: ...`, CRLF), is exactly the certificate path; comments
    (`#`, `!`), other certificates, prefixes, suffixes (`.bak`), quotes,
    variables, `$(...)`/backticks and escapes never match - nothing is
    expanded or interpreted,
  - every `SSL.patch` entry of the file must name the certificate; an entry
    that is continued (`\` at the end of the line), a line continued from
    the previous one that looks like `SSL.patch`, a key with a backslash
    escape or a bare CR make the file unusable as evidence (fail closed),
  - the unit must run from exactly one installation (fail closed):
    `WorkingDirectory`, the executable of EVERY `ExecStart` command (one
    `ExecStart=` line per command in `systemctl show`; several
    `{ path=... }` blocks on one line are accepted too), what a shell runs and
    every absolute path in the arguments that lies below `/srv`, `/opt` or
    `/usr/local` and names an IntegrationPlatform component must all name
    the same installation (`IntegrationPlatform_PI` and
    `IntegrationPlatform_PI2` are different), and at least one of them must
    be a run path (a mere argument such as
    `rsync /srv/IntegrationPlatform_PI/conf /backup` is not enough),
  - shells (`/bin/sh`, `/bin/bash`, also in `/usr/bin`):
    `sh <absolute script> [args]` runs that script; `sh -c <command>` is
    accepted only in the narrow form of ONE simple command
    `[exec] /absolute/program [args]` made of plain words (`A-Z a-z 0-9 .
    _ / @ + = : , -`), e.g.
    `sh -c 'exec /srv/IntegrationPlatform_X/apache-tomcat/bin/startup.sh'`.
    Shell semantics are not modelled, so anything else refuses the unit
    (false negatives are accepted, false positives are not): control
    operators (`;`, `&`, `&&`, `||`, `|`), redirections, `cd`, builtins
    (`set -e`, `false`, ...), assignments, relative programs, variables
    (`$X`, `${X}`), `$(...)`, backticks, quotes, parentheses, braces, globs,
    backslashes, other shell options (`-l`, `-e`, `-ec`, ...), an
    unparseable `ExecStart` or an installation named without a plain
    absolute path; nothing is expanded or executed,
  - the existence of `appConfig.properties`, the name
    `IntegrationPlatform`, the certificate directory or a common parent such
    as `/srv` are never evidence; an `appConfig.properties` of a sibling
    installation (`IntegrationPlatform_PI2` next to `IntegrationPlatform_PI`)
    binds only the unit of that sibling,
  - `appConfig.properties` and its directories must satisfy the narrow
    application policy described under *Privileged helper* (otherwise the unit is
    not offered; the root helper would refuse it),
- Docker Compose services whose volumes, configs, secrets, `env_file`,
  environment or `.env` variables cover the file (static analysis of the
  compose file). Before a restart the helper additionally requires that the
  running containers of the service bind-mount the certificate.

An ambiguous result (several applications use the file) lists all
candidates and offers no restart at all: `NIEJEDNOZNACZNY - żadna usługa
nie zostanie zrestartowana automatycznie`; the replacement can still be
approved and the services are restarted manually. A restart is offered only
for one unambiguous, helper-verifiable unit or service. Nothing is approved
automatically. A target whose directory is
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
caller <-> helper <-> library contract is API version 4; any other version on
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
  (exact path in the unit configuration, the same IntegrationPlatform
  installation directory, or `SSL.patch` of the classic Integration
  Platform). It is checked before the replacement and again right before
  the restart,
- classic Integration Platform (`SSL.patch`): the helper derives the
  installation itself from the unit (`systemctl show`, root-controlled unit
  file as above) and reads only
  `<installation>/apache-tomcat/webapps/p1-war/WEB-INF/appConfig.properties`
  of that installation; nothing the caller found is used. This file belongs
  to the application (production: `itgo:itgo 775`), so the root-controlled
  rule above does not apply to it; instead a narrow policy used only for this
  evidence applies, with the unit's `User=` (resolved with `id`; an empty
  `User=` means root, an unknown or malformed one gives no evidence) as the
  only principal besides root:
  - `/` and every directory above the installation (e.g. `/srv`) are owned
    by root, writable by group only for the `root` group, never by others,
    not symlinks (`root:root 775` is accepted),
  - the installation directory, every directory below it down to `WEB-INF`
    and `appConfig.properties` are owned by root or by the unit user,
    writable by group only for the `root` group or the unit user's primary
    group, never by others, not symlinks (`itgo:itgo 775` with `User=itgo`
    is accepted; a tree of another user, a foreign writable group or a
    world-writable node is refused),
  - `appConfig.properties` is a regular file with one hard link, at most
    256 KiB, without NUL bytes; it is read by name from its pinned
    directory (`cd -P`, policy re-checked) with
    `O_NOFOLLOW`/`O_NONBLOCK`/`O_NOCTTY`; the entry must be the validated
    device:inode (regular file, one link) right before the open and again
    after the read, and the copy must have its size (see *Limitations* for
    the remaining window),
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
- `SSL.patch` evidence: `appConfig.properties`, controlled by the unit's
  `User=` (or root), is part of the binding proof. The application user
  alone cannot start the root helper - only the P1CERT user has the sudoers
  entry, so this needs the P1CERT permissions separately - and a restart
  happens only inside an operation started by an authorised P1CERT
  operator (plan/run/schedule, or a direct helper call by that operator).
  The P1CERT operator and `User=` of the unit may be different accounts:
  the operator can then restart a proven unit that runs as another user.
  The safety of this binding therefore rests on the combination of a
  root-controlled systemd unit, one unambiguous IntegrationPlatform
  installation derived from it, `appConfig.properties` from an application
  tree owned only by root or `User=` (with the allowed group write, e.g.
  `itgo:itgo 775`, every member of the `root` group or of the primary group
  of `User=` can modify its entries as well, and so takes part in that
  evidence), an exact `SSL.patch` value and
  the authorised caller/helper; it is not a guarantee that the evidence
  grants the application user or the operator nothing. Whoever can edit
  `appConfig.properties` (or the installation tree) can point `SSL.patch` at
  another ezdrowie certificate and so make an operator's replacement of that
  certificate restart this unit. POSIX ACLs and
  Tomcat/Spring property sources other than this one file (system
  properties, other `.properties` files, `JAVA_OPTS`) are not evaluated.
  Only the line structure of `java.util.Properties` is followed; unusual
  but valid syntax (escapes, continuation lines around `SSL.patch`) is
  refused rather than interpreted, so such a unit is simply not offered.
  Only `ExecStart` and `WorkingDirectory` are analysed (not `ExecStartPre`,
  `Environment` variables or what a script does internally); a directory
  such as `apache-tomcat` that is a symlink (e.g. to a versioned Tomcat
  directory) makes the evidence unusable.
- `appConfig.properties` read window: Bash has no `openat`/`fstat`, so the
  read is by name between two identity checks, not bound to an open
  descriptor. A symlink, FIFO or device swapped in is never followed or
  blocked on (`O_NOFOLLOW`/`O_NONBLOCK`), and a new inode, a hard link or a
  copy of another size is detected. A principal that can modify `WEB-INF`
  (by the policy root, the unit's `User=` and, with group write, members of
  the `root` group or of the primary group of `User=`) can still put another regular
  file there for the read and the validated inode back before the second
  check (A-B-A swap of the same size); its content is then used as
  evidence. The binding is checked again right before the restart, so such a
  swap has to be repeated for that check as well. That principal controls
  the real file anyway; with `fs.protected_hardlinks=0` it could also use a
  hard link to a file it cannot read, whose content is only parsed for
  `SSL.patch` and never output.
- SAN parsing relies on the text output of `openssl x509 -text`; exotic SAN
  types whose printed value contains `, DNS:` could be misread. Sources are
  expected to be CA-issued ezdrowie.gov.pl certificates.

### Logs

Every command writes `logs/p1cert-ezdrowie-<command>-<timestamp>-<pid>.log`
(0600): scan, plan, run, decisions, backup, replacement, restart, rollback and
errors. The App Password is never logged.
