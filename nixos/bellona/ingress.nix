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
  };
}
