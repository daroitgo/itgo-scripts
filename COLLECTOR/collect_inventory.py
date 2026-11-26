#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Generate a bounded, read-only Linux inventory report."""

from __future__ import print_function

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
COLLECTOR_VERSION = "0.1.26"
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
MAX_GENERIC_COMPOSE_IMAGES = 64
MAX_COMPOSE_IMAGE_REFERENCE_CHARS = 512
MAX_COMPOSE_IMAGE_REPOSITORY_CHARS = 255
MAX_COMPOSE_IMAGE_TAG_CHARS = 128
MAX_MEMINFO_BYTES = 64 * 1024
MAX_INTEGRATION_WEBAPPS = 64
MAX_INTEGRATION_MAVEN_GROUP_DIRS = 32
MAX_INTEGRATION_MAVEN_ARTIFACT_DIRS = 32
MAX_APPLICATION_BASE_CHILDREN = 1024
MAX_APPLICATION_SCAN_DEPTH = 2
MAX_APPLICATION_DIRECTORIES = 4096
MAX_WARNINGS = 32
MAX_WARNING_MESSAGE_CHARS = 200
MAX_HOSTNAME_CHARS = 255
ITGO_IDENTITY_PATH = "/home/itgo/UTILITY/ITGO-CONFIG/client-identity.json"
ITGO_CLIENT_CODE_PATTERN = re.compile(r"^[a-z0-9_-]+$")
APPLICATION_BASE_PATHS = ("/srv", "/usr/local", "/usr/app", "/app", "/usr", "/opt")
APPLICATION_EXCLUDED_PATHS = ("/opt/containerd", "/srv/keystores")
SYSTEM_APPLICATION_DIRECTORY_NAMES = frozenset((
    "bin", "etc", "games", "include", "lib", "lib32", "lib64", "libexec",
    "sbin", "share", "src", "var",
))
PSIM2_EDM_DIRECTORY_NAMES = ("edm", "edm_psim2")
COMPOSE_FILENAMES = (
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
)
NBK_COMPOSE_FILENAME = "docker-compose.yml"
NBK_APPLICATION_VERSION_SELECTORS = (
    "BK_FRONT_VERSION",
    "SEROLOGY_FRONT_VERSION",
    "BT_FRONT_VERSION",
    "PLATFORM_APP_VERSION",
    "MESSAGES_APP_VERSION",
    "BK_APP_VERSION",
    "SEROLOGY_APP_VERSION",
    "BT_APP_VERSION",
    "SYNC_KEYCLOAK_APP_VERSION",
)
NBK_VERSION_PATTERN = re.compile(r"^v?(\d+\.\d+\.\d+\.p\d+)\Z")

# Compiled from docs/collectors/version-source-rule-catalog.json schema 1.0.
# Only matrix entries with readiness=ready are included here. Product entries
# remain implemented by the specialist detectors below.
CATALOG_SCHEMA_VERSION = "1.0"
CATALOG_READY_MATRIX_RULE_COUNT = 71
CATALOG_READY_PRODUCT_RULE_COUNT = 11
CATALOG_UNRESOLVED_RULE_COUNT = 7
CATALOG_RULE_ID_PREFIX = "version-source-catalog-1.0:"
CATALOG_READY_PRODUCT_RULE_IDS = (
    "amdx", "amms", "hazelcast", "hazelcast-management-center",
    "integration-platform", "mpi", "mswia-edm", "nbk", "p1-adapter", "psim2-edm",
    "token-generator",
)
CATALOG_UNRESOLVED_RULE_IDS = (
    "athos-mobit", "cpi-mpi-services", "hl7-proxy", "pi-hurtownie-provider",
    "pi-wwks2", "si-crt-provider", "lab",
)
CATALOG_INFRASTRUCTURE_SERVICE_NAMES = frozenset((
    "db", "database", "cache", "postgres", "postgresql", "redis",
    "elasticsearch", "logstash", "kibana", "nginx",
))

# These observations describe locally declared Elastic technology versions,
# not product versions that can be compared with the release matrix.
ELASTIC_TECHNOLOGY_SERVICES = {
    "si-elastic-client": ("filebeat",),
    "si-elastic-server": ("elasticsearch", "kibana"),
}
ELASTIC_TECHNOLOGY_VERSION_SELECTOR = "ELASTIC_VERSION"

# component_id, Compose path, ENV path, exact tag variable, directory aliases.
# A None alias tuple is allowed only for a component-specific variable and
# still requires a direct Compose image-tag binding.
CATALOG_ENV_RULES = (
    ("bosk", "docker-compose.yml", ".env", "BOSK_VERSION", ("bosk", "bosk-docker")),
    ("cpi-hl7-services", "docker-compose.yml", ".env", "CPI_VERSION", ("cpi-hl7-services",)),
    ("cpi-xml-services", "docker-compose.yml", ".env", "CPI_VERSION", ("cpi-xml-services",)),
    ("csi-amms-rest-services", "docker-compose.yml", ".env", "IMAGE_VERSION", ("csi-amms-rest-services",)),
    ("medical-events-data", "start_docker/docker-compose.yml", "start_docker/.env", "MEDICAL_EVENTS_DATA_VERSION", None),
    ("medical-events-p1", "start_docker/docker-compose.yml", "start_docker/.env", "MEDICAL_EVENTS_P1_VERSION", None),
    ("medical-events-repairer", "start_docker/docker-compose.yml", "start_docker/.env", "MEDICAL_EVENTS_REPAIRER_VERSION", None),
    ("pi-hl7-provider", "docker-compose.yml", ".env", "PI_VERSION", ("pi-hl7-provider",)),
    ("pi-xml-provider", "docker-compose.yml", ".env", "PI_VERSION", ("pi-xml-provider",)),
    ("si-accept", "docker-compose.yml", ".env", "PI_VERSION", ("si-accept",)),
    ("si-adm-nbk", "docker-compose.yml", ".env", "PI_VERSION", ("si-adm-nbk",)),
    ("si-ai-services", "docker-compose.yml", ".env", "PI_VERSION", ("si-ai-services",)),
    ("si-amms-push-service", "docker-compose.yml", ".env", "PI_VERSION", ("si-amms-push-service",)),
    ("si-athos", "docker-compose.yml", ".env", "PI_VERSION", ("si-athos",)),
    ("si-auth-service", "docker-compose.yml", ".env", "PI_VERSION", ("si-auth-service",)),
    ("si-certificate", "docker-compose.yml", ".env", "PI_VERSION", ("si-certificate",)),
    ("si-certum", "docker-compose.yml", ".env", "PI_VERSION", ("si-certum",)),
    ("si-connector", "docker-compose.yml", ".env", "PI_VERSION", ("si-connector",)),
    ("si-data-storage-service", "docker-compose.yml", ".env", "PI_VERSION", ("si-data-storage-service",)),
    ("si-documents-utility", "docker-compose.yml", ".env", "PI_VERSION", ("si-documents-utility",)),
    ("si-epuap", "docker-compose.yml", ".env", "PI_VERSION", ("si-epuap",)),
    ("si-identitymanager", "docker-compose.yml", ".env", "PI_VERSION", ("si-identitymanager",)),
    ("si-lab-integration", "docker-compose.yml", ".env", "PI_VERSION", ("si-lab-integration",)),
    ("si-mf-gov", "docker-compose.yml", ".env", "PI_VERSION", ("si-mf-gov",)),
    ("si-mhosp", "docker-compose.yml", ".env", "PI_VERSION", ("si-mhosp",)),
    ("si-mpi", "docker-compose.yml", ".env", "PI_VERSION", ("si-mpi",)),
    ("si-nfz", "docker-compose.yml", ".env", "PI_VERSION", ("si-nfz",)),
    ("si-nmvs", "docker-compose.yml", ".env", "PI_VERSION", ("si-nmvs",)),
    ("si-notifications", "docker-compose.yml", ".env", "PI_VERSION", ("si-notifications",)),
    ("si-notifications-adm", "docker-compose.yml", ".env", "PI_VERSION", ("si-notifications-adm",)),
    ("si-oplatomat", "docker-compose.yml", ".env", "PI_VERSION", ("si-oplatomat",)),
    ("si-p1-ewp", "docker-compose.yml", ".env", "PI_VERSION", ("si-p1-ewp",)),
    ("si-p1-medical-events", "docker-compose.yml", ".env", "PI_VERSION", ("si-p1-medical-events",)),
    ("si-p1-services", "docker-compose.yml", ".env", "PI_VERSION", ("si-p1-services",)),
    ("si-pdf-generator", "docker-compose.yml", ".env", "PI_VERSION", ("si-pdf-generator",)),
    ("si-pharmacy-services", "docker-compose.yml", ".env", "PI_VERSION", ("si-pharmacy-services",)),
    ("si-pharmindex-service", "docker-compose.yml", ".env", "PI_VERSION", ("si-pharmindex-service", "si-pharmaindex-service")),
    ("si-pue", "docker-compose.yml", ".env", "PI_VERSION", ("si-pue",)),
    ("si-rpl-import", "docker-compose.yml", ".env", "PI_VERSION", ("si-rpl-import",)),
    ("si-rpwdl", "docker-compose.yml", ".env", "PI_VERSION", ("si-rpwdl",)),
    ("si-simple", "docker-compose.yml", ".env", "PI_VERSION", ("si-simple",)),
    ("si-teryt-service", "docker-compose.yml", ".env", "PI_VERSION", ("si-teryt-service",)),
    ("si-topsor", "docker-compose.yml", ".env", "PI_VERSION", ("si-topsor",)),
    ("si-zsmopl-integration-multiclient", "docker-compose.yml", ".env", "PI_VERSION", ("si-zsmopl-integration-multiclient",)),
)

