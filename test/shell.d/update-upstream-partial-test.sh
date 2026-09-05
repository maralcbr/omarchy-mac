#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB

# Fails every upgrade with the report under test and counts the attempts.
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
echo $(($(cat "$PACMAN_ATTEMPTS") + 1)) >"$PACMAN_ATTEMPTS"
cat "$PACMAN_REPORT" >&2
exit 1
STUB

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE_SILICON:-} == 1 ]]
STUB

# Reaching the conflict handler at all is the failure under test, so it records
# and refuses rather than doing anything.
cat >"$stub_bin/omarchy-update-system-pkgs-when-conflicted" <<'STUB'
#!/bin/bash
touch "$HANDLER_CALLED"
exit 1
STUB

chmod +x "$stub_bin"/*

# Exactly what pacman leaves on stderr when a repository is mid-transition:
# aquamarine already rebuilt for a new soname, hyprland not yet.
write_report() {
  echo 0 >"$test_tmp/attempts"
  rm -f "$test_tmp/handler-called"
  printf '%s\n' "$@" >"$test_tmp/report"
}

run_update() {
  env \
    PACMAN_ATTEMPTS="$test_tmp/attempts" \
    PACMAN_REPORT="$test_tmp/report" \
    HANDLER_CALLED="$test_tmp/handler-called" \
    APPLE_SILICON="${APPLE_SILICON:-}" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$ROOT/bin/omarchy-update-system-pkgs" </dev/null >"$test_tmp/out" 2>"$test_tmp/err"
}

write_report \
  ":: installing aquamarine (0.15.0-2) breaks dependency 'libaquamarine.so=13-64' required by hyprland" \
  "error: failed to prepare transaction (could not satisfy dependencies)"
status=0
APPLE_SILICON=1 run_update || status=$?
(( status == 3 )) || fail "a mid-transition repository is not reported with its own status (got $status)"
grep -q 'Arch Linux ARM repositories are mid-update' "$test_tmp/err" ||
  fail "a mid-transition repository is not named as the cause"
grep -q 'Nothing on this Mac was changed' "$test_tmp/err" ||
  fail "the update does not say the Mac is untouched"
grep -q 'Try again later' "$test_tmp/err" ||
  fail "the update does not say what to do"
[[ ! -e $test_tmp/handler-called ]] ||
  fail "a mid-transition repository is handed to the conflict handler"
(($(cat "$test_tmp/attempts") == 1)) ||
  fail "an upgrade pacman refused is retried"
pass "a repository mid-transition is explained, not treated as our conflict"

write_report \
  ":: unable to satisfy dependency 'libaquamarine.so=13-64' required by hyprtoolkit" \
  "error: failed to prepare transaction (could not satisfy dependencies)"
status=0
APPLE_SILICON=1 run_update || status=$?
(( status == 3 )) && grep -q 'mid-update' "$test_tmp/err" ||
  fail "an unsatisfiable dependency is not recognised as a repository mid-transition"
pass "both of pacman's partial-upgrade refusals are recognised"

write_report \
  ":: unable to satisfy dependency 'libaquamarine.so=13-64' required by hyprtoolkit"
status=0
run_update || status=$?
(( status == 3 )) || fail "the message is Apple-only"
grep -q 'Arch Linux repositories are mid-update' "$test_tmp/err" ||
  fail "a non-Apple system is told about Arch Linux ARM"
grep -q 'Nothing on this computer was changed' "$test_tmp/err" ||
  fail "a non-Apple system is called a Mac"
pass "the wording follows the hardware"

# Every other failure still goes to the conflict handler, as before.
write_report \
  "omarchy: /usr/share/omarchy/x exists in filesystem" \
  "error: failed to commit transaction (conflicting files)"
status=0
APPLE_SILICON=1 run_update || status=$?
(( status != 3 )) || fail "a file conflict is mistaken for a repository mid-transition"
[[ -e $test_tmp/handler-called ]] ||
  fail "a file conflict no longer reaches the conflict handler"
pass "other failures still reach the conflict handler"
