#!/usr/bin/env python3
"""Generate a bounded, read-only Linux inventory report."""

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

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
DOCKER_EXACT_HINTS = {
    "zm_docker",
    "p1cer",
    "erej",
    "p1erej",
    "ekrn",
    "sgds",
    "p1adapter",
}
DOCKER_CONTAINS_HINTS = ("amdx", "mpi")
SAFE_COMMAND_ENV = {
    "DOCKER_CONFIG": "/nonexistent",
    "HOME": "/nonexistent",
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}


class CommandSpec:
    __slots__ = ("name", "executable", "arguments", "version_parser")

    def __init__(
        self,
        name: str,
        executable: str,
        arguments: Tuple[str, ...],
        version_parser: Callable[[str, str], Optional[str]],
    ) -> None:
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.version_parser = version_parser


def add_warning(
    warnings: List[Dict[str, str]], code: str, subject: str, message: str
) -> None:
    if len(warnings) >= MAX_WARNINGS:
        return
    warnings.append(
        {
            "code": code[:64],
            "subject": subject[:64],
            "message": message[:MAX_WARNING_MESSAGE_CHARS],
        }
    )


def parse_first_match(pattern: str, stdout: str, stderr: str) -> Optional[str]:
    bounded_text = (stdout + "\n" + stderr)[:MAX_COMMAND_OUTPUT_CHARS]
    match = re.search(pattern, bounded_text, flags=re.MULTILINE)
    return match.group(1) if match else None


def parse_systemd_version(stdout: str, stderr: str) -> Optional[str]:
    return parse_first_match(r"^systemd\s+(\S+)", stdout, stderr)


def parse_docker_version(stdout: str, stderr: str) -> Optional[str]:
    return parse_first_match(r"^Docker version\s+([^,\s]+)", stdout, stderr)


def parse_compose_version(stdout: str, stderr: str) -> Optional[str]:
    return parse_first_match(
        r"^(?:Docker Compose version|docker-compose version)\s+v?([^,\s]+)",
        stdout,
        stderr,
    )


def parse_java_version(stdout: str, stderr: str) -> Optional[str]:
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


def parse_os_release_value(raw_value: str) -> Optional[str]:
    try:
        values = shlex.split(raw_value, comments=False, posix=True)
    except ValueError:
        return None
    if len(values) != 1:
        return None
    return values[0][:256]


def read_os_release(
    warnings: List[Dict[str, str]], path: str = "/etc/os-release"
) -> Dict[str, Optional[str]]:
    allowed_fields = {"ID": "id", "NAME": "name", "VERSION_ID": "version_id"}
    result = {
        "id": None,
        "name": None,
        "version_id": None,
    }

    try:
        with open(path, encoding="utf-8", errors="strict") as os_release_file:
            contents = os_release_file.read(MAX_OS_RELEASE_CHARS + 1)
    except (OSError, UnicodeError):
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
                f"host.os.{output_key}",
                f"Could not parse allowlisted OS field {key}",
            )
            continue
        result[output_key] = value

    return result


def add_invalid_identity_warning(
    warnings: List[Dict[str, str]], message: str
) -> None:
    add_warning(
        warnings,
        "INVALID_ITGO_IDENTITY",
        "itgo_identity",
        message,
    )


def read_itgo_identity(
    warnings: List[Dict[str, str]], path: str = ITGO_IDENTITY_PATH
) -> Optional[Dict[str, str]]:
    identity_path = Path(path)
    try:
        exists = identity_path.is_file()
    except OSError:
        add_invalid_identity_warning(
            warnings,
            "Could not inspect ITGO identity file",
        )
        return None

    if not exists:
        return None

    try:
        with identity_path.open(encoding="utf-8", errors="strict") as identity_file:
            contents = identity_file.read(MAX_ITGO_IDENTITY_CHARS + 1)
    except (OSError, UnicodeError):
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

    if not isinstance(schema_version, str):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity schema_version must be a string",
        )
        return None
    if not isinstance(client_code, str) or not ITGO_CLIENT_CODE_PATTERN.match(
        client_code
    ):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity client_code is invalid",
        )
        return None
    if not isinstance(client_name, str) or not client_name:
        add_invalid_identity_warning(
            warnings,
            "ITGO identity client_name must be a non-empty string",
        )
        return None
    if managed_by is not None and not isinstance(managed_by, str):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity managed_by must be a string when present",
        )
        return None
    if created_by is not None and not isinstance(created_by, str):
        add_invalid_identity_warning(
            warnings,
            "ITGO identity created_by must be a string when present",
        )
        return None

    identity = {
        "schema_version": schema_version,
        "client_code": client_code,
        "client_name": client_name,
        "source_path": str(identity_path),
    }
    if managed_by is not None:
        identity["managed_by"] = managed_by
    if created_by is not None:
        identity["created_by"] = created_by
    return identity


