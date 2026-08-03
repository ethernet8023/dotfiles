{ lib, config, ... }:
{
  # who i am, per-host. one source of truth for the username/homedir/dotfiles
  # paths that used to be hardcoded (and then mkForce'd back) all over the place.
  #
  # shared by nixos and nix-darwin, so keep everything in here platform-neutral.
  options.me = {
    username = lib.mkOption {
      type = lib.types.str;
      default = "ethie";
      description = "login name of the primary human user.";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/home/${config.me.username}";
      example = "/Users/ethernet";
      description = ''
        home directory of the primary user. defaults to /home/<username>,
        which is right on luna; the older linux hosts still say /home/ari,
        and darwin needs /Users/<username>.
      '';
    };

    dotfiles = lib.mkOption {
      type = lib.types.str;
      default = "${config.me.homeDirectory}/dotfiles";
      description = "checkout of this repo, for `nh`'s default flake.";
    };

    sshKey = lib.mkOption {
      type = lib.types.str;
      default = "${config.me.homeDirectory}/.ssh/id_ed25519";
      description = "private key agenix decrypts secrets with.";
    };
  };
}
