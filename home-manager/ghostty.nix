{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  lightColors = import ./base16-light.nix { inherit pkgs inputs; };
in
{
  programs.ghostty = {
    enable = true;
    enableFishIntegration = true;

    # The light half of the terminal theme. stylix's ghostty target writes
    # `themes.stylix` from the one scheme it carries, which is the dark one, so
    # a reload after a mode toggle re-reads identical colours and appears to do
    # nothing. This is the same block from stylix's modules/ghostty/hm.nix, fed
    # the latte scheme instead.
    themes.stylix-light = with lightColors.withHashtag; {
      background = lightColors.base00;
      foreground = lightColors.base05;
      cursor-color = lightColors.base05;
      selection-background = lightColors.base02;
      selection-foreground = lightColors.base05;

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

    settings = {
      gtk-titlebar = false;
      # matches hyprland's inter-window gap (gaps_in = 5 per edge => 10 visible)
      window-padding-x = 10;
      window-padding-y = 10;
      font-family = (import ./font.nix).mono;

      # Ghostty resolves a `light:,dark:` pair against the desktop colour
      # scheme, but only while READING its config -- it does not repaint when
      # the appearance portal changes underneath a running process. Verified on
      # 1.3.1: a window left in light mode stayed at mocha #1D1D32, and the same
      # window redrew as latte #E0E2EC the moment it got SIGUSR2. So the pair
      # below picks the right half at startup and at every reload, and
      # noctalia.nix sends that reload on a mode toggle.
      #
      # mkForce because stylix's ghostty target sets `theme = "stylix"` from its
      # single scheme. That name is still the dark half below.
      theme = lib.mkForce "dark:stylix,light:stylix-light";

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