# Component-specific ENV variants whose identity additionally requires one exact
# Compose service. Multiple rows may represent one component; seen_components
# keeps the emitted observation singular when layouts overlap.
# component_id, Compose path, ENV path, exact tag variable, aliases, exact service.
CATALOG_EXACT_SERVICE_ENV_RULES = (
    (
        "si-amms-services", "docker-compose.yml", ".env",
        "ASVC_SERVICE_VERSION", ("si-amms-services",), "si-amms-services-app",
    ),
    (
        "si-amms-services", "docker-compose.yml", ".env",
        "PI_VERSION", ("si-amms-services",), "si-amms-services",
    ),
)

# Exact-service ENV rules whose service/Compose evidence is part of the emitted
# contract and is independently allowlisted by the backend.
CATALOG_STRICT_SERVICE_ENV_RULES = (
    (
        "si-zsmopl-integration", "docker-compose.yml", ".env",
        "PI_VERSION", ("si-zsmopl-integration",),
        "si-zsmopl-integration-app",
    ),
)

# One matrix component whose authoritative version is shared by two application
# services. Both exact services must bind their own exact ENV variable directly
# in the image tag. A singular version is emitted only when both local values
# agree; otherwise both observations are retained as an explicit ambiguity.
# component_id, Compose path, ENV path, aliases, ((service, variable), ...).
CATALOG_PAIRED_ENV_RULES = (
    (
        "si-aism",
        "si-aism/docker-compose.yml",
        "si-aism/.env",
        ("si-aism",),
        (
            ("asi-backend", "ASI_BACKEND_SERVICE_VERSION"),
            ("asi-frontend", "ASI_FRONTEND_SERVICE_VERSION"),
        ),
    ),
)

# Installer module metadata is distinct from the executable technology image
# tag. Identity requires the exact installation directory and Compose service;
# every allowlisted metadata value must be present, valid and equal. Unequal
# values are retained as an ambiguity rather than choosing one source.
# component_id, Compose path, aliases, exact service,
# ((source role, ENV path, selector), ...).
CATALOG_MODULE_METADATA_RULES = (
    (
        "si-aism-db",
        "si-aism-db/docker-compose.yml",
        ("si-aism-db",),
        "asi-db",
        (
            ("application_module", "si-aism-db/common.env", "APP_VERSION"),
            (
                "installer_module",
                "si-aism-db/installer.env",
                "INSTALL_ENV_MODULE_VERSION",
            ),
        ),
    ),
    (
        "si-aism-keycloak",
        "si-aism-keycloak/docker-compose.yml",
        ("si-aism-keycloak",),
        "keycloak",
        (
            ("application_module", "si-aism-keycloak/common.env", "APP_VERSION"),
            (
                "installer_module",
                "si-aism-keycloak/installer.env",
                "INSTALL_ENV_MODULE_VERSION",
            ),
        ),
    ),
    (
        "si-reverse-proxy",
        "si-reverse-proxy/docker-compose.yml",
        ("si-reverse-proxy", "si-aism-reverse-proxy"),
        "nginx",
        (
            (
                "installer_module",
                "si-reverse-proxy/installer.env",
                "INSTALL_ENV_MODULE_VERSION",
            ),
        ),
    ),
)

