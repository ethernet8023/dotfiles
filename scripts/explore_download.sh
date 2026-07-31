#!/usr/bin/env bash
# Explore CIBC's transaction-download UI, headed inside a hidden compositor.
#
# Requires BW_SESSION in the environment. Downloads nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${BW_SESSION:-}" ]; then
  echo "BW_SESSION unset - run: export BW_SESSION=\$(bw unlock --raw)" >&2
  exit 1
fi

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

exec cage -- python3 scripts/explore_download.py
