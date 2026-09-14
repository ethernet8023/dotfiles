#!/usr/bin/env bash
# ploopy-curve: launch the live trackball curve editor.
# Syncs starting curve from ~/dotfiles (what's baked), starts server if needed,
# prints the URL. Slider changes go live via hyprctl eval; re-bake winners
# into home-manager/hosts/luna.nix.
set -euo pipefail
DIR="$HOME/.local/share/ploopy-curve-editor"
PORT=8799
NIX_CFG="$HOME/dotfiles/home-manager/hosts/luna.nix"

python3 - "$NIX_CFG" "$DIR/curve.json" <<'EOF'
import re, sys, json
raw = open(sys.argv[1]).read()
m = re.search(r'accel_profile\s*=\s*"custom\s+([\d.]+)\s+([^"]+)"', raw)
if not m:
    sys.exit("no custom accel_profile found in " + sys.argv[1])
json.dump({"step": float(m.group(1)), "points": [float(x) for x in m.group(2).split()]},
          open(sys.argv[2], "w"))
EOF

if ! pgrep -f "ploopy-curve-editor/serve[r]\.py" >/dev/null; then
    setsid python3 "$DIR/server.py" >/dev/null 2>&1 &
    sleep 0.5
fi
echo "curve editor: http://127.0.0.1:$PORT"