# component_id, Compose path, exact direct service name. The repeated SDIP id
# represents the catalog's explicitly approved alternative deployment layout.
CATALOG_LITERAL_RULES = (
    ("cpi-sdip-services", "full-stack/docker-compose.yml", "cpi-sdip-services"),
    ("cpi-sdip-services", "sdip-provider/docker-compose.yml", "cpi-sdip-services"),
    ("cpi-szrp-services", "docker-compose.yml", "cpi-szrp-services"),
    ("ekrn", "docker-compose.yml", "ekrn"),
    ("p1-ozr-provider", "docker-compose.yml", "pi-p1-ozr-provider"),
    ("pi-kuj-pom-provider", "docker-compose.yml", "pi-kuj-pom-provider"),
    ("pi-lab-medical-events", "docker-compose.yml", "pi-lab-medical-events"),
    ("pi-lok-provider", "docker-compose.yml", "pi-lok-provider"),
    ("pi-mon-eanalizy", "e-Analizy/docker-compose.yml", "pi-mon-eanalizy"),
    ("pi-mon-provider", "e-Rejestracja/docker-compose.yml", "pi-mon-provider"),
    ("pi-msim-provider", "docker-compose.yml", "pi-msim"),
    ("pi-mswia-eanalizy", "e-analizy/docker-compose.yml", "pi-mswia-eanalizy"),
    ("pi-mswia-provider", "e-rejestracja/docker-compose.yml", "pi-mswia"),
    ("pi-p1-erejestracja-provider", "docker-compose.yml", "pi-p1-erejestracja-provider"),
    ("pi-p1-ksk-provider", "docker-compose.yml", "pi-p1-ksk-provider"),
    ("pi-p1-kso-provider", "docker-compose.yml", "pi-p1-kso-provider"),
    ("pi-p1-sgsds-provider", "docker-compose.yml", "pi-p1-sgsds-provider"),
    ("pi-p1-zlk-provider", "docker-compose.yml", "pi-p1-zlk-provider"),
    ("pi-psim2-epn-provider", "EPN/docker-compose.yml", "pi-psim2-epn-provider"),
    ("pi-psim-2-provider", "e-Rejestracja_e-Kontrahent/docker-compose.yml", "pi-psim-2-provider"),
    ("pi-sam", "docker-compose.yml", "pi-sam-provider"),
    ("pi-steryl", "docker-compose.yml", "pi-steryl"),
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
    "epn",
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
NON_PRIMARY_APPLICATION_SUFFIX_PATTERN = re.compile(
    r"_(?:new|old|backup|bak)\d*$",
    re.IGNORECASE,
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


def probe_command(spec, warnings, warn_not_found=True):
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
        if warn_not_found:
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


def collect_runtimes(warnings):
    runtimes = []
    compose_plugin_detected = False
    for spec in COMMAND_SPECS:
        warn_not_found = not (
            spec.name == "docker-compose" and compose_plugin_detected
        )
        runtime = probe_command(spec, warnings, warn_not_found=warn_not_found)
        runtimes.append(runtime)
        if spec.name == "docker-compose-plugin":
            compose_plugin_detected = runtime["status"] == "detected"
    return runtimes


def is_non_primary_application_directory_name(name):
    return NON_PRIMARY_APPLICATION_SUFFIX_PATTERN.search(name) is not None


def is_excluded_application_path(path):
    normalized_path = os.path.normpath(path)
    for excluded_path in APPLICATION_EXCLUDED_PATHS:
        normalized_excluded = os.path.normpath(excluded_path)
        if normalized_path == normalized_excluded:
            return True
        if normalized_path.startswith(normalized_excluded + os.sep):
            return True
    return False


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


def read_allowlisted_env_values(env_path, allowed_keys, include_empty=False):
    """Return last active values for exact allowlisted .env keys."""
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
        if value or include_empty:
            result[key] = value[:128]
    return result


def resolve_allowlisted_compose_registry(image, registry_values):
    """Resolve only a leading Compose DOCKER_REGISTRY interpolation."""
    marker = "${DOCKER_REGISTRY"
    if not image.startswith(marker):
        return image
    closing = image.find("}", len(marker))
    if closing < 0:
        return None
    expression_tail = image[len(marker):closing]
    operator = None
    word = ""
    for candidate_operator in (":-", ":?", ":+", "-", "?", "+"):
        if expression_tail.startswith(candidate_operator):
            operator = candidate_operator
            word = expression_tail[len(candidate_operator):]
            break
    if operator is None and expression_tail:
        return None
    if len(word) > 128 or any(character in word for character in ("$", "{", "}")):
        return None

    is_set = "DOCKER_REGISTRY" in registry_values
    value = registry_values.get("DOCKER_REGISTRY", "")
    is_nonempty = is_set and bool(value)
    if operator is None:
        registry = value if is_set else None
    elif operator == "-":
        registry = value if is_set else word
    elif operator == ":-":
        registry = value if is_nonempty else word
    elif operator == "?":
        registry = value if is_set else None
    elif operator == ":?":
        registry = value if is_nonempty else None
    elif operator == "+":
        registry = word if is_set else ""
    else:
        registry = word if is_nonempty else ""

    if not isinstance(registry, string_types) or not re.match(
        r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z", registry
    ):
        return None
    suffix = image[closing + 1:]
    if not suffix.startswith("/"):
        return None
    return registry + suffix


def read_allowlisted_compose_images(compose_path, allowed_repositories):
    """Return recognized exact repositories and their optional literal tags."""
    if not is_path_file_within_limit(compose_path, MAX_APPLICATION_COMPOSE_BYTES):
        return {}
    contents = read_utf8_text_file(compose_path, MAX_APPLICATION_COMPOSE_BYTES)
    if contents is None:
        return {}
    registry_values = read_allowlisted_env_values(
        os.path.join(os.path.dirname(compose_path), ".env"),
        ("DOCKER_REGISTRY",),
        include_empty=True,
    )
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
        quote = None
        if len(image) >= 2 and image[0] == image[-1] and image[0] in ("\"", chr(39)):
            quote = image[0]
            image = image[1:-1]
        if not image:
            continue
        image = (
            None
            if quote == chr(39) and image.startswith("${DOCKER_REGISTRY")
            else resolve_allowlisted_compose_registry(image, registry_values)
        )
        if image is None:
            continue
        for repository in allowed:
            prefix = repository + ":"
            if image == repository or image.startswith(repository + "@"):
                result[repository] = None
                break
            if not image.startswith(prefix):
                continue
            tag = image[len(prefix):].strip()
            if (
                tag
                and chr(36) + "{" not in tag
                and "@" not in tag
                and not any(character.isspace() for character in tag)
            ):
                result[repository] = tag[:128]
            else:
                result[repository] = None
            break
    return result


def read_allowlisted_compose_image_tags(compose_path, allowed_repositories):
    """Return last active literal tags for exact allowlisted image repositories."""
    images = read_allowlisted_compose_images(compose_path, allowed_repositories)
    return dict(
        (repository, tag)
        for repository, tag in images.items()
        if tag is not None
    )


def is_valid_compose_repository(repository):
    if (
        not repository
        or len(repository) > MAX_COMPOSE_IMAGE_REPOSITORY_CHARS
        or any(character.isspace() for character in repository)
        or any(character in repository for character in ("$", "{", "}", "@"))
    ):
        return False
    parts = repository.split("/")
    if any(not part for part in parts):
        return False
    first_name = parts[0]
    if ":" in first_name:
        first_name, port = first_name.rsplit(":", 1)
        if (
            not port.isdigit()
            or not 1 <= len(port) <= 5
            or not 1 <= int(port) <= 65535
        ):
            return False
    component_pattern = r"^[a-z0-9]+(?:[._-]+[a-z0-9]+)*\Z"
    return bool(first_name and re.match(component_pattern, first_name)) and all(
        re.match(component_pattern, part) is not None for part in parts[1:]
    )


def parse_generic_compose_image(raw_image, registry_values, quote):
    if not raw_image or len(raw_image) > MAX_COMPOSE_IMAGE_REFERENCE_CHARS:
        return None
    if quote == chr(39) and raw_image.startswith("${DOCKER_REGISTRY"):
        return None
    image = resolve_allowlisted_compose_registry(raw_image, registry_values)
    if image is None or len(image) > MAX_COMPOSE_IMAGE_REFERENCE_CHARS:
        return None
    if any(character.isspace() for character in image):
        return None

    reference = image
    if "@" in reference:
        repository, digest = reference.rsplit("@", 1)
        if not re.match(r"^sha256:[0-9a-f]{64}\Z", digest):
            return None
        reference = repository

    repository = reference
    tag = None
    last_slash = reference.rfind("/")
    last_colon = reference.rfind(":")
    if last_colon > last_slash:
        repository = reference[:last_colon]
        candidate_tag = reference[last_colon + 1:]
        if (
            len(candidate_tag) <= MAX_COMPOSE_IMAGE_TAG_CHARS
            and re.match(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z", candidate_tag)
        ):
            tag = candidate_tag
        elif not any(character in candidate_tag for character in ("$", "{", "}")):
            return None

    if not is_valid_compose_repository(repository):
        return None
    result = {"repository": repository}
    if tag is not None:
        result["tag"] = tag
    return result


def read_generic_compose_images(compose_path):
    """Return whether bounded Compose structure exists and safe observations."""
    if not is_path_file_within_limit(compose_path, MAX_APPLICATION_COMPOSE_BYTES):
        return False, []
    contents = read_utf8_text_file(compose_path, MAX_APPLICATION_COMPOSE_BYTES)
    if contents is None:
        return False, []
    registry_values = read_allowlisted_env_values(
        os.path.join(os.path.dirname(compose_path), ".env"),
        ("DOCKER_REGISTRY",),
        include_empty=True,
    )
    has_services_section = False
    has_service_declaration = False
    in_services_section = False
    service_indentation = None
    field_indentation = None
    current_service = False
    current_service_has_image = False
    ambiguous_structure = False
    images = []
    for line in contents.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        leading = line[:len(line) - len(line.lstrip())]
        if "\t" in leading:
            if in_services_section:
                ambiguous_structure = True
                break
            continue
        indentation = len(line) - len(line.lstrip())
        if indentation == 0:
            if stripped == "services:":
                if has_services_section:
                    ambiguous_structure = True
                    break
                has_services_section = True
                in_services_section = True
                continue
            in_services_section = False
            current_service = False
            continue

        if not in_services_section:
            continue

        service_match = re.match(
            r"^(?P<key>[A-Za-z0-9][A-Za-z0-9_.-]*)\s*:\s*\Z", stripped
        )
        if service_indentation is None:
            if service_match is None:
                ambiguous_structure = True
                break
            service_indentation = indentation
            current_service = not service_match.group("key").casefold().startswith("x-")
            if current_service:
                has_service_declaration = True
            current_service_has_image = False
            field_indentation = None
            continue

        if indentation < service_indentation:
            ambiguous_structure = True
            break
        if indentation == service_indentation:
            if service_match is None:
                ambiguous_structure = True
                break
            current_service = not service_match.group("key").casefold().startswith("x-")
            if current_service:
                has_service_declaration = True
            current_service_has_image = False
            field_indentation = None
            continue
        if not current_service:
            continue

        field_match = re.match(
            r"^(?P<key>[A-Za-z0-9][A-Za-z0-9_.-]*)\s*:\s*(?P<value>.*?)\s*\Z",
            stripped,
        )
        if field_indentation is None:
            if field_match is None:
                ambiguous_structure = True
                break
            field_indentation = indentation
        elif indentation < field_indentation:
            ambiguous_structure = True
            break

        if indentation != field_indentation:
            continue
        if field_match is None:
            ambiguous_structure = True
            break
        if field_match.group("key") != "image":
            continue
        if current_service_has_image:
            ambiguous_structure = True
            break
        current_service_has_image = True
        image = field_match.group("value").strip()
        quote = None
        if len(image) >= 2 and image[0] == image[-1] and image[0] in ("\"", chr(39)):
            quote = image[0]
            image = image[1:-1]
        if not image:
            continue
        observation = parse_generic_compose_image(image, registry_values, quote)
        if observation is not None:
            observation["source_path"] = compose_path
            images.append(observation)
    if ambiguous_structure:
        images = []
    return has_services_section and has_service_declaration, images


def read_catalog_compose_services(compose_path):
    """Read only direct service image expressions from unambiguous Compose."""
    if not is_path_file_within_limit(compose_path, MAX_APPLICATION_COMPOSE_BYTES):
        return False, {}
    contents = read_utf8_text_file(compose_path, MAX_APPLICATION_COMPOSE_BYTES)
    if contents is None:
        return False, {}

    has_services_section = False
    has_service_declaration = False
    in_services_section = False
    service_indentation = None
    field_indentation = None
    current_service = None
    current_service_has_image = False
    seen_services = set()
    images = {}
    ambiguous_structure = False

    for line in contents.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        leading = line[:len(line) - len(line.lstrip())]
        if "\t" in leading:
            if in_services_section:
                ambiguous_structure = True
                break
            continue
        indentation = len(line) - len(line.lstrip())
        if indentation == 0:
            if stripped == "services:":
                if has_services_section:
                    ambiguous_structure = True
                    break
                has_services_section = True
                in_services_section = True
                continue
            in_services_section = False
            current_service = None
            continue

        if not in_services_section:
            continue

        service_match = re.match(
            r"^(?P<key>[A-Za-z0-9][A-Za-z0-9_.-]*)\s*:\s*\Z", stripped
        )
        if service_indentation is None:
            if service_match is None:
                ambiguous_structure = True
                break
            service_indentation = indentation
        elif indentation < service_indentation:
            ambiguous_structure = True
            break

        if indentation == service_indentation:
            if service_match is None:
                ambiguous_structure = True
                break
            service_name = service_match.group("key")
            if service_name in seen_services:
                ambiguous_structure = True
                break
            seen_services.add(service_name)
            current_service = (
                None if service_name.casefold().startswith("x-") else service_name
            )
            if current_service is not None:
                has_service_declaration = True
            current_service_has_image = False
            field_indentation = None
            continue

        if current_service is None:
            continue

        field_match = re.match(
            r"^(?P<key>[A-Za-z0-9][A-Za-z0-9_.-]*)\s*:\s*(?P<value>.*?)\s*\Z",
            stripped,
        )
        if field_indentation is None:
            if field_match is None:
                ambiguous_structure = True
                break
            field_indentation = indentation
        elif indentation < field_indentation:
            ambiguous_structure = True
            break

        if indentation != field_indentation:
            continue
        if field_match is None:
            ambiguous_structure = True
            break
        if field_match.group("key") != "image":
            continue
        if current_service_has_image:
            ambiguous_structure = True
            break
        current_service_has_image = True

        image = field_match.group("value").strip()
        quote = None
        if len(image) >= 2 and image[0] == image[-1] and image[0] in ("\"", chr(39)):
            quote = image[0]
            image = image[1:-1]
        if image and len(image) <= MAX_COMPOSE_IMAGE_REFERENCE_CHARS:
            images[current_service] = (image, quote)

    if ambiguous_structure:
        return False, {}
    return has_services_section and has_service_declaration, images


def catalog_tag_variables(image, quote):
    """Return exact variables used in a Compose image tag, never its repository."""
    if quote == chr(39) or not image or len(image) > MAX_COMPOSE_IMAGE_REFERENCE_CHARS:
        return set()
    last_segment = image.rsplit("/", 1)[-1]
    if ":" not in last_segment:
        return set()
    tag = last_segment.split(":", 1)[-1]
    variables = set()
    pattern = re.compile(
        r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?:(?::?[-+?])[^}]*)?\}|([A-Za-z_][A-Za-z0-9_]*))"
    )
    for match in pattern.finditer(tag):
        variables.add(match.group(1) or match.group(2))
    return variables


