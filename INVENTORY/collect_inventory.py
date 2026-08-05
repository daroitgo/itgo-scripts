#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import print_function

"""Generate a bounded, read-only Linux inventory report."""

import argparse
import errno
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import zipfile

COLLECTOR_NAME = "itgo-infocenter-inventory"
COLLECTOR_VERSION = "0.1.9"
FORMAT_VERSION = "0.1"
COMMAND_TIMEOUT_SECONDS = 5
MAX_COMMAND_OUTPUT_CHARS = 4096
MAX_OS_RELEASE_CHARS = 65536
MAX_ITGO_IDENTITY_CHARS = 8192
MAX_ARCHIVE_ANALYSIS_BYTES = 256 * 1024 * 1024
MAX_ARCHIVE_METADATA_ENTRY_BYTES = 1024 * 1024
MAX_NESTED_WAR_ENTRY_BYTES = 1024 * 1024 * 1024
NESTED_WAR_COPY_CHUNK_BYTES = 1024 * 1024
MAX_POM_PROPERTIES_CHARS = 8192
MAX_MPI_ENV_BYTES = 64 * 1024
MAX_EDM_ENV_BYTES = 64 * 1024
MAX_APPLICATION_ENV_BYTES = 64 * 1024
MAX_APPLICATION_COMPOSE_BYTES = 256 * 1024
MAX_INTEGRATION_WEBAPPS = 64
MAX_INTEGRATION_MAVEN_GROUP_DIRS = 32
MAX_INTEGRATION_MAVEN_ARTIFACT_DIRS = 32
MAX_WARNINGS = 32
MAX_WARNING_MESSAGE_CHARS = 200
MAX_HOSTNAME_CHARS = 255
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
    "p1rej",
    "p1ser",
    "cer",
    "ser",
    "ozr",
    "vitreo",
    "hazelcast",
}
DOCKER_CONTAINS_HINTS = ("amdx", "mpi")
MPI_ENV_VERSION_PATTERN = re.compile(
    r"^(?P<commented>#\s*)?VERSION=(?P<version>[A-Za-z0-9._-]{1,128})\s*\Z"
)
EDM_ENV_VERSION_PATTERN = re.compile(
    r"^\s*#\s*EDM_VERSION\s*:\s*(?P<version>.*?)\s*\Z"
)
AMMS_EAR_RELATIVE_PATH = (
    "wildfly-26.0.1.Final",
    "standalone",
    "deployments",
    "amms.ear",
)
AMMS_WAR_ENTRY_NAME = "amms-war.war"
AMMS_BUILD_JSON_ENTRIES = (
    "WEB-INF/classes/mspa/build.json",
    "mspa/build.json",
)
INTEGRATION_WEBAPPS_RELATIVE_PATH = ("apache-tomcat", "webapps")
INTEGRATION_MAVEN_RELATIVE_PATH = (
    "META-INF",
    "maven",
)
SAFE_COMMAND_ENV = {
    "DOCKER_CONFIG": "/nonexistent",
    "HOME": "/nonexistent",
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}

try:
    string_types = (basestring,)
except NameError:
    string_types = (str,)


class CommandSpec(object):
    __slots__ = ("name", "executable", "arguments", "version_parser")

    def __init__(
        self,
        name,
        executable,
        arguments,
        version_parser,
    ):
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.version_parser = version_parser


class CommandResult(object):
    __slots__ = ("returncode", "stdout", "stderr", "timed_out")

    def __init__(self, returncode, stdout, stderr, timed_out):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.timed_out = timed_out


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
    return match.group(1) if match else None


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


def read_utf8_text_file(path, maximum_chars):
    try:
        with open(path, "rb") as text_file:
            payload = text_file.read(maximum_chars + 1)
    except OSError:
        return None
    if len(payload) > maximum_chars:
        return None
    try:
        return payload.decode("utf-8")
    except UnicodeError:
        return None


