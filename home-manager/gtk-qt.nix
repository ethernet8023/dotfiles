# GTK and Qt theming, handed to noctalia.
#
# Noctalia ships builtin templates for gtk3, gtk4, qt (qt5ct + qt6ct) and
# kcolorscheme, and re-renders every template on a mode toggle
# (`m_templateApplyService.apply(generated, mode)`). That is live light/dark for
# every GTK and Qt app, which stylix's one-scheme-per-generation model cannot do
# (see .hermes/plans/remove-stylix.md).
#
# The two must not both own these files. Stylix's gtk target writes
# `gtk-3.0/gtk.css` and `gtk-4.0/gtk.css` through xdg.configFile, and noctalia's
# gtk/apply.sh appends an `@import url("noctalia.css")` to the same path --
# deleting the read-only store symlink to do it, with an explicit
# "Read-only symlink (e.g. NixOS): convert to a local file" branch. So the
# stylix colour aspects are switched off here, in the same change that turns the
# templates on.
#
# Trade-off accepted: those files stop being managed declaratively. Noctalia
# owns them at runtime and its undo hooks clean up if the templates are ever
# turned back off.
#
# One rough edge, by design rather than accident: home-manager still writes
# `gtk-4.0/gtk.css`, because GTK4 ignores gtk-theme-name and HM imports the
# theme CSS there for the `gtk4.theme` set below. Noctalia's apply.sh APPENDS
# its @import to whatever that file already holds (it reads the content first),
# so the adw-gtk3 import survives and the noctalia colours land after it -- the
# right order. It does replace the store symlink with a real file to do so;
# `home-manager.backupFileExtension` is set globally, so the next switch moves
# that aside as .hm-backup rather than failing, and the next toggle re-appends.
# Untidy, not broken.
#
# Noctalia's templates render from ITS palette (colors.surface, colors.primary,
# ...), not base16 directly, so GTK and Qt follow the material-you palette
# derived from the custom catppuccin scheme in noctalia.nix rather than the
# base16 slots exactly.
{ pkgs, config, ... }:
let
  fonts = import ./font.nix;
in
{
  # `gtk.theme` is deliberately NOT set. It would only write
  # `gtk-theme-name=adw-gtk3` into settings.ini, fixed for the generation, while
  # noctalia's gtk apply.sh writes the same key to dconf and flips it between
  # `adw-gtk3` and `adw-gtk3-dark` on every toggle. dconf wins, so the static
  # line is dead -- and worse, it disagrees after the first toggle. Verified by
  # asking GTK itself: with dconf at adw-gtk3-dark and settings.ini at
  # adw-gtk3, `Gtk.Settings.get_default()` resolved `gtk-theme-name` to
  # adw-gtk3-dark.
  #
  # The font is a different case and does stay here: nothing else writes
  # gtk-font-name, and the same probe resolved it from settings.ini.
  gtk = {
    enable = true;
    font = {
      name = fonts.propo;
      size = fonts.sizes.applications;
    };
  };

  # Both variants have to be installed even though neither is named above:
  # apply.sh looks them up in the usual theme directories and skips the switch
  # when the target one is missing. adw-gtk3 ships both in one package.
  home.packages = [ pkgs.adw-gtk3 ];

  # qt5ct/qt6ct read the colour scheme files noctalia writes. The platform theme
  # still has to point at qtct for them to be consulted at all.
  qt = {
    enable = true;
    platformTheme.name = "qtct";
  };

  # ...and qtct has to be told to USE that scheme. The noctalia qt template
  # writes only `qt5ct/colors/noctalia.conf`, a palette file with no hook that
  # activates it (see [templates.qt] in its builtin.toml: an output_path pair
  # and an undo_hook, no post_hook). Without these two files, `custom_palette`
  # stays off, nothing points at the palette, and every Qt app renders with the
  # stock one -- which is exactly the state disabling the stylix qt target left
  # behind, since stylix was the thing writing qt5ct.conf.
  #
  # Noctalia never touches qt5ct.conf itself, only colors/noctalia.conf, so this
  # can stay a declarative store symlink with no writer conflict.
  #
  # style=Fusion because Kvantum came from the stylix qt target and went with
  # it; Fusion is the standard palette-respecting Qt style, so the scheme
  # actually shows up.
  xdg.configFile =
    let
      qtctConf = variant: ''
        [Appearance]
        custom_palette=true
        color_scheme_path=${config.xdg.configHome}/${variant}/colors/noctalia.conf
        standard_dialogs=default
        style=Fusion

        [Fonts]
        fixed="${fonts.mono},${toString fonts.sizes.applications}"
        general="${fonts.propo},${toString fonts.sizes.applications}"
      '';
    in
    {
      "qt5ct/qt5ct.conf".text = qtctConf "qt5ct";
      "qt6ct/qt6ct.conf".text = qtctConf "qt6ct";
    };
}
