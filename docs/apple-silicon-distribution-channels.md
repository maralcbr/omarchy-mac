# Apple Silicon distribution channels

Status: adopted 2026-09-04. Replaces the per-release download folder with a
permanent link and a signed channel the installer reads at run time.

## Why this exists

Before this, the app was welded to one Omarchy release. Its bundled descriptor
named a single versioned folder, the signed catalog was sealed inside the app,
and the key that signed the catalog was destroyed straight after signing. A
change to the app, the engine, or the OS package therefore cost the same thing:
a new catalog, a new throwaway key, a rebuild, a notarization, and a new
download URL. Ten releases shipped that way in two days, nine of them for
reasons that had nothing to do with the operating system being installed.

Now the app is built once against a long-lived key, and a release is a small
signed file published to a channel.

## What lives where

Everything is served from `https://downloads.aicodelabs.com.au`.

| Key | Mutable | Holds |
| --- | --- | --- |
| `releases/<os-tag>/…` | no | payload, engine, `installer_data.json`, `SHA256SUMS`, `catalog.json`, `catalog.json.sig`, `catalog.signed.json` |
| `installer/<version>/Omarchy-MX-Mac-Installer-<version>.pkg` (+ `.sha256`) | no | one immutable installer build |
| `channels/<channel>/catalog.signed.json` | **yes** | the catalog that channel currently serves |
| `channels/<channel>/channel.json` | **yes** | which OS tag and sequence that is, for humans |
| `installer/<channel>/Omarchy-MX-Mac-Installer.pkg` | **yes** | the download the README links to |
| `installer/<channel>/installer.json` | **yes** | that package's version, digest and size |

Exactly those four mutable keys may ever be overwritten, and only through
`scripts/publish-channels`, which refuses any other key and is covered by
`test/shell.d/apple-installer-channel-publish-test.sh`.

`<channel>` is `stable` or `rc`. Nothing else is accepted anywhere in the
tooling or the app.

## The signed envelope

`catalog.signed.json` carries the catalog and its signature together:

```json
{"schema_version":1,"catalog":"<base64 catalog bytes>","signature":"<base64 64 bytes>"}
```

The signature is still made over the raw catalog bytes, so the verifier in the
app is unchanged and the immutable `catalog.json` + `catalog.json.sig` pair
stays published for audit. The reason for one object is atomicity: a channel
update is a single write, so a reader can never see a new catalog beside the
previous signature.

## Catalogs do not expire

Catalog schema 4 has no `expiresAt`. A signed catalog stays valid until a
higher-sequence one replaces it, and the monotonic `sequence` is the only
machine-enforced guard. Schema 4 also drops the "issued in the past" check, so
a Mac whose clock has not yet reached a time server still installs.

The trade-off, accepted deliberately: someone able to serve an old but validly
signed catalog can hold a *first-time* installation on an old release. Once a
Mac has accepted a newer catalog, the sequence guard refuses anything older.

## The signing key

One long-lived Ed25519 key signs both channels. It lives in the operator's
login keychain as a generic password under the service
`omarchy-channel-signing-key`, and it is never written to disk on the signing
path.

### Creating it, once

Run this on the signing Mac, with an encrypted disk image mounted at
`/Volumes/Omarchy-Signing`:

```bash
cd apps/omarchy-apple-installer
xcrun swift scripts/catalog-signing.swift generate \
  /Volumes/Omarchy-Signing/trust-root.key /Volumes/Omarchy-Signing/trust-root.ed25519.pub
xcrun swift scripts/catalog-signing.swift import-keychain \
  /Volumes/Omarchy-Signing/trust-root.key omarchy-channel-signing-key
```

`import-keychain` prints the fingerprint and refuses to replace an existing
key, because overwriting it would strand every app already built against the
old public key. Keep the disk image offline as the only backup, write the
fingerprint down, then remove the on-disk copy with `rm -P`.

Generate the app's descriptor from the public key and commit both files to
`apps/omarchy-apple-installer/Release/`:

