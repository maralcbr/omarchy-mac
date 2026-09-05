#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

updater="$ROOT/bin/omarchy-update-asahi-bundle"
package_certificate="$ROOT/default/asahi-repository-signing.asc"
[[ -s $package_certificate ]] || fail "Asahi package signing certificate is installed with the runtime"
gpg --batch --show-keys --with-colons "$package_certificate" |
  grep -Fxq 'fpr:::::::::C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC:' ||
  fail "Asahi package signing certificate has the pinned primary fingerprint"
grep -Fq 'manifest_format == "2"' "$updater" || fail "Asahi updater consumes manifest format 2"
grep -Fq 'package=*)' "$updater" || fail "Asahi updater consumes canonical package records"
grep -Fq 'channel=*) channel_name=' "$updater" || fail "Asahi updater validates the signed channel name"
grep -Fq 'verify_release_signature "$workdir/channel"' "$updater" ||
  fail "Asahi updater verifies the channel with the release key"
grep -Fq 'verify_package_signature "$workdir/$manifest_name"' "$updater" ||
  fail "Asahi updater verifies the runtime manifest with the package key"
grep -Fq 'verify_package_signature "$archive" "$archive.sig"' "$updater" ||
  fail "Asahi updater verifies package archives with the package key"
if grep -Eq '/proc/swaps|/sys/module/zswap' "$updater"; then
  fail "Asahi bundle updates do not reject Omarchy's active zram configuration"
fi
grep -Fq '/sys/module/zswap/parameters/enabled' "$ROOT/bin/omarchy-install-asahi-fresh" ||
  fail "fresh Asahi installs retain the zswap safety gate"
pass "runtime zram is allowed only outside the fresh-install storage boundary"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
assets="$test_tmp/assets"
state="$test_tmp/state"
source_commit=0123456789abcdef0123456789abcdef01234567
package_source_commit=89abcdef0123456789abcdef0123456789abcdef
mkdir -p "$stub_bin" "$assets" "$test_tmp/root/proc/device-tree"
: >"$test_tmp/omarchy-release.gpg"
: >"$test_tmp/asahi-repository-signing.asc"
printf 'apple,j314s\0apple,arm-platform\0' >"$test_tmp/root/proc/device-tree/compatible"

write_channel() {
  local sequence="$1" source="$2"
  cat >"$assets/asahi-quattro-channel" <<EOF
format=1
channel=asahi-quattro
sequence=$sequence
release_tag=asahi-quattro-test
source_commit=$source
manifest=asahi-quattro-bundle.manifest
manifest_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  : >"$assets/asahi-quattro-channel.sig"
}

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
echo aarch64
SH
cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
output=""
url=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http*|file:*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -z ${TEST_CURL_LOG:-} ]] || printf '%s\n' "$url" >>"$TEST_CURL_LOG"
if [[ $url == */releases\?per_page=100 ]]; then
  cp "$TEST_ASSETS/releases.json" "$output"
else
  cp "$TEST_ASSETS/${url##*/}" "$output"
fi
SH
cat >"$stub_bin/gpg" <<'SH'
#!/bin/bash
if [[ " $* " == *" --show-keys "* ]]; then
  if [[ $* == *asahi-repository-signing.asc* ]]; then
    echo 'fpr:::::::::C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC:'
  else
    echo 'fpr:::::::::5983B1CA32CB778F4D74D24ECFF35022CA5B5959:'
  fi
  exit 0
fi
if [[ " $* " == *" --import "* ]]; then
  exit 0
