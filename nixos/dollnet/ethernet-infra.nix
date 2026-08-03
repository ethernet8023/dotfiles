# nixos/dollnet/ethernet-infra.nix — sol's infrastructure, ported to dollnet.
#
# this is a single self-contained NixOS module so dahlia can review/remove it
# without touching anything else in her config. dollnet's flake imports it via
# ethie-dotfiles nixosModules.dollnet-infra.
#
# what's ported from sol:
#   home-assistant (w/ govee BLE custom component)
#   immich (server + ML + redis + postgres)
#   navidrome
#   minidlna
#   samba (+ wsdd + avahi)
#   slskd
#   caddy (reverse proxy)
#   omada controller (docker)
#   digitalocean DDNS (home.ari.computer)
#
# what's NOT ported:
#   fido2-hid-bridge — sol-specific USB hardware.
#
# data is NOT ported. /mnt/storage dirs are created empty via tmpfiles.
#
# secrets (agenix, in our repo):
#   secrets/digitalocean-token.age — DigitalOcean API token for DDNS
#     (write access to ari.computer domain DNS records)
#
# other secrets (plaintext files the user creates):
#   /home/ethernet/slskd.env — soulseek credentials

{
  pkgs,
  config,
  lib,
  ...
}:

let
  ddns = pkgs.writeShellScriptBin "ddns" (builtins.readFile ./ddns.sh);
