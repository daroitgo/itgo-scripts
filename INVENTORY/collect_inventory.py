#!/usr/bin/env python
"""Generate a bounded, read-only Linux inventory report."""

from __future__ import print_function

import argparse
import errno
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime

try:
    string_types = (basestring,)
except NameError:
    string_types = (str,)

COLLECTOR_NAME = "itgo-infocenter-inventory"
COLLECTOR_VERSION = "0.1.0"
FORMAT_VERSION = "0.1"
COMMAND_TIMEOUT_SECONDS = 5
MAX_COMMAND_OUTPUT_CHARS = 4096
MAX_OS_RELEASE_CHARS = 65536
MAX_ITGO_IDENTITY_CHARS = 8192
MAX_WARNINGS = 32
MAX_WARNING_MESSAGE_CHARS = 200
ITGO_IDENTITY_PATH = "/home/itgo/UTILITY/ITGO-CONFIG/client-identity.json"
ITGO_CLIENT_CODE_PATTERN = re.compile(r"^[a-z0-9_-]+$")
APPLICATION_BASE_PATHS = ("/srv", "/opt")
COMPOSE_FILENAMES = (
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
)
DOCKER_EXACT_HINTS = set((
    "zm_docker",
    "p1cer",
    "erej",
    "p1erej",
    "ekrn",
    "sgds",
    "p1adapter",
))
DOCKER_CONTAINS_HINTS = ("amdx", "mpi")
SAFE_COMMAND_ENV = {
    "DOCKER_CONFIG": "/nonexistent",
    "HOME": "/nonexistent",
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}


class CommandSpec(object):
    __slots__ = ("name", "executable", "arguments", "version_parser")

    def __init__(self, name, executable, arguments, version_parser):
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.version_parser = version_parser


def add_warning(warnings, code, subject, message):
    if len(warnings) >= MAX_WARNINGS:
        return
    warnings.append(
        {
            "code": code[:64],
            "subject": subject[:64],
            "message": message[:MAX_WARNING_MESSAGE_CHARS],
        }
    )


def parse_first_match(pattern, stdout, stderr):
    bounded_text = (stdout + "\n" + stderr)[:MAX_COMMAND_OUTPUT_CHARS]
    match = re.search(pattern, bounded_text, flags=re.MULTILINE)
    if match:
        return match.group(1)
    return None


def parse_systemd_version(stdout, stderr):
    return parse_first_match(r"^systemd\s+(\S+)", stdout, stderr)


def parse_docker_version(stdout, stderr):
    return parse_first_match(r"^Docker version\s+([^,\s]+)", stdout, stderr)


def parse_compose_version(stdout, stderr):
    return parse_first_match(
        r"^(?:Docker Compose version|docker-compose version)\s+v?([^,\s]+)",
        stdout,
        stderr,
    )


def parse_java_version(stdout, stderr):
    return parse_first_match(r'^(?:openjdk|java) version "([^"]+)"', stdout, stderr)


COMMAND_SPECS = (
    CommandSpec("systemd", "systemctl", ("--version",), parse_systemd_version),
    CommandSpec("docker", "docker", ("--version",), parse_docker_version),
    CommandSpec(
        "docker-compose-plugin",
        "docker",
        ("compose", "version"),
        parse_compose_version,
    ),
    CommandSpec(
        "docker-compose",
        "docker-compose",
        ("--version",),
        parse_compose_version,
    ),
    CommandSpec("java", "java", ("-version",), parse_java_version),
)


def which(executable, path):
    for directory in path.split(os.pathsep):
        if not directory:
            continue
        candidate = os.path.join(directory, executable)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def parse_os_release_value(raw_value):
    try:
        values = shlex.split(raw_value, comments=False, posix=True)
    except ValueError:
        return None
    if len(values) != 1:
        return None
    return values[0][:256]


def read_text_file(path, limit):
    with io.open(path, "r", encoding="utf-8", errors="strict") as input_file:
        return input_file.read(limit + 1)


