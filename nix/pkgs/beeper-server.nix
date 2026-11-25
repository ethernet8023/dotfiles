# nix/pkgs/beeper-server.nix -- the headless Beeper Server runtime, from
# Beeper's own build CDN.
#
# Why not let `beeper install server` do it: the CLI downloads a generic-linux
# binary with interpreter /lib64/ld-linux-x86-64.so.2, and on NixOS that path
# is stub-ld, so the process dies with "Could not start dynamically linked
# executable" before it ever binds a port. Fixing the interpreter here means
# nothing about the box has to change (no nix-ld) and the version moves with
# the flake instead of with a runtime download.
#
# Why hand-rolled patchelf instead of autoPatchelfHook: this is a Node
# single-executable-application launcher (it unpacks app/build/main/server.mjs
# into ~/.cache/BeeperServer on first run), and patchelf's RPATH rewrite makes
# it segfault on startup -- verified by bisecting the two: setting the
# interpreter alone runs, adding --set-rpath core dumps. So the loader is
# patched and libstdc++ comes in through LD_LIBRARY_PATH on the wrapper instead.
#
# The build URL is versioned on the CDN, which is what makes pinning possible;
# `beeper update --server`'s feed is where to look for bumps. This binary is
# what BEEPER_SERVER_BIN points at in home-manager/hosts/bellona.nix, so
# `beeper targets start` and the unit both run this copy rather than a
# downloaded one.
#
# dontStrip is load-bearing: stripping drops the embedded payload and leaves a
# binary that behaves as plain node.
{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "beeper-server";
  version = "4.3.340";

  src = fetchurl {
    url = "https://beeper-desktop.download.beeper.com/builds/beeper-server-${finalAttrs.version}-linux-x64.tar.gz";
    hash = "sha256-k2TL6JBdUyFcqzHKXPmj75VB6D6LlaOVspX1vcumv1c=";
  };

  nativeBuildInputs = [
    patchelf
    makeWrapper
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 beeper-server $out/libexec/beeper-server
    patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} $out/libexec/beeper-server

    # ldd on the downloaded binary: libdl, libstdc++, libm, libgcc_s,
    # libpthread, libc -- everything but libstdc++ comes from the loader's own
    # closure.
    makeWrapper $out/libexec/beeper-server $out/bin/beeper-server \
      --set LD_LIBRARY_PATH ${lib.makeLibraryPath [stdenv.cc.cc.lib]}

    runHook postInstall
  '';

  meta = {
    description = "Headless Beeper Server (self-hosted Beeper runtime)";
    homepage = "https://www.beeper.com";
    license = lib.licenses.unfree;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = ["x86_64-linux"];
    mainProgram = "beeper-server";
  };
})
