# Keep the Apple Silicon speaker amplifiers powered between streams, and keep
# the asahi-audio DSP graph from pausing when a client closes its stream.
#
# These files are machine-wide so every user session and every PipeWire/Pulse
# client (current or future) gets the fix. The ALSA drop-in is also shipped
# at etc/wireplumber/ for omarchy-settings; this leaf still copies it so an
# install whose settings package predates that path is repaired. The DSP
# overlay cannot live in omarchy-settings: it shadows WirePlumber's
# node/software-dsp.lua and must not do that on x86.
omarchy-hw-apple-silicon || return 0

echo "Detected Apple Silicon Mac: keeping the speaker amplifiers and DSP graph powered between streams"

OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
dropin="$OMARCHY_PATH/default/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf"
dsp="$OMARCHY_PATH/default/wireplumber/scripts/node/software-dsp.lua"
sys_conf="${OMARCHY_ASAHI_SPEAKER_CONF:-/etc/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf}"
sys_dsp="${OMARCHY_ASAHI_SPEAKER_DSP:-/usr/local/share/wireplumber/scripts/node/software-dsp.lua}"

sudo mkdir -p "$(dirname "$sys_conf")"
sudo cp "$dropin" "$sys_conf"

sudo mkdir -p "$(dirname "$sys_dsp")"
sudo cp "$dsp" "$sys_dsp"
