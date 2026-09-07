#!/bin/bash

# The runtime is shared by the Asahi and Aurora payloads, so every script that
# names a kernel asks this helper. It must answer linux-asahi on an Asahi
# install, where the marker file does not exist at all.

source "$(dirname "$0")/base-test.sh"

helper="$ROOT/bin/omarchy-hw-apple-kernel"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[[ $(OMARCHY_APPLE_KERNEL_FILE="$work/absent" "$helper") == linux-asahi ]] ||
  fail "an install with no marker reports the Asahi kernel"

printf 'linux-aurora\n' >"$work/aurora"
[[ $(OMARCHY_APPLE_KERNEL_FILE="$work/aurora" "$helper") == linux-aurora ]] ||
  fail "an Aurora install reports the Aurora kernel"

printf 'linux-asahi\n' >"$work/asahi"
[[ $(OMARCHY_APPLE_KERNEL_FILE="$work/asahi" "$helper") == linux-asahi ]] ||
  fail "an explicit Asahi marker reports the Asahi kernel"

# The marker names a package that reaches pacman and a boot path, so anything
# that is not a bare kernel package name is refused rather than passed along.
for content in 'linux-aurora; rm -rf /' '../../etc/passwd' '' 'LINUX-AURORA'; do
  printf '%s\n' "$content" >"$work/hostile"
  [[ $(OMARCHY_APPLE_KERNEL_FILE="$work/hostile" "$helper") == linux-asahi ]] ||
    fail "a marker holding '$content' is refused"
done

ln -sfn "$work/aurora" "$work/link"
[[ $(OMARCHY_APPLE_KERNEL_FILE="$work/link" "$helper") == linux-asahi ]] ||
  fail "a symlinked marker is refused"

pass "the kernel helper defaults to Asahi and only accepts a real kernel name"
