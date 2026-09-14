{
  config,
  lib,
  pkgs,
  ...
}:
{
  # luna-specific home config: the desktop with two 27" monitors, both mounted
  # physically portrait -- a 4K on the right and a 1440p on the left.

  programs.noctalia.settings.bar.main.position = "bottom";

  wayland.windowManager.hyprland.settings.device = lib.mkMerge [
    [
      {
        name = "ploopy-corporation-ploopy-adept-trackball-mouse";
        # Custom accel profile: libinput IGNORES `sensitivity` under custom
        # (set-speed has no effect), so the slowdown is baked into the points.
        #
        # The sensor's true resolution is 12000 CPI, told to libinput via the
        # MOUSE_DPI hwdb rule in nixos/luna/configuration.nix. Before that
        # rule existed, libinput assumed 1000 dpi and normalized every delta
        # 12x oversized -- ALL accel/sensitivity tuning operated in the wrong
        # coordinate system and felt absurdly fast no matter the profile. If
        # tuning ever feels hopeless again, check `udevadm info -q property
        # -n /dev/input/eventN | grep MOUSE_DPI` FIRST.
        #
        # "custom <step> <points...>": f(x) = output speed at input speed x,
        # where x is RAW device units/ms (the custom profile bypasses libinput
        # DPI normalization entirely — at 12000 CPI, real hand speeds land
        # across x=0-30+ u/ms). This curve was sculpted BY HAND on 2026-09-03
        # with a live visualizer + slider rig (hyprctl eval applies instantly,
        # no rebuild/replug — use it to A/B before editing this file): gentle
        # low ramp for precision, steady climb through the medium range,
        # last-segment slope ((8-7.512)/2.2 ~= 0.22x) as the cruise factor.
        accel_profile = "custom 2.2 0.010725455777575553 0.027066619968138222 0.04987054844484621 0.11400618764267659 0.15755771097391608 0.2425425738956315 0.3767379683532114 0.6011738354029882 0.8768591742347696 1.2789678561514115 2.232807122433165 5.0133648028866045 6.624072807188476 6.744212988241895 7.512221021535088 8.000000000000004";
        scroll_factor = 0.3;
        natural_scroll = true;
      }
    ]
  ];

  # Hermes Agent. Upstream's home-manager module splits this in two, following
  # the home-manager convention: `programs.` installs things for me, `services.`
  # runs daemons. Both halves are wanted here -- luna is the machine I actually
  # sit at, so it gets the CLI, the desktop app, the gateway and the backend.
  #
  # (`services.hermes-agent.installPackage` used to cover the CLI. It is gone;
  # the module asserts on it rather than silently dropping `hermes` off PATH.)
  programs.hermes-agent = {
    enable = true; # `hermes` on PATH, and HERMES_HOME for interactive shells
    desktop.enable = true; # the Electron app + an XDG launcher entry
  };

  services.hermes-agent = {
    enable = true;

    # "serve" is the headless backend: the /api/ws + /api/pty sockets Hermes
    # Desktop attaches to, without building the browser admin panel. Loopback
    # only -- this machine is the client, so nothing needs to reach it over the
    # tailnet, and binding elsewhere would turn on the dashboard's auth gate.
    #
    # sessionTokenFile is what makes the desktop app share THIS backend rather
    # than spawning its own. The module keys the desktop wrapper off it: with a
    # token it exports HERMES_DESKTOP_REMOTE_URL + _TOKEN, and without one it
    # exports neither, because the desktop resolver throws outright when it
    # sees a URL and no token. So a tokenless backend here would leave two
    # backends running against one HERMES_HOME.
    #
    # Written by hand, chmod 0600, NOT through agenix: age secrets on this repo
    # decrypt to /run/agenix at *system* activation, and this is a home-manager
    # unit reading it as me. A plain file under ~/.config is the same trust
    # boundary as ~/.hermes/auth.json, which sits next to it unencrypted
    # anyway. Regenerate with:
    #   ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' \
    #       > ~/.config/hermes/session-token )
    backend = {
      mode = "serve";
      host = "127.0.0.1";
      port = 9119;
      sessionTokenFile = "${config.home.homeDirectory}/.config/hermes/session-token";
    };
  };

  programs.fish.shellAliases = {
    hs = "systemctl --user status hermes-agent hermes-backend";
    hlog = "journalctl --user -u hermes-agent -f";
    hblog = "journalctl --user -u hermes-backend -f";
  };

  # Live trackball curve editor for the Ploopy Adept (see the device block
  # above for how the custom accel profile works). `ploopy-curve` syncs its
  # starting curve from this file, serves the editor on 127.0.0.1:8799, and
  # pushes slider changes live via `hyprctl eval`. Winners get re-baked into
  # the accel_profile above. Editor assets live in ./ploopy-curve-editor/.
  home.file.".local/share/ploopy-curve-editor/server.py".source = ./ploopy-curve-editor/server.py;
  home.file.".local/share/ploopy-curve-editor/editor.html".source = ./ploopy-curve-editor/editor.html;
  home.packages = [
    (pkgs.writeShellScriptBin "ploopy-curve" (builtins.readFile ./ploopy-curve-editor/ploopy-curve.sh))
  ];
}
