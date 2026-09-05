#!/bin/bash

# Assemble an Omarchy Apple Silicon candidate directory (v8 generation) from a
# freshly built OS payload, mirroring the proven v7 candidate layout.
#
# This script only *assembles and verifies*. It never generates a catalog,
# mints a key, signs, builds, notarizes, or publishes. Those steps are printed
# as exact commands at the end.

set -uo pipefail

readonly DEFAULT_REPO_ROOT="/Users/maralc/dev/omarchy/omarchy-mx-mac-integration"
readonly DEFAULT_REFERENCE_CANDIDATE="/private/tmp/omarchy-mx-mac-candidate-v7.bXXpzZ"
readonly APP_PACKAGE_RELATIVE="apps/omarchy-apple-installer"
readonly REFERENCE_SIGNING_TOOL_DIGEST="af52a6f38d110ef2684a0114abe13928b7e9414857a25b07ce16d4807b825f96"
readonly DEFAULT_APP_VERSION="0.8.0"
readonly DEFAULT_BUILD_NUMBER="9"
readonly DEFAULT_TAG="v0.8.0-m1"
readonly DEFAULT_RELEASE_REPO="maralcbr/omarchy-mx-mac"
readonly DEFAULT_TEAM_ID="T2C384FJBD"

clone_copies=0
plain_copies=0
warnings=0

usage() {
  cat >&2 <<'USAGE'
Usage:
  assemble-candidate-v8.sh --payload FILE --out DIR [options]

Required:
  --payload FILE        the sealed OS payload zip. Both sidecars must sit
                        beside it:
                          FILE.installer-data.json
                          FILE.asahi-package-evidence.json

  --out DIR             candidate directory to create. Must not exist.

Options:
  --repo-root DIR       integration repo (default: the known checkout)
  --reference DIR       reference candidate supplying catalog-signing.swift
                        and the previous release descriptor (default: v7)
  --tag TAG             release tag used in the printed next steps
  --release-repo O/R    GitHub repo used in the printed next steps
  --app-version X.Y.Z   app marketing version for the printed build command
  --build-number N      app build number for the printed build command
  --team-id ID          signing team identifier for the printed build command
  --allow-metadata-drift
                        continue when the payload's installer-data sidecar is
                        not byte-identical to the app package's
                        Engine/installer_data.json (default: hard error)
  -h, --help            this text
USAGE
  exit 64
}

die() {
  echo "assemble-candidate-v8: $*" >&2
  exit 1
}

warn() {
  echo "assemble-candidate-v8: WARNING: $*" >&2
  warnings=$((warnings + 1))
}

step() {
  echo
  echo "== $* =="
}

require_regular_file() {
  [[ -f $1 && ! -L $1 ]] || die "missing or unsafe file: $1"
}

require_real_directory() {
  [[ -d $1 && ! -L $1 ]] || die "missing or unsafe directory: $1"
}

file_digest() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

file_size() {
  wc -c <"$1" | tr -d ' '
}

# Copy one file, verifying its digest before and after. Prefers an APFS clone
# (cp -c) and falls back to a plain copy on filesystems that cannot clone.
verified_copy() {
  local source=$1 destination=$2 label=$3
  local before after before_size after_size mode

  require_regular_file "$source"
  [[ ! -e $destination ]] || die "refusing to overwrite $destination"

  before=$(file_digest "$source") || die "cannot digest $source"
  before_size=$(file_size "$source")

  if cp -c "$source" "$destination" 2>/dev/null; then
    mode="clone"
    clone_copies=$((clone_copies + 1))
  elif cp "$source" "$destination"; then
    mode="copy"
    plain_copies=$((plain_copies + 1))
  else
    die "copy failed: $source -> $destination"
  fi

  after=$(file_digest "$destination") || die "cannot digest $destination"
  after_size=$(file_size "$destination")

  [[ $before == "$after" ]] ||
    die "digest changed across copy of $label: $before -> $after"
  (( before_size == after_size )) ||
    die "size changed across copy of $label: $before_size -> $after_size"

  printf '  %-6s %s\n' "$mode" "$(basename "$destination")"
  printf '         sha256 %s  %s bytes\n' "$after" "$after_size"
}

