{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # gnu coreutils under their real names, so scripts written on linux
    # don't trip over bsd flags. shadows the system ones on PATH.
    coreutils-full
    gnused
    gnutar
    findutils
  ];

  programs.fish.shellInit = ''
    # homebrew, for the casks nixpkgs can't do (gui apps w/ sparkle updaters)
    if test -x /opt/homebrew/bin/brew
      /opt/homebrew/bin/brew shellenv | source
    end
  '';
}