def read_os_release(warnings, path="/etc/os-release"):
    allowed_fields = {"ID": "id", "NAME": "name", "VERSION_ID": "version_id"}
    result = {
        "id": None,
        "name": None,
        "version_id": None,
    }

    try:
        contents = read_text_file(path, MAX_OS_RELEASE_CHARS)
    except (IOError, OSError, UnicodeError):
        add_warning(
            warnings,
            "OS_RELEASE_READ_FAILED",
            "host.os",
            "Could not read /etc/os-release safely",
        )
        return result

    if len(contents) > MAX_OS_RELEASE_CHARS:
        add_warning(
            warnings,
            "OS_RELEASE_TOO_LARGE",
            "host.os",
            "/etc/os-release exceeds the collector size limit",
        )
        return result

    for line in contents.splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        output_key = allowed_fields.get(key)
        if output_key is None:
            continue
        value = parse_os_release_value(raw_value)
        if value is None:
            add_warning(
                warnings,
                "OS_RELEASE_PARSE_ISSUE",
                "host.os." + output_key,
                "Could not parse allowlisted OS field " + key,
            )
            continue
        result[output_key] = value

    return result


def add_invalid_identity_warning(warnings, message):
    add_warning(
        warnings,
        "INVALID_ITGO_IDENTITY",
        "itgo_identity",
        message,
    )


def read_itgo_identity(warnings, path=ITGO_IDENTITY_PATH):
    try:
        exists = os.path.isfile(path)
    except OSError:
        add_invalid_identity_warning(
            warnings,
            "Could not inspect ITGO identity file",
        )
        return None

    if not exists:
        return None

    try:
        contents = read_text_file(path, MAX_ITGO_IDENTITY_CHARS)
    except (IOError, OSError, UnicodeError):
        add_invalid_identity_warning(
            warnings,
            "Could not read ITGO identity file",
        )
        return None

    if len(contents) > MAX_ITGO_IDENTITY_CHARS:
        add_invalid_identity_warning(
            warnings,
            "ITGO identity file exceeds the collector size limit",
        )
        return None

    try:
        parsed = json.loads(contents)
    except ValueError:
        add_invalid_identity_warning(
            warnings,
            "ITGO identity file is not valid JSON",
        )
        return None

    if not isinstance(parsed, dict):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity file must contain a JSON object",
        )
        return None

    schema_version = parsed.get("schema_version")
    client_code = parsed.get("client_code")
    client_name = parsed.get("client_name")
    managed_by = parsed.get("managed_by")
    created_by = parsed.get("created_by")

    if not isinstance(schema_version, string_types):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity schema_version must be a string",
        )
        return None
    if not isinstance(client_code, string_types) or not ITGO_CLIENT_CODE_PATTERN.match(
        client_code
    ):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity client_code is invalid",
        )
        return None
    if not isinstance(client_name, string_types) or not client_name:
        add_invalid_identity_warning(
            warnings,
            "ITGO identity client_name must be a non-empty string",
        )
        return None
    if managed_by is not None and not isinstance(managed_by, string_types):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity managed_by must be a string when present",
        )
        return None
    if created_by is not None and not isinstance(created_by, string_types):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity created_by must be a string when present",
        )
        return None

    identity = {
        "schema_version": schema_version,
        "client_code": client_code,
        "client_name": client_name,
        "source_path": path,
    }
    if managed_by is not None:
        identity["managed_by"] = managed_by
    if created_by is not None:
        identity["created_by"] = created_by
    return identity


def read_temp_output(temp_file):
    temp_file.seek(0)
    data = temp_file.read(MAX_COMMAND_OUTPUT_CHARS)
    if not isinstance(data, string_types):
        data = data.decode("utf-8", "replace")
    return data


