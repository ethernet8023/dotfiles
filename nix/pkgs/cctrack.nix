# nix/pkgs/cctrack.nix — the CIBC statement downloader + budget tracker, built
# from projects/cctrack.
#
# Why this is a nix build and not a pip install on the box:
#
#   * the venv is sealed from projects/cctrack/uv.lock via uv2nix, so the
#     service bellona runs is the same closure on every switch, and
#     `nix develop .#cctrack` hands a developer exactly those versions. The
#     alternative -- `uv pip install` at boot -- means prod silently drifts
#     from what the tests ran against.
#   * the browser comes from camoufox-nix's prebuilt package rather than
#     `python -m camoufox fetch`. CIBC's Akamai edge drops Playwright's own
#     Chromium *and* Firefox during the h2 handshake, so the scraper needs
#     camoufox's patched Firefox, genuinely headed. Fetching it at runtime
#     would drop an unpinned ~130MB Firefox build in ~/.cache; this way the
#     browser version moves with the flake.
#
# camoufox 0.5 reads CAMOUFOX_EXECUTABLE_PATH (camoufox/utils.py:1072), so the
# wrapper points the library at the store browser and it never downloads one.
# camoufox-bin ships its own fonts.conf through FONTCONFIG_FILE, which is what
# keeps the fingerprint identical to upstream's launcher.
{
  lib,
  pkgs,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
  camoufox-nix,
  source ? ../../projects/cctrack,
}:
let
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = source; };

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  python = pkgs.python313;

  # camoufox pins fpgen's fingerprint model and installs it into fpgen's
  # site-packages on first launch. In the store that directory is read-only, so
  # the first browser launch dies with EROFS on `fpgen/data`. Fetch the exact
  # archive camoufox names (camoufox/fpgen-model.json, tag model-2/2026, same
  # sha256) and unpack it at build time instead. fpgen reads the .zst members in
  # place, so nothing needs decompressing on disk, and the .pinned-model stamp
  # is written here too -- camoufox writes it unconditionally at launch, and a
  # read-only write there is not caught.
  fpgenModel = pkgs.fetchurl {
    url = "https://github.com/scrapfly/fingerprint-generator/releases/download/model-2/2026/model-release.zip";
    sha256 = "6530b8322cdaa4ec042921c8d9a0369a0e6e0269ba636c01a7203e4a2f109936";
  };

  # Native extensions come out of manylinux wheels, which link against
  # libstdc++/zlib rather than nixpkgs' copies. uv2nix's wheel overlay runs
  # autoPatchelf on them; anything that still needs a hand gets an entry here.
  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    }).overrideScope
      (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
          # playwright ships its own node to run the driver, and that prebuilt
          # binary segfaults on NixOS the moment you start a browser ("Connection
          # closed while reading from the driver"). autoPatchelf satisfies its
          # libraries but the build still dies. nixpkgs' node runs the same
          # driver -- `node driver/package/cli.js --version` prints 1.62.0 -- so
          # swap the binary and keep the python package, because the lock pins
          # playwright 1.62.0 as the pair camoufox 0.5.9 expects.
          (final: prev: {
            playwright = prev.playwright.overrideAttrs (old: {
              postFixup = (old.postFixup or "") + ''
                rm -f "$out/${python.sitePackages}/playwright/driver/node"
                ln -s ${pkgs.nodejs}/bin/node \
                  "$out/${python.sitePackages}/playwright/driver/node"
              '';
            });

            fpgen = prev.fpgen.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.unzip ];
              postInstall = (old.postInstall or "") + ''
                data="$out/${python.sitePackages}/fpgen/data"
                mkdir -p "$data"
                unzip -q -o ${fpgenModel} -d "$data"

                # fpgen decides its model is stale by mtime, and nix normalises
                # every store file to 1970-01-01, so the "five weeks old" check
                # can never pass -- it would try to re-download into a read-only
                # directory. Existing files are the pin here (the archive's
                # sha256 was checked by fetchurl), so drop the recency test.
                substituteInPlace "$out/${python.sitePackages}/fpgen/pkgman.py" \
                  --replace-fail \
                    " and files_are_recent(FILE_PAIRS.values()):" \
                    ":"
              '';
            });

            # camoufox stamps the model's mtimes and writes a stamp file at every
            # launch; both writes fail on a read-only store, and the mtime branch
            # re-raises because the normalised mtime is ancient. The model is
            # already pinned in fpgen's derivation above and is_pinned() has
            # verified it, so stamping has nothing left to do.
            camoufox = prev.camoufox.overrideAttrs (old: {
              postInstall = (old.postInstall or "") + ''
                # the replacement is built with escapeShellArg rather than
                # written inline: an escaped newline inside an indented nix
                # string also swallows the indentation after it, which put the
                # inserted `return` at column 0 and made camoufox die at import
                # with "IndentationError: expected an indented block".
                substituteInPlace "$out/${python.sitePackages}/camoufox/fpgen_model.py" \
                  --replace-fail \
                    'def _stamp(data_dir: Path) -> None:' \
                    ${lib.escapeShellArg "def _stamp(data_dir: Path) -> None:\n    return"}
              '';
            });
          })
        ]
      );

  # Prod gets main dependencies only; pytest/ruff are the "dev" group and
  # belong in the devShell, not in the service's closure.
  venv = pythonSet.mkVirtualEnv "cctrack-env" {
    cctrack = [ ];
  };

  # Same set plus the dev group, for `nix develop .#cctrack`.
  devVenv = pythonSet.mkVirtualEnv "cctrack-dev-env" {
    cctrack = [ "dev" ];
  };

  browser = camoufox-nix.packages.${pkgs.stdenv.hostPlatform.system}.camoufox-bin;
in
pkgs.runCommand "cctrack-0.1.0"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru = {
      inherit venv devVenv browser;
      # The devShell runs the checkout, not this copy: `python -m cctrack.cli`
      # from projects/cctrack puts the working tree on sys.path while the venv
      # supplies the deps.
      pythonEnv = venv;
    };
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${venv}/bin/cctrack $out/bin/cctrack \
      --set CAMOUFOX_EXECUTABLE_PATH ${browser}/bin/camoufox \
      --prefix PATH : ${lib.makeBinPath [ pkgs.cage browser ]}

    # Keep the venv reachable for `nix develop` and for the snapshot helper,
    # without duplicating the closure.
    ln -s ${venv} $out/venv
  ''