def is_catalog_infrastructure_service(service):
    normalized = service.casefold().replace("_", "-")
    parts = tuple(part for part in normalized.split("-") if part)
    return any(part in CATALOG_INFRASTRUCTURE_SERVICE_NAMES for part in parts)


def catalog_path_candidates(candidate_path, relative_path, aliases=None):
    """Resolve a fixed catalog path at a package root or at its named subroot."""
    if (
        not relative_path
        or os.path.isabs(relative_path)
        or os.path.normpath(relative_path).startswith(".." + os.sep)
        or os.path.normpath(relative_path) == ".."
    ):
        return []
    normalized = os.path.normpath(relative_path)
    results = [os.path.join(candidate_path, normalized)]
    parts = normalized.split(os.sep)
    candidate_name = os.path.basename(candidate_path)
    direct_root_match = (
        len(parts) > 1
        and parts[0].casefold().replace("_", "-")
        == candidate_name.casefold().replace("_", "-")
    )
    if len(parts) > 1 and aliases is not None:
        approved_aliases = tuple(
            alias.casefold().replace("_", "-") for alias in aliases
        )
        direct_root_match = (
            catalog_directory_matches(candidate_path, aliases)
            and parts[0].casefold().replace("_", "-") in approved_aliases
        )
    if direct_root_match:
        direct_path = os.path.join(candidate_path, *parts[1:])
        if direct_path not in results:
            results.append(direct_path)
    return results


def catalog_directory_matches(candidate_path, aliases):
    if aliases is None:
        return True
    name = os.path.basename(candidate_path).casefold().replace("_", "-")
    approved_aliases = tuple(
        alias.casefold().replace("_", "-") for alias in aliases
    )
    return name in approved_aliases


def catalog_application_version(
    component_id,
    method,
    version,
    source_path,
    source_selector,
    evidence_kind,
):
    return {
        "kind": method,
        "component_id": component_id,
        "rule_id": CATALOG_RULE_ID_PREFIX + component_id,
        "version": version,
        "source_path": source_path,
        "source_key": source_selector,
        "source_selector": source_selector,
        "source_state": "active",
        "evidence_kind": evidence_kind,
    }


def is_exact_nbk_installation(candidate_path, base_path):
    """Match only the confirmed /usr/app/nbk installation layout."""
    normalized_candidate = os.path.normpath(candidate_path)
    normalized_base = os.path.normpath(base_path)
    return (
        os.path.dirname(normalized_candidate) == normalized_base
        and os.path.basename(normalized_candidate).casefold() == "nbk"
        and os.path.basename(normalized_base).casefold() == "app"
        and os.path.basename(os.path.dirname(normalized_base)).casefold() == "usr"
    )


def read_nbk_compose_version(candidate_path, base_path, warnings):
    """Read the NBK business version from all approved application tags."""
    if not is_exact_nbk_installation(candidate_path, base_path):
        return None
    compose_path = os.path.join(candidate_path, NBK_COMPOSE_FILENAME)
    if not os.path.isfile(compose_path):
        return None

    fields = {
        "base_path": base_path,
        "matched_hint": "nbk_compose",
        "compose_files": [compose_path],
    }
    recognized, services = read_catalog_compose_services(compose_path)
    if not recognized:
        fields["catalog_version_observations"] = []
        fields["catalog_version_resolution"] = "invalid"
        add_warning(
            warnings,
            "NBK_COMPOSE_INVALID",
            compose_path,
            "NBK Compose structure is invalid or exceeds the safe read limit.",
        )
        return application_candidate("nbk", candidate_path, fields)

    allowed_selectors = set(NBK_APPLICATION_VERSION_SELECTORS)
    observations = []
    invalid_selectors = set()
    selector_counts = {}
    for service in sorted(services):
        image, quote = services[service]
        used_selectors = catalog_tag_variables(image, quote) & allowed_selectors
        if not used_selectors:
            continue
        last_segment = image.rsplit("/", 1)[-1]
        tag = last_segment.split(":", 1)[-1] if ":" in last_segment else ""
        for selector in sorted(used_selectors):
            selector_counts[selector] = selector_counts.get(selector, 0) + 1
            expression = re.match(
                r"^\$\{" + re.escape(selector) + r":-([^{}]+)\}\Z",
                tag,
            )
            version = None
            if expression is not None:
                version_match = NBK_VERSION_PATTERN.match(expression.group(1))
                if version_match is not None:
                    version = version_match.group(1)
            if version is None:
                invalid_selectors.add(selector)
            observations.append(
                {
                    "service": service,
                    "selector": selector,
                    "version": version,
                    "source_path": compose_path,
                    "image_selector": "services.{}.image.tag".format(service),
                }
            )

    observed_selectors = set(selector_counts)
    missing_selectors = sorted(allowed_selectors - observed_selectors)
    duplicate_selectors = sorted(
        selector for selector, count in selector_counts.items() if count != 1
    )
    fields["catalog_version_observations"] = observations

    if missing_selectors or invalid_selectors:
        fields["catalog_version_resolution"] = "incomplete"
        fields["missing_or_invalid_selectors"] = sorted(
            set(missing_selectors) | invalid_selectors
        )
        add_warning(
            warnings,
            "NBK_VERSION_INCOMPLETE",
            compose_path,
            "NBK application image tags do not contain all approved version defaults.",
        )
        return application_candidate("nbk", candidate_path, fields)

    versions = set(item["version"] for item in observations)
    if duplicate_selectors or len(versions) != 1:
        fields["catalog_version_resolution"] = "ambiguous"
        if duplicate_selectors:
            fields["duplicate_selectors"] = duplicate_selectors
        add_warning(
            warnings,
            "NBK_VERSION_AMBIGUOUS",
            compose_path,
            "NBK application image tags declare inconsistent versions.",
        )
        return application_candidate("nbk", candidate_path, fields)

    version = observations[0]["version"]
    application_version_value = catalog_application_version(
        "nbk",
        "catalog_compose_default",
        version,
        compose_path,
        "NBK_APPLICATION_VERSION_DEFAULTS",
        "local_compose_application_tag_defaults_equal",
    )
    application_version_value["source_state"] = "declared_default"
    fields["application_version"] = application_version_value
    fields["catalog_version_resolution"] = "matched"
    return application_candidate("nbk", candidate_path, fields)


