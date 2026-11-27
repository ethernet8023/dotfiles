{
  config,
  pkgs,
  hermes-agent-package,
  cctrack-package,
  ...
}:
let
  # first-start config for qbittorrent-nox (the unit at the bottom)
  qbittorrentConf = pkgs.writeText "qBittorrent.conf" ''
    [LegalNotice]
    Accepted=true

    [Preferences]
    WebUI\Address=127.0.0.1
    WebUI\LocalHostAuth=false
  '';
  qbittorrentSeedConfig = pkgs.writeShellScript "qbittorrent-seed-config" ''
    conf="''${XDG_CONFIG_HOME:-$HOME/.config}/qBittorrent/qBittorrent.conf"
    [ -e "$conf" ] || ${pkgs.coreutils}/bin/install -Dm600 ${qbittorrentConf} "$conf"
  '';

  # headless Beeper Server runtime. nix-built rather than downloaded by
  # `beeper install server` -- see the beeper section below for why.
  beeperServer = pkgs.callPackage ../../nix/pkgs/beeper-server.nix { };
in
{
  # ethernet@bellona -- the complete home config for my account on dahlia's box.
  #
  # bellona is not my machine: it's dahlia's NixOS server (tailnet
  # giraffa-richter.ts.net) that lives upstairs, and i'm just a user on it with
  # an account in wheel. her flake imports ONE thing from this repo,
  # nixosModules.bellona (flake.in.nix), which brings in:
  #
  #   nixos/bellona-ether.nix   the root-level half: account, ssh keys, linger
  #                             (home-manager cannot set linger itself), and
  #                             this file as home-manager.users.ethernet
  #   hermes-agent + agenix     their hm modules (sharedModules) and the
  #                             hermes-agent package (extraSpecialArgs), all
  #                             from OUR lock

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

  # upstream's module splits installation from the daemon: `programs.` puts
  # `hermes` on PATH and exports HERMES_HOME, `services.` runs the units. the
  # old `services.hermes-agent.installPackage` covered both and is gone, which
  # is why `hermes` vanished off PATH here while the units kept running.
  # no desktop: bellona has no display. the package defaults to the services'
  # package, so the CLI and the units stay one build.
  programs.hermes-agent = {
    enable = true;
  };

  services.hermes-agent = {
    enable = true;
    package = hermes-agent-package;

    # deliberately NOT ~/.hermes: naming this one explicitly means a shell is
    # never ambiguous about which instance it's pointed at, and a stray
    # unconfigured `hermes` can't adopt this state.
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
      # inference on the spark pair: DeepSeek-V4.1-Flash-1017 (EXL3 2.9bpw,
      # tensor-parallel, phobos rank 0 + deimos rank 1), exposed on phobos
      # :8888 -- same endpoint luna's `spark` alias
      # uses. by IP because this box has no mDNS resolver (no avahi) and
      # phobos's dhcp leases wander; if the lease moves, update here -- or
      # give bellona avahi and go back to phobos.local.
      model = {
        default = "DeepSeek-V4.1-Flash-1017";
        base_url = "http://192.168.2.159:8888/v1";
        provider = "custom";
        api_key = "local";
      };
    };

    # discord secrets stay out of the nix store. created by hand, chmod 0600:
    #   DISCORD_BOT_TOKEN, DISCORD_HOME_CHANNEL
    environmentFiles = [ "${config.home.homeDirectory}/.config/hermes/secrets.env" ];
  };

  # qbittorrent-nox seeds the pirateface.co torrents in ~/pirateface-seeds. a
  # user unit so it reads my files with no sudo; linger (nixos/bellona-ether.nix)
  # keeps it running while i'm logged out.
  #
  # qbittorrent rewrites its own config at runtime, so that can't be a
  # read-only store symlink: ExecStartPre writes it only when it's missing, and
  # anything changed in the web UI sticks. both settings in it are for
  # pirateface's package.sh, which adds torrents through the web API with no
  # credentials: the UI listens on 127.0.0.1 only, and localhost skips the
  # login. the price: anything running on bellona can drive it.
  systemd.user.services.qbittorrent-nox = {
    Unit.Description = "qBittorrent-nox (pirateface seeding)";
    Service = {
      ExecStartPre = "${qbittorrentSeedConfig}";
      ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox --confirm-legal-notice --webui-port=8080";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # ── cctrack: CIBC statements + the budget UI ─────────────────────────────
  #
  # CIBC's Akamai edge drops headless browsers during the h2 handshake, so the
  # scraper has to be genuinely headed: it runs under cage, a real compositor
  # with no visible output.
  #
  # A user unit rather than a system service because linger keeps it alive
  # while i'm logged out, everything it writes is mine, and root on this box
  # is dahlia's -- the less it has to do, the better. The package itself is
  # built by this flake (nix/pkgs/cctrack.nix), so prod is a pinned rev.

  home.packages = [
    cctrack-package

    # the `beeper` CLI (nix/pkgs/beeper-cli.nix). nixpkgs only packages Beeper
    # Desktop, which needs a display; this is the headless path, and it's also
    # what installs and supervises the Beeper Server below.
    (pkgs.callPackage ../../nix/pkgs/beeper-cli.nix { })
  ];

  # The CIBC card number + password, agenix-decrypted to a runtime path. The
  # service reads it via CCTRACK_LOGIN_FILE: nothing enters the nix store and
  # nothing goes on a command line (world-readable in /proc).
  age.secrets.cctrack-cibc = {
    file = ../../secrets/cctrack-cibc.age;
  };

  # ── beeper: where CIBC's SMS sign-on code lands ──────────────────────────
  #
  # CIBC texts the code to the phone, it reaches Beeper's cloud, and cctrack
  # reads it from the client API on 127.0.0.1:23373 -- the port cctrack's
  # BeeperClient hardcodes, which is why the target gets pinned to it. Running
  # Beeper here rather than relaying hermes's API means a sync never depends on
  # a laptop being awake -- and hermes's copy binds 127.0.0.1, so it was never
  # reachable from this box anyway.
  #
  # This used to be Beeper Desktop under cage: an Electron app that wanted a
  # display, a profile rsynced from another machine, and a GUI sign-in. Beeper
  # Server is the headless runtime built for exactly this.
  #
  # the runtime comes from nix/pkgs/beeper-server.nix, NOT from
  # `beeper install server`: the CLI's download is a generic-linux binary with
  # interpreter /lib64/ld-linux-x86-64.so.2, which is stub-ld on NixOS, so it
  # dies before binding a port ("Could not start dynamically linked
  # executable"). autoPatchelf fixes that at build time without touching
  # dahlia's box (no nix-ld), and the version moves with the flake instead of
  # with a runtime download. BEEPER_SERVER_BIN is what makes the CLI run this
  # copy rather than its own on `targets start`; `beeper update --server` still
  # downloads into ~/.beeper and is ignored here -- bump the version instead.
  #
  # the unit is declared here, unlike `beeper targets enable server`, which
  # writes its own into ~/.config/systemd/user pointing at a symlink that
  # changes under it. this one can point at a store path because the path only
  # changes when this file does. don't run `targets enable` on top of it, or
  # there are two servers fighting for 23373. linger
  # (nixos/bellona-ether.nix) is what makes it survive logout, same as
  # everything else in this file.
  #
  # first run is a human pass -- the code arrives by email and device
  # verification is approved from another signed-in Beeper device (or with the
  # recovery key). the unit is already up, so nothing gets spawned.
  #
  # the sign-in is curl rather than `beeper auth email`: 0.6.4 ships a
  # desktop-api SDK from before /v1/app/setup, so that command dies with
  # "client.app.login.start is undefined" even though main has it. the setup
  # endpoints are public pre-login; `beeper verify` is raw HTTP and does work.
  # docs/cctrack.md has the calls:
  #
  #   beeper targets add server server --port 23373 --default
  #   POST /v1/app/setup/{start,email,response}   # -> matrix.accessToken
  #   jq '.auth = {...}' ~/.beeper/targets/server.json
  #   beeper verify
  #   cctrack beeper auth           # new instance, new token

  home.sessionVariables.BEEPER_SERVER_BIN = "${beeperServer}/bin/beeper-server";

  systemd.user.services.beeper-server = {
    Unit = {
      Description = "Beeper Server (SMS bridge for CIBC sign-on codes)";
      # capitalised on purpose: systemd keys are case-sensitive and nix passes
      # them through verbatim, so `after`/`wants` are silently ignored (the
      # cctrack unit had that bug until now).
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${beeperServer}/bin/beeper-server --host=127.0.0.1 --port=23373 --data-dir=%h/.beeper/profiles/server/server --server-env=production";
      # `beeper targets add server server` creates this dir; starting before
      # that is fine (empty server, unauthenticated) and the auth commands talk
      # to it over HTTP afterwards.
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/.beeper/profiles/server/server";
      Restart = "on-failure";
      RestartSec = 15;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.cctrack = {
    Unit = {
      Description = "cctrack: CIBC statements + budget UI (127.0.0.1:5001)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # A rejected login is the one failure that can lock the account, so the
      # in-process scheduler owns retries (exponential backoff, hard stop after
      # four). These limits only stop a crash loop.
      StartLimitIntervalSec = 3600;
      StartLimitBurst = 5;
    };
    Service = {
      ExecStart = "${pkgs.cage}/bin/cage -- ${cctrack-package}/bin/cctrack serve --host 127.0.0.1 --port 5001 --auto-sync --every 360";
      # .sesskey and the downloaded CSVs have to land somewhere writable: the
      # package lives in /nix/store, and downloads_dir() defaults to the
      # checkout next to the package.
      WorkingDirectory = "%h/.local/share/cctrack";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/.local/share/cctrack/downloads";
      Environment = [
        # systemd does not expand shell-style $VAR references in Environment=;
        # it expands only %-specifiers. agenix's path option is the literal
        # string "${XDG_RUNTIME_DIR}/agenix/..." (the activation script expands
        # it in its own shell), so handing that to the unit reaches cctrack
        # unexpanded and every sync dies on a missing login file. %t is the
        # user manager's runtime dir, which is exactly where agenix installs it.
        "CCTRACK_LOGIN_FILE=%t/agenix/${config.age.secrets.cctrack-cibc.name}"
        "CCTRACK_DOWNLOADS=%h/.local/share/cctrack/downloads"
        "WLR_BACKENDS=headless"
        "WLR_LIBINPUT_NO_DEVICES=1"
      ];
      Restart = "on-failure";
      RestartSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