```bash
scripts/make-release-descriptor \
  --public-key /Volumes/Omarchy-Signing/trust-root.ed25519.pub \
  --base-url https://downloads.aicodelabs.com.au \
  --output Release/release.json
cp /Volumes/Omarchy-Signing/trust-root.ed25519.pub Release/
```

The descriptor names both channels even while only `stable` is in use. The app
is signed and notarized once, so a channel that is not in the descriptor cannot
be opened later without shipping another signed app.

The helper code-signing requirement in the descriptor must match the build that
will consume it, and `build-app.sh` refuses a mismatch. Pass `--adhoc` to write
the identifier-only requirement an ad-hoc local build uses; omit it for the
production Developer ID build.

### Rotating it

Rotation is a new app release, because the public key is inside the signed
bundle. Publish the new key's channel under a new prefix
(`channels/stable-k2/…`), ship an app whose descriptor names it, and keep the
old channel served until the old installers are retired. If the key is believed
compromised, delete the channel objects first so nothing is served at all, then
rotate.

## R2 quirks worth knowing

R2 speaks the S3 protocol, so the AWS CLI is the client, but it does not
implement every S3 call:

- **Server-side copies do not work at all.** `aws s3 cp s3://… s3://…` first
  fails on `GetObjectTagging` (`NotImplemented`); `--copy-props none` gets past
  that, and small objects then fail on `CopyObject` with `Header
  'x-amz-tagging-directive' with value 'REPLACE' not implemented`. Large objects
  take the multipart path and avoid the header, so a copy can half-succeed.
  Upload from a local file instead — a plain `PutObject` has none of these
  problems, which is why `publish-channels` never hits them.
- **Published objects are locked by a bucket policy.** The bucket carries an R2
  lock rule, `immutable-releases`, on the `releases/` prefix. Overwriting one
  fails with `ObjectLockedByBucketPolicy` on `CompleteMultipartUpload`, and
  deleting one fails the same way on `DeleteObject`. This is the never-clobber
  rule enforced by the storage itself rather than by the tooling, so any step
  that republishes must skip what is already present at the right size, and a
  genuine content change needs a new tag. The rule's condition decides whether
  `prune` can ever run: `Indefinite` means nothing under `releases/` is ever
  removable; an age condition (for example 7 days) keeps a fresh release
  immutable through its promotion window and lets `prune` reclaim it later.
  `installer/<version>/` is outside the rule and follows the tooling's own
  never-clobber check only.

## Runbooks

### Release the app

```bash
cd apps/omarchy-apple-installer
OMARCHY_APP_VERSION=2.0.0 OMARCHY_APP_BUILD_NUMBER=20 \
  OMARCHY_APP_SIGNING_IDENTITY="Developer ID Application: …" OMARCHY_TEAM_ID=T2C384FJBD \
  Packaging/build-app.sh "$PWD/Release" /tmp/app
OMARCHY_NOTARY_PROFILE=omarchy-notary Packaging/notarize-app.sh "/tmp/app/Omarchy MX Mac Installer.app"
Packaging/pkg/build-pkg.sh --app "/tmp/app/Omarchy MX Mac Installer.app" \
  --plist Packaging/helper-launchdaemon.plist --version 2.0.0 --out /tmp/Installer.pkg
xcrun notarytool submit /tmp/Installer.pkg --keychain-profile omarchy-notary --wait
xcrun stapler staple /tmp/Installer.pkg
scripts/publish-channels app-publish --pkg /tmp/Installer.pkg --version 2.0.0 --to rc
# test on real hardware, then:
scripts/publish-channels app-publish --pkg /tmp/Installer.pkg --version 2.0.0 --to stable
```

`app-publish` refuses a package that is not signed and stapled, and refuses to
rewrite an immutable version with different bytes.

### Release an OS package

