# cctrack: CIBC statements + budget tracking on bellona

The source is `projects/cctrack` in this repo (it used to live only on hermes,
with no remote). It downloads transaction CSVs from CIBC, imports them into a
local sqlite database, and serves a review/reporting UI.

Production runs on bellona as **user** units under ethernet's account:

| unit | what it does |
| --- | --- |
| `beeper-profile-server` | Beeper Server, headless, managed by the `beeper` CLI (`beeper targets enable server`). CIBC texts the sign-on code to the phone; Beeper syncs it, and cctrack reads it from the client API on `127.0.0.1:23373`. |
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

2. **Bring up Beeper Server.** `beeper` (built from `nix/pkgs/beeper-cli.nix`)
   installs and supervises the headless runtime itself, and enables
   `beeper-profile-server.service` in `~/.config/systemd/user` -- home-manager
   does not declare that unit, `home-manager/hosts/bellona.nix` says why. The
   port is pinned to 23373 because that is what cctrack's client hardcodes:

       beeper targets add server server --port 23373 --default
       beeper setup --server --install --email <beeper account email>
       beeper targets stop server    # setup leaves its own process running
       beeper targets enable server  # systemd owns it from here on

   `setup` mails a code, asks for it, then starts device verification: approve
   it from a signed-in Beeper device (a phone or a laptop). No other device?
   `beeper verify recovery-key -t server --key "ABCD-EFGH-IJKL-MNOP"`. Check it
   answers with `curl -s 127.0.0.1:23373/ | head -c 100`.

   The Desktop profile in `~/.config/BeeperTexts` is not what the server uses
   (its data lives in `~/.beeper/profiles/server/server`), so it can go.

3. **Authorise cctrack's Beeper API client.** the bearer token in
   `~/.config/cctrack/beeper_token.json` is bound to the instance's dynamic
   client registration, so the Desktop one does not carry over: mint a new one
   against the server. Beeper Server serves its approval page on the box only,
   so tunnel both ports and run it there:

       ssh -L 23373:127.0.0.1:23373 -L 8765:127.0.0.1:8765 bellona
       ssh bellona 'cctrack beeper auth'   # open the printed URL locally

   the token is short-lived (`cctrack/secrets/beeper.py` says a day), so this is
   also the thing to rerun when a sync reports "token rejected".

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
