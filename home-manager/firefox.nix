{ pkgs, lib, ... }:
let
  ffAddons = pkgs.nur.repos.rycee.firefox-addons;

  # addon -> extra ExtensionSettings keys. private_browsing is emitted only
  # where listed: an explicit false revokes access and greys out the toggle,
  # which is a bigger lockdown than freezing the addon set.
  addons = {
    ublock-origin.private_browsing = true;
    bitwarden = { };
    sponsorblock = { };
    refined-github = { };
    vimium = { };
    user-agent-string-switcher = { };
  };

  # rycee's addon packages drop exactly one xpi, named after the addon id,
  # under the firefox application id. policies force_installed needs a URL to
  # that file rather than the package.
  firefoxAppId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";
  forceInstalled = lib.mapAttrs' (
    name: extra:
    let
      addon = ffAddons.${name};
    in
    lib.nameValuePair addon.addonId (
      {
        installation_mode = "force_installed";
        install_url = "file://${addon}/share/mozilla/extensions/${firefoxAppId}/${addon.addonId}.xpi";
      }
      // extra
    )
  ) addons;
in
{
  programs.firefox = {
    enable = true;
    # upstream's default moves to $XDG_CONFIG_HOME/mozilla/firefox at
    # stateVersion 26.05. pin the legacy path -- switching means physically
    # moving ~/.mozilla/firefox, which isn't something a rebuild should do.
    configPath = ".mozilla/firefox";

    policies = {
      # the addon set is frozen here rather than in the profile: everything is
      # blocked by default, so the addons page offers neither install nor
      # remove for anything, including the entries below.
      ExtensionSettings = {
        "*" = {
          installation_mode = "blocked";
        };
      }
      // forceInstalled;

      # bitwarden owns credentials. the built-in manager only competes with it.
      PasswordManagerEnabled = false;
      OfferToSaveLogins = false;
      DisableFirefoxAccounts = false;

      # blank new tab, and nothing on about:home either.
      NewTabPage = false;
      FirefoxHome = {
        Search = false;
        TopSites = false;
        SponsoredTopSites = false;
        Highlights = false;
        Pocket = false;
        SponsoredPocket = false;
        Stories = false;
        SponsoredStories = false;
        Snippets = false;
        Locked = true;
      };
    };

    profiles = {
      default = {
        isDefault = true;
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
          "print.enabled" = true;

          # no stored credentials, no autofill, no capture prompts.
          "signon.rememberSignons" = false;
          "signon.autofillForms" = false;
          "signon.generation.enabled" = false;
          "signon.management.page.breach-alerts.enabled" = false;
          "signon.firefoxRelay.feature" = "disabled";
          "extensions.formautofill.addresses.enabled" = false;
          "extensions.formautofill.creditCards.enabled" = false;

          # new tab: no page, and every widget off in case one ever renders.
          "browser.newtabpage.enabled" = false;
          "browser.newtabpage.activity-stream.showSearch" = false;
          "browser.newtabpage.activity-stream.feeds.topsites" = false;
          "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
          "browser.newtabpage.activity-stream.feeds.section.highlights" = false;
          "browser.newtabpage.activity-stream.feeds.snippets" = false;
          "browser.newtabpage.activity-stream.feeds.weatherfeed" = false;
          "browser.newtabpage.activity-stream.showWeather" = false;
          "browser.newtabpage.activity-stream.showSponsored" = false;
          "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
          "browser.newtabpage.activity-stream.system.showSponsored" = false;
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
