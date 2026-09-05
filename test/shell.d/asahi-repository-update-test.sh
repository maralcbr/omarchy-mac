#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command sha256sum

updater="$ROOT/bin/omarchy-update-asahi-repository"
update="$ROOT/bin/omarchy-update"
update_available="$ROOT/bin/omarchy-update-available"
certificate="$ROOT/default/omarchy-arm-repository.asc"
primary_fingerprint=C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC
subkey_fingerprint=CAB18E175BFB9ACCE185234474DE0C737AC186E4
repo=maralcbr/omarchy-pkgs

[[ -s $certificate ]] || fail "Omarchy ARM repository certificate ships with the runtime"
if command -v gpg >/dev/null; then
  colons=$(gpg --batch --show-keys --with-colons "$certificate" 2>/dev/null || true)
  grep -Fxq "fpr:::::::::$primary_fingerprint:" <<<"$colons" ||
    fail "Omarchy ARM repository certificate has the pinned primary fingerprint"
  grep -Fxq "fpr:::::::::$subkey_fingerprint:" <<<"$colons" ||
    fail "Omarchy ARM repository certificate carries the pinned signing subkey"
fi
grep -Fq "trusted_subkey=$subkey_fingerprint" "$updater" || fail "repository updater pins the signing subkey"
grep -Fq '$2 == "VALIDSIG" && $3 == key' "$updater" || fail "repository updater requires the descriptor signature from the subkey itself"
grep -Fq '# omarchy:hidden=true' "$updater" || fail "repository updater is hidden from command listings"
grep -Fq '# omarchy:requires-sudo=true' "$updater" || fail "repository updater declares its sudo requirement"
grep -Fq 'omarchy-update-asahi-repository --yes' "$update" || fail "normal updates repoint the Apple Silicon package repository"
grep -Fq 'repository_status == 3' "$update" || fail "repository listing outages do not block platform package updates"
awk '/omarchy-update-asahi-repository --yes/ { seen = 1 } seen && /omarchy-update-system-pkgs([^-]|$)/ { ordered = 1 } END { exit !ordered }' "$update" ||
  fail "the repository is repointed before the system package upgrade"
grep -Fq 'omarchy-update-asahi-repository' "$update_available" || fail "availability checks include the package repository"
# A failed repoint leaves the previous signed snapshot pinned, which still
# installs, so it must not take the whole system update down with it.
awk '/repository_status != 0/ { getline; if ($0 ~ /exit/) exit 1 } END { exit 0 }' "$update" ||
  fail "a failed repository repoint continues to the package upgrade"
grep -Fq 'continuing with the pinned snapshot' "$update" ||
  fail "a failed repository repoint says the pinned snapshot is still in use"
# Candidate, channel and snapshot tags accumulate, so the newest snapshot can
# fall past the first page of the release listing.
grep -Fq '&page=$page' "$updater" || fail "repository updater pages through the release listing"
pass "Apple Silicon package repository updates are wired into the update flow"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
assets="$test_tmp/assets"
state="$test_tmp/state"
calls="$test_tmp/calls"
root="$test_tmp/root"
pacman_conf="$root/etc/pacman.conf"
old_commit=afd72814b7b29dddef2e07c7ed125101de34d4f4
new_commit=901e39bdc0dd42a93644bce14a07eeb9bb18a12c
old_tag="asahi-packages-stable-$old_commit"
new_tag="asahi-packages-stable-$new_commit"
mkdir -p "$stub_bin" "$assets" "$root/etc/pacman.d" "$root/proc/device-tree"
: >"$test_tmp/omarchy-arm-repository.asc"
printf 'apple,j314s\0apple,arm-platform\0' >"$root/proc/device-tree/compatible"

write_pacman_conf() {
  local tag="$1"
  cat >"$pacman_conf" <<CONF
[options]
Architecture = aarch64
SigLevel = Required DatabaseOptional

[asahi-alarm]
Server = https://github.com/asahi-alarm/asahi-alarm/releases/download/\$arch

[omarchy]
SigLevel = Required DatabaseOptional
Server = https://github.com/$repo/releases/download/$tag

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist

[aur]
Include = /etc/pacman.d/mirrorlist
CONF
  printf 'Server = http://mirror.archlinuxarm.org/$arch/$repo\n' >"$root/etc/pacman.d/mirrorlist"
}

