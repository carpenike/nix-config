# Unified Backup Monitoring via Node Exporter Textfile Collector
#
# Integrates with existing Prometheus monitoring infrastructure:
# - All backup metrics flow through textfile collector
# - Enterprise-grade alerting rules
# - Performance and health tracking
# - Integration with existing node-exporter setup

{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.backup;
  monitoringCfg = cfg.monitoring or {};

in {
  options.modules.services.backup.monitoring = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable backup monitoring via Prometheus";
    };

    textfileCollector = lib.mkOption {
      type = lib.types.submodule {
        options = {
          directory = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/node_exporter/textfile_collector";
            description = "Directory for textfile collector metrics";
          };

          retentionDays = lib.mkOption {
            type = lib.types.int;
            default = 7;
            description = "Days to retain old metric files";
          };
        };
      };
      default = {};
      description = "Textfile collector configuration";
    };

    alerting = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable backup alerting rules";
          };

          thresholds = lib.mkOption {
            type = lib.types.submodule {
              options = {
                backupStaleHours = lib.mkOption {
                  type = lib.types.int;
                  default = 25;
                  description = "Hours before backup is considered stale";
                };

                slowBackupMultiplier = lib.mkOption {
                  type = lib.types.float;
                  default = 2.0;
                  description = "Multiplier of 7-day average before backup is considered slow";
                };

                verificationStaleHours = lib.mkOption {
                  type = lib.types.int;
                  default = 168; # 1 week
                  description = "Hours before verification is considered stale";
                };
              };
            };
            default = {};
            description = "Alerting thresholds";
          };
        };
      };
      default = {};
      description = "Alerting configuration";
    };

    dashboards = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Generate Grafana dashboard JSON";
          };

          outputPath = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/backup-docs/dashboards";
            description = "Path to output dashboard files";
          };
        };
      };
      default = {};
      description = "Dashboard generation";
    };
  };

  config = lib.mkIf (cfg.enable && monitoringCfg.enable) {
    # Ensure textfile collector directory exists with proper permissions
    systemd.tmpfiles.rules = [
      "d ${monitoringCfg.textfileCollector.directory} 0755 root root -"
    ];

    # Metric cleanup service
    systemd.services.backup-metrics-cleanup = {
      description = "Cleanup old backup metric files";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "backup-metrics-cleanup" ''
          set -euo pipefail

          METRICS_DIR="${monitoringCfg.textfileCollector.directory}"
          RETENTION_DAYS="${toString monitoringCfg.textfileCollector.retentionDays}"

          # Remove metric files older than retention period
          find "$METRICS_DIR" -name "*.prom" -type f -mtime +$RETENTION_DAYS -delete || true
          find "$METRICS_DIR" -name "*.prom.tmp" -type f -mmin +60 -delete || true

          echo "Cleaned up old metric files older than $RETENTION_DAYS days"
        '';
      };
    };

    # Timer for metrics cleanup
    systemd.timers.backup-metrics-cleanup = {
      description = "Timer for backup metrics cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    # Health check service for monitoring system
    systemd.services.backup-monitoring-health = {
      description = "Backup monitoring health check";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "backup-monitoring-health" ''
          set -euo pipefail

          METRICS_FILE="${monitoringCfg.textfileCollector.directory}/backup_monitoring_health.prom"

          # Check textfile collector directory
          if [[ ! -d "${monitoringCfg.textfileCollector.directory}" ]]; then
            echo "ERROR: Textfile collector directory missing"
            exit 1
          fi

          # Check write permissions
          if ! touch "${monitoringCfg.textfileCollector.directory}/test.tmp" 2>/dev/null; then
            echo "ERROR: Cannot write to textfile collector directory"
            exit 1
          fi
          rm -f "${monitoringCfg.textfileCollector.directory}/test.tmp"

          # Write health metrics
          {
            echo "# HELP backup_monitoring_healthy Backup monitoring system health"
            echo "# TYPE backup_monitoring_healthy gauge"
            echo "backup_monitoring_healthy{hostname=\"${config.networking.hostName}\"} 1"

            echo "# HELP backup_monitoring_last_check Last health check timestamp"
            echo "# TYPE backup_monitoring_last_check gauge"
            echo "backup_monitoring_last_check{hostname=\"${config.networking.hostName}\"} $(date +%s)"
          } > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"
        '';
      };
    };

    # Timer for health checks
    systemd.timers.backup-monitoring-health = {
      description = "Timer for backup monitoring health checks";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/5"; # Every 5 minutes
        Persistent = true;
      };
    };

    # Generate alerting rules if alerting module exists
    modules.alerting.rules = lib.mkIf (monitoringCfg.alerting.enable && (config.modules.alerting.enable or false)) {
      # Unified backup job failure alert
      "unified-backup-failed" = {
        type = "promql";
        alertname = "UnifiedBackupFailed";
        expr = "restic_backup_status == 0";
        for = "5m";
        severity = "critical";
        labels = { service = "backup"; category = "unified"; };
        annotations = {
          summary = "Backup job {{ $labels.backup_job }} failed on {{ $labels.hostname }}";
          description = "Unified backup system job failed. Repository: {{ $labels.repository }}. Check systemd logs.";
          command = "journalctl -u restic-backup-{{ $labels.backup_job }}.service --since '2h'";
        };
      };

      # Backup stale alert
      "unified-backup-stale" = {
        type = "promql";
        alertname = "UnifiedBackupStale";
        expr = "(time() - restic_backup_last_success_timestamp) > ${toString (monitoringCfg.alerting.thresholds.backupStaleHours * 3600)}";
        for = "1h";
        severity = "high";
        labels = { service = "backup"; category = "unified"; };
        annotations = {
          summary = "Backup job {{ $labels.backup_job }} is stale on {{ $labels.hostname }}";
          description = "No successful backup in ${toString monitoringCfg.alerting.thresholds.backupStaleHours}+ hours. Repository: {{ $labels.repository }}";
          command = "journalctl -u restic-backup-{{ $labels.backup_job }}.service --since '24h'";
        };
      };

      # Slow backup alert
      "unified-backup-slow" = {
        type = "promql";
        alertname = "UnifiedBackupSlow";
        expr = "restic_backup_duration_seconds > (avg_over_time(restic_backup_duration_seconds[7d]) * ${toString monitoringCfg.alerting.thresholds.slowBackupMultiplier})";
        for = "30m";
        severity = "medium";
        labels = { service = "backup"; category = "unified"; };
        annotations = {
          summary = "Backup job {{ $labels.backup_job }} is running slowly on {{ $labels.hostname }}";
          description = "Duration {{ $value | humanizeDuration }} is ${toString monitoringCfg.alerting.thresholds.slowBackupMultiplier}x the 7-day average.";
          command = "journalctl -u restic-backup-{{ $labels.backup_job }}.service --since '2h'";
        };
      };

      # PostgreSQL backup verification alert
      "postgres-backup-verification-failed" = {
        type = "promql";
        alertname = "PostgresBackupVerificationFailed";
        expr = "postgres_backup_verification_status == 0";
        for = "5m";
        severity = "high";
        labels = { service = "backup"; category = "postgres"; };
        annotations = {
          summary = "PostgreSQL backup verification failed on {{ $labels.hostname }}";
          description = "Database backup integrity check failed. Investigate immediately.";
          command = "journalctl -u postgres-backup-verification.service --since '2h'";
        };
      };

      # PostgreSQL verification stale
      "postgres-backup-verification-stale" = {
        type = "promql";
        alertname = "PostgresBackupVerificationStale";
        expr = "(time() - postgres_backup_verification_last_success) > ${toString (monitoringCfg.alerting.thresholds.verificationStaleHours * 3600)}";
        for = "1h";
        severity = "medium";
        labels = { service = "backup"; category = "postgres"; };
        annotations = {
          summary = "PostgreSQL backup verification is stale on {{ $labels.hostname }}";
          description = "No successful verification in ${toString monitoringCfg.alerting.thresholds.verificationStaleHours}+ hours.";
          command = "systemctl status postgres-backup-verification.timer";
        };
      };

      # Monitoring system health
      "backup-monitoring-unhealthy" = {
        type = "promql";
        alertname = "BackupMonitoringUnhealthy";
        expr = "(backup_monitoring_healthy == 0) or (absent(backup_monitoring_healthy) == 1)";
        for = "15m";
        severity = "high";
        labels = { service = "backup"; category = "monitoring"; };
        annotations = {
          summary = "Backup monitoring system unhealthy on {{ $labels.hostname }}";
          description = "Backup monitoring system is not reporting healthy status. Check textfile collector.";
          command = "systemctl status backup-monitoring-health.service";
        };
      };
    };

    # Generate Grafana dashboard if enabled
    systemd.services.backup-dashboard-generator = lib.mkIf monitoringCfg.dashboards.enable {
      description = "Generate backup monitoring dashboard";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "generate-backup-dashboard" ''
          set -euo pipefail

          DASHBOARD_DIR="${monitoringCfg.dashboards.outputPath}"
          mkdir -p "$DASHBOARD_DIR"

          cat > "$DASHBOARD_DIR/unified-backup-dashboard.json" << 'EOF'
          {
            "dashboard": {
              "title": "Unified Backup System",
              "tags": ["backup", "restic", "postgresql"],
              "panels": [
                {
                  "title": "Backup Status Overview",
                  "type": "stat",
                  "targets": [
                    {
                      "expr": "restic_backup_status",
                      "legendFormat": "{{ backup_job }}"
                    }
                  ]
                },
                {
                  "title": "Backup Duration",
                  "type": "graph",
                  "targets": [
                    {
                      "expr": "restic_backup_duration_seconds",
                      "legendFormat": "{{ backup_job }}"
                    }
                  ]
                },
                {
                  "title": "PostgreSQL Backup Health",
                  "type": "stat",
                  "targets": [
                    {
                      "expr": "postgres_backup_verification_status",
                      "legendFormat": "Verification Status"
                    }
                  ]
                }
              ]
            }
          }
          EOF

          echo "Generated backup dashboard at $DASHBOARD_DIR/unified-backup-dashboard.json"
        '';
      };
    };

    # Generate documentation
    systemd.services.backup-monitoring-docs = {
      description = "Generate backup monitoring documentation";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "generate-backup-monitoring-docs" ''
          set -euo pipefail

          DOCS_DIR="/var/lib/backup-docs"
          mkdir -p "$DOCS_DIR"

          cat > "$DOCS_DIR/monitoring-guide.md" << 'EOF'
          # Unified Backup Monitoring Guide

          ## Metrics Overview

          ### Restic Backup Metrics
          - `restic_backup_status`: Job status (1=success, 0=failure)
          - `restic_backup_duration_seconds`: Backup duration
          - `restic_backup_last_success_timestamp`: Last successful backup

          ### PostgreSQL Metrics
          - `postgres_backup_verification_status`: Verification status
          - `postgres_pgbackrest_offsite_backup_status`: Offsite backup status

          ### Monitoring Health
          - `backup_monitoring_healthy`: Monitoring system health
          - `backup_monitoring_last_check`: Last health check

          ## Alerting Rules

          - **UnifiedBackupFailed**: Backup job failure (critical)
          - **UnifiedBackupStale**: Backup older than ${toString monitoringCfg.alerting.thresholds.backupStaleHours}h (high)
          - **UnifiedBackupSlow**: Backup taking ${toString monitoringCfg.alerting.thresholds.slowBackupMultiplier}x normal time (medium)
          - **PostgresBackupVerificationFailed**: DB verification failed (high)

          ## Troubleshooting

          1. Check systemd services: `systemctl status restic-backup-*`
          2. View logs: `journalctl -u restic-backup-SERVICE.service`
          3. Check metrics: `cat ${monitoringCfg.textfileCollector.directory}/*.prom`
          4. Verify repositories: `restic snapshots`
          EOF

          echo "Generated monitoring documentation at $DOCS_DIR/monitoring-guide.md"
        '';
      };
    };
  };
}
