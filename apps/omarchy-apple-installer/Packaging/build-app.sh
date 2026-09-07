#!/bin/bash

set -euo pipefail

fail() {
  echo "build-app: $*" >&2
  exit 1
}

usage() {
  echo "usage: build-app.sh RELEASE_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 64
}

(( $# == 2 )) || usage

script_directory="$({ cd "$(dirname "$0")" && pwd -P; })"
package_directory="$({ cd "$script_directory/.." && pwd -P; })"
release_directory="$({ cd "$1" && pwd -P; })"
output_directory="$2"

[[ -d $release_directory && ! -L $release_directory ]] \
  || fail "release directory must be a real directory"
[[ $output_directory == /* ]] \
  || output_directory="$package_directory/$output_directory"

build_jobs="${OMARCHY_BUILD_JOBS:-10}"
[[ $build_jobs =~ ^[1-9][0-9]*$ ]] \
  || fail "OMARCHY_BUILD_JOBS must be a positive integer"
export CARGO_BUILD_JOBS="$build_jobs"

marketing_version="${OMARCHY_APP_VERSION:-0.6.0}"
build_number="${OMARCHY_APP_BUILD_NUMBER:-6}"
signing_identity="${OMARCHY_APP_SIGNING_IDENTITY:--}"
team_identifier="${OMARCHY_TEAM_ID:-}"

[[ $marketing_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] \
  || fail "OMARCHY_APP_VERSION has an invalid format"
[[ $build_number =~ ^[1-9][0-9]*$ ]] \
  || fail "OMARCHY_APP_BUILD_NUMBER must be a positive integer"

app_identifier="com.omarchy.mx.installer"
helper_identifier="com.omarchy.mx.installer.helper"
app_name="Omarchy MX Mac Installer.app"
app_executable_name="OmarchyAppleInstallerApp"
helper_executable_name="omarchy-apple-installer-helper"
daemon_plist_name="$helper_identifier.plist"
engine_file_name="installer-v0.9.0-omarchy.14.tar.gz"
engine_digest="9e9277384b6c9e8b269cc79b1b24df7bfcdcbb898a596a677b74d1d18050aebe"

if [[ $signing_identity == "-" ]]; then
  client_requirement="identifier \"$app_identifier\""
  helper_requirement="identifier \"$helper_identifier\""
  timestamp_arguments=(--timestamp=none)
else
  [[ $team_identifier =~ ^[A-Z0-9]{10}$ ]] \
    || fail "OMARCHY_TEAM_ID is required for named signing identities"
  client_requirement="anchor apple generic and identifier \"$app_identifier\" and certificate leaf[subject.OU] = \"$team_identifier\""
  helper_requirement="anchor apple generic and identifier \"$helper_identifier\" and certificate leaf[subject.OU] = \"$team_identifier\""
  if [[ $signing_identity == "Developer ID Application:"* ]]; then
    timestamp_arguments=(--timestamp)
  elif [[ $signing_identity =~ ^[0-9A-Fa-f]{40}$ ]] \
    && security find-identity -p codesigning -v \
      | grep -i "$signing_identity" | grep -q "Developer ID Application"; then
    # Signing by SHA-1 fingerprint (duplicate same-name certificates make
    # names ambiguous): resolve the certificate kind from the keychain so
    # Developer ID builds keep the secure timestamp notarization requires.
    timestamp_arguments=(--timestamp)
  else
    timestamp_arguments=(--timestamp=none)
  fi
fi

release_descriptor="$release_directory/release.json"
trust_root="$release_directory/trust-root.ed25519.pub"
sealed_catalog="$release_directory/catalog.json"
sealed_catalog_signature="$release_directory/catalog.json.sig"
[[ -f $release_descriptor && ! -L $release_descriptor ]] \
  || fail "release.json is missing or unsafe"
[[ -f $trust_root && ! -L $trust_root ]] \
  || fail "trust-root.ed25519.pub is missing or unsafe"
(( $(stat -f %z "$release_descriptor") <= 65536 )) \
  || fail "release.json exceeds 65536 bytes"
(( $(stat -f %z "$trust_root") == 32 )) \
  || fail "trust-root.ed25519.pub must contain exactly 32 bytes"

sealed_catalog_available=false
if [[ -e $sealed_catalog || -L $sealed_catalog \
  || -e $sealed_catalog_signature || -L $sealed_catalog_signature ]]; then
  if [[ ! -f $sealed_catalog || -L $sealed_catalog ]]; then
    fail "catalog.json is missing or unsafe"
  fi
  if [[ ! -f $sealed_catalog_signature || -L $sealed_catalog_signature ]]; then
    fail "catalog.json.sig is missing or unsafe"
  fi
  catalog_size="$(stat -f %z "$sealed_catalog")"
  if (( catalog_size <= 0 || catalog_size > 1048576 )); then
    fail "catalog.json is empty or exceeds 1048576 bytes"
  fi
  if (( $(stat -f %z "$sealed_catalog_signature") != 64 )); then
    fail "catalog.json.sig must contain exactly 64 bytes"
  fi
  sealed_catalog_available=true
fi

descriptor_schema="$(plutil -extract schema_version raw -o - "$release_descriptor")"
descriptor_service="$(plutil -extract helper_mach_service_name raw -o - "$release_descriptor")"
descriptor_requirement="$(plutil -extract helper_code_signing_requirement raw -o - "$release_descriptor")"
descriptor_fingerprint="$(plutil -extract trust_root_fingerprint raw -o - "$release_descriptor")"
if [[ $descriptor_schema != "3" ]]; then
  fail "release.json schema_version must be 3"
fi
descriptor_default_channel="$(plutil -extract default_channel raw -o - "$release_descriptor")"
if [[ $descriptor_default_channel != "stable" && $descriptor_default_channel != "rc" ]]; then
  fail "release.json default_channel must be stable or rc"
fi
descriptor_stable_url="$(plutil -extract channels.stable.catalog_url raw -o - "$release_descriptor")"
descriptor_rc_url="$(plutil -extract channels.rc.catalog_url raw -o - "$release_descriptor")"
descriptor_rc_aurora_url="$(plutil -extract channels.rc-aurora.catalog_url raw -o - "$release_descriptor")"
for descriptor_url in "$descriptor_stable_url" "$descriptor_rc_url" "$descriptor_rc_aurora_url"; do
  if [[ $descriptor_url != https://?*/?* ]]; then
    fail "release.json channel URLs must be https with a host and a path"
  fi
done
# Two channels pointing at one object would silently erase the separation
# between what testers see and what everyone else installs.
if [[ $descriptor_stable_url == "$descriptor_rc_url" ||
  $descriptor_stable_url == "$descriptor_rc_aurora_url" ||
  $descriptor_rc_url == "$descriptor_rc_aurora_url" ]]; then
  fail "release.json channels must not share a URL"
fi
if [[ $descriptor_service != "$helper_identifier" ]]; then
  fail "release.json helper service does not match the compiled product"
fi
if [[ $descriptor_requirement != "$helper_requirement" ]]; then
  fail "release.json helper signing requirement does not match this build"
fi
actual_fingerprint="sha256:$(/usr/bin/shasum -a 256 "$trust_root" | awk '{print $1}')"
if [[ $descriptor_fingerprint != "$actual_fingerprint" ]]; then
  fail "release.json trust root fingerprint does not match the public key"
fi

engine_source="$package_directory/Engine/artifacts/$engine_file_name"
if [[ ! -f $engine_source || -L $engine_source ]]; then
  fail "the pinned validation engine artifact is missing"
fi
actual_engine_digest="$(/usr/bin/shasum -a 256 "$engine_source" | awk '{print $1}')"
if [[ $actual_engine_digest != "$engine_digest" ]]; then
  fail "the pinned validation engine digest is incorrect"
fi

mkdir -p "$output_directory"
final_app="$output_directory/$app_name"
[[ ! -e $final_app ]] \
  || fail "refusing to overwrite existing app: $final_app"

swift_tool="$(xcrun --find swift)"
(
  cd "$package_directory"
  "$swift_tool" build \
    --configuration release \
    --jobs "$build_jobs"
)
binary_directory="$({
  cd "$package_directory"
  "$swift_tool" build --configuration release --show-bin-path
})"

