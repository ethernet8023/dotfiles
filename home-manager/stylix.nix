{
  config,
  pkgs,
  ...
}:
{
  # Whole-system theming. Replaces catppuccin/nix, which had no noctalia port --
  # every catppuccin+noctalia config in the wild hand-writes that bridge, while
  # stylix ships one (modules/noctalia/hm.nix, for v5).
  #
  # Catppuccin is still the theme; it arrives as the base16 scheme rather than
  # through catppuccin/nix's per-app ports.
  stylix = {
    enable = true;
    autoEnable = true;

    polarity = "dark";
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";

    fonts = {
      monospace = {
        package = pkgs.nerd-fonts.mononoki;
        name = (import ./font.nix).mono;
      };
      sansSerif = {
        package = pkgs.nerd-fonts.mononoki;
        name = (import ./font.nix).propo;
      };
      serif = config.stylix.fonts.sansSerif;
    };

    image = ../wallpapers/succulents.jpg;
  };

  # stylix's hyprland target turns on hyprpaper whenever stylix.image is set.
  # noctalia draws the wallpaper here ([wallpaper] in noctalia.nix), and two
  # wallpaper daemons fight over the layer, so keep hyprpaper off. The image is
  # still used: stylix passes it to noctalia's wallpaper.default.path.
  stylix.targets.hyprland.hyprpaper.enable = false;
}