def parse_os_release_value(raw_value):
    try:
        values = shlex.split(raw_value, comments=False, posix=True)
    except ValueError:
        return None
    if len(values) != 1:
        return None
    return values[0][:256]


def get_uname_value(uname_result, attribute_name, index):
    value = getattr(uname_result, attribute_name, None)
    if value is not None:
        return value
    try:
        return uname_result[index]
    except (IndexError, TypeError):
        return None


def bounded_string(value, maximum_chars):
    if not isinstance(value, string_types):
        return None
    return value[:maximum_chars]


def normalize_hostname(value):
    if not isinstance(value, string_types):
        return None
    hostname = value.strip()[:MAX_HOSTNAME_CHARS]
    return hostname if hostname else None


def read_os_release(warnings, path="/etc/os-release"):
    allowed_fields = {"ID": "id", "NAME": "name", "VERSION_ID": "version_id"}
    result = {
        "id": None,
        "name": None,
        "version_id": None,
    }

    contents = read_utf8_text_file(path, MAX_OS_RELEASE_CHARS)
    if contents is None:
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
                "host.os.{}".format(output_key),
                "Could not parse allowlisted OS field {}".format(key),
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
    identity_path = path
    try:
        exists = os.path.isfile(identity_path)
    except OSError:
        add_invalid_identity_warning(
            warnings,
            "Could not inspect ITGO identity file",
        )
        return None

    if not exists:
        return None

    contents = read_utf8_text_file(identity_path, MAX_ITGO_IDENTITY_CHARS)
    if contents is None:
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
        "source_path": "{}".format(identity_path),
    }
    if managed_by is not None:
        identity["managed_by"] = managed_by
    if created_by is not None:
        identity["created_by"] = created_by
    return identity


def find_executable(executable, path):
    for directory in path.split(os.pathsep):
        if not directory:
            continue
        executable_path = os.path.join(directory, executable)
        if os.path.isfile(executable_path) and os.access(executable_path, os.X_OK):
            return executable_path
    return None


def run_command_with_timeout(command, timeout_seconds):
    process = subprocess.Popen(
        command,
        shell=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=SAFE_COMMAND_ENV,
    )
    deadline = time.time() + timeout_seconds
    timed_out = False

    while process.poll() is None:
        if time.time() >= deadline:
            timed_out = True
            process.kill()
            break
        time.sleep(0.05)

    stdout, stderr = process.communicate()
    return CommandResult(process.returncode, stdout, stderr, timed_out)


