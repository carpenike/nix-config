{ lib }:

# Monitoring Library: Reusable Alert Template Functions
#
# This library provides consistent, reusable alert rule generators for Prometheus.
# It is exposed as mylib.monitoring-helpers (wired in lib/default.nix). Services
# use these functions to contribute rules to modules.alerting.rules, ensuring
# consistency in naming, severity, and formatting across all alerts.
#
# NOTE: Do not confuse mylib.monitoring-helpers with the forgeDefaults helpers in
# lib/host-defaults.nix (e.g. forgeDefaults.mkServiceDownAlert /
# mkSystemdServiceDownAlert) — those are separate, host-oriented generators.
#
# Usage in service/host files:
#   {
#     modules.alerting.rules."my-service-unhealthy" =
#       mylib.monitoring-helpers.mkThresholdAlert {
#         name = "my-service";
#         alertname = "MyServiceUnhealthy";
#         expr = ''my_service_healthy == 0'';
#         summary = "...";
#         description = "...";
#       };
#   }
#
# Helpers based on per-service `up{job=...}` / process_* metrics
# (mkServiceDownAlert, mkHighMemoryAlert, mkHighCpuAlert, mkHighResponseTimeAlert)
# were removed: they were unused, and most services here are not scraped as
# individual Prometheus jobs exposing process_* / http_request_* metrics.

{
  # Generic threshold alert with custom expression
  mkThresholdAlert =
    { name
    , alertname
    , expr
    , for ? "5m"
    , severity ? "medium"
    , service ? name
    , category ? "custom"
    , summary
    , description
    ,
    }: {
      type = "promql";
      inherit alertname expr for severity;
      labels = {
        inherit service category;
      };
      annotations = {
        inherit summary description;
      };
    };

  # Database-specific alerts
  mkDatabaseConnectionsAlert =
    { name ? "database"
    , expr
    , for ? "5m"
    , severity ? "high"
    , category ? "capacity"
    ,
    }: {
      type = "promql";
      alertname = "${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["_" "_"] name)}TooManyConnections";
      inherit expr for severity;
      labels = {
        service = name;
        inherit category;
      };
      annotations = {
        summary = "${name} connection usage high on {{ $labels.instance }}";
        description = "${name} is using {{ $value }}% of max connections. Consider increasing max_connections or investigating connection leaks.";
      };
    };

  # Storage/capacity alerts
  mkHighCapacityAlert =
    { name
    , expr
    , for ? "15m"
    , severity ? "high"
    , category ? "capacity"
    , summary
    , description
    ,
    }: {
      type = "promql";
      alertname = "${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["_" "_"] name)}CapacityHigh";
      inherit expr for severity;
      labels = {
        service = name;
        inherit category;
      };
      annotations = {
        inherit summary description;
      };
    };

  # Container-specific alerts
  mkContainerDownAlert =
    { container
    , for ? "2m"
    , severity ? "medium"
    , category ? "availability"
    ,
    }: {
      type = "promql";
      alertname = "Container${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["" ""] container)}Down";
      expr = ''container_up{name="${container}"} == 0'';
      inherit for severity;
      labels = {
        service = "containers";
        inherit category;
      };
      annotations = {
        summary = "Container ${container} is down";
        description = "Container ${container} is not running. Check with: podman ps -a | grep ${container}";
      };
    };
}
