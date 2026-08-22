{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # Noctalia's colours, mapped from a base16 scheme exactly as stylix's own
  # noctalia target does (modules/noctalia/hm.nix) -- with one deliberate
  # difference: the primary role.
  #
  # stylix uses base0D for mPrimary, and catppuccin fills base0D with blue. The
  # accent wanted here is lavender, which the scheme puts in base07. Overriding
  # base0D globally would fix the shell and break everything else: that slot
  # means "functions, methods, headings", so every editor and every syntax
  # highlighter would turn lavender too. Remapping the one role here is the
  # narrow fix, so stylix's colour aspect for noctalia is switched off below and
  # these values are supplied instead.
  accent = "base07";
  accentHex = config.lib.stylix.colors.withHashtag.${accent};

  mkPalette =
    colors: with colors.withHashtag; {
      mPrimary = colors.withHashtag.${accent};
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
        cursor = colors.withHashtag.${accent};
        cursorText = base00;
        selectionFg = base05;
        selectionBg = base02;
      };
    };

  # The light half of the toggle, shared with ghostty.nix and vscode.nix. See
  # base16-light.nix for why a second scheme has to be built by hand.
  #
  # This palette themes the SHELL. The same scheme reaches the terminal and the
  # editor through their own targets, all keyed off the one dconf value
  # noctalia writes on a mode toggle.
  lightColors = import ./base16-light.nix { inherit pkgs inputs; };
in
{
  # Stylix keeps fonts, opacity and the wallpaper for noctalia; the colour and
  # polarity aspects are taken over here. mk-target.nix generates a per-argument
  # enable for every aspect a target consumes, so this disables just those two.
  stylix.targets.noctalia.colors.enable = false;
  stylix.targets.noctalia.polarity.enable = false;

  programs.noctalia = {
    enable = true;
    systemd.enable = true;

    customPalettes.stylix-accent = {
      dark = mkPalette config.lib.stylix.colors;
      light = mkPalette lightColors;
    };

    settings = {
      theme = {
        # The starting mode only. `noctalia msg theme-mode-toggle` (mod+T, the
        # bar widget, the control-center tile) persists the user's choice into
        # the state dir's settings.toml, which is layered over this file at
        # load, so a toggle survives both a restart and a rebuild.
        #
        # stylix's noctalia target writes this key too, from stylix.polarity.
        # Same value, but its definition and this one would collide, so its
        # polarity aspect is switched off alongside colours below.
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

        # stylix's noctalia target fills dock, notification and osd from
        # stylix.opacity (modules/noctalia/hm.nix), and nothing else. The
        # panels and the bar have no stylix aspect, so they stay opaque
        # unless set here and in bar.main below.
        #
        # `glass` is noctalia's own translucency preset: a detached panel
        # background drops to 0.55 and panel cards to 0.62-0.75
        # (detachedPanelBackgroundOpacityForTransparencyMode in
        # src/config/config_types.cpp). Both clear the layer rule's
        # ignore_alpha floor in hyprland.nix, so hyprland blurs them.
        panel.transparency_mode = "glass";
      };

      # Mirrors the module list waybar carried, in noctalia's widget names.
      # `position` is mkDefault because luna runs the bar along the bottom of
      # its portrait monitors (hosts/luna.nix); a plain value would conflict.
      bar.main = {
        position = lib.mkDefault "top";
        background_opacity = 0.75;
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
          "theme_mode"
          "notifications"
          "control-center"
          "session"
        ];
      };

      # The control centre's tile grid. Declaring the array replaces noctalia's
      # default set outright (config_types.cpp defaultControlCenterShortcuts),
      # so the six defaults are repeated here to keep them, with the light/dark
      # tile added -- it is a builtin type, just not on by default.
      control_center.shortcuts = map (type: { inherit type; }) [
        "wifi"
        "bluetooth"
        "caffeine"
        "nightlight"
        "dark_mode"
        "notification"
        "power_profile"
      ];

      notification.enable_daemon = true;

      # Ghostty resolves its `light:,dark:` theme pair only when it reads its
      # config; it does not repaint when the appearance portal changes under a
      # running process (see ghostty.nix). Noctalia already writes the portal
      # value on a mode toggle, so this hook additionally pokes ghostty to
      # re-read, which is what actually swaps the palette.
      #
      # The pid comes from ghostty's own D-Bus name rather than a name match:
      # the process `comm` is the truncated wrapper `.ghostty-wrappe`, so
      # `pkill -x ghostty` matches nothing, and `pkill -f ghostty` would match
      # unrelated shells. With gtk-single-instance = detect, every window
      # launched from the desktop or a compositor bind belongs to the one
      # instance that owns this name, so signalling it covers them all.
      #
      # Exits 0 when ghostty is not running: a hook that fails on every toggle
      # would be noise.
      hooks.theme_mode_changed = [
        ''
          ${lib.getExe' pkgs.systemd "busctl"} --user status com.mitchellh.ghostty 2>/dev/null \
            | ${lib.getExe' pkgs.gawk "awk"} '/^PID=/ { sub("PID=", ""); print $1 }' \
            | ${lib.getExe' pkgs.findutils "xargs"} -r ${lib.getExe' pkgs.util-linux "kill"} -USR2 || true
        ''
      ];

      lockscreen = {
        enabled = true;
        blurred_desktop = true;
      };

      wallpaper.enabled = true;
    };
  };

  # The window border follows base0D for the same reason the shell's primary
  # did; point it at the same accent so the frame matches the bar.
  wayland.windowManager.hyprland.settings.config.general."col.active_border" = lib.mkForce "rgb(${
    config.lib.stylix.colors.${accent}
  })";

  # Hermes has the same base0D-is-blue problem: its stylix target defaults the
  # accent to that slot. Point it at the same one so the agent, the shell and
  # the window borders agree. Inert unless services.hermes-agent is enabled.
  #
  # This assumes ./stylix-hermes-agent.nix is imported alongside this file --
  # both come in together from home-graphical.nix. Importing this module on its
  # own would fail on an undefined option.
  stylix.targets.hermes-agent.accentColor = accentHex;
}
