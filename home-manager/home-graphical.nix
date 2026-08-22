{
  pkgs,
  inputs,
  ...
}:
{
  imports = [
    inputs.stylix.homeModules.stylix
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

    ./stylix.nix
    ./stylix-hermes-agent.nix
    ./noctalia.nix
    ./fish-theme.nix
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

  # The light half of the Discord theme.
  #
  # stylix's discord target emits one :root block of --base00..--base0F from
  # the single scheme it carries, and every rule after it is written in terms
  # of those variables (modules/discord/common/color-theme.nix). So re-stating
  # just the sixteen inside a media query repaints the whole client, with no
  # need to duplicate the several hundred mappings.
  #
  # This needs no hook, unlike ghostty: vesktop is Electron, which resolves
  # prefers-color-scheme from the appearance portal live. Verified against
  # Electron 43 (vesktop's own) on this machine -- portal prefer-light gave
  # `matchMedia('(prefers-color-scheme: dark)').matches == false`, and
  # prefer-dark gave true, so the query tracks a toggle with no restart.
  #
  # stylix appends extraCss after its own body, so this block wins on order.
  stylix.targets.nixcord.extraCss =
    let
      c = (import ./base16-light.nix { inherit pkgs inputs; }).withHashtag;
    in
    ''

      @media (prefers-color-scheme: light) {
          :root {
              --base00: ${c.base00}; /* Black */
              --base01: ${c.base01}; /* Bright Black */
              --base02: ${c.base02}; /* Grey */
              --base03: ${c.base03}; /* Brighter Grey */
              --base04: ${c.base04}; /* Bright Grey */
              --base05: ${c.base05}; /* White */
              --base06: ${c.base06}; /* Brighter White */
              --base07: ${c.base07}; /* Bright White */
              --base08: ${c.base08}; /* Red */
              --base09: ${c.base09}; /* Orange */
              --base0A: ${c.base0A}; /* Yellow */
              --base0B: ${c.base0B}; /* Green */
              --base0C: ${c.base0C}; /* Cyan */
              --base0D: ${c.base0D}; /* Blue */
              --base0E: ${c.base0E}; /* Purple */
              --base0F: ${c.base0F}; /* Magenta */
          }
      }
    '';

  programs.fish.shellAliases = {
    pbpaste = "wl-paste";
    pbcopy = "wl-copy";
  };
}
