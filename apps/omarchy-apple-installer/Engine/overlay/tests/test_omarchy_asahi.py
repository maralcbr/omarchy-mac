# SPDX-License-Identifier: MIT
import io
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


class FakeOSInstaller:
    def __init__(self, dutil, data, template):
        self.min_recommended_size = template.get("minimum_size", 64 * GIB)
        self.name = template.get("default_os_name", "Omarchy")
        self.needs_firmware = False
        self.idata_targets = []
        self.efi_part = SimpleNamespace(uuid="ABCDEF")
        self.calls = []
        self.template = template

    def partition_disk(self, name, size):
        self.calls.append(("partition_disk", name, size))
        self.part_info = [
            SimpleNamespace(name="disk0s5", uuid="EFI-UUID", size=500 * 1024**2),
            SimpleNamespace(name="disk0s6", uuid="BOOT-UUID", size=2 * GIB),
            SimpleNamespace(name="disk0s7", uuid="ROOT-UUID", size=32 * GIB),
        ]
        self.efi_part = self.part_info[0]

    def install(self, installer):
        self.calls.append(("install", installer))
        icon = self.template.get("icon")
        if icon:
            Path(installer.icon_path).write_bytes(self.pkg.read(icon))
        for partition, info in zip(self.template["partitions"], self.part_info):
            if partition.get("image"):
                self.install_raw_image(partition["image"], info)


class FakeStubInstaller:
    def __init__(self, sysinfo, dutil, osinfo):
        self.calls = []
        self.osi = SimpleNamespace(
            vgid="vgid-1",
            sys_volume="System",
        )
        self.icon_path = dutil.stub_icon_path

    def load_ipsw(self, ipsw):
        self.calls.append(("load_ipsw", ipsw))

    def prepare_volume(self, part):
        self.calls.append(("prepare_volume", part.name))

    def check_volume(self, part=None):
        if part is not None:
            self.calls.append(("check_volume", part.name))
            return
        self.calls.append(("check_volume",))

    def install_files(self, current_os):
        self.calls.append(("install_files", current_os))

    def prepare_for_bless(self):
        self.calls.append(("prepare_for_bless",))

    def prepare_for_step2(self):
        self.calls.append(("prepare_for_step2",))


sys.modules["asahi_firmware"] = SimpleNamespace(
    core=SimpleNamespace(FWPackage=object),
)
sys.modules["osinstall"] = SimpleNamespace(OSInstaller=FakeOSInstaller, psize=lambda value: int(value[:-2]) * 1024**3 if value.endswith("GB") else int(value[:-1]))
sys.modules["stub"] = SimpleNamespace(StubInstaller=FakeStubInstaller)
sys.modules.setdefault(
    "util",
    SimpleNamespace(align_down=lambda value, align: value - value % align),
)
sys.path.insert(
    0,
    str(Path(__file__).resolve().parents[1] / "src"),
)

from omarchy_asahi import (  # noqa: E402
    AsahiAdapterError,
    AsahiInPlaceRepairAdapter,
    AsahiStage1Adapter,
)


GIB = 1024**3


