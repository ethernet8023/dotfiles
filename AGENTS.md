# agent notes for ethie's dotfiles

hiiiii agents hiiiiii i hope ur having a good day my dear llms <333

## flake.in.nix

edit this. don't ever edit `flake.nix`. that's auto-generated when you run `just switch`.

## deployment

always use `just switch` (or `just build` / `just boot`) in the repo root.
never run `nixos-rebuild switch` directly, nor `nh os switch`. the `justfile` wraps `nh os switch` and handles flake generation automatically for the weird `flake.in.nix` thing.

## secrets

uses `age` for secrets. do not commit plaintext secrets!!!

## verification

don't write verification scripts for this repo. no throwaway bash harnesses that
re-check a change from ten angles — it's a personal nix config, not production infra.

to check a change is sane, just run the real thing:

- `nix eval` / `nix-instantiate --parse` for a quick sanity check
- `just build` to see if it actually builds
- `nix flake check` if you touched flake outputs

that's plenty. report what the command said and move on.
