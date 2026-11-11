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
  # see home-manager/hosts/bellona.nix (backend.sessionTokenFile).
  "hermes-gateway-token.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };

  # bellona homelab. every one of these is encrypted to ethie's devices plus
  # her user key on bellona, so luna can decrypt them for verification and the
  # box can read them at activation.
  "authelia-jwt.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  "authelia-storage-key.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  "authelia-session-secret.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  # scoped Cloudflare API token (Zone.DNS edit on packet.dog only), read by
  # security.acme for the DNS-01 wildcard.
  "cloudflare-dns-token.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  # one SMB credential file: `username=ethernet` + `password=...`. it is both
  # the CIFS credentials file on the clients and the EnvironmentFile that seeds
  # smbpasswd on bellona.
  "bellona-smb.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  # slskd Soulseek credentials (SLSKD_SOULSEEK_USERNAME/PASSWORD).
  "slskd-env.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  "grafana-admin.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  "homelab-api-token.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  # Home Assistant long-lived token for homelab-api's presence lookup.
  "ha-token.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  # Real-Debrid WebDAV credentials: `username=` + `password=` lines, where the
  # password is the account's WebDAV password (account settings), not the API
  # token. consumed by the rclone mount in nixos/bellona/debrid.nix.
  "real-debrid-webdav.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
  "restic-password.age" = {
    publicKeys = keys.home-devices ++ [ keys.bellona-user ];
  };
}
