# Aurora channel integration — 2026-09-07

Integrated origin/main at 092e9dbc into feature/installer-audit-simulation. The Aurora feature was already merged upstream as aae25861 (PR 84), followed by release-tag suffix support and per-release download staging.

The approved Osaka Jade icon is preserved in commit 31e607e8. Earlier tested installer layout, removal, and speed changes were checkpointed separately in d586272b.

The live Release channel menu and simulator Test channel both include RC (Aurora). Stable and Release candidate keep the approved labels. Switching channels uses distinct signed catalog URLs and release-specific download directories. Replanning within the same release reuses prepared files after current catalog validation; execution handoff still verifies their bytes.

## Validation

- The new replan regression failed before fixing the merged cache-directory comparison, then passed.
- 329 debug and 323 release Swift tests passed through XcodeBuildMCP.
- Swift source/test strict formatting checks passed.
- Shell checks passed: channel publisher, kernel marker, fresh installer, bundle updater, Apple cursor, Apple diagnostics, helper daemon packaging, and icon branding. Bundle updater tests ran with GNU sed/coreutils on macOS.
- Updated stale shell fixtures to match the current target-user ownership guard, selected kernel path, kernel helper, and approved icon. Production disk and package safety checks were unchanged.
- Packaged version 2.0.3, build 2026090713, with an isolated ad hoc descriptor and signature; production credential signing was rejected by automatic approval review and was not performed.
- Opened the debug app in explicit simulation, selected RC (Aurora), and verified the channel badge and disk-size review. No physical installation was executed.

Local artifacts: dist/aurora-merge-review. Screenshot: ../review-images/aurora-merged-simulator.png relative to the worktree parent. The M1 retains the previously reviewed build 2026090712; this merge was not pushed or deployed.
