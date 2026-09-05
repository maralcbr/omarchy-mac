#!/usr/bin/env python3
"""Emit the unsigned support catalog for local signing.

The document this writes is the exact payload the app verifies: signing is a
separate step (`catalog-signing.swift sign-keychain`) that needs the long-lived
catalog-signing key, which lives in the operator's Keychain and never in this
repository.

Every per-release value comes from an inputs file (`--inputs`), so cutting a
release never edits this script. `scripts/release-inputs.template.json` holds
the current values.

The catalog pins whole-file digests. When the payload was split for release
delivery, the sibling `<payload>.partNN` files are emitted as an additional
`parts` array on `payloadArtifact`; the whole-file digest and size stay
authoritative and the whole-file URL becomes informational.

Schema 4 carries no `expiresAt`: a signed catalog stays valid until a
higher-sequence one replaces it. The monotonic `sequence` is the only
machine-enforced guard.

Usage:
  make-unsigned-catalog.py --base-url URL --assets-dir DIR --inputs FILE
                           [--output FILE] [--now ISO8601]
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
from pathlib import Path

SCHEMA_VERSION = 4

REQUIRED_INPUT_KEYS = frozenset(
    {
        "payload_name",
        "engine_name",
        "metadata_name",
        "engine_version",
        "evidence_revision",
        "asahi_installer_tag",
        "asahi_installer_revision",
        "asahi_installer_data_revision",
        "downstream_revision",
        "device_identifiers",
        "installer",
    }
)
REQUIRED_INSTALLER_KEYS = frozenset(
    {"minimum_version", "latest_version", "download_url"}
)

DEVICE_IDENTIFIER_PATTERN = re.compile(r"^apple,[0-9a-z]+$")
EVIDENCE_REVISION_PATTERN = re.compile(r"^[0-9a-z.-]+$")
INSTALLER_VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
ASAHI_TAG_PATTERN = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")

MAXIMUM_PART_COUNT = 16
PART_PATTERN = re.compile(r"\.part(\d{2})$")
READ_BLOCK_BYTES = 8 * 1024 * 1024


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(READ_BLOCK_BYTES):
            value.update(block)
    return value.hexdigest()


def require_regular_file(path: Path) -> Path:
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"unsafe or missing asset: {path}")
    return path


def artifact(path: Path, base_url: str) -> dict:
    return {
        "sourceURL": f"{base_url}/{path.name}",
        "fileName": path.name,
        "sizeBytes": path.stat().st_size,
    }


def discover_parts(payload: Path) -> list[Path]:
    """Return the `<payload>.partNN` siblings in ascending part order."""
    parts = sorted(
        candidate
        for candidate in payload.parent.iterdir()
        if candidate.name.startswith(f"{payload.name}.part")
        and PART_PATTERN.search(candidate.name)
    )
    for index, part in enumerate(parts):
        require_regular_file(part)
        expected = f"{payload.name}.part{index:02d}"
        if part.name != expected:
            raise SystemExit(
                f"payload part sequence is not contiguous: expected {expected}, "
                f"found {part.name}"
            )
    return parts


def part_records(payload: Path, parts: list[Path], base_url: str) -> list[dict]:
    """Digest every part, proving they concatenate back into the payload."""
    if len(parts) == 1:
        raise SystemExit(
            f"a split payload needs at least two parts: found {parts[0].name}"
        )
    if len(parts) > MAXIMUM_PART_COUNT:
        raise SystemExit(
            f"payload is split into {len(parts)} parts; the app accepts at most "
            f"{MAXIMUM_PART_COUNT}"
        )

    whole = hashlib.sha256()
    records = []
    declared_bytes = 0
    for part in parts:
        part_hash = hashlib.sha256()
        with part.open("rb") as stream:
            while block := stream.read(READ_BLOCK_BYTES):
                part_hash.update(block)
                whole.update(block)
        size_bytes = part.stat().st_size
        if size_bytes == 0:
            raise SystemExit(f"payload part is empty: {part.name}")
        declared_bytes += size_bytes
        records.append(
            {
                "sourceURL": f"{base_url}/{part.name}",
                "fileName": part.name,
                "sizeBytes": size_bytes,
                "sha256": f"sha256:{part_hash.hexdigest()}",
            }
        )

    payload_bytes = payload.stat().st_size
    if declared_bytes != payload_bytes:
        raise SystemExit(
            f"payload parts sum to {declared_bytes} bytes but the payload is "
            f"{payload_bytes} bytes"
        )
    payload_digest = digest(payload)
    if whole.hexdigest() != payload_digest:
        raise SystemExit(
            "payload parts do not concatenate into the payload: "
            f"parts hash to sha256:{whole.hexdigest()}, payload is "
            f"sha256:{payload_digest}"
        )
    return records


def parse_version(value: str) -> tuple[int, int, int]:
    parts = value.split(".")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def load_inputs(path: Path) -> dict:
    """Read and fully validate the per-release inputs, failing closed."""
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"unsafe or missing inputs file: {path}")
    try:
        document = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise SystemExit(f"inputs file is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise SystemExit("inputs file must contain a JSON object")

    keys = set(document)
    missing = REQUIRED_INPUT_KEYS - keys
    if missing:
        raise SystemExit(f"inputs file is missing keys: {', '.join(sorted(missing))}")
    unknown = keys - REQUIRED_INPUT_KEYS
    if unknown:
        raise SystemExit(f"inputs file has unknown keys: {', '.join(sorted(unknown))}")

    for key in (
        "payload_name",
        "engine_name",
        "metadata_name",
        "engine_version",
        "evidence_revision",
        "asahi_installer_tag",
    ):
        value = document[key]
        if not isinstance(value, str) or not value:
            raise SystemExit(f"inputs {key} must be a non-empty string")
    for key in ("payload_name", "engine_name", "metadata_name"):
        name = document[key]
        if "/" in name or name in {".", ".."}:
            raise SystemExit(f"inputs {key} must be a plain file name: {name}")

    if not EVIDENCE_REVISION_PATTERN.match(document["evidence_revision"]):
        raise SystemExit(
            "inputs evidence_revision must be lowercase [0-9a-z.-]: "
            f"{document['evidence_revision']}"
        )
    if not ASAHI_TAG_PATTERN.match(document["asahi_installer_tag"]):
        raise SystemExit(
            f"inputs asahi_installer_tag must look like vX.Y.Z: "
            f"{document['asahi_installer_tag']}"
        )
    for key in (
        "asahi_installer_revision",
        "asahi_installer_data_revision",
        "downstream_revision",
    ):
        value = document[key]
        if not isinstance(value, str) or not REVISION_PATTERN.match(value):
            raise SystemExit(f"inputs {key} must be a 40-character hex revision")

    identifiers = document["device_identifiers"]
    if not isinstance(identifiers, list) or not identifiers:
        raise SystemExit("inputs device_identifiers must be a non-empty list")
    if len(set(identifiers)) != len(identifiers):
        raise SystemExit("inputs device_identifiers contains duplicates")
    for identifier in identifiers:
        if not isinstance(identifier, str) or not DEVICE_IDENTIFIER_PATTERN.match(
            identifier
        ):
            raise SystemExit(f"invalid device identifier: {identifier}")

    installer = document["installer"]
    if not isinstance(installer, dict):
        raise SystemExit("inputs installer must be an object")
    installer_keys = set(installer)
    if installer_keys != REQUIRED_INSTALLER_KEYS:
        raise SystemExit(
            "inputs installer must have exactly "
            f"{', '.join(sorted(REQUIRED_INSTALLER_KEYS))}"
        )
    for key in ("minimum_version", "latest_version"):
        value = installer[key]
        if not isinstance(value, str) or not INSTALLER_VERSION_PATTERN.match(value):
            raise SystemExit(f"inputs installer.{key} must look like X.Y.Z: {value}")
    if parse_version(installer["minimum_version"]) > parse_version(
        installer["latest_version"]
    ):
        raise SystemExit(
            "inputs installer.minimum_version is newer than installer.latest_version"
        )
    download_url = installer["download_url"]
    if not isinstance(download_url, str) or not download_url.startswith("https://"):
        raise SystemExit(f"inputs installer.download_url must be https: {download_url}")

    return document


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit the unsigned support catalog."
    )
    parser.add_argument(
        "--base-url",
        required=True,
        help="release download base, without a trailing slash",
    )
    parser.add_argument(
        "--assets-dir",
        required=True,
        type=Path,
        help="directory holding the engine, metadata, and payload assets",
    )
    parser.add_argument(
        "--inputs",
        required=True,
        type=Path,
        help="per-release inputs JSON (see release-inputs.template.json)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="catalog path to write (default: <assets-dir>/catalog.json)",
    )
    parser.add_argument(
        "--now",
        help="override the issue time as YYYY-MM-DDTHH:MM:SSZ (tests only)",
    )
    arguments = parser.parse_args()

    if not arguments.base_url.startswith("https://"):
        raise SystemExit(f"--base-url must be https: {arguments.base_url}")
    if arguments.base_url.endswith("/"):
        raise SystemExit(
            f"--base-url must not end with a slash: {arguments.base_url}"
        )
    if not arguments.assets_dir.is_dir() or arguments.assets_dir.is_symlink():
        raise SystemExit(f"unsafe or missing assets directory: {arguments.assets_dir}")
    if arguments.output is None:
        arguments.output = arguments.assets_dir / "catalog.json"
    return arguments


def issue_time(override: str | None) -> datetime.datetime:
    if override is None:
        return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    try:
        parsed = datetime.datetime.strptime(override, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise SystemExit(f"--now must be YYYY-MM-DDTHH:MM:SSZ: {override}") from error
    return parsed.replace(tzinfo=datetime.timezone.utc)


def main() -> None:
    arguments = parse_arguments()
    inputs = load_inputs(arguments.inputs)
    assets = arguments.assets_dir
    engine = require_regular_file(assets / inputs["engine_name"])
    metadata = require_regular_file(assets / inputs["metadata_name"])
    payload = require_regular_file(assets / inputs["payload_name"])

    payload_artifact = artifact(payload, arguments.base_url)
    parts = discover_parts(payload)
    if parts:
        payload_artifact["parts"] = part_records(payload, parts, arguments.base_url)

    issued = issue_time(arguments.now)
    installer = inputs["installer"]

    catalog = {
        "schemaVersion": SCHEMA_VERSION,
        "sequence": int(issued.timestamp()),
        "issuedAt": issued.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "installer": {
            "minimumVersion": installer["minimum_version"],
            "latestVersion": installer["latest_version"],
            "downloadURL": installer["download_url"],
        },
        "models": [
            {
                "deviceIdentifier": device_identifier,
                "status": "enabled",
                "asahiInstallerTag": inputs["asahi_installer_tag"],
                "asahiInstallerRevision": inputs["asahi_installer_revision"],
                "asahiInstallerDataRevision": inputs["asahi_installer_data_revision"],
                "downstreamRevision": inputs["downstream_revision"],
                "engineVersion": inputs["engine_version"],
                "engineDigest": f"sha256:{digest(engine)}",
                "metadataDigest": f"sha256:{digest(metadata)}",
                "payloadDigest": f"sha256:{digest(payload)}",
                "evidenceRevision": inputs["evidence_revision"],
                "engineArtifact": artifact(engine, arguments.base_url),
                "metadataArtifact": artifact(metadata, arguments.base_url),
                "payloadArtifact": payload_artifact,
            }
            for device_identifier in inputs["device_identifiers"]
        ],
    }

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"unsigned_catalog={arguments.output}")
    print(f"unsigned_catalog_sha256={digest(arguments.output)}")
    print(f"sequence={catalog['sequence']}")
    print(f"evidence_revision={inputs['evidence_revision']}")
    print(f"models={len(catalog['models'])}")
    print(f"payload_parts={len(parts)}")


if __name__ == "__main__":
    main()
