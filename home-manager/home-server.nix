{
  pkgs,
  ...
}:
{
  # slim home profile for headless boxes: servers, and machines that aren't mine
  # (dollnet). home.nix is the desktop profile -- it drags in telegram-desktop,
  # google-cloud-sdk, jdk11, ansible, awscli, imagemagickBig, gdb/lldb, devenv.
  # none of that belongs on a shared server, so this is a parallel profile
  # rather than an import of home.nix.
  #
  # username / homeDirectory come from the consumer: identity.nix via
  # nixos/all-systems-configuration.nix on my own hosts, or set explicitly by a
  # foreign flake importing homeManagerModules.server.

  home = {
    stateVersion = "23.05"; # keep in step with home.nix
  };

  home.packages = with pkgs; [
    # shell config
    eza # ls replacement

    # TUI tools
    bottom # system manager, like htop
    lazygit # git manager

    # command-line utils
    screen
    killall
    file # file type identification
    jq # json processing tool
    ripgrep # grep replacement
    fd
    tokei # code LoC

    git-absorb
    gh
    nixd
  ];

  home.file = {
    ".cargo/config.toml".text = ''
      [net]
      git-fetch-with-cli = true   # use the `git` executable for git operations
    '';

    "bin/gh-watch-branch".source = ./gh-watch-branch;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fish = {
    enable = true;
    shellAliases = {
      reload-fish = "exec fish";
      gcp = "git cherry-pick";
      gs = "git status";
      gp = "git pull";
      gc = "git commit -m";
      gca = "git commit --amend";
      gl = "git log";
      gf = "git fetch -p";
      ls = "eza";
      lg = "lazygit";
      gcm = "git checkout master";
      gco = "git checkout";
    };

    shellInit = ''
      ${pkgs.lib.getExe pkgs.starship} init fish | source

      set -gx PATH $PATH ~/bin ~/go/bin ~/.cargo/bin
    '';
  };

  programs.mergiraf = {
    enable = true;
    enableGitIntegration = true;
  };

  programs.git = {
    enable = true;
    settings = {
      user.email = "arilotter@gmail.com";
      user.name = "ethernet";
      pull.rebase = true;
      rebase.autoStash = true;
      push.default = "simple";
      push.autoSetupRemote = true;
      alias = {
        gone = "!git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/ | awk '\$2 == \"[gone]\" { print \$1 }'";
        bclean = "!git gone | xargs -r git branch -D";
      };
    };
    signing.format = null;
    lfs.enable = true;
  };
}
