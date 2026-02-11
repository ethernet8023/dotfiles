{
  lib,
  config,
  ...
}:
{
  # try to mount the samba share on boot!
  # Create the activation script for smbpasswd
  system.activationScripts.smbpasswd = lib.stringAfter [ "users" "groups" ] ''
    SMB_PASSWORD=$(cat ${config.age.secrets.sol-smbpasswd.path})
    echo "username=ethie" > /etc/smb-creds
    echo "password=$SMB_PASSWORD" >> /etc/smb-creds
  '';

  fileSystems."/mnt/storage" = {
    device = "//sol/storage";
    fsType = "cifs";
    options = [
      "x-systemd.automount"
      "x-systemd.requires=tailscaled.service"
      "x-systemd.idle-timeout=60"
      "x-systemd.mount-timeout=30"
      "users"
      "rw"
      "credentials=/etc/smb-creds"
      "dir_mode=0777"
      "file_mode=0777"
    ];
  };
}
