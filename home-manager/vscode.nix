{
  pkgs,
  inputs,
  ...
}:
let
  lightColors = import ./base16-light.nix { inherit pkgs inputs; };

  # The light half of the editor theme. stylix's vscode target builds a
  # "Stylix" theme extension from the one scheme it carries, which is the dark
  # one, so vscode has nothing to switch to on a mode toggle.
  #
  # This reuses stylix's own colour-role template rather than hand-mapping the
  # workbench keys, so the light theme is the same several hundred mappings the
  # dark one gets, and tracks upstream when the input moves. Only the name,
  # the `type` and the scheme differ.
  lightTheme = (import "${inputs.stylix}/modules/vscode/templates/theme.nix" lightColors) // {
    name = "Stylix Light";
    type = "light";
  };

  stylixLightExtension =
    pkgs.runCommandLocal "stylix-vscode-light"
      {
        vscodeExtUniqueId = "stylix.stylix-light";
        vscodeExtPublisher = "stylix";
        version = "0.0.0";
        theme = builtins.toJSON lightTheme;

        # Mirrors stylix's package.json for the dark extension, with uiTheme
        # flipped: `vs` is the light base, `vs-dark` the dark one.
        manifest = builtins.toJSON {
          name = "stylix-light";
          displayName = "Stylix Light";
          version = "0.0.0";
          publisher = "stylix";
          description = "Light theme configured via NixOS or Home Manager.";
          categories = [ "Themes" ];
          engines.vscode = "^1.43.0";
          contributes.themes = [
            {
              label = "Stylix Light";
              uiTheme = "vs";
              path = "./themes/stylix-light.json";
            }
          ];
        };

        passAsFile = [
          "theme"
          "manifest"
        ];
      }
      ''
        dir="$out/share/vscode/extensions/$vscodeExtUniqueId"
        mkdir -p "$dir/themes"
        cp "$manifestPath" "$dir/package.json"
        cp "$themePath" "$dir/themes/stylix-light.json"
      '';
in
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
      extensions = [
        stylixLightExtension
      ]
      ++ (with pkgs.vscode-marketplace; [
        bierner.markdown-mermaid
        ms-vscode-remote.remote-containers
        semanticdiff.semanticdiff
        ms-python.python
        astral-sh.ty
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
        mark-wiemer.vscode-autohotkey-plus-plus
      ]);

      userSettings = {
        "window.titleBarStyle" = "native";
        "files.autoSave" = "afterDelay";
        "files.autoSaveDelay" = 150;
        "editor.multiCursorLimit" = 50000;
        "window.menuBarVisibility" = "toggle";
        "editor.inlayHints.enabled" = "offUnlessPressed";
        "editor.formatOnSave" = true;
        "ts.tsserver.experimental.enableProjectDiagnostics" = true;
        "update.mode" = "none";
        # rip out all the builtin ai chat/copilot stuff
        "chat.disableAIFeatures" = true;
        "chat.commandCenter.enabled" = false;
        "rust-analyzer.check.command" = "clippy";
        "python.analysis.typeCheckingMode" = "basic";
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "nixd";

        # Fonts come from stylix's vscode target, which sets the whole family
        # of *.fontFamily/*.fontSize keys from stylix.fonts.monospace.
        "editor.fontLigatures" = false;

        # Follow the desktop colour scheme rather than one pinned theme. vscode
        # reads that over the appearance portal, the same signal ghostty uses,
        # and noctalia writes it through dconf on every mode toggle.
        #
        # stylix's vscode target sets workbench.colorTheme = "Stylix" from its
        # single scheme. That key is left alone: with autoDetectColorScheme on,
        # the two preferred* keys below decide the theme, and "Stylix" stays a
        # valid fallback for a session that starts before the portal answers.
        "window.autoDetectColorScheme" = true;
        "workbench.preferredDarkColorTheme" = "Stylix";
        "workbench.preferredLightColorTheme" = "Stylix Light";
      };
    };
  };
}
