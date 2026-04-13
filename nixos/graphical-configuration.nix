{ pkgs, ... }:
{
  imports = [
    ./tuigreet.nix
    ./catppuccin.nix
  ];

  boot.plymouth.enable = true;

  console.keyMap = "us";

  services.xserver.xkb.layout = "us";

  security.pam.services.hyprlock = { };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  virtualisation = {
    docker.enable = true;
    # virtualbox.host = {
    #   enable = true;
    #   enableKvm = true;
    #   addNetworkInterface = false;
    # };
  };

  programs.uwsm = {
    enable = true;
  };
  programs.hyprland = {
    enable = true;
    withUWSM = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
    config.hyprland = {
      default = [ "hyprland" "gtk" ];
    };
  };

  environment.variables = {
    WLR_NO_HARDWARE_CURSORS = "1";
    NIXOS_OZONE_WL = "1";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_DESKTOP = "Hyprland";
    GDK_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    QT_QPA_PLATFORM_THEME = "qt6ct";
    QT_AUTO_SCREEN_SCALE_FACTOR = "1";
  };

  services = {
    fwupd.enable = true;
    printing.enable = false;
  };

  networking.networkmanager.enable = true;

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    liberation_ttf
    tex-gyre.heros
    nerd-fonts.mononoki
  ];
}
