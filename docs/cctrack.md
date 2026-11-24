# cctrack: CIBC statements + budget tracking on bellona

The source is `projects/cctrack` in this repo (it used to live only on hermes,
with no remote). It downloads transaction CSVs from CIBC, imports them into a
local sqlite database, and serves a review/reporting UI.

Production runs on bellona as two **user** units under ethernet's account:

| unit | what it does |
| --- | --- |
| `beeper` | Beeper Desktop, headless under `cage`. CIBC texts the sign-on code to the phone; Beeper syncs it, and cctrack reads it from Beeper's local API on `127.0.0.1:23373`. |
| `cctrack` | `cctrack serve --auto-sync --every 360` on `127.0.0.1:5001`, published at `budget.packet.dog` through caddy + authelia. |

Both run under `cage` with `WLR_BACKENDS=headless`: CIBC's Akamai edge drops
headless browsers during the h2 handshake, so the scraper has to be genuinely
headed, and Beeper is an Electron app that needs a display either way. User
units (not system services) because linger keeps them alive while logged out,
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

2. **Give Beeper a session.** Beeper Desktop's first-run sign-in is a GUI, and
   the box has no visible display. Copy the already-signed-in profile instead:

       rsync -a --exclude 'Cache*' --exclude 'GPUCache' --exclude 'Code Cache' \
         --exclude 'transcoded_cache' --exclude 'media' \
         hermes:'~/.config/BeeperTexts/' bellona:'~/.config/BeeperTexts/'

   Then `systemctl --user start beeper` and check it answers:
   `curl -s 127.0.0.1:23373/ | head -c 100`. If it asks to log in again, run
   `wayvnc` inside a `cage` session and connect from a laptop -- the profile
   copy usually avoids that.

3. **Authorise cctrack's Beeper API client.** cctrack keeps a bearer token in
   `~/.config/cctrack/beeper_token.json`; copy it from the machine that already
   authorised it. It is bound to the Beeper instance's dynamic client
   registration, which travels with the profile copy above, so the pair works
   together. If it does not, the OAuth flow opens a browser -- tunnel it:
   `ssh -L 23373:127.0.0.1:23373 -L 8765:127.0.0.1:8765 bellona` and run the
   `authorize()` helper on the box while opening the printed URL locally.

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
