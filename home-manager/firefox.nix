{ pkgs, ... }:
{
  programs.firefox = {
    enable = true;
    # upstream's default moves to $XDG_CONFIG_HOME/mozilla/firefox at
    # stateVersion 26.05. pin the legacy path -- switching means physically
    # moving ~/.mozilla/firefox, which isn't something a rebuild should do.
    configPath = ".mozilla/firefox";
    profiles = {
      default = {
        isDefault = true;
        extensions = {
          packages = with pkgs.nur.repos.rycee.firefox-addons; [
            ublock-origin
            bitwarden
            sponsorblock
            refined-github
          ];
          force = true;
        };
        userChrome = ''
          #back-button, #forward-button {
            display: none;
          }
        '';
        settings = {
          "extensions.autoDisableScopes" = 0;
          "browser.tabs.animate" = false;
          "browser.ml.linkPreview.enabled" = false;
          "screenshots.browser.component.enabled" = false;
          "dom.text_fragments.enabled" = false; # "copy link to highlight"
          "devtools.accessibility.enabled" = false; # annoying in normal use
          "browser.search.visualSearch.featureGate" = false;
          "browser.translations.select.enable" = false;
          "browser.ml.chat.menu" = false;
          "extensions.formautofill.addresses.enabled" = false;
          "extensions.formautofill.creditCards.enabled" = false;
          "print.enabled" = true;
        };
      };
    };
  };

  catppuccin.firefox.force = true;

  xdg.mimeApps.defaultApplications = {
    "text/html" = [ "firefox.desktop" ];
    "text/xml" = [ "firefox.desktop" ];
    "x-scheme-handler/http" = [ "firefox.desktop" ];
    "x-scheme-handler/https" = [ "firefox.desktop" ];
  };
}
