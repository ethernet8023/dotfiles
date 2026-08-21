{ ... }:
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

  # Hermes Agent, for the desktop app.
  #
  # "serve" is the headless backend: the /api/ws + /api/pty sockets Hermes
  # Desktop attaches to, without building the browser admin panel. Loopback
  # only -- this machine is the client, so nothing needs to reach it over the
  # tailnet, and binding elsewhere would turn on the dashboard's auth gate.
  #
  # No gateway here: that is the messaging side (Telegram, Discord, ...) and it
  # is a separate process from the backend. dollnet runs that one.
  services.hermes-agent = {
    enable = true;
    backend = {
      mode = "serve";
      host = "127.0.0.1";
      port = 9119;
    };
  };
}
