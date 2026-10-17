# nixos/bellona-ether.nix — everything ethernet, system-level, on bellona
# (dahlia's box; the machine's flake is github:ethernet8023/dollnet-dotfiles,
# evaluated as nixosConfigurations.bellona).
#
# dahlia's flake fresh start (2026-10) declares the machine and nothing else:
# no home-manager, no per-user config. this is the ONE module her nixosSystem
# imports to merge ethernet in:
#
#   ethie-dotfiles = github:ethernet8023/dotfiles;    # her inputs
#   ethie-dotfiles.nixosModules.bellona;              # her modules
#
# the wrapper (flake.in.nix) drags home-manager in from OUR pin and hands
# hermes-agent to the hm module from our lock too, so her flake stays two
# inputs light (nixpkgs + nixos-hardware).
#
# deliberately NOT resurrected here: the samba/avahi/minidlna/govee stack the
# old dollnet-infra module carried — the fresh start dropped it; re-add here
# if ethernet wants any of it back on this box.
{
  config,
  pkgs,
  ...
}:
let
  keys = import ../ssh-pubkeys.nix;
in
{
  users.users.ethernet = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;

    # hermes-agent / hermes-serve are systemd *user* units; they have to
    # survive logout, and home-manager cannot set this itself
    linger = true;

    # the mesh (see ssh-pubkeys.nix) — replaces the stale hand-copied list
    # this box used to carry
    openssh.authorizedKeys.keys = keys.mesh ++ [ keys.android ];
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-backup";

  # the whole user config: hermes gateway/backend, ssh client mesh, git, fish.
  # services.hermes-agent is declared by upstream's home-manager module — it
  # rides in via sharedModules (see the wrapper in flake.in.nix); a plain path
  # import here can't reach our flake inputs.
  home-manager.users.ethernet = import ../home-manager/hosts/dollnet.nix;
}
