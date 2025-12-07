# Auto-upgrade module for NixOS hosts
#
# Configures system.autoUpgrade to pull from GitHub and apply updates.
# Works with the update-flake-lock GitHub Action for centralized lock file management.
#
# Features:
# - Success/failure notifications via Pushover
# - Prometheus metrics for upgrade duration and status
# - Slow upgrade alerts (configurable threshold)
#
# Usage:
#   modules.autoUpgrade = {
#     enable = true;
#     # Optional overrides:
#     # schedule = "04:00";
#     # rebootWindow = { lower = "03:00"; upper = "05:00"; };
#     # slowThresholdMinutes = 30;
#   };
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.autoUpgrade;
  notificationsEnabled = config.modules.notifications.enable or false;
  alertingEnabled = config.modules.alerting.enable or false;

  textfileDir = "/var/lib/node_exporter/textfile_collector";

  # Script to record upgrade start time
  preScript = pkgs.writeShellScript "nixos-upgrade-pre" ''
    echo "$(date +%s)" > /run/nixos-upgrade-start-time
  '';

  # Script to write Prometheus metrics and trigger success notification
  postSuccessScript = pkgs.writeShellScript "nixos-upgrade-post-success" ''
        set -uf

        START_TIME=$(cat /run/nixos-upgrade-start-time 2>/dev/null || echo "$(date +%s)")
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        DURATION_MIN=$((DURATION / 60))

        # Write Prometheus metrics
        cat > "${textfileDir}/nixos_upgrade.prom.tmp" << EOF
    # HELP nixos_upgrade_last_run_timestamp_seconds Unix timestamp of last upgrade attempt
    # TYPE nixos_upgrade_last_run_timestamp_seconds gauge
    nixos_upgrade_last_run_timestamp_seconds $END_TIME

    # HELP nixos_upgrade_duration_seconds Duration of last upgrade in seconds
    # TYPE nixos_upgrade_duration_seconds gauge
    nixos_upgrade_duration_seconds $DURATION

    # HELP nixos_upgrade_success Whether last upgrade succeeded (1=success, 0=failure)
    # TYPE nixos_upgrade_success gauge
    nixos_upgrade_success 1
    EOF
        mv "${textfileDir}/nixos_upgrade.prom.tmp" "${textfileDir}/nixos_upgrade.prom"

        # Write notification payload
        PAYLOAD_DIR="/run/notify"
        mkdir -p "$PAYLOAD_DIR"

        # Check if this was a slow upgrade
        if [ "$DURATION_MIN" -ge ${toString cfg.slowThresholdMinutes} ]; then
          PRIORITY="high"
          TITLE="⚠️ NixOS Upgrade Slow"
        else
          PRIORITY="low"
          TITLE="✅ NixOS Upgrade Complete"
        fi

        cat > "$PAYLOAD_DIR/nixos-upgrade-success.json" << EOF
    {
      "priority": "$PRIORITY",
      "title": "$TITLE",
      "message": "Host: ${config.networking.hostName}\nDuration: ''${DURATION_MIN}m ''${DURATION}s\n\nUpgrade completed successfully."
    }
    EOF

        rm -f /run/nixos-upgrade-start-time
  '';

  # Script to write failure metrics
  postFailureScript = pkgs.writeShellScript "nixos-upgrade-post-failure" ''
        set -uf

        START_TIME=$(cat /run/nixos-upgrade-start-time 2>/dev/null || echo "$(date +%s)")
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))

        # Write Prometheus metrics indicating failure
        cat > "${textfileDir}/nixos_upgrade.prom.tmp" << EOF
    # HELP nixos_upgrade_last_run_timestamp_seconds Unix timestamp of last upgrade attempt
    # TYPE nixos_upgrade_last_run_timestamp_seconds gauge
    nixos_upgrade_last_run_timestamp_seconds $END_TIME

    # HELP nixos_upgrade_duration_seconds Duration of last upgrade in seconds
    # TYPE nixos_upgrade_duration_seconds gauge
    nixos_upgrade_duration_seconds $DURATION

    # HELP nixos_upgrade_success Whether last upgrade succeeded (1=success, 0=failure)
    # TYPE nixos_upgrade_success gauge
    nixos_upgrade_success 0
    EOF
        mv "${textfileDir}/nixos_upgrade.prom.tmp" "${textfileDir}/nixos_upgrade.prom"

        rm -f /run/nixos-upgrade-start-time
  '';
