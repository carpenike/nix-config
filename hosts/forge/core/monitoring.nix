{ lib, pkgs, ... }:

let
  bootStatusState = "/var/lib/boot-status/state";
  bootStatusMetrics = "/var/lib/node_exporter/textfile_collector/boot-status.prom";

  exportBootStatus = pkgs.writeShellScript "export-boot-status" ''
    set -euo pipefail

    state_file=${lib.escapeShellArg bootStatusState}
    metrics_file=${lib.escapeShellArg bootStatusMetrics}
    current_boot_id="$(cat /proc/sys/kernel/random/boot_id)"
    boot_timestamp="$(awk '$1 == "btime" { print $2 }' /proc/stat)"
    previous_clean=1
    previous_state=unknown
    previous_boot_id=""
    saved_result=1

    mkdir -p "$(dirname "$state_file")" "$(dirname "$metrics_file")"

    if [[ -r "$state_file" ]]; then
      read -r previous_state previous_boot_id saved_result < "$state_file" || true
      if [[ "$previous_boot_id" == "$current_boot_id" ]]; then
        previous_clean="''${saved_result:-1}"
      elif [[ "$previous_state" == "running" ]]; then
        previous_clean=0
      fi
    else
      # First activation has no marker yet. Journald still tells us whether
      # this boot followed an abrupt reset, including the 2026-08-24 freeze.
      journal_unclean="$(journalctl -b 0 -u systemd-journald.service --no-pager \
        --output=cat --grep="corrupted or uncleanly shut down" || true)"
      if [[ -n "$journal_unclean" ]]; then
        previous_clean=0
      fi
    fi

    state_tmp="''${state_file}.tmp"
    printf 'running %s %s\n' "$current_boot_id" "$previous_clean" > "$state_tmp"
    mv "$state_tmp" "$state_file"

    metrics_tmp="''${metrics_file}.tmp"
    {
      echo '# HELP host_previous_shutdown_clean Whether the previous shutdown completed cleanly (1=yes, 0=no).'
      echo '# TYPE host_previous_shutdown_clean gauge'
      printf 'host_previous_shutdown_clean %s\n' "$previous_clean"
      echo '# HELP host_unclean_boot_timestamp_seconds Boot time following an unclean shutdown, or zero.'
      echo '# TYPE host_unclean_boot_timestamp_seconds gauge'
      if [[ "$previous_clean" == 0 ]]; then
        printf 'host_unclean_boot_timestamp_seconds %s\n' "$boot_timestamp"
      else
        echo 'host_unclean_boot_timestamp_seconds 0'
      fi
    } > "$metrics_tmp"
    mv "$metrics_tmp" "$metrics_file"
  '';

  markBootClean = pkgs.writeShellScript "mark-boot-clean" ''
    set -euo pipefail

    state_file=${lib.escapeShellArg bootStatusState}
    current_boot_id="$(cat /proc/sys/kernel/random/boot_id)"
    saved_result=1
    marker_boot_id=""
    marker_result=1

    mkdir -p "$(dirname "$state_file")"
    if [[ -r "$state_file" ]]; then
      read -r _ marker_boot_id marker_result < "$state_file" || true
      if [[ "$marker_boot_id" == "$current_boot_id" ]]; then
        saved_result="''${marker_result:-1}"
      fi
    fi

    state_tmp="''${state_file}.tmp"
    printf 'clean %s %s\n' "$current_boot_id" "$saved_result" > "$state_tmp"
    mv "$state_tmp" "$state_file"
  '';
