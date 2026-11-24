# forge: forgejo, so repos can be pushed to this box.
#
# web is git.<domain>, behind the same authelia forward-auth as every other
# vhost. forgejo does not run its own login form: it reads authelia's Remote-User
# header on loopback (REVERSE_PROXY_TRUSTED_PROXIES), so the portal session IS
# the forgejo session. the account is created in preStart rather than through the
# install wizard, which is why the config is fully declarative here.
#
# git rides the box's OWN sshd on :22 -- no second daemon, no extra firewall
# port, and her normal ssh keys are what authenticate. forgejo writes its
# authorized_keys into its home (stateDir/.ssh/authorized_keys), which is sshd's
# default AuthorizedKeysFile for that account, so each entry carries forgejo's
# `serv key-N` forced command. the account is named `git` so clone urls read
# git@<host> like every other forge; the module only auto-creates an account
# called `forgejo`, hence the explicit user below.
#
# the tailnet is the exception: tailscale ssh owns :22 there, so a tailnet client
# reaches tailscaled instead of sshd, and tailscaled authenticates by tailnet
# identity and never runs forgejo's forced command. `tailscale set --ssh=false`
# on the box hands :22 back to sshd for every path.
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
      # sshd has to have a real account to authenticate; git@ is the name the
      # clone url should read, and it doubles as the unit's runtime user.
      user = "git";
      group = "git";

      settings = {
        server = {
          DOMAIN = gitDomain;
          ROOT_URL = "https://${gitDomain}/";
          # system sshd, not the built-in one: the module then adds a
          # `Match User git` block carrying AcceptEnv GIT_PROTOCOL, which is what
          # protocol v2 needs.
          START_SSH_SERVER = false;
          SSH_CREATE_AUTHORIZED_KEYS_FILE = true;
          SSH_DOMAIN = gitDomain;
          SSH_PORT = 22;
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

    # the module skips its own account creation when the runtime user is not
    # `forgejo`, and sshd's StrictModes wants this home owned by the same name.
    users.users.git = {
      home = config.services.forgejo.stateDir;
      useDefaultShell = true;
      group = "git";
      isSystemUser = true;
    };
    users.groups.git = { };

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
  };
}
