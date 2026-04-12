{
  pkgs,
  ...
}:
{
  home.sessionVariables = {
    SUDO_EDITOR = "code";
    VISUAL = "code";
  };

  programs.git.settings.core.editor = "code --wait";

  programs.vscode = {
    enable = true;

    # without this, only.. some of the extensions show up?
    # very very strange.
    mutableExtensionsDir = false;

    profiles.default = {
      extensions = with pkgs.vscode-marketplace; [
        bierner.markdown-mermaid
        ms-vscode-remote.remote-containers
        semanticdiff.semanticdiff
        ms-python.python
        ms-python.vscode-pylance
        ms-python.black-formatter
        golang.go
        rust-lang.rust-analyzer
        dbaeumer.vscode-eslint
        usernamehw.errorlens
        jnoortheen.nix-ide
        # (import ./skyweaver-vscode)
        tamasfe.even-better-toml
        # jolaleye.horizon-theme-vscode
        esbenp.prettier-vscode
        dbaeumer.vscode-eslint
        gruntfuggly.todo-tree
        wallabyjs.quokka-vscode
        yoavbls.pretty-ts-errors
        slevesque.shader
        xaver.clang-format
        ms-playwright.playwright
        ms-vscode-remote.remote-ssh
        charliermarsh.ruff
        mkhl.direnv
        ms-vsliveshare.vsliveshare
        github.vscode-pull-request-github
      ];

      userSettings = {
        "window.titleBarStyle" = "native";
        "files.autoSave" = "afterDelay";
        "files.autoSaveDelay" = 150;
        "editor.multiCursorLimit" = 50000;
        "window.menuBarVisibility" = "toggle";
        "editor.inlayHints.enabled" = "offUnlessPressed";
        "editor.formatOnSave" = true;
        "typescript.tsserver.experimental.enableProjectDiagnostics" = true;
        "update.mode" = "none";
        "rust-analyzer.check.command" = "clippy";
        "python.analysis.typeCheckingMode" = "basic";
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "nixd";
      };
    };
  };
}
