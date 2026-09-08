#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

user_leaf="$ROOT/install/user/hardware/apple/fix-speaker-pop.sh"
hardware_leaf="$ROOT/install/hardware/apple/fix-speaker-pop.sh"
user_all="$ROOT/install/user/all.sh"
hardware_all="$ROOT/install/hardware/all.sh"
migration="$ROOT/migrations/1788345489.sh"
dropin="$ROOT/default/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf"
etc_dropin="$ROOT/etc/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf"
dsp_src="$ROOT/default/wireplumber/scripts/node/software-dsp.lua"

grep -q 'apple/fix-speaker-pop.sh' "$user_all" ||
  fail "the speaker pop fix runs during per-user setup"
pass "the speaker pop fix runs during per-user setup"

grep -q 'apple/fix-speaker-pop.sh' "$hardware_all" ||
  fail "the speaker pop fix runs during machine-wide hardware setup"
pass "the speaker pop fix runs during machine-wide hardware setup"

cmp -s "$dropin" "$etc_dropin" ||
  fail "the packaged /etc drop-in matches the default source" "$(diff "$dropin" "$etc_dropin")"
pass "the packaged /etc drop-in matches the default source"

# The shipped rule must reach the raw speaker node, which the Asahi rules rename
# and hide, so it has to match on the ALSA path. Device 1 is the speaker array
# and device 0 the headphone jack on every AppleJ model.
grep -Fq 'api.alsa.path = "~hw:AppleJ[0-9][0-9][0-9],[01]"' "$dropin" ||
  fail "the drop-in matches every Apple Silicon speaker and headphone output" "$(cat "$dropin")"
grep -Fq 'session.suspend-timeout-seconds = 0' "$dropin" ||
  fail "the drop-in disables the idle suspend that powers the amplifiers down" "$(cat "$dropin")"
pass "the drop-in keeps the Apple Silicon outputs from suspending"

# The DSP overlay is session-wide: any current or future PipeWire/Pulse client
# that closes its stream would otherwise pause the asahi-audio convolver.
grep -Fq 'keep_speaker_dsp_alive' "$dsp_src" ||
  fail "the DSP overlay keeps speaker graphs from pausing" "$(cat "$dsp_src")"
grep -Fq 'session.suspend-timeout-seconds' "$dsp_src" ||
  fail "the DSP overlay pins the convolver suspend timeout" "$(cat "$dsp_src")"
grep -Fq 'node.pause-on-idle' "$dsp_src" ||
  fail "the DSP overlay disables pause-on-idle on speaker graphs" "$(cat "$dsp_src")"
pass "the DSP overlay keeps the speaker convolver from pausing"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
home="$test_tmp/home"
conf="$home/.config/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf"
dsp="$home/.local/share/wireplumber/scripts/node/software-dsp.lua"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash

[[ ${APPLE_SILICON:-0} == "1" ]]
SH

# Stubbed rather than run: the real one would restart the running user's audio.
cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash

printf 'systemctl' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
"$@"
SH

