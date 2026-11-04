# hermes webapp: the gateway serves the desktop workspace to a browser.
#
# this is config only -- the pinned hermes-agent already ships
# gateway/webapp_listener.py and a prebuilt webapp bundle, so no upstream
# change is needed. public_url turns on the sign-in gate (a signed-in webapp
# user can run commands as ethernet), and Caddy puts Authelia in front of it
# as well. the dashboard basic-auth provider is the gate's own login.
{ config, lib, ... }:
let
  cfg = config.me.bellona;
in
{
  config = lib.mkIf cfg.enable {
    home-manager.users.ethernet.services.hermes-agent.settings = {
      webapp = {
        enabled = true;
        host = "127.0.0.1";
        port = 9120;
        public_url = "https://hermes.${cfg.domain}";
      };
      dashboard = {
        public_url = "https://hermes.${cfg.domain}";
        basic_auth = {
          username = "ethernet";
          password = "6ace516154cafabd93fd8fd3";
        };
      };
    };
  };
}
