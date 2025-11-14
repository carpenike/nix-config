{ lib }:

# Monitoring Library: Reusable Alert Template Functions
#
# This library provides consistent, reusable alert rule generators for Prometheus.
# Services import this library and use these functions to contribute their monitoring
# rules to modules.alerting.rules, ensuring consistency in naming, severity, and
# formatting across all alerts.
#
# Usage in service files:
#   let
#     monitoringLib = import ../infrastructure/monitoring-lib.nix { inherit lib; };
#   in
#   {
#     config = lib.mkIf config.modules.alerting.enable {
#       modules.alerting.rules.my-service = [
#         (monitoringLib.mkServiceDownAlert { job = "my-service"; severity = "critical"; })
#       ];
#     };
#   }

{
  # Standard "service down" alert
  # Checks if the 'up' metric for a given job is 0
  mkServiceDownAlert = {
    job,
    name ? job,
    for ? "2m",
    severity ? "critical",
    category ? "availability",
    description ? "Service ${name} is not responding. Check service status.",
  }: {
    type = "promql";
    alertname = "${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["_" "_"] name)}Down";
    expr = ''up{job="${job}"} == 0'';
    inherit for severity;
    labels = {
      service = name;
      inherit category;
    };
    annotations = {
      summary = "${name} is down on {{ $labels.instance }}";
      inherit description;
    };
  };

  # High memory usage alert
  mkHighMemoryAlert = {
    job,
    name ? job,
    threshold ? 80,
    for ? "5m",
    severity ? "high",
    category ? "capacity",
  }: {
    type = "promql";
    alertname = "${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["_" "_"] name)}HighMemory";
    expr = ''process_resident_memory_bytes{job="${job}"} / process_virtual_memory_max_bytes{job="${job}"} * 100 > ${toString threshold}'';
    inherit for severity;
    labels = {
      service = name;
      inherit category;
    };
    annotations = {
      summary = "${name} high memory usage on {{ $labels.instance }}";
      description = "${name} is using {{ $value }}% of available memory.";
    };
  };

  # High CPU usage alert
  mkHighCpuAlert = {
    job,
    name ? job,
    threshold ? 80,
    for ? "10m",
    severity ? "medium",
    category ? "performance",
  }: {
    type = "promql";
    alertname = "${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["_" "_"] name)}HighCpu";
    expr = ''rate(process_cpu_seconds_total{job="${job}"}[1m]) * 100 > ${toString threshold}'';
    inherit for severity;
    labels = {
      service = name;
      inherit category;
    };
    annotations = {
      summary = "${name} high CPU usage on {{ $labels.instance }}";
      description = "${name} is using {{ $value }}% CPU for ${for}.";
    };
  };

  # HTTP service high response time alert
  mkHighResponseTimeAlert = {
    job,
    name ? job,
    threshold ? 1.0,  # seconds
    for ? "5m",
    severity ? "medium",
    category ? "performance",
  }: {
    type = "promql";
    alertname = "${lib.strings.toUpper (builtins.replaceStrings ["-" "."] ["_" "_"] name)}HighResponseTime";
    expr = ''histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{job="${job}"}[5m])) > ${toString threshold}'';
    inherit for severity;
    labels = {
      service = name;
      inherit category;
    };
    annotations = {
      summary = "${name} high response time on {{ $labels.instance }}";
      description = "${name} 95th percentile response time is {{ $value }}s (threshold: ${toString threshold}s).";
    };
  };

  # Generic threshold alert with custom expression
  mkThresholdAlert = {
    name,
    alertname,
    expr,
    threshold,
    for ? "5m",
    severity ? "medium",
    service ? name,
    category ? "custom",
    summary,
    description,
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
  mkDatabaseConnectionsAlert = {
    name ? "database",
    expr,
    threshold ? 80,
    for ? "5m",
    severity ? "high",
    category ? "capacity",
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
  mkHighCapacityAlert = {
    name,
    expr,
    threshold ? 85,
    for ? "15m",
    severity ? "high",
    category ? "capacity",
    summary,
    description,
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
  mkContainerDownAlert = {
    container,
    for ? "2m",
    severity ? "medium",
    category ? "availability",
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
