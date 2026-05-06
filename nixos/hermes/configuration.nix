{
  inputs,
  pkgs,
  ...
}:
{
  networking.hostName = "hermes";

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelParams = [ "ec_sys.write_support=1" ];
  };

  networking.firewall.allowedTCPPorts = [
    29811
    29812
    29813
    29814
    29815
    29816
  ];
  networking.firewall.allowedUDPPorts = [
    19810
    29810
  ];
  # UDP 19810, UDP 29810, TCP 29811, TCP 29812, TCP 29813, TCP 29814, TCP 29815, and TCP 29816 are required for device management, make sure that these ports are open in your firewall.
  # environment.systemPackages = [ inputs.fw-inputmodule.packages.${pkgs.system}.default ];
  programs.steam.enable = true;

  services = {
    libinput.enable = true;

    xserver = {
      videoDrivers = [ "amdgpu" ];
    };

    tailscale = {
      enable = true;
      useRoutingFeatures = "both";
      openFirewall = true;
    };
  };

  services.openssh.enable = true;
}
