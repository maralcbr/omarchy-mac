local paths = require("default.hypr.paths")

local apple_silicon = paths.omarchy_path .. "/bin/omarchy-hw-apple-silicon"

-- Apple's display controller runs its own firmware, and a hardware cursor
-- plane makes every pointer update a round trip into it. Under Hyprland that
-- path lags the pointer far enough behind the hand that every click feels
-- late, while the click itself reaches the page in a millisecond. Draw the
-- cursor in the frame the compositor already renders instead.
if o.shell_succeeds(o.shell_quote(apple_silicon)) then
  hl.config({
    cursor = {
      no_hardware_cursors = true,
    },
  })
end
