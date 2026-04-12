_default:
  @just --list --unsorted

genflake:
  nix run .#genflake flake.nix
  
build *args: genflake
  nh os build . {{args}}
  nvd diff /run/current-system ./result

switch *args: genflake
  nh os switch . {{args}}

boot *args: genflake
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