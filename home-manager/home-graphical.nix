{
  pkgs,
  inputs,
  ...
}:
{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ./home.nix
    ./hyprland.nix
    ./ghostty.nix
    ./mako.nix
    ./firefox.nix
    ./rofi.nix
    ./waybar.nix
    ./supersonic.nix
    ./vscode.nix
    ./neovim.nix
    ../nixos/catppuccin.nix
  ];

  home.packages = with pkgs; [
    # desktop env
    hyprpaper # wallpaper manager
    nautilus # file manager
    inputs.hypr-contrib.packages.${pkgs.system}.grimblast # screenshot tool
    pavucontrol # audio control
    blueman # bluetooth manager
    wl-clipboard # copy/paste cli
    monado # xr? :D

    # 3d pwint
    prusa-slicer

    easyeffects # mic settings

    vlc # video player
    google-chrome # web browser
    slack # ew

    # clang format needs..
    clang-tools

    # wine

    ledger-live-desktop
  ];

  programs.vesktop.enable = true;

  programs.fish.shellAliases = {
    pbpaste = "wl-paste";
    pbcopy = "wl-copy";
  };
}