class AsahiStage1AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.metadata = self.root / "installer_data.json"
        self.payload = self.root / "payload.zip"
        self._write_metadata()
        with zipfile.ZipFile(self.payload, "w") as archive:
            archive.writestr("omarchy-volume.icns", b"omarchy-icon")
            archive.writestr("esp/m1n1/boot.bin", "m1n1")
            archive.writestr("esp/EFI/BOOT/BOOTAA64.EFI", "grub")
            archive.writestr("boot.img", b"b" * 4096)
            archive.writestr("root.img", b"r" * 4096)
        self.installed_esp = self.root / "installed-esp"
        self.installed_stub_icon = self.root / ".VolumeIcon.icns"
        (self.installed_esp / "m1n1").mkdir(parents=True)
        (self.installed_esp / "m1n1/boot.bin").write_bytes(b"m1n1")
        (self.installed_esp / "EFI/BOOT").mkdir(parents=True)
        (self.installed_esp / "EFI/BOOT/BOOTAA64.EFI").write_bytes(b"grub")
        self.raw_images = {
            "disk0s6": b"b" * 4096,
            "disk0s7": b"r" * 4096,
        }
        self.free = FakePart(
            "disk0s3",
            offset=400 * GIB,
            size=100 * GIB,
            free=True,
            part_type="Free space",
        )
        self.plan = SimpleNamespace(
            plan_digest="a" * 64,
            candidate_kind="free",
            source_identifier="disk0s3",
            offset_bytes=self.free.offset,
            length_bytes=80 * GIB,
            minimum_container_bytes=0,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_free_extent_runs_exact_upstream_stage_one_primitives(self):
        dutil = FakeDiskUtil([[self.free]])
        installer = FakeInstaller(dutil)
        adapter = self._adapter(installer)

        adapter.preflight(self.plan)
        target_evidence = json.loads(adapter.prepare_target(self.plan))
        installed_evidence = json.loads(
            adapter.install_stub_and_esp(self.plan)
        )
        with patch.dict(
            os.environ,
            {"OMARCHY_MACHINE_OWNER": "mina"},
        ), patch(
            "omarchy_asahi.sys.stdin",
            SimpleNamespace(buffer=io.BytesIO(b"owner-password\n")),
        ), patch(
            "omarchy_asahi.subprocess.run",
        ) as run:
            recovery_evidence = json.loads(
                adapter.prepare_recovery_handoff(self.plan)
            )

        self.assertEqual(installer.chosen_firmware, None)
        self.assertEqual(
            installer.ins.calls[0],
            ("load_ipsw", "ipsw-image"),
        )
        self.assertEqual(
            dutil.add_calls,
            [("disk0s3", "apfs", "Omarchy", 2 * GIB)],
        )
        self.assertEqual(
            target_evidence["partition_identifier"],
            "disk0s4",
        )
        self.assertEqual(installed_evidence["apfs_vgid"], "vgid-1")
        self.assertEqual(installed_evidence["efi_partition"], "efi-uuid")
        self.assertEqual(
            installed_evidence["startup_volume_icon"],
            {
                "content_sha256": hashlib.sha256(b"omarchy-icon").hexdigest(),
                "installed_bytes": 12,
                "member": "omarchy-volume.icns",
                "verification": "stub-file-sha256",
            },
        )
        self.assertEqual(
            [item["partition_identifier"] for item in installed_evidence["populated_partitions"]],
            ["disk0s5", "disk0s6", "disk0s7"],
        )
        self.assertEqual(
            [item["installed_bytes"] for item in installed_evidence["populated_partitions"]],
            [8, 4096, 4096],
        )
        self.assertEqual(
            [item["verification"] for item in installed_evidence["populated_partitions"]],
            ["copied-tree-sha256", "raw-prefix-sha256", "source-sha256-write-flushed-v1"],
        )
        self.assertEqual(
            installed_evidence["populated_partitions"][1]["content_sha256"],
            hashlib.sha256(b"b" * 4096).hexdigest(),
        )
        self.assertEqual(
            recovery_evidence["outcome"],
            "awaiting_recovery",
        )
        self.assertLess(
            installer.ins.calls.index(("prepare_for_bless",)),
            installer.ins.calls.index(("prepare_for_step2",)),
        )
        run.assert_called_once_with(
            [
                "/usr/sbin/bless",
                "--setBoot",
                "--device",
                "/dev/System",
                "--user",
                "mina",
                "--stdinpass",
            ],
            input=b"owner-password\n",
            check=True,
            stdout=-3,
            stderr=-3,
        )

    def test_recovery_handoff_rejects_missing_owner_before_bless(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        adapter.preflight(self.plan)

        with patch.dict(os.environ, {}, clear=True), patch(
            "omarchy_asahi.subprocess.run",
        ) as run:
            with self.assertRaisesRegex(
                AsahiAdapterError,
                "machine owner is unavailable",
            ):
                adapter.prepare_recovery_handoff(self.plan)

        run.assert_not_called()

    def test_resize_uses_only_approved_container_and_minimum(self):
        source = FakePart(
            "disk0s2",
            offset=1 * GIB,
            size=500 * GIB,
            free=False,
        )
        resized_free = FakePart(
            "disk0s3",
            offset=421 * GIB,
            size=80 * GIB,
            free=True,
            part_type="Free space",
        )
        plan = SimpleNamespace(
            **{
                **self.plan.__dict__,
                "candidate_kind": "resize",
                "source_identifier": "disk0s2",
                "offset_bytes": resized_free.offset,
                "minimum_container_bytes": 320 * GIB,
            }
        )
        dutil = FakeDiskUtil([[source], [resized_free]])
        adapter = self._adapter(FakeInstaller(dutil))

        adapter.preflight(plan)
        adapter.prepare_target(plan)

        self.assertEqual(
            dutil.resize_calls,
            [("disk0s2", 420 * GIB)],
        )
        self.assertEqual(dutil.add_calls[0][0], "disk0s3")

    def test_changed_free_extent_is_rejected_before_partition_creation(self):
        changed = FakePart(
            "disk0s3",
            offset=self.free.offset + GIB,
            size=self.free.size,
            free=True,
            part_type="Free space",
        )
        dutil = FakeDiskUtil([[changed]])
        adapter = self._adapter(FakeInstaller(dutil))
        adapter.preflight(self.plan)

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "approved free extent changed",
        ):
            adapter.prepare_target(self.plan)

        self.assertEqual(dutil.add_calls, [])

    def test_retry_reconciles_the_exact_prepared_apfs_partition(self):
        prepared = FakePart(
            "disk0s4",
            offset=self.plan.offset_bytes,
            size=2 * GIB,
            free=False,
        )
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[prepared]])))
        adapter.preflight(self.plan)

        evidence = json.loads(adapter.install_stub_and_esp(self.plan))

        self.assertEqual(evidence["plan_digest"], self.plan.plan_digest)
        self.assertIn(("prepare_volume", "disk0s4"), adapter.installer.ins.calls)

    def test_installed_image_read_back_rejects_changed_partition_bytes(self):
        dutil = FakeDiskUtil([[self.free]])
        adapter = self._adapter(FakeInstaller(dutil))
        adapter.preflight(self.plan)
        adapter.prepare_target(self.plan)
        adapter.install_stub_and_esp(self.plan)
        self.raw_images["disk0s6"] = b"x" * 4096

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "installed content does not match payload",
        ):
            adapter._installed_evidence(self.plan)

    def test_fast_root_is_not_reread_but_retry_detects_corruption(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        adapter.preflight(self.plan)
        target = adapter.prepare_target(self.plan)
        read = adapter.raw_partition_opener
        def boot_only(name):
            self.assertNotEqual(name, "disk0s7")
            return read(name)
        adapter.raw_partition_opener = boot_only
        evidence = adapter.install_stub_and_esp(self.plan)
        self.raw_images["disk0s7"] = b"x" * 4096
        retry = self._retry_adapter(target, evidence)
        retry.preflight(self.plan)
        with self.assertRaisesRegex(AsahiAdapterError, "does not match payload"):
            retry.validate_installed_checkpoint(self.plan, target, evidence)

    def test_thorough_mode_reads_root(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        adapter.full_readback = True
        adapter.preflight(self.plan)
        adapter.prepare_target(self.plan)
        evidence = json.loads(adapter.install_stub_and_esp(self.plan))
        self.assertEqual(evidence["populated_partitions"][-1]["verification"],
                         "raw-prefix-sha256")
        self.raw_images["disk0s7"] = b"x" * 4096
        with self.assertRaisesRegex(AsahiAdapterError, "does not match payload"):
            adapter._installed_evidence(self.plan)

    def test_oversized_image_fails_before_disk_mutation(self):
        metadata = json.loads(self.metadata.read_text())
        metadata["os_list"][0]["partitions"][1]["size"] = "1024B"
        self.metadata.chmod(0o600)
        self.metadata.write_text(json.dumps(metadata))
        self.metadata.chmod(0o400)
        installer = FakeInstaller(FakeDiskUtil([[self.free]]))
        adapter = self._adapter(installer)
        with self.assertRaisesRegex(AsahiAdapterError, "exceeds partition capacity"):
            adapter.preflight(self.plan)
        self.assertEqual(installer.dutil.resize_calls, [])
        self.assertFalse(adapter.preflight_complete)

    def test_preflight_does_not_expand_the_package(self):
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        with patch.object(zipfile.ZipFile, "testzip", side_effect=AssertionError("expanded")):
            adapter.preflight(self.plan)

    def test_recovery_retry_revalidates_exact_installed_checkpoint(self):
        initial = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        initial.preflight(self.plan)
        target_evidence = initial.prepare_target(self.plan)
        installed_evidence = initial.install_stub_and_esp(self.plan)
        retry = self._retry_adapter(target_evidence, installed_evidence)

        retry.preflight(self.plan)
        retry.validate_installed_checkpoint(
            self.plan,
            target_evidence,
            installed_evidence,
        )

        self.assertEqual(retry.installer.dutil.resize_calls, [])
        self.assertEqual(retry.installer.dutil.add_calls, [])
        self.assertIn(
            ("check_volume", "disk0s4"),
            retry.installer.ins.calls,
        )

    def test_recovery_retry_rejects_changed_partition_identity(self):
        initial = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        initial.preflight(self.plan)
        target_evidence = initial.prepare_target(self.plan)
        installed_evidence = initial.install_stub_and_esp(self.plan)
        retry = self._retry_adapter(
            target_evidence,
            installed_evidence,
            changed_partition="disk0s7",
        )
        retry.preflight(self.plan)

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "installed partition identity changed",
        ):
            retry.validate_installed_checkpoint(
                self.plan,
                target_evidence,
                installed_evidence,
            )

        self.assertEqual(retry.installer.dutil.resize_calls, [])
        self.assertEqual(retry.installer.dutil.add_calls, [])

    def test_duplicate_target_metadata_is_rejected(self):
        target = self._target_metadata()
        self._write_metadata([target, dict(target)])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "exactly one Omarchy full-OS target",
        ):
            adapter.preflight(self.plan)

    def test_validation_only_uefi_target_is_not_an_install_target(self):
        target = self._target_metadata()
        target["omarchy_target"] = "apple-silicon-uefi"
        self._write_metadata([target])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "exactly one Omarchy full-OS target",
        ):
            adapter.preflight(self.plan)

    def test_missing_startup_volume_icon_is_rejected_before_mutation(self):
        target = self._target_metadata()
        target.pop("icon")
        self._write_metadata([target])
        adapter = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "invalid Omarchy Startup Options icon metadata",
        ):
            adapter.preflight(self.plan)

    def test_metadata_symlink_and_unprepared_adapter_are_rejected(self):
        link = self.root / "metadata-link.json"
        link.symlink_to(self.metadata)
        adapter = AsahiStage1Adapter(
            installer=FakeInstaller(FakeDiskUtil([[self.free]])),
            metadata_path=str(link),
            payload_path=str(self.payload),
            stub_size=2 * GIB,
        )
        with self.assertRaisesRegex(
            AsahiAdapterError,
            "metadata is unavailable",
        ):
            adapter.preflight(self.plan)

        fresh = self._adapter(FakeInstaller(FakeDiskUtil([[self.free]])))
        with self.assertRaisesRegex(
            AsahiAdapterError,
            "preflight is required",
        ):
            fresh.prepare_target(self.plan)

    def _adapter(self, installer):
        installer.dutil.stub_icon_path = str(self.installed_stub_icon)
        installer.dutil.mount_points = {
            "disk0s5": str(self.installed_esp),
        }
        @contextmanager
        def writer(name):
            stream = io.BytesIO()
            yield stream
            self.raw_images[name] = stream.getvalue()
            stream.close()

        return AsahiStage1Adapter(
            installer=installer,
            metadata_path=str(self.metadata),
            payload_path=str(self.payload),
            stub_size=2 * GIB,
            raw_partition_writer=writer,
            image_flush=lambda stream: None,
            raw_partition_opener=lambda name: io.BytesIO(
                self.raw_images[name]
            ),
        )

    def _retry_adapter(
        self,
        target_evidence,
        installed_evidence,
        changed_partition=None,
    ):
        target = json.loads(target_evidence)
        installed = json.loads(installed_evidence)
        parts = [
            FakePart(
                target["partition_identifier"],
                offset=target["offset_bytes"],
                size=target["size_bytes"],
                free=False,
                uuid=target["uuid"],
            )
        ]
        next_offset = target["offset_bytes"] + target["size_bytes"]
        for item in installed["populated_partitions"]:
            identity = item["partition_uuid"]
            if item["partition_identifier"] == changed_partition:
                identity = "changed-uuid"
            parts.append(
                FakePart(
                    item["partition_identifier"],
                    offset=next_offset,
                    size=item["partition_size_bytes"],
                    free=False,
                    uuid=identity,
                )
            )
            next_offset += item["partition_size_bytes"]
        return self._adapter(FakeInstaller(FakeDiskUtil([parts])))

    def _target_metadata(self):
        return {
            "omarchy_target": "apple-silicon-full-os",
            "minimum_size": 64 * GIB,
            "name": "Omarchy MX Mac",
            "default_os_name": "Omarchy",
            "boot_object": "m1n1.bin",
            "next_object": "m1n1/boot.bin",
            "package": self.payload.name,
            "icon": "omarchy-volume.icns",
            "supported_fw": None,
            "partitions": [
                {
                    "name": "EFI",
                    "type": "EFI",
                    "size": "500MB",
                    "format": "fat",
                    "copy_firmware": True,
                    "copy_installer_data": True,
                    "source": "esp",
                },
                {
                    "name": "Boot",
                    "type": "Linux",
                    "size": "2GB",
                    "image": "boot.img",
                },
                {
                    "name": "Root",
                    "type": "Linux",
                    "size": "32GB",
                    "expand": True,
                    "image": "root.img",
                },
            ],
        }

    def _write_metadata(self, targets=None):
        if targets is None:
            targets = [self._target_metadata()]
        if self.metadata.exists():
            self.metadata.chmod(0o600)
        self.metadata.write_text(
            json.dumps({"os_list": targets}),
            encoding="utf-8",
        )
        self.metadata.chmod(0o400)


class AsahiInPlaceRepairAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.payload = self.root / "payload.zip"
        self.content = {
            "disk0s3": bytearray(b"stub-old"),
            "disk0s4": bytearray(b"efi-old!"),
            "disk0s5": bytearray(b"boot-old"),
            "disk0s6": bytearray(b"root-old"),
        }
        replacements = {
            "boot": b"boot-new",
            "root": b"root-new",
        }
        with zipfile.ZipFile(self.payload, "w") as archive:
            for role, content in replacements.items():
                archive.writestr(f"repair/{role}.img", content)
        self.manifest = {
            "partitions": [
                {"role": "stub", "identifier": "disk0s3"},
                {"role": "efi", "identifier": "disk0s4"},
                {"role": "boot", "identifier": "disk0s5"},
                {"role": "root", "identifier": "disk0s6"},
            ],
            "existing_content": {
                role: self._identity(self.content[identifier])
                for role, identifier in (
                    ("stub", "disk0s3"),
                    ("efi", "disk0s4"),
                    ("boot", "disk0s5"),
                    ("root", "disk0s6"),
                )
            },
            "replacement_content": {
                "stub": {
                    **self._identity(self.content["disk0s3"]),
                    "payload_member": None,
                },
                "efi": {
                    **self._identity(self.content["disk0s4"]),
                    "payload_member": None,
                },
                "boot": {
                    **self._identity(replacements["boot"]),
                    "payload_member": "repair/boot.img",
                },
                "root": {
                    **self._identity(replacements["root"]),
                    "payload_member": "repair/root.img",
                },
            },
        }
        self.disk_utility = FakeDiskUtil([[]])
        self.installer = SimpleNamespace(dutil=self.disk_utility)
        self.opened_partitions = []
        self.adapter = AsahiInPlaceRepairAdapter(
            installer=self.installer,
            manifest=self.manifest,
            metadata_path=self.root / "metadata.json",
            payload_path=self.payload,
            raw_partition_opener=self._open_partition,
            boot_policy_authorizer=lambda *_: b"authorized",
        )
        self.plan = SimpleNamespace(plan_digest="a" * 64)

    def tearDown(self):
        self.temporary.cleanup()

    def test_repair_rewrites_only_declared_content_without_partitioning(self):
        existing = json.loads(
            self.adapter.validate_existing_install(self.plan)
        )
        written = json.loads(self.adapter.rewrite_existing_content(self.plan))
        repaired = json.loads(
            self.adapter.validate_repaired_content(self.plan)
        )

        self.assertEqual(set(existing["content"]), {"boot", "root"})
        self.assertEqual(existing["preserved_roles"], ["stub", "efi"])
        self.assertEqual(written["rewritten_roles"], ["boot", "root"])
        self.assertEqual(set(repaired["content"]), {"boot", "root"})
        self.assertEqual(repaired["preserved_roles"], ["stub", "efi"])
        self.assertEqual(self.content["disk0s3"], b"stub-old")
        self.assertEqual(self.content["disk0s4"], b"efi-old!")
        self.assertEqual(self.content["disk0s5"], b"boot-new")
        self.assertEqual(self.content["disk0s6"], b"root-new")
        self.assertEqual(self.disk_utility.resize_calls, [])
        self.assertEqual(self.disk_utility.add_calls, [])

    def test_readback_is_exhaustive_for_declared_writes_and_skips_preserved_content(self):
        self.adapter.validate_existing_install(self.plan)
        self.adapter.rewrite_existing_content(self.plan)
        self.content["disk0s4"][0] ^= 1

        self.assertEqual(
            json.loads(self.adapter.validate_repaired_content(self.plan))["preserved_roles"],
            ["stub", "efi"],
        )
        self.content["disk0s5"][0] ^= 1

        with self.assertRaisesRegex(
            AsahiAdapterError,
            "repair content changed",
        ):
            self.adapter.validate_repaired_content(self.plan)

    @staticmethod
    def _identity(content):
        return {
            "size_bytes": len(content),
            "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
        }

    def _open_partition(self, identifier, mode):
        self.opened_partitions.append((identifier, mode))
        return PartitionAccess(self.content[identifier], "w" in mode or "+" in mode)


