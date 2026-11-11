{ lib, ... }:
{
  imports = [
    ./storage.nix
    ./ingress.nix
    ./observability.nix
    ./apps.nix
    ./debrid.nix
    ./hermes-webapp.nix
  ];

  options.me.bellona = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "the whole bellona homelab stack";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "packet.dog";
    };
    lanAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.2.59";
    };
    zigbee.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "zigbee2mqtt; flip on once a coordinator is plugged in";
    };
  };
}
