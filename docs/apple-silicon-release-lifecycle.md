# Apple Silicon Release Lifecycle

This is the operator procedure for the future Omarchy Apple installation path.
It does not authorize a preview, publication, physical mutation, or removal.
The machine-readable source of the current gate is
`install/apple-silicon-platform-stack.json`; it is intentionally at
`stage: development`, with an empty physical allowlist and public release
authorization set to false.

The Apple path replaces the manual Asahi Arch Minimal distribution setup, not
the Asahi platform foundation. Asahi continues to own APFS preparation,
recoveryOS and boot policy, m1n1, U-Boot, device trees, machine firmware, and
the Asahi kernel.

## 1. Assemble a private candidate

1. Build only the explicit `aarch64/apple-silicon` target through the
   validation-only route. Never relabel generic ARM media.
2. Retain the exact ISO, static media evidence, content-addressed Apple package
   snapshot, all detached signatures, and every source commit named by the
   manifest.
3. Verify the ISO and manifest with the production public key and a durable,
   rollback-protected sequence store. Verification must be read-only first;
   advance the sequence only after the complete candidate set passes.
4. Record generic AArch64 VM results as generic VM evidence. They may validate
   GRUB, the live root, package resolution, interruption, and reboot behavior,
   but never satisfy Apple boot or physical disk-safety gates.
5. Do not upload, merge, publish, enable a model, or replace README installation
   instructions during private candidate assembly.

## 2. Admit one physical preview model

Physical admission is by exact device-tree identifier such as `apple,j314s`,
never by M1/M2/M3/M4 branding. Before the first mutation, satisfy the T6
recovery kit and authorization gate in
`docs/apple-silicon-installer-safety-plan.md`.

For each proposed model, retain a signed catalog record and a sanitized,
independently stored evidence revision covering:

- fresh install and every supported interruption/retry checkpoint;
- reboot into Omarchy and boot back into macOS;
- Startup Options, paired recoveryOS, and DFU recovery readiness;
- preservation of APFS, GPT ordering, unrelated partitions, and the paired
  System ESP outside the Asahi-owned operation;
- display, keyboard, touchpad, storage, Wi-Fi, audio and speaker safety,
  brightness, suspend, and power management;
- signed update, failed update recovery, rollback, and uninstall/reclaim
  guidance.

Only a complete matrix may enter `physical_allowlist`. The contract requires
each named capability to be true, derives `matrix_complete` from those values,
and binds the record to a retained evidence SHA-256 and catalog sequence.
Unsupported or incomplete identifiers remain absent from the signed catalog
and must stop before authorization or disk mutation.

The mechanics of publishing — the channel layout, the signing key, and the
commands for each step — are in
[`apple-silicon-distribution-channels.md`](apple-silicon-distribution-channels.md).
This document governs *when* a release may be published; that one describes
*how*.

## 3. Publish a preview

Preview publication requires a separate explicit authorization after all of
these are true:

1. the platform contract reports `readiness.ready: true` with no blockers;
2. every allowlisted exact model has `matrix_complete: true` and its evidence
   revision is retained outside the canary;
3. ISO, manifest, static and physical evidence, package inputs, source commits,
   signing identities, and sequence are mutually consistent;
4. recovery, rollback, removal, and known-limitations text has been reviewed;
5. the public object set has been fetched back and every hash/signature checked.

Publish to the beta channel first (`publish-channels os-promote --to beta`),
and promote to stable only after the evidence above is complete. Only at this gate may the
top-level README replace the current Asahi Arch Minimal instructions with the
macOS Omarchy installer → Asahi bridge → verified Apple media flow. The README
must name the exact allowlisted models and continue stating that Asahi supplies
the Apple platform foundation.

## 4. Promote to the standard signed channel

Promotion is forward-only and requires the complete preview allowlist to pass
install, reboot, recovery, update, and rollback on the promoted bytes. Reconcile
package ownership and migrations, prove eligible preview installations move to
the standard signed Omarchy channel, and leave ineligible systems on a
documented safe channel. Promotion receives a new, higher sequence; it never
reuses preview metadata or weakens exact-model admission.

## 5. Roll back a bad candidate

Anti-rollback means an older sequence must remain rejected even during an
incident. Publish a higher-sequence record that disables the affected model or
points to the last-known-good immutable artifact. Preserve the bad artifact,
manifest, signatures, logs, source provenance, and acceptance evidence for
audit and recovery analysis. If safe forward recovery is impossible, disable
new installations and publish manual recovery instructions; do not silently
downgrade installed systems.

## 6. Remove or retire support

Removal is archive-and-disable, not deletion:

1. remove the exact model from a higher-sequence signed support catalog;
2. stop new installations before authorization and mutation;
3. retain signed manifests/signatures, ISO and platform recovery assets, source
   provenance, sanitized evidence, and migration/rollback instructions;
4. keep existing installations on a documented supported or frozen channel;
5. verify public recovery-object reachability before changing any listing;
6. require separate explicit authorization for any later destructive cleanup.

Retirement of the downstream Mac channel happens only after eligible systems
are proven on the standard channel and every ineligible system has a safe,
documented disposition.
