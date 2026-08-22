# The light half of the light/dark toggle.
#
# stylix carries exactly one scheme per generation -- the dark one it themes the
# whole system from -- so anything that wants to follow noctalia's mode toggle
# needs a second scheme built by hand. This is catppuccin-latte, mocha's
# official light counterpart, built through the same base16 library stylix
# itself uses (stylix.inputs.base16), so the attrs it returns are shaped exactly
# like config.lib.stylix.colors and drop into the same templates.
#
# Latte's role assignments match mocha's, including lavender in base07, so the
# accent used across the shell stays put across a toggle.
#
# Consumers: noctalia.nix (shell palette), ghostty.nix (light terminal theme),
# vscode.nix (light editor theme).
{ pkgs, inputs }:
(inputs.stylix.inputs.base16.lib pkgs).mkSchemeAttrs "${pkgs.base16-schemes}/share/themes/catppuccin-latte.yaml"
