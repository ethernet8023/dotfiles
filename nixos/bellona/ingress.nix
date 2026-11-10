# ingress: one Caddy on the LAN address, one Authelia instance, wildcard cert
# via Cloudflare DNS-01. services bind loopback; only 443 is public.
#
# tailscale serve already owns :443 on the tailscale0 address, so Caddy binds
# the LAN address explicitly. tailnet clients reach services by the public DNS
# name (or split DNS on the LAN).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.me.bellona;
  domain = cfg.domain;
  authUrl = "https://auth.${domain}";
  autheliaPort = 9091;
  certName = domain;

  forwardAuth = ''
    forward_auth 127.0.0.1:${toString autheliaPort} {
      uri /api/authz/forward-auth
      copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
  '';

  vhost =
    {
      upstream,
      protect ? true,
      extra ? "",
    }:
    {
      useACMEHost = certName;
      listenAddresses = [ cfg.lanAddress ];
      extraConfig =
        extra
        + lib.optionalString protect forwardAuth
        + ''
          reverse_proxy 127.0.0.1:${toString upstream}
        '';
    };
in
{
  config = lib.mkIf cfg.enable {
    age.secrets.authelia-jwt = {
      file = ../../secrets/authelia-jwt.age;
      owner = "authelia-main";
      mode = "0400";
    };
    age.secrets.authelia-storage-key = {
      file = ../../secrets/authelia-storage-key.age;
      owner = "authelia-main";
      mode = "0400";
    };
    age.secrets.authelia-session-secret = {
      file = ../../secrets/authelia-session-secret.age;
      owner = "authelia-main";
      mode = "0400";
    };
    age.secrets.cloudflare-dns-token.file = ../../secrets/cloudflare-dns-token.age;

    networking.firewall.allowedTCPPorts = [ 443 ];

    # ssh is LAN + tailnet only. the router forwards just 443, so this is
    # belt-and-braces: if another port is ever forwarded, ssh still refuses
    # strangers. nixpkgs' iptables backend has no extraInputRules (that option
    # is nftables-only), and extraCommands runs AFTER the per-port accepts, so
    # insert at the head of nixos-fw instead. `-w` takes the xtables lock the
    # firewall script also holds; `nixos-fw-refuse` sends a reset so clients
    # fail fast instead of hanging on a drop.
    networking.firewall.extraCommands = ''
      iptables -w -I nixos-fw 1 -p tcp --dport 22 -s 192.168.2.0/24 -j nixos-fw-accept
      iptables -w -I nixos-fw 2 -p tcp --dport 22 -s 100.64.0.0/10 -j nixos-fw-accept
      iptables -w -I nixos-fw 3 -p tcp --dport 22 -s 127.0.0.0/8 -j nixos-fw-accept
      iptables -w -I nixos-fw 4 -p tcp --dport 22 -j nixos-fw-refuse
      ip6tables -w -I nixos-fw 1 -p tcp --dport 22 -s fd7a:115c:a1e0::/48 -j nixos-fw-accept
      ip6tables -w -I nixos-fw 2 -p tcp --dport 22 -s fe80::/10 -j nixos-fw-accept
      ip6tables -w -I nixos-fw 3 -p tcp --dport 22 -s ::1/128 -j nixos-fw-accept
      ip6tables -w -I nixos-fw 4 -p tcp --dport 22 -j nixos-fw-refuse
    '';

    security.acme = {
      acceptTerms = true;
      defaults.email = "arilotter@gmail.com";
      certs.${certName} = {
        domain = "*.${domain}";
        extraDomainNames = [ domain ];
        dnsProvider = "cloudflare";
        environmentFile = config.age.secrets.cloudflare-dns-token.path;
        group = "caddy";
        reloadServices = [ "caddy.service" ];
      };
    };

    services.caddy = {
      enable = true;
      virtualHosts = {
        "auth.${domain}" = {
          useACMEHost = certName;
          listenAddresses = [ cfg.lanAddress ];
          extraConfig = ''
            reverse_proxy 127.0.0.1:${toString autheliaPort}
          '';
        };

        "home.${domain}" = vhost { upstream = 8090; };
        "photos.${domain}" = vhost {
          upstream = 2283;
          protect = false;
        };
        "torrents.${domain}" = vhost { upstream = 8080; };
        "grafana.${domain}" = vhost { upstream = 3000; };
        "hermes.${domain}" = vhost { upstream = 9120; };
        "api.${domain}" = vhost {
          upstream = 8091;
          protect = false;
        };

        "music.${domain}" = {
          useACMEHost = certName;
          listenAddresses = [ cfg.lanAddress ];
          extraConfig = ''
            @rest path /rest/*
            handle @rest {
              reverse_proxy 127.0.0.1:4533
            }
            handle {
              ${forwardAuth}
              reverse_proxy 127.0.0.1:4533
            }
          '';
        };

        "soulseek.${domain}" = {
          useACMEHost = certName;
          listenAddresses = [ cfg.lanAddress ];
          extraConfig = ''
            @api path /api/*
            handle @api {
              reverse_proxy 127.0.0.1:5030
            }
            handle {
              ${forwardAuth}
              reverse_proxy 127.0.0.1:5030
            }
          '';
        };

        "ha.${domain}" = {
          useACMEHost = certName;
          listenAddresses = [ cfg.lanAddress ];
          extraConfig = ''
            @open path /api/* /local/* /auth/* /static/* /frontend_latest/* /frontend_es5/*
            handle @open {
              reverse_proxy 127.0.0.1:8123
            }
            handle {
              ${forwardAuth}
              reverse_proxy 127.0.0.1:8123
            }
          '';
        };
      };
    };

    services.authelia.instances.main = {
      enable = true;
      secrets = {
        jwtSecretFile = config.age.secrets.authelia-jwt.path;
        storageEncryptionKeyFile = config.age.secrets.authelia-storage-key.path;
        sessionSecretFile = config.age.secrets.authelia-session-secret.path;
      };
      settings = {
        theme = "dark";
        server.address = "tcp://127.0.0.1:${toString autheliaPort}";
        log.level = "info";
        totp.issuer = domain;
        authentication_backend.file.path = "/etc/authelia/users.yml";
        access_control = {
          default_policy = "deny";
          rules = [
            # apps with their own auth (or public share links) must not be
            # forward-authed, or mobile apps and share URLs break.
            {
              domain = "auth.${domain}";
              policy = "bypass";
            }
            {
              domain = "photos.${domain}";
              policy = "bypass";
            }
            # Subsonic clients authenticate themselves.
            {
              domain = "music.${domain}";
              resources = [ "^/rest(/.*)?$" ];
              policy = "bypass";
            }
            {
              domain = "music.${domain}";
              policy = "one_factor";
            }
            # Home Assistant's mobile app and API use long-lived tokens.
            {
              domain = "ha.${domain}";
              resources = [
                "^/api(/.*)?$"
                "^/local(/.*)?$"
                "^/auth(/.*)?$"
                "^/static(/.*)?$"
                "^/frontend_latest(/.*)?$"
              ];
              policy = "bypass";
            }
            {
              domain = "ha.${domain}";
              policy = "one_factor";
            }
            # slskd's API uses its own key.
            {
              domain = "soulseek.${domain}";
              resources = [ "^/api(/.*)?$" ];
              policy = "bypass";
            }
            {
              domain = "soulseek.${domain}";
              policy = "one_factor";
            }
            {
              domain = [
                "home.${domain}"
                "torrents.${domain}"
                "grafana.${domain}"
                "hermes.${domain}"
              ];
              policy = "two_factor";
            }
          ];
        };
        session = {
          name = "authelia_session";
          same_site = "lax";
          expiration = "12h";
          inactivity = "1h";
          cookies = [
            {
              domain = domain;
              authelia_url = authUrl;
              default_redirection_url = "https://home.${domain}";
            }
          ];
        };
        storage.local.path = "/var/lib/authelia-main/db.sqlite3";
        notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";
      };
    };

    # file backend users. the hash is argon2id; rotate with
    # `nix run nixpkgs#authelia -- crypto hash generate argon2 --password '...'`
    environment.etc."authelia/users.yml".text = ''
      users:
        ethie:
          displayname: ethie
          password: "$argon2id$v=19$m=65536,t=3,p=4$oaACm/iPV/GMY9ehonkpvw$MNTaruvqCc2njs7jYkTlSw4z90bPAox644QQM0PsfmY"
          email: arilotter@gmail.com
          groups:
            - admins
    '';
    # ACME only ever creates the _acme-challenge TXT records. A records are
    # routing, not proof of ownership, so Caddy never touches them. this
    # upserts @ and * to the current public IP; it needs Zone.DNS Edit plus
    # Zone.Zone Read on the token.
    systemd.services.bellona-ddns = {
      description = "upsert packet.dog A records from the current public IP";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.age.secrets.cloudflare-dns-token.path;
      };
      script = ''
        set -euo pipefail
        ip=$(${pkgs.curl}/bin/curl -fsS https://cloudflare.com/cdn-cgi/trace | ${pkgs.gnused}/bin/sed -n 's/^ip=//p')
        [ -n "$ip" ] || exit 1
        zone=$(${pkgs.curl}/bin/curl -fsS -H "Authorization: Bearer $CLOUDFLARE_DNS_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=${cfg.domain}" | ${pkgs.jq}/bin/jq -r '.result[0].id // empty')
        [ -n "$zone" ] || exit 1
        for name in "${cfg.domain}" "*.${cfg.domain}"; do
          payload=$(${pkgs.jq}/bin/jq -nc --arg n "$name" --arg ip "$ip" '{type:"A",name:$n,content:$ip,ttl:120,proxied:false}')
          id=$(${pkgs.curl}/bin/curl -fsS -H "Authorization: Bearer $CLOUDFLARE_DNS_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?type=A&name=$name" | ${pkgs.jq}/bin/jq -r '.result[0].id // empty')
          if [ -n "$id" ]; then
            ${pkgs.curl}/bin/curl -fsS -X PUT -H "Authorization: Bearer $CLOUDFLARE_DNS_API_TOKEN" -H "Content-Type: application/json" --data "$payload" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$id" >/dev/null
          else
            ${pkgs.curl}/bin/curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_DNS_API_TOKEN" -H "Content-Type: application/json" --data "$payload" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" >/dev/null
          fi
        done
      '';
    };
    systemd.timers.bellona-ddns = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitInactiveSec = "5min";
        Persistent = true;
      };
    };
  };
}
