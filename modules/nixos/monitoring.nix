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
    # Operational safety warnings
    warnings = optional (!cfg.nodeExporter.enable)
      "modules.monitoring is enabled but nodeExporter is disabled - no metrics will be collected";

    # Enable Prometheus Node Exporter with common defaults
    services.prometheus.exporters.node = {
      enable = mkDefault cfg.nodeExporter.enable;
      port = mkDefault cfg.nodeExporter.port;
      listenAddress = cfg.nodeExporter.listenAddress;
      enabledCollectors = mkDefault cfg.nodeExporter.enabledCollectors;

      extraFlags =
        optionals cfg.nodeExporter.textfileCollector.enable [
          "--collector.textfile.directory=${cfg.nodeExporter.textfileCollector.directory}"
        ]
        # Exposes node_systemd_service_restart_total, a per-unit counter of
        # systemd Restart= triggers. node_exporter gates it behind this flag
        # (off by default), so without it the counter is simply absent.
        #
        # It is the only crash-loop signal that survives scrape aliasing.
        # node_systemd_unit_state is sampled every 30s, so a unit that fails
        # and comes back inside one scrape interval reads as `active` almost
        # every time -- during the 43-minute Home Assistant loop on
        # 2026-08-16, 112 of 121 samples read active and the ServiceDown rule
        # could never hold its 2m condition. A monotonic counter increments on
        # every restart regardless of when the scrape lands.
        ++ optionals (elem "systemd" cfg.nodeExporter.enabledCollectors) [
          "--collector.systemd.enable-restarts-metrics"
        ];
    };

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.nodeExporter.openFirewall [ cfg.nodeExporter.port ];

    # Create textfile collector directory if enabled
    # Permissions: 2770 = setgid + rwx for owner/group, none for others
    # The setgid bit (2) ensures new files inherit the node-exporter group
    # Group write (7) allows services with SupplementaryGroups=["node-exporter"] to write metrics
    systemd.tmpfiles.rules = mkIf cfg.nodeExporter.textfileCollector.enable [
      "d ${cfg.nodeExporter.textfileCollector.directory} 2770 node-exporter node-exporter -"
    ];

    # Build-time assertion to ensure node-exporter group exists
    # This catches any future NixOS channel changes where the group name might change
    assertions = [
      {
        assertion = config.users.groups ? "node-exporter";
        message = "Expected users.groups.node-exporter to exist (Node Exporter group). This is required for textfile collector permissions.";
      }
    ];
  };
}
