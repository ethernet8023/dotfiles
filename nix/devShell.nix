{ pkgs }:

pkgs.mkShell {
  packages = with pkgs; [
    python313
    uv

    # credentials: `bw get item <name> --raw`
    bitwarden-cli

    # poking the local Beeper Desktop API + CSV spelunking
    jq
    sqlite

    # playwright needs a real chromium; nix provides a matched driver+browser pair
    playwright-driver.browsers
  ];

  shellHook = ''
    export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    if [ ! -d .venv ]; then
      echo "cctrack: creating .venv"
      uv venv --python ${pkgs.python313}/bin/python3
    fi
    source .venv/bin/activate
    uv pip install -e '.[dev]' --quiet
  '';
}
