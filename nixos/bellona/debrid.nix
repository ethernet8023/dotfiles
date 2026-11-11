# debrid: Real-Debrid's own WebDAV mounted read-only on tank, with jellyfin
# reading it as a library.
#
# no zurg: RD serves WebDAV itself at https://dav.real-debrid.com/ (username =
# account name, password = the WebDAV password from account settings). zurg's
# only real value over that is a movies/shows tree and no ~200-torrent display
# cap; both are worth adding later, neither is worth a pinned binary tonight.
#
# rclone does the mount because nothing else can read WebDAV as a filesystem.
# the credentials never enter the store: the config is written at start from
# agenix into /run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.me.bellona;
  mountPoint = "/tank/debrid";
  rcloneConfig = "/run/rclone-debrid/rclone.conf";
in
{
  config = lib.mkIf cfg.enable {
    age.secrets.real-debrid-webdav.file = ../../secrets/real-debrid-webdav.age;

    # jellyfin runs as its own user and has to read a mount owned by root.
    environment.etc."fuse.conf".text = "user_allow_other\n";

    systemd.services.rclone-debrid = {
      description = "mount Real-Debrid WebDAV on ${mountPoint}";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "tank.mount"
      ];
      wants = [ "network-online.target" ];
      requires = [ "tank.mount" ];
      before = [ "jellyfin.service" ];

      preStart = ''
        mkdir -p /run/rclone-debrid ${mountPoint}
        user=$(sed -n 's/^username=//p' ${config.age.secrets.real-debrid-webdav.path})
        pass=$(sed -n 's/^password=//p' ${config.age.secrets.real-debrid-webdav.path})
        cat > ${rcloneConfig} <<EOF
        [debrid]
        type = webdav
        url = https://dav.real-debrid.com/
        vendor = other
        user = $user
        pass = $(${pkgs.rclone}/bin/rclone obscure "$pass")
        EOF
      '';

      serviceConfig = {
        Type = "notify";
        ExecStart = lib.escapeShellArgs [
          "${pkgs.rclone}/bin/rclone"
          "mount"
          "debrid:"
          mountPoint
          "--config"
          rcloneConfig
          # writes, not full: jellyfin only reads, but rclone still needs a
          # place for its VFS metadata and for the range requests it turns into
          # cache files.
          "--vfs-cache-mode"
          "writes"
          "--vfs-cache-max-age"
          "24h"
          "--dir-cache-time"
          "1m"
          "--allow-other"
          "--read-only"
        ];
        ExecStop = "${pkgs.fuse}/bin/fusermount -uz ${mountPoint}";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    services.jellyfin = {
      enable = true;
      openFirewall = false; # caddy is the only way in
      dataDir = "/var/lib/jellyfin";
      cacheDir = "/var/cache/jellyfin";
      # strix halo vaapi is uneven; if the iGPU refuses, jellyfin falls back to
      # cpu (32 cores) on its own. forceEncodingConfig keeps this declarative
      # instead of drifting in encoding.xml.
      hardwareAcceleration = {
        enable = true;
        type = "vaapi";
        device = "/dev/dri/renderD128";
      };
      forceEncodingConfig = true;
    };
    systemd.services.jellyfin.after = [ "rclone-debrid.service" ];
    systemd.services.jellyfin.wants = [ "rclone-debrid.service" ];
  };
}
