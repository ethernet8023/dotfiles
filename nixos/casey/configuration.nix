{ pkgs, ... }:
{
  imports = [
    ./immich.nix
    ./home-assistant.nix
    ./qbittorrent.nix
    ./samba.nix
  ];

  # not yet migrated off the old homedir; everything under it is real.
  me.homeDirectory = "/home/ari";

  networking = {
    hostName = "casey";

    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # ssh
      ];
    };
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    openFirewall = true;
  };

  services.qbittorrent = {
    enable = true;
    openFirewall = true;
    dataDir = "/mnt/storage/torrents";
  };

  services.openssh.enable = true;

  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  hardware.graphics.extraPackages = [ pkgs.intel-media-driver ];
}
