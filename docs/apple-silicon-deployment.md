# Apple Silicon deployment runbook

How a change reaches an Omarchy Mac, from a commit to `omarchy update` or a
fresh install. Two lanes: the **fast lane** for changes to the runtime
(scripts, configuration, migrations — about fifteen minutes), and the **full
lane** for changes to the package set or a new OS image (a few hours, with a
VM gate). Policy and rationale live in
[`apple-silicon-release-lifecycle.md`](apple-silicon-release-lifecycle.md);
the signed channel layout in
[`apple-silicon-distribution-channels.md`](apple-silicon-distribution-channels.md).
This document is the sequence of commands.

## The moving parts

| Repository | Ships | Pinned by |
| --- | --- | --- |
| `omarchy-mx-mac` (this) | the runtime pair `omarchy-dev` / `omarchy-settings-dev`, the installer app, the acceptance harness, release tooling | `omarchy-pkgs/pkgbuilds/omarchy-source.conf` names the runtime source commit |
| `omarchy-pkgs` (branch `asahi-quattro`) | the 55-package `[omarchy]` repository and the 6-package runtime bundle, as immutable GitHub releases and signed release channels | `omarchy-iso/builder/arm-package-snapshots.conf`, `configs/airootfs/…/pacman-online-installed-arm.conf` |
| `omarchy-iso` | the OS payload (`omarchy-<date>-aarch64-apple-silicon-asahi-os-package.zip`) | `apps/omarchy-apple-installer/scripts/release-inputs.template.json`, `Engine/installer_data.json` |

Artifacts, in the order they are produced:

| Artifact | Where | Made by |
| --- | --- | --- |
| package candidate `asahi-packages-candidate-<pkgs commit>` | GitHub release, immutable, prerelease | `release-asahi-package-incremental.yml` |
| promoted packages `asahi-packages-stable-<pkgs commit>` | GitHub release, byte-identical copy | `bin/promote-asahi-package-candidate --publish` |
| runtime channel `asahi-quattro-channel-<N>` | GitHub release; `omarchy update` follows the highest N | `promote-asahi-quattro-runtime.yml mode=publish` |
| Arch Linux ARM snapshot `mirror/alarm/<YYYYMMDD>/` | R2 | rsync + rclone, see below |
| OS release `releases/os-v4.0.2-mac.1.<date>/` + signed catalog | R2, immutable (7-day age lock) | `publish-m1-release` + `make-unsigned-catalog.py` + `catalog-signing.swift` |
| channel `channels/rc` or `channels/stable` | R2, the only mutable keys | `publish-channels os-promote` |
| installer `installer/<version>/` and `installer/rc|stable/` | R2 | `publish-channels app-publish` |

