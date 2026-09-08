echo "Keep the Apple Silicon speaker amplifiers and DSP graph powered so playback stops popping"

# The hardware leaf writes the machine-wide copies; the user leaf writes the
# per-session copies. New installs run both; this migration reaches machines
# that predate either leaf. Re-run if any of the four files is missing so an
# ALSA-only or user-only copy from an earlier revision still becomes OS-wide.
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
hardware_script="$OMARCHY_PATH/install/hardware/apple/fix-speaker-pop.sh"
user_script="$OMARCHY_PATH/install/user/hardware/apple/fix-speaker-pop.sh"
sys_conf="${OMARCHY_ASAHI_SPEAKER_CONF:-/etc/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf}"
sys_dsp="${OMARCHY_ASAHI_SPEAKER_DSP:-/usr/local/share/wireplumber/scripts/node/software-dsp.lua}"
user_conf="$HOME/.config/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf"
user_dsp="$HOME/.local/share/wireplumber/scripts/node/software-dsp.lua"

[[ -f $hardware_script || -f $user_script ]] || exit 0
[[ -f $sys_conf && -f $sys_dsp && -f $user_conf && -f $user_dsp ]] && exit 0

[[ -f $hardware_script ]] && source "$hardware_script"
[[ -f $user_script ]] && source "$user_script"
[[ -f $sys_conf && -f $sys_dsp ]] || [[ -f $user_conf && -f $user_dsp ]] || exit 0

# WirePlumber only reads drop-ins and scripts at startup. Restarting the audio
# stack is a few hundred milliseconds of silence in the visible update terminal,
# and it is what makes the fix take effect without a logout. A failed restart is
# not a failed migration: the files are in place and the next login picks them up.
systemctl --user restart wireplumber.service >/dev/null 2>&1 || true
