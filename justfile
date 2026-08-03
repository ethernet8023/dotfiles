_default:
  @just --list --unsorted

genflake:
  nix run .#genflake flake.nix

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
