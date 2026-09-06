#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command lua

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A fake Omarchy root: the real Hyprland Lua tree plus a hardware detector
# whose answer the test controls.
fake_root="$test_tmp/omarchy"
mkdir -p "$fake_root/bin" "$fake_root/default"
ln -s "$ROOT/default/hypr" "$fake_root/default/hypr"

cursor_setting() {
  local detector_exit="$1"
  printf '#!/bin/bash\nexit %s\n' "$detector_exit" >"$fake_root/bin/omarchy-hw-apple-silicon"
  chmod +x "$fake_root/bin/omarchy-hw-apple-silicon"
  OMARCHY_PATH="$fake_root" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local cursor = "unset"
hl = {
  config = function(config)
    if config.cursor and config.cursor.no_hardware_cursors ~= nil then
      cursor = tostring(config.cursor.no_hardware_cursors)
    end
  end,
  env = function() end,
}
require("default.hypr.helpers")
require("default.hypr.apple")
print(cursor)
LUA
}

[[ $(cursor_setting 0) == "true" ]] ||
  fail "Apple Silicon does not get a software cursor"
pass "Apple Silicon draws the cursor in software"

[[ $(cursor_setting 1) == "unset" ]] ||
  fail "a non-Apple machine has its cursor setting changed"
pass "other hardware keeps Hyprland's default cursor"
