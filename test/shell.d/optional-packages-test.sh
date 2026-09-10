#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const menu = requireFromRoot('shell/plugins/menu/MenuModel.js')
const items = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
const byId = new Map(items.map(item => [item.id, item]))
const lines = fs.readFileSync(path.join(root, 'install/optional-packages.tsv'), 'utf8')
  .split('\n')
  .filter(line => line.startsWith('install.'))
const transactions = new Map(lines.map(line => {
  const separator = line.indexOf('|')
  return [line.slice(0, separator), line.slice(separator + 1).split(/\s+/)]
}))
const aurLines = fs.readFileSync(path.join(root, 'install/optional-aur-packages.tsv'), 'utf8')
  .split('\n')
  .filter(line => line.startsWith('install.'))
const aurTransactions = new Map(aurLines.map(line => line.split('|')))
const requiredLines = fs.readFileSync(path.join(root, 'install/optional-packages-aarch64-required'), 'utf8')
  .split('\n')
  .filter(line => line.startsWith('install.'))
const required = new Set(requiredLines)

assertEqual(transactions.size, lines.length, 'optional package transaction ids are unique')
assertEqual(aurTransactions.size, aurLines.length, 'optional AUR transaction ids are unique')
assertEqual(required.size, requiredLines.length, 'required aarch64 transaction ids are unique')
assertEqual(required.size, 23, 'aarch64 support baseline covers every currently supported transaction')
assertDeepEqual(
  [...required].filter(id => !transactions.has(id)),
  [],
  'required aarch64 transactions exist in the package manifest'
)

for (const [id, packages] of transactions) {
  const item = byId.get(id)
  assert(item, `optional package transaction has a menu row: ${id}`)
  assert(
    item.when?.includes(`omarchy-install-available ${id}`),
    `optional package transaction guards its menu row: ${id}`
  )
  assert(packages.length > 0 && packages.every(packageName => /^[a-zA-Z0-9@._+:-]+$/.test(packageName)),
    `optional package transaction contains valid names: ${id}`)
}

const unknownGuards = items
  .filter(item => /omarchy-install-available /.test(item.when || ''))
  .filter(item => !transactions.has(item.id))
  .map(item => item.id)
assertDeepEqual(unknownGuards, [], 'optional install guards all have a transaction')

for (const [id, packageName] of aurTransactions) {
  assert(byId.has(id), `optional AUR transaction has a menu row: ${id}`)
  assert(!transactions.has(id), `optional AUR transaction is not treated as a sync package: ${id}`)
  assert(new RegExp(`\\bomarchy-pkg-aur-add ${packageName}\\b`).test(
    fs.readFileSync(path.join(root, 'bin/omarchy-install-service-nordvpn'), 'utf8')
  ), `optional AUR transaction matches its installer: ${id}`)
}

const unguarded = items
  .filter(item => item.id.startsWith('install.'))
  .filter(item => /omarchy-pkg-present /.test(item.when || ''))
  .filter(item => item.id !== 'install.service.nordvpn')
  .filter(item => !transactions.has(item.id))
  .map(item => item.id)
assertDeepEqual(unguarded, [], 'pacman-backed install rows declare complete transactions')

const requiredSecondaryPackages = {
  'install.service.1password': ['1password-cli'],
  'install.service.dropbox': ['dropbox-cli', 'libappindicator-gtk3', 'python-gpgme', 'nautilus-dropbox'],
  'install.service.bitwarden': ['bitwarden-cli'],
  'install.gaming.retroarch': ['libretro-blastem', 'libretro-ppsspp', 'libretro-fbneo-git', 'retroarch-joypad-autoconfig-git'],
  'install.gaming.lutris': ['umu-launcher', 'wine-staging', 'wine-mono', 'wine-gecko', 'winetricks', 'python-protobuf'],
  'install.development.php.php': ['composer', 'php-sqlite', 'xdebug'],
  'install.development.php.symfony': ['composer', 'php-sqlite', 'xdebug', 'symfony-cli']
}
for (const [id, expected] of Object.entries(requiredSecondaryPackages)) {
  assertDeepEqual(
    expected.filter(packageName => !transactions.get(id).includes(packageName)),
    [],
    `optional package transaction includes secondary packages: ${id}`
  )
}
JS

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/omarchy/install" "$test_tmp/bin"
printf '%s\n' 'install.example|primary secondary' >"$test_tmp/omarchy/install/optional-packages.tsv"

cat >"$test_tmp/bin/omarchy-pkg-available" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >"$OMARCHY_TEST_LOG"
[[ $* == 'primary secondary' ]]
SH
chmod +x "$test_tmp/bin/omarchy-pkg-available"

export OMARCHY_TEST_LOG="$test_tmp/packages.log"
OMARCHY_PATH="$test_tmp/omarchy" PATH="$test_tmp/bin:$PATH" "$ROOT/bin/omarchy-install-available" install.example
[[ $(<"$OMARCHY_TEST_LOG") == 'primary secondary' ]] || fail 'optional install availability checks the complete transaction'
pass 'optional install availability checks the complete transaction'

if OMARCHY_PATH="$test_tmp/omarchy" PATH="$test_tmp/bin:$PATH" "$ROOT/bin/omarchy-install-available" install.unknown 2>/dev/null; then
  fail 'optional install availability rejects unknown transactions'
fi
pass 'optional install availability rejects unknown transactions'

cat >"$test_tmp/bin/pacman" <<'SH'
#!/bin/bash
operation=$1
shift
case $operation in
  -Si)
    [[ $1 != missing* ]]
    ;;
  -Sp)
    [[ " $* " != *' broken '* ]]
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$test_tmp/bin/pacman"
cat >"$test_tmp/live.tsv" <<'EOF'
install.good|primary secondary
install.hidden|missing
install.required-missing|missing-required
install.broken|broken
EOF
printf '%s\n' install.good install.required-missing install.broken >"$test_tmp/required"

set +e
live_output=$(OMARCHY_OPTIONAL_PACKAGES_FILE="$test_tmp/live.tsv" \
  OMARCHY_OPTIONAL_REQUIRED_FILE="$test_tmp/required" \
  OMARCHY_OPTIONAL_PACKAGE_CACHE="$test_tmp/cache" \
  PATH="$test_tmp/bin:$PATH" "$ROOT/test/optional-packages-live" 2>&1)
live_status=$?
set -e
(( live_status != 0 )) || fail 'live optional package preflight fails unresolved transactions'
[[ $live_output == *'1 resolved, 1 hidden, 2 failed'* ]] ||
  fail 'live optional package preflight reports every transaction' "$live_output"
[[ $live_output == *'install.required-missing lost required packages: missing-required'* ]] ||
  fail 'live optional package preflight fails a support regression' "$live_output"
pass 'live optional package preflight reports hidden and unresolved transactions'