write_release_listing() {
  cat >"$assets/releases.json" <<EOF
[
  {"tag_name":"asahi-packages-candidate-$new_commit","draft":false,"prerelease":true,"immutable":true,"published_at":"2026-09-01T09:20:52Z"},
  {"tag_name":"asahi-packages-stable-ffffffffffffffffffffffffffffffffffffffff","draft":true,"prerelease":false,"immutable":true,"published_at":"2026-09-03T00:00:00Z"},
  {"tag_name":"asahi-packages-stable-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","draft":false,"prerelease":false,"immutable":false,"published_at":"2026-09-03T00:00:00Z"},
  {"tag_name":"asahi-packages-stable-dddddddddddddddddddddddddddddddddddddddd","draft":false,"prerelease":true,"immutable":true,"published_at":"2026-09-03T00:00:00Z"},
  {"tag_name":"$new_tag","draft":false,"prerelease":false,"immutable":true,"published_at":"2026-09-02T02:14:02Z"},
  {"tag_name":"$old_tag","draft":false,"prerelease":false,"immutable":true,"published_at":"2026-08-25T05:11:46Z"},
  {"tag_name":"asahi-packages-784daa3efaecfa81b5b4da888b524e6ec4574d24","draft":false,"prerelease":false,"immutable":true,"published_at":"2026-09-04T00:00:00Z"},
  {"tag_name":"asahi-quattro-channel-26","draft":false,"prerelease":false,"immutable":true,"published_at":"2026-09-04T00:00:00Z"}
]
EOF
}

write_descriptor() {
  local commit="$1" workflow_run="$2" release_dir
  release_dir="$assets/asahi-packages-stable-$commit"
  mkdir -p "$release_dir"
  printf 'omarchy database for %s\n' "$commit" >"$release_dir/omarchy.db"
  printf 'signature\n' >"$release_dir/omarchy.db.sig"
  cat >"$release_dir/CANDIDATE" <<EOF
format=1
channel=candidate
release_tag=asahi-packages-candidate-$commit
source_commit=$commit
workflow_run=$workflow_run
runner_arch=aarch64
signing_fingerprint=$subkey_fingerprint
package_count=2
asset=omarchy.db|$(sha256sum "$release_dir/omarchy.db" | cut -d' ' -f1)
asset=omarchy.db.sig|$(sha256sum "$release_dir/omarchy.db.sig" | cut -d' ' -f1)
asset=omarchy.files|$(printf '%064d' 1)
asset=omarchy.files.sig|$(printf '%064d' 2)
package=1|aether|4.27.2-1|aarch64|aether-4.27.2-1-aarch64.pkg.tar.zst|$(printf '%064d' 3)|aether-4.27.2-1-aarch64.pkg.tar.zst.sig|$(printf '%064d' 4)
package=2|yay|12.6.0-1|aarch64|yay-12.6.0-1-aarch64.pkg.tar.zst|$(printf '%064d' 5)|yay-12.6.0-1-aarch64.pkg.tar.zst.sig|$(printf '%064d' 6)
EOF
  printf 'signature\n' >"$release_dir/CANDIDATE.sig"
}

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
output=""
url=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$TEST_CURL_LOG"
[[ ${TEST_CURL_OFFLINE:-0} != 1 ]] || exit 7
if [[ $url == */releases\?per_page=100 ]]; then
  cp "$TEST_ASSETS/releases.json" "$output"
