# cctrack: CIBC statements + budget tracking on bellona

The source is `projects/cctrack` in this repo (it used to live only on hermes,
with no remote). It downloads transaction CSVs from CIBC, imports them into a
local sqlite database, and serves a review/reporting UI.

Production runs on bellona as **user** units under ethernet's account:

| unit | what it does |
| --- | --- |
| `beeper-server` | Beeper Server, headless (nix/pkgs/beeper-server.nix). CIBC texts the sign-on code to the phone; Beeper syncs it, and cctrack reads it from the client API on `127.0.0.1:23373`. |
| `cctrack` | `cctrack serve --auto-sync --every 360` on `127.0.0.1:5001`, published at `budget.packet.dog` through caddy + authelia. |

`cctrack` runs under `cage` with `WLR_BACKENDS=headless`: CIBC's Akamai edge
drops headless browsers during the h2 handshake, so the scraper has to be
genuinely headed. Beeper used to run the same way, as Desktop under cage;
Beeper Server is headless on its own, so it just runs as itself. User units
(not system services) because linger keeps them alive while logged out,
everything they write is mine, and root on that box is dahlia's.

## Why the package is a nix build

`nix/pkgs/cctrack.nix` seals the venv from `projects/cctrack/uv.lock` with
uv2nix and takes the browser from `camoufox-nix`'s prebuilt package. The
alternative -- `uv pip install` at boot and `python -m camoufox fetch` -- means
prod silently drifts from what the tests ran against, and drops an unpinned
~130MB Firefox build in `~/.cache`. camoufox 0.5 reads
`CAMOUFOX_EXECUTABLE_PATH`, so the wrapper points it at the store browser and
it never downloads one.

The nested flake that used to live in `projects/cctrack` is gone: `nix develop`
from that directory now walks up to this repo's flake and gives the same sealed
env via `.#cctrack`.

Two library fixes live in that derivation, both from the store being read-only:

- playwright ships its own node to run its driver, and that prebuilt binary
  segfaults on NixOS ("Connection closed while reading from the driver"). The
  derivation swaps it for nixpkgs' node; the python package stays at the version
  the lock pins, which is the pair camoufox was built against.
- camoufox installs fpgen's fingerprint model into fpgen's site-packages at first
  launch, and decides the model is stale by mtime -- but nix normalises store
  mtimes to 1970, so both the install and the refresh hit EROFS. The model
  archive is fetched and unpacked at build time instead (same url and sha256 as
  `camoufox/fpgen-model.json`), and the two mtime checks are neutralised.

Both are verified by launching the browser headed under `cage`; if a future
camoufox or playwright bump breaks one, the symptom is a sync that dies before
CIBC's sign-on page loads.

## Secrets

`secrets/cctrack-cibc.age` holds the CIBC sign-on as

    username=<card number>
    password=<password>

read through `CCTRACK_LOGIN_FILE` (`cctrack/secrets/credentials.py`). A file
rather than the Bitwarden CLI because a systemd unit has no vault to unlock;
agenix decrypts it to a runtime path, so the password never enters the store,
the process argv (`/proc/<pid>/cmdline` is world-readable), or a log line.

Re-encrypt after changing it:

    EDITOR=nano nix shell nixpkgs#agenix -c agenix -e secrets/cctrack-cibc.age

## First run on the box (one human pass)

1. **Migrate the data.** From the machine that holds it (hermes):

       ssh bellona 'mkdir -p ~/.local/share/cctrack/downloads'
       ssh hermes 'cd ~/src/credit-card-tracker && .venv/bin/cctrack snapshot /tmp/cctrack.db'
       rsync -a hermes:/tmp/cctrack.db bellona:~/.local/share/cctrack/cctrack.db
       rsync -a hermes:~/.local/share/cctrack/camoufox/ bellona:~/.local/share/cctrack/camoufox/

   The `camoufox/` profile is what carries CIBC's trusted-device marker: with it,
   routine syncs skip 2FA and often the password screen. Losing it means a code
   every time.

