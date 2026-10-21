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

  # bellona-side half of the shared hermes gateway token: agenix decrypts
  # secrets/hermes-gateway-token.age with this box's key at hm activation, and
  # the backend (home-manager/hosts/dollnet.nix) points sessionTokenFile at
  # the runtime path. luna/hermes/iris decrypt their copy for the desktop via
  # the nixos/darwin age modules instead.
  home-manager.users.ethernet = {
    imports = [ ../home-manager/hosts/dollnet.nix ];
    # agenix's hm module declares `age` at the top level of the user config
    age = {
      identityPaths = [ "/home/ethernet/.ssh/id_ed25519" ];
      secrets.hermes-gateway-token.file = ../secrets/hermes-gateway-token.age;
    };
  };
}
