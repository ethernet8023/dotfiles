{ config, ... }:
{
  networking.hostName = "iris";
  networking.localHostName = "iris";
  networking.computerName = "iris";

  me = (import ../../hosts.nix).iris;

  # phone as the nfc card reader; options: tapbridge/docs/nix-darwin.md
  programs.tapbridge.enable = false;

  # the mesh (see ssh-pubkeys.nix); keeps agenix identity + machine ssh working
  users.users.${config.me.username}.openssh.authorizedKeys.keys =
    let
      keys = import ../../ssh-pubkeys.nix;
    in
    keys.mesh ++ [
      # the android key has always landed here too
      keys.android
    ];
}
