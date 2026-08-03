# home-manager/hermes-agent.nix — home-manager module for Hermes Agent
#
# User-level counterpart to hermes-agent's upstream `nixosModules.default`
# (github:NousResearch/hermes-agent, nix/nixosModules.nix). Upstream ships no
# home-manager module, so this is a port with the system-scope concerns removed:
#
#   dropped   user / group / createUser  — home-manager already runs as the user
#   dropped   container.*                — needs root and the docker socket
#   dropped   UMask 0007                 — that exists to share state with a
#                                          unix group; user state is single-user
#   reshaped  systemd.services           -> systemd.user.services
#   reshaped  system.activationScripts   -> home.activation
#   reshaped  addToSystemPackages        -> installPackage + home.sessionVariables
#   reshaped  stateDir (+ "/.hermes")    -> hermesHome, set directly
#
# Added beyond upstream: a `backend` unit for `hermes serve` / `hermes dashboard`.
# Upstream models only the messaging gateway, but Hermes Desktop connects to a
# serve/dashboard backend, which is a different process. The relationship:
#
#   dashboard = serve + web SPA     (same entrypoint, one flag apart —
#                                    mutually exclusive, hence backend.mode)
#   gateway                         (independent process; NOT run by either)
#
# Both units share one HERMES_HOME so sessions, skills, memory, and cron are
# common between them.
#
# `package` is a required option rather than being pulled from a flake input, so
# this module is self-contained and can be consumed from any flake (see
# homeManagerModules in flake.in.nix).
#
# NOT expressible in home-manager: `loginctl enable-linger`. Without linger the
# systemd user manager is torn down on logout and both units die with it. Set
#   users.users.<name>.linger = true;
# on the NixOS side. This module emits a warning if it can't be verified.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hermes-agent;

  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;

  # ── Deep-merge config type ──────────────────────────────────────────────
  # Same semantics as upstream so several `settings = { ... }` definitions
  # compose via recursiveUpdate instead of the last one winning.
  deepConfigType = types.mkOptionType {
    name = "hermes-config-attrs";
    description = "Hermes YAML config (attrset), merged deeply via lib.recursiveUpdate.";
    check = builtins.isAttrs;
    merge = _loc: defs: lib.foldl' lib.recursiveUpdate { } (map (d: d.value) defs);
  };

  # terminal.cwd replaces the deprecated MESSAGING_CWD env var. recursiveUpdate
  # ordering means an explicit settings.terminal.cwd overrides the default.
  configJson = builtins.toJSON (
    lib.recursiveUpdate { terminal.cwd = cfg.workingDirectory; } cfg.settings
  );
  generatedConfigFile = pkgs.writeText "hermes-config.yaml" configJson;
  configFile = if cfg.configFile != null then cfg.configFile else generatedConfigFile;

  # ── config.yaml deep-merge on activation ────────────────────────────────
  # Lifted from upstream nix/configMergeScript.nix. This is load-bearing:
  # hermes writes config.yaml at runtime (`hermes config set`, the TUI/desktop
  # settings panes), so the module must MERGE rather than overwrite. Declaring
  # it as a read-only home.file store symlink would break every in-app save.
  # Nix keys win; user-added keys are preserved.
  configMergeScript = pkgs.writeScript "hermes-config-merge" ''
    #!${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3
    import json, yaml, sys
    from pathlib import Path

    nix_json, config_path = sys.argv[1], Path(sys.argv[2])

    with open(nix_json) as f:
        nix = json.load(f)

    existing = {}
    if config_path.exists():
        with open(config_path) as f:
            existing = yaml.safe_load(f) or {}

    def deep_merge(base, override):
        result = dict(base)
        for k, v in override.items():
            if k in result and isinstance(result[k], dict) and isinstance(v, dict):
                result[k] = deep_merge(result[k], v)
            else:
                result[k] = v
        return result

    merged = deep_merge(existing, nix)
    with open(config_path, "w") as f:
        yaml.dump(merged, f, default_flow_style=False, sort_keys=False)
  '';

  # ── .env assembly ───────────────────────────────────────────────────────
  # Non-secret values from `environment`; secrets are concatenated at
  # activation time from `environmentFiles` so they never enter the store.
  envFileContent = lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") cfg.environment);

  # ── documents (SOUL.md and friends) ─────────────────────────────────────
  documentDerivation = pkgs.runCommand "hermes-documents" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: value:
        if builtins.isPath value || lib.isStorePath value then
          "cp ${value} $out/${name}"
        else
          "cat > $out/${name} <<'HERMES_DOC_EOF'\n${value}\nHERMES_DOC_EOF"
      ) cfg.documents
    )
  );

  # ── MCP server config ───────────────────────────────────────────────────
  mcpJson = builtins.toJSON {
    mcpServers = lib.mapAttrs (
      _: srv:
      (lib.optionalAttrs (srv.command != null) {
        inherit (srv) command args env;
      })
      // (lib.optionalAttrs (srv.url != null) {
        inherit (srv) url headers;
      })
      // lib.optionalAttrs (srv.auth != null) { inherit (srv) auth; }
    ) cfg.mcpServers;
  };
  mcpConfigFile = pkgs.writeText "hermes-mcp.json" mcpJson;

  # Shared unit scaffolding for both the gateway and serve units.
  commonServiceConfig = {
    Restart = cfg.restart;
    RestartSec = cfg.restartSec;
    WorkingDirectory = cfg.workingDirectory;
    # Single-user state: keep it private rather than upstream's group-shared 0007.
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
  };

  commonEnvironment = {
    HERMES_HOME = cfg.hermesHome;
    HERMES_MANAGED = "true";
  };

  unitPath = [
    cfg.package
    pkgs.bash
    pkgs.coreutils
    pkgs.git
  ]
  ++ cfg.extraPackages;

  # ── Backend launcher ────────────────────────────────────────────────────
  # With backend.interface set, the bind address cannot be known at build time,
  # so ExecStart becomes a small wrapper that resolves it at start. It waits for
  # the interface because a systemd *user* unit has no way to order itself after
  # a system unit like tailscaled.service — After=/Requires= silently do nothing
  # across that boundary, so polling is the only correct option.
  #
  # `exec` at the end keeps hermes as the unit's MainPID: no extra shell in the
  # cgroup, and systemd's restart/status logic tracks the real process.
  backendLauncher = pkgs.writeShellScript "hermes-backend-launch" ''
    set -euo pipefail

    _iface=${lib.escapeShellArg (toString cfg.backend.interface)}
    _timeout=${toString cfg.backend.interfaceTimeout}
    _waited=0

    while :; do
      _addr="$(${pkgs.iproute2}/bin/ip -4 -oneline addr show dev "$_iface" 2>/dev/null \
                 | ${pkgs.gawk}/bin/awk '{print $4}' \
                 | ${pkgs.coreutils}/bin/cut -d/ -f1 \
                 | ${pkgs.coreutils}/bin/head -n1 || true)"

      if [ -n "''${_addr:-}" ]; then
        break
      fi

      if [ "$_waited" -ge "$_timeout" ]; then
        echo "hermes-backend: interface '$_iface' had no IPv4 address after ''${_timeout}s; refusing to start." >&2
        echo "hermes-backend: binding to a fallback address could expose the backend more broadly than intended." >&2
        exit 1
      fi

      if [ "$_waited" = 0 ]; then
        echo "hermes-backend: waiting for '$_iface' to acquire an IPv4 address..." >&2
      fi
      ${pkgs.coreutils}/bin/sleep 2
      _waited=$(( _waited + 2 ))
    done

    echo "hermes-backend: binding to $_addr:${toString cfg.backend.port} (from $_iface)" >&2

    exec ${cfg.package}/bin/hermes ${cfg.backend.mode} \
      --host "$_addr" \
      --port ${toString cfg.backend.port} \
      --no-open \
      ${lib.escapeShellArgs cfg.backend.extraArgs}
  '';

  backendExecStart =
    if cfg.backend.interface != null then
      "${backendLauncher}"
    else
      lib.escapeShellArgs (
        [
          "${cfg.package}/bin/hermes"
          cfg.backend.mode
          "--host"
          cfg.backend.host
          "--port"
          (toString cfg.backend.port)
          # Headless service: never try to open a browser on activation.
          "--no-open"
        ]
        ++ cfg.backend.extraArgs
      );

