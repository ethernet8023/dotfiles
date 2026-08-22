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
  };

  xdg.configFile."uwsm/env".source =
    "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";

  gtk.font = {
    name = (import ./font.nix).propo;
  };

  # hypridle/hyprlock are retired: noctalia owns the lock screen ([lockscreen])
  # and idle behaviour ([idle.behavior.*]), and its lock screen authenticates
  # against the stock `login` pam service, so no pam entry is needed for it.

  wayland.windowManager.hyprland = {
    enable = true;
    portalPackage = null;
    xwayland.enable = true;
    systemd.enable = false;

    configType = "lua";

    settings = {
      # Everything that used to be a top-level hyprlang section
      # (general, decoration, input, ...) now lives under hl.config({...}).
      config = {
        general = {
          gaps_in = 5;
          gaps_out = 10;
          border_size = 2;
          layout = "dwindle";
        };

        decoration = {
          rounding = 20;
          rounding_power = 2;

          shadow = {
            enabled = true;
            range = 4;
            render_power = 3;
            # colour comes from stylix's hyprland target (base00 at 99 alpha)
          };

          blur = {
            enabled = true;
            # A macOS-style pane is a wide, soft blur rather than a tight one.
            # Radius grows roughly as size * 2^passes, so 8/3 is a far larger
            # kernel than 3/2 at a similar cost, because each extra pass runs
            # on a half-resolution buffer.
            size = 8;
            passes = 3;

            # vibrancy pushes saturation back into the blurred backdrop, which
            # is what stops a blur over a colourful wallpaper reading as flat
            # grey. vibrancy_darkness applies it to dark areas too.
            vibrancy = 0.4;
            vibrancy_darkness = 0.5;

            # The default contrast of 0.8916 crushes an already dark
            # catppuccin-mocha surface; lift both so the frosted layer stays
            # readable. noise keeps a wide blur from banding.
            brightness = 1.1;
            contrast = 1.1;
            noise = 0.02;

            # Panels and menus are child surfaces, and are not blurred by
            # default even when their parent is.
            popups = true;
            special = true;
          };
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
        # exec-once replacements. noctalia runs as a systemd user unit bound to
        # graphical-session.target (see noctalia.nix), so it is not started here.
        (h.onEvent "hyprland.start" [
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
        (h.bind (h.key mod "D") (h.exec "noctalia msg panel-toggle launcher"))
        (h.bind (h.key "${mod} + SHIFT" "Q") h.window.close)

        # window / workspace nav
        (h.bind (h.key mod "Tab") h.workspace.previous)
        (h.bind (h.key "ALT" "Tab") h.window.cycleNext)
        (h.bind (h.key "ALT" "Tab") h.window.bringToTop)
        (h.bind (h.key mod "Space") h.window.floatToggle)
        (h.bind (h.key "${mod} + SHIFT" "Space") h.window.pseudoToggle)

        # shell panels (was `ags toggle-window ...`; ags is not installed)
        (h.bind (h.key mod "C") (h.exec "noctalia msg panel-toggle notifications"))
        (h.bind (h.key mod "N") (h.exec "noctalia msg panel-toggle control-center"))
        (h.bind (h.key mod "V") (h.exec "noctalia msg panel-toggle clipboard"))
        (h.bind (h.key mod "L") (h.exec "noctalia msg session lock"))
        (h.bind (h.key mod "T") (h.exec "noctalia msg theme-mode-toggle"))
        (h.bind (h.key "${mod} + SHIFT" "E") (h.exec "noctalia msg panel-toggle session"))

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

      # noctalia's surfaces are layer-shell, except the settings window, which is
      # a real window (class dev.noctalia.Noctalia). Namespaces verified against
      # the noctalia source; the wallpaper layer is deliberately excluded from
      # blur, since blurring the backdrop costs work and shows nothing.
      layer_rule = [
        {
          match.namespace = "^noctalia-(bar-.+|dock|panel|attached-panel|notification|osd)$";
          blur = true;
          blur_popups = true;
          ignore_alpha = 0.5;
        }
      ];

      window_rule = [
        {
          match.class = "^(pavucontrol)$";
          float = true;
        }
        {
          match.class = "^(dev\\.noctalia\\.Noctalia)$";
          float = true;
        }
        {
          match.title = "^(Open Files)$";
          float = true;
        }
        {
          match.title = "^(Save File)$";
          float = true;
        }
        {
          match.title = "^(Hermes HUD)$";
          float = true;
          border_size = 0;
        }
      ];
    };

    extraConfig = ''
      -- TODO: the old hyprlang gesture = "3, horizontal, workspace" needs a lua port.
      -- hl.config({ gesture = { ... } }) details aren’t documented clearly yet.
    '';
  };
}
