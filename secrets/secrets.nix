let
  keys = import ../ssh-pubkeys.nix;
in
{
  "ethie-passwd.age" = {
    publicKeys = [
      keys.luna
      keys.hermes
    ];
  };
  "netrc.age" = {
    publicKeys = keys.home-devices;
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
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
}
