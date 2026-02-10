# Auto-upgrade module for NixOS hosts
#
# Configures system.autoUpgrade to pull from GitHub and apply updates.
# Works with the update-flake-lock GitHub Action for centralized lock file management.
#
# Features:
# - Success/failure notifications via Pushover
# - Prometheus metrics for upgrade duration and status
# - Slow upgrade alerts (configurable threshold)
# - Tolerates transient unit failures (exit code 4) during switch
#
# Exit Code Handling:
#   Code 0: Complete success
#   Code 4: Configuration applied, but transient units failed (treated as success)
#           This commonly occurs when Podman healthcheck services fire during container
#           restart and the container is still in "starting" state.
#   Other:  Real failure
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

  # Script to record upgrade start time and clean up transient failures
  #
  # RATIONALE: When Podman containers restart during switch-to-configuration,
  # their transient healthcheck timers (created by systemd-run) may fire while
  # containers are in "starting" state. This causes the healthcheck to return
  # "unhealthy" (exit code 1), which fails the transient service. The
  # switch-to-configuration script then sees these failed units and returns
  # status 4 (NOPERMISSION/failed units), causing the upgrade to "fail" even
  # though the actual configuration switch succeeded.
  #
  # This pre-script:
  # 1. Records the upgrade start time for metrics
  # 2. Resets all failed units (especially transient Podman healthcheck services)
  #
  # Note: We also set SuccessExitStatus=4 to treat exit code 4 as success, since
  # it specifically means "configuration applied but some transient units failed."
  #
  # The reset-failed is safe because:
  # - Transient units are ephemeral and will be recreated by Podman
  # - Persistent unit failures will reappear if the underlying issue persists
  # - We're only clearing the "failed" state, not stopping/masking any units
  preScript = pkgs.writeShellScript "nixos-upgrade-pre" ''
    set -euo pipefail

    echo "$(date +%s)" > /run/nixos-upgrade-start-time

    # Reset all failed units to prevent transient healthcheck failures from
    # causing switch-to-configuration to return status 4
    echo "Resetting failed systemd units before upgrade..."
    ${pkgs.systemd}/bin/systemctl reset-failed || true

    # Log any currently running healthcheck timers for debugging
    HEALTHCHECK_COUNT=$(${pkgs.systemd}/bin/systemctl list-units --all --type=timer 2>/dev/null | grep -c "healthcheck" || echo "0")
    echo "Found $HEALTHCHECK_COUNT active healthcheck timers"
  '';

  # Script to write Prometheus metrics and trigger success notification
  # Note: This runs for both exit code 0 (clean success) and exit code 4
  # (config applied but transient units failed) since we set SuccessExitStatus=4
  postSuccessScript = pkgs.writeShellScript "nixos-upgrade-post-success" ''
        set -uf

        START_TIME=$(cat /run/nixos-upgrade-start-time 2>/dev/null || echo "$(date +%s)")
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        DURATION_MIN=$((DURATION / 60))

        # Check for transient unit failures (indicates exit code 4 scenario)
        TRANSIENT_FAILURES=0
        FAILED_UNITS=$(${pkgs.systemd}/bin/systemctl list-units --failed --no-legend 2>/dev/null | grep -c "." || echo "0")
        if [ "$FAILED_UNITS" -gt 0 ]; then
          TRANSIENT_FAILURES=1
          echo "Note: Upgrade completed with $FAILED_UNITS transient unit failure(s) (exit code 4)"
        fi

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

    # HELP nixos_upgrade_transient_failures Whether transient unit failures occurred (exit code 4)
    # TYPE nixos_upgrade_transient_failures gauge
    nixos_upgrade_transient_failures $TRANSIENT_FAILURES
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

    # HELP nixos_upgrade_transient_failures Whether transient unit failures occurred (exit code 4)
    # TYPE nixos_upgrade_transient_failures gauge
    nixos_upgrade_transient_failures 0
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

    memoryHigh = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "24G";
      description = ''
        Soft memory limit for the upgrade process. When exceeded, memory allocation
        is throttled. Set to null to disable. Useful to prevent builds from consuming
        all system RAM.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "28G";
      description = ''
        Hard memory limit for the upgrade process. If exceeded, the service will
        be OOM-killed. Set to null to disable.
      '';
    };

    limitNOFILE = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.ints.positive lib.types.str);
      default = null;
      example = 524288;
      description = ''
        File descriptor limit for the upgrade process. Large closures can exhaust
        the default soft limit (1024) during nix build evaluation, causing
        "Too many open files" errors. Set to null to use the systemd default.
      '';
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

    # Extend nixos-upgrade service with metrics, notifications, and OOM protection
    systemd.services.nixos-upgrade = {
      # Record start time and reset failed units before upgrade
      preStart = "${preScript}";

      # Clean up transient healthcheck failures after upgrade completes
      # This runs regardless of exit code and resets failed transient units
      postStop = ''
        # Reset transient healthcheck services that may have failed during container restarts
        # These are created by systemd-run and have long hex names
        ${pkgs.systemd}/bin/systemctl reset-failed 2>/dev/null || true

        # Log final state for debugging
        FAILED_COUNT=$(${pkgs.systemd}/bin/systemctl list-units --failed --no-legend 2>/dev/null | wc -l || echo "0")
        if [ "$FAILED_COUNT" -gt 0 ]; then
          echo "Note: $FAILED_COUNT systemd units currently in failed state after upgrade"
          ${pkgs.systemd}/bin/systemctl list-units --failed --no-legend 2>/dev/null || true
        fi
      '';

      serviceConfig = {
        # Treat exit code 4 as success
        # Exit code 4 from switch-to-configuration means "configuration applied successfully,
        # but some transient units failed." This commonly occurs when Podman healthcheck
        # services (created via systemd-run) fire while containers are still in "starting"
        # state during container restarts. Since the configuration itself was applied
        # correctly, we treat this as success for auto-upgrade purposes.
        SuccessExitStatus = "4";

        # Set OOM score adjustment to prefer killing this service over critical ones
        # Range: -1000 (never kill) to 1000 (kill first), default is 0
        # This ensures that if OOM occurs, nixos-upgrade is killed before critical services
        OOMScoreAdjust = 500;
      } // lib.optionalAttrs (cfg.memoryHigh != null) {
        # Memory high threshold - throttle when exceeded (soft limit)
        # Useful to prevent builds (e.g., n8n peaked at 13.6G) from consuming all RAM
        MemoryHigh = cfg.memoryHigh;
      } // lib.optionalAttrs (cfg.memoryMax != null) {
        # Memory max - absolute limit, OOM-kill if exceeded
        MemoryMax = cfg.memoryMax;
      } // lib.optionalAttrs (cfg.limitNOFILE != null) {
        # Raise file descriptor limit for large closures
        # The default soft limit (1024) can be too low for nix build evaluation
        # on hosts with large dependency graphs, causing "Too many open files"
        LimitNOFILE = cfg.limitNOFILE;
      };

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
