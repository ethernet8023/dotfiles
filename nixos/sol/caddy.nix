{ config, pkgs, ... }:

let
  domain = "home.ari.computer";

  services = {
    ${toString config.services.slskd.openPorts.first} = "api";
    # 8888 = "dashboard";
    # 9000 = "metrics";
  };

  mkCaddyProxy = port: subdomain: ''
    ${subdomain}.${domain} {
      reverse_proxy localhost:${toString port}
      tls {
        issuer acme
      }
    }
  '';

  caddyConfig =
    let
      proxyConfigs = pkgs.lib.mapAttrsToList mkCaddyProxy services;
    in
    pkgs.lib.concatStringsSep "\n" proxyConfigs;

in
{
  services.caddy = {
    enable = true;

    configFile = pkgs.writeText "Caddyfile" caddyConfig;
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
