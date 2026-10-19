{
  config,
  pkgs,
  ...
}:
let
  # Same cursor noctalia.nix switches between at runtime; the greeter has no
  # hook to follow the light/dark toggle, so it gets the dark variant.
  cursors = import ../home-manager/cursors-data.nix { inherit pkgs; };
in
{
  services.displayManager.noctalia-greeter = {
    enable = true;

    cursorTheme = {
      inherit (cursors.dark) package name;
    };

    # Lets noctalia's "Sync Now" push wallpaper, palette and monitor layout to
    # the login screen without a polkit prompt. Appearance-only: the
    # constrained sync never accepts session commands.
    passwordlessSyncUsers = [ config.me.username ];

    settings = {
      # programs.hyprland.withUWSM leaves two entries in the picker; the bare
      # "Hyprland" one skips uwsm, so pin the managed one. Matched on Name=
      # (see `noctalia-greeter sessions`).
      session.default = "Hyprland (uwsm-managed)";
      cursor.size = cursors.size;
      keyboard.layout = config.services.xserver.xkb.layout;
    };
  };
}