```bash
cd apps/omarchy-apple-installer
scripts/publish-m1-release prepare --payload … --engine … --metadata Engine/installer_data.json \
  --tag os-v4.0.2-mac.1.20260902 --base-url https://downloads.aicodelabs.com.au/releases/os-v4.0.2-mac.1.20260902 \
  --out-dir /tmp/dist --no-split
python3 scripts/make-unsigned-catalog.py --base-url … --assets-dir /tmp/dist \
  --inputs scripts/release-inputs.template.json --output /tmp/catalog/catalog.json
xcrun swift scripts/catalog-signing.swift sign-keychain omarchy-channel-signing-key \
  /tmp/catalog/catalog.json /tmp/catalog/catalog.json.sig
scripts/publish-channels envelope --catalog /tmp/catalog/catalog.json \
  --signature /tmp/catalog/catalog.json.sig --output /tmp/catalog/catalog.signed.json
scripts/publish-m1-release publish-r2 --dir /tmp/dist --catalog-dir /tmp/catalog \
  --tag os-v4.0.2-mac.1.20260902 --bucket omarchy-releases \
  --endpoint https://ab85a8b9d88f084e66bf9d4a8ee5cf66.r2.cloudflarestorage.com \
  --base-url https://downloads.aicodelabs.com.au/releases/os-v4.0.2-mac.1.20260902
scripts/publish-channels os-promote --tag os-v4.0.2-mac.1.20260902 --to rc
# test on real hardware, then:
scripts/publish-channels os-promote --tag os-v4.0.2-mac.1.20260902 --to stable
```

Nothing about the app changes. `os-promote` verifies the signature against the
committed public key, proves every artifact the catalog names is already
published at the size the catalog claims and sits under that tag's own prefix,
and requires the sequence to exceed what the channel already serves.

Per-release values live in `scripts/release-inputs.template.json`, not in the
generator, so cutting a release never edits a script.

### Switch a Mac to the rc channel

From the app, use *Release Channel* in the menu bar. From a terminal:

```bash
defaults write com.omarchy.mx.installer ReleaseChannel rc
```

`defaults delete com.omarchy.mx.installer ReleaseChannel` returns to the
descriptor default. An unknown value is ignored rather than honoured. Each
channel records the release it last accepted separately, so moving back to
stable is not treated as a downgrade.

### Remove what nothing references

```bash
scripts/publish-channels prune            # plan only
scripts/publish-channels prune --confirm  # delete
```

A release set (`releases/<tag>/`) stays as long as any channel's catalog names an artifact under
it, or a channel's `channel.json` records it as `previous_os_tag` — the set that channel served
just before its current release. That one stays because rolling back re-signs a catalog over an
older set's URLs and those must still exist. An installer version (`installer/<version>/`) stays
as long as any channel's `installer.json` points at it. Everything else under those two prefixes
is deleted. A never-promoted candidate set is not rollback material and goes.

`os-promote --to stable` runs this prune itself once the promotion has been verified, so
cleanup happens at the moment the old release stops mattering; pass `--no-prune` to skip it. A
bucket lock that still protects the old set is reported after the promotion, never treated as a
failed release. Channel objects, the stable/rc/edge downloads, and
folders published by other lanes (the generic ISO releases) are never candidates, and the
references are re-read immediately before each deletion so a promotion in between cannot be
undone by a stale plan.

### Check what is live

```bash
scripts/publish-channels channel-status --channel all
```

### Roll a channel back

A byte copy of an older catalog is the wrong move: its sequence is lower, so
every Mac that already accepted the current one refuses it while fresh Macs
accept it, splitting the fleet. Instead regenerate a catalog over the older
artifact URLs with a new, higher sequence, sign it, publish it under the old
tag's prefix, and promote that.

## Which change costs what

| Change | What ships |
| --- | --- |
| Installer UI or behaviour | a new app build: `app-publish` to rc, then stable |
| Engine planning or install fix | a catalog only: sign, publish, `os-promote`. No rebuild, no notarization |
| Engine inspection fix | a new app build, because the bundled engine runs before any download |
| New OS payload | a full OS release, then `os-promote` |

The bundled engine and the catalog's engine are deliberately allowed to differ.
Nothing may reintroduce a check that they match.
