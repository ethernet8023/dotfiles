{
  config,
  pkgs,
  ...
}:
let
  nvidiaProfile = builtins.readFile ./nvidia-wayland-fix.json;
in
{
  networking.hostName = "luna";

  # home is /home/ethie here, which is what identity.nix defaults to.

  # luna-only home config, layered over the shared graphical one.
  home-manager.users.ethie.imports = [ ../../home-manager/hosts/luna.nix ];

  # Keep the systemd user manager running when no session is logged in, so the
  # hermes-backend unit (hosts/luna.nix) survives logout and starts at boot.
  # home-manager cannot set this itself -- it needs `loginctl enable-linger`.
  users.users.${config.me.username}.linger = true;

  services.xserver = {
    videoDrivers = [ "nvidia" ];
    displayManager.importedVariables = [
      "XDG_SESSION_TYPE"
      "XDG_CURRENT_DESKTOP"
      "XDG_SESSION_DESKTOP"
    ];
  };
  powerManagement.cpuFreqGovernor = "performance";

  # both DP monitors are physically portrait (see home-manager/hyprland.nix,
  # transform 3). nothing before hyprland knows that, so the early-boot
  # surfaces need telling separately -- there is no single global knob:
  #
  #   systemd-boot menu -- impossible. it draws through UEFI GOP text output,
  #     which has no rotation concept. upstream RFE systemd#30120, still open.
  #   plymouth (splash + LUKS passphrase prompt) -- runs in the initrd on
  #     simpledrm, whose connector is named "Unknown-1" (simpledrm registers
  #     DRM_MODE_CONNECTOR_Unknown). its DRM renderer reads the "panel
  #     orientation" connector property, which video=...:panel_orientation
  #     forces. "right_side_up" makes plymouth rotate its image clockwise.
  #   text consoles / tuigreet -- fbcon, rotated by fbcon=rotate. 1 is
  #     clockwise, matching the plymouth direction above. it is global (fbcon
  #     cannot rotate per output), which is fine here since both monitors are
  #     turned the same way.
  #
  # if a surface comes out upside down, flip BOTH to the other direction
  # together: fbcon=rotate:3 with panel_orientation=left_side_up.
  #
  # panel_orientation is deliberately NOT set on DP-1/DP-2. once nvidia-drm
  # takes over fb0 it runs drm_client_rotation, which hardware-rotates the
  # plane when the driver can do the angle. that rotation would stack on top
  # of the fbcon software rotation and turn the console twice.
  boot.kernelParams = [
    "fbcon=rotate:1"
    "video=Unknown-1:panel_orientation=right_side_up"
  ];

  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    modesetting.enable = true;
    nvidiaSettings = true;
  };
  environment.etc."nvidia/nvidia-application-profiles-rc.d/wayland-fix.json".source =
    pkgs.writeTextFile
      {
        name = "nvidia-wayland-fix.json";
        text = nvidiaProfile;
      };

  virtualisation.docker = {
    daemon.settings.features.cdi = true;
    rootless.daemon.settings.features.cdi = true;
  };
  programs.steam.enable = true;

  programs.wireshark = {
    enable = true;
    package = pkgs.wireshark;
  };
  services.usbmuxd.enable = true;
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    openFirewall = true;
  };
  services.openssh.enable = true;
}
