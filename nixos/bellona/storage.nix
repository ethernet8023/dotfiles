# storage: the 12.7T USB disk becomes a ZFS pool, appdata stays on the NVMe.
#
# the disk is a WD easystore on USB. that is fine for a homelab but it is not
# enterprise storage: a USB reset can suspend a pool. when the second disk
# arrives, `zpool attach tank <new>` turns this single-disk pool into a mirror
# in place (no rebuild, no downtime).
#
# the pool does not exist yet, so a oneshot creates it on the first boot after
# the switch. it is idempotent: `zpool list` short-circuits when tank is there.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.me.bellona;
  disk = "/dev/disk/by-id/usb-WD_easystore_264D_504C473130543350-0:0";
in
{
  config = lib.mkIf cfg.enable {
    age.secrets.bellona-smb = {
      file = ../../secrets/bellona-smb.age;
      mode = "0400";
    };
    age.secrets.restic-password = {
      file = ../../secrets/restic-password.age;
      mode = "0400";
    };

    # ZFS needs a stable host id; dahlia's flake does not set one.
    networking.hostId = lib.mkDefault "b3110a7e";

    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.extraPools = [ "tank" ];
    boot.zfs.forceImportRoot = false;
    services.zfs.autoScrub.enable = true;

    services.sanoid = {
      enable = true;
      templates.production = {
        hourly = 24;
        daily = 30;
        monthly = 6;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
      datasets."tank" = {
        useTemplate = [ "production" ];
        recursive = true;
      };
    };

    systemd.services.bellona-tank-init = {
      description = "create the bellona tank pool and datasets";
      wantedBy = [ "multi-user.target" ];
      before = [
        "zfs-mount.service"
        "multi-user.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        for _ in $(seq 1 30); do
          [ -e ${disk} ] && break
          sleep 1
        done
        if ! ${pkgs.zfs}/bin/zpool list -H tank >/dev/null 2>&1; then
          ${pkgs.util-linux}/bin/wipefs -a ${disk}
          ${pkgs.zfs}/bin/zpool create -f -o ashift=12 \
            -O compression=zstd -O atime=off -O xattr=sa tank ${disk}
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/media -o recordsize=1M tank/media
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/photos -o recordsize=1M tank/photos
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/music -o recordsize=1M tank/music
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/music/library tank/music/library
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/music/inbox tank/music/inbox
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/music/archive tank/music/archive
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/rekordbox tank/rekordbox
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/traces tank/traces
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/logs tank/logs
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/vault -o recordsize=128K tank/vault
          ${pkgs.zfs}/bin/zfs create -o mountpoint=/tank/backups tank/backups
        fi
        ${pkgs.zfs}/bin/zfs mount -a || true

        # datasets mount as root-owned; hand them to the services that write.
        if id immich >/dev/null 2>&1; then
          install -d -o immich -g immich -m 0750 /tank/photos
        fi
        install -d -o root -g media -m 0775 /tank/music/library /tank/music/inbox /tank/music/archive
        install -d -o ethernet -g users -m 0750 /tank/rekordbox /tank/vault
        if id loki >/dev/null 2>&1; then
          install -d -o loki -g loki -m 0750 /tank/logs/loki
        fi
        install -d -o root -g root -m 0755 /tank/backups
        install -d -o ethernet -g users -m 0755 /tank/traces
      '';
    };

    # appdata / DBs stay on the NVMe; only bulk data and logs live on tank.
    systemd.tmpfiles.rules = [
      "d /srv/rekordbox 0700 ethernet users -"
      "d /var/lib/beets 0750 ethernet users -"
    ];

    users.groups.media = { };
    users.users.ethernet.extraGroups = [ "media" ];

    services.samba = {
      enable = true;
      openFirewall = false;
      settings = {
        global = {
          "workgroup" = "WORKGROUP";
          "server string" = "bellona";
          "security" = "user";
          "map to guest" = "Bad User";
          "interfaces" = "lo enp191s0";
          "bind interfaces only" = "yes";
          "server min protocol" = "SMB2";
        };
        music = {
          path = "/tank/music/library";
          "read only" = "yes";
          "browseable" = "yes";
          "valid users" = "ethernet";
          comment = "music library (read-only)";
        };
        rekordbox = {
          path = "/srv/rekordbox";
          "read only" = "no";
          "browseable" = "yes";
          "valid users" = "ethernet";
          "force user" = "ethernet";
          "create mask" = "0600";
          "directory mask" = "0700";
          comment = "rekordbox database (one writer at a time)";
        };
        vault = {
          path = "/tank/vault";
          "read only" = "no";
          "browseable" = "yes";
          "valid users" = "ethernet";
          "force user" = "ethernet";
          comment = "markdown knowledge vault";
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      139
      445
    ];

    # samba keeps its own passdb; seed it from the same agenix credential file
    # the CIFS clients use. runs every activation, so the password stays in
    # sync with the secret.
    systemd.services.bellona-samba-passwd = {
      description = "set the SMB password for ethernet";
      after = [ "samba-smbd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = config.age.secrets.bellona-smb.path;
      };
      script = ''
        printf '%s\n%s\n' "$password" "$password" | ${pkgs.samba}/bin/smbpasswd -s -a ethernet
      '';
    };

    # local restic repo for now. swap the repository for an S3/B2 URL once the
    # offsite story exists; paths are the irreplaceable subset only.
    services.restic.backups.tank = {
      initialize = true;
      repository = "/tank/backups/restic";
      passwordFile = config.age.secrets.restic-password.path;
      paths = [
        "/tank/photos"
        "/tank/vault"
        "/tank/rekordbox"
        "/srv/rekordbox"
      ];
      timerConfig = {
        OnCalendar = "03:30";
        Persistent = true;
      };
    };
  };
}
