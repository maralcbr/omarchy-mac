# Direct Asahi Install VM

This harness tests the published fresh Omarchy 4 lifecycle in a disposable
generic aarch64 KVM guest. It verifies the signed public assets unchanged, then
runs the current source candidate with only its hardware predicates patched in
a retained test copy. The installed Apple
detector is overridden while system setup runs and restored byte-for-byte
afterward. A temporary SSH firewall allowance supports post-reboot assertions
and is removed by the final rerun check. No VM bypass is shipped in the
production installer.

The guest installs the real Asahi package set while continuing to boot an
unowned generic `linux-aarch64` test fixture through GRUB. This validates package resolution,
the exact six-package transaction, pinned source builds, failure recovery, user
provisioning, hard-interruption recovery, collision safety, reboot, safe
completed reruns, migrations, and protected boot
files. It cannot validate
Apple GPU, Wi-Fi, audio, suspend, or other physical hardware behavior.

Run:

```bash
test/vm/asahi-fresh/run
```

The guest uses 8 vCPUs, 6 GiB RAM, and a 96 GiB sparse disk. Set
`OMARCHY_VM_MEMORY_MB` explicitly when a different disposable-guest limit is
required.

The guest takes its Arch Linux ARM packages from a dated, immutable copy of the
`core`, `extra`, `alarm` and `aur` repositories in our own bucket, not from the
live mirrors, so a mirror caught mid-transition (one package rebuilt against a
new library, its dependents not yet) cannot fail a run that has nothing to do
with it. The default is the snapshot the current payload was built against;
`OMARCHY_VM_ALARM_MIRROR` overrides it with another mirror URL (any `https://`
URL naming `$repo` and `$arch`, so a live Arch Linux ARM mirror works too). Only the signed base rootfs still comes from a live mirror. See
`docs/apple-silicon-distribution-channels.md`, "The Arch Linux ARM snapshot".

Use `--rebuild-base` to discard the cached Arch Linux ARM base and `--keep` to
retain the VM container after a run. State and failure artifacts are written to
`test/vm/asahi-fresh/test-runs/`, which is ignored by Git.

Use `--optional-packages` to install every transaction in
`install/optional-packages-aarch64-required` with real `pacman -S` operations
after the reboot checks. Each transaction gets a separate log under
`test-runs/run/optional-package-logs/`. This validates package installation and
post-install hooks in a disposable system, but it does not automate application
login, GUI interaction, or hardware behavior.

To run the full lifecycle after installing an exact immutable package candidate,
provide its trusted identity explicitly:

```bash
OMARCHY_VM_CANDIDATE_TAG=asahi-packages-candidate-<40-hex-commit> \
OMARCHY_VM_CANDIDATE_SHA256=<64-hex-descriptor-checksum> \
OMARCHY_VM_CANDIDATE_FINGERPRINT=<40-hex-signing-subkey> \
OMARCHY_VM_CANDIDATE_PACKAGE_COUNT=<exact repository package count> \
test/vm/asahi-fresh/run
```

This opt-in path verifies the signed descriptor inside the guest, installs all
33 candidate packages through the exact release repository, and checks their
versions again after the full install and reboot. It does not alter the stable
repository pin used by the production installer or the default VM path.
