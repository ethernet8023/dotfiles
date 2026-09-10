{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # Colours an external target used to inject. noctalia.nix overrides
  # col.active_border with the lavender accent; these are the rest.
  colors = (import ./schemes.nix { inherit pkgs inputs; }).dark;
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

  wayland.windowManager.hyprland = {
    enable = true;
    portalPackage = null;
    xwayland.enable = true;
    systemd.enable = false;

    configType = "lua";

    settings =
      let
        inherit (import ./hyprland-helpers.nix { inherit lib; })
          mkBinds
          withFlags
          monitor
          exec
          onEvent
          locked
          layout
          window
          workspace
          raw
          focus
          mouse
          repeating
          workspaceBinds
          ;

        mod = "SUPER";

      in
      {
        # Everything that used to be a top-level hyprlang section
        # (general, decoration, input, ...) now lives under hl.config({...}).
        config = {
          general = {
            gaps_in = 5;
            gaps_out = 10;
            border_size = 2;
            layout = "dwindle";
            "col.inactive_border" = "rgb(${colors.base03})";
          };

          decoration = {
            rounding = 20;
            rounding_power = 2;

            shadow = {
              enabled = true;
              range = 4;
              render_power = 3;
              color = "rgba(${colors.base00}99)";
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
              vibrancy = 0.7;
              vibrancy_darkness = 0.6;

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
            accel_profile = "flat";
            touchpad = {
              natural_scroll = true;
              scroll_factor = 0.2;
              disable_while_typing = false;
            };
          };

          opengl = {
            nvidia_anti_flicker = 0;
          };

          misc = {
            background_color = "rgb(${colors.base00})";
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
          (onEvent "hyprland.start" [
            "gnome-keyring-daemon --start --components=secrets"
          ])
        ];

        monitor = [
          # Both desktop panels are 27" mounted portrait (transform 3), and both
          # end up 1440x2560 logical, so they sit side by side with no vertical
          # offset and a window keeps its size when it crosses between them.
          #
          # The scales are what make that true, and they are not free choices:
          # 27" 1440p is 109 DPI and 27" 4K is 163 DPI, exactly 1.5x, so scale
          # 1.5 on the 4K and 1 on the 1440p render everything at the same
          # physical size. 1.5 on the 1440p panel would not even be legal --
          # 2560/1.5 is not an integer, and Hyprland quietly rounds a rejected
          # scale to the nearest workable one (1.6) instead of failing.
          (monitor {
            # left: Dell U2722D
            output = "DP-2";
            mode = "2560x1440@59.95";
            position = "0x0";
            scale = 1;
            transform = 3;
          })
          (monitor {
            # right: Dell P2723QE
            output = "DP-1";
            mode = "3840x2160@60";
            position = "1440x0";
            scale = 1.5;
            transform = 3;
          })
          (monitor {
            output = "eDP-1";
            mode = "2560x1600@165";
            position = "0x0";
            scale = 1;
          })
        ];
        # All binds go under the `bind` setting; flags distinguish mouse/locked/repeating.
        bind =
          mkBinds (
            {
              # basics
              "${mod} + Return" = exec "ghostty";
              "${mod} + R" = layout "togglesplit";
              "${mod} + F" = window.fullscreenToggle;
              "${mod} + D" = exec "noctalia msg panel-toggle launcher";
              "${mod} + SHIFT + Q" = window.close;

              # window / workspace nav
              "${mod} + Tab" = workspace.previous;
              "ALT + Tab" = [
                window.cycleNext
                window.bringToTop
              ];
              "${mod} + Space" = window.floatToggle;
              "${mod} + SHIFT + Space" = window.pseudoToggle;

              # shell panels (was `ags toggle-window ...`; ags is not installed)
              "${mod} + C" = exec "noctalia msg panel-toggle notifications";
              "${mod} + N" = exec "noctalia msg panel-toggle control-center";
              "${mod} + V" = exec "noctalia msg panel-toggle clipboard";
              "${mod} + L" = exec "noctalia msg session lock";
              "${mod} + T" = exec "noctalia msg theme-mode-toggle";
              "${mod} + SHIFT + E" = exec "noctalia msg panel-toggle session";

              # screenshots
              "Print" = exec "grimblast copysave output # screenshot";
              "SUPER + S" = exec "grimblast copysave active";
              "SUPER + SHIFT + S" = exec "grimblast copysave area";

              # special workspace
              "SUPER + SHIFT + A" = window.moveToWorkspace "special";
              "SUPER + A" = raw "hl.dsp.workspace.toggle_special()";

              # focus
              "${mod} + Left" = focus.dir "l";
              "${mod} + Right" = focus.dir "r";
              "${mod} + Up" = focus.dir "u";
              "${mod} + Down" = focus.dir "d";

              # move windows
              "${mod} + SHIFT + Left" = window.moveDir "l";
              "${mod} + SHIFT + Right" = window.moveDir "r";
              "${mod} + SHIFT + Up" = window.moveDir "u";
              "${mod} + SHIFT + Down" = window.moveDir "d";

              # scroll workspaces
              "${mod} + mouse_down" = workspace.next;
              "${mod} + mouse_up" = workspace.prev;
            }
            // withFlags mouse {
              # mouse binds
              "${mod} + mouse:272" = window.drag;
              "${mod} + mouse:273" = window.resize;
            }
            // withFlags locked {
              # media keys (locked so they work at the lock screen)
              "XF86AudioPlay" = exec "${pkgs.playerctl}/bin/playerctl play-pause";
              "XF86AudioPrev" = exec "${pkgs.playerctl}/bin/playerctl previous";
              "XF86AudioNext" = exec "${pkgs.playerctl}/bin/playerctl next";

              # mute
              "XF86AudioMute" = exec "${pkgs.pulseaudio}/bin/pactl set-sink-mute @DEFAULT_SINK@ toggle";

              # lid switch
              "switch:on:Lid Switch" = exec "systemctl suspend";
            }
            // withFlags repeating {
              # brightness / volume (repeating)
              "XF86MonBrightnessUp" = exec "${pkgs.brightnessctl}/bin/brightnessctl s 5+";
              "XF86MonBrightnessDown" = exec "${pkgs.brightnessctl}/bin/brightnessctl s 5-";
              "XF86AudioRaiseVolume" = exec "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +3%";
              "XF86AudioLowerVolume" = exec "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -3%";
            }
          )
          ++ workspaceBinds { mod = mod; };

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
          # Firefox draws translucent chrome (firefox.nix), but a surface it
          # reports as fully opaque gets occlusion-culled: hyprland skips
          # rendering what is behind it, and the translucent parts come out
          # black. An opacity just under 1 opts the window out of that
          # optimisation without a visible change of its own -- the alpha that
          # matters is in the CSS. This is the workaround hyprland's own
          # maintainer gives for the case (hyprwm/Hyprland#3049).
          {
            match.class = "^(firefox)$";
            opacity = "0.99 override 0.99 override 1.0 override";
          }
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
