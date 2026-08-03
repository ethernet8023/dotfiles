{ config, ... }:
{
  networking.hostName = "iris";
  networking.localHostName = "iris";
  networking.computerName = "iris";

  me = (import ../../hosts.nix).iris;

  # keep the ssh key that agenix uses authorized for luna -> iris
  users.users.${config.me.username}.openssh.authorizedKeys.keys =
    let
      keys = import ../../ssh-pubkeys.nix;
    in
    with keys;
    [
      luna
      hermes
      android
    ];
}
