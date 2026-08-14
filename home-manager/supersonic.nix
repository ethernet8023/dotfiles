{
  pkgs,
  ...
}:
{
  home.packages = [ pkgs.supersonic ];
  services.mpris-proxy.enable = true;
  # xdg.configFile."supersonic/themes/nix-theme.toml".text =
  #   with config.lib.stylix.colors.withHashtag; ''
  #     [SupersonicTheme]
  #     Name = "Nix Theme"
  #     Version = "0.1"
  #     SupportsDark = true
  #     SupportsLight = true

  #     [DarkColors]
  #     PageBackground = "${base00}"
  #     InputBackground = "${base00}"
  #     InputBorder = "${base00}"
  #     MenuBackground = "${base00}"
  #     OverlayBackground = "${base00}"
  #     Pressed = "${base04}"
  #     Hyperlink = "${base0D}"
  #     ListHeader = "${base0B}"
  #     PageHeader = "${base02}"
  #     Background = "${base00}"
  #     ScrollBar = "${base0B}"
  #     Button = "${base01}"
  #     DisabledButton = "${base02}"
  #     Separator = "${base00}"
  #     Foreground = "${base05}"

  #     [LightColors]
  #     PageBackground = "${base00}"
  #     InputBackground = "${base00}"
  #     InputBorder = "${base00}"
  #     MenuBackground = "${base00}"
  #     OverlayBackground = "${base00}"
  #     Pressed = "${base04}"
  #     Hyperlink = "${base0D}"
  #     ListHeader = "${base0B}"
  #     PageHeader = "${base02}"
  #     Background = "${base00}"
  #     ScrollBar = "${base0B}"
  #     Button = "${base01}"
  #     DisabledButton = "${base02}"
  #     Separator = "${base00}"
  #     Foreground = "${base05}"
  #   '';
}
