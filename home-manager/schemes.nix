# The two base16 schemes this config is themed from.
#
# Both halves of the light/dark toggle in one place, built through
# SenchoPens/base16.nix -- the same library stylix uses internally, so
# `mkSchemeAttrs` returns the attrset shape every consumer here already expects
# (base00..base0F, plus the `withHashtag` variant and the `-rgb-r` style
# derivatives). Swapping a consumer from `config.lib.stylix.colors` to
# `(import ./schemes.nix { ... }).dark` is a rename, not a rewrite.
#
# base16.nix is a direct flake input rather than `stylix.inputs.base16`: the
# palette is used by several modules in their own right, and stylix is being
# removed (see .hermes/plans/remove-stylix.md).
#
# Catppuccin mocha and latte are counterparts, and their role assignments match
# -- including lavender in base07, which is the accent used across the shell,
# the window borders and the Hermes skin. So one role table maps both.
{ pkgs, inputs }:
let
  mkScheme =
    name: (inputs.base16.lib pkgs).mkSchemeAttrs "${pkgs.base16-schemes}/share/themes/${name}.yaml";
in
{
  dark = mkScheme "catppuccin-mocha";
  light = mkScheme "catppuccin-latte";
}