fi
echo '[GNUPG:] VALIDSIG 5983B1CA32CB778F4D74D24ECFF35022CA5B5959 2026-01-01 0 4 0 1 10 00 5983B1CA32CB778F4D74D24ECFF35022CA5B5959'
SH
cat >"$stub_bin/jq" <<'SH'
#!/bin/bash
echo asahi-quattro-channel-22
SH
cat >"$stub_bin/bsdtar" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$stub_bin/vercmp" <<'SH'
#!/bin/bash
echo 0
SH
chmod +x "$stub_bin"/*

run_check() {
  TEST_ASSETS="$assets" \
    OMARCHY_ASAHI_TESTING=1 \
    OMARCHY_ASAHI_ROOT="$test_tmp/root" \
    OMARCHY_ASAHI_BUNDLE_STATE="$state" \
    OMARCHY_ASAHI_KEY_FILE="$test_tmp/omarchy-release.gpg" \
    OMARCHY_ASAHI_PACKAGE_KEY_FILE="$test_tmp/asahi-repository-signing.asc" \
    OMARCHY_ASAHI_CHANNEL_URL="https://example.test/asahi-quattro-channel" \
    PATH="$stub_bin:$PATH" \
    "$updater" --check
}

run_discovery_check() {
  TEST_ASSETS="$assets" \
    TEST_CURL_LOG="$test_tmp/discovery-curl.log" \
    OMARCHY_ASAHI_TESTING=1 \
    OMARCHY_ASAHI_ROOT="$test_tmp/root" \
    OMARCHY_ASAHI_BUNDLE_STATE="$state" \
    OMARCHY_ASAHI_KEY_FILE="$test_tmp/omarchy-release.gpg" \
    OMARCHY_ASAHI_PACKAGE_KEY_FILE="$test_tmp/asahi-repository-signing.asc" \
    OMARCHY_ASAHI_RELEASES_API_URL="https://api.github.test/repos/example/releases?per_page=100" \
    PATH="$stub_bin:$PATH" \
    "$updater" --check
}

printf '%s\n' \
  '[{"draft":false,"prerelease":false,"tag_name":"asahi-quattro-channel-22"}]' \
  >"$assets/releases.json"
write_channel 2 "$source_commit"
run_discovery_check >"$test_tmp/discovery.out"
grep -Fxq 'https://api.github.test/repos/example/releases?per_page=100' "$test_tmp/discovery-curl.log" ||
  fail "versioned channel discovery reads the GitHub releases API"
grep -Fxq 'https://github.com/maralcbr/omarchy-pkgs/releases/download/asahi-quattro-channel-22/asahi-quattro-channel' "$test_tmp/discovery-curl.log" ||
  fail "versioned channel discovery downloads the selected signed pointer"
grep -Fq '&page=$page' "$updater" || fail "bundle updater pages through the release listing"
pass "immutable versioned Asahi channels are discovered dynamically"

write_channel 2 "$source_commit"
run_check >"$test_tmp/available.out"
grep -Fxq 'Apple Silicon Quattro bundle asahi-quattro-test is available' "$test_tmp/available.out" ||
  fail "signed Asahi channel reports an available release" "$(cat "$test_tmp/available.out")"
pass "signed Asahi channel reports an available release"

cat >"$state" <<EOF
format=1
sequence=2
tag=asahi-quattro-test
source_commit=$source_commit
package_source_commit=$package_source_commit
EOF
set +e
run_check >"$test_tmp/current.out"
status=$?
set -e
if (( status == 0 )); then
  fail "current Asahi release is not reported as available"
fi
[[ $status -eq 1 ]] || fail "current Asahi release uses the no-update status"
pass "current signed Asahi release is not offered again"

sed -i 's/^package_source_commit=.*/package_source_commit=invalid/' "$state"
set +e
run_check >"$test_tmp/package-source.out" 2>"$test_tmp/package-source.err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "invalid package source state fails closed" "status $status"
grep -Fq 'release state is malformed' "$test_tmp/package-source.err" ||
  fail "invalid package source state explains the refusal" "$(cat "$test_tmp/package-source.err")"
pass "fresh install package source state is validated"
sed -i "s/^package_source_commit=.*/package_source_commit=$package_source_commit/" "$state"

write_channel 1 fedcba9876543210fedcba9876543210fedcba98
set +e
run_check >"$test_tmp/rollback.out" 2>"$test_tmp/rollback.err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "signed rollback fails closed" "status $status"
grep -Fq 'refusing signed release rollback from sequence 2 to 1' "$test_tmp/rollback.err" ||
  fail "signed rollback explains the refusal" "$(cat "$test_tmp/rollback.err")"
pass "signed Asahi release sequence prevents rollback"

write_channel 2 fedcba9876543210fedcba9876543210fedcba98
set +e
run_check >"$test_tmp/reuse.out" 2>"$test_tmp/reuse.err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "release sequence reuse fails closed" "status $status"
grep -Fq 'sequence 2 was reused for different source' "$test_tmp/reuse.err" ||
  fail "release sequence reuse explains the refusal" "$(cat "$test_tmp/reuse.err")"
pass "signed release sequence cannot be rebound to another source"

cat >"$state" <<EOF
format=1
sequence=1
tag=asahi-quattro-old
source_commit=fedcba9876543210fedcba9876543210fedcba98
EOF
cat >"$state.pending" <<EOF
format=1
sequence=2
tag=asahi-quattro-test
source_commit=$source_commit
package_source_commit=$package_source_commit
EOF
write_channel 2 "$source_commit"
run_check >"$test_tmp/pending.out"
grep -Fxq 'Apple Silicon Quattro bundle asahi-quattro-test has pending migrations' "$test_tmp/pending.out" ||
  fail "pending bundle resumes migrations without reinstalling" "$(cat "$test_tmp/pending.out")"
pass "pending signed Asahi release resumes migrations"

