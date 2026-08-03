let
  keys = import ../ssh-pubkeys.nix;
in
{
  "ethie-passwd.age" = {
    publicKeys = [
      keys.luna
      keys.sol
      keys.hermes
      keys.casey
    ];
  };
  "sol-smbpasswd.age" = {
    publicKeys = [
      keys.luna
      keys.sol
      keys.hermes
    ];
  };
  "netrc.age" = {
    publicKeys = keys.home-devices;
  };
  "digitalocean-token.age" = {
    publicKeys = keys.home-devices ++ [ keys.dollnet ];
  };
}
