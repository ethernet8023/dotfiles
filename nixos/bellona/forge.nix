# forge: forgejo, so repos can be pushed to this box.
#
# web is git.<domain>, behind the same authelia forward-auth as every other
# vhost. forgejo does not run its own login form: it reads authelia's Remote-User
# header on loopback (REVERSE_PROXY_TRUSTED_PROXIES), so the portal session IS
# the forgejo session. the account is created in preStart rather than through the
# install wizard, which is why the config is fully declarative here.
#
# push is git over ssh on 2222, served by forgejo's own sshd, and the firewall
# scopes that port to the house LAN, the tailnet and loopback -- anything else is
# refused. port 22 is not an option: on the tailnet tailscale ssh answers on 22
# before forgejo's sshd would ever see the connection, and that stays on.
#
# state stays on the NVMe: repos, the sqlite db, lfs blobs and app.ini are
# appdata-scale, and a stateDir under /tank would race the pool -- tmpfiles
# would create it on the root fs before tank.mount shadows it, and anything
# written in between disappears behind the mount.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.me.bellona;
  domain = cfg.domain;
  gitDomain = "git.${domain}";
  httpPort = 3001;
  sshPort = 2222;
  exe = "${config.services.forgejo.package}/bin/forgejo";
in
{
  config = lib.mkIf cfg.enable {
    services.forgejo = {
      enable = true;
      # caddy is the only thing that talks to this; see ingress.nix.
      httpAddress = "127.0.0.1";
      httpPort = httpPort;
      lfs.enable = true;

      settings = {
        server = {
          DOMAIN = gitDomain;
          ROOT_URL = "https://${gitDomain}/";
          START_SSH_SERVER = true;
          SSH_DOMAIN = gitDomain;
          SSH_PORT = sshPort;
          SSH_LISTEN_PORT = sshPort;
          # the built-in sshd identifies the account by public key alone; this
          # only makes the advertised clone url read git@ instead of forgejo@.
          BUILTIN_SSH_SERVER_USER = "git";
        };
        # caddy terminates tls, so the session cookie must never travel in clear.
        session.COOKIE_SECURE = true;
        service = {
          DISABLE_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = true;
          ENABLE_REVERSE_PROXY_AUTHENTICATION = true;
          ENABLE_REVERSE_PROXY_AUTO_REGISTRATION = true;
          ENABLE_REVERSE_PROXY_EMAIL = true;
        };
        security = {
          REVERSE_PROXY_AUTHENTICATION_USER = "Remote-User";
          REVERSE_PROXY_AUTHENTICATION_EMAIL = "Remote-Email";
          # only caddy reaches forgejo, and it does so over loopback. anything
          # else sending Remote-User is not believed.
          REVERSE_PROXY_TRUSTED_PROXIES = "127.0.0.0/8,::1/128";
        };
      };
    };

    # the module's own preStart ends with `forgejo migrate`, so appending here
    # runs against a schema that exists. `admin user create` exits non-zero when
    # the account is already present, hence the list guard. the account is admin
    # so the first portal visit can administer the instance -- a reverse-proxy
    # auto-registration would make it an ordinary user instead.
    systemd.services.forgejo.preStart = lib.mkAfter ''
      if ! ${exe} admin user list | ${pkgs.gnugrep}/bin/grep -qw ethie; then
        ${exe} admin user create --admin --username ethie \
          --email arilotter@gmail.com --random-password
      fi
    '';

    # the router forwards only 443, but scope 2222 explicitly rather than
    # leaning on that: accept the house LAN, the tailnet and loopback, refuse
    # everything else. inserted at the head of nixos-fw so a stranger cannot
    # reach the port even if it is ever forwarded, and refused rather than
    # dropped so clients fail fast. same shape as the :22 block in ingress.nix;
    # both are dport-scoped, so the two sets cannot shadow each other.
    networking.firewall.extraCommands = ''
      iptables -w -I nixos-fw 1 -p tcp --dport 2222 -s 192.168.2.0/24 -j nixos-fw-accept
      iptables -w -I nixos-fw 2 -p tcp --dport 2222 -s 100.64.0.0/10 -j nixos-fw-accept
      iptables -w -I nixos-fw 3 -p tcp --dport 2222 -s 127.0.0.0/8 -j nixos-fw-accept
      iptables -w -I nixos-fw 4 -p tcp --dport 2222 -j nixos-fw-refuse
      ip6tables -w -I nixos-fw 1 -p tcp --dport 2222 -s fd7a:115c:a1e0::/48 -j nixos-fw-accept
      ip6tables -w -I nixos-fw 2 -p tcp --dport 2222 -s fe80::/10 -j nixos-fw-accept
      ip6tables -w -I nixos-fw 3 -p tcp --dport 2222 -s ::1/128 -j nixos-fw-accept
      ip6tables -w -I nixos-fw 4 -p tcp --dport 2222 -j nixos-fw-refuse
    '';
  };
}