def run_command_with_timeout(command, timeout_seconds, env):
    stdout_file = tempfile.TemporaryFile()
    stderr_file = tempfile.TemporaryFile()
    process = None
    try:
        process = subprocess.Popen(
            command,
            shell=False,
            stdout=stdout_file,
            stderr=stderr_file,
            env=env,
            close_fds=True,
        )
        deadline = time.time() + timeout_seconds
        while process.poll() is None:
            if time.time() >= deadline:
                try:
                    process.terminate()
                except OSError:
                    pass
                time.sleep(0.2)
                if process.poll() is None:
                    try:
                        process.kill()
                    except (AttributeError, OSError):
                        pass
                return {
                    "timeout": True,
                    "returncode": None,
                    "stdout": read_temp_output(stdout_file),
                    "stderr": read_temp_output(stderr_file),
                }
            time.sleep(0.05)

        return {
            "timeout": False,
            "returncode": process.returncode,
            "stdout": read_temp_output(stdout_file),
            "stderr": read_temp_output(stderr_file),
        }
    finally:
        if process is not None and process.poll() is None:
            try:
                process.kill()
            except (AttributeError, OSError):
                pass
        stdout_file.close()
        stderr_file.close()


def probe_command(spec, warnings):
    executable_path = which(spec.executable, SAFE_COMMAND_ENV["PATH"])
    item = {
        "source": "command",
        "source_path": executable_path,
        "name": spec.name,
        "version": None,
        "status": "not_found" if executable_path is None else "detected",
        "fields": {},
    }

    if executable_path is None:
        add_warning(
            warnings,
            "COMMAND_NOT_FOUND",
            spec.name,
            spec.executable + " is not available",
        )
        return item

    command = [executable_path] + list(spec.arguments)
    try:
        completed = run_command_with_timeout(
            command,
            COMMAND_TIMEOUT_SECONDS,
            SAFE_COMMAND_ENV,
        )
    except OSError:
        item["status"] = "failed"
        add_warning(
            warnings,
            "COMMAND_FAILED",
            spec.name,
            spec.name + " version probe could not be started",
        )
        return item

    if completed["timeout"]:
        item["status"] = "timeout"
        add_warning(
            warnings,
            "COMMAND_TIMEOUT",
            spec.name,
            spec.name + " version probe timed out",
        )
        return item

    if completed["returncode"] != 0:
        item["status"] = "failed"
        add_warning(
            warnings,
            "COMMAND_FAILED",
            spec.name,
            "%s version probe failed with exit status %s"
            % (spec.name, completed["returncode"]),
        )
        return item

    stdout = (completed["stdout"] or "")[:MAX_COMMAND_OUTPUT_CHARS]
    stderr = (completed["stderr"] or "")[:MAX_COMMAND_OUTPUT_CHARS]
    version = spec.version_parser(stdout, stderr)
    if version is None:
        item["status"] = "parse_issue"
        add_warning(
            warnings,
            "VERSION_PARSE_ISSUE",
            spec.name,
            "Could not parse " + spec.name + " version output",
        )
        return item

    item["version"] = version[:128]
    return item


def is_legacy_application_directory_name(name):
    tokens = [
        token
        for token in re.split(r"[^a-z0-9]+", name.lower())
        if token
    ]
    return "old" in tokens


def match_application_candidate(name):
    lower_name = name.lower()

    # One candidate record is emitted per directory. When a directory name could
    # match multiple families, prefer the more specific application family first.
    if name.startswith("IntegrationPlatform_"):
        return ("integration_platform", "IntegrationPlatform_*")
    if "wildfly" in lower_name:
        return ("wildfly_jboss", "contains:wildfly")
    if lower_name in DOCKER_EXACT_HINTS:
        return ("docker_compose", lower_name)
    for hint in DOCKER_CONTAINS_HINTS:
        if hint in lower_name:
            return ("docker_compose", "contains:" + hint)
    return None


def collect_compose_files(candidate_path):
    compose_files = []
    for filename in COMPOSE_FILENAMES:
        compose_path = os.path.join(candidate_path, filename)
        try:
            if os.path.isfile(compose_path):
                compose_files.append(compose_path)
        except OSError:
            continue
    return compose_files


def list_directory(path):
    try:
        return os.listdir(path), None
    except OSError as error:
        return None, error


