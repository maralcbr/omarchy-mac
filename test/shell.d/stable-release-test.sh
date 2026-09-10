#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
version=$(<"$ROOT/version")
notes="$ROOT/docs/releases/v$version.md"
[[ -s $notes ]]
grep -Fxq "# Omarchy MX Mac $version" "$notes"
grep -Fxq '## Validation' "$notes"
grep -Fq '**Full Changelog**:' "$notes"
grep -Fq "## [$version]" "$ROOT/CHANGELOG.md"
grep -Fq "| Omarchy \`$version\` | Recommended stable version |" "$ROOT/README.md" ||
  grep -Fq "| Omarchy \`$version\` | Prepared update (unpublished) |" "$ROOT/README.md"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state/omarchy/releases" "$tmp/release"

cat >"$tmp/release/omarchy-mx-mac-release" <<'EOF'
format=1
track=stable-mac
sequence=3
version=4.0.0-mac.1
source_tag=v4.0.0-mac.1
source_commit=0123456789abcdef0123456789abcdef01234567
minimum_updater_version=1
EOF
: >"$tmp/release/omarchy-mx-mac-release.sig"
: >"$tmp/keyring.gpg"

cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
while (($#)); do
  if [[ $1 == "--output" ]]; then
    output=$2
    shift 2
  else
    url=$1
    shift
  fi
done
cp "${url#file://}" "$output"
EOF
cat >"$tmp/bin/gpg" <<'EOF'
#!/bin/bash
if [[ " $* " == *" --show-keys "* ]]; then
  echo 'fpr:::::::::5983B1CA32CB778F4D74D24ECFF35022CA5B5959:'
elif [[ " $* " == *" --import "* ]]; then
  exit 0
elif [[ " $* " == *" --verify "* ]]; then
  (( ${GPG_EXIT:-0} == 0 )) || exit "$GPG_EXIT"
  echo '[GNUPG:] VALIDSIG SIGNINGSUBKEY 2026-01-01 0 4 0 1 10 00 5983B1CA32CB778F4D74D24ECFF35022CA5B5959'
fi
EOF
chmod +x "$tmp/bin"/*


cat >"$tmp/bin/gh" <<'EOF'
#!/bin/bash
[[ $1 == "api" ]] || exit 2
case "${GH_RELEASE_SCENARIO:-assetless-latest}" in
  assetless-latest)
    printf '%s\n' '[{"tag_name":"v4.0.1-mac.2","assets":[]},{"tag_name":"v4.0.1-mac.1","assets":[{"name":"omarchy-mx-mac-release"},{"name":"omarchy-mx-mac-release.sig"}]}]'
    ;;
  paginated)
    printf '%s\n' '[{"tag_name":"v4.0.1-mac.2","assets":[]}]'
    printf '%s\n' '[{"tag_name":"v4.0.1-mac.1","assets":[{"name":"omarchy-mx-mac-release"}]}]'
    ;;
  no-descriptor)
    printf '%s\n' '[{"tag_name":"v4.0.1-mac.2","assets":[]}]'
    ;;
  api-failure)
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/bin/gh"

previous_tag=$(PATH="$tmp/bin:$PATH" GH_RELEASE_SCENARIO=assetless-latest \
  "$ROOT/scripts/find-previous-stable-release" maralcbr/omarchy-mx-mac)
[[ $previous_tag == "v4.0.1-mac.1" ]] || {
  echo "not ok - assetless latest release did not fall back to signed descriptor" >&2
  exit 1
}

previous_tag=$(PATH="$tmp/bin:$PATH" GH_RELEASE_SCENARIO=paginated \
  "$ROOT/scripts/find-previous-stable-release" maralcbr/omarchy-mx-mac)
[[ $previous_tag == "v4.0.1-mac.1" ]] || {
  echo "not ok - paginated release lookup missed signed descriptor" >&2
  exit 1
}

if PATH="$tmp/bin:$PATH" GH_RELEASE_SCENARIO=no-descriptor \
  "$ROOT/scripts/find-previous-stable-release" maralcbr/omarchy-mx-mac >/dev/null 2>&1; then
  echo "not ok - missing signed descriptor was accepted" >&2
  exit 1
fi

if PATH="$tmp/bin:$PATH" GH_RELEASE_SCENARIO=api-failure \
  "$ROOT/scripts/find-previous-stable-release" maralcbr/omarchy-mx-mac >/dev/null 2>&1; then
  echo "not ok - GitHub API failure was accepted" >&2
  exit 1
fi

run_resolver() {
  PATH="$tmp/bin:$ROOT/bin:/usr/bin" XDG_STATE_HOME="$tmp/state" \
    OMARCHY_RELEASE_KEYRING="$tmp/keyring.gpg" \
    OMARCHY_RELEASE_BASE_URL="file://$tmp/release" \
    "$ROOT/bin/omarchy-stable-release" "$@"
}

[[ $(run_resolver source_tag) == "v4.0.0-mac.1" ]]
[[ $(run_resolver source_commit) == "0123456789abcdef0123456789abcdef01234567" ]]

GPG_EXIT=1 run_resolver >/dev/null 2>&1 && { echo "not ok - invalid signature accepted"; exit 1; }

sed -i 's/^sequence=3$/sequence=2/' "$tmp/release/omarchy-mx-mac-release"
printf 'format=1\ntrack=stable-mac\nsequence=3\n' >"$tmp/state/omarchy/releases/stable-mac"
run_resolver >/dev/null 2>&1 && { echo "not ok - rollback accepted"; exit 1; }

echo "ok - stable release descriptor verification and anti-rollback"
