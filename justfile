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

# ── bellona (dahlia's box) ───────────────────────────────────────────────
# the box's SYSTEM config is dahlia's flake, checked out on the box at
# /home/shared/flake. my own user config reaches it as that flake's
# `ethie-dotfiles` input, so:
# change dotfiles here -> push -> `just bellona-update-input` -> `just deploy-fleet bellona`.

# bump the ethie-dotfiles pin on the box and push the lockfile commit
bellona-update-input:
  #!/usr/bin/env bash
  set -euo pipefail
  ssh bellona 'cd /home/shared/flake && git pull --ff-only && nix flake update ethie-dotfiles && git add flake.lock && git -c user.name=ethernet -c user.email=arilotter@gmail.com commit -m "pin: bump ethie-dotfiles" && git push'

# ── fleet ────────────────────────────────────────────────────────────────
# luna    nixos — built + switched right here (sudo prompts locally)
# hermes  nixos — closure built here, pushed w/ --target-host + remote sudo
# iris    darwin — can't cross-build; repo is git-pulled and built ON the mac
# bellona nixos — dahlia's flake; sync its checkout, rebuild in place
#
# any host with uncommitted dotfiles is SKIPPED (drift means the running
# system corresponds to nothing in git). unreachable hosts skip silently.
# every remote sudo asks over the tty, once per host.

# tell each host to apply its config. args = subset, e.g. `just deploy-fleet luna iris`
deploy-fleet *hosts:
  #!/usr/bin/env bash
  set -uo pipefail
  hosts="{{hosts}}"
  want=" $hosts "; [ -z "$hosts" ] && want=" luna hermes iris bellona "
  has() { [[ " $want " == *" $1 "* ]]; }
  dirty() { $1 git -C "$2" status --porcelain 2>/dev/null; }

  if has luna; then
    echo "── luna ──"
    if [ -n "$(dirty '' "$HOME/dotfiles")" ]; then
      echo "   dirty dotfiles -- commit first, skipping"
    else
      sudo nixos-rebuild switch --flake "$HOME/dotfiles#luna" -L
    fi
  fi

  if has hermes; then
    echo "── hermes ──"
    H="ssh -F none -o BatchMode=yes ethie@hermes.tail5b83ba.ts.net"
    if ! timeout 12 $H true 2>/dev/null; then
      echo "   unreachable, skipping"
    elif [ -n "$(dirty "$H" '$HOME/dotfiles')" ]; then
      echo "   dirty dotfiles -- commit first, skipping"
    else
      NIX_SSHOPTS="-F none -t" nixos-rebuild switch --flake "$HOME/dotfiles#hermes" \
        --target-host ethie@hermes.tail5b83ba.ts.net --use-remote-sudo -L
    fi
  fi

  if has iris; then
    echo "── iris ──"
    I="ssh -F none -o BatchMode=yes ethernet@iris.local"
    if ! timeout 12 $I true 2>/dev/null; then
      echo "   unreachable, skipping"
    elif [ -n "$(dirty "$I" '$HOME/dotfiles')" ]; then
      echo "   dirty dotfiles -- commit first, skipping"
    else
      # darwin: pull the repo there and build on the metal
      ssh -F none -t ethernet@iris.local 'cd $HOME/dotfiles && git pull --ff-only \
        && sudo /run/current-system/sw/bin/darwin-rebuild switch --flake .#iris' \
        || echo "   deploy failed (see above)"
    fi
  fi

  if has bellona; then
    echo "── bellona ──"
    B="ssh -F none -o BatchMode=yes ethernet@100.95.51.7"
    if ! timeout 12 $B true 2>/dev/null; then
      echo "   unreachable, skipping"
    elif [ -n "$(dirty "$B" '/home/shared/flake')" ]; then
      echo "   dahlia's checkout is dirty -- not touching it, skipping"
    else
      $B 'git -C /home/shared/flake pull --ff-only' || echo "   pull failed, building stale checkout"
      attr=$($B 'grep -oE "nixosConfigurations\.[A-Za-z0-9_-]+" /home/shared/flake/flake.nix | head -1 | cut -d. -f2')
      ssh -F none -t ethernet@100.95.51.7 "sudo nixos-rebuild switch --flake /home/shared/flake#${attr:-bellona} -L" \
        || echo "   deploy failed (see above)"
    fi
  fi

# where each host stands vs master: dirty tree, pinned commit, and (nixos
# hosts, evaluated from here) whether /run/current-system == what master
# builds. darwin/bellona generations are compared by eyeball -- different
# builders, no local closure to diff against.
status:
  #!/usr/bin/env bash
  set -uo pipefail
  expected() { # $1 = flake attr; prints store path or nothing
    nix build --no-link --print-out-paths ".#nixosConfigurations.$1.config.system.build.toplevel" 2>/dev/null | tail -1
  }
  hostline() { # $1 label, $2 ssh-prefix ('' local; word-split!), $3 dotfiles dir, $4 attr or ''
    echo "── $1 ──"
    if [ -n "$2" ] && ! timeout 12 $2 true 2>/dev/null; then
      echo "   unreachable"; return
    fi
    local d="$(dirty "$2" "$3")"
    [ -n "$d" ] && echo "   dirty dotfiles ($(echo "$d" | wc -l) paths)" || echo "   dotfiles clean"
    local head="$( $2 git -C "$3" rev-parse --short HEAD 2>/dev/null )"
    echo "   dotfiles @ ${head:-?} (origin/master: $(git -C "$HOME/dotfiles" rev-parse --short origin/master 2>/dev/null))"
    local gen="$( $2 readlink /run/current-system 2>/dev/null )"
    echo "   generation: ${gen:-none}"
    if [ -n "$4" ]; then
      local want="$(expected "$4")"
      if [ -n "$want" ]; then
        if [ "$(basename "$gen")" = "$(basename "$want")" ]; then
          echo "   == master build ✔"
        else
          echo "   != master build (want $(basename "$want"))"
        fi
      fi
    fi
  }
  dirty() { $1 git -C "$2" status --porcelain 2>/dev/null; }

  hostline luna    ""                                                              "$HOME/dotfiles" luna
  hostline hermes  "ssh -F none -o BatchMode=yes ethie@hermes.tail5b83ba.ts.net"   '$HOME/dotfiles' hermes
  hostline iris    "ssh -F none -o BatchMode=yes ethernet@iris.local"              '$HOME/dotfiles' ''
  hostline bellona "ssh -F none -o BatchMode=yes ethernet@100.95.51.7"             /home/shared/flake ''
  echo "(iris = darwin, bellona = dahlia's flake: no local closure to diff -- compare by eye)"