2. **Sign the server in.** `beeper-server.service` comes from home-manager and
   is already running after the switch -- the runtime is a nix build
   (`nix/pkgs/beeper-server.nix`), because the CLI's own download is a
   generic-linux binary that NixOS's stub-ld cannot exec. So nothing here
   installs or starts anything. The target is pinned to 23373 because that is
   what cctrack's client hardcodes, and the unit's data dir is that target's
   profile dir:

       beeper targets add server server --port 23373 --default

   the sign-in itself is curl, not `beeper auth email`: the 0.6.4 release
   binary bundles a desktop-api SDK that predates `/v1/app/setup`, so
   `beeper auth email start` dies with "undefined is not an object (evaluating
   'client.app.login.start')" even though the source on main has the command.
   those endpoints are public before sign-in, so:

       B=http://127.0.0.1:23373
       ID=$(curl -s -X POST $B/v1/app/setup/start \
              -H 'authorization: Bearer setup-login-public-client' | jq -r .setupRequestID)
       curl -s -X POST $B/v1/app/setup/email -H 'authorization: Bearer setup-login-public-client' \
              -H 'content-type: application/json' \
              -d "{\"setupRequestID\":\"$ID\",\"email\":\"<beeper account email>\"}"
       curl -s -X POST $B/v1/app/setup/response -H 'authorization: Bearer setup-login-public-client' \
              -H 'content-type: application/json' \
              -d "{\"setupRequestID\":\"$ID\",\"response\":\"<code from the email>\"}" > /tmp/beeper-login.json

   hand the CLI that token, or its commands sit at "auth required":

       jq --arg t "$(jq -r .matrix.accessToken /tmp/beeper-login.json)" \
          '.auth = {accessToken: $t, tokenType: "Bearer", source: "manual"}' \
          ~/.beeper/targets/server.json > /tmp/t.json && mv /tmp/t.json ~/.beeper/targets/server.json

   verification is `beeper verify` -- that path is raw HTTP and does work:
   approve the prompt on a signed-in phone, or `beeper verify recovery-key
   -t server --key "ABCD-EFGH-IJKL-MNOP"`. `curl -s $B/v1/app/setup | jq .state`
   reads `ready` when it is done, and `beeper accounts list` shows the bridges.

   The Desktop profile in `~/.config/BeeperTexts` is not what the server uses
   (its data lives in `~/.beeper/profiles/server/server`), so it can go.

3. **Give cctrack a token.** cctrack reads a bearer token from
   `~/.config/cctrack/beeper_token.json`. Its own OAuth dance works, but the
   code exchange 400s against Beeper Server, and the token it mints is
   short-lived (`cctrack/secrets/beeper.py` says a day). The CLI's matrix token
   from step 2 reads the same API and does not expire, so hand cctrack that:

       TOK=$(jq -r .auth.accessToken ~/.beeper/targets/server.json)
       mkdir -p ~/.config/cctrack
       jq -n --arg t "$TOK" '{client_id: "beeper-cli", access_token: $t, token_type: "Bearer"}' \
         > ~/.config/cctrack/beeper_token.json
       chmod 600 ~/.config/cctrack/beeper_token.json
       systemctl --user restart cctrack

   proof it can read the CIBC texts:

       curl -s -H "authorization: Bearer $TOK" \
         "127.0.0.1:23373/v1/messages/search?query=CIBC&limit=2" | jq '.items[].text'

   if you ever do need a fresh one from cctrack itself, `cctrack beeper auth`
   prints an approval URL on the box -- tunnel 23373 and 8765 to reach it.

4. `systemctl --user start cctrack`, then `journalctl --user -u cctrack -f`
   while it does its first sync. The first sync after migration is a normal
   incremental one: the database already holds history to 2026-07-30.

## Dev loop

Production data is not edited in place. `scripts/dev.sh` pulls a snapshot with
`cctrack snapshot`, which uses sqlite's backup API -- safe while the server has
the file open -- and serves *that* on `:5002` with auto-sync off:

    just cctrack-dev              # snapshot prod, then serve on :5002
    just cctrack-dev --reuse      # serve the snapshot from last time
    just cctrack-dev --sync       # allow a real CIBC login against the copy
    just cctrack-test             # the suite, in the sealed env

The copy lives in `projects/cctrack/.dev/` (gitignored -- real transactions). A
dev sync uses its own browser profile and download dir, so it cannot invalidate
production's CIBC session.

## Deploy

Change under `projects/cctrack` -> commit -> push master -> on the box:
`just bellona-update-input` then `just deploy-fleet bellona`, or hand her
`nh os switch /home/shared/flake` + the root password. The flake input pin is
what decides which rev runs; `nix eval .#packages.x86_64-linux.cctrack.drvPath`
before pushing shows what will be built.

## Gotchas

- **`downloads_dir()` and `.sesskey` default to paths next to the package.** In
  the store that is read-only, so the unit sets `CCTRACK_DOWNLOADS` and a
  `WorkingDirectory` under `~/.local/share/cctrack`.
- **The scheduler's backoff is the retry policy.** Four consecutive failures
  stop it rather than retrying forever, because repeated bank logins are what
  lock an account. `Restart=on-failure` only covers a crashed process.
- **A locked vault is not a failure** on a laptop dev run; the scheduler pauses
  and reports once. On bellona there is no vault, so that path is unreachable.
- **2FA only needs Beeper when CIBC asks.** With the trusted-device profile,
  most runs never touch it, so a Beeper crash is not an outage.
