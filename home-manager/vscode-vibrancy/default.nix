# VS Code with a frameless, transparent window.
#
# Wraps pkgs.vscode and applies the two edits vscode-vibrancy-continued makes,
# at BUILD time in postFixup while $out is still writable -- so no extension is
# installed, nothing mutates /nix/store at runtime, and no elevation is needed.
# The editor stays a plain package that home-manager can point at.
#
# Linux only needs the transparency half. The extension's Windows path drives a
# native addon (SetWindowCompositionAttribute / DWM materials) and macOS calls
# setVibrancy, but Linux has no native blur API: a transparent window plus a
# blurring compositor IS the effect. That is why the runtime import and the
# `injectData` blob are absent here -- they carry the live `vscode_vibrancy.*`
# settings the extension assembles through the `vscode` API, which does not
# exist outside a running extension host and so cannot be produced honestly at
# build time. What remains is pure file transforms with no config dependency.
#
# So: this makes the window transparent. The BLUR is the compositor's job
# (hyprland.nix already configures it), and window opacity/colour are ordinary
# userSettings, not part of this patch.
#
# Re-verify when nixpkgs bumps vscode: the injection anchors move with VS Code
# releases. The patcher fails the build rather than silently emitting an
# unpatched editor, so a broken anchor shows up as a build error, not as a
# window that quietly is not transparent.
{
  lib,
  fetchFromGitHub,
  nodejs,
  vscode,
}:
let
  # Pinned to a commit, not a branch: these anchors are version-sensitive and a
  # moving ref would change the build output without anything in this repo
  # changing.
  vibrancySrc = fetchFromGitHub {
    owner = "illixion";
    repo = "vscode-vibrancy-continued";
    rev = "a71ac22b4bb9e2b088a12d1c240c577928c4f808";
    hash = "sha256-HusT91ST9JWKp/2ExJRr0WSuO2xmOHY256s1onUALfg=";
  };
in
vscode.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ nodejs ];

  postFixup = (old.postFixup or "") + ''
    node ${./vibrancy-patch.cjs} \
      "$out/lib/vscode/resources/app" \
      ${vibrancySrc}
  '';

  meta = (old.meta or { }) // {
    description = "${old.meta.description or "Visual Studio Code"} (frameless + transparent)";
  };
})