def catalog_component_candidate(
    component_id, candidate_path, base_path, version, extra_fields=None
):
    fields = {
        "base_path": base_path,
        "matched_hint": "catalog_rule",
        "product_identity": {
            "kind": "catalog_component",
            "source_key": component_id,
        },
    }
    if version is not None:
        fields["application_version"] = version
    if extra_fields:
        fields.update(extra_fields)
    return {
        "source": "filesystem_allowlist",
        "source_path": candidate_path,
        "name": component_id,
        "candidate_type": "catalog_component",
        "status": "candidate",
        "fields": fields,
    }


def collect_catalog_application_candidates(candidate_path, base_path):
    """Apply only compiled ready rules and emit at most one entry per component."""
    results = []
    seen_components = set()
    compose_cache = {}

    def compose_services(path):
        if path not in compose_cache:
            compose_cache[path] = read_catalog_compose_services(path)
        return compose_cache[path]

    env_rules = tuple(rule + (None, False) for rule in CATALOG_ENV_RULES)
    env_rules += tuple(rule + (False,) for rule in CATALOG_EXACT_SERVICE_ENV_RULES)
    env_rules += tuple(rule + (True,) for rule in CATALOG_STRICT_SERVICE_ENV_RULES)
    for (
        component_id,
        compose_relative,
        env_relative,
        variable,
        aliases,
        exact_service,
        strict_service_evidence,
    ) in env_rules:
        if component_id in seen_components:
            continue
        if not catalog_directory_matches(candidate_path, aliases):
            continue
        compose_paths = catalog_path_candidates(
            candidate_path, compose_relative, aliases
        )
        env_paths = catalog_path_candidates(candidate_path, env_relative, aliases)
        matched_compose_path = None
        for compose_path in compose_paths:
            recognized, services = compose_services(compose_path)
            if not recognized:
                continue
            if exact_service is None:
                has_binding = any(
                    not is_catalog_infrastructure_service(service)
                    and variable in catalog_tag_variables(image, quote)
                    for service, (image, quote) in services.items()
                )
            else:
                service_image = services.get(exact_service)
                has_binding = service_image is not None and variable in (
                    catalog_tag_variables(service_image[0], service_image[1])
                )
            if has_binding:
                matched_compose_path = compose_path
                break
        if matched_compose_path is None:
            continue

        env_path = None
        version = None
        for candidate_env_path in env_paths:
            values = read_allowlisted_env_values(candidate_env_path, (variable,))
            candidate_version = values.get(variable)
            if candidate_version is None or re.match(
                r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z", candidate_version
            ) is None:
                continue
            env_path = candidate_env_path
            version = candidate_version
            break
        if env_path is None:
            continue

        application_version_value = catalog_application_version(
            component_id,
            "catalog_env",
            version,
            env_path,
            variable,
            (
                "local_exact_service_compose_env_binding"
                if strict_service_evidence
                else "local_compose_env_binding"
            ),
        )
        extra_fields = None
        if strict_service_evidence:
            extra_fields = {
                "catalog_compose_binding": {
                    "service": exact_service,
                    "compose_path": matched_compose_path,
                    "image_selector": "services.{}.image.tag".format(exact_service),
                }
            }
        results.append(
            catalog_component_candidate(
                component_id,
                candidate_path,
                base_path,
                application_version_value,
                extra_fields,
            )
        )
        seen_components.add(component_id)

    for (
        component_id,
        compose_relative,
        env_relative,
        aliases,
        bindings,
    ) in CATALOG_PAIRED_ENV_RULES:
        if component_id in seen_components:
            continue
        if not catalog_directory_matches(candidate_path, aliases):
            continue
        matched_compose_path = None
        for compose_path in catalog_path_candidates(
            candidate_path, compose_relative, aliases
        ):
            recognized, services = compose_services(compose_path)
            if not recognized:
                continue
            if all(
                service in services
                and variable
                in catalog_tag_variables(
                    services[service][0],
                    services[service][1],
                )
                for service, variable in bindings
            ):
                matched_compose_path = compose_path
                break
        if matched_compose_path is None:
            continue

        variables = tuple(variable for _service, variable in bindings)
        matched_env_path = None
        values = None
        for env_path in catalog_path_candidates(candidate_path, env_relative, aliases):
            candidate_values = read_allowlisted_env_values(env_path, variables)
            if all(
                variable in candidate_values
                and re.match(
                    r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z",
                    candidate_values[variable],
                )
                is not None
                for variable in variables
            ):
                matched_env_path = env_path
                values = candidate_values
                break
        if matched_env_path is None or values is None:
            continue

        observations = []
        for service, variable in bindings:
            observations.append(
                {
                    "service": service,
                    "selector": variable,
                    "version": values[variable],
                    "source_path": matched_env_path,
                    "compose_path": matched_compose_path,
                    "image_selector": "services.{}.image.tag".format(service),
                }
            )
        distinct_versions = set(item["version"] for item in observations)
        resolution = "matched" if len(distinct_versions) == 1 else "ambiguous"
        application_version_value = None
        if resolution == "matched":
            application_version_value = catalog_application_version(
                component_id,
                "catalog_env",
                observations[0]["version"],
                matched_env_path,
                "+".join(variables),
                "local_compose_env_bindings_equal",
            )
        results.append(
            catalog_component_candidate(
                component_id,
                candidate_path,
                base_path,
                application_version_value,
                {
                    "catalog_version_observations": observations,
                    "catalog_version_resolution": resolution,
                },
            )
        )
        seen_components.add(component_id)

    for (
        component_id,
        compose_relative,
        aliases,
        exact_service,
        metadata_sources,
    ) in CATALOG_MODULE_METADATA_RULES:
        if component_id in seen_components:
            continue
        if not catalog_directory_matches(candidate_path, aliases):
            continue
        matched_compose_path = None
        for compose_path in catalog_path_candidates(
            candidate_path, compose_relative, aliases
        ):
            recognized, services = compose_services(compose_path)
            if recognized and exact_service in services:
                matched_compose_path = compose_path
                break
        if matched_compose_path is None:
            continue

        observations = []
        metadata_complete = True
        for source_role, env_relative, variable in metadata_sources:
            matched_env_path = None
            version = None
            for env_path in catalog_path_candidates(
                candidate_path, env_relative, aliases
            ):
                values = read_allowlisted_env_values(env_path, (variable,))
                candidate_version = values.get(variable)
                if candidate_version is None or re.match(
                    r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z",
                    candidate_version,
                ) is None:
                    continue
                matched_env_path = env_path
                version = candidate_version
                break
            if matched_env_path is None or version is None:
                metadata_complete = False
                break
            observations.append(
                {
                    "source_role": source_role,
                    "service": exact_service,
                    "selector": variable,
                    "version": version,
                    "source_path": matched_env_path,
                    "compose_path": matched_compose_path,
                }
            )
        if not metadata_complete:
            continue

        distinct_versions = set(item["version"] for item in observations)
        resolution = "matched" if len(distinct_versions) == 1 else "ambiguous"
        application_version_value = None
        if resolution == "matched":
            application_version_value = catalog_application_version(
                component_id,
                "catalog_env",
                observations[0]["version"],
                observations[0]["source_path"],
                "+".join(item["selector"] for item in observations),
                "local_module_metadata_values",
            )
        results.append(
            catalog_component_candidate(
                component_id,
                candidate_path,
                base_path,
                application_version_value,
                {
                    "catalog_module_version_observations": observations,
                    "catalog_version_resolution": resolution,
                },
            )
        )
        seen_components.add(component_id)

    for component_id, compose_relative, service in CATALOG_LITERAL_RULES:
        if component_id in seen_components:
            continue
        for compose_path in catalog_path_candidates(candidate_path, compose_relative):
            recognized, services = compose_services(compose_path)
            if not recognized or service not in services:
                continue
            image, quote = services[service]
            registry_values = read_allowlisted_env_values(
                os.path.join(os.path.dirname(compose_path), ".env"),
                ("DOCKER_REGISTRY",),
                include_empty=True,
            )
            if quote == chr(39) and image.startswith("${DOCKER_REGISTRY"):
                observation = None
            else:
                resolved_image = resolve_allowlisted_compose_registry(
                    image,
                    registry_values,
                )
                observation = (
                    parse_generic_compose_image(resolved_image, {}, quote)
                    if resolved_image is not None
                    else None
                )
            if observation is None or "tag" not in observation:
                continue
            selector = "services.{}.image.tag".format(service)
            application_version_value = catalog_application_version(
                component_id,
                "catalog_compose_image",
                observation["tag"],
                compose_path,
                selector,
                "local_compose_literal_tag",
            )
            results.append(
                catalog_component_candidate(
                    component_id,
                    candidate_path,
                    base_path,
                    application_version_value,
                )
            )
            seen_components.add(component_id)
            break

    return results


