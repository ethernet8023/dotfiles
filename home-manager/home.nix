{
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    inputs.nixvim.homeModules.default
    inputs.vscode-server.homeModules.default
  ];

  home = {
    username = "ethie";
    homeDirectory = "/home/ari";
    stateVersion = "23.05"; # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  };

  home.packages = with pkgs; [
    (pkgs.callPackage ./runpod { })
    (pkgs.callPackage ./signal-desktop { })
    telegram-desktop
    # shell config
    eza # ls replacement

    # "desktop" env
    upower # battery
    fastfetch # i mean, c'mon :)

    # TUI tools
    bottom # system manager, like htop
    nvtopPackages.full
    lazydocker # docker manager
    lazygit # git manager

    # command-line utils
    screen
    killall
    file # file type identification
    graphviz # graph visualization
    jq # json processing tool
    ripgrep # grep replacement
    tokei # code LoC
    imagemagickBig
    ranger

    git-absorb

    # programming tools
    devenv
    jdk11 # java
    trickle # limit bandwidth artificially
    wabt # webassembly binary tools
    google-cloud-sdk # google cloud sdk
    awscli # aws cli
    ansible # ansible devops bullshit
    nixd

    # programming languages
    python3

    # debuggers
    lldb
    gdb
    valgrind

    # graphics tools
    pngquant # png compression
  ];

  home.file = {
    ".cargo/config.toml".text = ''
      [net]
      git-fetch-with-cli = true   # use the `git` executable for git operations
    '';
  };

  home.sessionVariables = { };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.ssh = {
    enable = true;
    matchBlocks = {
      hgx = {
        hostname = "216.55.186.241";
        port = 22;
        user = "ari";
      };
    };
  };

  programs.fish = {
    enable = true;
    shellAliases = {
      netcopy = ''nc -q 0 tcp.st 7777 | grep URL | cut -d " " -f 2 | pbcopy'';
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
      ld = "lazydocker";
      gcm = "git checkout master";
      gco = "git checkout";
      p = "pnpm";
      # open a link on the connected android phone
      phone = "adb shell am start --user 0 -a android.intent.action.VIEW -d";
    };

    shellInit = ''
      ${pkgs.lib.getExe pkgs.starship} init fish | source

      set -gx ANDROID_HOME $HOME/Android/Sdk
      set -gx PATH $PATH ~/.yarn/bin ~/.npm/bin ~/bin ~/go/bin ~/.cargo/bin $ANDROID_HOME/emulator $ANDROID_HOME/tools $ANDROID_HOME/tools/bin $ANDROID_HOME/platform-tools

      function checkout-last-version
        set card $argv[1]
        git checkout (git rev-list -n 1 HEAD -- "$card")^ -- "$card"
      end

      set -gx SW_API_HOST "https://local-skyweaver-api.0xhorizon.net"
      set -gx SW_AUTH_TOKEN "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50IjoiMHgyMDM3MTI0NzMwZjRkMmQ1MTI0OGQyYzA1ZDJhZTVjYmQyODhlZDY3IiwiYXBwIjoiU2t5d2VhdmVyIiwiZXhwIjoxNjU1ODM2Nzg4LCJpYXQiOjE2MjQzMDA3ODgsIm9nbiI6Imh0dHBzOi8vbG9jYWwuMHhob3Jpem9uLm5ldCJ9.rFCF1PhcAEJbUdMB4LFd4L6ElqA8rtxMi46gK8fQBB"
    '';
  };

  programs.mergiraf.enable = true;
  programs.git = {
    enable = true;
    userEmail = "arilotter@gmail.com";
    userName = "Ari Lotter";
    settings = {
      pull.rebase = true;
      rebase.autoStash = true;
      diff.tool = "default-difftool";
      push.default = "simple";
      push.autoSetupRemote = true;
      url."git@github.com:".insteadOf = "https://github.com/";
      alias.ci = "!git commit -m 'ci: empty commit' --allow-empty && git push && git reset --soft HEAD~ && git push -f";
    };
    lfs.enable = true;
  };
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };

  services.vscode-server.enable = true;
}
