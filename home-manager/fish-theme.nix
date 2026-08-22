# Fish colours that follow the light/dark toggle.
#
# Replaces an earlier stylix fish target, which sourced base16-fish and called
# `base16-<slug>`. That did two harmful things
# on this setup:
#
#   1. It emits OSC 4 / OSC 10 / OSC 11 escapes that reprogram the terminal's
#      LIVE palette to the dark scheme at every interactive prompt. Ghostty
#      already owns its palette through the theme it picked for the current
#      mode, so in light mode ghostty loads latte and the first fish prompt
#      paints mocha straight back over it.
#   2. It writes fish_color_* with `set -U`, so the values persist into
#      ~/.config/fish/fish_variables. Universal variables outrank anything
#      config.fish sets later, which is exactly the case fish's own docs warn
#      about: "A theme set this way will not update as
#      fish_terminal_color_theme changes."
#
# Fish 4.x solves this natively. It enables unsolicited colour theme reporting
# (CSI ? 2031 h), the terminal reports a palette change, and fish re-queries
# the background and republishes $fish_terminal_color_theme. A .theme file with
# [light] and [dark] sections is re-applied on every change of that variable,
# with no hook of ours in the loop.
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  schemes = import ./schemes.nix { inherit pkgs inputs; };
  darkColors = schemes.dark;
  lightColors = schemes.light;

  # Base16 role -> fish colour variable. Mirrors the mapping base16-fish uses,
  # so the palette matches what the rest of the system shows, and both variants
  # are generated from one table so they cannot drift apart.
  #
  # The colours are the bare `eff1f5` form, NOT `withHashtag`. A `.theme` file
  # is read line by line with `read --tokenize`, which applies fish's own
  # tokenizer, and there `#` starts a comment. So `fish_color_command #89b4fa`
  # tokenizes to the single token `fish_color_command`, fish sets that variable
  # to the empty value, and every highlight colour is lost -- the whole shell
  # renders unhighlighted. Every theme fish ships writes bare hex for the same
  # reason. `--background=${base02}` keeps its `#` safely, because the `#` is
  # not at the start of a token there, but it is written bare too so the file
  # holds one spelling.
  mkVariant =
    colors: with colors; {
      fish_color_normal = base05;
      fish_color_command = base0D;
      fish_color_keyword = base0E;
      fish_color_quote = base0B;
      fish_color_redirection = base0C;
      fish_color_end = base09;
      fish_color_error = base08;
      fish_color_param = base04;
      fish_color_comment = base03;
      fish_color_selection = "--background=${base02}";
      fish_color_search_match = "--background=${base02}";
      fish_color_operator = base0C;
      fish_color_escape = base0C;
      fish_color_autosuggestion = base03;
      fish_color_cancel = "-r";
      fish_color_cwd = base0A;
      fish_color_cwd_root = base08;
      fish_color_host = base0D;
      fish_color_user = base0B;
      fish_color_valid_path = "--underline";

      fish_pager_color_progress = base03;
      fish_pager_color_prefix = base0C;
      fish_pager_color_completion = base05;
      fish_pager_color_description = base03;
      fish_pager_color_selected_background = "--background=${base02}";
    };

  renderVariant =
    colors:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "${name} ${value}") (mkVariant colors));

  themeName = "base16-auto";

  # `# name:` and `# preferred_background:` are the comments fish's own theme
  # format uses; the web config tool reads them.
  #
  # The [unknown] section is not optional in practice. fish sets
  # $fish_terminal_color_theme to `unknown` whenever the terminal does not
  # answer its background-colour query -- a bare TTY, some multiplexers, an ssh
  # session -- and a theme with no [unknown] variant leaves every fish_color_*
  # empty there, so the shell renders with no highlighting at all. Dark is the
  # better guess for this setup, so [unknown] repeats the dark variant.
  themeFile = pkgs.writeText "${themeName}.theme" ''
    # name: 'Base16 Auto'

    [light]
    # preferred_background: ${lightColors.base00}
    ${renderVariant lightColors}

    [dark]
    # preferred_background: ${darkColors.base00}
    ${renderVariant darkColors}

    [unknown]
    ${renderVariant darkColors}
  '';
in
{
  # See the header: this target actively fights ghostty's palette.
  xdg.configFile."fish/themes/${themeName}.theme".source = themeFile;

  programs.fish.interactiveShellInit = ''
    # Universal fish_color_* variables outrank a theme, and fish only populates
    # $fish_terminal_color_theme at the first interactive prompt. base16-fish
    # wrote a full set of them into fish_variables before this module existed,
    # so clear any that are still there; otherwise the theme below is loaded
    # and then silently overridden by the stale values.
    #
    # --entire is required: without it `string match --regex` returns the
    # matched PORTION of each name ("fish_color_") rather than the name itself,
    # so the loop erases a variable that does not exist and reports success.
    for __theme_color in (set --names --universal | string match --entire --regex '^fish_(pager_)?color_')
      set --erase --universal $__theme_color
    end
    set --erase __theme_color

    # Applies the variant matching $fish_terminal_color_theme, and re-applies it
    # whenever that variable changes -- so a mode toggle repaints live shells
    # with no reload. `choose` (not `save`) is deliberate: `save` would write
    # universal variables and pin one variant forever.
    fish_config theme choose ${themeName}
  '';
}
