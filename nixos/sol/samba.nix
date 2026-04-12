{
  pkgs,
  config,
  lib,
  ...
}:
{
  services.samba = {
    enable = true;
    nmbd.enable = true;
    winbindd.enable = true;
    openFirewall = true;
    settings = {
      global = {
        security = "user";
        workgroup = "WORKGROUP";
        "server string" = "sol";
        "server role" = "standalone server";
        "map to guest" = "Bad User";
        "guest account" = "nobody";
      };
      "public" = {
        "path" = "/mnt/storage/public";
        "browseable" = "yes";
        "public" = "yes";
        "guest only" = "yes";
        "read only" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force create mode" = "0644";
        "force directory mode" = "0755";
      };
      "storage" = {
        "path" = "/mnt/storage";
        "browseable" = "yes";
        "guest ok" = "no";
        "read only" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force create mode" = "0644";
        "force directory mode" = "0755";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  services.avahi.extraServiceFiles.smb = ''
    <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h</name>
      <service>
        <type>_smb._tcp</type>
        <port>445</port>
      </service>
    </service-group>
  '';

  # at activation time, sub in the samba password.
  system.activationScripts.sambaUserPassword = lib.stringAfter [ "users" "groups" ] ''
    SMB_PASSWORD=$(cat ${config.age.secrets.sol-smbpasswd.path})
    echo -e "$SMB_PASSWORD\n$SMB_PASSWORD" | ${pkgs.samba}/bin/smbpasswd -s -a ethie
  '';
}
