{
  config,
  hermes-agent-package,
  ...
}:
{
  # ethernet@dollnet -- the complete home config for my account on dahlia's box.
  #
  # dollnet is not my machine: it's dahlia's NixOS server (tailnet
  # giraffa-richter.ts.net) that lives upstairs, and i'm just a user on it with
  # an account in wheel. so everything about *my* account lives here in my repo,
  # and her configuration.nix only keeps the parts that genuinely need root:
  #
  #   users.users.ethernet          account + ssh keys
  #   users.users.ethernet.linger   so my systemd --user services survive logout
  #                                 (home-manager cannot set this itself)
  #
  # this file bundles its own imports, so her flake pulls in exactly one thing.
  #
  # the hermes-agent MODULE now comes from upstream
  # (hermes-agent.homeManagerModules.default) rather than a port in this repo.
  # her flake must add that import alongside this file; the package keeps coming
  # through extraSpecialArgs, because dollnet already has hermes-agent as a
  # flake input for dahlia's system-level instance and reusing it keeps one copy
  # of hermes-agent (and one nixpkgs) in the closure instead of two.

  imports = [
    ../home-server.nix
  ];

  home.username = "ethernet";
  home.homeDirectory = "/home/ethernet";

  # start/stop user services as part of the switch instead of waiting for the
  # next login. needs linger (set on her side) to outlive my shell.
  systemd.user.startServices = "sd-switch";

  programs.bash = {
    enable = true;
    # HERMES_HOME is exported by the hermes-agent module via
    # home.sessionVariables -- no manual export needed.
    shellAliases = {
      hs = "systemctl --user status hermes-agent hermes-backend";
      hlog = "journalctl --user -u hermes-agent -f";
      hblog = "journalctl --user -u hermes-backend -f";
    };
  };

  services.hermes-agent = {
    enable = true;
    package = hermes-agent-package;

    # deliberately NOT ~/.hermes. the system-level instance on this box is
    # dahlia's (container mode, HERMES_HOME=/var/lib/hermes/.hermes) and used to
    # export HERMES_HOME system-wide, which clobbered mine. naming this one
    # explicitly means a shell is never ambiguous about which instance it's
    # pointed at, and a stray unconfigured `hermes` can't adopt this state.
    hermesHome = "${config.home.homeDirectory}/.ethernet-hermes";
    workingDirectory = "${config.home.homeDirectory}/work";

    # required for discord to be online: the backend below does NOT run a
    # gateway (`hermes serve`/`dashboard` only *controls* one).
    gateway.enable = true;

    # backend for hermes desktop + the browser dashboard:
    #   settings -> gateway -> remote gateway
    #     -> http://bellona.giraffa-richter.ts.net:9119
    #
    # "dashboard" = "serve" (the /api/ws + /api/pty sockets desktop needs) plus
    # the browser admin panel on the same port. free on nix: the wrapper presets
    # HERMES_WEB_DIST to a prebuilt SPA, so the startup web build is skipped.
    #
    # bound to the magicdns name rather than an IP, for two reasons:
    #   1. the dashboard rejects any request whose Host header != the string it
    #      was bound to (DNS-rebinding defence, GHSA-ppp5-vxwm-4cf7). browsing to
    #      the name while bound to an IP gives "Invalid Host header".
    #   2. bellona is shared into my tailnet, so it has a *different* address in
    #      each tailnet's view -- an IP resolved on the box is simply wrong for
    #      remote peers; the dns name resolves correctly from both sides.
    #
    # waitFor polls until the magicdns name resolves before binding. without it
    # the unit races tailscaled at boot and uvicorn fails on the unresolvable
    # name, and only Restart=on-failure eventually catches it (NousResearch/
    # hermes-agent#91720).
    backend = {
      mode = "dashboard";
      host = "bellona.giraffa-richter.ts.net";
      waitFor = "hostname";
      port = 9119;

      # auth = one shared session token, agenix-decrypted (see
      # nixos/bellona-ether.nix). no nous portal oauth, no basic-auth: the
      # token becomes HERMES_DASHBOARD_SESSION_TOKEN and authorizes /api and
      # /api/ws directly. hermes desktop presents the same value in its
      # remote-gateway auth field -- read the luna copy at
      #      /run/agenix/hermes-gateway-token. the module insists on a runtime path
      #      (a nix store path would be world-readable) and 0600, which agenix
      #      gives us.
      sessionTokenFile = config.age.secrets.hermes-gateway-token.path;
    };

    settings = {
      # inference on the spark pair: phobos heads GLM-5.3-Flash EXL3 (4bpw,
      # deimos drafts), exposed on :8888 -- same endpoint luna's `spark` alias
      # uses. by IP because this box has no mDNS resolver (fresh nixos, no
      # avahi) and phobos's dhcp leases wander; if the lease moves, update
      # here -- or give bellona avahi and go back to phobos.local.
      model = {
        default = "GLM-5.3-Flash-EXL3";
        base_url = "http://192.168.2.159:8888/v1";
        provider = "custom";
        api_key = "local";
      };
    };

    # discord secrets stay out of the nix store. created by hand, chmod 0600:
    #   DISCORD_BOT_TOKEN, DISCORD_HOME_CHANNEL
    environmentFiles = [ "${config.home.homeDirectory}/.config/hermes/secrets.env" ];
  };
}