in
{
  # ── /mnt/storage directory tree ──────────────────────────────────────────
  # sol has an 8TB exfat disk at /mnt/storage. dollnet has no external disk,
  # so these live on the root btrfs (1.8TB free). swap for a real mountpoint
  # if you add a disk later.
  systemd.tmpfiles.rules = [
    "d /mnt/storage 0755 ethernet users -"
    "d /mnt/storage/immich 0755 ethernet users -"
    "d /mnt/storage/music 0755 ethernet users -"
    "d /mnt/storage/music-sorted 0755 ethernet users -"
    "d /mnt/storage/music-new-downloads 0755 ethernet users -"
    "d /mnt/storage/enemy 0755 ethernet users -"
    "d /mnt/storage/public 0755 ethernet users -"
  ];

  # ── ACME ─────────────────────────────────────────────────────────────────
  security.acme = {
    acceptTerms = true;
    defaults.email = "arilotter@gmail.com";
  };

  # ── Docker (for omada controller) ─────────────────────────────────────────
  # already enabled via hermes-agent container mode, but be explicit.
  virtualisation.docker.enable = true;

  # ── no sleep ──────────────────────────────────────────────────────────────
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # ── Firewall ──────────────────────────────────────────────────────────────
  # merges with dahlia's existing rules (22, 2302 for arma3).
  networking.firewall = {
    allowedTCPPorts = [
      80 # http (caddy)
      443 # https (caddy)
      139 # netbios
      5030 # slskd
      config.services.slskd.settings.web.port # slskd web
      7777 # game server (ported from sol)
      8043 29814 29815 29816 29813 28911 28912 27217 8088 8843
    ];
    allowedUDPPorts = [
      29810
      27001
      137
      138
      139 # netbios
      7777 # game server
    ];
  };

  # ── Home Assistant ────────────────────────────────────────────────────────
  services.home-assistant = {
    enable = true;
    openFirewall = true;
    extraComponents = [
      "esphome"
      "met"
      "radio_browser"
      "hue"
      "roku"
      "cast"
      "govee_ble"
      "govee_light_local"
    ];
    customComponents = [ ];
    config = {
      default_config = { };
    };
  };

  # bluetooth for govee BLE lights. needs a bluetooth adapter on this box.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # ── Immich ───────────────────────────────────────────────────────────────
  services.immich = {
    enable = true;
    port = 2283;
    openFirewall = true;
    host = "0.0.0.0";
    mediaLocation = "/mnt/storage/immich";
  };
  users.users.immich.extraGroups = [
    "video"
    "render"
  ];

  # ── Navidrome ────────────────────────────────────────────────────────────
  services.navidrome = {
    enable = true;
    openFirewall = true;
    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      MusicFolder = "/mnt/storage/music-sorted";
    };
  };

  # ── MiniDLNA ─────────────────────────────────────────────────────────────
  services.minidlna = {
    enable = true;
    openFirewall = true;
    settings = {
      notify_interval = 30;
      friendly_name = "dollnet";
      media_dir = [ "V,/mnt/storage/enemy" ];
    };
  };
  users.users.minidlna.extraGroups = [ "users" ];

  # ── Avahi (for samba discovery + mDNS) ───────────────────────────────────
  services.avahi = {
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

  # ── Samba ────────────────────────────────────────────────────────────────
  services.samba = {
    enable = true;
    nmbd.enable = true;
    winbindd.enable = true;
    openFirewall = true;
    settings = {
      global = {
        security = "user";
        workgroup = "WORKGROUP";
        "server string" = "dollnet";
        "server role" = "standalone server";
        "map to guest" = "Bad User";
        "guest account" = "nobody";
      };
      "public" = {
        "path" = "/mnt/storage/public";
        "browseable" = "yes";
        "public" = "yes";
        "guest only" = "yes";
        "read only" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force create mode" = "0644";
        "force directory mode" = "0755";
      };
      "storage" = {
        "path" = "/mnt/storage";
        "browseable" = "yes";
        "guest ok" = "no";
        "read only" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force create mode" = "0644";
        "force directory mode" = "0755";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  services.avahi.extraServiceFiles.smb = ''
    <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h</name>
      <service>
        <type>_smb._tcp</type>
        <port>445</port>
      </service>
    </service-group>
  '';

  # samba password from age secret. same one sol uses (sol-smbpasswd.age),
  # now re-encrypted to include dollnet's host key.
  age.secrets.sol-smbpasswd.file = ../../secrets/sol-smbpasswd.age;

  system.activationScripts.sambaUserPassword = lib.stringAfter [ "users" "groups" ] ''
    SMB_PASSWORD=$(cat ${config.age.secrets.sol-smbpasswd.path})
    echo -e "$SMB_PASSWORD\n$SMB_PASSWORD" | ${pkgs.samba}/bin/smbpasswd -s -a ethernet
  '';

  # ── SLSKD (Soulseek) ─────────────────────────────────────────────────────
  # needs /home/ethernet/slskd.env with your soulseek credentials.
  services.slskd = {
    enable = true;
    environmentFile = "/home/ethernet/slskd.env";
    domain = null;
    settings = {
      shares = {
        directories = [ "/mnt/storage/music" ];
        filters = [
          "\\.ini$"
          "Thumbs.db$"
          "\\.DS_Store$"
        ];
      };
      global.upload.slots = 5;
      directories.downloads = "/mnt/storage/music-new-downloads";
    };
  };

  # ── Caddy (reverse proxy) ────────────────────────────────────────────────
  # sol uses home.ari.computer (via DDNS). that domain points to sol, not here,
  # so we use the tailnet name instead. ACME over a tailnet name won't get
  # Let's Encrypt certs — switch to tailscale HTTPS or a real domain if needed.
  services.caddy = {
    enable = true;
    configFile = pkgs.writeText "Caddyfile" ''
      # slskd API
      slskd.dollnet.giraffa-richter.ts.net {
        reverse_proxy localhost:${toString config.services.slskd.settings.web.port}
      }
    '';
  };

  # ── Omada Controller (Docker) ─────────────────────────────────────────────
  # TP-Link EAP controller. sol ran mbentley/omada-controller:5.14.
  virtualisation.oci-containers.containers.omada-controller = {
    image = "mbentley/omada-controller:5.14";
    ports = [
      "8043:8043"
      "8044:8044"
      "8843:8843"
      "29810:29810/udp"
      "29811:29811/udp"
      "29812:29812/udp"
      "29813:29813"
      "29814:29814"
      "29815:29815"
      "29816:29816"
    ];
    volumes = [
      "omada-data:/opt/tplink/EAPController/data"
      "omada-logs:/opt/tplink/EAPController/logs"
    ];
    extraOptions = [ "--restart=unless-stopped" ];
  };

  # ── DigitalOcean DDNS ─────────────────────────────────────────────────────
  # updates the A record for home.ari.computer to this box's public IP.
  # polls every 5 min. the token is an agenix secret in our repo.
  age.secrets.digitalocean-token.file = ../../secrets/digitalocean-token.age;

  systemd.services.ddns = {
    enable = true;
    description = "Dynamic DNS Updater";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${ddns}/bin/ddns";
      Restart = "on-failure";
      Environment = [
        "DIGITALOCEAN_TOKEN_FILE=${config.age.secrets.digitalocean-token.path}"
        "DOMAIN=ari.computer"
        "NAME=home"
      ];
    };
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # ── steamcmd (for game server ports from sol's firewall) ──────────────────
  environment.systemPackages = [ pkgs.steamcmd ];
}