else
  path=${url#https://github.com/maralcbr/omarchy-pkgs/releases/download/}
  [[ -f $TEST_ASSETS/$path ]] || exit 22
  cp "$TEST_ASSETS/$path" "$output"
fi
SH
cat >"$stub_bin/gpg" <<'SH'
#!/bin/bash
primary=C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC
subkey=CAB18E175BFB9ACCE185234474DE0C737AC186E4
if [[ " $* " == *" --show-keys "* ]]; then
  printf 'pub:-:255:22:%s:::::::cSC::::::::0:\nfpr:::::::::%s:\n' "${primary:24}" "$primary"
  exit 0
fi
if [[ " $* " == *" --import "* ]]; then
  exit 0
fi
if [[ " $* " == *" --list-keys "* ]]; then
  printf 'pub:-:255:22:%s:::::::cSC::::::::0:\nfpr:::::::::%s:\nsub:-:255:22:%s:::::::s::::::::0:\nfpr:::::::::%s:\n' \
    "${primary:24}" "$primary" "${subkey:24}" "$subkey"
  exit 0
fi
[[ ${TEST_GPG_FAIL:-0} != 1 ]] || exit 1
signer=$subkey
[[ ${TEST_GPG_SIGNER:-subkey} == "subkey" ]] || signer=$primary
echo "[GNUPG:] VALIDSIG $signer 2026-01-01 0 4 0 1 22 00 $primary"
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo:%s\n' "$*" >>"$TEST_CALLS"
if [[ $1 == "env" ]]; then
  shift
  while [[ $1 == *=* ]]; do export "$1"; shift; done
fi
exec "$@"
SH
cat >"$stub_bin/install" <<'SH'
#!/bin/bash
args=()
while (($#)); do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
SH
cat >"$stub_bin/pacman-key" <<'SH'
#!/bin/bash
printf 'pacman-key:%s\n' "$*" >>"$TEST_CALLS"
if [[ $1 == "--finger" ]]; then
  [[ -f $TEST_KEY_STATE ]]
elif [[ $1 == "--add" ]]; then
  : >"$TEST_KEY_STATE"
fi
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
printf 'pacman:%s OMARCHY_UPDATE_PACMAN=%s\n' "$*" "${OMARCHY_UPDATE_PACMAN:-}" >>"$TEST_CALLS"
[[ ${TEST_PACMAN_FAIL:-0} != 1 ]]
SH
cat >"$stub_bin/gum" <<'SH'
#!/bin/bash
echo "gum must not prompt under --yes" >&2
exit 1
SH
chmod +x "$stub_bin"/*

run_updater() {
  TEST_ASSETS="$assets" \
    TEST_CURL_LOG="$test_tmp/curl.log" \
    TEST_CALLS="$calls" \
    TEST_KEY_STATE="$test_tmp/key-trusted" \
    OMARCHY_ASAHI_TESTING=1 \
    OMARCHY_ASAHI_ROOT="$root" \
    OMARCHY_ASAHI_REPOSITORY_STATE="$state" \
    OMARCHY_ASAHI_PACKAGE_KEY_FILE="$test_tmp/omarchy-arm-repository.asc" \
    OMARCHY_ASAHI_RELEASES_API_URL="https://api.github.test/repos/example/releases?per_page=100" \
    PATH="$stub_bin:$PATH" \
    "$updater" "$@"
}

run_status() {
  local out="$1" err="$2"
  shift 2
  set +e
  run_updater "$@" >"$out" 2>"$err"
  status=$?
  set -e
}

reset_run() {
  : >"$test_tmp/curl.log"
  : >"$calls"
  rm -f "$state" "$test_tmp/key-trusted"
}

write_release_listing
write_descriptor "$old_commit" 33000000000
write_descriptor "$new_commit" 33487927893
write_pacman_conf "$old_tag"

reset_run
run_status "$test_tmp/check.out" "$test_tmp/check.err" --check
(( status == 0 )) || fail "newer stable snapshot is reported as available" "status $status: $(cat "$test_tmp/check.err")"
grep -Fxq "Apple Silicon package repository $new_tag is available" "$test_tmp/check.out" ||
  fail "availability names the selected stable snapshot" "$(cat "$test_tmp/check.out")"
grep -Fxq 'https://api.github.test/repos/example/releases?per_page=100' "$test_tmp/curl.log" ||
  fail "stable discovery reads the GitHub releases listing"
grep -Fxq "https://github.com/$repo/releases/download/$new_tag/CANDIDATE" "$test_tmp/curl.log" ||
  fail "stable discovery downloads the signed descriptor of the newest promoted snapshot"
grep -Fxq "https://github.com/$repo/releases/download/$new_tag/CANDIDATE.sig" "$test_tmp/curl.log" ||
  fail "stable discovery downloads the descriptor signature"
! grep -Fq 'omarchy.db' "$test_tmp/curl.log" || fail "availability checks do not download the repository database"
[[ ! -s $calls ]] || fail "availability checks do not touch the system" "$(cat "$calls")"
pass "drafts, prereleases, mutable releases, candidates, and legacy tags are ignored in favour of the newest promoted stable snapshot"

write_pacman_conf "$new_tag"
reset_run
run_status "$test_tmp/current.out" "$test_tmp/current.err" --check
(( status == 1 )) || fail "current stable snapshot uses the no-update status" "status $status: $(cat "$test_tmp/current.err")"
! grep -Fq CANDIDATE "$test_tmp/curl.log" || fail "a current repository skips the descriptor download"
run_status "$test_tmp/current-apply.out" "$test_tmp/current-apply.err" --yes
(( status == 0 )) || fail "current stable snapshot is a successful no-op" "status $status: $(cat "$test_tmp/current-apply.err")"
grep -Fxq 'Apple Silicon package repository is up to date' "$test_tmp/current-apply.out" || fail "current snapshot reports up to date"
[[ ! -s $calls ]] || fail "a current repository is not rewritten" "$(cat "$calls")"
pass "a repository already on the newest snapshot is left alone"

write_pacman_conf "$old_tag"
reset_run
sed -i "s/^source_commit=.*/source_commit=$old_commit/" "$assets/$new_tag/CANDIDATE"
run_status "$test_tmp/source.out" "$test_tmp/source.err" --check
(( status == 2 )) || fail "descriptor for another source fails closed" "status $status"
grep -Fq 'source commit does not match the stable tag' "$test_tmp/source.err" ||
  fail "descriptor source mismatch explains the refusal" "$(cat "$test_tmp/source.err")"
write_descriptor "$new_commit" 33487927893
pass "a stable tag whose descriptor names another source is rejected"

reset_run
TEST_GPG_SIGNER=primary run_status "$test_tmp/primary.out" "$test_tmp/primary.err" --check
(( status == 2 )) || fail "descriptor signed by the primary key fails closed" "status $status"
grep -Fq 'was not signed by the Omarchy ARM repository signing subkey' "$test_tmp/primary.err" ||
  fail "primary key signature explains the refusal" "$(cat "$test_tmp/primary.err")"
TEST_GPG_FAIL=1 run_status "$test_tmp/badsig.out" "$test_tmp/badsig.err" --check
(( status == 2 )) || fail "invalid descriptor signature fails closed" "status $status"
grep -Fq 'signature verification failed for CANDIDATE' "$test_tmp/badsig.err" ||
  fail "invalid signature explains the refusal" "$(cat "$test_tmp/badsig.err")"
pass "only descriptors signed by the shipped repository subkey are accepted"

reset_run
cat >"$state" <<EOF
format=1
tag=asahi-packages-stable-0123456789abcdef0123456789abcdef01234567
source_commit=0123456789abcdef0123456789abcdef01234567
workflow_run=33500000000
descriptor_sha256=$(printf '%064d' 9)
EOF
run_status "$test_tmp/rollback.out" "$test_tmp/rollback.err" --check
(( status == 2 )) || fail "older build than the installed snapshot fails closed" "status $status"
grep -Fq "refusing package repository rollback from asahi-packages-stable-0123456789abcdef0123456789abcdef01234567 to $new_tag" "$test_tmp/rollback.err" ||
  fail "rollback refusal names both snapshots" "$(cat "$test_tmp/rollback.err")"
pass "signed workflow runs prevent repository rollback"

reset_run
TEST_CURL_OFFLINE=1 run_status "$test_tmp/offline.out" "$test_tmp/offline.err" --check
(( status == 3 )) || fail "listing outages use the transport status" "status $status"
pass "release listing outages are reported as transport failures"

reset_run
sed -i '/^\[aur\]$/d' "$pacman_conf"
run_status "$test_tmp/aur.out" "$test_tmp/aur.err" --yes
(( status == 2 )) || fail "missing platform repository fails closed" "status $status"
grep -Fq 'required [aur] repository is missing' "$test_tmp/aur.err" || fail "missing repository is named" "$(cat "$test_tmp/aur.err")"
write_pacman_conf "$old_tag"
printf '\n[omarchy]\nServer = https://example.test/other\n' >>"$pacman_conf"
run_status "$test_tmp/twice.out" "$test_tmp/twice.err" --yes
(( status == 2 )) || fail "duplicate [omarchy] blocks fail closed" "status $status"
grep -Fq 'exactly one [omarchy] repository' "$test_tmp/twice.err" || fail "duplicate block refusal is explained" "$(cat "$test_tmp/twice.err")"
[[ ! -s $calls ]] || fail "malformed pacman configuration is never rewritten" "$(cat "$calls")"
pass "protected pacman configuration is validated before any change"

write_pacman_conf "$old_tag"
reset_run
before=$(sed "s|$old_tag|$new_tag|" "$pacman_conf")
run_status "$test_tmp/apply.out" "$test_tmp/apply.err" --yes
(( status == 0 )) || fail "repository switch succeeds" "status $status: $(cat "$test_tmp/apply.err")"
grep -Fq "Switched the Apple Silicon package repository to $new_tag" "$test_tmp/apply.out" ||
  fail "repository switch reports the new snapshot" "$(cat "$test_tmp/apply.out")"
[[ $(cat "$pacman_conf") == "$before" ]] || fail "only the [omarchy] Server line changes" "$(diff <(echo "$before") "$pacman_conf" || true)"
grep -Fxq "https://github.com/$repo/releases/download/$new_tag/omarchy.db" "$test_tmp/curl.log" ||
  fail "the repository database is downloaded before switching"
grep -Fq 'sudo:pacman-key --finger C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC' "$calls" || fail "the repository key trust is checked"
grep -Fxq "pacman-key:--add $test_tmp/omarchy-arm-repository.asc" "$calls" || fail "a missing repository key is imported into pacman"
grep -Fxq 'pacman-key:--lsign-key C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC' "$calls" || fail "the imported repository key is locally signed"
grep -Fxq 'pacman:-Sy --noconfirm OMARCHY_UPDATE_PACMAN=1' "$calls" || fail "the new repository is synced through the update guard"
grep -Eq "^sudo:install -d -o root -g root -m 0700 $root/var/lib/omarchy/backups/asahi-repository-[0-9]{14}\$" "$calls" ||
  fail "a root-owned backup directory is created" "$(cat "$calls")"
[[ -f $(ls -d "$root"/var/lib/omarchy/backups/asahi-repository-*/pacman.conf) ]] || fail "the previous pacman.conf is backed up"
[[ -f $state ]] || fail "repository state is recorded"
grep -Fxq "tag=$new_tag" "$state" || fail "repository state records the snapshot"
grep -Fxq 'workflow_run=33487927893' "$state" || fail "repository state records the signed build"
grep -Fxq "descriptor_sha256=$(sha256sum "$assets/$new_tag/CANDIDATE" | cut -d' ' -f1)" "$state" ||
  fail "repository state records the descriptor digest"
pass "the [omarchy] repository is repointed at the verified stable snapshot"

reset_run
run_status "$test_tmp/again.out" "$test_tmp/again.err" --check
(( status == 1 )) || fail "the switched repository is current" "status $status: $(cat "$test_tmp/again.err")"
pass "a switched repository is not offered again"

write_pacman_conf "$old_tag"
reset_run
: >"$test_tmp/key-trusted"
TEST_PACMAN_FAIL=1 run_status "$test_tmp/sync.out" "$test_tmp/sync.err" --yes
(( status == 2 )) || fail "a failed repository sync fails closed" "status $status"
grep -Fq 'restored the previous repository' "$test_tmp/sync.err" || fail "sync failure explains the restore" "$(cat "$test_tmp/sync.err")"
grep -Fxq "Server = https://github.com/$repo/releases/download/$old_tag" "$pacman_conf" || fail "a failed sync restores the previous Server"
! grep -Fq 'pacman-key:--add' "$calls" || fail "an already trusted key is not re-imported"
[[ ! -f $state ]] || fail "a failed sync records no state"
pass "a snapshot pacman cannot read leaves the previous repository in place"
