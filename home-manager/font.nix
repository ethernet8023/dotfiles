# Font names and sizes, as plain data.
#
# The single source of truth for typography here. Kept argument-free so it can
# be imported from anywhere with `import ./font.nix`, including from module
# `let` blocks that have no access to pkgs.
#
# Sizes are in points, and mirror the values stylix defaulted to, so nothing
# resizes when its targets stop setting them. Consumers that need pixels
# convert with the usual 4/3 factor.
{
  mono = "Mononoki Nerd Font Mono";
  propo = "Mononoki Nerd Font Propo";
  emoji = "Noto Color Emoji";

  sizes = {
    applications = 12;
    desktop = 10;
    popups = 10;
    terminal = 12;
  };
}
