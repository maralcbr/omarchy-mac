# Installer speed candidate — 2026-09-07

The owner measured 15 minutes. This candidate implements the app and engine portion of the speed plan; it does not rebuild the OS payload. No sub-five-minute physical result has been measured.

## Implemented

- APFS copy-on-write clones the app handoff when supported, with full snapshot hashing and a physical-copy fallback. The root helper retains its independent private copy and authentication.
- Disk-size replanning reuses present staged assets after fresh catalog/version/model validation. The execution handoff still hashes the bytes before admission.
- The authenticated ZIP is no longer fully decompressed during preflight. Structural, image-capacity and member checks happen before disk mutation; each image is checked for exact length and ZIP CRC during its write.
- The raw writer hashes each decompressed image once, handles short writes, and flushes the device before producing an evidence receipt. macOS character devices use the SDK-defined DKIOCSYNCHRONIZE request.
- Boot images retain independent read-back. Normal root writes use source-hash/write-completion/flush evidence. Recovery retry reads all recorded image bytes and verifies identity and hashes. OMARCHY_FULL_READBACK=1 enables diagnostic full read-back.
- Engine phase timings are recorded separately from the fixed checkpoint journal in a .performance.jsonl sidecar. App preparation, credential validation and private import timings use OSLog.
- Progress is monotonic and capped below completion until the real success transition. A five-minute initial prediction is replaced by the latest successful live stage-one duration; it is an estimate, not a measured speed claim.

For the existing 2 GiB boot and 32 GiB root images, normal execution drops from approximately 102 GiB decompressed and 34 GiB reread to 34 GiB decompressed and 2 GiB reread. The write volume remains 34 GiB. Download time, APFS operations and Recovery interaction still contribute.

## Candidate and validation

- Worktree branch: feature/installer-audit-simulation.
- App: 2.0.2, build 2026090701; local Developer ID signed candidate.
- Execution engine: v0.9.0-omarchy.15, 17,840,637 bytes, SHA-256 8672182b3a60eecab83a7a1f014d257047f77d065432b3da9ea29509a57eb28f.
- Two Python-only repacks are identical. 1,528 unchanged archive entries were compared for bytes, modes, type and link target against the authenticated deployed .14 engine. This is not a claim of two complete native rebuilds.
- Bundled read-only inspection remains pinned to .14; the isolated test catalog selects .15 for execution.
- Same September 6 OS payload retained. Production stable and RC catalogs remain unchanged.
- Swift tests: 296 debug and 291 release passed. Engine overlay: 102 tests passed. Packaging verifier tests: 9 passed. Archive modes: 1,538 entries passed.
- Physical DKIOCSYNCHRONIZE support and complete installation duration remain to be verified on the M1. Mocked tests verify the correct request layout and failure handling, not hardware success.

## Manual-test readiness

The local candidate is under dist/m1-speed-20260907. Its isolated catalog points to testing/m1-speed-20260907 on the existing downloads host. Upload and Apple notarization were rejected by automatic approval review and have not occurred. Do not treat the package as ready for a complete online installation until those artifacts are published and verified.

M1 cleanup was also blocked by automatic approval review: Thunderbolt resolves through en0 instead of bridge0, and Wi-Fi SSH was rejected despite prior owner authorization. No reboot, partition deletion or deployment occurred in this implementation turn. The M1 remains on its installed Linux system.

After access is approved: boot macOS, identify partitions freshly, remove only the Omarchy stub/EFI/boot/root partitions, preserve macOS and Apple Recovery, verify free space, copy the admitted package into the M1 Downloads folder and verify its hash. Measure cold-download and warm-cache runs separately. Record preparation, private import, partition setup, image write/flush, boot read-back and Recovery handoff; exclude user interaction when comparing machine execution time.
