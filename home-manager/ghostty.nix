{
  pkgs,
  inputs,
  ...
}:
let
  schemes = import ./schemes.nix { inherit pkgs inputs; };
  fonts = import ./font.nix;
  opacity = import ./opacity.nix;

  # Both halves of the terminal theme, from one mapping so they cannot drift.
  # This is the block stylix's modules/ghostty/hm.nix built, inlined here when
  # stylix was removed -- the base16 slot assignment is base16's convention, not
  # stylix's, so it carries over unchanged.
  mkTheme =
    colors: with colors.withHashtag; {
      background = colors.base00;
      foreground = colors.base05;
      cursor-color = colors.base05;
      selection-background = colors.base02;
      selection-foreground = colors.base05;

      palette = [
        "0=${base00}"
        "1=${base08}"
        "2=${base0B}"
        "3=${base0A}"
        "4=${base0D}"
        "5=${base0E}"
        "6=${base0C}"
        "7=${base05}"
        "8=${base03}"
        "9=${base08}"
        "10=${base0B}"
        "11=${base0A}"
        "12=${base0D}"
        "13=${base0E}"
        "14=${base0C}"
        "15=${base07}"
      ];
    };
in
{
  programs.ghostty = {
    enable = true;
    enableFishIntegration = true;

    # Named `stylix`/`stylix-light` no longer, but the names are still just
    # labels the `theme` setting below refers to.
    themes = {
      dark = mkTheme schemes.dark;
      light = mkTheme schemes.light;
    };

    settings = {
      gtk-titlebar = false;
      # matches hyprland's inter-window gap (gaps_in = 5 per edge => 10 visible)
      window-padding-x = 10;
      window-padding-y = 10;

      font-family = fonts.mono;
      font-size = fonts.sizes.terminal;
      background-opacity = opacity.terminal;

      # Ghostty resolves a `light:,dark:` pair against the desktop colour
      # scheme, but only while READING its config -- it does not repaint when
      # the appearance portal changes underneath a running process. Verified on
      # 1.3.1: a window left in light mode stayed at mocha #1D1D32, and the same
      # window redrew as latte #E0E2EC the moment it got SIGUSR2. So the pair
      # below picks the right half at startup and at every reload, and
      # noctalia.nix sends that reload on a mode toggle.
      theme = "dark:dark,light:light";

      # Home-manager gives the ghostty user unit an X-Reload-Triggers listing
      # the config and every theme file, so a switch that changes any of them
      # SIGUSR2s ghostty and it toasts "Reloaded the configuration". The theme
      # hook does the same on every toggle, which would make the toast routine.
      # The reload itself is wanted -- it is what applies the colours -- so only
      # the toast is switched off.
      app-notifications = "no-config-reload";
    };
  };
}
