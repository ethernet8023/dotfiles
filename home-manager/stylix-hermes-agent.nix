# Stylix target for Hermes Agent.
#
# Hermes themes every surface it has -- CLI, Ink TUI, and the Electron desktop
# app -- from one YAML "skin" in $HERMES_HOME/skins/, selected by `display.skin`
# in config.yaml. That is a good fit for stylix: one palette in, all three
# surfaces repaint.
#
# This is an out-of-tree target. Stylix has no hermes-agent module upstream, so
# it is written against `config.lib.stylix.mkEnableTarget` and gated the same way
# stylix's own targets are, which means it picks up `stylix.enable`,
# `stylix.autoEnable`, and the usual `stylix.targets.hermes-agent.enable`
# override without special-casing.
#
# Pairs with ./hermes-agent.nix, whose activation script owns $HERMES_HOME.
# Skins are written through home.file rather than that script because a skin is
# pure derived data with no runtime writer -- unlike config.yaml, which Hermes
# rewrites itself (`hermes config set`, the GUI settings pane) and which
# therefore has to be deep-merged rather than replaced.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.stylix.targets.hermes-agent;
  hermesCfg = config.services.hermes-agent;

  inherit (config.lib.stylix) colors;

  skinName = "stylix";

  # Hermes resolves a skin against the built-in `default`, but only for keys the
  # default itself defines -- and several documented keys (ui_tool, ui_thinking,
  # ui_text, the syntax_* and diff_* families) are absent from it, falling back
  # at render time to whatever the renderer picked. Setting every key here keeps
  # the palette under stylix's control instead of half-inherited from Hermes gold.
  mkPalette =
    c: with c; {
      background = base00;

      # Panels and banners.
      banner_border = base02;
      banner_title = base05;
      banner_accent = cfg.accentColor;
      banner_dim = base03;
      banner_text = base05;

      # General UI.
      ui_accent = cfg.accentColor;
      ui_text = base05;
      ui_label = base04;
      ui_border = base02;
      ui_ok = base0B;
      ui_error = base08;
      ui_warn = base0A;

      # Tool markers and reasoning text. Hermes' default leaves these unset and
      # falls back to ui_accent / banner_dim; pinning them means the classic
      # gold marker cannot leak through a partial palette.
      ui_tool = cfg.accentColor;
      ui_thinking = base03;

      # Diffs. Backgrounds are the polarity-appropriate tints; the word-level
      # foregrounds are the saturated pair.
      diff_added = base0B;
      diff_removed = base08;
      diff_added_word = base0B;
      diff_removed_word = base08;

      # Syntax highlighting, following base16's conventional slot meanings.
      syntax_string = base0B;
      syntax_number = base09;
      syntax_keyword = base0E;
      syntax_comment = base03;

      # Prompt and input chrome.
      prompt = base05;
      input_rule = base02;
      response_border = cfg.accentColor;
      shell_dollar = base0B;

      # Status bar.
      status_bar_bg = base01;
      status_bar_text = base04;
      status_bar_strong = base05;
      status_bar_dim = base03;
      status_bar_good = base0B;
      status_bar_warn = base0A;
      status_bar_bad = base09;
      status_bar_critical = base08;

      # Session label and misc TUI fills.
      session_label = cfg.accentColor;
      session_border = base03;
      voice_status_bg = base01;
      selection_bg = base02;

      # Completion menu.
      completion_menu_bg = base01;
      completion_menu_current_bg = base02;
      completion_menu_meta_bg = base01;
      completion_menu_meta_current_bg = base02;
    };

  skin = {
    name = skinName;
    description = "Generated from the active stylix base16 scheme";
    colors = mkPalette colors.withHashtag;
  }
  // lib.optionalAttrs (cfg.extraConfig != { }) cfg.extraConfig;

  skinFile = (pkgs.formats.yaml { }).generate "hermes-skin-${skinName}.yaml" skin;
in
{
  options.stylix.targets.hermes-agent = {
    enable = config.lib.stylix.mkEnableTarget "Hermes Agent" true;

    accentColor = lib.mkOption {
      type = lib.types.str;
      default = colors.withHashtag.base0D;
      defaultText = lib.literalExpression "config.lib.stylix.colors.withHashtag.base0D";
      description = ''
        Colour used for accents: headings, links, tool-call markers, the
        response border and the session label.

        base16 has no accent slot, so stylix targets pick one by meaning and
        base0D ("functions, methods, headings") is the conventional choice.
        Point this at another slot to match a shell or bar accent that does not
        follow the same convention.
      '';
      example = lib.literalExpression "config.lib.stylix.colors.withHashtag.base07";
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Extra top-level keys merged into the generated skin, for the parts of
        the format that are not colours: `branding`, `spinner`, `tool_prefix`,
        `tool_emojis`, `banner_logo`, `banner_hero`.
      '';
      example = lib.literalExpression ''
        {
          branding = {
            agent_name = "Hermes";
            prompt_symbol = "❯";
          };
          tool_prefix = "┊";
        }
      '';
    };
  };

  config = lib.mkIf (config.stylix.enable && cfg.enable && hermesCfg.enable) {
    # home.file paths are relative to the home directory, so a hermesHome
    # outside it cannot be expressed here. removePrefix would silently no-op and
    # produce an absolute key, which home-manager writes to the wrong place.
    assertions = [
      {
        assertion = lib.hasPrefix "${config.home.homeDirectory}/" hermesCfg.hermesHome;
        message = ''
          stylix: hermes-agent: services.hermes-agent.hermesHome
          (${hermesCfg.hermesHome}) is outside home.homeDirectory
          (${config.home.homeDirectory}), so the generated skin cannot be placed
          with home.file.

          Move hermesHome under the home directory, or set
          `stylix.targets.hermes-agent.enable = false` and install the skin
          yourself.
        '';
      }
    ];

    # $HERMES_HOME is an arbitrary path rather than a fixed XDG location, so the
    # skin goes through home.file with a path relative to the home directory.
    # Hermes reads skins fine as read-only store symlinks (it only ever loads
    # them), unlike config.yaml which it rewrites at runtime.
    home.file."${lib.removePrefix "${config.home.homeDirectory}/" hermesCfg.hermesHome}/skins/${skinName}.yaml" =
      {
        source = skinFile;
      };

    # Selects the skin. This lands in config.yaml through the hermes-agent
    # module's deep merge, so keys set at runtime via `hermes config set` or the
    # GUI survive -- only display.skin is claimed.
    #
    # Deliberately a plain value, NOT lib.mkDefault: `settings` is a custom
    # option type whose merge is `foldl' recursiveUpdate` over the raw
    # definition values, so it never applies priorities. An mkDefault here
    # survives into the generated YAML as a literal
    # `{_type = "override"; priority = 1000; ...}` attrset and Hermes then looks
    # up a skin whose name is that attrset. To use a different skin, turn this
    # target off:
    #
    #   stylix.targets.hermes-agent.enable = false;
    services.hermes-agent.settings.display.skin = skinName;
  };
}
