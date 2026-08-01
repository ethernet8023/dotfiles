#!/usr/bin/env bash
# Run the cctrack web UI with auto-sync, without a browser window in your face.
#
# A sync must drive a headed browser -- CIBC's edge drops headless ones during
# the h2 handshake -- so an hourly sync would otherwise pop a window open while
# you are working. cage on the wlroots headless backend is a real compositor
# with no visible output, so the browser is genuinely headed and invisible.
#
#   ./scripts/serve.sh              # hourly
#   ./scripts/serve.sh --every 180  # every three hours
#
# The vault must be unlocked first; the scheduler pauses rather than failing
# repeatedly if it locks:
#   export BW_SESSION=$(bw unlock --raw)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${BW_SESSION:-}" ]; then
  echo "BW_SESSION unset - run: export BW_SESSION=\$(bw unlock --raw)" >&2
  echo "(the UI still works; scheduled syncs will pause until it is set)" >&2
fi

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

exec cage -- python3 -m cctrack.cli serve --auto-sync "$@"
