# Glances System Monitoring
#
# Provides real-time system monitoring via web interface
# Used by Homepage dashboard for system stats widget

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.glances.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.glances = {
        enable = true;
        port = 61208;

        # Reverse proxy for external access
        reverseProxy = {
          enable = true;
          hostName = "glances.forge.holthome.net";
          # Uses PocketID/caddy-security for authentication
          caddySecurity = forgeDefaults.caddySecurity.admin;
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # Service availability alert
      modules.alerting.rules."glances-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "glances-web" "Glances" "system monitoring";

      # Homepage dashboard contributions - multiple Glances widgets for different metrics
      # All widgets link to the main Glances UI
      modules.services.homepage.contributions = let
        glancesUrl = "https://glances.forge.holthome.net";
        baseWidget = {
          type = "glances";
          url = "http://localhost:61208";
          version = 4;
        };
      in {
        # System info widget (hostname, OS, kernel, CPU/RAM/SWAP usage)
        glances-info = {
          group = "System Resources";
          name = "System Info";
          icon = "glances";
          href = glancesUrl;
          widget = baseWidget // { metric = "info"; };
        };

        # CPU usage graph
        glances-cpu = {
          group = "System Resources";
          name = "CPU Usage";
          icon = "mdi-cpu-64-bit";
          href = glancesUrl;
          widget = baseWidget // { metric = "cpu"; };
        };

        # Memory usage graph
        glances-memory = {
          group = "System Resources";
          name = "Memory Usage";
          icon = "mdi-memory";
          href = glancesUrl;
          widget = baseWidget // { metric = "memory"; };
        };

        # Top processes by CPU
        glances-process = {
          group = "System Resources";
          name = "Top Processes";
          icon = "mdi-application-cog";
          href = glancesUrl;
          widget = baseWidget // { metric = "process"; };
        };

        # GPU usage (Intel integrated or discrete)
        glances-gpu = {
          group = "System Resources";
          name = "GPU Usage";
          icon = "mdi-expansion-card";
          href = glancesUrl;
          widget = baseWidget // { metric = "gpu:0"; };
        };

        # Root filesystem usage
        glances-fs-root = {
          group = "System Resources";
          name = "Root Filesystem";
          icon = "mdi-harddisk";
          href = glancesUrl;
          widget = baseWidget // { metric = "fs:/"; };
        };

        # Link to full Glances UI (in Infrastructure group for quick access)
        glances = {
          group = "Infrastructure";
          name = "Glances";
          icon = "glances";
          href = glancesUrl;
          description = "Full System Monitoring Dashboard";
        };
      };
    })
  ];
}