app_binary="$binary_directory/$app_executable_name"
helper_binary="$binary_directory/OmarchyAppleInstallerHelper"
[[ -x $app_binary ]] || fail "app executable was not built"
[[ -x $helper_binary ]] || fail "helper executable was not built"

assembly_root="$(mktemp -d "$output_directory/.omarchy-app.XXXXXX")"
trap 'rm -rf "$assembly_root"' EXIT
assembled_app="$assembly_root/$app_name"
contents="$assembled_app/Contents"
resources="$contents/Resources"

mkdir -p \
  "$contents/MacOS" \
  "$resources/Release" \
  "$resources/Engine/artifacts" \
  "$contents/Library/LaunchDaemons"

install -m 0755 "$app_binary" "$contents/MacOS/$app_executable_name"
install -m 0755 "$helper_binary" "$resources/$helper_executable_name"
install -m 0444 "$release_descriptor" "$resources/Release/release.json"
install -m 0444 "$trust_root" "$resources/Release/trust-root.ed25519.pub"
if [[ $sealed_catalog_available == "true" ]]; then
  install -m 0444 "$sealed_catalog" "$resources/Release/catalog.json"
  install -m 0444 \
    "$sealed_catalog_signature" \
    "$resources/Release/catalog.json.sig"
fi
install -m 0444 "$engine_source" "$resources/Engine/artifacts/$engine_file_name"
install -m 0444 \
  "$script_directory/OmarchyInstaller.icns" \
  "$resources/OmarchyInstaller.icns"
install -m 0444 "$script_directory/Info.plist" "$contents/Info.plist"
install -m 0444 \
  "$script_directory/$daemon_plist_name" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"

chmod 0644 "$contents/Info.plist"
chmod 0644 "$contents/Library/LaunchDaemons/$daemon_plist_name"
plutil -replace CFBundleShortVersionString \
  -string "$marketing_version" "$contents/Info.plist"
plutil -replace CFBundleVersion \
  -string "$build_number" "$contents/Info.plist"
plutil -replace \
  EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT \
  -string "$client_requirement" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name"
plutil -lint \
  "$contents/Info.plist" \
  "$contents/Library/LaunchDaemons/$daemon_plist_name" >/dev/null

codesign --force --sign "$signing_identity" \
  "${timestamp_arguments[@]}" \
  --options runtime \
  --identifier "$helper_identifier" \
  "$resources/$helper_executable_name"
codesign --force --sign "$signing_identity" \
  "${timestamp_arguments[@]}" \
  --options runtime \
  "$assembled_app"

codesign --verify --deep --strict --verbose=2 "$assembled_app"
codesign --verify --strict \
  -R="$helper_requirement" \
  "$resources/$helper_executable_name"
codesign --verify --strict \
  -R="$client_requirement" \
  "$assembled_app"

mv "$assembled_app" "$final_app"
echo "$final_app"
