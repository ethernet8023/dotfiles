{
  pkgs,
  lib,
  ...
}:
{
  programs.waybar = {
    enable = true;

    # Waybar 0.15.0 still speaks the pre-0.54 Hyprland IPC dispatch format
    # ("dispatch workspace 3"). Hyprland runs the Lua config manager here (see
    # hyprland.nix, configType = "lua"), which evaluates that as Lua and fails
    # with a syntax error, so clicking a workspace does nothing. Upstream fixed
    # this by probing the Hyprland version and emitting hl.dsp.focus{...}, but
    # the fix is unreleased -- 0.15.0 predates it. Drop this patch once nixpkgs
    # carries a release containing Alexays/Waybar#5008.
    package = pkgs.waybar.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./waybar-hyprland-lua-dispatch.patch ];
    });

    systemd.enable = true;
    settings = {
      # `settings` is an attrsOf submodule, so a host file setting
      # settings.mainBar.position overrides just that key and leaves the rest
      # of this bar alone. The keys describing bar geometry are mkDefault
      # because they only suit a vertical bar; luna turns it horizontal in
      # hosts/luna.nix, and a plain value there would conflict with one here.
      mainBar = {
        layer = "top";
        position = lib.mkDefault "right";
        # Cross-axis size of a vertical bar. A horizontal bar takes its height
        # from the modules instead, so luna nulls this out.
        width = lib.mkDefault 50;
        margin = "16";
        # Pin the bar flush against the edge it lives on.
        margin-right = lib.mkDefault 0;
        spacing = 0;
        output = [
          "DP-2"
          "eDP-1"
        ];
        reload_style_on_change = true;
        modules-left = [ "hyprland/workspaces" ];
        modules-right = [
          "tray"
          "backlight"
          "network"
          "battery"
          "pulseaudio"
          "idle_inhibitor"
          "disk"
          "memory"
          "cpu"
          "temperature"
          "clock"
          "clock#calendar"
        ];

        battery = {
          format = "{icon}  {capacity}%";
          format-icons = [
            ""
            ""
            ""
            ""
            ""
          ];
        };

        network = {
          format-wifi = "  {signalStrength}%";
          format-ethernet = "  {ifname}";
          format-disconnected = "󰤫";
        };
        pulseaudio = {
          scroll-step = 1;
          format = "{icon}  {volume}%";
          format-bluetooth = "vol.{volume}";
          format-bluetooth-muted = " {icon} {format_source}";
          format-muted = "";
          format-source = "{volume}%";
          format-source-muted = "";
          format-icons = {
            headphone = "";
            phone = "";
            portable = "";
            car = "";
            default = [
              ""
              ""
              ""
            ];
          };
          rotate = 0;
          on-click = "pavucontrol";
        };

        backlight = {
          device = "amdgpu_bl1";
          format = "{icon} {percent}%";
          format-icons = [
            "󰛩"
            "󱩎"
            "󱩏"
            "󱩐"
            "󱩑"
            "󱩒"
            "󱩓"
            "󱩔"
            "󱩕"
            "󱩖"
            "󰛨"
          ];
        };

        idle_inhibitor = {
          format = "{icon}";
          format-icons = {
            activated = "󰛊 ";
            deactivated = "󰾫 ";
          };
        };

        disk = {
          interval = 30;
          format = "󰋊 {percentage_used}%";
          tooltip-format = ''{used} used out of {total} on "{path}" ({percentage_used}%)'';
        };
        memory = {
          interval = 10;
          format = " {used}";
          tooltip-format = "{used}GiB used of {total}GiB ({percentage}%)";
        };
        cpu = {
          interval = 10;
          format = " {usage}%";
        };
        temperature = {
          interval = 10;
        };

        clock = {
          interval = 1;
          format = "{:%H:%M:%S}";
        };

        "clock#calendar" = {
          format = "{:%a %b %d}";
        };

        "hyprland/workspaces" = {
          show-special = true;
          persistent-workspaces = {
            "*" = [
              1
              2
              3
              4
              5
              6
              7
              8
              9
              10
            ];
          };
          format = "{icon}";
          format-icons = {
            active = "";
            empty = "";
            default = "";
            urgent = "";
            special = "󰠱";
          };
        };

        "hyprland/window" = {
          icon = true;
          icon-size = 22;
          rewrite = {
            "(.*) — Mozilla Firefox" = "$1 - 🦊";
            "(.*) - Visual Studio Code" = "$1 - 󰨞 ";
            "(.*) - Discord" = "$1 - 󰙯 ";
            "^$" = "👾";
          };
        };
      };
    };

    # Supplying `style` at all replaces Waybar's default stylesheet, and the
    # catppuccin module's definition is only colour variables -- so nothing
    # sets the module padding the default sheet normally provides, and the
    # items sit flush against each other. The option is `lines`, so this
    # concatenates with catppuccin's rather than conflicting with it.
    #
    # Horizontal padding on the modules themselves (not `spacing`, which is
    # gaps *between* modules only, leaving each item's own text edge-to-edge).
    style = ''
      .modules-left > widget > *,
      .modules-center > widget > *,
      .modules-right > widget > * {
        padding-left: 10px;
        padding-right: 10px;
      }

      /* Workspace pills are individual buttons inside one module, so they
         need their own padding; the rule above only reaches the container.
         The icons are single nerd-font glyphs, which sit wider than their
         advertised advance width, so they need more room than plain text. */
      #workspaces button {
        padding-left: 10px;
        padding-right: 10px;
      }
    '';
  };
}
