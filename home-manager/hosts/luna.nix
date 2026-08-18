{ ... }:
{
  # luna-specific home config: the desktop with two 4K monitors, both mounted
  # physically portrait (transform 3, see ../hyprland.nix).
  #
  # Only differences from the shared graphical config belong here. Everything
  # else comes from home-graphical.nix.

  # A bar down the long edge of a portrait monitor eats a lot of vertical
  # space, and the short edge is cheap -- so run it horizontally along the
  # bottom rather than vertically like the laptop does. The keys overridden
  # here are mkDefault in ../waybar.nix.
  programs.waybar.settings.mainBar = {
    position = "bottom";
    # A horizontal bar takes its height from the modules; width is the
    # cross-axis size of a vertical bar and would squash this one. null drops
    # the key from the generated config entirely.
    width = null;
    margin-right = null;
    margin-bottom = 0;
  };
}