in
{
  # Core system health monitoring for forge
  # These alerts monitor fundamental OS-level metrics: CPU, memory, disk, systemd units
  # Infrastructure service alerts (Prometheus, Caddy, etc.) are co-located with their service definitions

  modules.alerting.rules = {
    # Node exporter down - cannot collect system metrics
    "node-exporter-down" = {
      type = "promql";
      alertname = "NodeExporterDown";
      expr = "up{job=\"node\"} == 0";
      for = "2m";
      severity = "critical";
      labels = { service = "system"; category = "monitoring"; };
      annotations = {
        summary = "Node exporter is down on {{ $labels.instance }}";
        description = "Cannot collect system metrics. Check prometheus-node-exporter.service status.";
      };
    };

    # Dead Man's Switch / Watchdog
    # This alert always fires to test the entire monitoring pipeline
    # It's routed to an external service (healthchecks.io) to detect total system failure
    "watchdog" = {
      type = "promql";
      alertname = "Watchdog";
      expr = "vector(1)";
      # No 'for' needed - should always be firing
      severity = "critical";
      labels = { service = "monitoring"; category = "meta"; };
      annotations = {
        summary = "Watchdog alert for monitoring pipeline";
        description = "This alert is always firing to test the entire monitoring pipeline. It should be routed to an external dead man's switch service.";
      };
    };

    # Distinguish a hard reset/watchdog recovery from a planned reboot. The
    # metric is emitted after boot from the persistent marker below and only
    # pages during the first hour, so it records the incident without becoming
    # a permanent alert for the lifetime of the new boot.
    "unclean-host-reboot" = {
      type = "promql";
      alertname = "UncleanHostReboot";
      expr = ''
        host_previous_shutdown_clean{host="forge"} == 0
        and on(instance)
        (time() - node_boot_time_seconds{host="forge"} < 3600)
      '';
      for = "1m";
      severity = "critical";
      labels = { service = "system"; category = "availability"; };
      annotations = {
        summary = "Forge recovered from an unclean shutdown";
        description = "Forge rebooted without completing its shutdown path. Inspect the previous boot journal and /var/lib/systemd/pstore for a panic, watchdog reset, power loss, or hard lock.";
      };
    };

    # Disk space critical
    "filesystem-space-critical" = {
      type = "promql";
      alertname = "FilesystemSpaceCritical";
      expr = ''
        (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes) < 0.10
      '';
      for = "5m";
      severity = "critical";
      labels = { service = "system"; category = "storage"; };
      annotations = {
        summary = "Filesystem {{ $labels.mountpoint }} is critically low on space on {{ $labels.instance }}";
        description = "Only {{ $value | humanizePercentage }} available. Immediate cleanup required.";
      };
    };

    # Disk space warning
    "filesystem-space-low" = {
      type = "promql";
      alertname = "FilesystemSpaceLow";
      expr = ''
        (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes) < 0.20
      '';
      for = "15m";
      severity = "high";
      labels = { service = "system"; category = "storage"; };
      annotations = {
        summary = "Filesystem {{ $labels.mountpoint }} is low on space on {{ $labels.instance }}";
        description = "Only {{ $value | humanizePercentage }} available. Plan cleanup or expansion.";
      };
    };

    # High CPU load
    "high-cpu-load" = {
      type = "promql";
      alertname = "HighCPULoad";
      expr = "node_load15 > (count(node_cpu_seconds_total{mode=\"idle\"}) * 0.8)";
      for = "15m";
      severity = "medium";
      labels = { service = "system"; category = "performance"; };
      annotations = {
        summary = "High CPU load on {{ $labels.instance }}";
        description = "15-minute load average is {{ $value }}. Investigate resource-intensive processes.";
      };
    };

    # CPU temperature warning - catches sustained thermal pressure before throttling
    "cpu-temperature-high" = {
      type = "promql";
      alertname = "CpuTemperatureHigh";
      expr = ''
        max by (instance, host) (node_hwmon_temp_celsius{chip="platform_coretemp_0"}) > 90
      '';
      for = "2m";
      severity = "high";
      labels = { service = "system"; category = "hardware"; };
      annotations = {
        summary = "CPU temperature high on {{ $labels.instance }}";
        description = "Hottest CPU sensor is {{ $value }} C. Investigate CPU load and cooling.";
      };
    };

    # CPU temperature critical - immediate warning at the processor's thermal limit
    "cpu-temperature-critical" = {
      type = "promql";
      alertname = "CpuTemperatureCritical";
      expr = ''
        max by (instance, host) (node_hwmon_temp_celsius{chip="platform_coretemp_0"}) >= 100
      '';
      for = "0m";
      severity = "critical";
      labels = { service = "system"; category = "hardware"; };
      annotations = {
        summary = "CPU temperature critical on {{ $labels.instance }}";
        description = "Hottest CPU sensor is {{ $value }} C. Reduce load or shut down immediately and inspect cooling.";
      };
    };

    # Aquaero channels 1 and 2 are the active cooling-loop fan channels.
    "aquaero-cooling-channel-low" = {
      type = "promql";
      alertname = "AquaeroCoolingChannelLow";
      expr = ''
        node_hwmon_fan_rpm{chip=~".*0c70:f001.*",sensor=~"fan1|fan2"} < 200
      '';
      for = "2m";
      severity = "critical";
      labels = { service = "system"; category = "hardware"; };
      annotations = {
        summary = "Aquaero cooling channel {{ $labels.sensor }} stopped on {{ $labels.instance }}";
        description = "Aquaero {{ $labels.sensor }} is reporting {{ $value }} RPM. Inspect fan/pump power and the liquid-cooling loop immediately.";
      };
    };

    "aquaero-cooling-telemetry-missing" = {
      type = "promql";
      alertname = "AquaeroCoolingTelemetryMissing";
      expr = ''
        absent(node_hwmon_fan_rpm{chip=~".*0c70:f001.*",sensor="fan1"})
        or
        absent(node_hwmon_fan_rpm{chip=~".*0c70:f001.*",sensor="fan2"})
      '';
      for = "5m";
      severity = "high";
      labels = { service = "system"; category = "monitoring"; };
      annotations = {
        summary = "Aquaero cooling telemetry missing on forge";
        description = "One or both active Aquaero cooling channels are absent from node-exporter. Check the Aquaero USB connection and hwmon driver.";
      };
    };

    # High memory usage. Add reclaimable ZFS ARC when exported, while the zero
    # fallback preserves standard MemAvailable accounting on non-ZFS hosts.
    # NAS instances use the separate NASHighMemory alert in nas-monitoring.nix.
    "high-memory-usage" = {
      type = "promql";
      alertname = "HighMemoryUsage";
      expr = ''
        (1 - (
          (
            node_memory_MemAvailable_bytes{instance!~"nas-.*"}
            + on(instance) (
              node_zfs_arc_size{instance!~"nas-.*"}
              or on(instance) (0 * node_memory_MemAvailable_bytes{instance!~"nas-.*"})
            )
          )
          / on(instance) node_memory_MemTotal_bytes{instance!~"nas-.*"}
        )) > 0.90
      '';
      for = "10m";
      severity = "high";
      labels = { service = "system"; category = "performance"; };
      annotations = {
        summary = "High memory usage on {{ $labels.instance }}";
        description = "Effective memory usage is {{ $value | humanizePercentage }} after excluding reclaimable ZFS ARC where available. Risk of OOM kills.";
      };
    };

    # SystemD unit failed
    "systemd-unit-failed" = {
      type = "promql";
      alertname = "SystemdUnitFailed";
      expr = ''
        node_systemd_unit_state{state="failed"} == 1
      '';
      for = "5m";
      severity = "high";
      labels = { service = "system"; category = "systemd"; };
      annotations = {
        summary = "SystemD unit {{ $labels.name }} failed on {{ $labels.instance }}";
        description = "Service is in failed state. Check: systemctl status {{ $labels.name }}";
      };
    };

    # Critical memory pressure - host is nearly out of memory
    # Fires at 95% (vs HighMemoryUsage at 90%) for immediate attention
    "memory-pressure-critical" = {
      type = "promql";
      alertname = "MemoryPressureCritical";
      expr = ''
        (1 - (node_memory_MemAvailable_bytes{instance!~"nas-.*"} / node_memory_MemTotal_bytes{instance!~"nas-.*"})) > 0.95
      '';
      for = "5m";
      severity = "critical";
      labels = { service = "system"; category = "performance"; };
      annotations = {
        summary = "Critical memory pressure on {{ $labels.instance }}";
        description = "Memory usage is {{ $value | humanizePercentage }}. OOM kills imminent. Investigate immediately.";
        command = "ps aux --sort=-%mem | head -20";
      };
    };

    # NFS mount errors - detect stale or errored NFS mounts
    # Critical for backup reliability (restic, pgBackRest depend on NFS)
    "nfs-mount-error" = {
      type = "promql";
      alertname = "NFSMountError";
      expr = ''
        node_filesystem_device_error{fstype="nfs4"} > 0
      '';
      for = "5m";
      severity = "high";
      labels = { service = "system"; category = "storage"; };
      annotations = {
        summary = "NFS mount error on {{ $labels.mountpoint }} on {{ $labels.instance }}";
        description = "NFS filesystem at {{ $labels.mountpoint }} has device errors. Backups may be failing silently. Check: mount | grep nfs";
      };
    };

    # NFS mount disappeared - filesystem was expected but is gone
    "nfs-mount-missing" = {
      type = "promql";
      alertname = "NFSMountMissing";
      expr = ''
        absent(node_filesystem_avail_bytes{mountpoint="/mnt/nas-backup"}) == 1
        and on() (node_time_seconds - node_boot_time_seconds) > 600
      '';
      for = "15m";
      severity = "high";
      labels = { service = "system"; category = "storage"; };
      annotations = {
        summary = "NFS backup mount missing on {{ $labels.instance }}";
        description = "The /mnt/nas-backup mount is not present. Restic backups will fail. Check NAS connectivity and automount.";
      };
    };

    # Systemd timer not firing - detect timers that stopped triggering
    # Uses node_systemd_timer_last_trigger_seconds from node_exporter
    # Excludes transient/ephemeral timers (podman healthchecks have hash names)
    "systemd-timer-stale" = {
      type = "promql";
      alertname = "SystemdTimerStale";
      expr = ''
        (time() - node_systemd_timer_last_trigger_seconds{name!~".*[0-9a-f]{64}.*"}) > 86400 * 2
        and node_systemd_unit_state{name=~".*\\.timer", state="active"} == 1
      '';
      for = "30m";
      severity = "medium";
      labels = { service = "system"; category = "systemd"; };
      annotations = {
        summary = "Systemd timer {{ $labels.name }} hasn't fired in 2+ days on {{ $labels.instance }}";
        description = "Timer {{ $labels.name }} last triggered {{ $value | humanizeDuration }} ago. Check: systemctl list-timers {{ $labels.name }}";
      };
    };
  };

  # Keep one boot ID in the persistent system dataset. ExecStop marks an
  # orderly shutdown; a hard lock leaves the marker as "running", which the
  # next boot exports through node-exporter's textfile collector.
  modules.system.impermanence.directories = [{
    directory = "/var/lib/boot-status";
    user = "root";
    group = "root";
    mode = "0755";
  }];

  systemd.services.boot-status-metrics = {
    description = "Export previous shutdown status";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-journald.service" "prometheus-node-exporter.service" ];
    wants = [ "prometheus-node-exporter.service" ];
    path = [ pkgs.coreutils pkgs.gawk pkgs.systemd ];
    unitConfig.RequiresMountsFor = [ "/var/lib/boot-status" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = exportBootStatus;
      ExecStop = markBootClean;
    };
  };
}