in
{
  options.services.hermes-agent = {
    enable = mkEnableOption "Hermes Agent (user-level, home-manager)";

    package = mkOption {
      type = types.package;
      description = "The hermes-agent package to use.";
    };

    hermesHome = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.hermes";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.hermes"'';
      description = ''
        Value of HERMES_HOME — the state directory holding config.yaml, .env,
        auth.json, sessions, skills, memory, and cron.

        Upstream's NixOS module takes a `stateDir` and appends `/.hermes`; this
        module sets HERMES_HOME directly so the directory can be named freely.
      '';
      example = "/home/ethernet/.ethernet-hermes";
    };

    workingDirectory = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}";
      defaultText = lib.literalExpression "config.home.homeDirectory";
      description = "Working directory for the agent (also written as terminal.cwd).";
    };

    installPackage = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add the hermes CLI to home.packages and export HERMES_HOME via
        home.sessionVariables, so interactive shells share state with the
        services.

        Upstream's equivalent (`addToSystemPackages`) exports HERMES_HOME
        through environment.variables, which is system-wide and clobbers every
        user's HERMES_HOME. Scoping it to this user's session is the point of
        doing this in home-manager.
      '';
    };

    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Explicit config.yaml. When set it is installed verbatim (overwriting on
        every activation) instead of deep-merging `settings`.
      '';
    };

    settings = mkOption {
      type = deepConfigType;
      default = { };
      description = ''
        config.yaml contents as a Nix attrset. Deep-merged into any existing
        config.yaml on activation: these keys win, keys you set at runtime via
        `hermes config set` or the GUI are preserved.
      '';
      example = lib.literalExpression ''
        {
          model.default = "anthropic/claude-sonnet-4";
          display.skin = "synthwave";
        }
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Non-secret environment variables written to $HERMES_HOME/.env.
        Do NOT put credentials here — they would land in the world-readable
        Nix store. Use `environmentFiles` for secrets.
      '';
    };

    environmentFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = ''
        Files containing secrets (API keys, tokens), concatenated into
        $HERMES_HOME/.env at activation. Read outside the store, so agenix /
        sops-nix output paths are safe here.
      '';
    };

    authFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Seed file for auth.json (OAuth credentials). Only copied when auth.json
        does not already exist, so tokens refreshed at runtime survive.
      '';
    };

    authFileForceOverwrite = mkOption {
      type = types.bool;
      default = false;
      description = "Always overwrite auth.json from authFile on activation.";
    };

    documents = mkOption {
      type = types.attrsOf (types.either types.str types.path);
      default = { };
      description = "Files to place in $HERMES_HOME (e.g. SOUL.md), as strings or paths.";
    };

    mcpServers = mkOption {
      default = { };
      description = "MCP servers, written to $HERMES_HOME/mcp.json.";
      type = types.attrsOf (
        types.submodule {
          options = {
            command = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Server command (stdio transport).";
            };
            args = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Command arguments (stdio transport).";
            };
            env = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Environment for the server process (stdio transport).";
            };
            url = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Endpoint URL (HTTP/StreamableHTTP transport).";
            };
            headers = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "HTTP headers, e.g. for auth (HTTP transport).";
            };
            auth = mkOption {
              type = types.nullOr (types.enum [ "oauth" ]);
              default = null;
              description = ''
                Set to "oauth" for the OAuth 2.1 PKCE flow (remote MCP servers).
                Tokens are stored in $HERMES_HOME/mcp-tokens/.
              '';
            };
          };
        }
      );
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages on the services' PATH (tools the agent can call).";
    };

    restart = mkOption {
      type = types.str;
      default = "on-failure";
      description = ''
        systemd Restart= policy.

        Defaults to on-failure rather than upstream's "always": a misconfigured
        unit under Restart=always crash-loops indefinitely and shreds the
        journal. on-failure still respects systemd's start-limit backoff.
      '';
    };

    restartSec = mkOption {
      type = types.either types.int types.str;
      default = 10;
      description = "systemd RestartSec=.";
    };

    # ── Gateway (messaging channels) ──────────────────────────────────────
    gateway = {
      enable = mkEnableOption "the messaging gateway service (Telegram, Discord, Slack, ...)";

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments for `hermes gateway`.";
      };
    };

    # ── Backend: serve / dashboard ────────────────────────────────────────
    # Not present upstream, which models only the gateway.
    #
    # `hermes serve` and `hermes dashboard` are the SAME entrypoint
    # (hermes_cli/main.py:cmd_dashboard) separated by one flag: serve sets
    # HERMES_SERVE_HEADLESS=1 and skips the web SPA build, dashboard builds and
    # mounts it. Both call the same start_server() and both expose the
    # /api/ws + /api/pty sockets that Hermes Desktop attaches to. So:
    #
    #   dashboard = serve + web UI
    #
    # They are one process and mutually exclusive — hence a `mode` enum rather
    # than two booleans.
    #
    # The gateway is NOT part of this chain. web_server.py only ever reaches a
    # gateway via `_spawn_gateway_restart()` (subprocess.Popen of
    # `hermes gateway restart`) — it *controls* an external gateway, it does not
    # embed one. web_server.py:154 says so outright: "desktop app spawns a
    # `hermes dashboard` backend, not a gateway". Messaging channels therefore
    # need `gateway.enable = true` alongside whichever backend mode you pick.
    backend = {
      mode = mkOption {
        type = types.enum [
          "none"
          "serve"
          "dashboard"
        ];
        default = "none";
        description = ''
          Which backend process to run for Hermes Desktop / the web UI.

          - "none"      — no backend (messaging gateway only)
          - "serve"     — headless backend: the /api/ws + /api/pty sockets the
                          desktop app needs, without building the web SPA.
                          Cheapest option for a desktop-only setup.
          - "dashboard" — everything "serve" provides plus the browser admin
                          panel served from the same port.

          "dashboard" is a strict superset of "serve". Neither one runs the
          messaging gateway — set `gateway.enable` for that.
        '';
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Bind address. Binding to a non-loopback address automatically engages
          the auth gate, so credentials must be configured for the desktop app
          to get through (HERMES_DASHBOARD_BASIC_AUTH_* for username/password,
          or the Nous Portal OAuth provider).

          Ignored when `interface` is set, which resolves the address at
          service start instead.
        '';
        example = "100.80.221.70";
      };

      interface = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Resolve the bind address from this network interface's first IPv4
          address at service start, instead of hardcoding `host`.

          Intended for Tailscale ("tailscale0"), whose address is stable in
          practice but is an opaque literal in the config and would silently
          become wrong if the tailnet were rebuilt or the node re-added.

          Because a systemd *user* unit cannot order itself after a system unit
          like tailscaled.service, the wrapper polls for the interface to come
          up (see `interfaceTimeout`) rather than assuming it is ready.
        '';
        example = "tailscale0";
      };

      interfaceTimeout = mkOption {
        type = types.int;
        default = 120;
        description = ''
          Seconds to wait for `interface` to acquire an IPv4 address before
          failing the unit. Polled every 2s.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 9119;
        description = "Listen port.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments for `hermes serve` / `hermes dashboard`.";
      };
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.gateway.enable || cfg.backend.mode != "none" || cfg.installPackage;
            message = ''
              services.hermes-agent is enabled but nothing would be produced:
              enable gateway, set backend.mode, or leave installPackage on.
            '';
          }
          {
            # Non-loopback bind engages the dashboard auth gate; without
            # credentials the desktop app has no provider to sign in against.
            # An `interface` bind is treated as non-loopback: the address is not
            # known until start, so it cannot be proven safe here.
            assertion =
              (cfg.backend.mode == "none")
              || (
                cfg.backend.interface == null
                && (cfg.backend.host == "127.0.0.1" || cfg.backend.host == "localhost")
              )
              || cfg.environmentFiles != [ ]
              || cfg.environment ? HERMES_DASHBOARD_BASIC_AUTH_USERNAME
              || cfg.environment ? HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH;
            message = ''
              services.hermes-agent.backend binds a non-loopback address
              (${
                if cfg.backend.interface != null then
                  "resolved from interface ${cfg.backend.interface}"
                else
                  cfg.backend.host
              }), which engages the dashboard auth gate,
              but no credentials are configured. Hermes Desktop will have no
              provider to sign in against.

              Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME / _PASSWORD (and a stable
              _SECRET so sessions survive restarts) via environmentFiles, or
              register OAuth with `hermes dashboard register`.
            '';
          }
        ];

        warnings =
          lib.optional
            (
              cfg.environment != { }
              && lib.any (v: v != "") (
                lib.attrValues (
                  lib.filterAttrs (
                    n: _:
                    lib.hasInfix "TOKEN" n
                    || lib.hasInfix "KEY" n
                    || lib.hasInfix "SECRET" n
                    || lib.hasInfix "PASSWORD" n
                  ) cfg.environment
                )
              )
            )
            ''
              services.hermes-agent.environment contains what looks like a
              credential. Values here are written into the world-readable Nix
              store — use environmentFiles instead.
            ''
          ++
            lib.optional
              ((cfg.gateway.enable || cfg.backend.mode != "none") && !config.systemd.user.startServices)
              ''
                services.hermes-agent defines user services but
                systemd.user.startServices is off, so they will not start until the
                next login or an explicit `systemctl --user start`.
              ''
          # The most likely misconfiguration: assuming a backend covers messaging.
          # `hermes serve`/`dashboard` never runs a gateway, so Discord/Telegram
          # would simply be offline with no error anywhere.
          ++ lib.optional (cfg.backend.mode != "none" && !cfg.gateway.enable) ''
            services.hermes-agent.backend.mode is "${cfg.backend.mode}" but
            gateway.enable is false. The backend serves Hermes Desktop and the
            web UI only — it does NOT run the messaging gateway, so Discord /
            Telegram / Slack channels will be offline.

            Set services.hermes-agent.gateway.enable = true if you want them.
          '';
      }

      # ── CLI on PATH + session HERMES_HOME ─────────────────────────────────
      (mkIf cfg.installPackage {
        home.packages = [ cfg.package ];
        home.sessionVariables.HERMES_HOME = cfg.hermesHome;
      })

      # ── State directory, config, secrets, documents ───────────────────────
      {
        home.activation.hermes-agent-setup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          _hermesHome=${lib.escapeShellArg cfg.hermesHome}

          $DRY_RUN_CMD mkdir -p "$_hermesHome"
          $DRY_RUN_CMD chmod 0700 "$_hermesHome"
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg cfg.workingDirectory}

          for _subdir in cron sessions logs memories plugins skills; do
            $DRY_RUN_CMD mkdir -p "$_hermesHome/$_subdir"
          done

          # config.yaml — merge, never clobber (hermes writes this at runtime).
          ${
            if cfg.configFile != null then
              ''
                $DRY_RUN_CMD install -m 0600 ${configFile} "$_hermesHome/config.yaml"
              ''
            else
              ''
                $DRY_RUN_CMD ${configMergeScript} ${generatedConfigFile} "$_hermesHome/config.yaml"
                $DRY_RUN_CMD chmod 0600 "$_hermesHome/config.yaml"
              ''
          }

          # Marker so interactive shells detect declarative management.
          $DRY_RUN_CMD touch "$_hermesHome/.managed"

          # .env — non-secret values from Nix, then secrets appended from files
          # outside the store.
          $DRY_RUN_CMD install -m 0600 /dev/null "$_hermesHome/.env"
          ${lib.optionalString (cfg.environment != { }) ''
            $DRY_RUN_CMD cat > "$_hermesHome/.env" <<'HERMES_ENV_EOF'
            ${envFileContent}
            HERMES_ENV_EOF
          ''}
          ${lib.concatMapStringsSep "\n" (f: ''
            if [ -r ${lib.escapeShellArg f} ]; then
              $DRY_RUN_CMD sh -c 'cat ${lib.escapeShellArg f} >> "$1"' _ "$_hermesHome/.env"
              $DRY_RUN_CMD sh -c 'printf "\n" >> "$1"' _ "$_hermesHome/.env"
            else
              echo "hermes-agent: WARNING cannot read environmentFile ${f}" >&2
            fi
          '') cfg.environmentFiles}
          $DRY_RUN_CMD chmod 0600 "$_hermesHome/.env"

          ${lib.optionalString (cfg.authFile != null) ''
            if ${if cfg.authFileForceOverwrite then "true" else ''[ ! -e "$_hermesHome/auth.json" ]''}; then
              $DRY_RUN_CMD install -m 0600 ${cfg.authFile} "$_hermesHome/auth.json"
            fi
          ''}

          ${lib.optionalString (cfg.documents != { }) ''
            $DRY_RUN_CMD cp -f ${documentDerivation}/* "$_hermesHome/"
            $DRY_RUN_CMD chmod 0600 "$_hermesHome"/*.md || true
          ''}

          ${lib.optionalString (cfg.mcpServers != { }) ''
            $DRY_RUN_CMD install -m 0600 ${mcpConfigFile} "$_hermesHome/mcp.json"
          ''}
        '';
      }

      # ── Messaging gateway unit ────────────────────────────────────────────
      (mkIf cfg.gateway.enable {
        systemd.user.services.hermes-agent = {
          Unit = {
            Description = "Hermes Agent Gateway";
            # No network-online.target here: that is a system target and is not
            # reachable from the user manager.
            After = [ "default.target" ];
          };
          Install.WantedBy = [ "default.target" ];
          Service = commonServiceConfig // {
            Environment = (lib.mapAttrsToList (k: v: "${k}=${v}") commonEnvironment) ++ [
              "PATH=${lib.makeBinPath unitPath}"
            ];
            ExecStart = lib.escapeShellArgs (
              [
                "${cfg.package}/bin/hermes"
                "gateway"
              ]
              ++ cfg.gateway.extraArgs
            );
          };
        };
      })

      # ── Backend unit (serve / dashboard) ──────────────────────────────────
      (mkIf (cfg.backend.mode != "none") {
        systemd.user.services.hermes-backend = {
          Unit = {
            Description =
              if cfg.backend.mode == "dashboard" then
                "Hermes Agent web dashboard + desktop backend (hermes dashboard)"
              else
                "Hermes Agent backend for Hermes Desktop (hermes serve)";
            After = [ "default.target" ];
          };
          Install.WantedBy = [ "default.target" ];
          Service = commonServiceConfig // {
            Environment = (lib.mapAttrsToList (k: v: "${k}=${v}") commonEnvironment) ++ [
              "PATH=${lib.makeBinPath unitPath}"
            ];
            ExecStart = backendExecStart;
          };
        };
      })
    ]
  );
}
