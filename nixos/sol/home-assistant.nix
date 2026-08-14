{
  pkgs,
  config,
  lib,
  ...
}:
{
  services.home-assistant = {
    enable = true;
    openFirewall = true;
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
}
