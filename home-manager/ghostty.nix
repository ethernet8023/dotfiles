{
  ...
}:
{
  programs.ghostty = {
    enable = true;
    enableFishIntegration = true;

    settings = {
      gtk-titlebar = false;
      # matches hyprland's inter-window gap (gaps_in = 5 per edge => 10 visible)
      window-padding-x = 10;
      window-padding-y = 10;
      font-family = (import ./font.nix).mono;
    };
  };
}
