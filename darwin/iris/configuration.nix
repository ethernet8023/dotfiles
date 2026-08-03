{ config, ... }:
{
  networking.hostName = "iris";
  networking.localHostName = "iris";
  networking.computerName = "iris";

  # macbook: username is `ethernet`, and darwin homes live under /Users
  me.username = "ethernet";
  me.homeDirectory = "/Users/ethernet";

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