def collect_application_candidates(warnings, base_paths=APPLICATION_BASE_PATHS):
    candidates = []

    for base_path in sorted(base_paths):
        children, error = list_directory(base_path)
        if error is not None:
            if error.errno == errno.ENOENT:
                continue
            if error.errno in (errno.EACCES, errno.EPERM):
                add_warning(
                    warnings,
                    "APPLICATION_BASE_READ_DENIED",
                    "application_candidates",
                    "Could not read allowlisted application base path",
                )
                continue
            add_warning(
                warnings,
                "APPLICATION_BASE_READ_FAILED",
                "application_candidates",
                "Could not read allowlisted application base path",
            )
            continue

        for child_name in sorted(children):
            child_path = os.path.join(base_path, child_name)
            try:
                if not os.path.isdir(child_path):
                    continue
            except OSError:
                continue

            if is_legacy_application_directory_name(child_name):
                continue

            match = match_application_candidate(child_name)
            if match is None:
                continue

            candidate_type, matched_hint = match
            fields = {
                "base_path": base_path,
                "matched_hint": matched_hint,
            }
            if candidate_type == "docker_compose":
                fields["compose_files"] = collect_compose_files(child_path)

            candidates.append(
                {
                    "source": "filesystem_allowlist",
                    "source_path": child_path,
                    "name": child_name,
                    "candidate_type": candidate_type,
                    "status": "candidate",
                    "fields": fields,
                }
            )

    return candidates


def collect_report(
    generated_at=None,
    application_base_paths=APPLICATION_BASE_PATHS,
    itgo_identity_path=ITGO_IDENTITY_PATH,
):
    warnings = []
    timestamp = generated_at or (
        datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
    )

    try:
        uname = os.uname()
        kernel = uname[2][:256]
        architecture = uname[4][:128]
    except (AttributeError, OSError):
        kernel = None
        architecture = None
        add_warning(
            warnings,
            "UNAME_FAILED",
            "host",
            "Could not read kernel and architecture information",
        )

    itgo_identity = read_itgo_identity(warnings, itgo_identity_path)

    return {
        "report": {
            "collector": {
                "name": COLLECTOR_NAME,
                "version": COLLECTOR_VERSION,
            },
            "format_version": FORMAT_VERSION,
            "generated_at": timestamp,
            "warnings": warnings,
        },
        "itgo_identity": itgo_identity,
        "host": {
            "os": read_os_release(warnings),
            "kernel": kernel,
            "architecture": architecture,
        },
        "runtimes": [probe_command(spec, warnings) for spec in COMMAND_SPECS],
        "application_candidates": collect_application_candidates(
            warnings,
            application_base_paths,
        ),
        "application_servers": {
            "tomcat": [],
            "wildfly": [],
        },
    }


def write_report(output_path, report):
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if not isinstance(payload, bytes):
        payload = payload.encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(output_path, flags, 0o600)
    try:
        try:
            os.fchmod(descriptor, 0o600)
        except (AttributeError, OSError):
            pass
        output_file = os.fdopen(descriptor, "wb")
        descriptor = -1
        try:
            output_file.write(payload)
            output_file.flush()
            os.fsync(output_file.fileno())
        finally:
            output_file.close()
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(output_path)
        except OSError:
            pass
        raise


def build_argument_parser():
    parser = argparse.ArgumentParser(
        description="Generate a read-only ITGO InfoCenter inventory JSON report."
    )
    parser.add_argument(
        "--output",
        required=True,
        help="New JSON output file; existing files are never overwritten.",
    )
    return parser


def main(argv=None):
    arguments = build_argument_parser().parse_args(argv)
    try:
        write_report(arguments.output, collect_report())
    except OSError as error:
        if getattr(error, "errno", None) == errno.EEXIST:
            print("error: output file already exists: " + arguments.output, file=sys.stderr)
            return 2
        print("error: could not write inventory report: " + str(error), file=sys.stderr)
        return 1
    except (ValueError, TypeError) as error:
        print("error: could not write inventory report: " + str(error), file=sys.stderr)
        return 1

    print("Inventory report written to " + arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
