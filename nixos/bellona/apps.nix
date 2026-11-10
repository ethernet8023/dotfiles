# apps: photos, music, seedbox, home automation, dashboard, knowledge vault.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.me.bellona;
  beetsConfig = pkgs.writeText "beets-config.yaml" ''
    directory: /tank/music/library
    library: /var/lib/beets/library.db
    import:
      move: yes
      write: yes
      quiet: yes
      autotag: yes
    paths:
      default: $albumartist/$album%aunique{}/$track $title
  '';
in
{
  config = lib.mkIf cfg.enable {
    age.secrets.slskd-env.file = ../../secrets/slskd-env.age;
    age.secrets.homelab-api-token.file = ../../secrets/homelab-api-token.age;
    age.secrets.ha-token.file = ../../secrets/ha-token.age;

    # ── photos ────────────────────────────────────────────────────────────
    services.immich = {
      enable = true;
      host = "127.0.0.1";
      port = 2283;
      mediaLocation = "/tank/photos";
      # strix halo ROCm is uneven; start on CPU and measure before enabling
      # accelerationDevices = [ "/dev/dri/renderD128" ];
    };
    systemd.services.immich-server.after = [ "tank.mount" ];
    systemd.services.immich-server.requires = [ "tank.mount" ];
    systemd.services.immich-machine-learning.after = [ "tank.mount" ];
    systemd.services.immich-machine-learning.requires = [ "tank.mount" ];

    # ── music ─────────────────────────────────────────────────────────────
    services.navidrome = {
      enable = true;
      user = "navidrome";
      group = "media";
      settings = {
        Address = "127.0.0.1";
        Port = 4533;
        MusicFolder = "/tank/music/library";
        ScanSchedule = "@every 1h";
      };
    };
    systemd.services.navidrome.after = [ "tank.mount" ];
    systemd.services.navidrome.requires = [ "tank.mount" ];

    services.slskd = {
      enable = true;
      user = "slskd";
      group = "media";
      environmentFile = config.age.secrets.slskd-env.path;
      settings = {
        web = {
          ip_address = "127.0.0.1";
          port = 5030;
          authentication.disabled = true; # behind Caddy forward-auth
        };
        directories = {
          downloads = "/tank/music/inbox";
          incomplete = "/tank/music/inbox/.incomplete";
        };
        shares.directories = [ "/tank/music/library" ];
        soulseek.listen_port = 50300;
      };
    };
    systemd.services.slskd.after = [ "tank.mount" ];
    systemd.services.slskd.requires = [ "tank.mount" ];
    networking.firewall.allowedTCPPorts = [
      50300
      8091
    ];

    systemd.services.beets-import = {
      description = "import slskd downloads into the beets library";
      after = [
        "network.target"
        "tank.mount"
      ];
      requires = [ "tank.mount" ];
      serviceConfig = {
        Type = "oneshot";
        User = "ethernet";
        Group = "users";
      };
      script = ''
        ${pkgs.beets}/bin/beet -c ${beetsConfig} import -q /tank/music/inbox
      '';
    };
    systemd.timers.beets-import = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };

    # ── home automation ───────────────────────────────────────────────────
    services.mosquitto = {
      enable = true;
      listeners = [
        {
          port = 1883;
          address = "127.0.0.1";
          settings.allow_anonymous = true;
        }
      ];
    };

    services.home-assistant = {
      enable = true;
      configWritable = false;
      config = {
        homeassistant = {
          name = "bellona";
          latitude = 43.6532;
          longitude = -79.3832;
          unit_system = "metric";
          time_zone = "America/Toronto";
        };
        http.server_host = [ "127.0.0.1" ];
        http.server_port = 8123;
        # full-resolution history forever. long-term statistics are already
        # kept forever by HA; this keeps every state change too.
        recorder = {
          db_url = "sqlite:////var/lib/hass/home-assistant_v2.db";
          purge_keep_days = 3650;
          auto_purge = false;
        };
      };
    };

    services.zigbee2mqtt = lib.mkIf cfg.zigbee.enable {
      enable = true;
      settings = {
        mqtt.server = "mqtt://127.0.0.1:1883";
        serial = {
          port = "/dev/ttyACM0";
          adapter = "zstack";
        };
        frontend = {
          host = "127.0.0.1";
          port = 8092;
        };
      };
    };

    # ── dashboard ─────────────────────────────────────────────────────────
    services.glance = {
      enable = true;
      settings = {
        server = {
          host = "127.0.0.1";
          port = 8090;
        };
        pages = [
          {
            name = "home";
            columns = [
              {
                size = "small";
                widgets = [
                  {
                    type = "custom-api";
                    title = "homelab";
                    url = "http://127.0.0.1:8091/summary";
                    template = ''
                      {{ .JSON.String "headline" }}
                    '';
                  }
                ];
              }
              {
                size = "full";
                widgets = [
                  {
                    type = "bookmarks";
                    groups = [
                      {
                        # glance 0.8 keys these as `title`, not `name` -- `name`
                        # parses fine and then renders as an empty row.
                        title = "services";
                        links = [
                          {
                            title = "Immich";
                            url = "https://photos.${cfg.domain}";
                          }
                          {
                            title = "Music";
                            url = "https://music.${cfg.domain}";
                          }
                          {
                            title = "Soulseek";
                            url = "https://soulseek.${cfg.domain}";
                          }
                          {
                            title = "Torrents";
                            url = "https://torrents.${cfg.domain}";
                          }
                          {
                            title = "Home Assistant";
                            url = "https://ha.${cfg.domain}";
                          }
                          {
                            title = "Grafana";
                            url = "https://grafana.${cfg.domain}";
                          }
                          {
                            title = "Hermes";
                            url = "https://hermes.${cfg.domain}";
                          }
                        ];
                      }
                    ];
                  }
                ];
              }
            ];
          }
        ];
      };
    };

    systemd.services.homelab-api = {
      description = "homelab summary API";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "victoriametrics.service"
        "home-assistant.service"
      ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./homelab-api.py}";
        Restart = "on-failure";
      };
    };
    systemd.services.qbt-exporter = {
      description = "qBittorrent prometheus exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./qbt-exporter.py}";
        Restart = "on-failure";
      };
    };

    # ── knowledge vault ───────────────────────────────────────────────────
    services.syncthing = {
      enable = true;
      user = "ethernet";
      dataDir = "/home/ethernet/.local/state/syncthing";
      configDir = "/home/ethernet/.config/syncthing";
      settings = {
        gui.address = "127.0.0.1:8384";
        folders.vault = {
          id = "vault";
          label = "vault";
          path = "/tank/vault";
        };
      };
    };
    systemd.services.syncthing.after = [ "tank.mount" ];
    systemd.services.syncthing.requires = [ "tank.mount" ];

    # ── Hermes session archive ────────────────────────────────────────────
    # "every trace" = every Hermes home. phobos/deimos do not run Hermes, so
    # the sources are the boxes that do. hardlink snapshots keep daily copies
    # cheap on ZFS; nothing is ever deleted.
    systemd.services.hermes-archive = {
      description = "snapshot Hermes homes to tank/traces";
      after = [
        "network.target"
        "tank.mount"
      ];
      requires = [ "tank.mount" ];
      serviceConfig = {
        Type = "oneshot";
        User = "ethernet";
        Group = "users";
      };
      script = ''
        set -u
        stamp=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
        snap_local() {
          base=/tank/traces/hermes/bellona
          ${pkgs.coreutils}/bin/mkdir -p "$base"
          prev=$(${pkgs.findutils}/bin/find "$base" -mindepth 1 -maxdepth 1 -type d | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/tail -n1)
          dest="$base/$stamp"
          if [ -n "$prev" ]; then
            ${pkgs.rsync}/bin/rsync -a --link-dest="$prev" /home/ethernet/.ethernet-hermes/ "$dest/"
          else
            ${pkgs.rsync}/bin/rsync -a /home/ethernet/.ethernet-hermes/ "$dest/"
          fi
        }
        snap_remote() {
          host=$1
          target=$2
          path=$3
          base=/tank/traces/hermes/$host
          ${pkgs.coreutils}/bin/mkdir -p "$base"
          prev=$(${pkgs.findutils}/bin/find "$base" -mindepth 1 -maxdepth 1 -type d | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/tail -n1)
          dest="$base/$stamp"
          if [ -n "$prev" ]; then
            ${pkgs.rsync}/bin/rsync -a --link-dest="$prev" \
              -e "${pkgs.openssh}/bin/ssh -F none -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8" \
              "$target:$path/" "$dest/" || true
          else
            ${pkgs.rsync}/bin/rsync -a \
              -e "${pkgs.openssh}/bin/ssh -F none -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8" \
              "$target:$path/" "$dest/" || true
          fi
        }
        snap_local
        snap_remote luna ethie@100.108.28.67 /home/ethie/.hermes
        snap_remote hermes ethie@hermes.tail5b83ba.ts.net /home/ari/.hermes
        snap_remote iris ethernet@iris.local /Users/ethernet/.hermes
      '';
    };
    systemd.timers.hermes-archive = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "04:00";
        Persistent = true;
      };
    };
  };
}
