# Global font configuration.
#
# Replaces stylix's fontconfig target, which was a nine-line wrapper over
# `fonts.fontconfig.defaultFonts` -- a stock home-manager option
# (modules/misc/fontconfig.nix). Font packages are a plain `home.packages`
# entry. Neither needs stylix (see .hermes/plans/remove-stylix.md).
#
# The target is switched off here rather than left to merge: `defaultFonts.*`
# are lists, so two definitions would concatenate and the winning family would
# depend on stylix's internal ordering index.
{ pkgs, ... }:
let
  fonts = import ./font.nix;
in
{
  fonts.fontconfig = {
    enable = true;

    defaultFonts = {
      monospace = [ fonts.mono ];
      sansSerif = [ fonts.propo ];
      # No serif face is shipped in this setup; the proportional one stands in,
      # matching what stylix did (its serif was defined as sansSerif).
      serif = [ fonts.propo ];
      emoji = [ fonts.emoji ];
    };
  };

  home.packages = [
    pkgs.nerd-fonts.mononoki
    pkgs.noto-fonts-color-emoji
  ];
}
