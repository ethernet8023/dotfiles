{
  config,
  lib,
  ...
}:
{
  nixpkgs.hostPlatform = "x86_64-linux";

  boot = {
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "usb_storage"
      "sd_mod"
    ];
    initrd.kernelModules = [ ];
    kernelModules = [ "kvm-amd" ];
    extraModulePackages = [ ];
    kernelParams = [ "nvidia-drm.fbdev=1" ];
    blacklistedKernelModules = [
      "snd_hda_codec_hdmi"
      "nfc"
    ];

    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;

    # full-disk encryption: LUKS2 container on nvme1n1p2 holds the root fs.
    # this UUID is the *container's* (crypto_LUKS), not the ext4 inside it.
    initrd.luks.devices."cryptroot" = {
      device = "/dev/disk/by-uuid/e34694f3-93b5-49b3-8743-528709aa97ed";
      allowDiscards = true; # pass TRIM through to the SSD
      bypassWorkqueues = true; # faster on NVMe
    };
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A37F-0985";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  networking.useDHCP = lib.mkDefault true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  zramSwap.enable = true;
  swapDevices = [
    {
      device = "/var/lib/swapfile2";
      size = 128 * 1024;
    }
  ];
}
