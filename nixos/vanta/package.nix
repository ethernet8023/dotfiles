# vanta device-monitor agent, repackaged from vanta's own .deb.
#
# shaped like `pkgs.osquery` so we can use the nixpkgs osquery service.
# only needs `bin/osqueryd` and `bin/osqueryi`, so this drops in as
# `services.osquery.package`. here `bin/osqueryd` is not osquery itself, it is
# vanta's `metalauncher`, which supervises the real osqueryd + the vanta
# extension and talks to vanta's backend.
{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  stdenv,
  makeWrapper,
  coreutils,
  diffutils,
  jq,
  lsb-release,
}:
let
  version = "2.20.0";
in
stdenvNoCC.mkDerivation {
  pname = "vanta";
  inherit version;

  # versioned URL, not https://app.vanta.com/osquery/download/linux: that one
  # 302s to whatever is newest and would break the hash on every vanta release.
  src = fetchurl {
    url = "https://agent-downloads.vanta.com/targets/versions/${version}/vanta-amd64.deb";
    hash = "sha256-QuZ+K4dXI5YZ8qKqgJPcMrkbiKpFwtFThjYJf8S2PaY=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];
  # only the bundled osqueryd is dynamically linked (libc family); the go
  # binaries are static and autoPatchelf leaves them alone.
  buildInputs = [ stdenv.cc.cc.lib ];

  unpackPhase = "dpkg-deb -x $src .";

  # stripping would only risk the static go binaries for no gain.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    # the agent hardcodes /var/vanta/<file>; the real files live in the store
    # and the osqueryd wrapper below installs them into /var/vanta at start.
    mkdir -p $out/libexec/vanta $out/bin
    cp var/vanta/* $out/libexec/vanta/

    # same name `vanta-cli` the deb exposes via /usr/local/bin.
    ln -s $out/libexec/vanta/vanta-cli $out/bin/vanta-cli

    # `osqueryi` = the bundled osquery in shell mode (the nixpkgs module wraps
    # this for the system-wide `osqueryi`).
    makeWrapper $out/libexec/vanta/osqueryd $out/bin/osqueryi --add-flags -S

    # `osqueryd` = what services.osquery execs. it ignores the module's
    # --flagfile: vanta's launcher passes its own flags to the real osqueryd.
    cat > $out/bin/osqueryd <<'WRAPPER'
    #!${stdenv.shell}
    set -eu
    export PATH=${
      lib.makeBinPath [
        coreutils
        diffutils
        jq
        # the agent shells out to lsb_release for the os name/version; nixos
        # has none on PATH, so without this the os version is reported blank.
        lsb-release
      ]
    }
    export VANTA_REGION=us

    libexec=@out@/libexec/vanta

    # copied, not symlinked: the launcher refuses binaries that are writable by
    # non-root, and a symlink is always mode 777. cmp keeps restarts cheap, and
    # re-copying also resets anything the agent self-updated, which pins us to
    # the version in the store.
    mkdir -p /var/vanta
    for f in "$libexec"/*; do
      dest="/var/vanta/$(basename "$f")"
      if ! cmp -s "$f" "$dest"; then
        install -m 0755 -o root -g root "$f" "$dest.new"
        mv -f "$dest.new" "$dest"
      fi
    done

    # equivalent of the deb's postinst: VANTA_KEY + VANTA_OWNER_EMAIL (from the
    # unit's EnvironmentFile) become /etc/vanta.conf. only rewritten when they
    # change, because the nonce below re-requests activation and the agent
    # edits this file itself once registered.
    if [ -n "''${VANTA_KEY:-}" ] && [ -n "''${VANTA_OWNER_EMAIL:-}" ]; then
      if ! jq -e --arg k "$VANTA_KEY" --arg e "$VANTA_OWNER_EMAIL" \
           '.AGENT_KEY == $k and .OWNER_EMAIL == $e' /etc/vanta.conf >/dev/null 2>&1; then
        umask 077
        jq -n --arg k "$VANTA_KEY" --arg e "$VANTA_OWNER_EMAIL" --arg r "$VANTA_REGION" \
          --argjson n "$(date +%s000)" \
          '{ACTIVATION_REQUESTED_NONCE: $n, AGENT_KEY: $k, OWNER_EMAIL: $e, REGION: $r, NEEDS_OWNER: true}' \
          > /etc/vanta.conf.tmp
        mv /etc/vanta.conf.tmp /etc/vanta.conf
      fi
    elif [ ! -e /etc/vanta.conf ]; then
      echo "VANTA_KEY / VANTA_OWNER_EMAIL not set and no /etc/vanta.conf; agent will be unregistered" >&2
    fi

    exec /var/vanta/metalauncher
    WRAPPER
    substituteInPlace $out/bin/osqueryd --subst-var out
    chmod +x $out/bin/osqueryd

    runHook postInstall
  '';

  meta = {
    description = "Vanta device monitoring agent (repackaged .deb)";
    homepage = "https://vanta.com";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "vanta-cli";
  };
}
