# app registry: one block per service, and everything else is derived from it.
#
# ingress.nix builds the Caddy vhosts and the Authelia access rules from this
# table, apps.nix builds the glance services page from it, and homelab-api gets
# the same table as JSON so each widget can report status/uptime. adding a
# service means adding one attr here -- no second list to forget.
#
# flavor drives the service-specific line in the widget (and nothing else); it
# is a hint for homelab-api, not a config switch. unit is the systemd unit whose
# state feeds uptime, and stays null for user units (qBittorrent, Hermes,
# cctrack), which are judged by probing their own listener instead.
{
  config,
  lib,
  ...
}:
let
  cfg = config.me.bellona;
in
{
  options.me.bellona.apps = lib.mkOption {
    description = ''
      The services this box publishes. One attr per app; ingress, auth rules,
      the dashboard and the status API are all generated from it.
    '';
    default = {
      glance = {
        title = "Dashboard";
        port = 8090;
        subdomain = "home";
        unit = "glance.service";
        group = "infra";
        note = "this dashboard";
      };
      immich = {
        title = "Immich";
        port = 2283;
        subdomain = "photos";
        unit = "immich-server.service";
        healthPath = "/api/server/ping";
        flavor = "immich";
        group = "media";
        # immich has its own auth and share links, so it must not sit behind
        # forward-auth. it stays unpublished until its backend is verified --
        # flip publish on and the vhost + bypass rule appear together.
        protect = false;
        publish = false;
        note = "photos";
      };
      navidrome = {
        title = "Music";
        port = 4533;
        subdomain = "music";
        unit = "navidrome.service";
        flavor = "navidrome";
        group = "media";
        note = "music library";
      };
      slskd = {
        title = "Soulseek";
        port = 5030;
        subdomain = "soulseek";
        unit = "slskd.service";
        flavor = "slskd";
        group = "media";
        note = "download queue";
      };
      qbittorrent = {
        title = "Torrents";
        port = 8080;
        subdomain = "torrents";
        flavor = "qbittorrent";
        group = "media";
        note = "seedbox";
      };
      jellyfin = {
        title = "Jellyfin";
        port = 8096;
        subdomain = "media";
        unit = "jellyfin.service";
        flavor = "jellyfin";
        group = "media";
        note = "video library";
      };
      home-assistant = {
        title = "Home Assistant";
        port = 8123;
        subdomain = "ha";
        unit = "home-assistant.service";
        flavor = "home-assistant";
        group = "home";
        note = "house automation";
      };
      grafana = {
        title = "Grafana";
        port = 3000;
        subdomain = "grafana";
        unit = "grafana.service";
        flavor = "grafana";
        group = "infra";
        note = "metrics";
      };
      hermes = {
        title = "Hermes";
        port = 9120;
        subdomain = "hermes";
        flavor = "hermes";
        group = "infra";
        note = "agent workspace";
      };
      forgejo = {
        title = "Git";
        port = 3001;
        subdomain = "git";
        unit = "forgejo.service";
        flavor = "forgejo";
        group = "infra";
        note = "forge";
      };
      cctrack = {
        title = "Budget";
        port = 5001;
        subdomain = "budget";
        flavor = "cctrack";
        group = "infra";
        note = "statements";
      };
    };
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
            description = "display name, used for the vhost-adjacent widget and the bookmark";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "loopback port the app listens on";
          };
          subdomain = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "subdomain under me.bellona.domain; null means loopback-only";
          };
          unit = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "systemd unit whose state feeds uptime (null for user units)";
          };
          healthPath = lib.mkOption {
            type = lib.types.str;
            default = "/";
            description = "path probed on the loopback port for live reachability";
          };
          flavor = lib.mkOption {
            type = lib.types.enum [
              "generic"
              "immich"
              "navidrome"
              "slskd"
              "qbittorrent"
              "home-assistant"
              "grafana"
              "hermes"
              "forgejo"
              "jellyfin"
              "cctrack"
            ];
            default = "generic";
            description = "which service-specific line homelab-api reports";
          };
          group = lib.mkOption {
            type = lib.types.enum [
              "media"
              "home"
              "infra"
            ];
            default = "infra";
            description = "which column of the services page this app lands in";
          };
          protect = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "put authelia forward-auth in front (false for apps with their own auth)";
          };
          publish = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "create the caddy vhost + authelia rule at all";
          };
          note = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "fallback line for the widget when the app exposes no health data";
          };
        };
      }
    );
  };
}
