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
  # the hermes-agent package is passed in rather than taken from an input of
  # mine: dollnet already has hermes-agent as a flake input for dahlia's
  # system-level instance, and reusing it keeps one copy of hermes-agent (and
  # one nixpkgs) in the closure instead of two. it also keeps this repo's
  # checkNixpkgsVersions check happy -- adding hermes-agent here would need
  # followsNixpkgs, which would evaluate its uv2nix python set against
  # nixpkgs-master rather than the nixpkgs it pins and tests against.

  imports = [
    ../hermes-agent.nix
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
    #     -> http://dollnet.giraffa-richter.ts.net:9119
    #
    # "dashboard" = "serve" (the /api/ws + /api/pty sockets desktop needs) plus
    # the browser admin panel on the same port. free on nix: the wrapper presets
    # HERMES_WEB_DIST to a prebuilt SPA, so the startup web build is skipped.
    #
    # bound to the magicdns name rather than an IP, for two reasons:
    #   1. the dashboard rejects any request whose Host header != the string it
    #      was bound to (DNS-rebinding defence, GHSA-ppp5-vxwm-4cf7). browsing to
    #      the name while bound to an IP gives "Invalid Host header".
    #   2. dollnet is shared into my tailnet, so it has a *different* address in
    #      each tailnet's view -- 100.80.221.70 in its own, 100.95.51.7 from
    #      luna. an IP resolved on the box is simply wrong for remote peers; the
    #      dns name resolves correctly from both sides.
    backend = {
      mode = "dashboard";
      hostname = "dollnet.giraffa-richter.ts.net";
      port = 9119;
    };

    settings = {
      # local inference via the ollama already running on this box
      model = {
        default = "qwen3.6:27b";
        base_url = "http://localhost:11434/v1";
        provider = "custom";
        api_key = "";
      };

      # nous portal oauth for the dashboard login gate.
      #
      # `hermes dashboard register` refuses to run here -- it bails on
      # is_managed(), on the assumption that a managed install gets its
      # client_id stamped in by whatever orchestrates it. that assumption is
      # right; nix IS the orchestrator, so the stamping happens here rather
      # than by letting the CLI write into .env (which activation truncates
      # every rebuild anyway).
      #
      # get the id from https://portal.nousresearch.com/local-dashboards --
      # register a dashboard with redirect uri
      #   http://dollnet.giraffa-richter.ts.net:9119/auth/callback
      # plain http is fine: the nous provider explicitly allows non-https
      # hosts and only requires the path end in /auth/callback.
      #
      # the plugin reads dashboard.oauth.client_id from config.yaml
      # (_resolve_client_id, precedence 2 behind the env var), and an empty
      # string means "no client_id configured" -- so the gate stays on
      # basic-auth until this is filled in.
      #
      # no dashboard.public_url needed: with the backend bound to the magicdns
      # name, the callback url the auth layer reconstructs from the request is
      # already correct.
      dashboard.oauth.client_id = "";
    };

    # secrets stay out of the nix store. created by hand, chmod 0600:
    #   DISCORD_BOT_TOKEN, DISCORD_HOME_CHANNEL
    #   HERMES_DASHBOARD_BASIC_AUTH_USERNAME
    #   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
    #   HERMES_DASHBOARD_BASIC_AUTH_SECRET  (stable, so desktop sessions
    #                                        survive a backend restart)
    environmentFiles = [ "${config.home.homeDirectory}/.config/hermes/secrets.env" ];
  };

  programs.beets = {
    enable = true;
    settings = {
      directory = "/mnt/storage/music-sorted";
      library = "/mnt/storage/music.db";
      import.move = true;
    };
  };
}
