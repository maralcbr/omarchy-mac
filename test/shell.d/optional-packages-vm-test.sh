#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"

# The real guest stages this helper under /root. Keep this unit test outside
# the guest filesystem and replace only that deployment path with a stub.
printf '#!/bin/bash\nexit 0\n' >"$test_tmp/alarm-snapshot"
sed "s|bash /root/omarchy-vm-alarm-snapshot|bash $test_tmp/alarm-snapshot|" \
  "$ROOT/test/vm/asahi-fresh/guest/optional-packages" >"$test_tmp/optional-packages"


cat >"$test_tmp/bin/pacman" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_PACMAN_LOG"
case $1 in
  -S)
    [[ " $* " != *' broken '* ]]
    ;;
  -Q)
    [[ $2 != unregistered ]]
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$test_tmp/bin/pacman"

cat >"$test_tmp/transactions.tsv" <<'EOF'
install.good|primary secondary
install.broken|broken
install.unregistered|unregistered
EOF
printf '%s\n' install.good install.broken install.unregistered >"$test_tmp/required"

export OMARCHY_TEST_PACMAN_LOG="$test_tmp/pacman.log"
set +e
output=$(PATH="$test_tmp/bin:$PATH" \
  OMARCHY_OPTIONAL_PACKAGES_FILE="$test_tmp/transactions.tsv" \
  OMARCHY_OPTIONAL_REQUIRED_FILE="$test_tmp/required" \
  OMARCHY_OPTIONAL_LOG_DIR="$test_tmp/logs" \
  bash "$test_tmp/optional-packages" 2>&1)
status=$?
set -e

(( status != 0 )) || fail 'optional package VM stage fails when any transaction fails'
[[ $output == *'1 installed, 2 failed'* ]] ||
  fail 'optional package VM stage reports every transaction' "$output"
grep -Fqx -- '-S --noconfirm --needed primary secondary' "$OMARCHY_TEST_PACMAN_LOG" ||
  fail 'optional package VM stage installs complete transactions'
grep -Fqx -- '-S --noconfirm --needed broken' "$OMARCHY_TEST_PACMAN_LOG" ||
  fail 'optional package VM stage continues after a failed transaction'
grep -Fqx -- '-S --noconfirm --needed unregistered' "$OMARCHY_TEST_PACMAN_LOG" ||
  fail 'optional package VM stage checks later transactions'
[[ -f $test_tmp/logs/install-good.log && -f $test_tmp/logs/install-broken.log ]] ||
  fail 'optional package VM stage retains per-transaction logs'
pass 'optional package VM stage installs all transactions and reports every failure'

printf '%s\n' install.unknown >"$test_tmp/required"
if PATH="$test_tmp/bin:$PATH" \
  OMARCHY_OPTIONAL_PACKAGES_FILE="$test_tmp/transactions.tsv" \
  OMARCHY_OPTIONAL_REQUIRED_FILE="$test_tmp/required" \
  OMARCHY_OPTIONAL_LOG_DIR="$test_tmp/logs" \
  bash "$test_tmp/optional-packages" >/dev/null 2>&1; then
  fail 'optional package VM stage rejects unknown required transactions'
fi
pass 'optional package VM stage rejects unknown required transactions'
