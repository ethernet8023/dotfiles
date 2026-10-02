{
  pkgs,
  lib,
  inputs,
  config,
  ...
}:
let
  schemes = import ./schemes.nix { inherit pkgs inputs; };
  toml = pkgs.formats.toml { };

  ghostty = lib.getExe config.programs.ghostty.package;

  # yazi flavor from a base16 scheme, so yazi follows the same two palettes as
  # ghostty and the shell. The slot -> role table is the catppuccin flavor's
  # (yazi-rs/flavors), except accents use base07 (lavender), the accent used
  # across the shell, the window borders and the Hermes skin, where that flavor
  # uses blue. Anything not set here falls back to yazi's built-in theme.
  mkFlavor =
    colors:
    with colors.withHashtag;
    let
      accent = base07;
      fg = c: { fg = c; };
      fgbg = f: b: {
        fg = f;
        bg = b;
      };
    in
    {
      mgr = {
        cwd = fg base0C;
        find_keyword = {
          fg = base0A;
          bold = true;
          italic = true;
          underline = true;
        };
        find_position = {
          fg = base0E;
          bg = "reset";
          bold = true;
          italic = true;
        };
        marker_copied = fgbg base0B base0B;
        marker_cut = fgbg base08 base08;
        marker_marked = fgbg base0C base0C;
        marker_selected = fgbg base0A base0A;
        count_copied = fgbg base00 base0B;
        count_cut = fgbg base00 base08;
        count_selected = fgbg base00 base0A;
        border_symbol = "│";
        border_style = fg base04;
      };

      tabs = {
        active = (fgbg base00 accent) // {
          bold = true;
        };
        inactive = fgbg accent base02;
      };

      mode = {
        normal_main = (fgbg base00 accent) // {
          bold = true;
        };
        normal_alt = fgbg accent base02;
        select_main = (fgbg base00 base0C) // {
          bold = true;
        };
        select_alt = fgbg base0C base02;
        unset_main = (fgbg base00 base06) // {
          bold = true;
        };
        unset_alt = fgbg base06 base02;
      };

      status = {
        perm_sep = fg base04;
        perm_type = fg base0D;
        perm_read = fg base0A;
        perm_write = fg base08;
        perm_exec = fg base0B;
        progress_label = (fg base05) // {
          bold = true;
        };
        progress_normal = fgbg base0B base03;
        progress_error = fgbg base0A base08;
      };

      pick = {
        border = fg accent;
        active = (fg base0E) // {
          bold = true;
        };
        inactive = { };
      };

      input = {
        border = fg accent;
        title = { };
        value = { };
        selected.reversed = true;
      };

      cmp.border = fg accent;

      tasks = {
        border = fg accent;
        title = { };
        hovered = (fg base0E) // {
          bold = true;
        };
      };

      which = {
        border = fg accent;
        cand = fg base0C;
        rest = fg base04;
        desc = fg base0E;
        separator = "  ";
        separator_style = fg base03;
      };

      help = {
        on = fg base0C;
        run = fg base0E;
        hovered = {
          reversed = true;
          bold = true;
        };
        footer = fgbg base02 base05;
      };

      spot = {
        border = fg accent;
        title = fg accent;
        tbl_col = fg base0C;
        tbl_cell = fgbg base0E base02;
      };

      notify = {
        title_info = fg base0B;
        title_warn = fg base0A;
        title_error = fg base08;
      };

      filetype.rules = [
        {
          mime = "**/image/*";
          fg = base0C;
        }
        {
          mime = "**/{audio,video}/*";
          fg = base0A;
        }
        {
          mime = "**/application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}";
          fg = base0E;
        }
        {
          mime = "**/application/{pdf,doc,rtf}";
          fg = base0B;
        }
        {
          mime = "vfs/{absent,stale}";
          fg = base04;
        }
        {
          url = "*";
          fg = base05;
        }
        {
          url = "*/";
          fg = base0D;
        }
      ];
    };

  # A flavor is a directory holding flavor.toml.
  flavorDir =
    name: colors:
    pkgs.linkFarm "yazi-flavor-${name}" [
      {
        name = "flavor.toml";
        path = toml.generate "flavor.toml" (mkFlavor colors);
      }
    ];

  # One window per launch, own app id so it never joins ghostty's single
  # instance. Both the show-in-folder service and the file chooser use this.
  chooserClass = "local.termfilechooser";
  yaziTerm = pkgs.writeShellScriptBin "yazi-term" ''
    exec ${ghostty} --gtk-single-instance=false --title=yazi -e ${lib.getExe config.programs.yazi.package} "$@"
  '';

  fileManager1 = pkgs.writers.writePython3Bin "file-manager1" {
    libraries = [ pkgs.python3Packages.dbus-fast ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./file-manager1.py);
in
{
  programs.yazi = {
    enable = true;
    enableFishIntegration = true;
    # cd's the shell to wherever you quit. Pinned: the default depends on
    # home.stateVersion.
    shellWrapperName = "y";

    settings.mgr = {
      show_hidden = true;
      sort_by = "natural";
      sort_dir_first = true;
    };

    # Yazi asks the terminal for its background colour at startup and picks the
    # matching half, so this follows ghostty, which follows the noctalia toggle.
    flavors = {
      base16-dark = flavorDir "dark" schemes.dark;
      base16-light = flavorDir "light" schemes.light;
    };
    theme.flavor = {
      dark = "base16-dark";
      light = "base16-light";
    };
  };

  # File chooser: xdg-desktop-portal-termfilechooser (selected for the
  # FileChooser interface in nixos/graphical-configuration.nix) runs its yazi
  # wrapper inside TERMCMD. The class is what hyprland.nix floats it by -- yazi
  # rewrites the window title, so a title match would not hold.
  xdg.configFile."xdg-desktop-portal-termfilechooser/config".text = ''
    [filechooser]
    cmd=yazi-wrapper.sh
    default_dir=$HOME
    env=TERMCMD=${ghostty} --gtk-single-instance=false --class=${chooserClass} -e
    open_mode=suggested
    save_mode=suggested
  '';

  # Show in folder: browsers call org.freedesktop.FileManager1.ShowItems.
  xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text = ''
    [D-BUS Service]
    Name=org.freedesktop.FileManager1
    Exec=${lib.getExe fileManager1} ${lib.getExe yaziTerm}
  '';
}
