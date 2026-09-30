# Stylus's storage.local file, generated from catppuccin's own userstyle export
# so the installed styles are whatever upstream currently ships.
#
# Stylus has no file-based install, and its styles normally live in IndexedDB,
# which nothing outside the browser can write. But it has a fallback backend
# that keeps every style as a `style-<id>` key in storage.local, switched on by
# the `dbInChromeStorage` flag. This profile already runs storage.local on the
# legacy JSON file (ExtensionStorageIDB.enabled = false), so a file at
# browser-extension-data/<id>/storage.js is enough.
#
# The styles have to be fully built. On startup Stylus keeps a stored style only
# if it already has compiled `sections`; a style with just its `sourceCode`
# (what the export contains) is dropped, not rebuilt. So build-storage.mjs runs
# Stylus's own less + section-splitting code, from the addon package, over every
# style. That is the same work Stylus does when you click Import.
#
# Not reachable from here: Stylus's own prefs (update interval, "patch CSP")
# live in storage.sync, a separate backend. Set those once in the UI.
{
  pkgs,
  inputs,
  stylusXpi,
  darkFlavor,
  lightFlavor,
  accent,
}:
pkgs.runCommand "stylus-catppuccin-storage.js"
  {
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.unzip
    ];
    pins = builtins.toJSON {
      accentColor = accent;
      inherit darkFlavor lightFlavor;
    };
  }
  ''
    mkdir js
    unzip -j ${stylusXpi} js/usercss-compiler.js js/less.js js/moz-parser.js js/parserlib.js -d js
    node ${./catppuccin-userstyles/build-storage.mjs} js \
      ${inputs.catppuccin-userstyles-export} \
      ${inputs.catppuccin-userstyles-lib} \
      $out "$pins"
  ''