def generic_compose_candidate(candidate_path, base_path, candidate_name, warnings):
    compose_files = []
    images = []
    seen_images = set()
    image_limit_warned = False
    for compose_path in collect_compose_files(candidate_path):
        is_compose_file, observations = read_generic_compose_images(compose_path)
        if not is_compose_file:
            continue
        compose_files.append(compose_path)
        for observation in observations:
            key = (observation["repository"], observation.get("tag"))
            if key in seen_images:
                continue
            if len(images) >= MAX_GENERIC_COMPOSE_IMAGES:
                if not image_limit_warned:
                    add_warning(
                        warnings,
                        "APPLICATION_COMPOSE_IMAGE_LIMIT",
                        candidate_name,
                        "Application Compose image limit reached",
                    )
                    image_limit_warned = True
                continue
            seen_images.add(key)
            images.append(observation)
    if not compose_files:
        return None
    fields = {
        "base_path": base_path,
        "matched_hint": "generic_compose",
        "compose_files": compose_files,
        "compose_images": images,
    }
    technology_fields = collect_elastic_technology_fields(
        candidate_path, candidate_name
    )
    if technology_fields is not None:
        fields.update(technology_fields)
    return application_candidate(
        candidate_name,
        candidate_path,
        fields,
    )


def collect_elastic_technology_fields(candidate_path, candidate_name):
    """Read an Elastic version only from exact service image-tag bindings."""
    component_id = candidate_name.casefold()
    required_services = ELASTIC_TECHNOLOGY_SERVICES.get(component_id)
    if (
        required_services is None
        or os.path.basename(candidate_path).casefold() != component_id
    ):
        return None

    selector = ELASTIC_TECHNOLOGY_VERSION_SELECTOR
    matched_compose_path = None
    for compose_path in collect_compose_files(candidate_path):
        recognized, services = read_catalog_compose_services(compose_path)
        if not recognized:
            continue
        if all(
            service in services
            and selector
            in catalog_tag_variables(services[service][0], services[service][1])
            for service in required_services
        ):
            matched_compose_path = compose_path
            break
    if matched_compose_path is None:
        return None

    env_path = os.path.join(candidate_path, ".env")
    version = read_allowlisted_env_values(env_path, (selector,)).get(selector)
    if version is None or re.match(
        r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z", version
    ) is None:
        return None

    observations = [
        {
            "service": service,
            "selector": selector,
            "version": version,
            "source_path": env_path,
            "compose_path": matched_compose_path,
            "image_selector": "services.{}.image.tag".format(service),
        }
        for service in required_services
    ]
    return {
        "technology_version": {
            "kind": "compose_env",
            "component_id": component_id,
            "version": version,
            "source_path": env_path,
            "source_key": selector,
            "source_selector": selector,
            "source_state": "active",
            "evidence_kind": "local_exact_service_compose_env_binding",
            "declaration_origin": "local_configuration",
        },
        "technology_version_observations": observations,
        "technology_version_resolution": "matched",
    }


def collect_cpu_logical_count(warnings):
    try:
        value = os.cpu_count()
    except (AttributeError, OSError):
        value = None
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        add_warning(
            warnings,
            "CPU_COUNT_UNAVAILABLE",
            "host.cpu_logical_count",
            "Could not determine the logical CPU count",
        )
        return None
    return value


