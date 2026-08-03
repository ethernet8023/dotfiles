{
  pkgs,
  inputs,
  config,
  ...
}:
{
  imports = [ ../identity.nix ];

  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    config.allowUnfree = true;
  };

  # determinate ships its own daemon + nix.conf management. if nix-darwin also
  # tries to own them the two fight over /etc/nix/nix.conf on every activation.
  nix.enable = false;

  age = {
    identityPaths = [ config.me.sshKey ];
    secrets = {
      netrc.file = ../secrets/netrc.age;
    };
  };

  time.timeZone = "America/Toronto";

  users.users.${config.me.username} = {
    name = config.me.username;
    home = config.me.homeDirectory;
    shell = pkgs.fish;
  };

  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    wget
    git
    zip
    unzip
    fish
    bashInteractive
    nano
    nixfmt
    just
    nvd
    nh
    inputs.agenix.packages.${pkgs.system}.default
  ];

  # touch id for sudo, incl. after a reboot (sudo_local survives updates)
  security.pam.services.sudo_local.touchIdAuth = true;

  system = {
    primaryUser = config.me.username;

    defaults = {
      NSGlobalDomain = {
        # the whole point of a mac keyboard is the key repeat working
        InitialKeyRepeat = 15;
        KeyRepeat = 2;
        ApplePressAndHoldEnabled = false;
        AppleInterfaceStyle = "Dark";
        _HIHideMenuBar = false;
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        NSAutomaticQuoteSubstitutionEnabled = false;
        NSAutomaticDashSubstitutionEnabled = false;
        "com.apple.swipescrolldirection" = false; # no "natural" scrolling
      };

      dock = {
        autohide = true;
        show-recents = false;
        tilesize = 48;
        mru-spaces = false; # stop reordering my spaces
      };

      finder = {
        AppleShowAllExtensions = true;
        FXEnableExtensionChangeWarning = false;
        ShowPathbar = true;
        _FXShowPosixPathInTitle = true;
      };

      screencapture.location = "${config.me.homeDirectory}/Pictures/screenshots";

      # hold escape to... escape
      CustomUserPreferences = {
        "com.apple.symbolichotkeys" = { };
      };
    };

    # https://nixos.org/manual/nix-darwin -- bump only when the release notes say so
    stateVersion = 5;
  };
}
