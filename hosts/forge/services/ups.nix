# UPS Monitoring Configuration
#
# Monitors APC Smart-UPS 2200 RM XL via SNMP for graceful shutdown on low battery.
# Exports metrics to Prometheus via node_exporter textfile collector.
#
# Infrastructure Contributions:
#   - Backup: Not applicable (hardware monitor, no persistent data)
#   - Sanoid: Not applicable (no ZFS dataset)
#   - Monitoring: UPS-specific alerts defined below (battery, load, status)
{ config, pkgs, lib, mylib, ... }:
let
  serviceEnabled = config.power.ups.enable or false;
in
{
  # UPS system control (graceful shutdown on low battery)
  # Using Network UPS Tools (NUT) to monitor APC Smart-UPS 2200 RM XL at 10.9.18.245
  #
  # NixOS 25.05 uses power.ups module (not services.nut)
  # APC Network Management Cards use SNMP, not NUT server (upsd)
  # This uses standalone mode with snmp-ups driver to monitor via SNMP
  #
  # Prometheus metrics are exported via node_exporter textfile collector every 15 seconds
  # Security: Runs as node-exporter user (same pattern as pgbackrest metrics) with systemd hardening
  # TODO: Change SNMP community string from 'public' for better security
  # TODO: Migrate hardcoded passwords to sops-nix secrets management

  power.ups = {
    enable = true;
    mode = "standalone";

    # Define the UPS - using snmp-ups driver for APC network management card
    ups.apc = {
      driver = "snmp-ups";
      port = "10.9.18.245";  # IP address of the APC network management card
      description = "APC Smart-UPS 2200 RM XL";

      # SNMP driver configuration for APC
      # Note: Not specifying mibs directive - let NUT auto-detect the correct MIB
      directives = [
        "community = public"     # Default SNMP community string (TODO: verify/change)
      ];
    };

    # Monitor the local UPS (upsd runs locally in standalone mode)
    upsmon.monitor.apc = {
      system = "apc@localhost";
      powerValue = 1;
      user = "upsmon";
      passwordFile = toString (pkgs.writeText "upsmon-password" "changeme");
      type = "primary";  # This system initiates shutdown (formerly "master")
    };

    # Define the upsmon user for local upsd access
    users.upsmon = {
      passwordFile = toString (pkgs.writeText "upsmon-password" "changeme");
      upsmon = "primary";  # Primary monitoring role (formerly "master")
      # Allow this user to set variables and trigger forced shutdown
      actions = [ "set" "fsd" ];
      instcmds = [ "all" ];
    };
  };

  # Install NUT client utilities for manual UPS querying
  # Use: upsc apc@localhost to check UPS status
  environment.systemPackages = [ pkgs.nut ];

  # Add network dependency to UPS driver service
  # The UPS is accessed via SNMP over the network at 10.9.18.245
  # Without this, the service can start before network is available, causing failures
  systemd.services.upsdrv = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # Export UPS metrics to Prometheus via node_exporter textfile collector
  # Metrics are written to /var/lib/node_exporter/textfile_collector/ups.prom
  # and automatically scraped by the existing node_exporter service
  systemd.timers.ups-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";           # Start 1 minute after boot
      OnUnitActiveSec = "15s";    # Run every 15 seconds
      Unit = "ups-metrics.service";
    };
  };

  systemd.services.ups-metrics = {
    description = "Export UPS metrics to Prometheus textfile collector";
    after = [ "upsd.service" "upsmon.service" "prometheus-node-exporter.service" ];
    wants = [ "prometheus-node-exporter.service" ];

    serviceConfig = {
      Type = "oneshot";
      # Run as node-exporter user to write to textfile directory
      # Follows same pattern as pgbackrest metrics in default.nix
      User = "node-exporter";
      # upsc queries upsd over TCP/localhost and doesn't require special group membership
      # Systemd hardening
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      # Allow writing to the textfile directory
      ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];
    };

    script = ''
      # Capture timestamp and check if upsc succeeds
      TIMESTAMP=$(${pkgs.coreutils}/bin/date +%s)
      TEMP_DATA=$(${pkgs.coreutils}/bin/mktemp)

      # Query UPS status and check exit code
      if ${pkgs.nut}/bin/upsc apc@localhost > "$TEMP_DATA" 2>/dev/null; then
        SCRAPE_SUCCESS=1
      else
        SCRAPE_SUCCESS=0
      fi

      # Process UPS data and convert to Prometheus format
      ${pkgs.coreutils}/bin/cat "$TEMP_DATA" | ${pkgs.gawk}/bin/awk '
        BEGIN {
          OFS = ""
          # Initialize status flags to 0
          on_battery = 0
          low_battery = 0
          online = 0
        }

        # Battery metrics
        /^battery\.charge:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_battery_charge{ups=\"apc\"} ", $2
        }
        /^battery\.runtime:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_battery_runtime_seconds{ups=\"apc\"} ", $2
        }
        /^battery\.voltage:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_battery_voltage{ups=\"apc\"} ", $2
        }

        # Load and power metrics
        /^ups\.load:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_load_percent{ups=\"apc\"} ", $2
        }
        /^ups\.realpower\.nominal:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_realpower_nominal_watts{ups=\"apc\"} ", $2
        }

        # Voltage metrics
        /^input\.voltage:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_input_voltage{ups=\"apc\"} ", $2
        }
        /^output\.voltage:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_output_voltage{ups=\"apc\"} ", $2
        }

        # Temperature
        /^ups\.temperature:/ {
          if ($2 ~ /^[0-9.]+$/) print "ups_temperature_celsius{ups=\"apc\"} ", $2
        }

        # UPS status flags - parse the entire status string (can be multi-token like "OB LB")
        /^ups\.status:/ {
          # Extract everything after the colon to capture full status string
          idx = index($0, ":")
          status = substr($0, idx+2)
          # OB = On Battery, LB = Low Battery, OL = Online
          if (status ~ /OB/) on_battery = 1
          if (status ~ /LB/) low_battery = 1
          if (status ~ /OL/) online = 1
        }

        END {
          # Output status flags
          print "ups_on_battery{ups=\"apc\"} ", on_battery
          print "ups_low_battery{ups=\"apc\"} ", low_battery
          print "ups_online{ups=\"apc\"} ", online
        }
      ' > /var/lib/node_exporter/textfile_collector/ups.prom.tmp

      # Add scrape metadata metrics
      echo "ups_metrics_scrape_success{ups=\"apc\"} $SCRAPE_SUCCESS" >> /var/lib/node_exporter/textfile_collector/ups.prom.tmp
      echo "ups_metrics_last_scrape_timestamp_seconds{ups=\"apc\"} $TIMESTAMP" >> /var/lib/node_exporter/textfile_collector/ups.prom.tmp

      # Clean up temp file
      ${pkgs.coreutils}/bin/rm -f "$TEMP_DATA"

      # Atomic move to prevent partial reads
      ${pkgs.coreutils}/bin/mv /var/lib/node_exporter/textfile_collector/ups.prom.tmp \
                               /var/lib/node_exporter/textfile_collector/ups.prom

      # Set appropriate permissions (644 allows node_exporter to read)
      ${pkgs.coreutils}/bin/chmod 644 /var/lib/node_exporter/textfile_collector/ups.prom
    '';
  };

  # Alert rules for UPS monitoring
  # Using monitoring-helpers library for consistency where patterns fit
  modules.alerting.rules = lib.mkIf serviceEnabled {
    # Metrics scraping failure - using threshold helper
    "ups-metrics-scrape-failed" = mylib.monitoring-helpers.mkThresholdAlert {
      name = "ups";
      alertname = "UPSMetricsScrapeFailure";
      expr = "ups_metrics_scrape_success == 0";
      threshold = 0;
      for = "5m";
      severity = "high";
      category = "monitoring";
      summary = "UPS metrics collection failed on {{ $labels.instance }}";
      description = "Unable to scrape UPS metrics from NUT. Check ups-metrics.service and upsd.service logs.";
    };

    # UPS-specific alerts - these have unique descriptions/context that don't fit generic helpers
    # Keeping them as custom alerts for clarity and UPS-specific language
    "ups-on-battery" = {
      type = "promql";
      alertname = "UPSOnBattery";
      expr = "ups_on_battery == 1";
      for = "2m";
      severity = "medium";
      labels = { service = "ups"; category = "power"; };
      annotations = {
        summary = "UPS {{ $labels.ups }} running on battery power";
        description = "Power outage detected. Current battery: {{ with query \"ups_battery_charge{ups='apc'}\" }}{{ . | first | value }}{{ end }}%, runtime: {{ with query \"ups_battery_runtime_seconds{ups='apc'}\" }}{{ . | first | value | humanizeDuration }}{{ end }}";
      };
    };

    # Low battery warning - Runtime calibration completed (October 2025)
    "ups-low-battery" = {
      type = "promql";
      alertname = "UPSLowBattery";
      expr = "ups_low_battery == 1";
      for = "0s";  # Immediate alert
      severity = "critical";
      labels = { service = "ups"; category = "power"; };
      annotations = {
        summary = "UPS {{ $labels.ups }} battery critically low";
        description = "UPS low battery flag set. System shutdown imminent. Battery: {{ with query \"ups_battery_charge{ups='apc'}\" }}{{ . | first | value }}{{ end }}%, runtime: {{ with query \"ups_battery_runtime_seconds{ups='apc'}\" }}{{ . | first | value | humanizeDuration }}{{ end }}";
      };
    };

    # Battery charge threshold using capacity helper
    "ups-battery-charge-low" = mylib.monitoring-helpers.mkHighCapacityAlert {
      name = "ups";
      expr = "ups_battery_charge < 50";
      threshold = 50;
      for = "5m";
      severity = "medium";
      category = "power";
      summary = "UPS {{ $labels.ups }} battery charge below 50%";
      description = "Battery charge at {{ $value }}%. Runtime remaining: {{ with query \"ups_battery_runtime_seconds{ups='apc'}\" }}{{ . | first | value | humanizeDuration }}{{ end }}";
    };

    # Runtime critically low (less than 5 minutes)
    "ups-runtime-critical" = {
      type = "promql";
      alertname = "UPSRuntimeCritical";
      expr = "ups_battery_runtime_seconds < 300";
      for = "1m";
      severity = "critical";
      labels = { service = "ups"; category = "power"; };
      annotations = {
        summary = "UPS {{ $labels.ups }} runtime critically low";
        description = "Only {{ $value | humanizeDuration }} of battery runtime remaining. Prepare for shutdown.";
      };
    };

    # High load warning using threshold helper
    "ups-load-high" = mylib.monitoring-helpers.mkThresholdAlert {
      name = "ups";
      alertname = "UPSLoadHigh";
      expr = "ups_load_percent > 80";
      threshold = 80;
      for = "10m";
      severity = "medium";
      category = "capacity";
      summary = "UPS {{ $labels.ups }} load is high";
      description = "Current load: {{ $value }}%. Consider load balancing or UPS upgrade if sustained.";
    };

    # Temperature warning using threshold helper
    "ups-temperature-high" = mylib.monitoring-helpers.mkThresholdAlert {
      name = "ups";
      alertname = "UPSTemperatureHigh";
      expr = "ups_temperature_celsius > 30";
      threshold = 30;
      for = "15m";
      severity = "medium";
      category = "health";
      summary = "UPS {{ $labels.ups }} temperature elevated";
      description = "UPS temperature at {{ $value }}°C. Check ventilation and ambient temperature.";
    };

    # UPS offline using threshold helper
    "ups-offline" = mylib.monitoring-helpers.mkThresholdAlert {
      name = "ups";
      alertname = "UPSOffline";
      expr = "ups_online == 0";
      threshold = 0;
      for = "2m";
      severity = "critical";
      category = "connectivity";
      summary = "UPS {{ $labels.ups }} appears offline";
      description = "Cannot communicate with UPS or UPS reports offline status. Check network connectivity and UPS health.";
    };
  };
}
