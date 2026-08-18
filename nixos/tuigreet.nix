{
  config,
  lib,
  pkgs,
  ...
}:
let
  # programs.hyprland.withUWSM is on, so the launch line for a systemd-managed
  # Hyprland already exists: the hyprland package ships hyprland-uwsm.desktop,
  # whose Exec= runs the compositor through uwsm. Point at that file directly
  # rather than restating its command here, so the launch line stays owned by
  # the package and follows it across updates.
  uwsmSession = "${config.programs.hyprland.package}/share/wayland-sessions/hyprland-uwsm.desktop";

  # tuigreet has no "default session" option: with no --cmd it takes
  # sessions[0] after sorting entries by Name (info.rs get_sessions). Handing
  # it a directory holding only this entry makes the uwsm session both the
  # only choice and index 0.
  #
  # NixOS otherwise collects every entry from
  # services.displayManager.sessionPackages into one directory, and that
  # includes the bare hyprland.desktop that withUWSM supersedes. "Hyprland"
  # sorts before "Hyprland (uwsm-managed)", so pointing tuigreet at the
  # collected directory would default to the NON-uwsm session.
  sessions = pkgs.runCommand "tuigreet-wayland-sessions" { } ''
    mkdir -p "$out"
    # cp rather than ln -s: a symlink to a missing target is created happily,
    # and an empty session directory would leave the greeter with nothing to
    # launch. This fails the build instead if the entry ever moves.
    cp ${uwsmSession} "$out/"
  '';

  greeting = "access is restricted to authorized personnel only.";
in
{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        # No --cmd. tuigreet reads Exec= out of the desktop file and derives
        # XDG_SESSION_DESKTOP, DESKTOP_SESSION, XDG_SESSION_TYPE and
        # XDG_CURRENT_DESKTOP from its other keys (ipc.rs
        # wrap_session_command), which a bare --cmd string cannot supply.
        command = lib.concatStringsSep " " [
          (lib.getExe pkgs.tuigreet)
          "--sessions ${lib.escapeShellArg sessions}"
          "--remember"
          "--remember-user-session"
          "-g ${lib.escapeShellArg greeting}"
        ];
        user = "greeter";
      };
    };
  };

  systemd.services.greetd.serviceConfig = {
    Type = "idle";
    StandardInput = "tty";
    StandardOutput = "tty";
    StandardError = "journal"; # Without this errors will spam on screen
    # Without these bootlogs will spam on screen
    TTYReset = true;
    TTYVHangup = true;
    TTYVTDisallocate = true;
  };
}
