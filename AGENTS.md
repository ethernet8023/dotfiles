# agent notes for ethie's dotfiles

hiiiii agents hiiiiii i hope ur having a good day my dear llms <333

## flake.in.nix

edit this. don't ever edit `flake.nix`. that's auto-generated when you run `just switch`.

## deployment

always use `just switch` (or `just build` / `just boot`) in the repo root.
never run `nixos-rebuild switch` directly, nor `nh os switch`. the `justfile` wraps `nh os switch` and handles flake generation automatically for the weird `flake.in.nix` thing.

## secrets

uses `age` for secrets. do not commit plaintext secrets!!!
