{
  config,
  pkgs,
  lib,
  ...
}:
let
  h = import ./hyprland-helpers.nix { inherit lib; };

  mod = "SUPER";
in
{
  home.sessionVariables = {
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_DESKTOP = "Hyprland";
    GDK_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    QT_QPA_PLATFORM_THEME = "qt6ct";
    QT_AUTO_SCREEN_SCALE_FACTOR = "1";
    # HYPRCURSOR_THEME = config.home.pointerCursor.name;
    # HYPRCURSOR_SIZE = config.home.pointerCursor.size;
  };

  services.hypridle = {
    enable = false;
    settings = {
      general = {
        before_sleep_cmd = "hyprlock";
        ignore_dbus_inhibit = false;
        lock_cmd = "hyprlock";
      };
      listener = [
        {
          timeout = 60;
          on-timeout = "hyprlock";
        }
      ];
    };
  };

  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        disable_loading_bar = true;
        grace = 10;
        hide_cursor = true;
        no_fade_in = false;
      };

      # input-field = [
      #   {
      #     size = "400, 50";
      #     position = "0, 0";
      #     monitor = "";
      #     dots_center = true;
      #     fade_on_empty = false;
      #     rounding = -1;
      #     outline_thickness = 2;
      #     placeholder_text = "";
      #     fail_text = "";
      #   }
      # ];
    };
  };

  wayland.windowManager.hyprland = {
    enable = true;
    portalPackage = null;
    xwayland.enable = true;
    systemd.enable = true;

    configType = "lua";

    settings = {
      # Everything that used to be a top-level hyprlang section
      # (general, decoration, input, ...) now lives under hl.config({...}).
      config = {
        general = {
          gaps_in = 4;
          gaps_out = 4;
          border_size = 4;
          layout = "dwindle";
        };

        decoration = {
          rounding = 9;
          blur.enabled = false;
          shadow.enabled = false;
        };

        animations.enabled = false;

        dwindle = {
          preserve_split = true;
          force_split = 2;
        };

        master.smart_resizing = true;

        input = {
          kb_layout = "us";
          repeat_delay = 300;
          repeat_rate = 50;
          follow_mouse = 1;
          touchpad = {
            natural_scroll = true;
            scroll_factor = 0.3;
            disable_while_typing = false;
          };
        };

        opengl = {
          nvidia_anti_flicker = 0;
        };

        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          mouse_move_enables_dpms = true;
          layers_hog_keyboard_focus = true;
          disable_autoreload = false;
          allow_session_lock_restore = true;
          vrr = 2;
        };
      };

      on = [
        # exec-once replacements
        (h.onEvent "hyprland.start" [
          "hyprpaper"
          "gnome-keyring-daemon --start --components=secrets"
        ])
      ];

      monitor = [
        (h.monitor {
          output = "DP-2";
          mode = "3840x2160@60";
          position = "1440x32";
          scale = 1.5;
          transform = 3;
        })
        (h.monitor {
          output = "DP-1";
          mode = "3840x2160@60";
          position = "0x0";
          scale = 1.5;
          transform = 3;
        })
        (h.monitor {
          output = "eDP-1";
          mode = "2560x1600@165";
          position = "0x0";
          scale = 1;
        })
      ];

      # All binds go under the `bind` setting; flags distinguish mouse/locked/repeating.
      bind = [
        # basics
        (h.bind (h.key mod "Return") (h.exec "ghostty"))
        (h.bind (h.key mod "R") (h.layout "togglesplit"))
        (h.bind (h.key mod "F") h.window.fullscreenToggle)
        (h.bind (h.key mod "D") (h.exec ''rofi -show drun -display-drun " " -show-icons''))
        (h.bind (h.key "${mod} + SHIFT" "Q") h.window.close)

        # window / workspace nav
        (h.bind (h.key mod "Tab") h.workspace.previous)
        (h.bind (h.key "ALT" "Tab") h.window.cycleNext)
        (h.bind (h.key "ALT" "Tab") h.window.bringToTop)
        (h.bind (h.key mod "Space") h.window.floatToggle)
        (h.bind (h.key "${mod} + SHIFT" "Space") h.window.pseudoToggle)

        # widgets
        (h.bind (h.key mod "C") (h.exec "ags toggle-window notificationsCenter"))
        (h.bind (h.key mod "N") (h.exec "ags toggle-window quicksettings"))

        # screenshots
        (h.bind (h.noMod "Print") (h.exec "grimblast copysave output # screenshot"))
        (h.bind (h.key "SUPER" "S") (h.exec "grimblast copysave active"))
        (h.bind (h.key "SUPER + SHIFT" "S") (h.exec "grimblast copysave area"))

        # special workspace
        (h.bind (h.key "SUPER + SHIFT" "A") (h.window.moveToWorkspace "special"))
        (h.bind (h.key "SUPER" "A") (h.raw "hl.dsp.workspace.toggle_special()"))

        # focus
        (h.bind (h.key mod "Left") (h.focus.dir "l"))
        (h.bind (h.key mod "Right") (h.focus.dir "r"))
        (h.bind (h.key mod "Up") (h.focus.dir "u"))
        (h.bind (h.key mod "Down") (h.focus.dir "d"))

        # move windows
        (h.bind (h.key "${mod} + SHIFT" "Left") (h.window.moveDir "l"))
        (h.bind (h.key "${mod} + SHIFT" "Right") (h.window.moveDir "r"))
        (h.bind (h.key "${mod} + SHIFT" "Up") (h.window.moveDir "u"))
        (h.bind (h.key "${mod} + SHIFT" "Down") (h.window.moveDir "d"))

        # scroll workspaces
        (h.bind (h.key mod "mouse_down") h.workspace.next)
        (h.bind (h.key mod "mouse_up") h.workspace.prev)

        # mouse binds
        (h.bindf (h.key mod "mouse:272") h.window.drag h.mouse)
        (h.bindf (h.key mod "mouse:273") h.window.resize h.mouse)

        # media keys (locked so they work at the lock screen)
        (h.bindf (h.noMod "XF86AudioPlay") (h.exec "${pkgs.playerctl}/bin/playerctl play-pause") h.locked)
        (h.bindf (h.noMod "XF86AudioPrev") (h.exec "${pkgs.playerctl}/bin/playerctl previous") h.locked)
        (h.bindf (h.noMod "XF86AudioNext") (h.exec "${pkgs.playerctl}/bin/playerctl next") h.locked)

        # brightness / volume (repeating)
        (h.bindf (h.noMod "XF86MonBrightnessUp") (h.exec "${pkgs.brightnessctl}/bin/brightnessctl s 5+")
          h.repeating
        )
        (h.bindf (h.noMod "XF86MonBrightnessDown") (h.exec "${pkgs.brightnessctl}/bin/brightnessctl s 5-")
          h.repeating
        )
        (h.bindf (h.noMod "XF86AudioRaiseVolume")
          (h.exec "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +3%")
          h.repeating
        )
        (h.bindf (h.noMod "XF86AudioLowerVolume")
          (h.exec "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -3%")
          h.repeating
        )

        # mute
        (h.bindf (h.noMod "XF86AudioMute")
          (h.exec "${pkgs.pulseaudio}/bin/pactl set-sink-mute @DEFAULT_SINK@ toggle")
          h.locked
        )

        # lid switch
        (h.bindf (h.noMod "switch:on:Lid Switch") (h.exec "systemctl suspend") h.locked)
      ]
      ++ (h.workspaceBinds { mod = mod; });

      window_rule = [
        (h.floatRule { class = "^(pavucontrol)$"; })
        (h.floatRule { title = "^(Open Files)$"; })
        (h.floatRule { title = "^(Save File)$"; })
      ];
    };

    extraConfig = ''
      -- TODO: the old hyprlang gesture = "3, horizontal, workspace" needs a lua port.
      -- hl.config({ gesture = { ... } }) details aren’t documented clearly yet.
    '';
  };
}
