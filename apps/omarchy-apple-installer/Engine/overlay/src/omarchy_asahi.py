# SPDX-License-Identifier: MIT
"""Concrete stage-1 adapter over pinned upstream Asahi primitives."""

import hashlib
import io
import json
import os
import re
import stat
import shutil
import subprocess
import sys
import zipfile
from pathlib import PurePosixPath

import asahi_firmware
import osinstall
import stub

import omarchy_planner
from omarchy_image import (
    WRITE_VERIFICATION, flush_device, hash_target, open_target, timing, write_image,
)


TARGET = "apple-silicon-full-os"
MAXIMUM_PASSWORD_BYTES = 1_024
MACHINE_OWNER_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,255}$")
PARTITION_PATTERN = re.compile(r"^disk[0-9]+s[0-9]+$")
READBACK_CHUNK_BYTES = 1024 * 1024


class AsahiAdapterError(RuntimeError):
    pass


class AsahiInPlaceRepairAdapter:
    """Non-partitioning adapter for one manifest-bound installed system."""

    def __init__(
        self,
        *,
        installer,
        manifest,
        metadata_path,
        payload_path,
        raw_partition_opener=None,
        boot_policy_authorizer=None,
    ):
        self.installer = installer
        self.manifest = manifest
        self.metadata_path = metadata_path
        self.payload_path = payload_path
        self.raw_partition_opener = (
            raw_partition_opener or self._open_raw_partition
        )
        self.boot_policy_authorizer = (
            boot_policy_authorizer or self._authorize_boot_policy
        )

    def validate_existing_install(self, plan):
        return self._content_evidence(
            plan,
            self.manifest["existing_content"],
            "existing",
        )

    def rewrite_existing_content(self, plan):
        rewritten = []
        try:
            payload = zipfile.ZipFile(self.payload_path)
        except (OSError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("invalid repair payload") from error
        with payload:
            names = payload.namelist()
            if len(names) != len(set(names)):
                raise AsahiAdapterError("ambiguous repair payload")
            for role in ("stub", "efi", "boot", "root"):
                expected = self.manifest["replacement_content"][role]
                member = expected["payload_member"]
                if member is None:
                    if expected != {
                        **self.manifest["existing_content"][role],
                        "payload_member": None,
                    }:
                        raise AsahiAdapterError(
                            "preserved repair content changed"
                        )
                    continue
                if (
                    not isinstance(member, str)
                    or member not in names
                    or PurePosixPath(member).is_absolute()
                    or ".." in PurePosixPath(member).parts
                ):
                    raise AsahiAdapterError("invalid repair payload member")
                info = payload.getinfo(member)
                if info.file_size != expected["size_bytes"]:
                    raise AsahiAdapterError("repair payload size changed")
                identifier = self._partition_identifier(role)
                digest = hashlib.sha256()
                written = 0
                with payload.open(info) as source, self.raw_partition_opener(
                    identifier,
                    "r+b",
                ) as target:
                    target.seek(0)
                    while True:
                        chunk = source.read(READBACK_CHUNK_BYTES)
                        if not chunk:
                            break
                        digest.update(chunk)
                        written += len(chunk)
                        if target.write(chunk) != len(chunk):
                            raise AsahiAdapterError(
                                "incomplete repair content write"
                            )
                    target.flush()
                    try:
                        os.fsync(target.fileno())
                    except (AttributeError, io.UnsupportedOperation):
                        pass
                if (
                    written != expected["size_bytes"]
                    or "sha256:" + digest.hexdigest() != expected["sha256"]
                ):
                    raise AsahiAdapterError("repair payload digest changed")
                rewritten.append(role)
        return self._canonical_evidence(
            plan,
            {"rewritten_roles": rewritten},
        )

    def validate_repaired_content(self, plan):
        return self._content_evidence(
            plan,
            self.manifest["replacement_content"],
            "repaired",
        )

    def authorize_existing_boot_policy(self, plan):
        evidence = self.boot_policy_authorizer(
            plan,
            self._partition_identifier("stub"),
        )
        if not isinstance(evidence, bytes) or not evidence:
            raise AsahiAdapterError("invalid repair authorization evidence")
        return evidence

    def _content_evidence(self, plan, expected_by_role, state):
        observed = {}
        preserved_roles = [
            role
            for role in ("stub", "efi", "boot", "root")
            if self.manifest["replacement_content"][role]["payload_member"]
            is None
        ]
        rewritten_roles = [
            role
            for role in ("stub", "efi", "boot", "root")
            if role not in preserved_roles
        ]
        for role in rewritten_roles:
            expected = expected_by_role[role]
            size = expected["size_bytes"]
            digest = hashlib.sha256()
            remaining = size
            with self.raw_partition_opener(
                self._partition_identifier(role),
                "rb",
            ) as stream:
                stream.seek(0)
                while remaining:
                    chunk = stream.read(min(remaining, READBACK_CHUNK_BYTES))
                    if not chunk:
                        raise AsahiAdapterError("repair content changed")
                    digest.update(chunk)
                    remaining -= len(chunk)
            actual = "sha256:" + digest.hexdigest()
            if actual != expected["sha256"]:
                raise AsahiAdapterError("repair content changed")
            observed[role] = {"size_bytes": size, "sha256": actual}
        return self._canonical_evidence(
            plan,
            {
                "state": state,
                "content": observed,
                "preserved_roles": preserved_roles,
            },
        )

    def _partition_identifier(self, role):
        matches = [
            item["identifier"]
            for item in self.manifest["partitions"]
            if item["role"] == role
        ]
        if len(matches) != 1 or PARTITION_PATTERN.fullmatch(matches[0]) is None:
            raise AsahiAdapterError("repair partition identity changed")
        return matches[0]

    @staticmethod
    def _canonical_evidence(plan, evidence):
        return json.dumps(
            {"plan_digest": plan.plan_digest, **evidence},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    @staticmethod
    def _open_raw_partition(identifier, mode):
        if PARTITION_PATTERN.fullmatch(identifier or "") is None:
            raise AsahiAdapterError("invalid raw partition identity")
        return open("/dev/r" + identifier, mode, buffering=0)

    def _authorize_boot_policy(self, plan, stub_identifier):
        owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
        if MACHINE_OWNER_PATTERN.fullmatch(owner) is None:
            raise AsahiAdapterError("machine owner is unavailable")
        password_input = sys.stdin.buffer.read(MAXIMUM_PASSWORD_BYTES + 2)
        if not password_input.endswith(b"\n"):
            raise AsahiAdapterError("machine owner password is unavailable")
        password = password_input[:-1]
        if (
            not password
            or len(password) > MAXIMUM_PASSWORD_BYTES
            or b"\x00" in password
            or b"\n" in password
            or b"\r" in password
        ):
            raise AsahiAdapterError("machine owner password is invalid")

        matches = [
            part
            for part in self.installer.parts
            if part.name == stub_identifier and not part.free
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("repair stub identity changed")
        target = matches[0]
        existing = stub.StubInstaller(
            self.installer.sysinfo,
            self.installer.dutil,
            self.installer.osinfo,
        )
        existing.check_volume(target)
        existing.prepare_for_bless()
        try:
            subprocess.run(
                [
                    "/usr/sbin/bless",
                    "--setBoot",
                    "--device",
                    "/dev/" + existing.osi.sys_volume,
                    "--user",
                    owner,
                    "--stdinpass",
                ],
                input=password_input,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise AsahiAdapterError(
                "Recovery handoff authorization failed"
            ) from error
        existing.prepare_for_step2()
        return self._canonical_evidence(
            plan,
            {"outcome": "awaiting_recovery"},
        )


class OmarchyOSInstaller(osinstall.OSInstaller):
    def install_raw_image(self, image, info):
        self.image_receipts[image] = write_image(
            self.pkg, image, info,
            opener=self.image_opener, flush=self.image_flush,
        )


class AsahiStage1Adapter:
    def __init__(
        self,
        *,
        installer,
        metadata_path,
        payload_path,
        stub_size,
        raw_partition_opener=None,
        raw_partition_writer=None,
        image_flush=flush_device,
        full_readback=False,
    ):
        self.installer = installer
        self.metadata_path = metadata_path
        self.payload_path = payload_path
        self.stub_size = stub_size
        self.raw_partition_opener = (
            raw_partition_opener or self._open_raw_partition
        )
        self.image_writer = raw_partition_writer or open_target
        self.image_flush = image_flush
        self.full_readback = full_readback
        self.template = None
        self.osins = None
        self.target_part = None
        self.preflight_complete = False

    def preflight(self, plan):
        if self.preflight_complete:
            return
        metadata = self._load_metadata()
        templates = [
            template
            for template in metadata["os_list"]
            if template.get("omarchy_target") == TARGET
        ]
        if len(templates) != 1:
            raise AsahiAdapterError(
                "metadata must contain exactly one Omarchy full-OS target"
            )
        self.installer.data = metadata
        self.template = templates[0]
        self.osins = OmarchyOSInstaller(
            self.installer.dutil,
            metadata,
            self.template,
        )
        self.osins.image_receipts = {}
        self.osins.image_opener = self.image_writer
        self.osins.image_flush = self.image_flush
        if (
            plan.length_bytes
            < self.stub_size + self.osins.min_recommended_size
        ):
            raise AsahiAdapterError(
                "approved extent is smaller than Asahi minimum"
            )
        try:
            self.osins.pkg = zipfile.ZipFile(self.payload_path)
            # Authenticated package admission precedes this adapter. CRC is
            # checked during extraction; avoid a separate full expansion.
        except (OSError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("invalid Omarchy payload") from error
        self._validate_full_os_package()
        ipsw = self.installer.choose_ipsw(
            self.template.get("supported_fw"),
        )
        self.installer.ins = stub.StubInstaller(
            self.installer.sysinfo,
            self.installer.dutil,
            self.installer.osinfo,
        )
        self.installer.ins.load_ipsw(ipsw)
        self.installer.osins = self.osins
        self.preflight_complete = True

    def remove_existing_install(self, plan):
        """Free the exact partitions of the approved existing install.

        Runs against the partition table the admission just validated: the
        candidate identity digest is re-derived from the live parts and must
        equal the approved plan's before anything is erased. Erasure
        addresses partitions by UUID because identifiers shift as space is
        released. Afterwards one free extent must cover the approved extent.
        """
        self._require_preflight()
        if plan.candidate_kind != "replace":
            raise AsahiAdapterError("removal requires a replace candidate")
        if not plan.candidate_identity_digest:
            raise AsahiAdapterError("replace plan carries no identity")
        self.installer.check_cur_os()

        os_label = self.template.get("default_os_name")
        candidates = omarchy_planner.collect_existing_installs(
            self.installer,
            os_label,
            plan.minimum_install_bytes,
            1,
        )
        matches = [
            candidate
            for candidate in candidates
            if candidate["source_identifier"] == plan.source_identifier
            and candidate["offset_bytes"] == plan.offset_bytes
            and candidate["length_bytes"] >= plan.length_bytes
            and candidate["identity_digest"]
            == plan.candidate_identity_digest
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("approved existing install changed")

        stub_index = next(
            index
            for index, part in enumerate(self.installer.parts)
            if not part.free and part.name == plan.source_identifier
        )
        members = self.installer.parts[stub_index : stub_index + 4]
        observed = omarchy_planner.replace_identity_digest(
            members,
            os_label,
            next(
                getattr(os_info, "vgid", None)
                for os_info in members[0].os
                if getattr(os_info, "stub", False)
                and getattr(os_info, "label", None) == os_label
            ),
        )
        if observed != plan.candidate_identity_digest:
            raise AsahiAdapterError("approved existing install changed")

        container = getattr(members[0], "container", None) or {}
        reference = container.get("ContainerReference")
        if not isinstance(reference, str) or not reference:
            raise AsahiAdapterError("existing stub container is unreadable")
        self.installer.dutil.action(
            "apfs", "deleteContainer", reference, verbose=True
        )
        for member in members:
            self.installer.dutil.action(
                "eraseVolume", "free", "none", member.uuid, verbose=True
            )
        self._refresh_parts()
        freed = self._find_free_extent(plan)
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "removed": [
                    {
                        "name": member.name,
                        "offset_bytes": member.offset,
                        "size_bytes": member.size,
                        "type": member.type,
                        "uuid": member.uuid,
                    }
                    for member in members
                ],
                "free_offset_bytes": freed.offset,
                "free_size_bytes": freed.size,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def prepare_target(self, plan):
        self._require_preflight()
        self.installer.check_cur_os()
        self._refresh_parts()
        if plan.candidate_kind == "resize":
            source = self._find_partition(
                name=plan.source_identifier,
                free=False,
            )
            new_size = source.size - plan.length_bytes
            if new_size < plan.minimum_container_bytes:
                raise AsahiAdapterError(
                    "resize would cross the approved minimum"
                )
            self.installer.dutil.resizeContainer(source.name, new_size)
            self._refresh_parts()
        free = self._find_free_extent(plan)
        self.target_part = self.installer.dutil.addPartition(
            free.name,
            "apfs",
            self.osins.name,
            self.stub_size,
        )
        self.installer.part = self.target_part
        return self._target_evidence(plan)

    def install_stub_and_esp(self, plan):
        self._require_preflight()
        if self.target_part is None:
            self._refresh_parts()
            self.target_part = self._find_prepared_target(plan)
            self.installer.part = self.target_part

        self.installer.ins.prepare_volume(self.target_part)
        self.installer.ins.check_volume()
        self.installer.ins.install_files(self.installer.cur_os)
        os_size = plan.length_bytes - self.stub_size
        self.osins.partition_disk(self.target_part.name, os_size)

        firmware_package = None
        if self.osins.needs_firmware:
            os.makedirs("vendorfw", exist_ok=True)
            firmware_package = asahi_firmware.core.FWPackage(
                "vendorfw"
            )
            self.installer.ins.collect_firmware(firmware_package)
            firmware_package.close()
            self.osins.firmware_package = firmware_package

        self.osins.install(self.installer.ins)
        for target in self.osins.idata_targets:
            self.installer.ins.collect_installer_data(target)
            shutil.copy(
                "installer.log",
                os.path.join(target, "installer.log"),
            )
        return self._installed_evidence(plan)

    def validate_installed_checkpoint(
        self,
        plan,
        target_evidence,
        installed_evidence,
    ):
        """Re-read the exact completed stage-one state without mutation."""
        self._require_preflight()
        target = self._parse_checkpoint_evidence(
            target_evidence,
            {
                "plan_digest",
                "partition_identifier",
                "offset_bytes",
                "size_bytes",
                "uuid",
            },
        )
        installed = self._parse_checkpoint_evidence(
            installed_evidence,
            {
                "plan_digest",
                "apfs_vgid",
                "system_volume",
                "efi_partition",
                "startup_volume_icon",
                "populated_partitions",
            },
        )
        if (
            target["plan_digest"] != plan.plan_digest
            or installed["plan_digest"] != plan.plan_digest
        ):
            raise AsahiAdapterError("installed checkpoint plan changed")

        self._refresh_parts()
        self.target_part = self._find_prepared_target(plan)
        self.installer.part = self.target_part
        if self._target_evidence(plan) != target_evidence:
            raise AsahiAdapterError("prepared target identity changed")

        recorded = installed["populated_partitions"]
        if (
            not isinstance(recorded, list)
            or len(recorded) != len(self.template["partitions"])
        ):
            raise AsahiAdapterError("installed partition count changed")
        expected_keys = {
            "name",
            "partition_identifier",
            "partition_uuid",
            "partition_size_bytes",
            "population",
            "installed_bytes",
            "verification",
            "content_sha256",
        }
        identifiers = []
        for item, partition in zip(
            recorded,
            self.template["partitions"],
            strict=True,
        ):
            if not isinstance(item, dict) or set(item) != expected_keys:
                raise AsahiAdapterError(
                    "installed checkpoint shape changed"
                )
            expected_population = partition.get("image") or partition.get(
                "source"
            )
            if (
                item["name"] != partition["name"]
                or item["population"] != expected_population
            ):
                raise AsahiAdapterError(
                    "installed checkpoint metadata changed"
                )
            identifiers.append(item["partition_identifier"])

        extent_end = plan.offset_bytes + plan.length_bytes
        physical = [
            part
            for part in self.installer.parts
            if not part.free
            and part.offset >= self.target_part.offset + self.target_part.size
            and part.offset < extent_end
        ]
        physical.sort(key=lambda part: part.offset)
        if [part.name for part in physical] != identifiers:
            raise AsahiAdapterError("installed partition identity changed")

        for item, part in zip(recorded, physical, strict=True):
            if (
                not isinstance(part.uuid, str)
                or part.uuid.lower() != item["partition_uuid"]
                or part.size != item["partition_size_bytes"]
                or part.offset + part.size > extent_end
            ):
                raise AsahiAdapterError(
                    "installed partition identity changed"
                )

        self.osins.part_info = physical
        self.osins.efi_part = next(
            (
                part
                for partition, part in zip(
                    self.template["partitions"],
                    physical,
                    strict=True,
                )
                if partition["type"] == "EFI"
            ),
            None,
        )
        self.installer.ins.check_volume(self.target_part)
        if self._installed_evidence(plan, recorded=recorded) != installed_evidence:
            raise AsahiAdapterError("installed content checkpoint changed")

    def prepare_recovery_handoff(self, plan):
        self._require_preflight()
        owner = os.environ.get("OMARCHY_MACHINE_OWNER", "")
        if MACHINE_OWNER_PATTERN.fullmatch(owner) is None:
            raise AsahiAdapterError("machine owner is unavailable")

        password_input = sys.stdin.buffer.read(MAXIMUM_PASSWORD_BYTES + 2)
        if not password_input.endswith(b"\n"):
            raise AsahiAdapterError("machine owner password is unavailable")
        password = password_input[:-1]
        if (
            not password
            or len(password) > MAXIMUM_PASSWORD_BYTES
            or b"\x00" in password
            or b"\n" in password
            or b"\r" in password
        ):
            raise AsahiAdapterError("machine owner password is invalid")

        if self.target_part is None:
            self._refresh_parts()
            self.target_part = self._find_prepared_target(plan)
            self.installer.part = self.target_part
        if not hasattr(self.installer.ins, "osi"):
            self.installer.ins.check_volume(self.target_part)

        self.installer.ins.prepare_for_bless()
        try:
            subprocess.run(
                [
                    "/usr/sbin/bless",
                    "--setBoot",
                    "--device",
                    "/dev/" + self.installer.ins.osi.sys_volume,
                    "--user",
                    owner,
                    "--stdinpass",
                ],
                input=password_input,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise AsahiAdapterError(
                "Recovery handoff authorization failed"
            ) from error

        self.installer.ins.prepare_for_step2()
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "outcome": "awaiting_recovery",
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def _load_metadata(self):
        return load_metadata(self.metadata_path)

    def _parse_checkpoint_evidence(self, evidence, expected_keys):
        try:
            payload = json.loads(evidence)
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
            raise AsahiAdapterError(
                "installed checkpoint is invalid"
            ) from error
        if (
            not isinstance(payload, dict)
            or set(payload) != expected_keys
            or json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            != evidence
        ):
            raise AsahiAdapterError("installed checkpoint is invalid")
        return payload

    def _refresh_parts(self):
        self.installer.dutil.get_info()
        self.installer.parts = self.installer.dutil.get_partitions(
            self.installer.sys_disk
        )

    def _find_partition(self, *, name, free):
        matches = [
            part
            for part in self.installer.parts
            if part.name == name and part.free is free
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("approved source partition changed")
        return matches[0]

    def _find_free_extent(self, plan):
        matches = [
            part
            for part in self.installer.parts
            if part.free
            and part.offset == plan.offset_bytes
            and part.size >= plan.length_bytes
        ]
        if len(matches) != 1:
            raise AsahiAdapterError("approved free extent changed")
        return matches[0]

    def _find_prepared_target(self, plan):
        minimum = int(self.stub_size * 0.95)
        maximum = int(self.stub_size * 1.05)
        matches = [
            part
            for part in self.installer.parts
            if not part.free
            and part.offset == plan.offset_bytes
            and minimum <= part.size <= maximum
            and isinstance(part.type, str)
            and "APFS" in part.type
        ]
        if len(matches) != 1:
            raise AsahiAdapterError(
                "prepared APFS target cannot be reconciled"
            )
        return matches[0]

    def _target_evidence(self, plan):
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "partition_identifier": self.target_part.name,
                "offset_bytes": self.target_part.offset,
                "size_bytes": self.target_part.size,
                "uuid": self.target_part.uuid,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def _installed_evidence(self, plan, recorded=None):
        osi = self.installer.ins.osi
        startup_volume_icon = self._verify_installed_file(
            self.template["icon"],
            self.installer.ins.icon_path,
        )
        populated_partitions = []
        if len(self.template["partitions"]) != len(self.osins.part_info):
            raise AsahiAdapterError("installed partition count changed")
        for partition, info in zip(
            self.template["partitions"],
            self.osins.part_info,
        ):
            image = partition.get("image")
            source = partition.get("source")
            if image:
                previous = next((item for item in (recorded or [])
                                 if item["population"] == image), None)
                receipt = previous or self.osins.image_receipts.get(image)
                if receipt is None:
                    raise AsahiAdapterError("completed image write receipt missing")
                installed_bytes = self.osins.pkg.getinfo(image).file_size
                if (receipt["partition_identifier"] != info.name
                        or receipt["partition_uuid"] != info.uuid.lower()
                        or receipt["partition_size_bytes"] != info.size
                        or receipt["installed_bytes"] != installed_bytes
                        or installed_bytes <= 0 or installed_bytes > info.size
                        or re.fullmatch(r"[0-9a-f]{64}", receipt["content_sha256"]) is None):
                    raise AsahiAdapterError("installed image receipt changed")
                content_digest = receipt["content_sha256"]
                verification = (previous["verification"] if previous else
                                WRITE_VERIFICATION if image == "root.img"
                                and not self.full_readback else "raw-prefix-sha256")
                if verification not in (WRITE_VERIFICATION, "raw-prefix-sha256"):
                    raise AsahiAdapterError("unknown image verification method")
                # On exceptional Recovery retry, recheck all installed images
                # against their recorded hashes without decompressing source.
                if previous or image != "root.img" or self.full_readback:
                    observed = hash_target(self.raw_partition_opener, info.name,
                                           installed_bytes)
                    if observed != content_digest:
                        raise AsahiAdapterError("installed content does not match payload")
                population = image
            else:
                installed_bytes, content_digest = self._verify_copied_tree(
                    source,
                    info,
                )
                population = source
                verification = "copied-tree-sha256"
            if installed_bytes <= 0:
                raise AsahiAdapterError("installed partition is empty")
            populated_partitions.append(
                {
                    "name": partition["name"],
                    "partition_identifier": info.name,
                    "partition_uuid": info.uuid.lower(),
                    "partition_size_bytes": info.size,
                    "population": population,
                    "installed_bytes": installed_bytes,
                    "verification": verification,
                    "content_sha256": content_digest,
                }
            )
        return json.dumps(
            {
                "plan_digest": plan.plan_digest,
                "apfs_vgid": osi.vgid,
                "system_volume": osi.sys_volume,
                "efi_partition": (
                    self.osins.efi_part.uuid.lower()
                    if self.osins.efi_part is not None
                    else None
                ),
                "startup_volume_icon": startup_volume_icon,
                "populated_partitions": populated_partitions,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def _verify_raw_image(self, image, info):
        if (
            PARTITION_PATTERN.fullmatch(info.name) is None
            or not isinstance(info.size, int)
        ):
            raise AsahiAdapterError("installed partition identity changed")
        member = self.osins.pkg.getinfo(image)
        if member.file_size <= 0 or member.file_size > info.size:
            raise AsahiAdapterError("installed image does not fit partition")
        try:
            with self.osins.pkg.open(member) as source:
                with self.raw_partition_opener(info.name) as target:
                    digest = self._matching_stream_digest(
                        source,
                        target,
                        member.file_size,
                    )
        except (OSError, KeyError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("installed image read-back failed") from error
        return member.file_size, digest

    def _verify_installed_file(self, member_name, target_path):
        try:
            member = self.osins.pkg.getinfo(member_name)
            target_status = os.lstat(target_path)
            if (
                not stat.S_ISREG(target_status.st_mode)
                or stat.S_ISLNK(target_status.st_mode)
                or target_status.st_size != member.file_size
                or member.file_size <= 0
            ):
                raise AsahiAdapterError("installed branding changed")
            flags = os.O_RDONLY
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(target_path, flags)
            with os.fdopen(descriptor, "rb") as observed, self.osins.pkg.open(
                member
            ) as expected:
                digest = self._matching_stream_digest(
                    expected,
                    observed,
                    member.file_size,
                )
        except (OSError, KeyError, zipfile.BadZipFile) as error:
            raise AsahiAdapterError("installed branding read-back failed") from error
        return {
            "member": member_name,
            "installed_bytes": member.file_size,
            "verification": "stub-file-sha256",
            "content_sha256": digest,
        }

    def _verify_copied_tree(self, source, info):
        if PARTITION_PATTERN.fullmatch(info.name) is None:
            raise AsahiAdapterError("installed partition identity changed")
        try:
            mountpoint = self.installer.dutil.mount(info.name)
            mount_status = os.lstat(mountpoint)
        except OSError as error:
            raise AsahiAdapterError("installed tree read-back failed") from error
        if not stat.S_ISDIR(mount_status.st_mode) or stat.S_ISLNK(
            mount_status.st_mode
        ):
            raise AsahiAdapterError("installed tree mount is unsafe")

        prefix = source.rstrip("/") + "/"
        members = sorted(
            (
                member
                for member in self.osins.pkg.infolist()
                if not member.is_dir()
                and member.filename.startswith(prefix)
            ),
            key=lambda member: member.filename,
        )
        if not members:
            raise AsahiAdapterError("installed tree source is empty")
        tree_digest = hashlib.sha256()
        installed_bytes = 0
        for member in members:
            relative = member.filename[len(prefix) :]
            target_path = os.path.join(mountpoint, *PurePosixPath(relative).parts)
            try:
                target_status = os.lstat(target_path)
                if (
                    not stat.S_ISREG(target_status.st_mode)
                    or stat.S_ISLNK(target_status.st_mode)
                    or target_status.st_size != member.file_size
                ):
                    raise AsahiAdapterError(
                        "installed tree member changed"
                    )
                flags = os.O_RDONLY
                if hasattr(os, "O_CLOEXEC"):
                    flags |= os.O_CLOEXEC
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(target_path, flags)
                with os.fdopen(descriptor, "rb") as observed, self.osins.pkg.open(
                    member
                ) as expected:
                    member_digest = self._matching_stream_digest(
                        expected,
                        observed,
                        member.file_size,
                    )
            except (OSError, KeyError, zipfile.BadZipFile) as error:
                raise AsahiAdapterError(
                    "installed tree read-back failed"
                ) from error
            encoded_name = member.filename.encode("utf-8")
            tree_digest.update(len(encoded_name).to_bytes(8, "big"))
            tree_digest.update(encoded_name)
            tree_digest.update(bytes.fromhex(member_digest))
            installed_bytes += member.file_size
        return installed_bytes, tree_digest.hexdigest()

    def _matching_stream_digest(self, expected, observed, expected_bytes):
        digest = hashlib.sha256()
        remaining = expected_bytes
        while remaining:
            chunk = expected.read(min(READBACK_CHUNK_BYTES, remaining))
            if not chunk:
                raise AsahiAdapterError("installed content is truncated")
            observed_chunk = bytearray()
            while len(observed_chunk) < len(chunk):
                addition = observed.read(len(chunk) - len(observed_chunk))
                if not addition:
                    raise AsahiAdapterError("installed content is truncated")
                observed_chunk.extend(addition)
            if chunk != observed_chunk:
                raise AsahiAdapterError("installed content differs from payload")
            digest.update(chunk)
            remaining -= len(chunk)
        if expected.read(1):
            raise AsahiAdapterError("payload member size changed")
        return digest.hexdigest()

    @staticmethod
    def _open_raw_partition(name):
        return open("/dev/r" + name, "rb", buffering=0)

    def _validate_full_os_package(self):
        if self.template.get("package") != os.path.basename(
            self.payload_path
        ):
            raise AsahiAdapterError("metadata package does not match payload")
        if (
            self.template.get("boot_object") != "m1n1.bin"
            or self.template.get("next_object") != "m1n1/boot.bin"
        ):
            raise AsahiAdapterError("invalid Omarchy boot chain metadata")
        if self.template.get("icon") != "omarchy-volume.icns":
            raise AsahiAdapterError(
                "invalid Omarchy Startup Options icon metadata"
            )

        partitions = self.template.get("partitions")
        expected = (
            ("EFI", "EFI", "esp", None, False),
            ("Boot", "Linux", None, "boot.img", False),
            ("Root", "Linux", None, "root.img", True),
        )
        if not isinstance(partitions, list) or len(partitions) != len(expected):
            raise AsahiAdapterError("invalid Omarchy full-OS partitions")
        for partition, contract in zip(partitions, expected):
            name, part_type, source, image, expand = contract
            if (
                partition.get("name") != name
                or partition.get("type") != part_type
                or partition.get("source") != source
                or partition.get("image") != image
                or bool(partition.get("expand", False)) is not expand
            ):
                raise AsahiAdapterError("invalid Omarchy full-OS partitions")
        efi = partitions[0]
        if (
            efi.get("format") != "fat"
            or efi.get("copy_firmware") is not True
            or efi.get("copy_installer_data") is not True
        ):
            raise AsahiAdapterError("invalid Omarchy ESP metadata")

        required = {
            "boot.img",
            "root.img",
            "esp/m1n1/boot.bin",
            "esp/EFI/BOOT/BOOTAA64.EFI",
            "omarchy-volume.icns",
        }
        members = {}
        for member in self.osins.pkg.infolist():
            path = PurePosixPath(member.filename)
            file_type = (member.external_attr >> 16) & 0o170000
            if (
                not member.filename
                or "\\" in member.filename
                or path.is_absolute()
                or ".." in path.parts
                or file_type == 0o120000
                or member.filename in members
            ):
                raise AsahiAdapterError("unsafe Omarchy payload member")
            members[member.filename] = member
        if not required.issubset(members):
            raise AsahiAdapterError("incomplete Omarchy full-OS payload")
        for name in required:
            if members[name].file_size <= 0:
                raise AsahiAdapterError("empty Omarchy full-OS payload member")
        for partition in partitions[1:]:
            try:
                capacity = osinstall.psize(partition["size"])
            except (KeyError, TypeError, ValueError) as error:
                raise AsahiAdapterError("invalid Omarchy partition capacity") from error
            if capacity <= 0 or members[partition["image"]].file_size > capacity:
                raise AsahiAdapterError("Omarchy image exceeds partition capacity")
        for name in ("boot.img", "root.img"):
            if members[name].file_size % 4096 != 0:
                raise AsahiAdapterError("Omarchy image size is not 4KiB aligned")

    def _require_preflight(self):
        if not self.preflight_complete:
            raise AsahiAdapterError("adapter preflight is required")


def load_metadata(path):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise AsahiAdapterError("metadata is unavailable") from error
    try:
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or status.st_size < 1
            or status.st_size > 65_536
        ):
            raise AsahiAdapterError("metadata is invalid")
        data = os.read(descriptor, status.st_size + 1)
    finally:
        os.close(descriptor)
    if not data or len(data) > 65_536:
        raise AsahiAdapterError("metadata is invalid")
    try:
        metadata = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AsahiAdapterError("metadata is invalid") from error
    if (
        not isinstance(metadata, dict)
        or set(metadata) != {"os_list"}
        or not isinstance(metadata["os_list"], list)
    ):
        raise AsahiAdapterError("metadata is invalid")
    return metadata