Machines: **this Mac (M4)** builds the payload and publishes to R2; **GitHub**
builds candidates and publishes runtime channels; **the M1** runs VM
acceptance (it needs KVM, which GitHub's ARM runners lack) — grant yourself
access with the LAN-only helper described in the workspace `AGENTS.md`.
Anything with `bash`, `find`, or a case-insensitive disk in the path runs on
Linux (the M1) or under `/opt/homebrew/bin/bash` with the GNU `gnubin`
directories first on `PATH`; see the gotchas at the end.

## Fast lane: a runtime-only change

Applies when the change is confined to what `omarchy-dev` and
`omarchy-settings-dev` package — `bin/`, `default/`, `config/`, `install/`,
`migrations/`, tests, docs. Nothing in the repository package set moves.

1. Land the change on `main` with its `test/shell.d` coverage, and push.
2. In `omarchy-pkgs`:

   ```bash
   bin/asahi-runtime-release <full main commit>     # --dry-run to preview
   ```

   It pins `omarchy-source.conf` to the commit and merges that as a PR, builds
   an incremental candidate on the newest published candidate (only the
   runtime pair rebuilds; the gate installs the predecessor set from its dated
   snapshot and upgrades over it), approves the `asahi-quattro-release` gates,
   checks the candidate rebuilt nothing outside the runtime, and publishes
   `asahi-quattro-channel-<N+1>`.
3. Installed Macs receive it on their next `omarchy update`. Verify on one:

   ```bash
   omarchy-update-asahi-bundle --check    # "… <tag> is available"
   ```

What the lane skips on purpose: VM acceptance, package promotion, and the OS
payload — the repository set is byte-identical to a set that already passed
them, and fresh installs sync their repositories and update on first boot.
The command refuses a candidate that rebuilt a repository package; that change
is a full-lane change.

Timing: ~12–15 minutes, dominated by the runtime build and the upgrade gate.

## Full lane: a package-set change or a new OS image

Use it when `pkgbuilds/asahi-repository-*`, a PKGBUILD, the builder, or the
workflows change, or when the image itself must change (finalizer, pins, base
system). Every step below waits on the previous one.

### 1. Candidate

Open a PR against `asahi-quattro` (squash merge, no approvals required), then:

```bash
gh workflow run release-asahi-package-incremental.yml -R maralcbr/omarchy-pkgs --ref asahi-quattro \
  -f mode=incremental -f publish_candidate=true \
  -f predecessor_tag=asahi-packages-candidate-<prev> -f predecessor_candidate_sha256=<sha of its CANDIDATE> \
  -f previous_package_commit=<prev pkgs commit> -f previous_runtime_commit=<prev mx-mac commit> \
  -f predecessor_signing_fingerprint=CAB18E175BFB9ACCE185234474DE0C737AC186E4
```

`mode=full` rebuilds everything (~1 h); the planner also falls back to full
when workflows or the build contract changed in the compared range. Approve
the environment gate when the publish job reaches it (`gh api … /pending_deployments`
with a JSON body of integer `environment_ids`). Read the result from the
candidate release: `CANDIDATE` (descriptor; its sha256 is the candidate's
identity), `asahi-quattro-bundle.manifest` (runtime), `PLAN.json`.

### 2. VM acceptance on the M1

Sync the harness (`rsync -a --exclude .git … omarchy-mx-mac/ 192.168.0.192:~/omarchy-src/`),
keep the machine awake (the harness needs `docker` group membership and KVM),
then:

```bash
export OMARCHY_VM_CANDIDATE_TAG=asahi-packages-candidate-<commit>
export OMARCHY_VM_CANDIDATE_SHA256=<sha of CANDIDATE>
export OMARCHY_VM_CANDIDATE_FINGERPRINT=CAB18E175BFB9ACCE185234474DE0C737AC186E4
export OMARCHY_VM_CANDIDATE_PACKAGE_COUNT=55
# default mirror is the snapshot the payload pins; a live mirror needs its own shape:
export OMARCHY_VM_ALARM_MIRROR='https://ca.us.mirror.archlinuxarm.org/$arch/$repo'
test/vm/asahi-fresh/run --optional-packages
```

Passing means 23 `ok` lines and exit 0. Record it as
`docs/releases/asahi-packages-candidate-<8hex>-acceptance.txt` (copy the
previous one; `format=1`, `candidate_tag`, `candidate_sha256`,
`signing_fingerprint` and `status=accepted` are validated, the log hashes come
from `test/vm/asahi-fresh/test-runs/run/` of a `--keep` run).

### 3. Promote the packages

On Linux (the M1), with a GitHub token that can create releases:

```bash
bin/promote-asahi-package-candidate --publish maralcbr/omarchy-pkgs \
  asahi-packages-candidate-<commit> <candidate sha256> CAB18E175BFB9ACCE185234474DE0C737AC186E4 \
  default/omarchy-arm-repository.asc <acceptance file> <sha256 of the acceptance file>
```

Creates `asahi-packages-stable-<commit>`; `omarchy-update-asahi-repository`
moves installed Macs to it on their next update.

### 4. Runtime channel

```bash
gh workflow run promote-asahi-quattro-runtime.yml -R maralcbr/omarchy-pkgs --ref asahi-quattro \
  -f candidate_tag=… -f candidate_sha256=… -f source_commit=<mx-mac commit> -f sequence=<N+1> -f mode=publish
```

Approve the gate. The sequence must be exactly one above the highest
published channel.

### 5. Repoint the image

In `omarchy-iso`, all in one commit:

- `builder/arm-package-snapshots.conf` — every field, derived from the
  candidate's signed assets: `ARM_REPOSITORY_RELEASE=…stable-<c>`,
  `…DESCRIPTOR_RELEASE=…candidate-<c>`, `…DESCRIPTOR_SHA256`,
  `…SOURCE_COMMIT=<c>`, `…PACKAGE_COUNT`; `ARM_RUNTIME_RELEASE=…candidate-<c>`,
  `…MANIFEST_SHA256`, `…SOURCE_COMMIT=<mx-mac commit>`;
  `ARM_RUNTIME_CHANNEL_SEQUENCE=<N>`, `…CHANNEL_TAG=asahi-quattro-<8hex>`.
  The build verifies each against the release; a half-edited file fails it.
- `configs/airootfs/usr/share/omarchy-iso/pacman-online-installed-arm.conf` —
  `[omarchy]` on the same stable tag (the build cross-checks).
- `configs/pacman-online-arm.conf` — the Arch Linux ARM snapshot to build from.
- `builder/products/omarchy-mx-mac.json` — a new `package_filename` date, and
  the matching expectation in `test/unit/test_asahi_stage_inputs.py`.

Also `test/prepare-alarm-container` here and, if the snapshot changed, the
harness default in `test/vm/asahi-fresh/run` and the gate pin in both
`release-asahi-package-*.yml` workflows.

### 6. Build the payload (this Mac)

```bash
cd omarchy-iso
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) OMARCHY_ASAHI_CHECKPOINT_ROOT=$HOME/.cache/omarchy/asahi-checkpoints-<date>
export PATH=/opt/homebrew/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/grep/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:$PATH
/opt/homebrew/bin/bash bin/omarchy-iso-make --target aarch64/apple-silicon --artifact asahi-os-package --mode diagnostic
/opt/homebrew/bin/bash bin/omarchy-iso-make --target aarch64/apple-silicon --artifact asahi-os-package --mode qualification
```

A fresh checkpoint root needs the diagnostic pass first (it content-locks the
toolchain); qualification then restores the stages. Output lands in
`release/`. 60–90 minutes when pins changed; the diagnostic mode rebuilds the
base image every run and compares it, so re-running it against an existing
`checkpoints/base-images` fails — delete that directory first.

### 7. Publish and promote

In `apps/omarchy-apple-installer` of this repository:

```bash
A=apps/omarchy-apple-installer; W=~/omarchy-cutover/release-<date>; TAG=os-v4.0.2-mac.1.<date>
P=../omarchy-iso/release/omarchy-<date>-aarch64-apple-silicon-asahi-os-package.zip
cp "$P.installer-data.json" $W/installer_data.json          # names this payload; also copy it to $A/Engine/
python3 - <<'PY'                                             # inputs: payload_name, evidence_revision
…
PY
git tag -a $TAG -m "…" && git push origin $TAG                # publish-r2 requires the tag on origin
bash $A/scripts/publish-m1-release prepare --payload "$P" --engine $A/Engine/artifacts/installer-v0.9.0-omarchy.14.tar.gz \
  --metadata $W/installer_data.json --tag $TAG --repo maralcbr/omarchy-mx-mac --out-dir $W/staged --no-split \
  --base-url https://downloads.aicodelabs.com.au/releases/$TAG
python3 $A/scripts/make-unsigned-catalog.py --base-url https://downloads.aicodelabs.com.au/releases/$TAG \
  --assets-dir $W/staged --inputs $W/inputs.json --output $W/catalog/catalog.json
xcrun swift $A/scripts/catalog-signing.swift sign-keychain omarchy-channel-signing-key $W/catalog/catalog.json $W/catalog/catalog.json.sig
xcrun swift $A/scripts/catalog-signing.swift verify $A/Release/trust-root.ed25519.pub $W/catalog/catalog.json $W/catalog/catalog.json.sig
$A/scripts/publish-channels envelope --catalog $W/catalog/catalog.json --signature $W/catalog/catalog.json.sig --output $W/catalog/catalog.signed.json
OMARCHY_PUBLISH_ASSUME_YES=$TAG bash $A/scripts/publish-m1-release publish-r2 --dir $W/staged --tag $TAG \
  --bucket omarchy-releases --endpoint https://ab85a8b9d88f084e66bf9d4a8ee5cf66.r2.cloudflarestorage.com \
  --base-url https://downloads.aicodelabs.com.au/releases/$TAG --catalog-dir $W/catalog
OMARCHY_PUBLISH_ASSUME_YES=$TAG $A/scripts/publish-channels os-promote --tag $TAG --to rc
```

R2 credentials come from the login Keychain (`omarchy-r2-access-key-id`,
`omarchy-r2-secret-access-key`), the catalog key from
`omarchy-channel-signing-key`. `os-promote --to stable` is a separate,
deliberate step, and prunes unreferenced release sets afterwards. The
installer app has its own lane (`publish-channels app-publish`) and only
changes when the app does; the README download link never changes.

## Cutting an Arch Linux ARM snapshot

The payload build and the acceptance gate read Arch Linux ARM from a dated,
immutable copy in R2 (`mirror/alarm/<YYYYMMDD>/<repo>/os/aarch64/`) so an
upstream mid-transition cannot fail a build that has nothing to do with it.
Cut a new one when a package we carry needs something newer than the current
snapshot has (as `hyprland` needed `aquamarine 0.15`), or on a cadence.

```bash
# refresh the local mirror incrementally (core alarm aur extra; drops *.old, dereferences the .db links)
rsync -rtL --delete --exclude '*.old' rsync://ca.us.mirror.archlinuxarm.org/archlinuxarm/aarch64/<repo>/ ~/.cache/omarchy/alarm-mirror/<date>/aarch64/<repo>/
# copy the previous snapshot server-side (rclone, ~10 min for 28k objects), then sync only the delta
rclone copy r2:omarchy-releases/mirror/alarm/<prev> r2:omarchy-releases/mirror/alarm/<date> --transfers 32 --s3-no-check-bucket
rclone sync ~/.cache/omarchy/alarm-mirror/<date>/aarch64/<repo>/ r2:omarchy-releases/mirror/alarm/<date>/<repo>/os/aarch64/ --size-only
# force the databases, then verify: each <repo>.db must match the local copy byte for byte
```

`rclone` needs `RCLONE_CONFIG_R2_{TYPE=s3,PROVIDER=Cloudflare,ENDPOINT,ACCESS_KEY_ID,SECRET_ACCESS_KEY}` and
`RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`. Then repoint every reader (step 5)
and record the date in `apple-silicon-distribution-channels.md`. Snapshots are
never modified or pruned automatically.

## Gates and timings

| Step | Gate | Time |
| --- | --- | --- |
| candidate build | shell tests on the source commit; signing check; upgrade lifecycle (predecessor from its snapshot, upgrade against live) | 15 min incremental, 60 full |
| VM acceptance | fresh install, interruption/resume, reboot, verify, optional packages, rerun rejection | 10–15 min |
| promotion | acceptance file bound to the candidate identity; byte-identical copy | 2 min |
| runtime channel | candidate verified; sequence strictly increasing | 2 min |
| payload | checkpointed stages; content evidence; drift gate between cache and repository | 60–90 min |
| publish + rc | readback of every object; catalog signature; sequence above the live channel | 15 min |

## Gotchas that cost a retry each

- macOS: `/bin/bash` is 3.2 (`mapfile`, `declare -A`, `${x,,}` fail),
  BSD `find` has no `-printf`, `sed -i` needs `''`, and the default disk is
  case-insensitive (`candidate/` collides with `CANDIDATE`). Run release
  scripts on the M1, or on this Mac under `/opt/homebrew/bin/bash` with
  `gnubin` first on `PATH` and `TMPDIR` on a case-sensitive volume.
- Helpers launched as `bash <script>` take whatever `bash` is first on `PATH`
  — put `/opt/homebrew/bin` first for the payload build.
- A GitHub release serves every tag's `omarchy.db` under one name with
  unordered upload times; repointing `[omarchy]` to an older tag makes pacman
  keep a stale database and reject it against the new signature. The installed
  pin writer drops the cache; the acceptance guest patches its packaged copy.
- `publish-r2` needs the tag pushed to `origin`, `--base-url` equal to the
  pinned `releases/<tag>` URL, and `OMARCHY_PUBLISH_ASSUME_YES=<exact tag>`
  when there is no terminal.
- Over ssh, `pkill -f omarchy-update` matches the ssh shell's own command
  line; exclude `$$` and `$PPID`.
- The acceptance guest and the gate need Arch Linux ARM in a state consistent
  with the candidate: pin the snapshot the candidate was accepted against,
  not the newest.