def probe_command(
    spec: CommandSpec, warnings: List[Dict[str, str]]
) -> Dict[str, Any]:
    executable_path = shutil.which(
        spec.executable,
        path=SAFE_COMMAND_ENV["PATH"],
    )
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
            f"{spec.executable} is not available",
        )
        return item

    command = [executable_path, *spec.arguments]
    try:
        completed = subprocess.run(
            command,
            shell=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
            check=False,
            env=SAFE_COMMAND_ENV,
        )
    except subprocess.TimeoutExpired:
        item["status"] = "timeout"
        add_warning(
            warnings,
            "COMMAND_TIMEOUT",
            spec.name,
            f"{spec.name} version probe timed out",
        )
        return item
    except OSError:
        item["status"] = "failed"
        add_warning(
            warnings,
            "COMMAND_FAILED",
            spec.name,
            f"{spec.name} version probe could not be started",
        )
        return item

    if completed.returncode != 0:
        item["status"] = "failed"
        add_warning(
            warnings,
            "COMMAND_FAILED",
            spec.name,
            f"{spec.name} version probe failed with exit status {completed.returncode}",
        )
        return item

    stdout = (completed.stdout or "")[:MAX_COMMAND_OUTPUT_CHARS]
    stderr = (completed.stderr or "")[:MAX_COMMAND_OUTPUT_CHARS]
    version = spec.version_parser(stdout, stderr)
    if version is None:
        item["status"] = "parse_issue"
        add_warning(
            warnings,
            "VERSION_PARSE_ISSUE",
            spec.name,
            f"Could not parse {spec.name} version output",
        )
        return item

    item["version"] = version[:128]
    return item


def is_legacy_application_directory_name(name: str) -> bool:
    tokens = [
        token
        for token in re.split(r"[^a-z0-9]+", name.lower())
        if token
    ]
    return "old" in tokens


def match_application_candidate(name: str) -> Optional[Tuple[str, str]]:
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


def collect_compose_files(candidate_path: Path) -> List[str]:
    compose_files = []  # type: List[str]
    for filename in COMPOSE_FILENAMES:
        compose_path = candidate_path / filename
        try:
            if compose_path.is_file():
                compose_files.append(str(compose_path))
        except OSError:
            continue
    return compose_files


def collect_application_candidates(
    warnings: List[Dict[str, str]],
    base_paths: Tuple[str, ...] = APPLICATION_BASE_PATHS,
) -> List[Dict[str, Any]]:
    candidates = []  # type: List[Dict[str, Any]]

    for base_path in sorted(base_paths):
        base = Path(base_path)
        try:
            children = list(base.iterdir())
        except FileNotFoundError:
            continue
        except PermissionError:
            add_warning(
                warnings,
                "APPLICATION_BASE_READ_DENIED",
                "application_candidates",
                "Could not read allowlisted application base path",
            )
            continue
        except OSError:
            add_warning(
                warnings,
                "APPLICATION_BASE_READ_FAILED",
                "application_candidates",
                "Could not read allowlisted application base path",
            )
            continue

        for child in sorted(children, key=lambda item: (str(item), item.name)):
            try:
                if not child.is_dir():
                    continue
            except OSError:
                continue

            if is_legacy_application_directory_name(child.name):
                continue

            match = match_application_candidate(child.name)
            if match is None:
                continue

            candidate_type, matched_hint = match
            fields = {
                "base_path": str(base),
                "matched_hint": matched_hint,
            }  # type: Dict[str, Any]
            if candidate_type == "docker_compose":
                fields["compose_files"] = collect_compose_files(child)

            candidates.append(
                {
                    "source": "filesystem_allowlist",
                    "source_path": str(child),
                    "name": child.name,
                    "candidate_type": candidate_type,
                    "status": "candidate",
                    "fields": fields,
                }
            )

    return candidates


def collect_report(
    generated_at: Optional[str] = None,
    application_base_paths: Tuple[str, ...] = APPLICATION_BASE_PATHS,
    itgo_identity_path: str = ITGO_IDENTITY_PATH,
) -> Dict[str, Any]:
    warnings = []  # type: List[Dict[str, str]]
    timestamp = generated_at or (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )

    try:
        uname = os.uname()
        kernel = uname.release[:256]
        architecture = uname.machine[:128]
    except OSError:
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


def write_report(output_path: Path, report: Dict[str, Any]) -> None:
    payload = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(output_path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as output_file:
            descriptor = -1
            output_file.write(payload)
            output_file.flush()
            os.fsync(output_file.fileno())
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            output_path.unlink()
        except OSError:
            pass
        raise


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a read-only ITGO InfoCenter inventory JSON report."
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="New JSON output file; existing files are never overwritten.",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    arguments = build_argument_parser().parse_args(argv)
    try:
        write_report(arguments.output, collect_report())
    except FileExistsError:
        print(f"error: output file already exists: {arguments.output}", file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError) as error:
        print(f"error: could not write inventory report: {error}", file=sys.stderr)
        return 1

    print(f"Inventory report written to {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
