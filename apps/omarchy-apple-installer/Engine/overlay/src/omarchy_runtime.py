# SPDX-License-Identifier: MIT
"""Closed execution runtime presented to the pinned upstream entry point."""

import os

import omarchy_asahi
import omarchy_contract
import omarchy_execution
import omarchy_planner
import omarchy_repair
import omarchy_stage1


ENVIRONMENT_KEYS = {
    "OMARCHY_ENGINE_MODE",
    "OMARCHY_ENGINE_JOURNAL",
    "OMARCHY_ENGINE_REQUEST",
    "OMARCHY_ENGINE_IDENTITY",
    "OMARCHY_ENGINE_METADATA",
    "OMARCHY_ENGINE_PAYLOAD",
    "OMARCHY_ENGINE_REPAIR_MANIFEST",
    "OMARCHY_ENGINE_BINDING_DIGEST",
    "OMARCHY_ENGINE_PLAN_DIGEST",
    "OMARCHY_MACHINE_OWNER",
    "DISTRO",
    "DISTRO_DOCS",
}


class EngineRuntimeError(omarchy_contract.ContractError):
    pass


class EngineRuntime:
    def __init__(self, *, mode, values):
        self.mode = mode
        self.values = values
        self.journal = omarchy_contract.Journal(
            values["OMARCHY_ENGINE_JOURNAL"]
        )
        self.device_identifier = None

    @classmethod
    def from_environment(cls, environment=None):
        environment = os.environ if environment is None else environment
        values = {
            key: environment.get(key)
            for key in ENVIRONMENT_KEYS
            if environment.get(key)
        }
        mode = values.get("OMARCHY_ENGINE_MODE")
        if mode is None:
            if values:
                raise EngineRuntimeError("engine mode is missing")
            return None
        if mode not in (
            "inspect",
            "plan",
            "install",
            "retry-recovery-authorization",
        ):
            raise EngineRuntimeError("unsupported engine mode")
        if environment.get("EXPERT"):
            raise EngineRuntimeError("expert mode is forbidden")

        required = {
            "inspect": {"OMARCHY_ENGINE_JOURNAL"},
            "plan": {
                "OMARCHY_ENGINE_JOURNAL",
                "OMARCHY_ENGINE_REQUEST",
                "OMARCHY_ENGINE_IDENTITY",
            },
            "install": ENVIRONMENT_KEYS
            - {
                "OMARCHY_ENGINE_MODE",
                "OMARCHY_ENGINE_REPAIR_MANIFEST",
            },
            "retry-recovery-authorization": ENVIRONMENT_KEYS
            - {
                "OMARCHY_ENGINE_MODE",
                "OMARCHY_ENGINE_REPAIR_MANIFEST",
            },
        }[mode]
        missing = sorted(required - set(values))
        if missing:
            raise EngineRuntimeError(
                "missing engine environment: " + ",".join(missing)
            )
        return cls(mode=mode, values=values)

    def metadata(self, bundled_metadata):
        if self.mode not in (
            "install",
            "retry-recovery-authorization",
        ):
            return bundled_metadata
        return omarchy_asahi.load_metadata(
            self.values["OMARCHY_ENGINE_METADATA"]
        )

    def inspect(self, device_class, supported):
        self.device_identifier = (
            omarchy_contract.normalize_device_identifier(device_class)
        )
        self.journal.inspection(
            self.device_identifier,
            "supported" if supported else "unsupported",
        )

    def run_layout(
        self,
        *,
        installer,
        free_parts,
        resizable_parts,
        stub_size,
        part_align,
    ):
        if self.device_identifier is None:
            inspection = self.journal.inspection_payload
            if inspection is None:
                raise EngineRuntimeError("inspection is required")
            self.device_identifier = inspection["device_identifier"]
        if self.journal.inspection_payload["support"] != "supported":
            raise EngineRuntimeError("unsupported device has no layout")

        repair_manifest = None
        repair_manifest_path = self.values.get(
            "OMARCHY_ENGINE_REPAIR_MANIFEST"
        )
        if repair_manifest_path is not None:
            repair_manifest = omarchy_repair.load_repair_manifest(
                repair_manifest_path
            )
            if repair_manifest["device_identifier"] != self.device_identifier:
                raise EngineRuntimeError("repair device changed")
            collected = omarchy_repair.collect_repair_inventory(
                installer,
                repair_manifest,
                disk_identity_reader=(
                    omarchy_repair.read_normalized_disk_identity
                ),
                filesystem_identity_reader=(
                    omarchy_repair.inspect_filesystem_identity
                ),
            )
        else:
            collected = omarchy_planner.collect_inventory(
                installer,
                free_parts,
                resizable_parts,
                stub_size,
                part_align,
            )
        live = omarchy_contract.normalized_inventory(
            collected["system_store_identifier"],
            collected["candidates"],
        )
        if self.journal.inventory_payload is None:
            self.journal.inventory(
                live["system_store_identifier"],
                live["candidates"],
            )
        elif self.journal.plan_payload is None or self.mode not in (
            "install",
            "retry-recovery-authorization",
        ):
            self.journal.inventory(
                live["system_store_identifier"],
                live["candidates"],
            )
        elif (
            live["system_store_identifier"]
            != self.journal.inventory_payload["system_store_identifier"]
        ):
            raise EngineRuntimeError("system store changed during resume")

        if self.mode == "inspect":
            return "inspected"
        if self.mode == "plan":
            omarchy_planner.emit_plan(
                self.journal,
                self.values["OMARCHY_ENGINE_REQUEST"],
                self.values["OMARCHY_ENGINE_IDENTITY"],
                self.device_identifier,
                part_align,
            )
            return "planned"

        admission_inventory = self.journal.inventory_payload
        if (
            self.journal.plan_payload is not None
            and not self.journal.events
            and not self.journal.checkpoints
            and self.journal.completion_outcome is None
        ):
            admission_inventory = live

        plan = omarchy_execution.admit_execution(
            request_path=self.values["OMARCHY_ENGINE_REQUEST"],
            identity_path=self.values["OMARCHY_ENGINE_IDENTITY"],
            live_inventory=admission_inventory,
            expected_binding_digest=self.values[
                "OMARCHY_ENGINE_BINDING_DIGEST"
            ],
            expected_plan_digest=self.values[
                "OMARCHY_ENGINE_PLAN_DIGEST"
            ],
        )
        self._record_execution_plan(plan)
        if getattr(plan, "operation", "install") == omarchy_repair.REPAIR_OPERATION:
            if repair_manifest is None:
                raise EngineRuntimeError("repair manifest is required")
            adapter = omarchy_asahi.AsahiInPlaceRepairAdapter(
                installer=installer,
                manifest=repair_manifest,
                metadata_path=self.values["OMARCHY_ENGINE_METADATA"],
                payload_path=self.values["OMARCHY_ENGINE_PAYLOAD"],
            )
            executor = omarchy_repair.RepairExecutor(adapter)
            if self.mode == "retry-recovery-authorization":
                return executor.retry_boot_policy(
                    plan,
                    self.journal,
                )
            return executor.apply(
                plan,
                self.journal,
            )
        completed = omarchy_stage1.validate_stage1_resume(
            plan,
            self.journal,
        )
        if completed is not None:
            if self.mode == "retry-recovery-authorization":
                raise EngineRuntimeError(
                    "Recovery authorization is already complete"
                )
            return completed

        adapter = omarchy_asahi.AsahiStage1Adapter(
            installer=installer,
            metadata_path=self.values["OMARCHY_ENGINE_METADATA"],
            payload_path=self.values["OMARCHY_ENGINE_PAYLOAD"],
            stub_size=stub_size,
            full_readback=os.environ.get("OMARCHY_FULL_READBACK") == "1",
        )
        with omarchy_asahi.timing("preflight"):
            adapter.preflight(plan)
        if self.mode == "retry-recovery-authorization":
            return omarchy_stage1.retry_recovery_authorization(
                plan,
                self.journal,
                adapter,
            )
        return omarchy_stage1.run_stage1(
            plan,
            self.journal,
            adapter,
        )

    def _record_execution_plan(self, plan):
        digest = self.journal.plan(
            device_identifier=plan.device_identifier,
            layout_digest=plan.layout_digest,
            candidate_kind=plan.candidate_kind,
            source_identifier=plan.source_identifier,
            requested_length_bytes=plan.length_bytes,
            engine_version=plan.engine_version,
            engine_digest=plan.engine_digest,
            metadata_digest=plan.metadata_digest,
            payload_digest=plan.payload_digest,
            repair_manifest_digest=getattr(
                plan,
                "repair_manifest_digest",
                None,
            ),
            required_human_steps=list(plan.required_human_steps),
        )
        if digest != plan.plan_digest:
            raise EngineRuntimeError("admitted plan journal mismatch")
