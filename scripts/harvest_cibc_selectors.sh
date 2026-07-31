#!/usr/bin/env bash
# Harvest the real CIBC sign-on selectors, headed, inside a hidden compositor.
#
# CIBC (Akamai) drops headless chromium during the h2 handshake, so this must run
# genuinely headed. cage on the wlroots headless backend gives a real compositor
# with no visible window.
set -euo pipefail
cd "$(dirname "$0")/.."

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

exec cage -- python3 scripts/harvest_cibc_selectors.py
