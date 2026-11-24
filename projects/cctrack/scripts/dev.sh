#!/usr/bin/env bash
# Run cctrack against a throwaway copy of the production database.
#
# Production runs on bellona as a user unit (home-manager/hosts/bellona.nix in
# the dotfiles). Editing code against the live database is how a migration eats
# a table, so this pulls a consistent snapshot with `cctrack snapshot` -- which
# uses sqlite's backup API, so it is safe while the server is writing -- and
# serves THAT on a different port with auto-sync off.
#
#   ./scripts/dev.sh                snapshot prod, then serve on :5002
#   ./scripts/dev.sh --reuse        serve the snapshot from last time
#   ./scripts/dev.sh --sync         let the dev server sync (a real CIBC login,
#                                   against the copy and a separate profile)
#   ./scripts/dev.sh --port 5099    another port
#
# The snapshot lives in .dev/, which is gitignored: it holds real transactions.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
state="${CCTRACK_DEV_STATE:-$root/.dev}"
devdb="$state/cctrack.db"
port=5002
reuse=0
sync=0
snapshot_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --reuse) reuse=1 ;;
    --sync) sync=1 ;;
    --snapshot-only) snapshot_only=1 ;;
    --port) port="$2"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# LAN first, then the tailnet address luna sees for the box. Both are needed:
# at home the LAN route is instant, away from home only the tailnet one exists.
hosts=${CCTRACK_PROD_HOSTS:-ethernet@192.168.2.59 ethernet@100.95.51.7}

pull_snapshot() {
  mkdir -p "$state"
  local tmp="$devdb.part"
  rm -f "$tmp"

  for host in $hosts; do
    # The remote half writes to a temp dir and cats it back, so a failed
    # snapshot cannot leave a half-file behind locally.
    if ssh -F none -o BatchMode=yes -o ConnectTimeout=6 "$host" '
        set -e
        d=$(mktemp -d)
        trap "rm -rf $d" EXIT
        ~/.nix-profile/bin/cctrack snapshot "$d/cctrack.db" >/dev/null
        cat "$d/cctrack.db"
      ' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$devdb"
      echo "snapshot from $host -> $devdb"
      return 0
    fi
    echo "  $host unreachable or no snapshot, trying the next" >&2
  done

  rm -f "$tmp"
  echo "no production snapshot; run with --reuse if you already have one" >&2
  return 1
}

if [ "$reuse" -eq 0 ]; then
  pull_snapshot
fi

if [ "$snapshot_only" -eq 1 ]; then
  exit 0
fi

if [ ! -f "$devdb" ]; then
  echo "no snapshot at $devdb -- drop --reuse, or run once without it" >&2
  exit 1
fi

# Separate profile + downloads so a dev sync cannot fight production's browser
# session or scribble CSVs into the checkout. A fresh profile means CIBC asks
# for the 2FA code on the first dev sync -- that is the price of isolation.
export XDG_DATA_HOME="$state/data"
export CCTRACK_DOWNLOADS="$state/downloads"
export CCTRACK_PROFILE="$state/data/camoufox"
mkdir -p "$XDG_DATA_HOME" "$CCTRACK_DOWNLOADS" "$CCTRACK_PROFILE"

cd "$root"
echo
echo "dev server: http://127.0.0.1:$port  (db: $devdb)"
python -m cctrack.cli status --db "$devdb" || true
echo

if [ "$sync" -eq 1 ]; then
  # cage is a real compositor with no visible window; the browser has to be
  # headed because CIBC's edge drops headless ones.
  exec cage -- python -m cctrack.cli serve --db "$devdb" --port "$port" --auto-sync
fi

exec python -m cctrack.cli serve --db "$devdb" --port "$port"
