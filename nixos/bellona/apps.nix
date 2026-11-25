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

  # ── dashboard generation ────────────────────────────────────────────────
  # everything below is derived from me.bellona.apps (registry.nix), so a new
  # service shows up on the dashboard with status, uptime and a link without
  # anyone editing this file.
  apps = cfg.apps;
  published = lib.filterAttrs (_: a: a.publish && a.subdomain != null) apps;
  apiBase = "http://127.0.0.1:8091";

  # the same table homelab-api reads at runtime. it lives in the store, so it
  # changes only when the registry does, which is exactly when the unit restarts.
  registryJson = pkgs.writeText "homelab-apps.json" (
    builtins.toJSON {
      domain = cfg.domain;
      apps = lib.mapAttrs (_: a: {
        inherit (a)
          title
          port
          subdomain
          unit
          healthPath
          flavor
          note
          ;
      }) apps;
    }
  );

  appTemplate = ''
    <div class="flex justify-between">
      <a class="size-h4 color-highlight" href="{{ .JSON.String "url" }}">{{ .JSON.String "title" }}</a>
      <span class="size-h6 {{ if .JSON.Bool "up" }}color-positive{{ else }}color-negative{{ end }}">{{ .JSON.String "status" }}</span>
    </div>
    <ul class="list-horizontal-text margin-top-10">
      <li>uptime {{ .JSON.String "uptime_7d" }}</li>
      <li>{{ .JSON.Int "restarts_30d" }} restarts</li>
      <li>{{ .JSON.Int "latency_ms" }}ms</li>
    </ul>
    <p class="size-h6 color-paragraph margin-top-10">{{ .JSON.String "info" }}</p>
  '';

  machineTemplate = ''
    <div class="flex justify-between text-center">
      <div>
        <div class="size-h3 color-highlight">{{ .JSON.Float "cpu_pct" | printf "%.0f" }}%</div>
        <div class="size-h6">CPU</div>
      </div>
      <div>
        <div class="size-h3 color-highlight">{{ .JSON.Float "mem_pct" | printf "%.0f" }}%</div>
        <div class="size-h6">RAM</div>
      </div>
      <div>
        <div class="size-h3 color-highlight">{{ .JSON.Float "gpu_pct" | printf "%.0f" }}%</div>
        <div class="size-h6">iGPU</div>
      </div>
    </div>
    <ul class="list-horizontal-text margin-top-15">
      <li>{{ .JSON.String "mem_used" }} / {{ .JSON.String "mem_total" }}</li>
      <li>load {{ .JSON.String "load" }}</li>
      <li>gpu {{ .JSON.String "gpu_temp" }}</li>
    </ul>
    <ul class="list-horizontal-text margin-top-10">
      {{ range .JSON.Array "temps" }}<li>{{ .String "label" }} {{ .Float "c" | printf "%.0f" }}C</li>{{ end }}
    </ul>
    <ul class="list-horizontal-text margin-top-10">
      {{ range .JSON.Array "disks" }}<li>{{ .String "label" }} {{ .String "pct" }}%</li>{{ end }}
    </ul>
    {{ range .JSON.Array "zfs" }}
    <div class="size-h6 margin-top-10">{{ .String "name" }}: {{ .String "alloc" }} / {{ .String "size" }} ({{ .String "health" }})</div>
    {{ end }}
  '';

  sparksTemplate = ''
    {{ range .JSON.Array "nodes" }}
    <div class="flex justify-between margin-top-10">
      <span class="size-h4 color-highlight">{{ .String "host" }}</span>
      <span class="size-h6 {{ if .Bool "up" }}color-positive{{ else }}color-negative{{ end }}">{{ .String "status" }}</span>
    </div>
    <ul class="list-horizontal-text">
      {{ range .Array "lines" }}<li>{{ .String "" }}</li>{{ end }}
    </ul>
    {{ end }}
  '';

  presenceTemplate = ''
    {{ if .JSON.Array "people" }}
    <ul class="list list-gap-10">
      {{ range .JSON.Array "people" }}
      <li class="flex justify-between">
        <span class="size-h4 color-highlight">{{ .String "name" }}</span>
        <span class="size-h6">{{ .String "state" }}</span>
      </li>
      {{ end }}
    </ul>
    {{ else }}
    <p class="size-h6 color-paragraph">no presence data</p>
    {{ end }}
  '';

  torrentsTemplate = ''
    <div class="flex justify-between">
      <span class="size-h4 color-highlight">{{ .JSON.String "up" }} up</span>
      <span class="size-h4 color-highlight">{{ .JSON.String "down" }} down</span>
    </div>
    <ul class="list-horizontal-text margin-top-10">
      <li>ratio {{ .JSON.Float "ratio" | printf "%.2f" }}</li>
      <li>{{ .JSON.Int "count" }} torrents</li>
    </ul>
  '';

  appWidget = slug: a: {
    type = "custom-api";
    title = a.title;
    # glance caches fetched widget data for minutes by default; a status line
    # that stale is a lie. 30s sits just above the 15s vllm scrape.
    cache = "30s";
    url = "${apiBase}/app/${slug}";
    template = appTemplate;
  };

  groupWidgets = g: lib.mapAttrsToList appWidget (lib.filterAttrs (_: a: a.group == g) published);
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
    # slskd validates its directories on startup and refuses to run if the
    # incomplete dir is missing -- it does not create it itself. the service
    # user already has group write on /tank/music/inbox, so create it in the
    # same sandbox rather than as root.
    systemd.services.slskd.preStart = ''
      ${pkgs.coreutils}/bin/mkdir -p /tank/music/inbox/.incomplete
    '';
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
        # every request arrives from caddy on 127.0.0.1, so HA's trusted_networks
        # provider authenticates it as the owner and never renders a login form --
        # authelia's forward-auth is the only gate on the public path. the
        # homeassistant provider stays listed so a direct LAN/tailnet hit can
        # still log in normally. allow_bypass_login needs exactly one user;
        # with several HA shows a picker instead of a password.
        auth_providers = [
          { type = "homeassistant"; }
          {
            type = "trusted_networks";
            trusted_networks = [ "127.0.0.1" ];
            allow_bypass_login = true;
          }
        ];
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
    # the pages are generated from the registry: home is the machine + the
    # sparks + presence + the seedbox, and one page per group holds a widget per
    # app (status, uptime, restarts, latency, link). adding an app to
    # me.bellona.apps adds its widget here.
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
                    title = "bellona";
                    cache = "30s";
                    url = "${apiBase}/machine";
                    template = machineTemplate;
                  }
                  {
                    type = "custom-api";
                    title = "sparks";
                    cache = "30s";
                    url = "${apiBase}/sparks";
                    template = sparksTemplate;
                  }
                  {
                    type = "custom-api";
                    title = "presence";
                    cache = "60s";
                    url = "${apiBase}/presence";
                    template = presenceTemplate;
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
                        links = lib.mapAttrsToList (_: a: {
                          title = a.title;
                          url = "https://${a.subdomain}.${cfg.domain}";
                        }) published;
                      }
                    ];
                  }
                  {
                    type = "custom-api";
                    title = "seedbox";
                    cache = "30s";
                    url = "${apiBase}/torrents";
                    template = torrentsTemplate;
                  }
                ];
              }
            ];
          }
          {
            # glance allows up to 3 columns per page but requires 1 or 2 of them
            # to be full width, so the groups are packed into two full columns
            # instead of three small ones.
            name = "services";
            columns = [
              {
                size = "full";
                widgets = groupWidgets "media" ++ groupWidgets "home";
              }
              {
                size = "full";
                widgets = groupWidgets "infra";
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
        # the app registry is passed in as JSON so the unit knows which apps to
        # report on without a second hand-kept list.
        ExecStart = "${pkgs.python3}/bin/python3 ${./homelab-api.py} ${registryJson}";
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
        snap_remote luna ethie@luna.local /home/ethie/.hermes
        snap_remote hermes ethie@hermes.local /home/ari/.hermes
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
