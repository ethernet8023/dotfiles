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
