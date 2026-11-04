# Fleet management: what is worth adopting

Researched against how people actually run multi-host NixOS fleets in 2026,
including isabelroses' dotfiles (easy-hosts + lethe + `nh`/`nom`).

## What exists

| tool | what it does | fit here |
|---|---|---|
| `deploy-rs` | flake deploy profiles, magic rollback, per-profile activation | good for luna/hermes; risky for bellona (rollback needs a reachable host and root) |
| `colmena` | parallel multi-host deploy, root SSH, build-on-target options | good once there are several identical servers; overkill for four hosts |
| `nixos-anywhere` | install NixOS over SSH (partition, kexec) | one-time installs / reinstalls, not day-to-day |
| `nixinate` | generates a `deploy` app per host | small, no daemon, but no rollback |
| `easy-hosts` | declarative host inventory for flake-parts | restructures the flake; nice if host count grows |
| `lethe` | records each deployment's closure in SQLite, diffs deployments | **adopt**: answers "what changed when it broke" without a rebuild |
| `nh` / `nom` | build UX (nix-output-monitor, nh os switch) | already useful; `nh` is on iris |

isabelroses' setup is: `just deploy <host>` -> `nixos-rebuild --target-host
--use-substitutes` -> `lethe record <host>` -> `lethe diff <host>`, plus
`easy-hosts` for the inventory. The interesting part is not the deploy command,
it is the **deployment ledger**: every switch leaves a closure snapshot you can
diff later.

## Recommendation

1. Keep the existing `just deploy-fleet` / `just status`. It already encodes the
   real constraints: dirty-tree skip, bellona's dirty checkout, darwin builds on
   the mac, bellona's sudo password.
2. Add `lethe` as the ledger. Record after every successful deploy and diff when
   something regresses. Recipes are in the justfile (`just record <host>`,
   `just diff <host>`); it runs from the flake, no new input.
3. Do not move to `deploy-rs` for bellona: magic rollback wants to reconnect and
   activate as root, and bellona's sudo is interactive. `deploy-rs` is fine for
   luna/hermes later if the justfile gets unwieldy.
4. Do not restructure to `easy-hosts` yet. Four hosts and a foreign flake do not
   justify it; revisit when there is a rack of identical machines.
5. For phobos/deimos (DGX OS, not Nix): they are outside the flake. Run pinned
   binaries (node_exporter, a vLLM metrics scrape) as systemd units, or add them
   to the tailnet and let VictoriaMetrics scrape them. `nixos-anywhere` is the
   escape hatch if you ever want them declarative.
