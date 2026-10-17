_default:
  @just --list --unsorted

genflake:
  #!/usr/bin/env bash
  set -euo pipefail
  # `nix run .#genflake` is flakegen's documented entry point, but it breaks
  # under determinate nix, which defaults lazy-trees=true: flakegen's app is
  # `program = toPath ./genflake`, and with lazy-trees that freezes a *virtual*
  # store path (nix path-info: "is not valid") into the output, so nix run
  # exec()s a path that was never materialised -- a different hash every eval.
  # inputs.flakegen.outPath is realised and stable, so go through that.
  fg=$(nix eval --accept-flake-config --raw --impure \
        --expr "(builtins.getFlake (toString ./.)).inputs.flakegen.outPath" 2>/dev/null || true)
  if [ -n "$fg" ] && [ -x "$fg/genflake" ]; then
    "$fg/genflake" flake.nix
  else
    nix run .#genflake flake.nix
  fi

# nh wants `os` on nixos and `darwin` on macos
_nh := if os() == "macos" { "darwin" } else { "os" }

build *args: genflake
  nh {{_nh}} build . {{args}}
  nvd diff /run/current-system ./result

switch *args: genflake
  nh {{_nh}} switch . {{args}}

boot *args: genflake
  #!/usr/bin/env bash
  if [ "$(uname)" = "Darwin" ]; then
    echo "no 'boot' on darwin -- nh darwin only has switch/build. use 'just switch'." >&2
    exit 1
  fi
  nh os boot . {{args}}

update:
  nix flake update

check:
  nix flake check

clean:
  sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations old
  sudo nix-collect-garbage --delete-older-than 3d

fmt:
  nix fmt .

# ── dollnet (dahlia's box; see ~/dotfiles-dollnet) ─────────────────────
# the box's SYSTEM config lives in the ~/dotfiles-dollnet clone of
# ethernet8023/dollnet-dotfiles, checked out on the box at /home/shared/flake.
# my own user config reaches it as that flake's `ethie-dotfiles` input, so:
# change dotfiles here -> push -> `just dollnet-update-input` -> `just dollnet-switch`.

# bump the ethie-dotfiles pin on the box and push the lockfile commit
dollnet-update-input:
  #!/usr/bin/env bash
  set -euo pipefail
  ssh ethernet@dollnet 'cd /home/shared/flake && git pull --ff-only && nix flake update ethie-dotfiles && git add flake.lock && git -c user.name=ethernet -c user.email=arilotter@gmail.com commit -m "pin: bump ethie-dotfiles" && git push'

# deploy: sync both checkouts, build the closure here, switch it there.
# asks for the box's sudo password once (over the tty NIX_SSHOPTS=-t allocates).
dollnet-switch *args:
  #!/usr/bin/env bash
  set -euo pipefail
  git -C "$HOME/dotfiles-dollnet" pull --ff-only
  ssh ethernet@dollnet 'git -C /home/shared/flake pull --ff-only' \
    || echo "!! box checkout dirty; skipped pull -- reconcile /home/shared/flake by hand"
  NIX_SSHOPTS=-t nixos-rebuild switch --flake "$HOME/dotfiles-dollnet#dollnet" --use-remote-sudo -L {{args}}
