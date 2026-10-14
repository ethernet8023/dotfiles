# vanta device monitoring, run as nixos's own services.osquery with a custom pkg.
{ config, pkgs, ... }:
let
  # osquery's deb_packages table parses /var/lib/dpkg/status, and vanta-cli
  # `list packages` reads that table; nixos has no dpkg, so the table is empty.
  # write a status file from the system closure so it lists what's installed.
  dpkgStatus = pkgs.writeShellScript "nix-dpkg-status" ''
    set -eu
    export PATH=${
      pkgs.lib.makeBinPath [
        config.nix.package
        pkgs.gawk
        pkgs.coreutils
      ]
    }
    out=$1; shift
    nix-store -qR "$@" | awk '
      { sub(/^\/nix\/store\/[a-z0-9]{32}-/, "") }
      /\.(drv|patch|sh|py|nix|json|conf|service|socket|target)$/ { next }
      {
        # trailing word-only suffixes are output/variant names, not part of the
        # version (glibc-2.42-51-bin, git-2.55.0-fish-completions).
        while (/-[0-9]/ && sub(/[-_][a-z][a-z_-]*$/, ""));
        if (!match($0, /-[0-9][^ ]*$/)) next
        name = substr($0, 1, RSTART - 1)
        ver = substr($0, RSTART + 1)
        # dpkg versions only allow [A-Za-z0-9.+~:-]
        gsub(/[^A-Za-z0-9.+~:-]/, ".", ver)
        if (name != "") print name "\t" ver
      }' | sort -t "$(printf '\t')" -k1,1 -k2,2V | awk -F '\t' '
      # dpkg status allows one stanza per name; several store versions of one
      # package collapse to the newest.
      { latest[$1] = $2 }
      END {
        for (n in latest)
          printf "Package: %s\nStatus: install ok installed\nPriority: optional\nSection: nix\nInstalled-Size: 0\nMaintainer: nixpkgs\nArchitecture: amd64\nVersion: %s\nDescription: nix store path %s-%s\n\n", n, latest[n], n, latest[n]
      }' > "$out.tmp"
    mv "$out.tmp" "$out"
  '';
in
{
  # edit with `agenix -e vanta.age` from secrets
  age.secrets.vanta.file = ../../secrets/vanta.age;

  services.osquery = {
    enable = true;
    package = pkgs.callPackage ./package.nix { };
  };

  # the deb's vanta.service is replaced by osqueryd.service, which runs
  # vanta's launcher; the secrets reach it as plain env vars.
  systemd.services.osqueryd.serviceConfig.EnvironmentFile = config.age.secrets.vanta.path;

  # runs on every switch and at boot; $systemConfig is the generation being
  # activated (/run/current-system is not updated yet at this point).
  system.activationScripts.vantaDpkgStatus = ''
    mkdir -p /var/lib/dpkg
    ${dpkgStatus} /var/lib/dpkg/status "$systemConfig"
  '';

  # vanta-cli on PATH (the module already adds osqueryi).
  environment.systemPackages = [ config.services.osquery.package ];
}
