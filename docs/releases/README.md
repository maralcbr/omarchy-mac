# Release Notes

Each stable Mac release has one curated notes file named after its immutable
tag, for example `v4.0.0-mac.14.md`. The release workflow publishes that file
verbatim instead of generating notes from pull request titles.

Release preparation must:

1. Update `version` and the recommended version in `README.md`.
2. Add the release to `CHANGELOG.md`.
3. Add `docs/releases/vX.Y.Z-mac.N.md` with user-facing changes, validation,
   known limitations when applicable, and a full-diff link.
4. Run `test/shell.d/stable-release-test.sh` before creating the tag.

The notes file must exist in the tagged commit. The publishing workflow reads
it with `git show`, validates its title and required sections, and passes the
immutable copy to `gh release create --notes-file`.

The installer and the operating system are released on separate lines, so each
has its own notes file:

- `installer-vX.Y.Z.md` — the macOS installer app. Sections: what changed,
  compatibility, validation.
- `os-v<omarchy version>.<YYYYMMDD>.md` — an Omarchy package published to a
  release channel. Same shape as the earlier `vX.Y.Z-mac.N.MMDDYY` notes.

`v4.0.2-mac.1.19.090426` was the last release to carry both identities in one
tag. See
[`../apple-silicon-distribution-channels.md`](../apple-silicon-distribution-channels.md).

Product releases and package-channel releases are separate immutable records:

- `maralcbr/omarchy-mx-mac` tags identify the product source and publish the
  curated validation notes.
- `maralcbr/omarchy-pkgs` channel releases contain the signed installer,
  channel pointer, manifests, and package assets consumed by installations.

The recommended version in `README.md`, the root `version` file,
`CHANGELOG.md`, the product release notes, and the source version identified
by the current stable package channel must agree before a release is called
stable. Validation scope is recorded per release; generic ARM64 VM acceptance
must not be described as physical Apple-hardware qualification.
