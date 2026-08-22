{ config, ... }:
{
  # luna-specific home config: the desktop with two 4K monitors, both mounted
  # physically portrait (transform 3, see ../hyprland.nix).
  #
  # Only differences from the shared graphical config belong here. Everything
  # else comes from home-graphical.nix.

  # A bar down the long edge of a portrait monitor eats a lot of vertical
  # space, and the short edge is cheap -- so run it along the bottom rather
  # than the top like the laptop does.
  programs.noctalia.settings.bar.main.position = "bottom";

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
}
