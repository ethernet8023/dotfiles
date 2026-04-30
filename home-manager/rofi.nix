{
  config,
  pkgs,
  ...
}:
{
  programs.rofi = {
    enable = true;
    terminal = pkgs.lib.getExe pkgs.ghostty;

    theme =
      let
        inherit (config.lib.formats.rasi) mkLiteral;
      in
      {
        "*".spacing = 2;
        window = {
          location = mkLiteral "center";
          anchor = mkLiteral "north";
          border = mkLiteral "8px";
          border-radius = mkLiteral "9px";
          width = 480;
        };
        inputbar = {
          spacing = mkLiteral "8px";
          padding = mkLiteral "8px";
        };

        textbox = {
          padding = mkLiteral "8px";
        };

        listview = {
          fixed-height = false;
          scrollbar = true;
          lines = 8;
          columns = 1;
          padding = mkLiteral "4px 0";
        };

        element = {
          padding = mkLiteral "8px";
          spacing = mkLiteral "8px";
        };

        "#scrollbar" = {
          width = mkLiteral "4px";
          border = 0;
          handle-width = mkLiteral "8px";
          padding = 0;
        };

        "#sidebar".border = mkLiteral "2px 0px 0px";

        "#element-icon".spacing = 0;
        "#element-text".spacing = 0;
        "#entry".spacing = 0;
        "#prompt".spacing = 0;
      };
  };
}
