# Changelog

Release notes for the maintained Apple Silicon line are version-controlled in
[`docs/releases/`](docs/releases/). GitHub Releases publish those files
verbatim.

## [4.0.3-mac.1] - Unreleased

- Integrate upstream 4.0.3 security fixes, AI integrations, and migrations.
- Retain Apple Silicon package, boot, network, and migration protections.
- Prepare OpenClaw and Perplexity ARM packages and current Asahi platform pins.
- Publication and physical qualification remain pending. See
  [preparation notes](docs/releases/v4.0.3-mac.1.md).

## [4.0.2-mac.1] - 2026-08-31

- Integrated upstream Omarchy 4.0.2 while preserving the Apple Silicon install,
  update, boot, and package safety gates.
- Added upstream security hardening for SSH password logins, the desktop
  input-group grant, browser policy directories, web app definitions, printer
  services, Plymouth theme publication, Windows VM mounts, and retired
  installer artifacts.
- Reviewed all ten new upstream migrations for Apple Silicon; every one runs,
  with the signed-repository and rc-channel repairs verified as no-ops on the
  already hardened Apple Silicon package setup.
- Aligned the Apple Silicon base packages with the upstream CUPS privilege
  separation after confirming `cups-pk-helper` resolves for aarch64.

[Release notes](docs/releases/v4.0.2-mac.1.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.1-mac.2...v4.0.2-mac.1)

## [4.0.1-mac.2] - 2026-08-26

- Corrected numbered Mac release handling in the signed Quattro upgrade path.
- Published immutable Apple Silicon channel sequence 25 from source commit
  `fe8d2bf8aa64f33b5cff285445900e5d1a2eb4b2`.
- Separated release and package signing trust, restored ARM Node selection, and
  repaired updates with active zram.
- Accepted the release in the generic ARM64 QEMU/HVF VM; physical Apple-hardware
  qualification is not claimed for this release.

[Release notes](docs/releases/v4.0.1-mac.2.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.1-mac.1...v4.0.1-mac.2)

## [4.0.1-mac.1] - 2026-08-25

- Integrated upstream Omarchy 4.0.1 while preserving the Apple Silicon install,
  update, boot, and package safety gates.
- Added upstream hardening for theme and plugin sources, FIDO2 credentials,
  notifications, DNS changes, and Windows VM configuration.
- Reviewed every new migration explicitly for Apple Silicon, running the
  architecture-neutral repairs and holding package swaps outside the validated
  Apple package bundle.

[Release notes](docs/releases/v4.0.1-mac.1.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.16...v4.0.1-mac.1)

## [4.0.0-mac.16] - 2026-08-24

- Early-loads the Apple keyboard and multi-touch HID drivers to prevent an
  intermittent boot race that could leave the internal trackpad unavailable.
- Detects Apple MTP multi-touch trackpads in Omarchy hardware and menu guards.
- Uses macOS-style natural scrolling and physical-click touchpad defaults.

[Release notes](docs/releases/v4.0.0-mac.16.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.15...v4.0.0-mac.16)

## [4.0.0-mac.15] - 2026-08-24

- Published and configured an immutable signed Apple Silicon package repository,
  restoring native package availability for supported Omarchy applications.
- Added continuous aarch64 package resolution and installation audits across
  every package manifest and optional transaction.
- Repaired UTF-8 locale generation, PipeWire realtime scheduling, and GNOME
  Keyring unlock for fresh and existing Apple Silicon installations.

[Release notes](docs/releases/v4.0.0-mac.15.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.14...v4.0.0-mac.15)

## [4.0.0-mac.14] - 2026-08-24

- Added version-controlled release notes and a maintained Apple Silicon
  changelog.
- Validated parallel native-ARM package preparation, signed immutable package
  reuse, and GitHub Actions builder caching.
- Restricted package signing and release writes to the final protected publish
  job after exact six-package fan-in verification.

[Release notes](docs/releases/v4.0.0-mac.14.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.13...v4.0.0-mac.14)

## [4.0.0-mac.13] - 2026-08-24

- Rebuilt `quickshell-git` against Qt 6.11.2 and raised its package release to
  ensure existing installations receive the ABI-compatible binary.
- Published signed Apple Silicon bundle sequence 17 from source commit
  `59c188fa`.
- Superseded `4.0.0-mac.12` after real-hardware reboot validation exposed the
  Quickshell/Qt ABI mismatch.

[Release notes](docs/releases/v4.0.0-mac.13.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.12...v4.0.0-mac.13)

## [4.0.0-mac.12] - 2026-08-23

- Added complete optional-package transaction manifests shared by menu guards,
  tests, and CI.
- Added scheduled native-aarch64 package resolution, download, and AUR build
  validation.
- Extended the disposable Asahi VM to install and verify all 20 required
  optional transactions.

[Release notes](docs/releases/v4.0.0-mac.12.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.11...v4.0.0-mac.12)

## [4.0.0-mac.11] - 2026-08-22

- Retired the legacy seamless-login service before enabling SDDM.
- Added migration repair for affected installations and corrected Quattro
  upgrade cleanup ordering.

[Release notes](docs/releases/v4.0.0-mac.11.md) | [Full diff](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.10...v4.0.0-mac.11)

## Historical Releases

- [4.0.0-mac.10](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.9...v4.0.0-mac.10) - 2026-08-21
- [4.0.0-mac.9](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.8...v4.0.0-mac.9) - 2026-08-20
- [4.0.0-mac.8](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.7...v4.0.0-mac.8) - 2026-08-20
- [4.0.0-mac.7](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.6...v4.0.0-mac.7) - 2026-08-19
- [4.0.0-mac.6](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.5...v4.0.0-mac.6) - 2026-08-17
- [4.0.0-mac.5](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.4...v4.0.0-mac.5) - 2026-08-16
- [4.0.0-mac.4](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.3...v4.0.0-mac.4) - 2026-08-16
- [4.0.0-mac.3](https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.0-mac.1...v4.0.0-mac.3) - 2026-08-15
- [4.0.0-mac.1](https://github.com/maralcbr/omarchy-mx-mac/compare/v3.8.4-mac.4...v4.0.0-mac.1) - 2026-08-15

[4.0.0-mac.13]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.0-mac.13
[4.0.0-mac.14]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.0-mac.14
[4.0.0-mac.15]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.0-mac.15
[4.0.0-mac.16]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.0-mac.16
[4.0.1-mac.1]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.1-mac.1
[4.0.0-mac.12]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.0-mac.12
[4.0.0-mac.11]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.0-mac.11

[4.0.1-mac.2]: https://github.com/maralcbr/omarchy-mx-mac/releases/tag/v4.0.1-mac.2
