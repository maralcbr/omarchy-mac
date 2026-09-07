import os
# SPDX-License-Identifier: MIT
"""Resumable sequencing for Asahi-owned stage-1 mutations."""

from dataclasses import dataclass
from omarchy_image import timing


class Stage1Error(RuntimeError):
    pass


class AmbiguousMutationState(Stage1Error):
    pass


@dataclass(frozen=True)
class Stage:
    event: str
    checkpoint_identifier: str
    checkpoint_phase: str
    adapter_method: str
    retryable_before_checkpoint: bool = False


STAGES = (
    Stage(
        event="apfs_preparation_started",
        checkpoint_identifier="apfs-target-prepared",
        checkpoint_phase="apfs_preparation",
        adapter_method="prepare_target",
    ),
    Stage(
        event="stub_and_esp_started",
        checkpoint_identifier="stub-and-esp-installed",
        checkpoint_phase="stub_and_esp",
        adapter_method="install_stub_and_esp",
    ),
    Stage(
        event="recovery_handoff_started",
        checkpoint_identifier="recovery-handoff-prepared",
        checkpoint_phase="awaiting_recovery",
        adapter_method="prepare_recovery_handoff",
        retryable_before_checkpoint=True,
    ),
)

# Replacing an existing install removes its partitions first; every later
# stage is the normal free-extent flow. The removal has its own intent
# event and checkpoint so an interruption between "started" and "removed"
# is an ambiguous state that is never replayed.
REPLACE_STAGES = (
    Stage(
        event="existing_removal_started",
        checkpoint_identifier="existing-install-removed",
        checkpoint_phase="existing_removal",
        adapter_method="remove_existing_install",
    ),
) + STAGES


def stages_for(plan):
    if getattr(plan, "candidate_kind", None) == "replace":
        return REPLACE_STAGES
    return STAGES


def run_stage1(plan, journal, adapter):
    """Run each mutation once, or return an already completed outcome."""
    completed = validate_stage1_resume(plan, journal)
    if completed is not None:
        return completed

    # The privileged helper runs with umask 077 so nothing it creates is
    # readable by other users. The stub volume and its ESP are not the
    # helper's private state: macOS and the unprivileged inspection that
    # precedes every later install enumerate them, and a stub whose
    # System/Library/CoreServices is 700 makes that enumeration fail with
    # "permission denied" (omarchy.9/.10 shipped that way and could not
    # offer Replace). Files that must stay private are written with an
    # explicit mode, so the standard umask is right for everything else.
    os.umask(0o022)

    for stage in stages_for(plan):
        if stage.checkpoint_identifier in journal.checkpoints:
            continue

        if not journal.has_event(stage.event):
            journal.event(stage.event)
        operation = getattr(adapter, stage.adapter_method, None)
        if operation is None or not callable(operation):
            raise Stage1Error(
                f"adapter does not implement {stage.adapter_method}"
            )
        with timing(stage.adapter_method):
            evidence = operation(plan)
        if not isinstance(evidence, bytes) or not evidence:
            raise Stage1Error(
                f"{stage.adapter_method} returned invalid evidence"
            )
        journal.checkpoint(
            stage.checkpoint_identifier,
            stage.checkpoint_phase,
            evidence,
        )

    _require_all_checkpoints(plan, journal)
    journal.completion("awaiting_recovery")
    return "awaiting_recovery"


def retry_recovery_authorization(plan, journal, adapter):
    """Validate a completed stage-one checkpoint and retry only bless."""
    if journal.plan_digest != plan.plan_digest:
        raise Stage1Error("journal plan does not match admitted plan")
    stages = stages_for(plan)
    required_events = {stage.event for stage in stages}
    required_checkpoints = {
        stage.checkpoint_identifier for stage in stages
    } - {"recovery-handoff-prepared"}
    if (
        journal.completion_outcome is not None
        or journal.events != required_events
        or set(journal.checkpoints) != required_checkpoints
    ):
        raise Stage1Error(
            "Recovery retry requires completed stage-one installation"
        )

    validator = getattr(
        adapter,
        "validate_installed_checkpoint",
        None,
    )
    recovery = getattr(adapter, "prepare_recovery_handoff", None)
    if not callable(validator) or not callable(recovery):
        raise Stage1Error("adapter does not implement Recovery retry")

    validator(
        plan,
        journal.checkpoint_evidence("apfs-target-prepared"),
        journal.checkpoint_evidence("stub-and-esp-installed"),
    )
    evidence = recovery(plan)
    if not isinstance(evidence, bytes) or not evidence:
        raise Stage1Error(
            "prepare_recovery_handoff returned invalid evidence"
        )
    journal.checkpoint(
        "recovery-handoff-prepared",
        "awaiting_recovery",
        evidence,
    )
    journal.completion("awaiting_recovery")
    return "awaiting_recovery"


def validate_stage1_resume(plan, journal):
    """Validate resume state before adapter preflight or mutation."""
    if journal.plan_digest != plan.plan_digest:
        raise Stage1Error("journal plan does not match admitted plan")
    if journal.completion_outcome is not None:
        if journal.completion_outcome != "awaiting_recovery":
            raise Stage1Error("unexpected stage-1 completion")
        _require_all_checkpoints(plan, journal)
        return journal.completion_outcome

    for stage in stages_for(plan):
        completed = stage.checkpoint_identifier in journal.checkpoints
        started = journal.has_event(stage.event)
        if completed:
            if not started:
                raise Stage1Error("checkpoint is missing its intent record")
            continue
        if started and not stage.retryable_before_checkpoint:
            raise AmbiguousMutationState(
                f"{stage.event} has no completion checkpoint"
            )
    return None


def _require_all_checkpoints(plan, journal):
    missing = [
        stage.checkpoint_identifier
        for stage in stages_for(plan)
        if stage.checkpoint_identifier not in journal.checkpoints
    ]
    if missing:
        raise Stage1Error(
            "stage-1 completion is missing checkpoints: "
            + ",".join(missing)
        )
