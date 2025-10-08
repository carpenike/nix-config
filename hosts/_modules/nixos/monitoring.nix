{ config, lib, ... }:

with lib;

let
  cfg = config.modules.monitoring;
in
{
  options.modules.monitoring = {
    enable = mkEnableOption "Prometheus Node Exporter monitoring";

    nodeExporter = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Prometheus Node Exporter";
      };

      port = mkOption {
        type = types.port;
        default = 9100;
        description = "Port for Node Exporter to listen on";
      };

      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = ''
          Address for Node Exporter to listen on.
          Use "0.0.0.0" for internal network access, "127.0.0.1" for localhost only.
          This is a security-sensitive setting - consider host requirements carefully.
        '';
      };

      enabledCollectors = mkOption {
        type = types.listOf types.str;
        default = [ "systemd" ];
        description = "List of collectors to enable by default";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open firewall port for Prometheus scraping.
          Set to false by default for security - enable explicitly per host.
        '';
      };

      textfileCollector = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable textfile collector for custom metrics";
        };

        directory = mkOption {
          type = types.path;
          default = "/var/lib/node_exporter/textfile_collector";
          description = "Directory for textfile collector metrics";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    # Enable Prometheus Node Exporter with common defaults
    services.prometheus.exporters.node = {
      enable = mkDefault cfg.nodeExporter.enable;
      port = mkDefault cfg.nodeExporter.port;
      listenAddress = cfg.nodeExporter.listenAddress;
      enabledCollectors = mkDefault cfg.nodeExporter.enabledCollectors;

      extraFlags = mkIf cfg.nodeExporter.textfileCollector.enable [
        "--collector.textfile.directory=${cfg.nodeExporter.textfileCollector.directory}"
      ];
    };

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.nodeExporter.openFirewall [ cfg.nodeExporter.port ];

    # Create textfile collector directory if enabled
    systemd.tmpfiles.rules = mkIf cfg.nodeExporter.textfileCollector.enable [
      "d ${cfg.nodeExporter.textfileCollector.directory} 0755 node-exporter node-exporter -"
    ];
  };
}
