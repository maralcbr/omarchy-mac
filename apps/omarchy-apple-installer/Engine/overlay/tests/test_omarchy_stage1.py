# SPDX-License-Identifier: MIT
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest


sys.path.insert(
    0,
    str(Path(__file__).resolve().parents[1] / "src"),
)

from omarchy_contract import Journal  # noqa: E402
from omarchy_stage1 import (  # noqa: E402
    AmbiguousMutationState,
    Stage1Error,
    retry_recovery_authorization,
    run_stage1,
    validate_stage1_resume,
)


class Stage1CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "engine.jsonl"
        self.journal = self._planned_journal()
        self.plan = SimpleNamespace(
            plan_digest=self.journal.plan_digest,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_stage1_runs_mutations_under_the_standard_umask(self):
        # The helper starts the engine with umask 077; the stub and ESP it
        # creates must still be world-readable or later unprivileged
        # enumeration of the existing install fails.
        import os

        seen = {}

        class UmaskAdapter:
            def __getattr__(self, name):
                def operation(plan):
                    current = os.umask(0)
                    os.umask(current)
                    seen[name] = current
                    return b"evidence"

                return operation

        previous = os.umask(0o077)
        try:
            run_stage1(self.plan, self.journal, UmaskAdapter())
        finally:
            os.umask(previous)
        self.assertEqual(len(seen), 3)
        self.assertEqual({0o022}, set(seen.values()))

    def test_fresh_stage1_runs_ordered_mutations_and_completes(self):
        adapter = RecordingStage1Adapter()

        outcome = run_stage1(self.plan, self.journal, adapter)

        self.assertEqual(outcome, "awaiting_recovery")
        self.assertEqual(
            adapter.calls,
            [
                "prepare_target",
                "install_stub_and_esp",
                "prepare_recovery_handoff",
            ],
        )
        self.assertEqual(
            list(self.journal.checkpoints),
            [
                "apfs-target-prepared",
                "stub-and-esp-installed",
                "recovery-handoff-prepared",
            ],
        )
        self.assertEqual(
            self.journal.completion_outcome,
            "awaiting_recovery",
        )

    def test_completed_stage1_retry_performs_no_mutation(self):
        first = RecordingStage1Adapter()
        run_stage1(self.plan, self.journal, first)
        resumed = Journal(str(self.path))
        second = RecordingStage1Adapter()

        outcome = run_stage1(self.plan, resumed, second)

        self.assertEqual(outcome, "awaiting_recovery")
        self.assertEqual(second.calls, [])

    def test_crash_after_intent_fails_closed_on_retry(self):
        crashing = RecordingStage1Adapter(
            failure="install_stub_and_esp",
        )
        with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
            run_stage1(self.plan, self.journal, crashing)
        resumed = Journal(str(self.path))
        retry = RecordingStage1Adapter()

        with self.assertRaisesRegex(
            AmbiguousMutationState,
            "stub_and_esp_started has no completion checkpoint",
        ):
            run_stage1(self.plan, resumed, retry)

        self.assertEqual(retry.calls, [])
        self.assertIn(
            "apfs-target-prepared",
            resumed.checkpoints,
        )
        self.assertNotIn(
            "stub-and-esp-installed",
            resumed.checkpoints,
        )

    def test_recovery_handoff_can_retry_after_authentication_failure(self):
        crashing = RecordingStage1Adapter(
            failure="prepare_recovery_handoff",
        )
        with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
            run_stage1(self.plan, self.journal, crashing)
        resumed = Journal(str(self.path))
        retry = RecordingStage1Adapter()

        outcome = run_stage1(self.plan, resumed, retry)

        self.assertEqual(outcome, "awaiting_recovery")
        self.assertEqual(retry.calls, ["prepare_recovery_handoff"])
        self.assertEqual(
            resumed.completion_outcome,
            "awaiting_recovery",
        )

    def test_explicit_recovery_retry_validates_checkpoint_then_runs_bless_only(self):
        target_evidence = b'{"partition_identifier":"disk0s4"}'
        installed_evidence = b'{"populated_partitions":["disk0s5"]}'
        self.journal.event("apfs_preparation_started")
        self.journal.checkpoint(
            "apfs-target-prepared",
            "apfs_preparation",
            target_evidence,
        )
        self.journal.event("stub_and_esp_started")
        self.journal.checkpoint(
            "stub-and-esp-installed",
            "stub_and_esp",
            installed_evidence,
        )
        self.journal.event("recovery_handoff_started")
        adapter = RecordingStage1Adapter()

        outcome = retry_recovery_authorization(
            self.plan,
            self.journal,
            adapter,
        )

        self.assertEqual(outcome, "awaiting_recovery")
        self.assertEqual(
            adapter.calls,
            ["validate_installed_checkpoint", "prepare_recovery_handoff"],
        )
        self.assertEqual(
            adapter.validated_evidence,
            (target_evidence, installed_evidence),
        )

    def test_explicit_recovery_retry_rejects_incomplete_stage_one(self):
        adapter = RecordingStage1Adapter()

        with self.assertRaisesRegex(
            Stage1Error,
            "Recovery retry requires completed stage-one installation",
        ):
            retry_recovery_authorization(
                self.plan,
                self.journal,
                adapter,
            )

        self.assertEqual(adapter.calls, [])

    def test_invalid_adapter_evidence_stops_before_checkpoint(self):
        adapter = RecordingStage1Adapter(
            invalid_evidence="prepare_target",
        )

        with self.assertRaisesRegex(
            Stage1Error,
            "prepare_target returned invalid evidence",
        ):
            run_stage1(self.plan, self.journal, adapter)

        self.assertEqual(adapter.calls, ["prepare_target"])
        self.assertTrue(
            self.journal.has_event("apfs_preparation_started")
        )
        self.assertFalse(
            self.journal.has_checkpoint("apfs_preparation")
        )

    def test_mismatched_journal_plan_is_rejected_before_adapter(self):
        adapter = RecordingStage1Adapter()
        wrong = SimpleNamespace(plan_digest="a" * 64)

        with self.assertRaisesRegex(
            Stage1Error,
            "journal plan does not match admitted plan",
        ):
            run_stage1(wrong, self.journal, adapter)

        self.assertEqual(adapter.calls, [])

    def test_resume_validation_does_not_require_an_adapter(self):
        self.assertIsNone(
            validate_stage1_resume(self.plan, self.journal)
        )

    def _planned_journal(self):
        journal = Journal(str(self.path))
        journal.inspection("apple,j314s", "supported")
        candidate = {
            "kind": "free",
            "source_identifier": "disk0s3",
            "offset_bytes": 447_750_000_000,
            "length_bytes": 100 * 1024**3,
            "minimum_install_bytes": 64 * 1024**3,
            "minimum_container_bytes": 0,
        }
        layout = journal.inventory("disk0", [candidate])
        journal.plan(
            device_identifier="apple,j314s",
            layout_digest=layout,
            candidate_kind="free",
            source_identifier="disk0s3",
            requested_length_bytes=80 * 1024**3,
            engine_version="v0.9.0-omarchy.2",
            engine_digest="sha256:" + "d" * 64,
            metadata_digest="sha256:" + "e" * 64,
            payload_digest="sha256:" + "f" * 64,
            required_human_steps=[
                "enterOneTrueRecovery",
                "authenticateMachineOwner",
            ],
        )
        return journal


class RecordingStage1Adapter:
    def __init__(self, failure=None, invalid_evidence=None):
        self.failure = failure
        self.invalid_evidence = invalid_evidence
        self.calls = []
        self.validated_evidence = None

    def prepare_target(self, plan):
        return self._record("prepare_target", plan)

    def install_stub_and_esp(self, plan):
        return self._record("install_stub_and_esp", plan)

    def prepare_recovery_handoff(self, plan):
        return self._record("prepare_recovery_handoff", plan)

    def validate_installed_checkpoint(
        self,
        plan,
        target_evidence,
        installed_evidence,
    ):
        self.calls.append("validate_installed_checkpoint")
        self.validated_evidence = (target_evidence, installed_evidence)

    def _record(self, name, plan):
        self.calls.append(name)
        if self.failure == name:
            raise RuntimeError("synthetic crash")
        if self.invalid_evidence == name:
            return b""
        return f"{name}|{plan.plan_digest}".encode("utf-8")


if __name__ == "__main__":
    unittest.main()