in
{
  options.modules.autoUpgrade = {
    enable = lib.mkEnableOption "automatic system upgrades from GitHub";

    flakeUrl = lib.mkOption {
      type = lib.types.str;
      default = "github:carpenike/nix-config";
      description = "GitHub flake URL to pull updates from";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "04:00";
      description = "Time to run auto-upgrade (24-hour format)";
    };

    randomizedDelay = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = "Random delay to avoid thundering herd";
    };

    allowReboot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow automatic reboots when kernel changes";
    };

    rebootWindow = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          lower = lib.mkOption {
            type = lib.types.str;
            default = "03:00";
            description = "Start of reboot window (24-hour format)";
          };
          upper = lib.mkOption {
            type = lib.types.str;
            default = "05:00";
            description = "End of reboot window (24-hour format)";
          };
        };
      });
      default = null;
      description = "Time window during which reboots are allowed";
    };

    persistent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run missed upgrades on next boot";
    };

    slowThresholdMinutes = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Upgrade duration (minutes) after which to send high-priority notification";
    };
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      flake = "${cfg.flakeUrl}#${config.networking.hostName}";
      dates = cfg.schedule;
      randomizedDelaySec = cfg.randomizedDelay;
      persistent = cfg.persistent;

      # Don't try to write lock file - we're pulling from GitHub
      flags = [ "--no-write-lock-file" ];

      # Reboot settings
      allowReboot = cfg.allowReboot;
      rebootWindow = lib.mkIf (cfg.rebootWindow != null) cfg.rebootWindow;
    };

    # Ensure textfile collector directory exists
    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root -"
    ];

    # Register notification templates
    # Note: Success notification is handled directly by nixos-upgrade-metrics service
    # which writes JSON with duration info - no template needed
    modules.notifications.templates = lib.mkIf notificationsEnabled {
      nixos-upgrade-failure = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        title = "❌ NixOS Upgrade Failed";
        body = ''
          Automatic NixOS upgrade failed on ${config.networking.hostName}.

          Check logs with: journalctl -u nixos-upgrade.service -n 100
        '';
      };
    };

    # Path unit to trigger success notification
    systemd.paths."notify-pushover@nixos-upgrade-success" = lib.mkIf notificationsEnabled {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/run/notify/nixos-upgrade-success.json";
      };
    };

    # Path unit to trigger failure notification
    systemd.paths."notify-pushover@nixos-upgrade-failure" = lib.mkIf notificationsEnabled {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/run/notify/nixos-upgrade-failure.json";
      };
    };

    # Extend nixos-upgrade service with metrics and notifications
    systemd.services.nixos-upgrade = {
      # Record start time before upgrade
      preStart = "${preScript}";

      # Add failure notifications and metrics
      # - notify@ sends immediate Pushover notification
      # - failure-metrics records to Prometheus for dashboards (no duplicate alert)
      onFailure =
        (lib.optionals notificationsEnabled [ "notify@nixos-upgrade-failure.service" ])
        ++ (lib.optionals alertingEnabled [ "nixos-upgrade-failure-metrics.service" ]);

      # Success is handled by nixos-upgrade-metrics.service which:
      # - Records metrics to Prometheus
      # - Writes notification JSON with duration info
      # - Triggers notify-pushover@ via path unit
    };

    # Separate service to record metrics after upgrade completes
    systemd.services.nixos-upgrade-metrics = {
      description = "Record NixOS upgrade metrics";
      after = [ "nixos-upgrade.service" ];
      wantedBy = [ "nixos-upgrade.service" ];
      unitConfig = {
        # Only run if nixos-upgrade succeeded
        ConditionPathExists = "/run/nixos-upgrade-start-time";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = postSuccessScript;
        RemainAfterExit = false;
      };
    };

    # Service to record failure metrics
    systemd.services.nixos-upgrade-failure-metrics = lib.mkIf alertingEnabled {
      description = "Record NixOS upgrade failure metrics";
      unitConfig = {
        # Only run if start time was recorded
        ConditionPathExists = "/run/nixos-upgrade-start-time";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = postFailureScript;
        RemainAfterExit = false;
      };
    };

    # Prometheus alerts for upgrade issues
    # Note: Failure notifications are handled immediately via Pushover (onFailure handler)
    # These alerts are for observability dashboards and detecting missed upgrades
    modules.alerting.rules = lib.mkIf alertingEnabled {
      "nixos-upgrade-slow" = {
        type = "promql";
        alertname = "NixOSUpgradeSlow";
        expr = "nixos_upgrade_duration_seconds > ${toString (cfg.slowThresholdMinutes * 60)}";
        for = "0m";
        severity = "medium";
        labels = {
          category = "system";
          service = "nixos-upgrade";
        };
        annotations = {
          summary = "NixOS upgrade took {{ $value | humanizeDuration }} on {{ $labels.instance }}";
          description = "The automatic NixOS upgrade took longer than ${toString cfg.slowThresholdMinutes} minutes. This may indicate cache issues or network problems.";
          command = "journalctl -u nixos-upgrade.service --since '6 hours ago'";
        };
      };

      "nixos-upgrade-stale" = {
        type = "promql";
        alertname = "NixOSUpgradeStale";
        expr = "time() - nixos_upgrade_last_run_timestamp_seconds > 90000"; # 25 hours
        for = "1h";
        severity = "medium";
        labels = {
          category = "system";
          service = "nixos-upgrade";
        };
        annotations = {
          summary = "NixOS upgrade hasn't run in over 25 hours on {{ $labels.instance }}";
          description = "The automatic NixOS upgrade timer may have failed or the system hasn't been online.";
          command = "systemctl status nixos-upgrade.timer nixos-upgrade.service";
        };
      };
    };
  };
}
