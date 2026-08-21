{
  config,
  lib,
  ...
}:
let
  inherit (config.lib.stylix) colors;

  # Noctalia's colours, mapped from the active base16 scheme exactly as stylix's
  # own noctalia target does (modules/noctalia/hm.nix) -- with one deliberate
  # difference: the primary role.
  #
  # stylix uses base0D for mPrimary, and catppuccin-mocha fills base0D with
  # blue. The accent wanted here is lavender, which the scheme puts in base07.
  # Overriding base0D globally would fix the shell and break everything else:
  # that slot means "functions, methods, headings", so every editor and every
  # syntax highlighter would turn lavender too. Remapping the one role here is
  # the narrow fix, so stylix's colour aspect for noctalia is switched off
  # below and these values are supplied instead.
  accent = "base07";
  accentHex = colors.withHashtag.${accent};

  palette = with colors.withHashtag; {
    mPrimary = accentHex;
    mOnPrimary = base00;
    mSecondary = base0E;
    mOnSecondary = base00;
    mTertiary = base0C;
    mOnTertiary = base00;
    mError = base08;
    mOnError = base00;
    mSurface = base00;
    mOnSurface = base05;
    mSurfaceVariant = base01;
    mOnSurfaceVariant = base04;
    mOutline = base03;
    mShadow = base00;
    mHover = base02;
    mOnHover = base05;

    terminal = {
      normal = {
        black = base00;
        red = base08;
        green = base0B;
        yellow = base0A;
        blue = base0D;
        magenta = base0E;
        cyan = base0C;
        white = base05;
      };
      bright = {
        black = base03;
        red = base08;
        green = base0B;
        yellow = base0A;
        blue = base0D;
        magenta = base0E;
        cyan = base0C;
        white = base07;
      };
      foreground = base05;
      background = base00;
      cursor = accentHex;
      cursorText = base00;
      selectionFg = base05;
      selectionBg = base02;
    };
  };
in
{
  # Stylix keeps fonts, opacity and the wallpaper for noctalia; only the colour
  # aspect is taken over here. mk-target.nix generates a per-argument enable for
  # every aspect a target consumes, so this disables just that one function.
  stylix.targets.noctalia.colors.enable = false;

  programs.noctalia = {
    enable = true;
    systemd.enable = true;

    customPalettes.stylix-accent = {
      dark = palette;
      light = palette;
    };

    settings = {
      theme = {
        mode = "dark";
        source = "custom";
        custom_palette = "stylix-accent";

        # Every builtin template rewrites the target app's own config file to
        # add an include, and those files are read-only nix store symlinks
        # here. Colours reach other apps through stylix instead.
        templates = {
          enable_builtin_templates = false;
          enable_community_templates = false;
        };
      };

      shell = {
        # Replaces the polkit agent that nothing else was providing.
        polkit_agent = true;
        settings_show_advanced = true;
      };

      # Mirrors the module list waybar carried, in noctalia's widget names.
      # `position` is mkDefault because luna runs the bar along the bottom of
      # its portrait monitors (hosts/luna.nix); a plain value would conflict.
      bar.main = {
        position = lib.mkDefault "top";
        start = [
          "launcher"
          "workspaces"
          "active_window"
        ];
        center = [ "clock" ];
        end = [
          "tray"
          "sysmon"
          "brightness"
          "network"
          "bluetooth"
          "volume"
          "battery"
          "notifications"
          "control-center"
          "session"
        ];
      };

      notification.enable_daemon = true;

      lockscreen = {
        enabled = true;
        blurred_desktop = true;
      };

      wallpaper.enabled = true;
    };
  };

  # The window border follows base0D for the same reason the shell's primary
  # did; point it at the same accent so the frame matches the bar.
  wayland.windowManager.hyprland.settings.config.general."col.active_border" =
    lib.mkForce "rgb(${colors.${accent}})";

  # Hermes has the same base0D-is-blue problem: its stylix target defaults the
  # accent to that slot. Point it at the same one so the agent, the shell and
  # the window borders agree. Inert unless services.hermes-agent is enabled.
  #
  # This assumes ./stylix-hermes-agent.nix is imported alongside this file --
  # both come in together from home-graphical.nix. Importing this module on its
  # own would fail on an undefined option.
  stylix.targets.hermes-agent.accentColor = accentHex;
}
