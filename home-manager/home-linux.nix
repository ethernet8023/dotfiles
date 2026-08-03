{ inputs, pkgs, ... }:
{
  imports = [
    # remote vscode into this box; no reason to on the machine i'm sitting at
    inputs.vscode-server.homeModules.default
  ];

  home.packages = with pkgs; [
    # the ramdisk wrapper is linux-shaped: pkill + ~/.config/Signal
    (pkgs.callPackage ./signal-desktop { })

    upower # battery. macos has its own ideas
    trickle # LD_PRELOAD bandwidth shaper, so: linux only
    valgrind # marked broken on darwin
  ];

  services.vscode-server.enable = true;
}
