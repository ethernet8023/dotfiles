{
  pkgs,
  config,
  lib,
  ...
}:
{
  services.home-assistant = {
    enable = true;
    extraComponents = [
      "esphome"
      "met"
      "radio_browser"
      "hue"
      "roku"
      "cast"
      "govee_ble"
      "govee_light_local"
    ];
    customComponents = [
      (pkgs.callPackage ./govee-led.nix { })
    ];
    config = {
      default_config = { };
    };
  };

  # `openFirewall` was removed upstream (mkRemovedOptionModule): the frontend
  # port is no longer set in YAML, so it cannot be known at eval time. It was
  # the only thing exposing home-assistant here -- caddy.nix does not proxy it
  # and 8123 is not in sol's port list -- so the port is opened explicitly
  # rather than dropped along with the option.
  networking.firewall.allowedTCPPorts = [ 8123 ];
}
