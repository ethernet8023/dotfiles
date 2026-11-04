# SMB client mounts for the nixos fleet. bellona serves the shares; every
# other nixos host mounts them lazily through systemd automount, so a laptop
# that is away from the house does not block boot.
#
# the credential file is the agenix secret `bellona-smb` (username=ethernet,
# password=...). Windows cannot use this file; see docs/windows-rekordbox-smb.md.
{ config, lib, ... }:
let
  cred = config.age.secrets.bellona-smb.path;
  uid = toString config.users.users.${config.me.username}.uid;
  gid = toString config.users.groups.users.gid;

  mount =
    { share, ro }:
    {
      device = "//192.168.2.59/${share}";
      fsType = "cifs";
      options = [
        "credentials=${cred}"
        "uid=${uid}"
        "gid=${gid}"
        (if ro then "ro" else "rw")
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=300"
        "nofail"
        "_netdev"
        "vers=3.0"
      ];
    };
in
{
  age.secrets.bellona-smb.file = ../secrets/bellona-smb.age;

  fileSystems."/mnt/bellona/music" = mount {
    share = "music";
    ro = true;
  };
  fileSystems."/mnt/bellona/rekordbox" = mount {
    share = "rekordbox";
    ro = false;
  };
  fileSystems."/mnt/bellona/vault" = mount {
    share = "vault";
    ro = false;
  };
}
