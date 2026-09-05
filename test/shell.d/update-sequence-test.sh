#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

# Every step omarchy-update runs, recorded in order with the unattended flag it
# was handed. One of them can be told to fail.
steps=(
  omarchy-update-lock
  omarchy-update-requires-free-space
  omarchy-update-confirm
  omarchy-update-pkg-prune
  omarchy-snapshot
  omarchy-update-stay-awake
  omarchy-update-dev
  omarchy-update-keyring
  omarchy-update-system-pkgs
  omarchy-migrate
  omarchy-hook
  omarchy-update-aur-pkgs
  omarchy-update-mise
  omarchy-update-orphan-pkgs
  omarchy-update-analyze-logs
  omarchy-update-status
  omarchy-update-restart
)

for step in "${steps[@]}"; do
  cat >"$stub_bin/$step" <<'STUB'
#!/bin/bash
printf '%s unattended=%s\n' "${0##*/}" "${OMARCHY_UPDATE_UNATTENDED:-}" >>"$STEP_LOG"
if [[ ${CLEANUP_FAIL:-0} == "1" && ${0##*/} == "omarchy-update-stay-awake" && ${1:-} == "stop" ]]; then
  exit 7
fi
[[ ${FAILING_STEP:-} != "${0##*/}" ]] || exit "${FAILING_STATUS:-42}"
STUB
  chmod +x "$stub_bin/$step"
done

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$stub_bin/omarchy-hw-apple-silicon"

# OMARCHY_UPDATE_LOGGED stands in for the script(1) wrapper the update re-execs
# itself under; the stubbed lock reports itself already held.
run_update() {
  : >"$test_tmp/steps"
  STEP_LOG="$test_tmp/steps" \
    FAILING_STEP="${FAILING_STEP:-}" \
    FAILING_STATUS="${FAILING_STATUS:-}" \
    CLEANUP_FAIL="${CLEANUP_FAIL:-0}" \
    OMARCHY_UPDATE_LOGGED=1 \
    PATH="$stub_bin:$PATH" \
    bash "$ROOT/bin/omarchy-update" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

steps_run() {
  cut -d' ' -f1 "$test_tmp/steps"
}

# Every step of a whole update, in order. $1 asks for the one a person confirms.
# Stay Awake bookends the work, so it is here twice.
expected_steps() {
  printf '%s\n' \
    omarchy-update-lock \
    omarchy-update-requires-free-space \
    ${1:+omarchy-update-confirm} \
    omarchy-update-pkg-prune \
    omarchy-snapshot \
    omarchy-update-stay-awake \
    omarchy-update-dev \
    omarchy-update-keyring \
    omarchy-update-system-pkgs \
    omarchy-migrate \
    omarchy-hook \
    omarchy-update-aur-pkgs \
    omarchy-update-mise \
    omarchy-update-orphan-pkgs \
    omarchy-update-analyze-logs \
    omarchy-update-status \
    omarchy-update-stay-awake \
    omarchy-update-restart
}

run_update -y || fail "an update where everything works reports a failure"
diff <(expected_steps) <(steps_run) >"$test_tmp/order" ||
  fail "an update where everything works does not run every step in order" "$(cat "$test_tmp/order")"
pass "an update where every step works runs all of them, in order"

grep -q '^omarchy-update-system-pkgs unattended=1$' "$test_tmp/steps" ||
  fail "-y does not mark the update unattended"
run_update </dev/null || fail "a confirmed update reports a failure"
diff <(expected_steps confirmed) <(steps_run) >"$test_tmp/order" ||
  fail "a confirmed update runs a different set of steps" "$(cat "$test_tmp/order")"
grep -q '^omarchy-update-system-pkgs unattended=$' "$test_tmp/steps" ||
  fail "an update a person confirmed is treated as unattended"
pass "-y is what marks an update unattended, not the update itself"

# Migrations ship with the packages the upgrade installs and are written against
# them. Running them against what is still on disk is the failure this ordering
# exists to prevent, so the update stops where the packages did.
if FAILING_STEP=omarchy-update-system-pkgs run_update -y; then
  fail "an update whose packages did not upgrade passes for a whole one"
fi
for step in omarchy-migrate omarchy-hook omarchy-update-aur-pkgs omarchy-update-restart; do
  if grep -q "^$step " "$test_tmp/steps"; then
    fail "a blocked package upgrade still runs $step"
  fi
done
pass "a blocked package upgrade stops the update before it migrates"

set +e
FAILING_STEP=omarchy-update-system-pkgs CLEANUP_FAIL=1 run_update -y
update_status=$?
set -e
[[ $update_status -eq 42 ]] ||
  fail "cleanup failure replaces the original update status" "expected 42, got $update_status"
pass "cleanup failure preserves the original update status"

# A package upgrade the repositories themselves refuse (status 3) has already
# told the person to try again later; the generic failure banner on top of that
# would send them looking for an error to correct that is not theirs.
set +e
FAILING_STEP=omarchy-update-system-pkgs FAILING_STATUS=3 run_update -y
update_status=$?
set -e
[[ $update_status -eq 3 ]] ||
  fail "a repository mid-transition does not keep its status" "expected 3, got $update_status"
if grep -q 'Something went wrong' "$test_tmp/err" "$test_tmp/out"; then
  fail "a repository mid-transition is reported as something to correct"
fi
if grep -q '^omarchy-migrate ' "$test_tmp/steps"; then
  fail "a repository mid-transition still migrates"
fi
pass "a repository mid-transition stops the update without the failure banner"

set +e
FAILING_STEP=omarchy-update-system-pkgs run_update -y
set -e
grep -q 'Something went wrong' "$test_tmp/out" "$test_tmp/err" ||
  fail "any other blocked upgrade lost the failure banner"
pass "every other blocked upgrade still shows the failure banner"
