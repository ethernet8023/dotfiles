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
      keys.dollnet
    ];
  };
  "netrc.age" = {
    publicKeys = keys.home-devices;
  };
  "digitalocean-token.age" = {
    publicKeys = keys.home-devices ++ [ keys.dollnet ];
  };
  # vanta device monitor, luna + hermes only (nixos/vanta/module.nix)
  "vanta.age" = {
    publicKeys = [
      keys.luna
      keys.hermes
    ];
  };

  # shared hermes gateway session token: bellona's dashboard backend validates
  # it, and the desktops presenting it read their copy via age on each host.
  # see home-manager/hosts/dollnet.nix (backend.sessionTokenFile).
  "hermes-gateway-token.age" = {
    publicKeys = keys.physically-safe-devices ++ [ keys.bellona-user ];
  };
}