class FakePart:
    def __init__(
        self,
        name,
        *,
        offset,
        size,
        free,
        part_type="Apple_APFS",
        uuid="PART-UUID",
    ):
        self.name = name
        self.offset = offset
        self.size = size
        self.free = free
        self.type = part_type
        self.uuid = uuid


class FakeDiskUtil:
    def __init__(self, partition_rounds):
        self.partition_rounds = list(partition_rounds)
        self.round = 0
        self.resize_calls = []
        self.add_calls = []
        self.mount_points = {}

    def get_info(self):
        return None

    def get_partitions(self, disk):
        index = min(self.round, len(self.partition_rounds) - 1)
        self.round += 1
        return self.partition_rounds[index]

    def resizeContainer(self, name, new_size):
        self.resize_calls.append((name, new_size))

    def addPartition(self, name, part_type, label, size):
        self.add_calls.append((name, part_type, label, size))
        source = self.partition_rounds[-1][0]
        return FakePart(
            "disk0s4",
            offset=source.offset,
            size=size,
            free=False,
        )

    def mount(self, name):
        return self.mount_points[name]


class PartitionAccess:
    def __init__(self, content, writable):
        self.content = content
        self.writable = writable
        self.stream = io.BytesIO(bytes(content))

    def __enter__(self):
        return self.stream

    def __exit__(self, exc_type, exc_value, traceback):
        if exc_type is None and self.writable:
            self.content[:] = self.stream.getvalue()
        self.stream.close()


class FakeInstaller:
    def __init__(self, dutil):
        self.dutil = dutil
        self.sys_disk = "disk0"
        self.sysinfo = object()
        self.osinfo = object()
        self.cur_os = "current-os"
        self.chosen_firmware = "unset"
        self.check_cur_os_calls = 0

    def choose_ipsw(self, supported_firmware):
        self.chosen_firmware = supported_firmware
        return "ipsw-image"

    def check_cur_os(self):
        self.check_cur_os_calls += 1


if __name__ == "__main__":
    unittest.main()
