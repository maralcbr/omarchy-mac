# Installer release inputs

Production packaging reads this directory and copies its contents into
`Omarchy MX Mac Installer.app/Contents/Resources/Release/`:

- `release.json` — schema version 2 descriptor naming the stable and rc
  channel catalog URLs, the default channel, the expected Ed25519 trust-root
  fingerprint, the helper Mach service name, and the helper code-signing
  requirement. Generate it with `scripts/make-release-descriptor`.
- `trust-root.ed25519.pub` — exactly 32 raw Ed25519 public-key bytes matching
  the descriptor fingerprint.

Both files are the same for every build and change only when the signing key is
rotated. The private key lives in the operator's login keychain under the
service `omarchy-channel-signing-key` and must never appear here or anywhere
else on disk; see
[`docs/apple-silicon-distribution-channels.md`](../../../docs/apple-silicon-distribution-channels.md).

The descriptor names both channels even while only the stable channel is in
use, because the app is signed once: a channel absent from the descriptor
cannot be opened later without shipping another signed app.

The app rejects missing, symlinked, group- or world-writable, oversized,
unknown, or mismatched release inputs, and `build-app.sh` refuses a descriptor
whose schema, helper identity, fingerprint, or channel URLs do not match the
product it is building.

For a private or offline build the directory may also contain a signed
`catalog.json` and `catalog.json.sig` pair. The app then verifies that sealed
catalog with the same trust root instead of fetching a channel. Production
builds omit the pair so the app reads its channel at run time.
