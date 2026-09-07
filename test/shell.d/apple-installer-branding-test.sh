#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

package=$ROOT/apps/omarchy-apple-installer
build_script=$package/Packaging/build-app.sh
info_plist=$package/Packaging/Info.plist
icon=$package/Packaging/OmarchyInstaller.icns
icon_pack=$package/Packaging/IconPack-Original-Osaka-Jade

if [[ ! -f $icon || -L $icon ]]; then
  fail "installer icon is a real file"
fi
if (( $(wc -c <"$icon") != 80044 )); then
  fail "installer icon has the reviewed size"
fi
if [[ $(sha256sum "$icon" | awk '{print $1}') != \
  "e25b0b39c61cee9881f06f1184978e5e73241f80e42fe8b369ac79242b85b0b9" ]]; then
  fail "installer icon has the reviewed digest"
fi
if [[ $(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleIconFile"])' \
  "$info_plist") != \
  "OmarchyInstaller" ]]; then
  fail "Info.plist selects the Omarchy app icon"
fi
if ! grep -Fq '"$script_directory/OmarchyInstaller.icns"' "$build_script"; then
  fail "app packaging installs the Omarchy app icon"
fi
if ! cmp -s "$ROOT/icon.png" "$icon_pack/original-icon.png"; then
  fail "icon pack preserves the original project image"
fi
if ! cmp -s "$icon" "$icon_pack/OmarchyInstaller.icns"; then
  fail "app packaging uses the approved icon pack"
fi

pass "installer packaging binds the approved original Omarchy icon"