chmod +x "$stub_bin"/*

sys_conf="$test_tmp/etc/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf"
sys_dsp="$test_tmp/usr/local/share/wireplumber/scripts/node/software-dsp.lua"

run_user_leaf() {
  local apple_silicon="${1:-1}"

  rm -rf "$home"
  mkdir -p "$home"

  APPLE_SILICON="$apple_silicon" HOME="$home" OMARCHY_PATH="$ROOT" \
    PATH="$stub_bin:$PATH" \
    bash -eE -c 'source "$1"' bash "$user_leaf" </dev/null
}

run_hardware_leaf() {
  local apple_silicon="${1:-1}"

  rm -rf "$test_tmp/etc" "$test_tmp/usr"
  : >"$calls"

  APPLE_SILICON="$apple_silicon" HOME="$home" OMARCHY_PATH="$ROOT" \
    TEST_LOG="$calls" PATH="$stub_bin:$PATH" \
    OMARCHY_ASAHI_SPEAKER_CONF="$sys_conf" \
    OMARCHY_ASAHI_SPEAKER_DSP="$sys_dsp" \
    bash -eE -c 'source "$1"' bash "$hardware_leaf" </dev/null
}

run_user_leaf >/dev/null
[[ -f $conf ]] ||
  fail "an Apple Silicon Mac gets the drop-in" "$(ls -R "$home" 2>&1)"
cmp -s "$conf" "$dropin" ||
  fail "the installed drop-in is the shipped one" "$(diff "$dropin" "$conf")"
[[ -f $dsp ]] ||
  fail "an Apple Silicon Mac gets the DSP overlay" "$(ls -R "$home" 2>&1)"
cmp -s "$dsp" "$dsp_src" ||
  fail "the installed DSP overlay is the shipped one" "$(diff "$dsp_src" "$dsp")"
pass "an Apple Silicon Mac gets the drop-in and DSP overlay"

run_hardware_leaf >/dev/null
[[ -f $sys_conf ]] ||
  fail "an Apple Silicon Mac gets the machine-wide drop-in" "$(ls -R "$test_tmp/etc" 2>&1)"
cmp -s "$sys_conf" "$dropin" ||
  fail "the machine-wide drop-in is the shipped one" "$(diff "$dropin" "$sys_conf")"
[[ -f $sys_dsp ]] ||
  fail "an Apple Silicon Mac gets the machine-wide DSP overlay" "$(ls -R "$test_tmp/usr" 2>&1)"
cmp -s "$sys_dsp" "$dsp_src" ||
  fail "the machine-wide DSP overlay is the shipped one" "$(diff "$dsp_src" "$sys_dsp")"
pass "an Apple Silicon Mac gets the machine-wide drop-in and DSP overlay"

# Intel and T2 Macs have a different audio path with no amplifier to keep awake.
run_user_leaf 0 >/dev/null
[[ ! -e $conf ]] ||
  fail "a Mac without Apple Silicon is left alone" "$(cat "$conf")"
[[ ! -e $dsp ]] ||
  fail "a Mac without Apple Silicon does not get the DSP overlay" "$(cat "$dsp")"
pass "a Mac without Apple Silicon is left alone"

run_hardware_leaf 0 >/dev/null
[[ ! -e $sys_conf ]] ||
  fail "a Mac without Apple Silicon does not get the machine-wide drop-in" "$(cat "$sys_conf")"
[[ ! -e $sys_dsp ]] ||
  fail "a Mac without Apple Silicon does not get the machine-wide DSP overlay" "$(cat "$sys_dsp")"
pass "a Mac without Apple Silicon is left alone by hardware setup"

# Installs that predate the leaf never ran it, so the migration has to reach
# them. omarchy-migrate runs migrations under bash -euo pipefail.
run_migration() {
  local apple_silicon="${1:-1}"

  : >"$calls"

  APPLE_SILICON="$apple_silicon" HOME="$home" TEST_LOG="$calls" \
    OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" \
    OMARCHY_ASAHI_SPEAKER_CONF="$sys_conf" \
    OMARCHY_ASAHI_SPEAKER_DSP="$sys_dsp" \
    bash -euo pipefail "$migration"
}

rm -rf "$home" "$test_tmp/etc" "$test_tmp/usr"
mkdir -p "$home"
run_migration >/dev/null
[[ -f $conf && -f $dsp && -f $sys_conf && -f $sys_dsp ]] ||
  fail "the migration fixes an install that never ran the leaf" "$(ls -R "$home" "$test_tmp/etc" "$test_tmp/usr" 2>&1)"
grep -Fq $'systemctl\t--user\trestart\twireplumber.service' "$calls" ||
  fail "the migration restarts WirePlumber so the fix applies without a logout" "$(cat "$calls")"
pass "the migration fixes an install that never ran the leaf"

run_migration >/dev/null
[[ ! -s $calls ]] ||
  fail "a repaired install is left untouched" "$(cat "$calls")"
pass "the migration is idempotent"

# An ALSA-only copy from the first revision must still pick up the DSP overlay
# and the machine-wide files.
rm -rf "$home" "$test_tmp/etc" "$test_tmp/usr"
mkdir -p "$(dirname "$conf")"
cp "$dropin" "$conf"
run_migration >/dev/null
[[ -f $dsp && -f $sys_conf && -f $sys_dsp ]] ||
  fail "the migration adds the DSP overlay to an ALSA-only install" "$(ls -R "$home" "$test_tmp/etc" "$test_tmp/usr" 2>&1)"
grep -Fq $'systemctl\t--user\trestart\twireplumber.service' "$calls" ||
  fail "the migration restarts WirePlumber after adding the DSP overlay" "$(cat "$calls")"
pass "the migration adds the DSP overlay to an ALSA-only install"

rm -rf "$home" "$test_tmp/etc" "$test_tmp/usr"
mkdir -p "$home"
run_migration 0 >/dev/null
[[ ! -e $conf ]] ||
  fail "the migration skips hardware without the popping amplifiers" "$(cat "$conf")"
[[ ! -e $dsp ]] ||
  fail "the migration does not install the DSP overlay off Apple Silicon" "$(cat "$dsp")"
[[ ! -e $sys_conf ]] ||
  fail "the migration does not install the machine-wide drop-in off Apple Silicon" "$(cat "$sys_conf")"
[[ ! -s $calls ]] ||
  fail "the migration restarts nothing without Apple Silicon" "$(cat "$calls")"
pass "the migration skips hardware without the popping amplifiers"

echo "apple-speaker-pop: all checks passed"
