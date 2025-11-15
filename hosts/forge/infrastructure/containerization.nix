{ ... }:

{
  # Podman containerization configuration for forge
  # Defines container networking and generic container health monitoring

  modules.virtualization.podman = {
    enable = true;
    networks = {
      "media-services" = {
        driver = "bridge";
        # DNS resolution is enabled by default for bridge networks
        # Containers on this network can reach each other by container name
      };
    };
  };

  # Generic container health alerts
  # Service-specific alerts (e.g., "sonarr queue blocked") are in service files
  modules.alerting.rules = {
    # Container health check failures
    "container-health-check-failed" = {
      type = "promql";
      alertname = "ContainerHealthCheckFailed";
      expr = ''
        container_health_status{health!="healthy"} == 1
      '';
      for = "5m";
      severity = "medium";
      labels = { service = "container"; category = "health"; };
      annotations = {
        summary = "Container {{ $labels.name }} health check failed on {{ $labels.instance }}";
        description = "Container health status is {{ $labels.health }}. Check container logs: podman logs {{ $labels.name }}";
        command = "podman logs {{ $labels.name }} --since 30m";
      };
    };

    # High container memory usage
    "container-memory-high" = {
      type = "promql";
      alertname = "ContainerMemoryHigh";
      expr = ''
        container_memory_percent > 85
      '';
      for = "10m";
      severity = "medium";
      labels = { service = "container"; category = "performance"; };
      annotations = {
        summary = "Container {{ $labels.name }} memory usage is high on {{ $labels.instance }}";
        description = "Memory usage is {{ $value }}%. Monitor for potential OOM issues.";
        command = "podman stats {{ $labels.name }} --no-stream";
      };
    };
  };
}
