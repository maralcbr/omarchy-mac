# Keep the Apple Silicon speaker amplifiers powered between streams, and keep
# the asahi-audio DSP graph from pausing when a client closes its stream.
#
# Machine-wide copies live under /etc and /usr/local (see
# install/hardware/apple/fix-speaker-pop.sh). This per-user copy covers the
# session that is finalizing now, including users created after install, and
# stays in lockstep with the shipped files whenever the leaf re-runs.
omarchy-hw-apple-silicon || return 0

echo "Detected Apple Silicon Mac: keeping the speaker amplifiers and DSP graph powered between streams"

mkdir -p "$HOME/.config/wireplumber/wireplumber.conf.d"
cp "$OMARCHY_PATH/default/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf" \
  "$HOME/.config/wireplumber/wireplumber.conf.d/"

# WirePlumber loads scripts from XDG_DATA_HOME before /usr/share, so this
# shadows node/software-dsp.lua for this user without touching the package.
mkdir -p "$HOME/.local/share/wireplumber/scripts/node"
cp "$OMARCHY_PATH/default/wireplumber/scripts/node/software-dsp.lua" \
  "$HOME/.local/share/wireplumber/scripts/node/"
