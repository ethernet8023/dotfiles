# Cursor theme names, shared by cursors.nix (which installs and sets them) and
# noctalia.nix (whose theme_mode_changed hook switches between them).
#
# Split out so the two never disagree: a hook naming a theme that is not the one
# installed fails silently, leaving the pointer on the old variant.
{ pkgs }:
{
  size = 24;

  dark = {
    package = pkgs.catppuccin-cursors.mochaLavender;
    name = "catppuccin-mocha-lavender-cursors";
  };

  light = {
    package = pkgs.catppuccin-cursors.latteLavender;
    name = "catppuccin-latte-lavender-cursors";
  };
}