write_channel 3 fedcba9876543210fedcba9876543210fedcba98
set +e
run_check >"$test_tmp/pending-newer.out" 2>"$test_tmp/pending-newer.err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "new release cannot leapfrog pending migrations" "status $status"
grep -Fq 'finish pending release sequence 2 before installing sequence 3' "$test_tmp/pending-newer.err" ||
  fail "pending migration refusal explains the blocker" "$(cat "$test_tmp/pending-newer.err")"
pass "new signed release cannot leapfrog pending migrations"
rm -f "$state.pending"

mkdir -p \
  "$test_tmp/root/boot/grub" \
  "$test_tmp/root/etc/NetworkManager/conf.d" \
  "$test_tmp/root/sys/module/zswap/parameters"
: >"$test_tmp/root/boot/vmlinuz-linux-asahi"
: >"$test_tmp/root/boot/grub/grub.cfg"
cat >"$test_tmp/root/etc/pacman.conf" <<'EOF'
[asahi-alarm]
[core]
[extra]
[alarm]
[aur]
EOF
printf '%s\n' 'wifi.backend=iwd' >"$test_tmp/root/etc/NetworkManager/conf.d/wifi_backend.conf"
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
[[ $1 == "-Qq" && $2 == "linux-asahi" ]]
SH
chmod +x "$stub_bin/pacman"

run_update_to_manifest() {
  local curl_log="$1"
  TEST_ASSETS="$assets" \
    TEST_CURL_LOG="$curl_log" \
    OMARCHY_ASAHI_TESTING=1 \
    OMARCHY_ASAHI_ROOT="$test_tmp/root" \
    OMARCHY_ASAHI_BUNDLE_STATE="$state" \
    OMARCHY_ASAHI_KEY_FILE="$test_tmp/omarchy-release.gpg" \
    OMARCHY_ASAHI_PACKAGE_KEY_FILE="$test_tmp/asahi-repository-signing.asc" \
    OMARCHY_ASAHI_CHANNEL_URL="https://example.test/asahi-quattro-channel" \
    OMARCHY_ASAHI_RELEASE_BASE_URL="https://example.test/asahi-quattro-test" \
    PATH="$stub_bin:$PATH" \
    "$updater" --yes
}

cat >"$state" <<EOF
format=1
sequence=1
tag=asahi-quattro-old
source_commit=fedcba9876543210fedcba9876543210fedcba98
EOF
write_channel 2 "$source_commit"

printf '%s\n' 'Filename Type Size Used Priority' '/dev/zram0 partition 1048572 0 100' >"$test_tmp/root/proc/swaps"
printf '%s\n' N >"$test_tmp/root/sys/module/zswap/parameters/enabled"
set +e
run_update_to_manifest "$test_tmp/zram-curl.log" >"$test_tmp/zram.out" 2>"$test_tmp/zram.err"
status=$?
set -e
[[ $status -eq 3 ]] || fail "active zram reaches the immutable manifest download" "status $status: $(cat "$test_tmp/zram.err")"
grep -Fxq 'https://example.test/asahi-quattro-test/asahi-quattro-bundle.manifest' "$test_tmp/zram-curl.log" ||
  fail "active zram is not rejected before the immutable manifest download"
pass "bundle update permits active zram"

printf '%s\n' 'Filename Type Size Used Priority' >"$test_tmp/root/proc/swaps"
printf '%s\n' Y >"$test_tmp/root/sys/module/zswap/parameters/enabled"
set +e
run_update_to_manifest "$test_tmp/zswap-curl.log" >"$test_tmp/zswap.out" 2>"$test_tmp/zswap.err"
status=$?
set -e
[[ $status -eq 3 ]] || fail "active zswap reaches the immutable manifest download" "status $status: $(cat "$test_tmp/zswap.err")"
grep -Fxq 'https://example.test/asahi-quattro-test/asahi-quattro-bundle.manifest' "$test_tmp/zswap-curl.log" ||
  fail "active zswap is not rejected before the immutable manifest download"
pass "bundle update permits active zswap"

cat >"$stub_bin/gpg" <<'SH'
#!/bin/bash
if [[ " $* " == *" --show-keys "* ]]; then
  if [[ $* == *asahi-repository-signing.asc* ]]; then
    echo 'fpr:::::::::C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC:'
  else
    echo 'fpr:::::::::5983B1CA32CB778F4D74D24ECFF35022CA5B5959:'
  fi
  exit 0
fi
if [[ " $* " == *" --import "* ]]; then
  exit 0
fi
exit 1
SH
set +e
run_check >"$test_tmp/signature.out" 2>"$test_tmp/signature.err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "invalid channel signature fails closed" "status $status"
grep -Fq 'signature verification failed' "$test_tmp/signature.err" ||
  fail "invalid signature explains the refusal" "$(cat "$test_tmp/signature.err")"
pass "unsigned Asahi channel is rejected"
