{ pkgs }:

let
  # playwright comes from nix, not pip: nixpkgs patches the python package to point
  # at the exact chromium revision in playwright-driver.browsers. See pyproject.toml.
  pythonEnv = pkgs.python313.withPackages (ps: [ ps.playwright ]);
in
pkgs.mkShell {
  packages = with pkgs; [
    pythonEnv
    uv

    # credentials: `bw get item <name> --raw`
    bitwarden-cli

    # poking the local Beeper Desktop API + CSV spelunking
    jq
    sqlite

    playwright-driver.browsers

    # CIBC's Akamai edge kills headless chromium during the h2 handshake, so the
    # scraper must run genuinely headed. cage on the wlroots headless backend is a
    # real compositor with no visible window -- headed browser, cron-friendly.
    cage
    wayland-utils
  ];

  shellHook = ''
    export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    # uv installs manylinux wheels with native extensions (greenlet, matplotlib's
    # kiwisolver, ...) that link against libstdc++/zlib. NixOS has no /usr/lib, so
    # they must be reachable via LD_LIBRARY_PATH or every import blows up with
    # "libstdc++.so.6: cannot open shared object file".
    export LD_LIBRARY_PATH="${
      pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.glib ]
    }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    if [ ! -d .venv ]; then
      echo "cctrack: creating .venv"
      # --system-site-packages so the venv can see nix's playwright
      uv venv --system-site-packages --python ${pythonEnv}/bin/python3
    fi
    source .venv/bin/activate
    uv pip install -e '.[dev]' --quiet
  '';
}
