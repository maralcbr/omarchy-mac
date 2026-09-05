# Apple Silicon release versioning

Status: revised 2026-09-04. The installer and the operating system it installs
are now released on separate lines. See
[`apple-silicon-distribution-channels.md`](apple-silicon-distribution-channels.md)
for the channel layout and the runbooks.

Scope: the Apple Silicon (`maralcbr/omarchy-mx-mac`) release lane only. The
Linux/x86 workflow (`.github/workflows/release.yml`) keeps its existing
`vX.Y.Z-mac.N` tags and is unaffected.

## Two identities

| | Value | Where it is set |
| --- | --- | --- |
| Installer version | `2.0.0` | `CFBundleShortVersionString` via `OMARCHY_APP_VERSION`, and `pkgbuild --version` |
| Installer build | integer, keeps counting (next `20`) | `CFBundleVersion` via `OMARCHY_APP_BUILD_NUMBER` |
| Installer tag | `installer-v2.0.0` | git tag, matching `^installer-v[0-9]+\.[0-9]+\.[0-9]+$` |
| OS release tag | `os-v4.0.2-mac.1.20260902[.N]` | git tag and the R2 prefix `releases/<tag>/` |
| Catalog `evidenceRevision` | the OS tag without `os-v` | `evidence_revision` in the release inputs |
| Catalog `sequence` | epoch seconds at generation | the generator; the only machine-enforced guard |

`v4.0.2-mac.1.19.090426` was the last composite tag. Nothing now requires the
installer version and the Omarchy version to move together.

## Rules

1. The catalog `sequence` is the only guard a machine enforces. It must
   increase for every catalog published to a channel, and `os-promote` refuses
   anything that does not exceed what the channel already serves.
2. An installer version is immutable once published: `app-publish` refuses to
   rewrite `installer/<version>/` with different bytes.
3. Two releases never share a tag. A rebuilt OS payload on the same day gets a
   suffix, as in `os-v4.0.2-mac.1.20260902.2`.
4. `CFBundleVersion` increases by one for every app build that leaves the
   machine, independent of the marketing version.
5. `evidenceRevision` stays lowercase `[0-9a-z.-]`; the generator enforces it.

## Where the per-release values live

`apps/omarchy-apple-installer/scripts/release-inputs.template.json` holds the
payload name, engine name and version, the Asahi revisions, the evidence
revision, the supported device identifiers, and the installer compatibility
block. The catalog generator reads that file, so cutting a release edits data,
not code.

The installer compatibility block is what lets a published catalog refuse an
installer that is too old to install it safely:

```json
"installer": {
  "minimum_version": "2.0.0",
  "latest_version": "2.0.0",
  "download_url": "https://downloads.aicodelabs.com.au/installer/stable/Omarchy-MX-Mac-Installer.pkg"
}
```

An installer below `minimum_version` stops before downloading anything and
offers that link. Raise `minimum_version` only when an older installer would
genuinely mis-install the release.