# Pull a shell assignment out of build-app.sh so the engine identity is read
# from the app package's own pin rather than restated here.
read_pinned_value() {
  local file=$1 name=$2 value
  value=$(
    awk -v name="$name" '
      $0 ~ "^" name "=" {
        line = $0
        sub("^" name "=", "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    ' "$file"
  )
  [[ -n $value ]] || die "cannot read $name from $file"
  printf '%s\n' "$value"
}

read_release_input() {
  local file=$1 key=$2 value
  value=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$file" "$key" 2>/dev/null) ||
    die "could not read $key from $file"
  [[ -n $value ]] || die "empty $key in $file"
  printf '%s\n' "$value"
}


write_manifest() {
  local out=$1 payload_name=$2 payload_digest=$3 payload_size=$4
  local manifest="$out/MANIFEST.txt"
  local generated
  generated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  {
    echo "# v8 candidate file manifest (sha256  size  path)"
    echo "# Generated $generated - ASSEMBLED candidate: payload + sidecars"
    echo "# embedded and digest-verified, engine pinned from the app package."
    echo "# Catalog is NOT generated, NOT signed; app is NOT built."
    echo "# Payload $payload_name is $payload_size bytes, sha256 $payload_digest."
  } >"$manifest" || die "cannot write $manifest"

  (
    cd "$out" || exit 1
    find . -type f ! -name MANIFEST.txt -print |
      LC_ALL=C sort |
      while IFS= read -r path; do
        printf '%s %13s  %s\n' \
          "$(shasum -a 256 "$path" | cut -d ' ' -f 1)" \
          "$(wc -c <"$path" | tr -d ' ')" \
          "$path"
      done
  ) >>"$manifest" || die "cannot append to $manifest"

  echo "  wrote MANIFEST.txt ($(grep -c '' "$manifest") lines)"
}

main() {
  local payload="" out="" repo_root="$DEFAULT_REPO_ROOT"
  local reference="$DEFAULT_REFERENCE_CANDIDATE"
  local tag="$DEFAULT_TAG" release_repo="$DEFAULT_RELEASE_REPO"
  local app_version="$DEFAULT_APP_VERSION" build_number="$DEFAULT_BUILD_NUMBER"
  local team_id="$DEFAULT_TEAM_ID" allow_metadata_drift="no"

  while (( $# > 0 )); do
    case $1 in
      --payload) payload=${2:-}; shift 2 ;;
      --out) out=${2:-}; shift 2 ;;
      --repo-root) repo_root=${2:-}; shift 2 ;;
      --reference) reference=${2:-}; shift 2 ;;
      --tag) tag=${2:-}; shift 2 ;;
      --release-repo) release_repo=${2:-}; shift 2 ;;
      --app-version) app_version=${2:-}; shift 2 ;;
      --build-number) build_number=${2:-}; shift 2 ;;
      --team-id) team_id=${2:-}; shift 2 ;;
      --allow-metadata-drift) allow_metadata_drift="yes"; shift ;;
      -h|--help) usage ;;
      *) echo "assemble-candidate-v8: unknown argument: $1" >&2; usage ;;
    esac
  done

  [[ -n $payload && -n $out ]] || usage
  [[ $tag =~ ^v[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]] ||
    die "--tag must match publish-m1-release's rule ^v[0-9A-Za-z][0-9A-Za-z.+_-]*$ (got: $tag)"
  [[ $release_repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die "--release-repo must be OWNER/REPO"
  [[ $app_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] ||
    die "--app-version has an invalid format"
  [[ $build_number =~ ^[1-9][0-9]*$ ]] ||
    die "--build-number must be a positive integer"
  [[ $team_id =~ ^[A-Z0-9]{10}$ ]] || die "--team-id must be 10 characters"

  # ---- inputs ------------------------------------------------------------
  require_regular_file "$payload"
  local payload_dir payload_name metadata_sidecar evidence_sidecar
  payload_dir=$({ cd "$(dirname "$payload")" && pwd -P; }) ||
    die "cannot resolve payload directory"
  payload_name=$(basename "$payload")
  payload="$payload_dir/$payload_name"
  metadata_sidecar="$payload.installer-data.json"
  evidence_sidecar="$payload.asahi-package-evidence.json"
  require_regular_file "$metadata_sidecar"
  require_regular_file "$evidence_sidecar"

  require_real_directory "$repo_root"
  local app_package="$repo_root/$APP_PACKAGE_RELATIVE"
  require_real_directory "$app_package"
  local build_app="$app_package/Packaging/build-app.sh"
  local notarize_app="$app_package/Packaging/notarize-app.sh"
  local publisher="$app_package/scripts/publish-m1-release"
  local generator="$app_package/scripts/make-unsigned-catalog.py"
  local release_inputs="$app_package/scripts/release-inputs.template.json"
  require_regular_file "$build_app"
  require_regular_file "$notarize_app"
  require_regular_file "$publisher"
  require_regular_file "$generator"
  require_regular_file "$release_inputs"

  require_real_directory "$reference"
  local signing_tool="$reference/catalog/catalog-signing.swift"
  local reference_release="$reference/catalog/release/release.json"
  local reference_trust_root="$reference/catalog/release/trust-root.ed25519.pub"
  require_regular_file "$signing_tool"
  require_regular_file "$reference_release"
  require_regular_file "$reference_trust_root"

  [[ ! -e $out ]] || die "refusing to overwrite existing path: $out"
  [[ $out != */ ]] || die "--out must not end with a slash"

  # ---- engine identity, read from the app package's own pin --------------
  step "Engine pin (from $build_app)"
  local engine_name engine_digest_pin engine_source engine_digest
  engine_name=$(read_pinned_value "$build_app" engine_file_name) || exit 1
  engine_digest_pin=$(read_pinned_value "$build_app" engine_digest) || exit 1
  engine_source="$app_package/Engine/artifacts/$engine_name"
  require_regular_file "$engine_source"
  engine_digest=$(file_digest "$engine_source")
  echo "  name   $engine_name"
  echo "  pinned $engine_digest_pin"
  echo "  actual $engine_digest"
  [[ $engine_digest == "$engine_digest_pin" ]] ||
    die "engine at $engine_source does not match the pin in build-app.sh"

  # ---- metadata agreement -------------------------------------------------
  step "Installer metadata agreement"
  local engine_metadata="$app_package/Engine/installer_data.json"
  require_regular_file "$engine_metadata"
  if cmp -s "$metadata_sidecar" "$engine_metadata"; then
    echo "  payload sidecar is byte-identical to Engine/installer_data.json"
  else
    echo "  sidecar  $(file_digest "$metadata_sidecar")"
    echo "  engine   $(file_digest "$engine_metadata")"
    if [[ $allow_metadata_drift == "yes" ]]; then
      warn "installer metadata drift accepted by --allow-metadata-drift"
    else
      die "payload installer-data sidecar differs from Engine/installer_data.json;
  the catalog binds the Engine copy, so the two must agree.
  Re-run with --allow-metadata-drift only if that divergence is intended."
    fi
  fi

  # ---- generator name agreement ------------------------------------------
  step "Catalog inputs name agreement"
  local generator_payload generator_engine generator_metadata generator_evidence
  generator_payload=$(read_release_input "$release_inputs" payload_name) || exit 1
  generator_engine=$(read_release_input "$release_inputs" engine_name) || exit 1
  generator_metadata=$(read_release_input "$release_inputs" metadata_name) || exit 1
  generator_evidence=$(read_release_input "$release_inputs" evidence_revision) || exit 1
  [[ $generator_payload == "$payload_name" ]] ||
    warn "release inputs pin payload_name=$generator_payload but this payload is $payload_name; update the inputs before generating the catalog"
  [[ $generator_engine == "$engine_name" ]] ||
    warn "release inputs pin engine_name=$generator_engine but the app package pins $engine_name"
  [[ $generator_metadata == "installer_data.json" ]] ||
    warn "release inputs pin metadata_name=$generator_metadata"
  case $generator_evidence in
    *v8*) echo "  evidence_revision=$generator_evidence" ;;
    *) warn "release inputs still declare evidence_revision=$generator_evidence; bump it for the v8 generation" ;;
  esac

  # ---- reference signing tool --------------------------------------------
  step "Reference catalog-signing tool"
  local signing_tool_digest
  signing_tool_digest=$(file_digest "$signing_tool")
  echo "  $signing_tool"
  echo "  sha256 $signing_tool_digest"
  [[ $signing_tool_digest == "$REFERENCE_SIGNING_TOOL_DIGEST" ]] ||
    warn "catalog-signing.swift does not match the v6/v7 digest $REFERENCE_SIGNING_TOOL_DIGEST"

  # ---- build the tree -----------------------------------------------------
  step "Creating candidate tree at $out"
  mkdir -p \
    "$out/package/build-evidence" \
    "$out/engine" \
    "$out/catalog/unsigned" \
    "$out/catalog/release" \
    "$out/catalog/public" \
    "$out/catalog/v7-reference" \
    "$out/app/build" \
    "$out/app/transfer" \
    "$out/dist" \
    "$out/evidence/omarchy-mx-mac" \
    "$out/evidence/omarchy-iso" ||
    die "cannot create candidate tree at $out"
  chmod 0700 "$out" || die "cannot restrict $out"
  echo "  created"

  step "Embedding the payload and its sidecars"
  verified_copy "$payload" "$out/package/$payload_name" "payload"
  verified_copy "$metadata_sidecar" \
    "$out/package/$payload_name.installer-data.json" "installer-data sidecar"
  verified_copy "$evidence_sidecar" \
    "$out/package/$payload_name.asahi-package-evidence.json" "package-evidence sidecar"

  local payload_digest payload_size
  payload_digest=$(file_digest "$out/package/$payload_name")
  payload_size=$(file_size "$out/package/$payload_name")

  step "Embedding the pinned engine and its lock files"
  verified_copy "$engine_source" "$out/engine/$engine_name" "engine"
  verified_copy "$engine_metadata" "$out/engine/installer_data.json" "installer metadata"
  local lock_file
  for lock_file in source-lock.json build-locked-engine.sh verify-source-lock.py \
    verify-archive-modes.py; do
    if [[ -f "$app_package/Engine/$lock_file" && ! -L "$app_package/Engine/$lock_file" ]]; then
      verified_copy "$app_package/Engine/$lock_file" "$out/engine/$lock_file" "$lock_file"
    else
      warn "app package has no Engine/$lock_file; not embedded"
    fi
  done

  step "Staging the catalog scaffolding"
  verified_copy "$signing_tool" "$out/catalog/catalog-signing.swift" "catalog-signing.swift"
  verified_copy "$generator" "$out/catalog/make-unsigned-catalog.py" "make-unsigned-catalog.py"
  verified_copy "$reference_release" "$out/catalog/v7-reference/release.json" "v7 release.json"
  verified_copy "$reference_trust_root" \
    "$out/catalog/v7-reference/trust-root.ed25519.pub" "v7 trust root"
  echo "  catalog/unsigned, catalog/release and catalog/public are empty on purpose:"
  echo "  the generator is templated below, not run by this script."

  # ---- summaries ----------------------------------------------------------
  local assembled_at
  assembled_at=$(date -u '+%Y-%m-%dT%H:%MZ')
  local base_url="https://github.com/$release_repo/releases/download/$tag"
  local dist_dir="$out/dist/$tag"
  local engine_size metadata_size evidence_size
  engine_size=$(file_size "$out/engine/$engine_name")
  metadata_size=$(file_size "$out/engine/installer_data.json")
  evidence_size=$(file_size "$out/package/$payload_name.asahi-package-evidence.json")

  step "Writing CANDIDATE-SUMMARY.md and NEXT-STEPS.md"
  cat >"$out/CANDIDATE-SUMMARY.md" <<SUMMARY
# Omarchy MX Mac candidate v8 — local assembly summary

This is private local candidate construction evidence. It is **not** M1
admission, authorization, publication, notarization, deployment, or an
end-to-end installed-system claim. Nothing here is signed, published,
notarized, or connected to any device.

- Candidate path: \`$out\`
- Assembled (UTC): \`$assembled_at\`
- Assembled by: \`assemble-candidate-v8.sh\`
- Reference candidate (read-only): \`$reference\`
- Source worktree: \`$repo_root\`
- Status: **ASSEMBLED, UNSIGNED.** Catalog not generated, not signed; app not
  built; nothing published.

## Identities

| Role | Identity |
| --- | --- |
| Full-OS payload | \`$payload_name\` |
| — size | \`$payload_size\` bytes |
| — SHA-256 | \`$payload_digest\` |
| Package evidence sidecar | \`$payload_name.asahi-package-evidence.json\`, \`$evidence_size\` bytes |
| — SHA-256 | \`$(file_digest "$out/package/$payload_name.asahi-package-evidence.json")\` |
| Installer metadata | \`installer_data.json\`, \`$metadata_size\` bytes |
| — SHA-256 | \`$(file_digest "$out/engine/installer_data.json")\` |
| Engine | \`$engine_name\`, \`$engine_size\` bytes |
| — SHA-256 | \`$engine_digest\` (matches the pin in \`Packaging/build-app.sh\`) |

## Verification performed by the assembler

- Payload, both sidecars, and the engine were digested **before** the copy and
  re-digested **after**; sizes were compared too. Any drift is a hard error.
- Copies preferred an APFS clone (\`cp -c\`) and fell back to a plain \`cp\`
  where cloning is unavailable. Clones: $clone_copies. Plain copies: $plain_copies.
- The engine digest was checked against the pin hard-coded in
  \`Packaging/build-app.sh\` before embedding.
- The payload's \`installer-data.json\` sidecar was compared byte-for-byte with
  the app package's \`Engine/installer_data.json\` (the bytes the catalog binds).
- The catalog generator's pinned \`PAYLOAD_NAME\`/\`ENGINE_NAME\` constants were
  compared against the real file names.
- Per-file digests for the whole tree: \`MANIFEST.txt\`.

## What is NOT done here

1. **Catalog generation** — templated in \`NEXT-STEPS.md\`, not run.
2. **Catalog signing** — owner-hands ephemeral-key ritual, see \`NEXT-STEPS.md\`.
3. **Source-lock rebind** — \`$APP_PACKAGE_RELATIVE/Engine/source-lock.json\`
   still binds whatever payload it bound before this assembly. It must be
   rebound to \`$payload_digest\` / \`$payload_size\`
   before the app is built. That is a repository source edit, deliberately not
   performed here.
4. **App build, notarization, publication** — all downstream, all templated.
SUMMARY

  cat >"$out/NEXT-STEPS.md" <<NEXTSTEPS
# v8 candidate — exact next steps

Run these in order. Nothing below has been run by the assembler.

Shell variables used throughout:

\`\`\`bash
CANDIDATE="$out"
REPO="$repo_root"
APP="\$REPO/$APP_PACKAGE_RELATIVE"
TAG="$tag"
RELEASE_REPO="$release_repo"
BASE_URL="$base_url"
DIST="$dist_dir"
\`\`\`

## 0. Rebind the source lock (repository edit, before the app build)

\`$APP_PACKAGE_RELATIVE/Engine/source-lock.json\` → \`full_os_payload\`:

- sha256 \`$payload_digest\`
- size \`$payload_size\`

Then refresh the candidate's copy:

\`\`\`bash
cp "\$APP/Engine/source-lock.json" "\$CANDIDATE/engine/source-lock.json"
\`\`\`

## 1. Stage the release assets and split the payload

\`\`\`bash
"\$APP/scripts/publish-m1-release" prepare \\
  --payload "\$CANDIDATE/package/$payload_name" \\
  --engine "\$CANDIDATE/engine/$engine_name" \\
  --metadata "\$CANDIDATE/engine/installer_data.json" \\
  --tag "\$TAG" \\
  --repo "\$RELEASE_REPO" \\
  --out-dir "\$DIST"
\`\`\`

This writes \`SHA256SUMS\` and \`release-urls.env\` into \`\$DIST\` and splits the
payload into \`$payload_name.partNN\`. The URLs are deterministic before the
release exists, which is why the catalog can be generated next.

## 2. Generate the unsigned catalog (TEMPLATED — not run by the assembler)

Confirm first that \`scripts/release-inputs.template.json\` pins the right names and
evidence revision for this generation (\`PAYLOAD_NAME\`, \`ENGINE_NAME\`,
\`evidence_revision\`, \`downstream_revision\`), then:

\`\`\`bash
python3 "\$APP/scripts/make-unsigned-catalog.py" \\
  --base-url "\$BASE_URL" \\
  --assets-dir "\$DIST" \\
  --inputs "\$APP/scripts/release-inputs.template.json" \\
  --output "\$CANDIDATE/catalog/unsigned/catalog.json"
\`\`\`

The generator digests every \`.partNN\` file, proves the parts concatenate back
into the whole payload, and refuses to emit anything if they do not.

## 3. Sign the catalog — owner-hands ephemeral-key ritual

The private catalog-signing key is ephemeral by design: minted in a private
temporary directory, used once, destroyed. It never enters the candidate, the
repository, a log, or an evidence file.

\`\`\`bash
# 3a. Private, owner-only workspace outside the candidate.
KEYDIR="\$(mktemp -d /private/tmp/omarchy-v8-signing.XXXXXX)"
chmod 0700 "\$KEYDIR"

# 3b. Mint the v8 trust root.
xcrun swift "\$CANDIDATE/catalog/catalog-signing.swift" generate \\
  "\$KEYDIR/catalog-signing.ed25519" \\
  "\$KEYDIR/trust-root.ed25519.pub"

# 3c. Sign the unsigned catalog.
cp "\$CANDIDATE/catalog/unsigned/catalog.json" "\$CANDIDATE/catalog/release/catalog.json"
xcrun swift "\$CANDIDATE/catalog/catalog-signing.swift" sign \\
  "\$KEYDIR/catalog-signing.ed25519" \\
  "\$CANDIDATE/catalog/release/catalog.json" \\
  "\$CANDIDATE/catalog/release/catalog.json.sig"

# 3d. Publish the public half into the candidate and write release.json.
cp "\$KEYDIR/trust-root.ed25519.pub" "\$CANDIDATE/catalog/release/trust-root.ed25519.pub"
FINGERPRINT="sha256:\$(shasum -a 256 "\$CANDIDATE/catalog/release/trust-root.ed25519.pub" | cut -d ' ' -f 1)"
sed "s|\"trust_root_fingerprint\": \".*\"|\"trust_root_fingerprint\": \"\$FINGERPRINT\"|" \\
  "\$CANDIDATE/catalog/v7-reference/release.json" \\
  >"\$CANDIDATE/catalog/release/release.json"

# 3e. Verify BEFORE the app build. This must print catalog_signature=passed.
xcrun swift "\$CANDIDATE/catalog/catalog-signing.swift" verify \\
  "\$CANDIDATE/catalog/release/trust-root.ed25519.pub" \\
  "\$CANDIDATE/catalog/release/catalog.json" \\
  "\$CANDIDATE/catalog/release/catalog.json.sig"

# 3f. Mirror the signed pair into catalog/public (the v6/v7 layout).
cp "\$CANDIDATE/catalog/release/catalog.json" "\$CANDIDATE/catalog/public/catalog.json"
cp "\$CANDIDATE/catalog/release/catalog.json.sig" "\$CANDIDATE/catalog/public/catalog.json.sig"

# 3g. Destroy the key and its workspace. Do not skip, do not copy it anywhere.
rm -rf "\$KEYDIR"
unset KEYDIR
\`\`\`

Signing freezes the tag: the signed catalog names \`\$BASE_URL\` asset URLs, so
those exact bytes must be what gets published under \`\$TAG\`, forever.

## 4. Build the app

\`\`\`bash
OMARCHY_APP_VERSION=$app_version \\
OMARCHY_APP_BUILD_NUMBER=$build_number \\
OMARCHY_APP_SIGNING_IDENTITY="<Developer ID Application SHA-1 fingerprint>" \\
OMARCHY_TEAM_ID=$team_id \\
OMARCHY_BUILD_JOBS=10 \\
"\$APP/Packaging/build-app.sh" \\
  "\$CANDIDATE/catalog/release" \\
  "\$CANDIDATE/app/build"
\`\`\`

Pass the certificate **SHA-1 fingerprint**, not the common name: the keychain
holds duplicate same-name certificates and a name is ambiguous.

## 5. Notarize and staple

\`\`\`bash
OMARCHY_NOTARY_PROFILE=omarchy-notary \\
  "\$APP/Packaging/notarize-app.sh" \\
  "\$CANDIDATE/app/build/Omarchy MX Mac Installer.app"
\`\`\`

One-time owner setup this needs: a "Developer ID Application" certificate in
the keychain, and
\`xcrun notarytool store-credentials omarchy-notary\`.

## 6. Package the app for transfer

\`\`\`bash
ditto -c -k --keepParent \\
  "\$CANDIDATE/app/build/Omarchy MX Mac Installer.app" \\
  "\$CANDIDATE/app/transfer/Omarchy-MX-Mac-Installer-$app_version.zip"
\`\`\`

## 7. Publish (owner confirms at the prompt)

\`\`\`bash
git push origin "\$TAG"   # the tag must already exist on origin
"\$APP/scripts/publish-m1-release" publish \\
  --dir "\$DIST" \\
  --app "\$CANDIDATE/app/transfer/Omarchy-MX-Mac-Installer-$app_version.zip" \\
  --tag "\$TAG" \\
  --repo "\$RELEASE_REPO" \\
  --notes-file /Users/maralc/dev/omarchy/iteration2/release-notes-v8.md
\`\`\`

Assets are uploaded once and never clobbered. A published asset whose bytes
differ from the staged bytes is a hard error that requires a new tag.

## 8. Refresh the manifest after every step that adds files

\`\`\`bash
( cd "\$CANDIDATE" && find . -type f ! -name MANIFEST.txt -print | LC_ALL=C sort |
    while IFS= read -r f; do
      printf '%s %13s  %s\\n' "\$(shasum -a 256 "\$f" | cut -d ' ' -f 1)" \\
        "\$(wc -c <"\$f" | tr -d ' ')" "\$f"
    done )
\`\`\`
NEXTSTEPS
  echo "  wrote CANDIDATE-SUMMARY.md"
  echo "  wrote NEXT-STEPS.md"

  step "Writing MANIFEST.txt"
  write_manifest "$out" "$payload_name" "$payload_digest" "$payload_size"

  # ---- report -------------------------------------------------------------
  echo
  echo "candidate=$out"
  echo "payload=$payload_name"
  echo "payload_sha256=$payload_digest"
  echo "payload_bytes=$payload_size"
  echo "engine=$engine_name"
  echo "engine_sha256=$engine_digest"
  echo "clone_copies=$clone_copies"
  echo "plain_copies=$plain_copies"
  echo "warnings=$warnings"
  echo
  echo "Next steps, in order (full commands in $out/NEXT-STEPS.md):"
  echo "  1. rebind Engine/source-lock.json full_os_payload -> $payload_digest / $payload_size"
  echo "  2. $publisher prepare --payload $out/package/$payload_name \\"
  echo "       --engine $out/engine/$engine_name \\"
  echo "       --metadata $out/engine/installer_data.json \\"
  echo "       --tag $tag --repo $release_repo --out-dir $dist_dir"
  echo "  3. python3 $generator --base-url $base_url \\"
  echo "       --assets-dir $dist_dir --inputs $release_inputs \\"
  echo "       --output $out/catalog/unsigned/catalog.json"
  echo "  4. OWNER: ephemeral-key signing ritual (mint in a 0700 mktemp dir,"
  echo "     sign, write release.json, verify -> catalog_signature=passed,"
  echo "     destroy the key). Section 3 of NEXT-STEPS.md."
  echo "  5. build: OMARCHY_APP_VERSION=$app_version OMARCHY_APP_BUILD_NUMBER=$build_number \\"
  echo "       OMARCHY_TEAM_ID=$team_id OMARCHY_APP_SIGNING_IDENTITY=<Developer ID SHA-1> \\"
  echo "       $build_app $out/catalog/release $out/app/build"
  echo "  6. notarize: OMARCHY_NOTARY_PROFILE=omarchy-notary $notarize_app \\"
  echo "       \"$out/app/build/Omarchy MX Mac Installer.app\""
  echo "  7. ditto -c -k --keepParent the app, then publish-m1-release publish."
  if (( warnings > 0 )); then
    echo
    echo "Assembly completed with $warnings warning(s) — read them before step 2."
  fi
}

main "$@"
