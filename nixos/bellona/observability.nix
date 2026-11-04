# observability: metrics, logs, dashboards. "keep everything" means long
# retention, not a pretend retention policy: metrics 10y, Loki retention
# disabled (0s), and the archive lives on tank.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.me.bellona;
in
{
  config = lib.mkIf cfg.enable {
    age.secrets.grafana-admin = {
      file = ../../secrets/grafana-admin.age;
      owner = "grafana";
      mode = "0400";
    };

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
        "tcpstat"
        "conntrack"
      ];
    };

    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      retentionPeriod = "10y";
      prometheusConfig.scrape_configs = [
        {
          job_name = "node";
          scrape_interval = "30s";
          static_configs = [
            {
              targets = [
                "127.0.0.1:9100"
                "100.108.28.67:9100" # luna
                "100.102.87.69:9100" # phobos
              ];
            }
          ];
        }
        {
          job_name = "vllm";
          metrics_path = "/metrics";
          scrape_interval = "15s";
          static_configs = [
            { targets = [ "100.102.87.69:8888" ]; } # phobos spark endpoint
          ];
        }
        {
          job_name = "qbittorrent";
          scrape_interval = "30s";
          static_configs = [ { targets = [ "127.0.0.1:9877" ]; } ];
        }
      ];
    };

    services.loki = {
      enable = true;
      dataDir = "/tank/logs/loki";
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 3100;
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9095;
        };
        common = {
          path_prefix = "/tank/logs/loki";
          storage.filesystem = {
            chunks_directory = "/tank/logs/loki/chunks";
            rules_directory = "/tank/logs/loki/rules";
          };
          replication_factor = 1;
          ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
        };
        schema_config.configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
        limits_config = {
          retention_period = "0s"; # keep forever
          allow_structured_metadata = true;
          volume_enabled = true;
        };
        compactor = {
          working_directory = "/tank/logs/loki/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
      };
    };
    systemd.services.loki.after = [ "tank.mount" ];
    systemd.services.loki.requires = [ "tank.mount" ];

    services.alloy = {
      enable = true;
      configPath = "/etc/alloy";
    };
    environment.etc."alloy/config.alloy".text = ''
      logging {
        level = "warn"
      }

      loki.source.journal "journal" {
        forward_to = [loki.write.local.receiver]
      }

      loki.write "local" {
        endpoint {
          url = "http://127.0.0.1:3100/loki/api/v1/push"
        }
      }
    '';

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = "grafana.${cfg.domain}";
          root_url = "https://grafana.${cfg.domain}";
        };
        security = {
          admin_password = "$__file{/run/agenix/grafana-admin}";
          secret_key = "bellona-grafana-secret-key-2026";
        };
        auth = {
          disable_login_form = true;
          "proxy.enabled" = true;
          "proxy.header_name" = "Remote-User";
          "proxy.header_property" = "username";
          "proxy.auto_sign_up" = true;
          "proxy.sync_ttl" = 15;
        };
        users.auto_assign_org_role = "Viewer";
      };
      provision.datasources.settings.datasources = [
        {
          name = "VictoriaMetrics";
          type = "prometheus";
          url = "http://127.0.0.1:8428";
          access = "proxy";
          isDefault = true;
        }
        {
          name = "Loki";
          type = "loki";
          url = "http://127.0.0.1:3100";
          access = "proxy";
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [ 9100 ];
  };
}