def normalize_command_output(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def probe_command(spec, warnings):
    executable_path = find_executable(
        spec.executable,
        SAFE_COMMAND_ENV["PATH"],
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
            "{} is not available".format(spec.executable),
        )
        return item

    command = [executable_path] + list(spec.arguments)
    try:
        completed = run_command_with_timeout(command, COMMAND_TIMEOUT_SECONDS)
    except OSError:
        item["status"] = "failed"
        add_warning(
            warnings,
            "COMMAND_FAILED",
            spec.name,
            "{} version probe could not be started".format(spec.name),
        )
        return item

    if completed.timed_out:
        item["status"] = "timeout"
        add_warning(
            warnings,
            "COMMAND_TIMEOUT",
            spec.name,
            "{} version probe timed out".format(spec.name),
        )
        return item
    if completed.returncode != 0:
        item["status"] = "failed"
        add_warning(
            warnings,
            "COMMAND_FAILED",
            spec.name,
            "{} version probe failed with exit status {}".format(
                spec.name,
                completed.returncode,
            ),
        )
        return item

    stdout = normalize_command_output(completed.stdout)[:MAX_COMMAND_OUTPUT_CHARS]
    stderr = normalize_command_output(completed.stderr)[:MAX_COMMAND_OUTPUT_CHARS]
    version = spec.version_parser(stdout, stderr)
    if version is None:
        item["status"] = "parse_issue"
        add_warning(
            warnings,
            "VERSION_PARSE_ISSUE",
            spec.name,
            "Could not parse {} version output".format(spec.name),
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
    if lower_name.startswith("edm"):
        return ("edm", "prefix:edm")
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


def is_direct_srv_candidate(candidate_path):
    return os.path.basename(os.path.dirname(candidate_path)) == "srv"


def read_allowlisted_env_values(env_path, allowed_keys):
    """Return last nonempty active values for exact allowlisted .env keys."""
    if not is_path_file_within_limit(env_path, MAX_APPLICATION_ENV_BYTES):
        return {}
    contents = read_utf8_text_file(env_path, MAX_APPLICATION_ENV_BYTES)
    if contents is None:
        return {}
    allowed = set(allowed_keys)
    result = {}
    for line in contents.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if key not in allowed:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("\"", chr(39)):
            value = value[1:-1].strip()
        if value:
            result[key] = value[:128]
    return result


def read_allowlisted_compose_image_tags(compose_path, allowed_repositories):
    """Return last active tags for exact allowlisted image repositories."""
    if not is_path_file_within_limit(compose_path, MAX_APPLICATION_COMPOSE_BYTES):
        return {}
    contents = read_utf8_text_file(compose_path, MAX_APPLICATION_COMPOSE_BYTES)
    if contents is None:
        return {}
    allowed = set(allowed_repositories)
    result = {}
    for line in contents.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^image\s*:\s*(.*?)\s*\Z", stripped)
        if match is None:
            continue
        image = match.group(1).strip()
        if len(image) >= 2 and image[0] == image[-1] and image[0] in ("\"", chr(39)):
            image = image[1:-1]
        if not image or "@" in image or chr(36) + "{" in image:
            continue
        for repository in allowed:
            prefix = repository + ":"
            if not image.startswith(prefix):
                continue
            tag = image[len(prefix):].strip()
            if tag and not any(character.isspace() for character in tag):
                result[repository] = tag[:128]
            break
    return result


def application_version(kind, version, source_path, source_key):
    return {
        "kind": kind,
        "version": version,
        "source_path": source_path,
        "source_key": source_key,
        "source_state": "active",
    }


def read_mpi_env_version(candidate_path):
    """Read the sole allowlisted MPI application version from candidate_path/.env."""
    if os.path.basename(os.path.dirname(candidate_path)) != "srv":
        return None
    if not os.path.basename(candidate_path).lower().startswith("mpi"):
        return None

    env_path = os.path.join(candidate_path, ".env")
    if not is_path_file_within_limit(env_path, MAX_MPI_ENV_BYTES):
        return None
    contents = read_utf8_text_file(env_path, MAX_MPI_ENV_BYTES)
    if contents is None:
        return None

    for line in contents.splitlines():
        match = MPI_ENV_VERSION_PATTERN.match(line)
        if match is None:
            continue
        return {
            "kind": "mpi_env",
            "version": match.group("version"),
            "source_path": env_path,
            "source_key": "VERSION",
            "source_state": (
                "commented" if match.group("commented") is not None else "active"
            ),
        }
    return None


def read_edm_env_version(candidate_path):
    """Read the sole allowlisted EDM application version from candidate_path/.env."""
    if os.path.basename(os.path.dirname(candidate_path)) != "srv":
        return None
    if not os.path.basename(candidate_path).lower().startswith("edm"):
        return None

    env_path = os.path.join(candidate_path, ".env")
    if not is_path_file_within_limit(env_path, MAX_EDM_ENV_BYTES):
        return None
    contents = read_utf8_text_file(env_path, MAX_EDM_ENV_BYTES)
    if contents is None:
        return None

    version = None
    for line in contents.splitlines():
        match = EDM_ENV_VERSION_PATTERN.match(line)
        if match is None:
            continue
        value = match.group("version").strip()
        if value:
            version = value[:128]

    if version is None:
        return None
    return {
        "kind": "edm_env",
        "version": version,
        "source_path": env_path,
        "source_key": "EDM_VERSION",
        "source_state": "commented",
    }


def is_path_file_within_limit(path, maximum_bytes):
    try:
        stat_result = os.stat(path)
    except OSError:
        return False
    return stat_result.st_size <= maximum_bytes and os.path.isfile(path)


def find_zip_entry(archive, entry_name):
    for entry in archive.infolist():
        if entry.filename == entry_name:
            return entry
    return None


def read_zip_entry_bytes(archive, entry, maximum_bytes):
    if entry.file_size > maximum_bytes:
        return None
    entry_file = archive.open(entry)
    try:
        payload = entry_file.read(maximum_bytes + 1)
    finally:
        entry_file.close()
    if len(payload) > maximum_bytes:
        return None
    return payload


def stream_zip_entry_to_temporary_file(archive, entry, maximum_bytes):
    """Copy one bounded ZIP entry to a private temporary file in /tmp."""
    if entry.file_size > maximum_bytes:
        return None

    descriptor = None
    temporary_path = None
    entry_file = None
    temporary_file = None
    completed = False
    copied_bytes = 0
    try:
        descriptor, temporary_path = tempfile.mkstemp(
            prefix="itgo-amms-war-", dir="/tmp"
        )
        os.fchmod(descriptor, 0o600)
        temporary_file = os.fdopen(descriptor, "wb")
        descriptor = None
        entry_file = archive.open(entry)
        while True:
            chunk = entry_file.read(NESTED_WAR_COPY_CHUNK_BYTES)
            if not chunk:
                break
            copied_bytes += len(chunk)
            if copied_bytes > maximum_bytes:
                return None
            temporary_file.write(chunk)
        temporary_file.close()
        temporary_file = None
        completed = True
        return temporary_path
    except (OSError, RuntimeError, zipfile.BadZipFile):
        return None
    finally:
        if entry_file is not None:
            entry_file.close()
        if temporary_file is not None:
            temporary_file.close()
        if descriptor is not None:
            os.close(descriptor)
        if temporary_path is not None and not completed:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def read_amms_build_metadata(candidate_path):
    ear_path = os.path.join(candidate_path, *AMMS_EAR_RELATIVE_PATH)
    if not os.path.isfile(ear_path):
        return None

    ear_archive = None
    temporary_war_path = None
    try:
        ear_archive = zipfile.ZipFile(ear_path)
        war_entry = find_zip_entry(ear_archive, AMMS_WAR_ENTRY_NAME)
        if war_entry is None:
            return None
        temporary_war_path = stream_zip_entry_to_temporary_file(
            ear_archive,
            war_entry,
            MAX_NESTED_WAR_ENTRY_BYTES,
        )
        if temporary_war_path is None:
            return None
    except (OSError, zipfile.BadZipFile, RuntimeError):
        return None
    finally:
        if ear_archive is not None:
            ear_archive.close()

    war_archive = None
    try:
        war_archive = zipfile.ZipFile(temporary_war_path)
        for build_entry_name in AMMS_BUILD_JSON_ENTRIES:
            try:
                build_entry = war_archive.getinfo(build_entry_name)
            except KeyError:
                continue
            build_payload = read_zip_entry_bytes(
                war_archive,
                build_entry,
                MAX_ARCHIVE_METADATA_ENTRY_BYTES,
            )
            if build_payload is None:
                continue
            try:
                parsed = json.loads(build_payload.decode("utf-8"))
            except (UnicodeError, ValueError):
                continue
            if not isinstance(parsed, dict):
                continue
            build_number = parsed.get("buildNumber")
            build_date = parsed.get("buildDate")
            result = {
                "kind": "amms_build",
                "source_path": "{}".format(ear_path),
                "source_entry": AMMS_WAR_ENTRY_NAME + "!/" + build_entry_name,
            }
            if isinstance(build_number, string_types) and build_number:
                result["version"] = build_number[:128]
            if isinstance(build_date, string_types) and build_date:
                result["build_date"] = build_date[:128]
            if "version" in result or "build_date" in result:
                return result
    except (OSError, zipfile.BadZipFile, RuntimeError):
        return None
    finally:
        if war_archive is not None:
            war_archive.close()
        if temporary_war_path is not None:
            try:
                os.unlink(temporary_war_path)
            except OSError:
                pass

    return None


def parse_pom_properties(contents):
    result = {}
    allowed_keys = {
        "groupId": "group_id",
        "artifactId": "artifact_id",
        "version": "version",
    }
    for line in contents.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        output_key = allowed_keys.get(key.strip())
        if output_key is None:
            continue
        value = value.strip()
        if value:
            result[output_key] = value[:255]
    return result


def read_pom_properties(path):
    if not is_path_file_within_limit(path, MAX_POM_PROPERTIES_CHARS):
        return {}
    contents = read_utf8_text_file(path, MAX_POM_PROPERTIES_CHARS)
    if contents is None:
        return {}
    return parse_pom_properties(contents)


def collect_integration_webapps(candidate_path):
    webapps_path = os.path.join(candidate_path, *INTEGRATION_WEBAPPS_RELATIVE_PATH)
    try:
        children = [os.path.join(webapps_path, name) for name in os.listdir(webapps_path)]
    except OSError:
        return []

    webapps = []
    for child in sorted(children, key=lambda item: (item, os.path.basename(item))):
        if len(webapps) >= MAX_INTEGRATION_WEBAPPS:
            break
        if os.path.basename(child).lower() == "manager":
            continue
        try:
            if not os.path.isdir(child):
                continue
        except OSError:
            continue

        webapp = {
            "name": os.path.basename(child),
            "path": child,
        }
        maven_path = os.path.join(child, *INTEGRATION_MAVEN_RELATIVE_PATH)
        try:
            group_dirs = [os.path.join(maven_path, name) for name in os.listdir(maven_path)]
        except OSError:
            group_dirs = []

        checked_group_dirs = 0
        for group_dir in sorted(group_dirs, key=lambda item: (item, os.path.basename(item))):
            if checked_group_dirs >= MAX_INTEGRATION_MAVEN_GROUP_DIRS:
                break
            try:
                if not os.path.isdir(group_dir):
                    continue
            except OSError:
                continue
            checked_group_dirs += 1

            try:
                artifact_dirs = [os.path.join(group_dir, name) for name in os.listdir(group_dir)]
            except OSError:
                artifact_dirs = []

            checked_artifact_dirs = 0
            for artifact_dir in sorted(artifact_dirs, key=lambda item: (item, os.path.basename(item))):
                if checked_artifact_dirs >= MAX_INTEGRATION_MAVEN_ARTIFACT_DIRS:
                    break
                try:
                    if not os.path.isdir(artifact_dir):
                        continue
                except OSError:
                    continue
                checked_artifact_dirs += 1
                properties_path = os.path.join(artifact_dir, "pom.properties")
                metadata = read_pom_properties(properties_path)
                if not metadata or not metadata.get("version"):
                    continue
                webapp["group_id"] = metadata.get("group_id")
                webapp["artifact_id"] = metadata.get("artifact_id")
                webapp["version"] = metadata.get("version")
                webapp["source_path"] = properties_path
                break
            if "source_path" in webapp:
                break

        webapps.append(webapp)

    return webapps


def collect_integration_version_metadata(candidate_path):
    webapps = collect_integration_webapps(candidate_path)
    if not webapps:
        return None, []

    for webapp in webapps:
        version = webapp.get("version")
        if isinstance(version, string_types) and version:
            return {
                "kind": "maven",
                "version": version,
                "group_id": webapp.get("group_id"),
                "artifact_id": webapp.get("artifact_id"),
                "source_path": webapp.get("source_path"),
            }, webapps

    return None, webapps


COMPOSE_SINGLE_COMPONENTS = {
    "ekrn": "amms.asseco.pl/asseco-poz/ekrn",
    "ozr": "amms.asseco.pl/asseco-poz/pi-p1-ozr-provider",
    "vitreo": "amms.asseco.pl/asseco-poz/cpi-szrp-services",
}
EREJESTRACJA_DIRECTORIES = {
    "p1erej", "p1rej", "p1cer", "p1ser", "erej", "cer", "ser"
}
EREJESTRACJA_REPOSITORY = "amms.asseco.pl/asseco-poz/pi-p1-erejestracja-provider"
ZM_COMPONENTS = (
    ("token-generator", "TOKEN_GENERATOR_VERSION"),
    ("medical-events-data", "MEDICAL_EVENTS_DATA_VERSION"),
    ("medical-events-p1", "MEDICAL_EVENTS_P1_VERSION"),
    ("medical-events-repairer", "MEDICAL_EVENTS_REPAIRER_VERSION"),
)
HAZELCAST_COMPONENTS = (
    ("hazelcast", "hazelcast/hazelcast"),
    ("hazelcast-management-center", "hazelcast/management-center"),
)


def application_candidate(name, candidate_path, fields):
    return {
        "source": "filesystem_allowlist",
        "source_path": candidate_path,
        "name": name,
        "candidate_type": "docker_compose",
        "status": "candidate",
        "fields": fields,
    }


def special_application_candidates(candidate_path, base_path, candidate_name):
    """Return candidates for exact /srv-only version probes, or None if generic."""
    if not is_direct_srv_candidate(candidate_path):
        return None
    lower_name = candidate_name.lower()
    base_fields = {"base_path": base_path, "matched_hint": lower_name}

    if lower_name == "p1adapter":
        env_path = os.path.join(candidate_path, ".env")
        values = read_allowlisted_env_values(env_path, ("P1_ADAPTER_VERSION",))
        fields = dict(base_fields)
        if "P1_ADAPTER_VERSION" in values:
            fields["application_version"] = application_version(
                "p1adapter_env", values["P1_ADAPTER_VERSION"], env_path, "P1_ADAPTER_VERSION"
            )
        return [application_candidate(candidate_name, candidate_path, fields)]

    repository = COMPOSE_SINGLE_COMPONENTS.get(lower_name)
    if lower_name in EREJESTRACJA_DIRECTORIES:
        repository = EREJESTRACJA_REPOSITORY
    if repository is not None:
        compose_path = os.path.join(candidate_path, "docker-compose.yml")
        tags = read_allowlisted_compose_image_tags(compose_path, (repository,))
        fields = dict(base_fields)
        if repository in tags:
            fields["application_version"] = application_version(
                "compose_image", tags[repository], compose_path, repository
            )
        return [application_candidate(candidate_name, candidate_path, fields)]

    if lower_name == "zm_docker":
        env_path = os.path.join(candidate_path, ".env")
        values = read_allowlisted_env_values(
            env_path, tuple(source_key for name, source_key in ZM_COMPONENTS)
        )
        result = []
        for name, source_key in ZM_COMPONENTS:
            version = values.get(source_key)
            if version is None:
                continue
            fields = dict(base_fields)
            fields["application_version"] = application_version(
                "zm_env", version, env_path, source_key
            )
            result.append(application_candidate(name, candidate_path, fields))
        return result or None

    if lower_name == "hazelcast":
        compose_path = os.path.join(candidate_path, "docker-compose.yml")
        tags = read_allowlisted_compose_image_tags(
            compose_path, tuple(source_key for name, source_key in HAZELCAST_COMPONENTS)
        )
        result = []
        for name, source_key in HAZELCAST_COMPONENTS:
            version = tags.get(source_key)
            if version is None:
                continue
            fields = dict(base_fields)
            fields["application_version"] = application_version(
                "compose_image", version, compose_path, source_key
            )
            result.append(application_candidate(name, candidate_path, fields))
        return result or None

    return None


def collect_application_candidates(
    warnings,
    base_paths=APPLICATION_BASE_PATHS,
):
    candidates = []

    for base_path in sorted(base_paths):
        base = base_path
        try:
            children = [os.path.join(base, name) for name in os.listdir(base)]
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EPERM):
                add_warning(
                    warnings,
                    "APPLICATION_BASE_READ_DENIED",
                    "application_candidates",
                    "Could not read allowlisted application base path",
                )
            elif error.errno != errno.ENOENT:
                add_warning(
                    warnings,
                    "APPLICATION_BASE_READ_FAILED",
                    "application_candidates",
                    "Could not read allowlisted application base path",
                )
            continue

        for child in sorted(children, key=lambda item: (item, os.path.basename(item))):
            try:
                if not os.path.isdir(child):
                    continue
            except OSError:
                continue

            candidate_name = os.path.basename(child)
            if is_legacy_application_directory_name(candidate_name):
                continue
            if (
                candidate_name.lower().startswith("edm")
                and os.path.basename(base) != "srv"
            ):
                continue

            special_candidates = special_application_candidates(
                child, base, candidate_name
            )
            if special_candidates is not None:
                candidates.extend(special_candidates)
                continue

            match = match_application_candidate(candidate_name)
            if match is None:
                continue

            candidate_type, matched_hint = match
            fields = {
                "base_path": base,
                "matched_hint": matched_hint,
            }
            if candidate_type == "docker_compose":
                fields["compose_files"] = collect_compose_files(child)
                application_version = read_mpi_env_version(child)
                if application_version is not None:
                    fields["application_version"] = application_version
            elif candidate_type == "edm":
                application_version = read_edm_env_version(child)
                if application_version is not None:
                    fields["application_version"] = application_version
            elif candidate_type == "wildfly_jboss":
                application_version = read_amms_build_metadata(child)
                if application_version is not None:
                    fields["application_version"] = application_version
            elif candidate_type == "integration_platform":
                application_version, webapps = collect_integration_version_metadata(child)
                if application_version is not None:
                    fields["application_version"] = application_version
                fields["webapps"] = webapps

            candidates.append(
                {
                    "source": "filesystem_allowlist",
                    "source_path": child,
                    "name": os.path.basename(child),
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
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    )

    try:
        uname = os.uname()
        hostname = normalize_hostname(get_uname_value(uname, "nodename", 1))
        kernel = bounded_string(get_uname_value(uname, "release", 2), 256)
        architecture = bounded_string(get_uname_value(uname, "machine", 4), 128)
    except OSError:
        hostname = None
        kernel = None
        architecture = None
        add_warning(
            warnings,
            "UNAME_FAILED",
            "host",
            "Could not read uname host information",
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
            "hostname": hostname,
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
    payload = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(output_path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output_file:
            descriptor = -1
            output_file.write(payload)
            output_file.flush()
            os.fsync(output_file.fileno())
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
        type=str,
        help="New JSON output file; existing files are never overwritten.",
    )
    return parser


def main(argv=None):
    arguments = build_argument_parser().parse_args(argv)
    try:
        write_report(arguments.output, collect_report())
    except OSError as error:
        if error.errno == errno.EEXIST:
            sys.stderr.write("error: output file already exists: {}\n".format(arguments.output))
            return 2
        sys.stderr.write("error: could not write inventory report: {}\n".format(error))
        return 1
    except (ValueError, TypeError) as error:
        sys.stderr.write("error: could not write inventory report: {}\n".format(error))
        return 1

    print("Inventory report written to {}".format(arguments.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
