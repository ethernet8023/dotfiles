{
  pkgs,
  inputs,
  ...
}:
{
  imports = [
    inputs.noctalia.homeModules.default
    inputs.noctalia-appmenu.homeManagerModules.default
    inputs.nixcord.homeModules.nixcord
    inputs.hermes-agent.homeManagerModules.default
    ./home.nix
    ./hyprland.nix
    ./ghostty.nix
    ./firefox.nix
    ./supersonic.nix
    ./vscode.nix
    # ./neovim.nix

    ./hermes-agent-skin.nix
    ./hermes-desktop-theme.nix
    ./noctalia.nix
    ./fish-theme.nix
    ./fonts.nix
    ./cursors.nix
    ./gtk-qt.nix
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
  # declaratively. The theme is written below.
  programs.nixcord = {
    enable = true;
    vesktop.enable = true;
    discord.enable = false;
  };

  # Discord's theme, both halves, written straight to vesktop's theme dir --
  # the same place stylix's nixcord target wrote it, minus stylix.
  #
  # The colour mapping is vendored (./vendor/discord-color-theme.nix): it emits
  # one :root block of --base00..--base0F and writes every later rule in terms
  # of those sixteen. So appending a media query that restates just the sixteen
  # repaints the entire client, with no need to duplicate the mappings.
  #
  # This needs no hook, unlike ghostty: vesktop is Electron, which resolves
  # prefers-color-scheme from the appearance portal live. Verified against
  # Electron 43 (vesktop's own) on this machine -- portal prefer-light gave
  # `matchMedia('(prefers-color-scheme: dark)').matches == false`, and
  # prefer-dark gave true, so the query tracks a toggle with no restart.
  xdg.configFile."vesktop/themes/base16.theme.css".text =
    let
      schemes = import ./schemes.nix { inherit pkgs inputs; };
      c = schemes.light.withHashtag;
      mkTheme = import ./vendor/discord-color-theme.nix;
    in
    ''
      /**
      * @name Base16
      * @author home-manager
      * @version 0.0.0
      * @description Theme configured via Home Manager.
      **/
    ''
    + mkTheme schemes.dark
    + ''

      @media (prefers-color-scheme: light) {
          :root {
              --base00: ${c.base00};
              --base01: ${c.base01};
              --base02: ${c.base02};
              --base03: ${c.base03};
              --base04: ${c.base04};
              --base05: ${c.base05};
              --base06: ${c.base06};
              --base07: ${c.base07};
              --base08: ${c.base08};
              --base09: ${c.base09};
              --base0A: ${c.base0A};
              --base0B: ${c.base0B};
              --base0C: ${c.base0C};
              --base0D: ${c.base0D};
              --base0E: ${c.base0E};
              --base0F: ${c.base0F};
          }
      }
    '';

  programs.nixcord.config.enabledThemes = [ "base16.theme.css" ];
}
