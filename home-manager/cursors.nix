# Cursor theme, both halves of the light/dark toggle.
#
# Not a migration: nothing was setting a cursor theme at all. `cursor-theme` was
# unset in dconf and absent from gtk-3.0/settings.ini, so the pointer was
# whatever Adwaita default each toolkit fell back to. Stylix has no cursor
# target (see .hermes/plans/remove-stylix.md).
#
# catppuccin-cursors ships one derivation per flavour+accent, in both xcursor
# and hyprcursor form, so the lavender pair matches the base07 accent used for
# the shell, the window borders and the Hermes skin.
#
# There is deliberately no `home.pointerCursor` here. That option writes a
# SINGLE theme name into the session environment, the GTK settings.ini files and
# ~/.icons, fixed for the whole generation -- which is wrong the moment the mode
# is toggled, and cannot be corrected without a rebuild. Noctalia owns the
# cursor instead, from its `started` and `theme_mode_changed` hooks
# (see noctalia.nix), which between them cover login and every later change.
#
# This module therefore only installs the two themes. Everything that selects
# one happens at runtime.
{ pkgs, ... }:
let
  cursors = import ./cursors-data.nix { inherit pkgs; };
in
{
  # Both variants, not just the active one: the hooks switch between them at
  # runtime and can only name a theme already on XCURSOR_PATH. Installing them
  # into the profile is what puts them there -- the profile's share/icons is
  # already on the default XCURSOR_PATH.
  home.packages = [
    cursors.dark.package
    cursors.light.package
  ];
}
