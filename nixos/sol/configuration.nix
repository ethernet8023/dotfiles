{ pkgs, ... }:
{
  imports = [
    ./samba.nix
    ./navidrome.nix
    ./digitalocean-dynamic-dns.nix # todo make it work...
    ./slskd.nix
    ./home-assistant.nix
    ./immich.nix
    # TODO pihole
    # TODO vaultwarden
  ];

  # not yet migrated off the old homedir; everything under it is real.
  me = (import ../../hosts.nix).sol;

  security.acme = {
    acceptTerms = true;
    defaults.email = "arilotter@gmail.com";
  };

  networking = {
    hostName = "sol";

    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # ssh
        80 # http
        443 # https
        139 # netbios
        5030 # slskd
        7777
      ];
      allowedUDPPorts = [
        137
        138
        139 # netbios
        7777 # game server
      ];
    };
  };

  environment.systemPackages = [
    pkgs.steamcmd
  ];

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    openFirewall = true;
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
