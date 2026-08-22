{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # Noctalia's colours, mapped from a base16 scheme -- with one deliberate
  # difference from the conventional mapping: the primary role.
  #
  # The usual choice for mPrimary is base0D, and catppuccin fills base0D with
  # blue. The accent wanted here is lavender, which the scheme puts in base07.
  # Overriding base0D globally would fix the shell and break everything else:
  # that slot means "functions, methods, headings", so every editor and every
  # syntax highlighter would turn lavender too. Remapping the one role here is
  # the narrow fix.
  accent = "base07";
  accentHex = darkColors.withHashtag.${accent};

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
  # schemes.nix for why both halves are built by hand.
  #
  # This palette themes the SHELL. The same scheme reaches the terminal and the
  # editor through their own targets, all keyed off the one dconf value
  # noctalia writes on a mode toggle.
  schemes = import ./schemes.nix { inherit pkgs inputs; };
  darkColors = schemes.dark;
  lightColors = schemes.light;

  # Shared with cursors.nix, which installs both variants; everything that
  # SELECTS one happens here, at runtime.
  cursors = import ./cursors-data.nix { inherit pkgs; };

  # Applies the cursor theme for a mode, everywhere a cursor is read from.
  #
  # Used by two hooks, because neither covers the other's case: `started` fires
  # once at launch with NO environment (application.cpp fires it via the plain
  # fire() overload), and `theme_mode_changed` never fires at startup at all --
  # it is guarded on `previousMode.has_value()`, which is empty on the first
  # pass. So login reconciles by asking, and later changes are told.
  #
  # $1 is the mode, or empty to ask noctalia for it. `theme-mode-get` prints the
  # RESOLVED mode, which matters because the configured one may be "auto";
  # reading settings.toml directly would hand back that literal. IPC comes up in
  # an earlier startup phase than the hooks (initIpc at application.cpp:252,
  # hooks at :257), so it answers even from `started`.
  applyCursor = pkgs.writeShellScript "noctalia-apply-cursor" ''
    set -u
    mode="''${1:-}"
    if [ -z "$mode" ]; then
      mode=$(${lib.getExe' config.programs.noctalia.package "noctalia"} msg theme-mode-get 2>/dev/null || echo dark)
    fi

    if [ "$mode" = "light" ]; then
      theme=${cursors.light.name}
    else
      theme=${cursors.dark.name}
    fi
    size=${toString cursors.size}

    # 1. Hyprland's own pointer. Repaints immediately; purely runtime state,
    #    which is why this has to run again at every login.
    ${lib.getExe' pkgs.hyprland "hyprctl"} setcursor "$theme" "$size" >/dev/null 2>&1 || true

    # 2. GTK apps, which read dconf and not the environment. hyprctl does not
    #    touch this.
    ${lib.getExe' pkgs.dconf "dconf"} write /org/gnome/desktop/interface/cursor-theme "'$theme'" 2>/dev/null || true
    ${lib.getExe' pkgs.dconf "dconf"} write /org/gnome/desktop/interface/cursor-size "$size" 2>/dev/null || true

    # 3. XCURSOR_* for anything spawned later. Verified: a client started
    #    through systemd or dbus activation picks these up live, so this is what
    #    replaces the fixed-per-generation value home.pointerCursor would write.
    #    uwsm already finalizes exactly these names into the systemd user
    #    manager (UWSM_FINALIZE_VARNAMES), so this works with the session
    #    manager rather than around it.
    #
    #    Not covered: hyprland's own exec environment is frozen at launch, so a
    #    client started from a compositor keybind keeps the value it had then.
    #    `hyprctl keyword env` cannot fix that -- it is rejected outright under
    #    the lua parser ("keyword can't work with non-legacy parsers").
    ${lib.getExe' pkgs.systemd "systemctl"} --user set-environment \
      XCURSOR_THEME="$theme" XCURSOR_SIZE="$size" HYPRCURSOR_THEME="$theme" HYPRCURSOR_SIZE="$size" 2>/dev/null || true
    ${lib.getExe' pkgs.dbus "dbus-update-activation-environment"} --systemd \
      XCURSOR_THEME XCURSOR_SIZE HYPRCURSOR_THEME HYPRCURSOR_SIZE 2>/dev/null || true
  '';
in
{
  programs.noctalia = {
    enable = true;
    systemd.enable = true;

    customPalettes.base16-accent = {
      dark = mkPalette darkColors;
      light = mkPalette lightColors;
    };

    settings = {
      theme = {
        # The starting mode only. `noctalia msg theme-mode-toggle` (mod+T, the
        # bar widget, the control-center tile) persists the user's choice into
        # the state dir's settings.toml, which is layered over this file at
        # load, so a toggle survives both a restart and a rebuild.
        #
        mode = "dark";
        source = "custom";
        custom_palette = "base16-accent";

        # Templates re-render on every mode toggle, so anything driven by one
        # gets live light/dark for free. `builtin_ids` is an allowlist, not a
        # switch: only the templates named here run, so this does not opt into
        # the whole catalog.
        #
        # These four are the ones whose apps are installed and whose files are
        # no longer written by home-manager -- see gtk-qt.nix, which disables
        # the matching declarative writers in the same change. Adding an id here
        # without freeing its file first means two writers fighting over it.
        #
        # gtk3/gtk4 write $XDG_CONFIG_HOME/gtk-{3,4}.0/noctalia.css and append
        # an @import to gtk.css; qt writes qt5ct/qt6ct colour schemes;
        # kcolorscheme writes a KDE .colors file, which is what Qt/KDE dialogs
        # read for their palette.
        templates = {
          enable_builtin_templates = true;
          builtin_ids = [
            "gtk3"
            "gtk4"
            "qt"
            "kcolorscheme"
          ];
          enable_community_templates = false;

          # Firefox. Not a builtin -- there is no firefox entry in noctalia's
          # builtin.toml -- but `post_action = "firefox-theme"` is a first-class
          # action in the template engine, alongside kde-color-scheme.
          #
          # The action reads the colors.json this template renders, makes sure
          # the Pywalfox-compatible native-messaging manifest points at the
          # noctalia binary, and then pushes the mode and the palette over a
          # socket to every running Firefox profile. So the browser repaints on
          # a toggle with no restart -- the thing the userChrome approach in
          # firefox.nix could not do.

          #
          # It needs the Pywalfox extension: `pywalfox@frewacom.org` is the only
          # id the generated manifest allows (kExtensionId in
          # src/theme/firefox_theme/firefox_theme.cpp). firefox.nix force-installs
          # it.
          user.firefox = {
            enabled = true;
            input_path = "${./noctalia-templates/firefox-colors.json}";
            output_path = "${config.xdg.cacheHome}/noctalia/firefox-colors.json";
            post_action = "firefox-theme";
          };
        };
      };

      shell = {
        # Replaces the polkit agent that nothing else was providing.
        polkit_agent = true;
        settings_show_advanced = true;

        # Opacity values are the shared knob every other translucent surface
        # reads; noctalia's own dock/notification/osd keys were previously fed
        # from the same numbers by an external target.
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
        background_opacity = 0.5;
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
      #
      # $NOCTALIA_THEME_MODE is exported by the hook manager for this kind
      # (application_services.cpp fires ThemeModeChanged with it), so the
      # commands can branch on the mode they were fired for.
      #
      # Reconciles the cursor at login. `started` carries no environment, so
      # the script asks noctalia for the resolved mode itself.
      hooks.started = [ "${applyCursor}" ];

      hooks.theme_mode_changed = [
        ''
          ${lib.getExe' pkgs.systemd "busctl"} --user status com.mitchellh.ghostty 2>/dev/null \
            | ${lib.getExe' pkgs.gawk "awk"} '/^PID=/ { sub("PID=", ""); print $1 }' \
            | ${lib.getExe' pkgs.findutils "xargs"} -r ${lib.getExe' pkgs.util-linux "kill"} -USR2 || true
        ''

        # Cursor. Same script as `started`, told the mode rather than asking:
        # the hook manager exports it for this kind.
        ''${applyCursor} "$NOCTALIA_THEME_MODE"''
      ];

      lockscreen = {
        enabled = true;
        blurred_desktop = true;
      };

      wallpaper = {
        enabled = true;

        # One image mapped across the whole desktop rather than repeated per
        # screen. In this mode each output draws the slice of the image that
        # matches its own place in the layout: noctalia takes the bounding box
        # of every output and gives each one an offset/size within it
        # (computeWallpaperSpanParams, src/shell/wallpaper/wallpaper_geometry.cpp).
        fill_mode = "span";

        # The path has to reach the store, not ../wallpapers: noctalia reads it
        # at runtime from a plain string, so a repo-relative path would break
        # the moment the working copy moved.
        default.path = "${../wallpapers/future_funk_4k.jpg}";
      };
    };
  };
  programs.noctalia.plugins.appmenu.enable = true;
  # The window border follows base0D for the same reason the shell's primary
  # did; point it at the same accent so the frame matches the bar.
  wayland.windowManager.hyprland.settings.config.general."col.active_border" =
    "rgb(${darkColors.${accent}})";

  # Hermes has the same base0D-is-blue problem: its skin defaults the accent to
  # that slot. Point it at the same one so the agent, the shell and the window
  # borders agree. Inert unless services.hermes-agent is enabled.
  #
  # This assumes ./hermes-agent-skin.nix is imported alongside this file -- both
  # come in together from home-graphical.nix. Importing this module on its own
  # would fail on an undefined option.
  theming.hermes-agent.accentColor = accentHex;
}
