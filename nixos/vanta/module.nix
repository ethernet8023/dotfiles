# vanta device monitoring, run as nixos's own services.osquery with a custom pkg.
{ config, pkgs, ... }:
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

  # vanta-cli on PATH (the module already adds osqueryi).
  environment.systemPackages = [ config.services.osquery.package ];
}
