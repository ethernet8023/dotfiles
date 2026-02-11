let
  keys = import ../ssh-pubkeys.nix;
in
{
  "sol-smbpasswd.age".publicKeys = [
    keys.luna
    keys.sol
    keys.hermes
  ];
  "ethie-passwd.age".publicKeys = [
    keys.luna
    keys.sol
    keys.hermes
    keys.casey
  ];
  "netrc.age".publicKeys = keys.home-devices;
}
