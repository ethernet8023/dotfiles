{
  config,
  lib,
  pkgs,
  ...
}:
let
  nvidiaProfile = builtins.readFile ./nvidia-wayland-fix.json;
in
{
  networking.hostName = "luna";

  # luna-only: home lives at /home/ethie, not the shared /home/ari.
  # other hosts (hermes/sol/casey) still use /home/ari until migrated.
  users.users.ethie.home = lib.mkForce "/home/ethie";
  home-manager.users.ethie.home.homeDirectory = lib.mkForce "/home/ethie";
  age.identityPaths = lib.mkForce [ "/home/ethie/.ssh/id_ed25519" ];
  programs.nh.flake = lib.mkForce "/home/ethie/dotfiles";

  services.xserver = {
    videoDrivers = [ "nvidia" ];
    displayManager.importedVariables = [
      "XDG_SESSION_TYPE"
      "XDG_CURRENT_DESKTOP"
      "XDG_SESSION_DESKTOP"
    ];
  };
  powerManagement.cpuFreqGovernor = "performance";
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

  hardware.nvidia-container-toolkit.enable = true;
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
