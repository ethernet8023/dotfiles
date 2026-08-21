{
  pkgs,
  inputs,
  ...
}:
{
  imports = [
    inputs.stylix.homeModules.stylix
    inputs.noctalia.homeModules.default
    inputs.nixcord.homeModules.nixcord
    inputs.hermes-agent.homeManagerModules.default
    ./home.nix
    ./hyprland.nix
    ./ghostty.nix
    ./firefox.nix
    ./supersonic.nix
    ./vscode.nix
    # ./neovim.nix

    ./stylix.nix
    ./stylix-hermes-agent.nix
    ./noctalia.nix
  ];

  home.packages = with pkgs; [
    # desktop env
    nautilus # file manager
    inputs.hypr-contrib.packages.${pkgs.stdenv.hostPlatform.system}.grimblast # screenshot tool
    pavucontrol # audio control
    blueman # bluetooth manager
    wl-clipboard # copy/paste cli
    # monado # xr? :D

    # 3d pwint
    # prusa-slicer

    easyeffects # mic settings

    vlc # video player
    google-chrome # web browser
    slack # ew

    deskflow # one kb/mouse across luna, hermes, promise, iris

    # clang format needs..
    clang-tools

    # wine

    ledger-live-desktop
    beeper
  ];

  # Discord, via nixcord: it manages vesktop (the client) plus vencord (the mod)
  # declaratively, and stylix themes it through modules/discord/.
  programs.nixcord = {
    enable = true;
    vesktop.enable = true;
    discord.enable = false;
  };

  programs.fish.shellAliases = {
    pbpaste = "wl-paste";
    pbcopy = "wl-copy";
    # hyprland isn't GNOME/KDE, so electron's keyring autodetection falls back
    # to the plaintext "basic" store and hermes-desktop's safeStorage refuses
    # to save oauth tokens ("Secure token storage is unavailable"). force the
    # libsecret backend; gnome-keyring is already running (hyprland.nix).
    hermes-desktop = "nix run github:nousresearch/hermes-agent#desktop -- --password-store=gnome-libsecret";
  };
}
