# nix/pkgs/beeper-cli.nix -- the `beeper` CLI (github:beeper/cli), from their
# release tarball.
#
# Why this exists at all: the CLI is what talks to a Beeper target, and on
# bellona it is also what installs and supervises Beeper Server itself
# (`beeper install server`, `beeper targets enable server`). nixpkgs only
# packages Beeper Desktop (`pkgs.beeper`), which needs a display; this is the
# headless path.
#
# Why a binary and not a source build: upstream is a Bun workspace and only
# publishes the rolled-up single-file executable. It is not a thin launcher --
# stripping it drops the embedded bundle and the binary silently starts
# behaving as plain `bun` (`--version` prints bun's version), hence dontStrip.
#
# First run unpacks that embedded payload (~390MB of node_modules) into
# $BEEPER_CLI_BINARY_CACHE_DIR or ~/.cache/beeper-cli/binary by shelling out
# to `tar -xzf`, so tar and gzip have to be on PATH. The payload was rolled up
# on macOS, so GNU tar otherwise prints an AppleDouble xattr warning per file;
# TAR_OPTIONS silences it.
#
# Beeper Server itself is NOT part of this package: it comes from Beeper's
# update feed (a feed URL + JSON, which nix cannot resolve), so the CLI
# downloads it into ~/.beeper and updates it with `beeper update --server`.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  gnutar,
  gzip,
  zlib,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "beeper-cli";
  version = "0.6.4";

  src = fetchurl {
    url = "https://github.com/beeper/cli/releases/download/v${finalAttrs.version}/beeper-cli-${finalAttrs.version}-linux-x64.tar.gz";
    hash = "sha256-etZp/32P0gMujDJO3CeeyxgoL2KOEaBr6rF7enS63oo=";
  };

  # the tarball has no root directory: it unpacks ./bin/beeper into cwd.
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    zlib
    stdenv.cc.cc.lib
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/beeper $out/bin/beeper
    wrapProgram $out/bin/beeper \
      --prefix PATH : ${lib.makeBinPath [gnutar gzip]} \
      --set-default TAR_OPTIONS --warning=no-unknown-keyword

    runHook postInstall
  '';

  meta = {
    description = "One CLI for all your chats, backed by Beeper Desktop or Beeper Server";
    homepage = "https://github.com/beeper/cli";
    license = lib.licenses.mit;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = ["x86_64-linux"];
    mainProgram = "beeper";
  };
})
