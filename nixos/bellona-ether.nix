# nixos/bellona-ether.nix — everything ethernet, system-level, on bellona
# (dahlia's box; its machine flake is checked out at /home/shared/flake there
# and evaluated as nixosConfigurations.bellona).
#
# dahlia's flake declares the machine and nothing else: no home-manager, no
# per-user config. this is the ONE module her nixosSystem imports to merge
# ethernet in:
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

    # the mesh (see ssh-pubkeys.nix)
    openssh.authorizedKeys.keys = keys.mesh ++ [ keys.android ];
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-backup";

  # bellona-side half of the shared hermes gateway token: agenix decrypts
  # secrets/hermes-gateway-token.age with this box's key at hm activation, and
  # the backend (home-manager/hosts/bellona.nix) points sessionTokenFile at
  # the runtime path. luna/hermes/iris decrypt their copy for the desktop via
  # the nixos/darwin age modules instead.
  home-manager.users.ethernet = {
    imports = [ ../home-manager/hosts/bellona.nix ];
    # agenix's hm module declares `age` at the top level of the user config
    age = {
      identityPaths = [ "/home/ethernet/.ssh/id_ed25519" ];
      secrets.hermes-gateway-token = {
        file = ../secrets/hermes-gateway-token.age;
        # absolute path, NOT the module default "${XDG_RUNTIME_DIR}/agenix/...":
        # the module passes the path to the backend verbatim as
        # HERMES_DASHBOARD_SESSION_TOKEN=file:<path> (#146093/#146104, merged),
        # and a placeholder would pass through unexpanded and 401 the desktop.
        # pin /run/user/<uid>/agenix/<name>. uid 1001 = ethernet.
        path = "/run/user/1001/agenix/hermes-gateway-token";
      };
    };
  };
}
