# Omarchy MX Mac Installer 2.0.0

The installer now has its own version line and its own permanent download. It
reads the current signed Omarchy release from a channel at run time instead of
carrying one release inside itself, so a new operating system package no longer
requires a new installer, and an installer fix no longer re-signs the operating
system catalog.

Download: `https://downloads.aicodelabs.com.au/installer/stable/Omarchy-MX-Mac-Installer.pkg`

## What changed

- **One permanent download.** The link above always serves the current
  installer. Previous releases each lived in their own versioned folder with no
  stable address.
- **Releases are published to a channel.** The app reads
  `channels/stable/catalog.signed.json`, a single signed object holding the
  catalog and its signature together, so a channel update is one atomic write
  and can never be read half-applied.
- **A rc channel exists for testing.** Testers switch under *Release Channel*
  in the menu bar, or with
  `defaults write com.omarchy.mx.installer ReleaseChannel rc`. A rc run is
  marked with a banner and a badge on every screen, and each channel remembers
  its own accepted release, so switching back to stable is never mistaken for a
  downgrade.
- **Catalogs no longer expire.** A signed catalog stays valid until a
  higher-sequence one replaces it, and a Mac whose clock has not yet reached a
  time server still installs.
- **The installer states its own minimum.** A published release can name the
  oldest installer that may install it. An installer below that minimum stops
  before downloading anything and offers the current download.
- **Engine fixes need not rebuild the app.** The engine that plans and performs
  an install now comes from the channel. The engine bundled in the app is used
  only to inspect the Mac before anything is downloaded, which is what allows an
  existing Omarchy installation to be refused without touching the network.

## Fixed since 4.0.2-mac.1.10.090226

The nine builds between `1.11` and `1.19` were never announced. Their fixes are
included here:

- The privileged helper is no longer installed with a placeholder client
  requirement. Packages `1.11` through `1.18` shipped a helper that exited on
  launch and was restarted every ten seconds; `build-pkg.sh` now refuses to
  build such a package at all.
- The validation engine keeps python.org's entitlements when re-signed, so it
  launches under a hardened runtime.
- An existing Omarchy installation is detected and refused before any download
  starts, and is recognised by the boot volume's name.
- The plan acknowledgement survives resizing the disk split, so *Install* stays
  available after dragging the divider.
- The helper is contacted before work is sent to it, and a long wait says so.
- The installer is a single page; the earlier multi-screen flow was removed.

## Compatibility

- Requires an Apple Silicon Mac that Asahi Linux supports. Physical
  qualification is recorded against a 14-inch 2021 MacBook Pro with M1 Pro
  (`apple,j314s`).
- Installers older than `2.0.0` are pinned to a single release folder signed by
  a key that no longer exists, and stop working on 2026-12-01. Replace them with
  the download above; nothing published later can revive them.
- The package identifier is unchanged, so this installs over an earlier
  installer.

## Validation

- Swift test suite in debug and release, strict `swift-format` lint clean.
- Channel publishing and promotion covered by
  `test/shell.d/apple-installer-channel-publish-test.sh`, including refusal of a
  catalog whose signature does not verify, whose sequence does not advance,
  whose artifacts belong to another release or disagree in size, and of a
  package that is not notarized and stapled.
- Catalog generation covered by `scripts/tests/test_make_unsigned_catalog.py`.
- Physical installation is qualified separately on Apple hardware; a source
  build is not installation proof.

**Full Changelog**: https://github.com/maralcbr/omarchy-mx-mac/compare/v4.0.2-mac.1.10.090226...installer-v2.0.0
