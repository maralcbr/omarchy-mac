#!/usr/bin/env python3
"""Focused tests for the unsigned catalog generator."""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "make-unsigned-catalog.py"
TEMPLATE = Path(__file__).resolve().parents[1] / "release-inputs.template.json"
BASE_URL = "https://downloads.example.test/releases/os-v1.0.0-mac.1.20260902"
NOW = "2026-09-04T00:00:00Z"


class CatalogGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(
            tempfile.mkdtemp(prefix="omarchy-catalog-test-")
        )
        self.assets = self.directory / "assets"
        self.assets.mkdir()
        self.inputs = json.loads(TEMPLATE.read_text())
        for key in ("engine_name", "metadata_name", "payload_name"):
            (self.assets / self.inputs[key]).write_bytes(key.encode() * 64)

    def write_inputs(self, document: dict | None = None) -> Path:
        path = self.directory / "inputs.json"
        path.write_text(json.dumps(document or self.inputs, indent=2))
        return path

    def generate(self, document: dict | None = None, output: str = "catalog.json"):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--base-url",
                BASE_URL,
                "--assets-dir",
                str(self.assets),
                "--inputs",
                str(self.write_inputs(document)),
                "--output",
                str(self.directory / output),
                "--now",
                NOW,
            ],
            capture_output=True,
            text=True,
        )

    def assertRejected(self, document: dict, fragment: str) -> None:
        result = self.generate(document)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_emits_schema_four_without_an_expiry(self) -> None:
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads((self.directory / "catalog.json").read_text())
        self.assertEqual(catalog["schemaVersion"], 4)
        self.assertNotIn("expiresAt", catalog)
        self.assertEqual(catalog["issuedAt"], NOW)
        self.assertEqual(catalog["sequence"], 1788480000)
        self.assertEqual(len(catalog["models"]), 22)

    def test_carries_the_installer_compatibility_block(self) -> None:
        self.generate()
        catalog = json.loads((self.directory / "catalog.json").read_text())
        self.assertEqual(
            catalog["installer"],
            {
                "minimumVersion": "2.0.0",
                "latestVersion": "2.0.0",
                "downloadURL": self.inputs["installer"]["download_url"],
            },
        )

    def test_artifact_urls_sit_under_the_base_url(self) -> None:
        self.generate()
        catalog = json.loads((self.directory / "catalog.json").read_text())
        model = catalog["models"][0]
        for role in ("engineArtifact", "metadataArtifact", "payloadArtifact"):
            self.assertTrue(model[role]["sourceURL"].startswith(f"{BASE_URL}/"))

    def test_the_same_inputs_produce_the_same_bytes(self) -> None:
        self.generate(output="first.json")
        self.generate(output="second.json")
        self.assertEqual(
            (self.directory / "first.json").read_bytes(),
            (self.directory / "second.json").read_bytes(),
        )

    def test_a_split_payload_proves_its_parts_concatenate(self) -> None:
        payload = self.assets / self.inputs["payload_name"]
        content = payload.read_bytes()
        half = len(content) // 2
        (self.assets / f"{payload.name}.part00").write_bytes(content[:half])
        (self.assets / f"{payload.name}.part01").write_bytes(content[half:])
        self.generate()
        catalog = json.loads((self.directory / "catalog.json").read_text())
        parts = catalog["models"][0]["payloadArtifact"]["parts"]
        self.assertEqual([part["fileName"] for part in parts],
                         [f"{payload.name}.part00", f"{payload.name}.part01"])
        self.assertEqual(
            sum(part["sizeBytes"] for part in parts),
            catalog["models"][0]["payloadArtifact"]["sizeBytes"],
        )

    def test_a_corrupt_part_is_rejected(self) -> None:
        payload = self.assets / self.inputs["payload_name"]
        content = payload.read_bytes()
        half = len(content) // 2
        (self.assets / f"{payload.name}.part00").write_bytes(content[:half])
        (self.assets / f"{payload.name}.part01").write_bytes(b"x" * (len(content) - half))
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not concatenate", result.stderr)

    def test_an_unknown_inputs_key_is_rejected(self) -> None:
        document = dict(self.inputs)
        document["unexpected"] = "value"
        self.assertRejected(document, "unknown keys")

    def test_a_missing_inputs_key_is_rejected(self) -> None:
        document = dict(self.inputs)
        del document["engine_version"]
        self.assertRejected(document, "missing keys")

    def test_a_minimum_newer_than_the_latest_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["installer"]["minimum_version"] = "3.0.0"
        self.assertRejected(document, "newer than")

    def test_a_plain_http_download_url_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["installer"]["download_url"] = "http://downloads.example.test/a.pkg"
        self.assertRejected(document, "must be https")

    def test_a_malformed_installer_version_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["installer"]["latest_version"] = "2.0"
        self.assertRejected(document, "installer.latest_version")

    def test_a_malformed_device_identifier_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["device_identifiers"] = ["apple,j314s", "Apple,J999"]
        self.assertRejected(document, "invalid device identifier")

    def test_duplicate_device_identifiers_are_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["device_identifiers"] = ["apple,j314s", "apple,j314s"]
        self.assertRejected(document, "duplicates")

    def test_an_uppercase_evidence_revision_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["evidence_revision"] = "4.0.2-MAC.1"
        self.assertRejected(document, "evidence_revision")

    def test_a_payload_name_with_a_path_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["payload_name"] = "../escape.zip"
        self.assertRejected(document, "plain file name")

    def test_a_short_revision_is_rejected(self) -> None:
        document = json.loads(json.dumps(self.inputs))
        document["downstream_revision"] = "abc123"
        self.assertRejected(document, "40-character hex")

    def test_the_committed_template_is_valid(self) -> None:
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads((self.directory / "catalog.json").read_text())
        digest = hashlib.sha256(
            (self.assets / self.inputs["payload_name"]).read_bytes()
        ).hexdigest()
        self.assertEqual(
            catalog["models"][0]["payloadDigest"], f"sha256:{digest}"
        )


if __name__ == "__main__":
    unittest.main()
