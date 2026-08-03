{
  pkgs,
  ...
}:
{
  # platform-specific bits live in home-{linux,darwin}.nix, wired up by the
  # flake's tty-modules / darwin-modules -- not imported here, since choosing
  # an import based on `pkgs` recurses under home-manager's useGlobalPkgs.

  home = {
    # username / homeDirectory come from the host config (see identity.nix),
    # since they differ per machine: /home/ethie on luna, /home/ari on the
    # older linux hosts, /Users/ethernet on darwin.
    stateVersion = "23.05"; # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  };

  home.packages = with pkgs; [
    (pkgs.callPackage ./runpod { })
    telegram-desktop
    # shell config
    eza # ls replacement

    # "desktop" env
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
    gh
    jdk11 # java
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

    # graphics tools
    pngquant # png compression
  ];

  home.file = {
    ".cargo/config.toml".text = ''
      [net]
      git-fetch-with-cli = true   # use the `git` executable for git operations
    '';

    "bin/gh-watch-branch".source = ./gh-watch-branch;
  };

  home.sessionVariables = { };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.ssh = {
    enable = true;
    # upstream is dropping its implicit `Host *` defaults, so spell them out
    # and opt out of the built-ins. these are the values the old default
    # produced, so the generated config is unchanged.
    enableDefaultConfig = false;
    settings = {
      "*" = {
        addKeysToAgent = "no";
        compression = false;
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
        forwardAgent = false;
        hashKnownHosts = false;
        serverAliveCountMax = 3;
        serverAliveInterval = 0;
        userKnownHostsFile = "~/.ssh/known_hosts";
      };
      hgx = {
        hostname = "216.55.186.241";
        port = 22;
        user = "ari";
      };
      iris = {
        # dhcp moves it around; mdns is stable
        hostname = "iris.local";
        user = (import ../hosts.nix).iris.username;
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
      url."git@github.com:".insteadOf = "https://github.com/";
      alias = {
        ci = "!git commit -m 'ci: empty commit' --allow-empty && git push && git reset --soft HEAD~ && git push -f";
        gone = "!git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/ | awk '\$2 == \"[gone]\" { print \$1 }'";
        bclean = "!git gone | xargs -r git branch -D";
        wtgone = "!git worktree list --porcelain | awk '/^worktree /{p=$2} /^branch /{b=$2; sub(\"refs/heads/\",\"\",b); print p, b}' | while read path branch; do git gone | grep -qx \"$branch\" && echo \"$path\"; done";
        wtclean = "!git worktree prune -v && git wtgone | xargs -r -I{} git worktree remove {}";
        wtcleanf = "!git wtgone | xargs -r -I{} git worktree remove {} --force && git worktree prune -v";
        allclean = "!git bclean; git wtclean; git bclean; git wtclean";
        allcleanf = "!git bclean; git wtcleanf; git bclean; git wtcleanf";
      };
    };
    signing.format = null;
    lfs.enable = true;
  };
  programs.difftastic = {
    enable = true;
    git = {
      enable = true;
      diffToolMode = true;
    };
  };

  # programs.delta = {
  #   enable = true;
  #   enableGitIntegration = true;
  # };
}
