# Surface opacity, as plain data.
#
# Was `stylix.opacity`. Kept as a shared file for the same reason font.nix is:
# several modules need the same numbers, and hyprland's blur only has an effect
# where a surface is translucent -- these values are the alpha side of the blur
# configured in hyprland.nix.
#
# Argument-free so it can be imported from a `let` block anywhere.
{
  # Ghostty. Also the value firefox.nix mixes its chrome toward.
  terminal = 0.85;

  # Browser chrome and other application windows.
  applications = 0.85;

  # Noctalia's popups: dock, notifications, OSD.
  popups = 0.85;

  # Noctalia's desktop-level surfaces.
  desktop = 0.8;
}
