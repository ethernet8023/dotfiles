_default:
  @just --list --unsorted

genflake:
  #!/usr/bin/env bash
  set -euo pipefail
  # `nix run .#genflake` is the documented way, but flakegen's app output
  # resolves to a fresh, unrealised store path on every eval on darwin --
  # you get "unable to execute .../genflake: No such file or directory" with a
  # different hash each run. the flakegen input itself is stable, so call the
  # script out of it directly and only fall back to the app if that fails.
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
