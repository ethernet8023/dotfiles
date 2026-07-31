#!/usr/bin/env bash
# Diagnostic: run a REAL headed chromium inside a headless compositor.
#
# Proven: headless chromium (all 3 variants) gets ERR_HTTP2_PROTOCOL_ERROR from
# CIBC's Akamai edge, because the connection is dropped during the h2 handshake
# before any JS runs -- so navigator.webdriver-style stealth patches cannot help.
# Headed chromium gets 200.
#
# cage on the wlroots headless backend gives us a genuine Wayland compositor with
# no visible window, so chromium runs truly headed (real GPU/display stack, real
# h2 fingerprint) while staying suitable for a cron job.
set -euo pipefail
cd "$(dirname "$0")/.."

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

echo "== running headed chromium under cage (WLR_BACKENDS=headless) =="
exec cage -- python3 scripts/diag_cibc_cage_inner.py
