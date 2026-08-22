# Window colours for the transparent VS Code build (./vscode-vibrancy).
#
# The patch makes the WINDOW transparent; the page still paints over it, so
# every background VS Code draws has to carry alpha or the result is a
# see-through frame around an opaque editor. These are those colours.
#
# The key lists and the per-tier alphas are ported from the extension's own
# computeVibrancyColors (extension/file-transforms.js) rather than picked by
# eye -- it has already worked out which surfaces may go fully clear, which
# need to stay legible, and which must not (dropdowns over text). The colour
# is the base16 scheme's base00, so this follows the palette, and the alpha
# comes from the shared opacity knob, so it moves with the terminal and the
# shell rather than drifting on its own.
{ colors, opacity }:
let
  inherit (colors.withHashtag) base00;

  # #rrggbb + 2-hex alpha, the form VS Code's colorCustomizations accept.
  # Mirrors the extension's computeTransparentHex.
  withAlpha =
    a:
    let
      byte = builtins.floor (a * 255.0 + 0.5);
      hex = "0123456789abcdef";
      hi = builtins.substring (byte / 16) 1 hex;
      lo = builtins.substring (byte - (byte / 16) * 16) 1 hex;
    in
    "${base00}${hi}${lo}";

  # Fully clear: these sit on top of the editor surface, so tinting them again
  # would stack a second layer of the same colour and darken it.
  transparent = [
    "editorPane.background"
    "editorGroupHeader.tabsBackground"
    "editorGroupHeader.noTabsBackground"
    "breadcrumb.background"
    "editorGutter.background"
    "panel.background"
    "tab.activeBackground"
    "tab.unfocusedActiveBackground"
  ];

  # The actual glass: the large surfaces the wallpaper shows through.
  semitransparent = [
    "sideBar.background"
    "sideBarTitle.background"
    "activityBar.background"
    "editor.background"
    "tab.inactiveBackground"
    "tab.unfocusedInactiveBackground"
  ];

  # Sticky scroll overlaps the code it is pinned above, so it needs to stay
  # readable against moving content. The extension floors it at 0.75.
  stickyScroll = [
    "editorStickyScroll.background"
    "editorStickyScrollGutter.background"
    "sideBarStickyScroll.background"
    "panelStickyScroll.background"
    "terminalStickyScroll.background"
  ];

  # Nearly opaque on purpose: popups, hovers and menus land on top of text, and
  # transparent ones are unreadable. 0.9 is the extension's value.
  opaque = [
    "inlineChat.background"
    "editorWidget.background"
    "editorHoverWidget.background"
    "editorSuggestWidget.background"
    "notifications.background"
    "notificationCenterHeader.background"
    "menu.background"
    "quickInput.background"
  ];

  mk =
    keys: alpha:
    builtins.listToAttrs (
      map (k: {
        name = k;
        value = withAlpha alpha;
      }) keys
    );
in
mk transparent 0.0
// mk semitransparent opacity
// mk stickyScroll (if opacity > 0.75 then opacity else 0.75)
// mk opaque 0.9
