{
  pkgs,
  lib,
  inputs,
  config,
  ...
}:
{
  imports = [ ../identity.nix ];

  nixpkgs = {
    overlays = [
      inputs.nur.overlays.default
      inputs.vscode-ext.overlays.default
    ];
    config.allowUnfree = true;
  };

  nix = {
    settings = {
      trusted-users = [
        "root"
        "@wheel"
      ];
      experimental-features = "nix-command flakes";
      auto-optimise-store = true;

      substituters = [
        "https://cache.nixos.org/"
        "https://nix-community.cachix.org"
        "https://cache.nixos-cuda.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];

      # see https://garnix.io/docs/caching#private-caches
      netrc-file = config.age.secrets.netrc.path;

      # The narinfo-cache-positive-ttl setting by default is very high (30 days).
      # It has to be lowered, since garnix uses presigned urls for private store paths that expire much quicker.
      # It should be set to 3600 (i.e. 1 hour).
      narinfo-cache-positive-ttl = 3600;
    };
  };

  age = {
    identityPaths = [ config.me.sshKey ];
    secrets = {
      ethie-passwd.file = ../secrets/ethie-passwd.age;
      sol-smbpasswd.file = ../secrets/sol-smbpasswd.age;
      netrc.file = ../secrets/netrc.age;
    };
  };

  boot = {
    # disable modules that conflict w/ smart card reader.
    blacklistedKernelModules = [
      "nfc"
      "pn533"
      "pn533_usb"
    ];
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    supportedFilesystems = [ "ntfs" ];
    binfmt.emulatedSystems = lib.lists.remove pkgs.stdenv.hostPlatform.system [
      "aarch64-linux"
      "x86_64-linux"
    ];
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = "1048576";
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";

    # home.nix is shared with darwin, so it can't hardcode either of these.
    users.${config.me.username} = {
      home.username = config.me.username;
      home.homeDirectory = config.me.homeDirectory;
    };
  };

  time.timeZone = "America/Toronto";

  i18n.defaultLocale = "en_US.UTF-8";

  security.polkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    socketActivation = true;
    wireplumber.enable = true;
  };

  services.pulseaudio.package = pkgs.pulseaudioFull;
  hardware.enableRedistributableFirmware = true;
  hardware.ledger.enable = true;

  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      zlib
      zstd
      stdenv.cc.cc
      curl
      openssl
      attr
      libssh
      bzip2
      libxml2
      acl
      libsodium
      util-linux
      xz
      systemd

      # electron, jesus
      glib
      nspr
      nss
      dbus
      atk
      cups
      cairo
      gtk3
      pango
      libx11
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      libgbm
      expat
      libxcb
      libxkbcommon
      alsa-lib
    ];
  };
  programs.fish.enable = true;
  programs.dconf.enable = true;
  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep-since 4d --keep 3";
    flake = config.me.dotfiles;
  };

  users = {
    mutableUsers = false;
    users.${config.me.username} = {
      isNormalUser = true;
      home = config.me.homeDirectory;
      description = "ethernet";
      uid = 1000;
      extraGroups = [
        "wheel"
        "sudoers"
        "networkmanager"
        "adbusers"
        "audio"
        "docker"
        "dialout"
        "video"
        "wireshark"
        "adbusers"
        "vboxusers"
      ];
      shell = pkgs.fish;
      hashedPasswordFile = config.age.secrets.ethie-passwd.path;
      openssh.authorizedKeys.keys =
        let
          keys = (import ../ssh-pubkeys.nix);
        in
        with keys;
        [
          luna
          hermes
          android
          nous-eng
        ];
    };
  };

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
    steam-run
    inputs.agenix.packages.${pkgs.system}.default
    clinfo
    nh
  ];

  services = {

    gnome.gnome-keyring.enable = true;

    avahi = {
      enable = true;
      nssmdns4 = true;
      ipv4 = true;
      ipv6 = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
        userServices = true;
        hinfo = true;
        domain = true;
      };
    };
    udev.extraRules = ''
      # udev rules for ACS CCID devices - NFC card reader.

      # If not adding the device, go away
      ACTION!="add", GOTO="pcscd_acsccid_rules_end"
      SUBSYSTEM!="usb", GOTO="pcscd_acsccid_rules_end"
      ENV{DEVTYPE}!="usb_device", GOTO="pcscd_acsccid_rules_end"

      # set USB power management to auto.
      ENV{ID_USB_INTERFACES}==":0b0000:", TEST=="power/control", ATTR{power/control}="auto"

      # All done
      LABEL="pcscd_acsccid_rules_end"
    '';
  };

  security.wrappers."mount.cifs" = {
    program = "mount.cifs";
    source = "${lib.getBin pkgs.cifs-utils}/bin/mount.cifs";
    owner = "root";
    group = "root";
    setuid = true;
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.05";
}
