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
      hermes-gateway-token.file = ../secrets/hermes-gateway-token.age;
      # the user must be able to read this one: the launchd agent builds
      # ~/.nsmbrc from it and mount_smbfs uses that.
      bellona-smb = {
        file = ../secrets/bellona-smb.age;
        owner = config.me.username;
        mode = "0400";
      };
    };
  };

  # macOS has no fstab-style cifs mounts worth using; mount_smbfs + ~/.nsmbrc
  # is the supported path. the agent writes the credential file and mounts the
  # shares at login, and is a no-op if they are already mounted.
  launchd.user.agents.bellona-smb = {
    serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          { echo "[192.168.2.59]"; cat /run/agenix/bellona-smb; } > "$HOME/.nsmbrc"
          chmod 600 "$HOME/.nsmbrc"
          /bin/mkdir -p /Volumes/bellona-music /Volumes/bellona-vault
          /sbin/mount | /usr/bin/grep -q "on /Volumes/bellona-music" \
            || /sbin/mount_smbfs //ethernet@192.168.2.59/music /Volumes/bellona-music
          /sbin/mount | /usr/bin/grep -q "on /Volumes/bellona-vault" \
            || /sbin/mount_smbfs //ethernet@192.168.2.59/vault /Volumes/bellona-vault
        ''
      ];
      RunAtLoad = true;
      KeepAlive = false;
    };
  };

  time.timeZone = "America/Toronto";

  users.users.${config.me.username} = {
    name = config.me.username;
    home = config.me.homeDirectory;
    shell = pkgs.fish;
  };

  programs.fish.enable = true;

  # macos won't accept a login shell that isn't in /etc/shells, so
  # users.users.<n>.shell silently stays zsh without this.
  environment.shells = [ pkgs.fish ];

  # nix-darwin's manual doesn't build against nixpkgs master: it passes
  # --sidebar-depth, which nixos-render-docs has dropped. doc.enable is what
  # pulls in darwin-manual-html, and it's independent of documentation.enable.
  # man pages still work.
  documentation = {
    enable = false;
    doc.enable = false;
  };

  # darwin-uninstaller is its own nix-darwin evaluation with default options,
  # so our documentation settings don't reach it and it drags the broken
  # darwin-manual-html back in. determinate ships its own uninstaller anyway.
  system.tools.darwin-uninstaller.enable = false;

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
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
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