def read_memory_total_bytes(warnings, path="/proc/meminfo"):
    contents = read_utf8_text_file(path, MAX_MEMINFO_BYTES)
    if contents is None:
        add_warning(
            warnings,
            "MEMINFO_READ_FAILED",
            "host.memory_total_bytes",
            "Could not read /proc/meminfo safely",
        )
        return None
    for line in contents.splitlines():
        match = re.match(r"^MemTotal:\s*([0-9]+)\s+kB\s*\Z", line)
        if match is None:
            continue
        kilobytes = int(match.group(1))
        if kilobytes > 0:
            return kilobytes * 1024
        break
    add_warning(
        warnings,
        "MEMTOTAL_PARSE_ISSUE",
        "host.memory_total_bytes",
        "Could not parse MemTotal from /proc/meminfo",
    )
    return None


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
PSIM2_EDM_COMPONENTS = (
    ("Eureka", "EUREKA_VERSION"),
    ("API Gateway", "APIGATEWAY_VERSION"),
    ("Regional EDM Adapter", "REGIONAL_EDM_ADAPTER_VERSION"),
)
PSIM2_EDM_REPOSITORIES = (
    "amms.asseco.pl/asseco-poz/eureka",
    "amms.asseco.pl/asseco-poz/api-gateway",
    "amms.asseco.pl/asseco-poz/regional-edm-adapter",
)
PSIM2_EPN_REPOSITORY = "amms.asseco.pl/asseco-poz/pi-psim2-epn-provider"
PSIM2_EREJ_REPOSITORY = "amms.asseco.pl/asseco-poz/pi-psim-2-provider"
MSWIA_EANALIZY_REPOSITORY = "amms.asseco.pl/asseco-poz/pi-mswia-eanalizy"
MSWIA_EREJ_REPOSITORY = "amms.asseco.pl/asseco-poz/pi-mswia-provider"
KNOWN_REGIONAL_COMPOSE_REPOSITORIES = PSIM2_EDM_REPOSITORIES + (
    PSIM2_EPN_REPOSITORY,
    PSIM2_EREJ_REPOSITORY,
    MSWIA_EANALIZY_REPOSITORY,
    MSWIA_EREJ_REPOSITORY,
    EREJESTRACJA_REPOSITORY,
)
CATALOG_SPECIALIST_COMPOSE_COMPONENTS = {
    COMPOSE_SINGLE_COMPONENTS["ekrn"]: "ekrn",
    COMPOSE_SINGLE_COMPONENTS["ozr"]: "p1-ozr-provider",
    COMPOSE_SINGLE_COMPONENTS["vitreo"]: "cpi-szrp-services",
    EREJESTRACJA_REPOSITORY: "pi-p1-erejestracja-provider",
    PSIM2_EPN_REPOSITORY: "pi-psim2-epn-provider",
    PSIM2_EREJ_REPOSITORY: "pi-psim-2-provider",
    MSWIA_EANALIZY_REPOSITORY: "pi-mswia-eanalizy",
    MSWIA_EREJ_REPOSITORY: "pi-mswia-provider",
    "hazelcast/hazelcast": "hazelcast",
    "hazelcast/management-center": "hazelcast-management-center",
}
CATALOG_SPECIALIST_ZM_COMPONENTS = dict(
    (source_key, name) for name, source_key in ZM_COMPONENTS
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


def add_catalog_source_metadata(version, component_id, selector, evidence_kind):
    """Add the C2A provenance contract without removing legacy fields."""
    version["component_id"] = component_id
    version["rule_id"] = CATALOG_RULE_ID_PREFIX + component_id
    if "source_key" not in version:
        version["source_key"] = selector
    version["source_selector"] = selector
    if "source_state" not in version:
        version["source_state"] = "active"
    version["evidence_kind"] = evidence_kind


def enrich_specialist_catalog_metadata(candidates):
    """Add catalog provenance to exact established detectors, in place."""
    for candidate in candidates:
        fields = candidate.get("fields")
        if not isinstance(fields, dict):
            continue
        version = fields.get("application_version")
        if isinstance(version, dict) and "component_id" not in version:
            kind = version.get("kind")
            source_key = version.get("source_key")
            component_id = None
            selector = source_key
            evidence_kind = "local_specialist_detector"
            if kind == "amms_build":
                component_id = "amms"
                selector = "$.buildNumber"
                evidence_kind = "local_nested_archive_json"
            elif kind == "maven":
                component_id = "integration-platform"
                selector = "version"
                evidence_kind = "local_maven_metadata"
            elif kind == "mpi_env":
                component_id = "mpi"
            elif kind == "edm_env":
                component_id = "amdx"
            elif kind == "p1adapter_env":
                component_id = "p1-adapter"
            elif kind == "mswia_edm":
                component_id = "mswia-edm"
            elif kind == "zm_env":
                component_id = CATALOG_SPECIALIST_ZM_COMPONENTS.get(source_key)
            elif kind == "compose_image":
                component_id = CATALOG_SPECIALIST_COMPOSE_COMPONENTS.get(source_key)
            if component_id is not None and selector is not None:
                add_catalog_source_metadata(
                    version,
                    component_id,
                    selector,
                    evidence_kind,
                )

        if fields.get("product_identity") == {
            "kind": "psim2_edm",
            "source_key": "PSIM2_EDM",
        }:
            for component in fields.get("components", ()):
                if not isinstance(component, dict):
                    continue
                selector = component.get("source_key")
                if selector is None:
                    continue
                add_catalog_source_metadata(
                    component,
                    "psim2-edm",
                    selector,
                    "local_psim2_env_signature",
                )

        if candidate.get("candidate_type") == "integration_platform":
            for webapp in fields.get("webapps", ()):
                if not isinstance(webapp, dict) or "version" not in webapp:
                    continue
                add_catalog_source_metadata(
                    webapp,
                    "integration-platform",
                    "version",
                    "local_maven_metadata",
                )
    return candidates


def psim2_edm_candidate(candidate_path, base_path, warnings, compose_files):
    env_path = os.path.join(candidate_path, ".env")
    source_keys = tuple(source_key for name, source_key in PSIM2_EDM_COMPONENTS)
    values = read_allowlisted_env_values(env_path, source_keys)
    components = []
    for name, source_key in PSIM2_EDM_COMPONENTS:
        components.append(
            {
                "name": name,
                "version": values.get(source_key),
                "source_key": source_key,
                "source_path": env_path,
            }
        )
    if len(values) < len(PSIM2_EDM_COMPONENTS):
        add_warning(
            warnings,
            "PSIM2_EDM_COMPONENTS_INCOMPLETE",
            "PSIM2 EDM",
            "One or more PSIM2 EDM component versions are unavailable",
        )
    return {
        "source": "filesystem_allowlist",
        "source_path": candidate_path,
        "name": os.path.basename(candidate_path),
        "candidate_type": "psim2_edm",
        "status": "candidate",
        "fields": {
            "base_path": base_path,
            "matched_hint": "psim2_edm_compose",
            "compose_files": compose_files,
            "product_identity": {
                "kind": "psim2_edm",
                "source_key": "PSIM2_EDM",
            },
            "components": components,
        },
    }


def legacy_edm_application_candidates(candidate_path, base_path):
    candidates = []
    legacy_version = read_edm_env_version(candidate_path)
    if legacy_version is not None:
        candidates.append(
            {
                "source": "filesystem_allowlist",
                "source_path": candidate_path,
                "name": os.path.basename(candidate_path),
                "candidate_type": "edm",
                "status": "candidate",
                "fields": {
                    "base_path": base_path,
                    "matched_hint": "prefix:edm",
                    "application_version": legacy_version,
                },
            }
        )
    return candidates


def compose_product_candidate(
    candidate_name,
    candidate_path,
    base_fields,
    repository,
    tag,
    compose_path,
    include_product_identity,
):
    fields = dict(base_fields)
    if include_product_identity:
        fields["product_identity"] = {
            "kind": "compose_image",
            "source_key": repository,
        }
    if tag is not None:
        fields["application_version"] = application_version(
            "compose_image",
            tag,
            compose_path,
            repository,
        )
    return application_candidate(candidate_name, candidate_path, fields)


def read_known_regional_compose_images(candidate_path):
    """Read only allowlisted image repositories from supported Compose files."""
    compose_files = collect_compose_files(candidate_path)
    images = {}
    source_paths = {}
    for compose_path in compose_files:
        found = read_allowlisted_compose_images(
            compose_path, KNOWN_REGIONAL_COMPOSE_REPOSITORIES
        )
        for repository, tag in found.items():
            if repository not in images or (images[repository] is None and tag is not None):
                images[repository] = tag
                source_paths[repository] = compose_path
    return compose_files, images, source_paths


def mswia_edm_candidate(
    candidate_path,
    base_path,
    compose_files,
    image_tag,
    image_source_path,
):
    env_path = os.path.join(candidate_path, ".env")
    env_values = read_allowlisted_env_values(
        env_path, ("REGIONAL_EDM_ADAPTER_VERSION",)
    )
    version = image_tag or env_values.get("REGIONAL_EDM_ADAPTER_VERSION")
    version_source_path = image_source_path if image_tag is not None else env_path
    fields = {
        "base_path": base_path,
        "matched_hint": "mswia_edm_compose",
        "compose_files": compose_files,
        "product_identity": {
            "kind": "mswia_edm",
            "source_key": "MSWIA_EDM",
        },
    }
    if version is not None:
        fields["application_version"] = application_version(
            "mswia_edm", version, version_source_path, "MSWIA_EDM"
        )
    return {
        "source": "filesystem_allowlist",
        "source_path": candidate_path,
        "name": os.path.basename(candidate_path),
        "candidate_type": "mswia_edm",
        "status": "candidate",
        "fields": fields,
    }


def classify_known_regional_compose(
    candidate_path, base_path, candidate_name, warnings
):
    """Return the resolution state and candidates for known Compose signatures."""
    compose_files, images, source_paths = read_known_regional_compose_images(
        candidate_path
    )
    if not images:
        return None

    present = set(images)
    if present == set((EREJESTRACJA_REPOSITORY,)):
        return None
    edm_repositories = set(PSIM2_EDM_REPOSITORIES)
    present_edm = present.intersection(edm_repositories)
    regional_adapter = PSIM2_EDM_REPOSITORIES[2]
    recognized = []
    partial_edm = False

    if present_edm == edm_repositories:
        recognized.append("psim2_edm")
    elif present_edm == set((regional_adapter,)):
        recognized.append("mswia_edm")
    elif present_edm:
        partial_edm = True

    provider_repositories = (
        PSIM2_EPN_REPOSITORY,
        PSIM2_EREJ_REPOSITORY,
        MSWIA_EANALIZY_REPOSITORY,
        MSWIA_EREJ_REPOSITORY,
    )
    recognized.extend(
        repository for repository in provider_repositories if repository in present
    )
    central_erej_conflict = (
        EREJESTRACJA_REPOSITORY in present and bool(recognized)
    )

    if partial_edm or len(recognized) != 1 or central_erej_conflict:
        warning_code = "COMPOSE_PRODUCT_AMBIGUOUS"
        warning_subject = candidate_name
        warning_message = "Known Compose image signatures do not identify one product"
        if (
            candidate_name.lower() == "erej"
            and set(recognized) == set((PSIM2_EREJ_REPOSITORY,))
            and EREJESTRACJA_REPOSITORY in present
            and not partial_edm
        ):
            warning_code = "EREJ_PRODUCT_AMBIGUOUS"
            warning_subject = "EREJ"
            warning_message = "Both allowlisted EREJ product repositories are present"
        add_warning(
            warnings,
            warning_code,
            warning_subject,
            warning_message,
        )
        return (
            "unresolved",
            [
                application_candidate(
                    candidate_name,
                    candidate_path,
                    {
                        "base_path": base_path,
                        "matched_hint": "compose_signature_unresolved",
                        "compose_files": compose_files,
                    },
                )
            ],
        )

    identity = recognized[0]
    if identity == "psim2_edm":
        return (
            "recognized",
            [psim2_edm_candidate(candidate_path, base_path, warnings, compose_files)],
        )
    if identity == "mswia_edm":
        return (
            "recognized",
            [
                mswia_edm_candidate(
                    candidate_path,
                    base_path,
                    compose_files,
                    images[regional_adapter],
                    source_paths[regional_adapter],
                )
            ],
        )

    base_fields = {
        "base_path": base_path,
        "matched_hint": "compose_image",
        "compose_files": compose_files,
    }
    return (
        "recognized",
        [
            compose_product_candidate(
                candidate_name,
                candidate_path,
                base_fields,
                identity,
                images[identity],
                source_paths[identity],
                True,
            )
        ],
    )


def special_application_candidates(candidate_path, base_path, candidate_name, warnings):
    """Return candidates for exact allowlisted version probes, or None if generic."""
    lower_name = candidate_name.lower()
    base_fields = {"base_path": base_path, "matched_hint": lower_name}

    if lower_name == "epn":
        compose_path = os.path.join(candidate_path, "docker-compose.yml")
        images = read_allowlisted_compose_images(
            compose_path, (PSIM2_EPN_REPOSITORY,)
        )
        if PSIM2_EPN_REPOSITORY not in images:
            return [application_candidate(candidate_name, candidate_path, base_fields)]
        return [
            compose_product_candidate(
                candidate_name,
                candidate_path,
                base_fields,
                PSIM2_EPN_REPOSITORY,
                images[PSIM2_EPN_REPOSITORY],
                compose_path,
                True,
            )
        ]

    if lower_name == "erej":
        compose_path = os.path.join(candidate_path, "docker-compose.yml")
        repositories = (EREJESTRACJA_REPOSITORY, PSIM2_EREJ_REPOSITORY)
        images = read_allowlisted_compose_images(compose_path, repositories)
        recognized = [repository for repository in repositories if repository in images]
        if len(recognized) == 2:
            add_warning(
                warnings,
                "EREJ_PRODUCT_AMBIGUOUS",
                "EREJ",
                "Both allowlisted EREJ product repositories are present",
            )
            return [application_candidate(candidate_name, candidate_path, base_fields)]
        if len(recognized) == 1:
            repository = recognized[0]
            return [
                compose_product_candidate(
                    candidate_name,
                    candidate_path,
                    base_fields,
                    repository,
                    images[repository],
                    compose_path,
                    True,
                )
            ]
        return [application_candidate(candidate_name, candidate_path, base_fields)]

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
        compose_path = os.path.join(candidate_path, "docker-compose.yml")
        images = read_allowlisted_compose_images(
            compose_path, (EREJESTRACJA_REPOSITORY,)
        )
        if EREJESTRACJA_REPOSITORY not in images:
            return [application_candidate(candidate_name, candidate_path, base_fields)]
        return [
            compose_product_candidate(
                candidate_name,
                candidate_path,
                base_fields,
                EREJESTRACJA_REPOSITORY,
                images[EREJESTRACJA_REPOSITORY],
                compose_path,
                True,
            )
        ]
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
    normalized_bases = []
    for base_path in base_paths:
        normalized = os.path.normpath(base_path)
        if normalized not in normalized_bases:
            normalized_bases.append(normalized)
    base_set = set(normalized_bases)
    seen_directories = set()
    seen_catalog_sources = set()
    visited_directories = [0]
    directory_limit_warned = [False]
    depth_limit_warned = [False]

    def warn_once(flag, code, message):
        if flag[0]:
            return
        flag[0] = True
        add_warning(warnings, code, "application_candidates", message)

    def uses_system_directory_exclusions(base):
        normalized_parts = os.path.normpath(base).casefold().split(os.sep)
        return normalized_parts[-1:] == ["usr"] or normalized_parts[-2:] == [
            "usr", "local"
        ]

    def is_excluded_directory_name(base, name):
        return (
            uses_system_directory_exclusions(base)
            and name.casefold() in SYSTEM_APPLICATION_DIRECTORY_NAMES
        )

    def inspect_candidate(child, base):
        candidate_name = os.path.basename(child)
        if is_non_primary_application_directory_name(candidate_name):
            return False

        before_count = len(candidates)
        nbk_candidate = read_nbk_compose_version(child, base, warnings)
        if nbk_candidate is not None:
            candidates.append(nbk_candidate)
            return True

        catalog_candidates = collect_catalog_application_candidates(child, base)
        if catalog_candidates:
            nested_source = False
            for catalog_candidate in catalog_candidates:
                catalog_fields = catalog_candidate["fields"]
                application_version_value = catalog_fields.get("application_version")
                if isinstance(application_version_value, dict):
                    source_paths = (application_version_value["source_path"],)
                    rule_id = application_version_value["rule_id"]
                else:
                    source_paths = tuple(
                        observation["source_path"]
                        for observation in catalog_fields.get(
                            "catalog_version_observations", ()
                        )
                        if isinstance(observation, dict)
                        and "source_path" in observation
                    )
                    rule_id = CATALOG_RULE_ID_PREFIX + catalog_candidate["name"]
                normalized_source_paths = tuple(
                    os.path.normpath(source_path) for source_path in source_paths
                )
                detection_key = (rule_id, normalized_source_paths)
                if detection_key not in seen_catalog_sources:
                    seen_catalog_sources.add(detection_key)
                    candidates.append(catalog_candidate)
                for source_path in normalized_source_paths:
                    relative_source = os.path.relpath(source_path, child)
                    if os.sep in relative_source:
                        nested_source = True
            return "catalog_nested" if nested_source else True

        regional_detection = classify_known_regional_compose(
            child, base, candidate_name, warnings
        )
        unresolved_regional_candidates = None
        if regional_detection is not None:
            regional_resolution, regional_candidates = regional_detection
            if regional_resolution == "unresolved":
                unresolved_regional_candidates = regional_candidates
            else:
                if candidate_name.lower().startswith("edm"):
                    candidates.extend(legacy_edm_application_candidates(child, base))
                candidates.extend(regional_candidates)
                return True

        if unresolved_regional_candidates is not None:
            if candidate_name.lower().startswith("edm"):
                legacy_edm_candidates = legacy_edm_application_candidates(child, base)
                if legacy_edm_candidates:
                    candidates.extend(legacy_edm_candidates)
                    return True
            if not candidate_name.lower().startswith("mpi"):
                candidates.extend(unresolved_regional_candidates)
                return True

        if candidate_name.lower() in PSIM2_EDM_DIRECTORY_NAMES:
            candidates.extend(legacy_edm_application_candidates(child, base))
            return len(candidates) > before_count

        special_candidates = special_application_candidates(
            child, base, candidate_name, warnings
        )
        if special_candidates is not None:
            candidates.extend(special_candidates)
            return True

        match = match_application_candidate(candidate_name)
        if match is None:
            generic_candidate = generic_compose_candidate(
                child, base, candidate_name, warnings
            )
            if generic_candidate is None:
                return False
            candidates.append(generic_candidate)
            return True

        candidate_type, matched_hint = match
        fields = {
            "base_path": base,
            "matched_hint": matched_hint,
        }
        if candidate_type == "docker_compose":
            fields["compose_files"] = collect_compose_files(child)
            application_version_value = read_mpi_env_version(child)
            if application_version_value is not None:
                fields["application_version"] = application_version_value
        elif candidate_type == "edm":
            application_version_value = read_edm_env_version(child)
            if application_version_value is not None:
                fields["application_version"] = application_version_value
        elif candidate_type == "wildfly_jboss":
            application_version_value = read_amms_build_metadata(child)
            if application_version_value is not None:
                fields["application_version"] = application_version_value
        elif candidate_type == "integration_platform":
            application_version_value, webapps = collect_integration_version_metadata(child)
            if application_version_value is not None:
                fields["application_version"] = application_version_value
            fields["webapps"] = webapps

        candidates.append({
            "source": "filesystem_allowlist",
            "source_path": child,
            "name": os.path.basename(child),
            "candidate_type": candidate_type,
            "status": "candidate",
            "fields": fields,
        })
        return True

    def list_children(directory):
        try:
            child_names = sorted(os.listdir(directory))
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
            return []

        if len(child_names) > MAX_APPLICATION_BASE_CHILDREN:
            add_warning(
                warnings,
                "APPLICATION_BASE_CHILD_LIMIT",
                "application_candidates",
                "Application base child limit reached",
            )
            child_names = child_names[:MAX_APPLICATION_BASE_CHILDREN]
        return child_names

    def has_scannable_child_directory(directory, base):
        try:
            entries = os.scandir(directory)
        except OSError:
            return False
        try:
            for index, entry in enumerate(entries):
                if index >= MAX_APPLICATION_BASE_CHILDREN:
                    add_warning(
                        warnings,
                        "APPLICATION_BASE_CHILD_LIMIT",
                        "application_candidates",
                        "Application base child limit reached",
                    )
                    return False
                if is_excluded_directory_name(base, entry.name):
                    continue
                if is_non_primary_application_directory_name(entry.name):
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False):
                        return True
                except OSError:
                    continue
        finally:
            entries.close()
        return False

    for base in normalized_bases:
        if is_excluded_application_path(base):
            continue
        pending = []
        if os.path.basename(base).lower() == "app":
            pending.append((base, 0))
        else:
            for child_name in reversed(list_children(base)):
                pending.append((os.path.join(base, child_name), 1))

        while pending:
            child, depth = pending.pop()
            normalized_child = os.path.normpath(child)
            if is_excluded_application_path(normalized_child):
                continue
            if normalized_child in seen_directories:
                continue
            if normalized_child != base and normalized_child in base_set:
                continue
            child_name = os.path.basename(normalized_child)
            if (
                os.path.basename(base).lower() == "usr"
                and depth == 1
                and child_name.lower() in ("local", "app")
            ):
                continue
            if is_excluded_directory_name(base, child_name):
                continue
            if is_non_primary_application_directory_name(child_name):
                continue
            try:
                if not os.path.isdir(child):
                    continue
            except OSError:
                continue
            if visited_directories[0] >= MAX_APPLICATION_DIRECTORIES:
                warn_once(
                    directory_limit_warned,
                    "APPLICATION_DIRECTORY_LIMIT",
                    "Application directory visit limit reached",
                )
                pending = []
                break
            visited_directories[0] += 1
            seen_directories.add(normalized_child)

            if depth > 1 and os.path.islink(child):
                continue
            detected = inspect_candidate(child, base)
            if detected:
                if depth == 0 and detected != "catalog_nested":
                    pending = []
                if detected != "catalog_nested":
                    continue
            if os.path.islink(child):
                continue
            if depth >= MAX_APPLICATION_SCAN_DEPTH:
                if has_scannable_child_directory(child, base):
                    warn_once(
                        depth_limit_warned,
                        "APPLICATION_DEPTH_LIMIT",
                        "Application directory depth limit reached",
                    )
                continue
            for nested_name in reversed(list_children(child)):
                pending.append((os.path.join(child, nested_name), depth + 1))

    return enrich_specialist_catalog_metadata(candidates)


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
    cpu_logical_count = collect_cpu_logical_count(warnings)
    memory_total_bytes = read_memory_total_bytes(warnings)

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
            "cpu_logical_count": cpu_logical_count,
            "memory_total_bytes": memory_total_bytes,
        },
        "runtimes": collect_runtimes(warnings),
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
