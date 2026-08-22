{
  pkgs,
  inputs,
  ...
}:
let
  fonts = import ./font.nix;
  opacity = import ./opacity.nix;
  schemes = import ./schemes.nix { inherit pkgs inputs; };

  # Alpha-carrying backgrounds for the transparent window, both halves of the
  # toggle. The window patch only makes the WINDOW see-through; without these
  # the page paints an opaque sheet over it.
  vibrancyColors =
    colors:
    import ./vscode-vibrancy/colors.nix {
      inherit colors;
      opacity = opacity.applications;
    };
in
{
  home.sessionVariables = {
    SUDO_EDITOR = "code";
    VISUAL = "code";
  };

  programs.git.settings.core.editor = "code --wait";

  programs.vscode = {
    enable = true;

    # Frameless + transparent window, patched at build time. See
    # ./vscode-vibrancy for what that does and when it needs re-checking.
    package = pkgs.callPackage ./vscode-vibrancy { };

    # without this, only.. some of the extensions show up?
    # very very strange.
    mutableExtensionsDir = false;

    profiles.default = {
      extensions = (
        with pkgs.vscode-marketplace;
        [
          # Ships every catppuccin flavour as a separate theme, so the two
          # halves of the light/dark toggle come from one upstream extension
          # instead of a generated one. Replaced the stylix-built theme, which
          # only ever carried a single scheme.
          catppuccin.catppuccin-vsc
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
        ]
      );

      userSettings = {
        # "custom" rather than "native": VS Code only drops the OS frame
        # (c.frame=!1 in main.js) when it draws its own titlebar, and with
        # "native" it takes the other branch and keeps the system frame -- which
        # would sit as an opaque strip above an otherwise transparent window.
        # The vibrancy patch sets frame:false in the BrowserWindow options, but
        # this is the setting that makes VS Code agree.
        "window.titleBarStyle" = "custom";

        # ...and no window buttons drawn into that custom titlebar either.
        # `window.controlsStyle` takes "native" | "custom" | "hidden" in this
        # build (the enum is right beside titleBarStyle in main.js); "hidden"
        # removes the minimise/maximise/close set. Hyprland does window
        # management here, so they are decoration with nothing to add.
        "window.controlsStyle" = "hidden";

        # Alpha on every background VS Code paints, so the transparent window
        # underneath is actually visible. Scoped per theme with the bracket
        # syntax (getThemeSpecificColors in the workbench bundle applies these
        # over the unscoped block), because the two halves of the light/dark
        # toggle need different base colours.
        "workbench.colorCustomizations" = {
          "[Catppuccin Mocha]" = vibrancyColors schemes.dark;
          "[Catppuccin Latte]" = vibrancyColors schemes.light;
        };

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

        # Fonts: stylix's vscode target used to set the whole family of
        # *.fontFamily/*.fontSize keys. Only the editor and terminal ones
        # actually matter here.
        "editor.fontFamily" = fonts.mono;
        "editor.fontSize" = fonts.sizes.applications;
        "terminal.integrated.fontFamily" = fonts.mono;
        "terminal.integrated.fontSize" = fonts.sizes.terminal;
        "editor.fontLigatures" = false;

        # Follow the desktop colour scheme rather than one pinned theme. vscode
        # reads that over the appearance portal, the same signal ghostty uses,
        # and noctalia writes it through dconf on every mode toggle.
        #
        # Theme names as the catppuccin extension registers them; they must
        # match its contributed labels exactly or vscode reports "Theme is
        # unknown or not installed".
        "window.autoDetectColorScheme" = true;
        "workbench.colorTheme" = "Catppuccin Mocha";
        "workbench.preferredDarkColorTheme" = "Catppuccin Mocha";
        "workbench.preferredLightColorTheme" = "Catppuccin Latte";
      };
    };
  };
}
