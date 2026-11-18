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

  # macOS has no fstab-style cifs mounts worth using; mount_smbfs is the
  # supported path. bellona's smbd binds the LAN + loopback only (deliberate:
  # SMB stays off the internet), so away from the house the shares come in
  # over an ssh tunnel to bellona's localhost:445 rather than the LAN address.
  # /Volumes is root-owned, so the mounts live under ~/Volumes where a user
  # agent can create the mountpoints; the agent re-runs every 10 min so a
  # tunnel that died with sleep/lid gets re-established.
  launchd.user.agents.bellona-smb = {
    serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          PW=$(/usr/bin/sed -n 's/^password=//p' /run/agenix/bellona-smb)
          /usr/bin/printf '[192.168.2.59]\nusername=ethernet\npassword=%s\n' "$PW" > "$HOME/.nsmbrc"
          /bin/chmod 600 "$HOME/.nsmbrc"
          /bin/mkdir -p "$HOME/Volumes/bellona-music" "$HOME/Volumes/bellona-rekordbox" "$HOME/Volumes/bellona-vault"
          SRV=127.0.0.1:4445
          if /usr/bin/nc -z -G2 -w2 192.168.2.59 445; then
            SRV=192.168.2.59
          else
            /usr/bin/pgrep -f "ssh -f -N -L 4445:127.0.0.1:445" >/dev/null \
              || /usr/bin/ssh -f -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
                   -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
                   -L 4445:127.0.0.1:445 ethernet@100.95.51.7
            /usr/bin/nc -z -G3 -w3 127.0.0.1 4445 || exit 0
          fi
          for s in music rekordbox vault; do
            /sbin/mount | /usr/bin/grep -q "on $HOME/Volumes/bellona-$s" && continue
            /sbin/mount_smbfs "//ethernet:$PW@$SRV/$s" "$HOME/Volumes/bellona-$s"
          done
        ''
      ];
      RunAtLoad = true;
      KeepAlive = false;
      StartInterval = 600;
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
