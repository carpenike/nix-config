{
  pkgs,
  lib,
  config,
  hostname,
  ...
}:
let
  ifGroupsExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  imports = [
    (import ./disko-config.nix {
      disks = [ "/dev/disk/by-id/nvme-Samsung_SSD_950_PRO_512GB_S2GMNX0H803986M" "/dev/disk/by-id/nvme-WDS100T3X0C-00SJG0_200278801343" ];
      inherit lib;  # Pass lib here
    })
    ./secrets.nix
    ./systemPackages.nix
    ./backup.nix
    ./monitoring.nix
    ./monitoring-ui.nix  # Web UI exposure for Prometheus/Alertmanager
    ./alerting.nix
    ./postgresql.nix
    ./dispatcharr.nix
    ./plex.nix
    ./uptime-kuma.nix    # Uptime monitoring and status page
    ./ups.nix            # UPS monitoring configuration
    ./pgweb.nix          # PostgreSQL web management interface
    ./authelia.nix       # SSO authentication service
    ../../profiles/hardware/intel-gpu.nix
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.30";

    networking = {
      hostName = hostname;
      hostId = "1b3031e7";  # Preserved from nixos-bootstrap
      useDHCP = true;
      # Firewall disabled; per-service modules will declare their own rules
      firewall.enable = false;
      domain = "holthome.net";

      # REMOVED 2025-11-01: These /etc/hosts entries are no longer needed.
      # The TLS certificate exporter was rewritten to read cert files directly from disk
      # instead of making network connections via openssl s_client. All intra-host
      # monitoring connections properly use 127.0.0.1 or localhost directly in their
      # scrape configs. Keeping these entries created confusing split-horizon DNS behavior.
      #
      # Commented out for observation period - will be fully removed if no issues arise.
      #
      # extraHosts = ''
      #   127.0.0.1 alertmanager.forge.holthome.net
      #   127.0.0.1 prometheus.forge.holthome.net
      #   127.0.0.1 loki.holthome.net
      #   127.0.0.1 grafana.holthome.net
      #   127.0.0.1 iptv.holthome.net
      #   127.0.0.1 plex.holthome.net
      # '';
    };

    # Boot loader configuration
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # User configuration
    users.users.ryan = {
      uid = 1000;
      name = "ryan";
      home = "/home/ryan";
      group = "ryan";
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = lib.strings.splitString "\n" (builtins.readFile ../../home/ryan/config/ssh/ssh.pub);
      isNormalUser = true;
      extraGroups =
        [
          "wheel"
          "users"
          "podman"  # Rootless podman container management
        ]
        ++ ifGroupsExist [
          "network"
        ];
    };
    users.groups.ryan = {
      gid = 1000;
    };

    # Add postgres user to restic-backup group for R2 secret access
    # and node-exporter group for metrics file write access
    # Required for pgBackRest to read AWS credentials and write Prometheus metrics
    users.users.postgres.extraGroups = [ "restic-backup" "node-exporter" ];

    system.activationScripts.postActivation.text = ''
      # Must match what is in /etc/shells
      chsh -s /run/current-system/sw/bin/fish ryan
    '';

    # Expose VA-API drivers for host-side tools (vainfo, ffmpeg)
    # hardware.opengl was renamed; migrate to hardware.graphics
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [ intel-media-driver libva libva-utils ];
    };

    modules = {
      # Explicitly enable ZFS filesystem module
      filesystems.zfs = {
        enable = true;
        mountPoolsAtBoot = [ "rpool" "tank" ];
        # Use default rpool/safe/persist for system-level /persist
      };

      # Enable Intel DRI / VA-API support on this host
      common.intelDri = {
        enable = true;
        driver = "iHD"; # Use iHD (intel-media-driver) for modern Intel GPUs; set to "i965" for legacy hardware
        services = [ "podman-dispatcharr.service" ];
      };

      # (moved) VA-API driver exposure configured via top-level 'hardware.opengl'

      # Co-located monitoring alerts for forge
      alerting = {
        # Enable dead man's switch via Healthchecks.io
        receivers.healthchecks.urlSecret = "monitoring/healthchecks-url";

        # Using lib.mkMerge to combine multiple alert rule sets
        rules = lib.mkMerge [
        # ZFS monitoring alerts (conditional on ZFS being enabled)
        (lib.mkIf config.modules.filesystems.zfs.enable {
        # ZFS pool health degraded
        "zfs-pool-degraded" = {
          type = "promql";
          alertname = "ZFSPoolDegraded";
          expr = "node_zfs_zpool_state{state!=\"online\",zpool!=\"\"} > 0";
          for = "5m";
          severity = "critical";
          labels = { service = "zfs"; category = "storage"; };
          annotations = {
            summary = "ZFS pool {{ $labels.zpool }} is degraded on {{ $labels.instance }}";
            description = "Pool state: {{ $labels.state }}. Check 'zpool status {{ $labels.zpool }}' for details.";
            command = "zpool status {{ $labels.zpool }}";
          };
        };

        # ZFS snapshot age violations
        "zfs-snapshot-stale" = {
          type = "promql";
          alertname = "ZFSSnapshotStale";
          expr = "(time() - zfs_snapshot_latest_timestamp{dataset!=\"\"}) > 3600";
          for = "30m";
          severity = "high";
          labels = { service = "zfs"; category = "backup"; };
          annotations = {
            summary = "ZFS snapshots are stale for {{ $labels.dataset }} on {{ $labels.instance }}";
            description = "Last snapshot was {{ $value | humanizeDuration }} ago. Check sanoid service.";
            command = "systemctl status sanoid.service && journalctl -u sanoid.service --since '2 hours ago'";
          };
        };

        # ZFS snapshot count too low
        "zfs-snapshot-count-low" = {
          type = "promql";
          alertname = "ZFSSnapshotCountLow";
          expr = "zfs_snapshot_count{dataset!=\"\"} < 2";
          for = "1h";
          severity = "high";
          labels = { service = "zfs"; category = "backup"; };
          annotations = {
            summary = "ZFS snapshot count is low for {{ $labels.dataset }} on {{ $labels.instance }}";
            description = "Only {{ $value }} snapshots exist. Sanoid autosnap may be failing.";
            command = "zfs list -t snapshot | grep {{ $labels.dataset }}";
          };
        };

        # ZFS pool space usage high
        "zfs-pool-space-high" = {
          type = "promql";
          alertname = "ZFSPoolSpaceHigh";
          expr = "(node_zfs_zpool_used_bytes{zpool!=\"\"} / node_zfs_zpool_size_bytes) > 0.80";
          for = "15m";
          severity = "high";
          labels = { service = "zfs"; category = "storage"; };
          annotations = {
            summary = "ZFS pool {{ $labels.zpool }} is {{ $value | humanizePercentage }} full on {{ $labels.instance }}";
            description = "Pool usage exceeds 80%. Consider expanding pool or cleaning up data.";
            command = "zpool list {{ $labels.zpool }} && zfs list -o space";
          };
        };

        # ZFS pool space critical
        "zfs-pool-space-critical" = {
          type = "promql";
          alertname = "ZFSPoolSpaceCritical";
          expr = "(node_zfs_zpool_used_bytes{zpool!=\"\"} / node_zfs_zpool_size_bytes) > 0.90";
          for = "5m";
          severity = "critical";
          labels = { service = "zfs"; category = "storage"; };
          annotations = {
            summary = "ZFS pool {{ $labels.zpool }} is {{ $value | humanizePercentage }} full on {{ $labels.instance }}";
            description = "CRITICAL: Pool usage exceeds 90%. Immediate action required to prevent write failures.";
            command = "zpool list {{ $labels.zpool }} && df -h";
          };
        };

        # ZFS preseed restore failed
        "zfs-preseed-failed" = {
          type = "promql";
          alertname = "ZFSPreseedFailed";
          expr = "zfs_preseed_status == 0 and changes(zfs_preseed_last_completion_timestamp_seconds[15m]) > 0";
          for = "0m";
          severity = "critical";
          labels = { service = "zfs-preseed"; category = "disaster-recovery"; };
          annotations = {
            summary = "ZFS pre-seed restore failed for {{ $labels.service }}";
            description = "The automated restore for service '{{ $labels.service }}' using method '{{ $labels.method }}' has failed. The service will start with an empty data directory. Manual intervention is required. Check logs with: journalctl -u preseed-{{ $labels.service }}.service";
          };
        };

        # ZFS preseed aborted due to unhealthy pool
        "zfs-preseed-pool-unhealthy" = {
          type = "promql";
          alertname = "ZFSPreseedPoolUnhealthy";
          expr = ''
            zfs_preseed_status{method="pool_unhealthy"} == 0
            and
            changes(zfs_preseed_last_completion_timestamp_seconds{method="pool_unhealthy"}[15m]) > 0
          '';
          for = "0m";
          severity = "critical";
          labels = { service = "zfs-preseed"; category = "storage"; };
          annotations = {
            summary = "ZFS pre-seed for {{ $labels.service }} aborted due to unhealthy pool";
            description = "The pre-seed restore for '{{ $labels.service }}' was aborted because its parent ZFS pool is not in an ONLINE state. Check 'zpool status' for details.";
            command = "zpool status";
          };
        };
        })  # End ZFS alerts mkIf

        # System health monitoring alerts (always enabled)
        {
          # Node exporter down
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

          # Prometheus self-monitoring
          "prometheus-down" = {
            type = "promql";
            alertname = "PrometheusDown";
            expr = "up{job=\"prometheus\"} == 0";
            for = "5m";
            severity = "critical";
            labels = { service = "monitoring"; category = "prometheus"; };
            annotations = {
              summary = "Prometheus is down on {{ $labels.instance }}";
              description = "Monitoring system is not functioning. Check prometheus.service status.";
            };
          };

          # Alertmanager down
          "alertmanager-down" = {
            type = "promql";
            alertname = "AlertmanagerDown";
            expr = "up{job=\"alertmanager\"} == 0";
            for = "5m";
            severity = "high";
            labels = { service = "monitoring"; category = "alertmanager"; };
            annotations = {
              summary = "Alertmanager is down on {{ $labels.instance }}";
              description = "Alert delivery system is not functioning. Check alertmanager.service status.";
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

          # High memory usage
          "high-memory-usage" = {
            type = "promql";
            alertname = "HighMemoryUsage";
            expr = ''
              (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.90
            '';
            for = "10m";
            severity = "high";
            labels = { service = "system"; category = "performance"; };
            annotations = {
              summary = "High memory usage on {{ $labels.instance }}";
              description = "Memory usage is {{ $value | humanizePercentage }}. Risk of OOM kills.";
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

          # Dispatcharr container service down
          "dispatcharr-service-down" = {
            type = "promql";
            alertname = "DispatcharrServiceDown";
            expr = ''
              container_service_active{service="dispatcharr"} == 0
            '';
            for = "2m";
            severity = "high";
            labels = { service = "dispatcharr"; category = "container"; };
            annotations = {
              summary = "Dispatcharr service is down on {{ $labels.instance }}";
              description = "IPTV stream management service is not running. Check: systemctl status podman-dispatcharr.service";
              command = "systemctl status podman-dispatcharr.service && journalctl -u podman-dispatcharr.service --since '30m'";
            };
          };

          # Sonarr container service down
          "sonarr-service-down" = {
            type = "promql";
            alertname = "SonarrServiceDown";
            expr = ''
              container_service_active{service="sonarr"} == 0
            '';
            for = "2m";
            severity = "high";
            labels = { service = "sonarr"; category = "container"; };
            annotations = {
              summary = "Sonarr service is down on {{ $labels.instance }}";
              description = "TV series management service is not running. Check: systemctl status podman-sonarr.service";
              command = "systemctl status podman-sonarr.service && journalctl -u podman-sonarr.service --since '30m'";
            };
          };

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

          # Backup and ZFS snapshot health alerts (Gemini Pro recommendations)

          # ZFS snapshot age too old - Sanoid not running
          "zfs-snapshot-too-old" = {
            type = "promql";
            alertname = "ZFSSnapshotTooOld";
            expr = ''
              zfs_latest_snapshot_age_seconds > 86400
            '';
            for = "30m";
            severity = "high";
            labels = { service = "backup"; category = "zfs"; };
            annotations = {
              summary = "ZFS snapshot for {{ $labels.dataset }} is over 24 hours old on {{ $labels.hostname }}";
              description = "Latest snapshot age: {{ $value | humanizeDuration }}. Sanoid may not be running. Check: systemctl status sanoid.service";
              command = "systemctl status sanoid.service && journalctl -u sanoid.service --since '24h'";
            };
          };

          # ZFS snapshot critically old - backup data at risk
          "zfs-snapshot-critical" = {
            type = "promql";
            alertname = "ZFSSnapshotCritical";
            expr = ''
              zfs_latest_snapshot_age_seconds > 172800
            '';
            for = "1h";
            severity = "critical";
            labels = { service = "backup"; category = "zfs"; };
            annotations = {
              summary = "ZFS snapshot for {{ $labels.dataset }} is over 48 hours old on {{ $labels.hostname }}";
              description = "Latest snapshot age: {{ $value | humanizeDuration }}. CRITICAL: Backup data is stale. Immediate investigation required.";
              command = "systemctl status sanoid.service && zfs list -t snapshot {{ $labels.dataset }}";
            };
          };

          # Stale ZFS holds detected
          "zfs-holds-stale" = {
            type = "promql";
            alertname = "ZFSHoldsStale";
            expr = ''
              count(zfs_hold_age_seconds > 21600) by (hostname) > 3
            '';
            for = "2h";
            severity = "medium";
            labels = { service = "backup"; category = "zfs"; };
            annotations = {
              summary = "Multiple stale ZFS holds detected on {{ $labels.hostname }}";
              description = "{{ $value }} holds are older than 6 hours. Backup jobs may have failed. Check: systemctl status restic-zfs-hold-gc.service";
              command = "zfs holds -rH | grep restic- && systemctl status restic-zfs-hold-gc.service";
            };
          };

          # NOTE: Restic backup alerts (restic-backup-failed, restic-backup-stale) are defined
          # in hosts/_modules/nixos/services/backup/monitoring.nix alongside the backup module
        }  # End system health alerts
        ];  # End alerting.rules mkMerge
      };  # End alerting block

      # Storage dataset management
      # forge uses the tank pool (2x NVME) for service data
      # tank/services acts as a logical parent (not mounted)
      # Individual services mount to standard FHS paths
      storage = {
        datasets = {
          enable = true;
          parentDataset = "tank/services";
          parentMount = "/srv";  # Fallback for services without explicit mountpoint

          services = {
            # PostgreSQL dataset is now managed by the PostgreSQL module's storage-integration.nix
            # to avoid duplicate dataset creation and configuration conflicts.
            # See: hosts/_modules/nixos/services/postgresql/storage-integration.nix

            # Prometheus time-series database
            # Multi-model consensus (GPT-5 + Gemini 2.5 Pro + Gemini 2.5 Flash): 8.7/10 confidence
            # Verdict: Prometheus TSDB is correct tool; ZFS snapshots are excessive for disposable metrics
            prometheus = {
              recordsize = "128K";  # Aligned with Prometheus WAL segments and 2h block files
              compression = "lz4";  # Minimal overhead; TSDB chunks already compressed
              mountpoint = "/var/lib/prometheus2";
              owner = "prometheus";
              group = "prometheus";
              mode = "0755";
              properties = {
                # Industry best practice: Do NOT snapshot Prometheus TSDB (metrics are disposable)
                # Reasoning: 15-day retention doesn't justify 6-month snapshots; configs in Git, data replaceable
                # CoW amplification during TSDB compaction significantly impacts performance under snapshots
                "com.sun:auto-snapshot" = "false";  # Disable snapshots (was: true)
                logbias = "throughput";  # Optimize for streaming writes, not low-latency sync
                primarycache = "metadata";  # Avoid ARC pollution; Prometheus has its own caching
                atime = "off";  # Reduce metadata writes on read-heavy query workloads
              };
            };

            # Loki log aggregation storage
            # Optimized for log chunks and WAL files with appropriate compression
            loki = {
              recordsize = "1M";      # Optimized for log chunks (large sequential writes)
              compression = "zstd";   # Better compression for text logs than lz4
              mountpoint = "/var/lib/loki";
              owner = "loki";
              group = "loki";
              mode = "0750";
              properties = {
                "com.sun:auto-snapshot" = "true";   # Enable snapshots for log retention
                logbias = "throughput";             # Optimize for streaming log writes
                atime = "off";                      # Reduce metadata overhead
                primarycache = "metadata";          # Don't cache log data in ARC
              };
            };

            # Alertmanager: Using ephemeral root filesystem storage
            # Rationale (GPT-5 validated):
            # - Only stores silences and notification deduplication state
            # - Homelab acceptable to lose silences on restart
            # - Duplicate notifications after restart are tolerable
            # - Dedicated dataset unnecessary for minimal administrative state
            # Location: /var/lib/alertmanager on rpool/local/root (not snapshotted)
            #
            # Updated: Manage Alertmanager storage via ZFS storage module for consistency
            # (still not snapshotted; data is non-critical). This creates the mountpoint
            # with correct ownership/permissions and ensures ordering via zfs-service-datasets.
            alertmanager = {
              recordsize = "16K";     # Small files; minimal overhead
              compression = "lz4";    # Fast, default
              mountpoint = "/var/lib/alertmanager";
              owner = "alertmanager";
              group = "alertmanager";
              mode = "0750";
              properties = {
                "com.sun:auto-snapshot" = "false";  # Do not snapshot (non-critical state)
                logbias = "throughput";
                primarycache = "metadata";
                atime = "off";
              };
            };
          };

          # Utility datasets (not under parentDataset/services)
          utility = {
            # Temporary dataset for ZFS clone-based backups
            # Used by snapshot-based backup services (dispatcharr, plex)
            # to avoid .zfs directory issues when backing up mounted filesystems
            "tank/temp" = {
              mountpoint = "none";
              compression = "lz4";
              recordsize = "128K";
              properties = {
                "com.sun:auto-snapshot" = "false";  # Don't snapshot temporary clones
              };
            };
          };
        };

        # Shared NFS mount for media access from NAS
        nfsMounts.media = {
          enable = true;
          automount = false;  # Disable automount for always-on media services (prevents idle timeout cascade stops)
          server = "nas.holthome.net";
          remotePath = "/mnt/tank/share";
          localPath = "/mnt/media";  # Use /mnt to avoid conflict with tank/media at /srv/media
          group = "media";
          mode = "02775";  # setgid bit ensures new files inherit media group
          mountOptions = [ "nfsvers=4.2" "timeo=60" "retry=5" "rw" "noatime" ];
        };
      };

      # ZFS snapshot and replication management (part of backup infrastructure)
      backup.sanoid = {
        enable = true;
        sshKeyPath = config.sops.secrets."zfs-replication/ssh-key".path;
        snapshotInterval = "*:0/5";  # Run snapshots every 5 minutes (for high-frequency datasets)
        replicationInterval = "*:0/15";  # Run replication every 15 minutes for faster DR

        # Retention templates for different data types
        templates = {
          production = {
            hourly = 24;      # 24 hours
            daily = 7;        # 1 week
            weekly = 4;       # 1 month
            monthly = 3;      # 3 months
            autosnap = true;
            autoprune = true;
          };
          services = {
            hourly = 48;      # 2 days
            daily = 14;       # 2 weeks
            weekly = 8;       # 2 months
            monthly = 6;      # 6 months
            autosnap = true;
            autoprune = true;
          };
          # High-frequency snapshots for PostgreSQL WAL archives
          # Provides 5-minute RPO for database point-in-time recovery
          wal-frequent = {
            frequently = 12;  # Keep 12 five-minute snapshots (1 hour of frequent retention)
            hourly = 48;      # 2 days of hourly rollup
            daily = 7;        # 1 week of daily rollup
            autosnap = true;
            autoprune = true;
          };
        };

        # Dataset snapshot and replication configuration
        datasets = {
          # Home directory - user data
          "rpool/safe/home" = {
            useTemplate = [ "production" ];
            recursive = false;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/home";
              sendOptions = "w";  # Raw encrypted send
              recvOptions = "u";  # Don't mount on receive
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # System persistence - configuration and state
          "rpool/safe/persist" = {
            useTemplate = [ "production" ];
            recursive = false;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/persist";
              sendOptions = "w";
              recvOptions = "u";
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # Parent service dataset - metadata only, children managed by their respective modules
          # This dataset itself doesn't get snapshotted (recursive = false)
          # Individual service modules (dispatcharr, sonarr, etc.) configure their own snapshots
          # Note: No useTemplate needed - this is just a logical container, not an actual snapshot target
          "tank/services" = {
            recursive = false;  # Don't snapshot children - they manage themselves
            autosnap = false;   # Don't snapshot the parent directory itself
            autoprune = false;
            # No replication - individual services handle their own replication
          };

          # NOTE: tank/temp is now managed via storage.datasets.utility (see above)
          # Removed from Sanoid config to avoid delegation permission errors during bootstrap

          # Dispatcharr request orchestration service
          # Enable snapshots and replication for configuration and state
          "tank/services/dispatcharr" = {
            useTemplate = [ "services" ];
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/dispatcharr";
              sendOptions = "wp";  # Raw encrypted send with property preservation
              recvOptions = "u";   # Don't mount on receive
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # Explicitly disable snapshots on PostgreSQL dataset (rely on pgBackRest)
          "tank/services/postgresql" = {
            autosnap = false;
            autoprune = false;
            recursive = false;
          };

          # Explicitly disable snapshots/replication on Prometheus dataset (metrics are disposable)
          # Rationale (multi-model consensus 8.7/10 confidence):
          # - Industry best practice: Don't backup Prometheus TSDB, only configs/dashboards
          # - 15-day metric retention doesn't justify 6-month snapshot policy
          # - CoW amplification during TSDB compaction degrades performance
          # - Losing metrics on rebuild is acceptable; alerting/monitoring continues immediately
          "tank/services/prometheus" = {
            autosnap = false;
            autoprune = false;
            recursive = false;
          };

          # Loki log aggregation storage
          # Enable snapshots for log retention and disaster recovery
          "tank/services/loki" = {
            useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
            recursive = false;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/loki";
              sendOptions = "w";  # Raw encrypted send (no property preservation)
              recvOptions = "u";  # Don't mount on receive
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # Promtail log shipping agent storage
          # NOTE (Gemini Pro 2.5 validated): Snapshots/replication DISABLED for Promtail
          # Rationale:
          # - Promtail stores live operational state (positions.yaml, wal/) that becomes stale instantly
          # - Restoring stale state causes permanent log LOSS (skips recent logs)
          # - Starting fresh causes duplication (annoying but self-recovering)
          # - In DR: provision new empty dataset, do NOT restore from snapshots
          # - Persistent storage still REQUIRED for normal operation
          "tank/services/promtail" = {
            autosnap = false;   # Disable snapshots per Gemini Pro recommendation
            autoprune = false;
            recursive = false;
            # No replication - state should not be preserved in DR scenarios
          };

          # Grafana monitoring dashboard storage
          # Enable snapshots and replication for dashboards, datasources, and settings
          "tank/services/grafana" = {
            useTemplate = [ "services" ];  # 2 days hourly, 2 weeks daily, 2 months weekly, 6 months monthly
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/grafana";
              sendOptions = "w";  # Raw encrypted send (no property preservation)
              recvOptions = "u";  # Don't mount on receive
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # Plex media server application data
          # Enable snapshots and replication for Plex metadata/state
          "tank/services/plex" = {
            useTemplate = [ "services" ];
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/plex";
              sendOptions = "w";  # Raw encrypted send (no property preservation)
              recvOptions = "u";  # Don't mount on receive
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # Sonarr TV series management application data
          # Enable snapshots and replication for library metadata and settings
          "tank/services/sonarr" = {
            useTemplate = [ "services" ];
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/sonarr";
              sendOptions = "wp";  # Raw encrypted send with property preservation
              recvOptions = "u";   # Don't mount on receive
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              # Consistent naming for Prometheus metrics
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };
        };

        # Restic backup jobs configuration

        # Monitor pool health and alert on degradation
        healthChecks = {
          enable = true;
          interval = "15min";
        };
      };

      system.impermanence.enable = true;

      # Enable persistent journald storage for log retention across reboots
      # Critical for disaster recovery operation visibility and debugging

      # System health monitoring alerts are defined above in the alerting.rules mkMerge block
      # See line ~85 for the complete alert rule definitions including system health metrics

      # Distributed notification system
      # Templates auto-register from service modules (backup.nix, zfs-replication.nix, etc.)
      # No need to explicitly enable individual templates here
      notifications = {
        enable = true;
        defaultBackend = "pushover";

        pushover = {
          enable = true;
          tokenFile = config.sops.secrets."pushover/token".path;
          userKeyFile = config.sops.secrets."pushover/user-key".path;
          defaultPriority = 0;  # Normal priority
          enableHtml = true;
        };
      };

      # System-level notifications (boot/shutdown)
      systemNotifications = {
        enable = true;
        boot.enable = true;
        shutdown.enable = true;
      };

      services = {
        openssh.enable = true;

        # Caddy reverse proxy
        caddy = {
          enable = true;
          # Domain defaults to networking.domain (holthome.net)
        };

        # Observability stack - centralized logging
        observability = {
          enable = true;
          # Disable Prometheus in observability module since forge uses legacy configuration
          prometheus.enable = false;
          loki = {
            enable = true;
            retentionDays = 30; # Longer retention for primary server
            zfsDataset = "tank/services/loki";
            preseed = {
              enable = true;
              repositoryUrl = "/mnt/nas-backup";
              passwordFile = config.sops.secrets."restic/password".path;
              restoreMethods = [ "syncoid" "local" "restic" ];
            };
          };
          promtail = {
            enable = true;
            zfsDataset = "tank/services/promtail";  # Give Promtail its own ZFS dataset
            containerLogSource = "journald"; # Use systemd journal for container logs
            dropNoisyUnits = [
              "systemd-logind"
              "systemd-networkd"
              "systemd-resolved"
              "systemd-timesyncd"
              "NetworkManager"
              "sshd"  # Add sshd to reduce noise from frequent SSH connections
            ];
            # Disable syslog receiver to avoid duplicates (we tail files instead)
            syslog.enable = false;
            # Enable syslog receiver for external systems
            extraScrapeConfigs = [
              {
                job_name = "omada-relay-file";
                static_configs = [
                  {
                    targets = [ "localhost" ];
                    labels = {
                      job = "omada-relay-file";
                      app = "omada";
                      __path__ = "/var/log/omada-relay.log";
                    };
                  }
                ];
                pipeline_stages = [
                  { labels = { env = "homelab"; }; }
                  # Drop any syslog header lines that may precede cleaned messages
                  { drop = { source = "message"; expression = "^<\\d+>"; }; }
                  # Parse the Omada log format
                  {
                    regex = {
                      expression = "^\\[(?P<ts>[\\d.]+)\\]\\s+AP MAC=(?P<ap_mac>[0-9a-f:]+)\\s+MAC SRC=(?P<mac_src>[0-9a-f:]+)\\s+IP SRC=(?P<ip_src>[\\d.]+)\\s+IP DST=(?P<ip_dst>[\\d.]+)\\s+IP proto=(?P<proto>\\d+)\\s+SPT=(?P<sport>\\d+)\\s+DPT=(?P<dport>\\d+)";
                    };
                  }
                  # Extract key fields as labels for efficient querying
                  {
                    labels = {
                      ap_mac = "";
                      ip_src = "";
                      ip_dst = "";
                      proto = "";
                    };
                  }
                  # Use the timestamp from the log entry
                  {
                    timestamp = {
                      source = "ts";
                      format = "Unix";
                    };
                  }
                ];
              }
            ];
          };
          grafana = {
            enable = true;
            zfsDataset = "tank/services/grafana";
            subdomain = "grafana";
            adminUser = "admin";
            adminPasswordFile = config.sops.secrets."grafana/admin-password".path;

            # OIDC authentication via Authelia
            oidc = {
              enable = true;
              clientId = "grafana";
              clientSecretFile = config.sops.secrets."grafana/oidc_client_secret".path;
              authUrl = "https://auth.${config.networking.domain}/api/oidc/authorization";
              tokenUrl = "https://auth.${config.networking.domain}/api/oidc/token";
              apiUrl = "https://auth.${config.networking.domain}/api/oidc/userinfo";
              scopes = [ "openid" "profile" "email" "groups" ];
              roleAttributePath = "contains(groups[*], 'admins') && 'Admin' || 'Viewer'";
              allowSignUp = true;
              signoutRedirectUrl = "https://auth.${config.networking.domain}/logout?rd=https://grafana.${config.networking.domain}";
            };

            autoConfigure = {
              loki = true;  # Auto-configure Loki data source
              prometheus = true;  # Auto-configure Prometheus if available
            };
            plugins = [];
            preseed = {
              enable = true;
              repositoryUrl = "/mnt/nas-backup";
              passwordFile = config.sops.secrets."restic/password".path;
              restoreMethods = [ "syncoid" "local" "restic" ];
            };
          };
          reverseProxy = {
            enable = true;
            subdomain = "loki";
            auth = {
              user = "admin";
              passwordHashEnvVar = "CADDY_LOKI_ADMIN_BCRYPT";
            };
          };
          loki.backup = {
            enable = true;
            includeChunks = false; # Rely on ZFS snapshots for data
          };
          alerts.enable = true; # Enable Loki alerting rules
        };

      # Media management services
      sonarr = {
        enable = true;

        # -- Container Image Configuration --
        # Pin to specific version tags for stability and reproducibility.
        # Avoid ':latest' tag in production to prevent unexpected updates.
        #
        # Renovate bot will automatically update this when configured.
        # Find available tags at: https://fleet.linuxserver.io/image?name=linuxserver/sonarr
        #
        # Example formats:
        # 1. Version pin only:
        #    image = "lscr.io/linuxserver/sonarr:4.0.10.2544-ls294";
        #
        # 2. Version + digest (recommended - immutable and reproducible):
        #    image = "lscr.io/linuxserver/sonarr:4.0.10.2544-ls294@sha256:abc123...";
        #
        # Uncomment and set when ready to pin version:
        image = "ghcr.io/home-operations/sonarr:4.0.15.2940@sha256:ca6c735014bdfb04ce043bf1323a068ab1d1228eea5bab8305ca0722df7baf78";

        # dataDir defaults to /var/lib/sonarr (dataset mountpoint)
        nfsMountDependency = "media";  # Use shared NFS mount and auto-configure mediaDir
        healthcheck.enable = true;  # Enable container health monitoring

        # Reverse proxy configuration for external access
        reverseProxy = {
          enable = true;
          hostName = "sonarr.holthome.net";

          # Enable Authelia SSO protection
          authelia = {
            enable = true;
            instance = "main";  # Use the main Authelia instance
            authDomain = "auth.holthome.net";  # Where users go to authenticate
            policy = "one_factor";  # Allow passwordless WebAuthn (passkey with biometric/PIN = strong single factor)
            allowedGroups = [ "media" ];  # Who can access this service

            # Bypass authentication for API endpoints (needed for Prowlarr, mobile apps, RSS)
            bypassPaths = [ "/api" "/feed" ];

            # Restrict API access to internal networks only (enhanced security)
            # This prevents external access to API endpoints even with a leaked API key
            allowedNetworks = [
              "172.16.0.0/12"    # Docker internal networks (172.16-31.x.x)
              "192.168.1.0/24"   # Local LAN
              "10.0.0.0/8"       # Internal private network range
            ];
          };
        };
        backup = {
          enable = true;
          repository = "nas-primary";  # Primary NFS backup repository
          # TODO: Enable ZFS snapshots for SQLite consistency when Sonarr gets ZFS dataset
          # useSnapshots = true;
          # zfsDataset = "tank/services/sonarr";
        };
        notifications.enable = true;  # Enable failure notifications
        preseed = {
          enable = true;  # Enable self-healing restore
          # Pass repository config explicitly (reading from config.sops.secrets to avoid circular dependency)
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          # environmentFile not needed for local filesystem repository
        };
      };

      # (rsyslogd configured at top-level services.rsyslogd)

      # Additional service-specific configurations are in their own files
      # See: dispatcharr.nix, etc.
        # Example service configurations can be copied from luna when ready
      };

      users = {
        groups = {
          admins = {
            gid = 991;
            members = [
              "ryan"
            ];
          };
          # Shared media group for *arr services NFS access
          # High GID to avoid conflicts with system/user GIDs
          media = {
            gid = 65537;
          };
        };
      };
    };

    services.rsyslogd = {
      enable = true;
      extraConfig = ''
        global(workDirectory="/var/spool/rsyslog")
        global(maxMessageSize="64k")

        # Load message modification module
        module(load="mmjsonparse")

        template(name="OmadaToRFC5424" type="string"
          string="<134>1 %timegenerated:::date-rfc3339% %fromhost% omada - - [omada@47450 src_ip=\"%fromhost-ip%\"] %$.cleanmsg%\n")

        # Unescaped message template for file sink (preserve embedded newlines)
        template(name="OmadaRawUnescaped" type="string"
          string="%timegenerated:::date-rfc3339% src_ip=%fromhost-ip% %$.cleanmsg%\n")

        ruleset(name="omada_devices") {
          # Convert Omada's literal CR/LF markers into real newlines and strip residuals
          set $.cleanmsg = replace($msg, "#015#012", "\n");
          set $.cleanmsg = replace($.cleanmsg, "#012", "\n");
          set $.cleanmsg = replace($.cleanmsg, "#015", "");
          # Split on newlines - rsyslog will process each line separately
          # The key is to configure the input to parse multi-line packets
          action(type="omfile" file="/var/log/omada-relay.log" template="OmadaToRFC5424")

          # Raw sink with unescaped newlines for Promtail file tailing
          action(type="omfile" file="/var/log/omada-raw.log" template="OmadaRawUnescaped")

          action(
            type="omfwd" Target="127.0.0.1" Port="1516" Protocol="udp" template="OmadaToRFC5424"
            queue.type="LinkedList" queue.size="10000" queue.dequeueBatchSize="200"
            action.resumeRetryCount="-1" action.resumeInterval="5"
          )
          stop
        }

        # UDP input for Omada syslog (rate limiting configured on input)
        module(load="imudp")
        input(
          type="imudp"
          port="1514"
          ruleset="omada_devices"
          # Rate limit to protect against bursts (set on input; not supported on module load)
          rateLimit.Interval="5"
          rateLimit.Burst="10000"
        )

        module(load="impstats" interval="60" severity="7" log.file="/var/log/rsyslog-stats.log")
      '';
    };

    # pgBackRest - PostgreSQL Backup & Recovery
    # Replaces custom pg-backup-scripts with industry-standard tooling
    environment.systemPackages = [ pkgs.pgbackrest pkgs.acl ];

    # pgBackRest configuration
    # Industry-standard dual-repository setup with full PITR capability on both repos
    #
    # WAL archiving strategy:
    # - Repo1 (NFS): Fast local backups + continuous WAL archiving
    #   * 7-day retention
    #   * Point-in-Time Recovery (PITR) capable
    #   * Primary recovery source (fastest)
    #
    # - Repo2 (Cloudflare R2): Offsite DR + continuous WAL archiving
    #   * 30-day retention
    #   * Point-in-Time Recovery (PITR) capable
    #   * Geographic redundancy
    #   * Cost-effective (R2 has zero egress fees)
    #
    # Archive-async with local spool ensures WAL archiving continues even if repos are temporarily unavailable
    # Single unified pgBackRest configuration for both repositories
    # - Repo1 (NFS): Primary for fast local recovery with PITR
    # - Repo2 (R2/S3): Offsite DR with full PITR capability
    #
    # CRITICAL: R2 credentials MUST be in the config file for archive_command to work
    # The PostgreSQL archiver process reads /etc/pgbackrest.conf and does NOT have
    # access to environment variables set in backup scripts or systemd services.
    # This is why backups work (they set env vars) but WAL archiving fails.
    #
    # We generate this config file from a template that includes placeholders,
    # then use a systemd service to substitute the actual credentials at runtime.
    environment.etc."pgbackrest.conf.template".text = ''
      [global]
      # Repo1 (NFS) - Primary for WAL archiving and local backups
      repo1-path=/mnt/nas-postgresql/pgbackrest
      repo1-retention-full=7

      # Repo2 (Cloudflare R2) - Offsite DR with PITR capability
      # Now includes WAL archiving for complete offsite PITR
      repo2-type=s3
      repo2-path=/forge-pgbackrest
      repo2-s3-bucket=nix-homelab-prod-servers
      repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com
      repo2-s3-region=auto
      repo2-s3-uri-style=path
      repo2-retention-full=30
      # Credentials will be substituted by pgbackrest-config-generator service
      repo2-s3-key=__R2_ACCESS_KEY_ID__
      repo2-s3-key-secret=__R2_SECRET_ACCESS_KEY__

      # Global archive settings (apply to all repositories with archiving enabled)
      # Archive async with local spool to decouple DB availability from repos
      # If repos are down, archive_command succeeds by writing to local spool
      # Background process flushes to repos when they are available
      archive-async=y
      spool-path=/var/lib/pgbackrest/spool
      archive-push-queue-max=1073741824

      # Other global settings
      process-max=2
      log-level-console=info
      log-level-file=detail
      start-fast=y
      delta=y
      compress-type=lz4
      compress-level=3

      [main]
      pg1-path=/var/lib/postgresql/16
      pg1-port=5432
      pg1-user=postgres
    '';

    # Service to generate pgbackrest.conf with actual credentials from SOPS
    # Runs before PostgreSQL and preseed to ensure all pgBackRest operations have valid config
    systemd.services.pgbackrest-config-generator = {
      description = "Generate pgBackRest configuration with R2 credentials";
      wantedBy = [ "multi-user.target" ];
      before = [ "postgresql.service" "postgresql-preseed.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
        ExecStart = pkgs.writeShellScript "generate-pgbackrest-conf" ''
          set -euo pipefail

          # Read template and substitute credentials
          sed -e "s|__R2_ACCESS_KEY_ID__|$AWS_ACCESS_KEY_ID|g" \
              -e "s|__R2_SECRET_ACCESS_KEY__|$AWS_SECRET_ACCESS_KEY|g" \
              /etc/pgbackrest.conf.template > /etc/pgbackrest.conf

          # Set secure permissions (postgres user needs to read this)
          chmod 640 /etc/pgbackrest.conf
          chown postgres:postgres /etc/pgbackrest.conf

          echo "Generated /etc/pgbackrest.conf with R2 credentials"
        '';
      };
    };

    # Declaratively manage pgBackRest repository directory and metrics file
    # Format: Type, Path, Mode, User, Group, Age, Argument
    # This ensures directories/files exist on boot with correct ownership/permissions
    systemd.tmpfiles.rules = [
      "d /mnt/nas-postgresql/pgbackrest 0750 postgres postgres - -"
      # Create local spool directory for async WAL archiving
      # Critical: Allows archive_command to succeed even when NFS is down
      "d /var/lib/pgbackrest 0750 postgres postgres - -"
      "d /var/lib/pgbackrest/spool 0750 postgres postgres - -"
      # Create pgBackRest log directory
      "d /var/log/pgbackrest 0750 postgres postgres - -"
      # Create systemd journal directory with correct permissions for persistent storage
      # Mode 2755 sets setgid bit so files inherit systemd-journal group
      "d /var/log/journal 2755 root systemd-journal - -"
      # Ensure textfile_collector directory exists before creating metrics file
      # Mode 0775 allows node-exporter group members to write metrics files
      "d /var/lib/node_exporter/textfile_collector 0775 node-exporter node-exporter - -"
      # Create metrics file at boot with correct ownership so postgres user can write to it
      # and node-exporter group can read it. Type "f" creates the file if it doesn't exist.
      "f /var/lib/node_exporter/textfile_collector/pgbackrest.prom 0644 postgres node-exporter - -"
      # Create metrics file for the post-preseed service
      "f /var/lib/node_exporter/textfile_collector/postgresql_postpreseed.prom 0644 postgres node-exporter - -"
      # Note: /var/lib/postgresql directory created by zfs-service-datasets.service with proper ownership
    ];

    # pgBackRest systemd services
    # Note: repo2 configuration defined in top-level let block as repo2Flags and repo2EnvVars
    systemd.services = {
      # Stanza creation (runs once at setup)
      pgbackrest-stanza-create = {
        description = "pgBackRest stanza initialization";
        after = [ "postgresql-readiness-wait.service" "postgresql-preseed.service" ];
        wants = [ "postgresql-readiness-wait.service" "postgresql-preseed.service" ];
        requires = [ "postgresql-readiness-wait.service" "postgresql-preseed.service" ];
        path = [ pkgs.pgbackrest pkgs.postgresql_16 ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          RemainAfterExit = true;
          # Add R2 credentials for repo2 stanza creation
          EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
        };
        # Add NFS mount dependency
        unitConfig = {
          RequiresMountsFor = [ "/mnt/nas-postgresql" ];
        };
        script = ''
          set -euo pipefail

          # Directory is managed by systemd.tmpfiles.rules
          # This service handles three scenarios:
          # 1. Fresh install: Creates new stanza
          # 2. After pre-seed restore: Validates existing stanza matches restored DB
          # 3. Disaster recovery: Force recreates stanza when metadata conflicts

          echo "[$(date -Iseconds)] Creating pgBackRest stanza 'main' for both repos (NFS + R2)..."

          # Check if we're in disaster recovery scenario (preseed marker exists)
          DISASTER_RECOVERY=false
          if [ -f "/var/lib/postgresql/.preseed-completed" ]; then
            echo "[$(date -Iseconds)] Preseed marker detected - this is a disaster recovery scenario"
            DISASTER_RECOVERY=true
          fi

          # Try to create/upgrade stanza to handle both fresh install and disaster recovery
          echo "[$(date -Iseconds)] Attempting stanza creation for both repositories..."

          # Transform AWS env vars to pgBackRest format for repo2 access
          export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
          export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"

          # Capture output for better error logging
          # Try creating stanza for both repos first (ideal path)
          # Repo2 configuration now in /etc/pgbackrest.conf
          if ! output=$(pgbackrest --stanza=main stanza-create 2>&1); then
            echo "[$(date -Iseconds)] Initial stanza creation for both repos failed, checking if upgrade is needed or repo2 is unavailable..."
            echo "--- pgbackrest stanza-create output ---"
            echo "$output"
            echo "---------------------------------------"

            # Check if this is a database system identifier mismatch (error 028)
            # This happens after disaster recovery when database was rebuilt but stanza exists
            if pgbackrest --stanza=main info >/dev/null 2>&1; then
              echo "[$(date -Iseconds)] Stanza exists but database mismatch detected - upgrading stanza"

              if ! upgrade_output=$(pgbackrest --stanza=main stanza-upgrade 2>&1); then
                echo "[$(date -Iseconds)] ERROR: Stanza upgrade failed"
                echo "--- pgbackrest stanza-upgrade output ---"
                echo "$upgrade_output"
                echo "------------------------------------------"
                exit 1
              fi
              echo "[$(date -Iseconds)] Stanza upgrade successful - database now matches backup metadata"
            else
              # Stanza doesn't exist and dual-repo creation failed
              # Prioritize getting repo1 online for WAL archiving even if repo2 is broken
              echo "[$(date -Iseconds)] WARNING: Dual-repository stanza creation failed. Attempting repo1-only to secure WAL archiving..."

              # Try stanza-create with just repo1 (no --repo flag needed, it will use what's in config)
              if pgbackrest --stanza=main stanza-create 2>&1; then
                echo "[$(date -Iseconds)] SUCCESS: Repo1 stanza is active. WAL archiving will function."
                echo "[$(date -Iseconds)] WARNING: Repo2 (R2) stanza creation failed. System operational but with reduced redundancy."
                echo "[$(date -Iseconds)] Action required: Fix repo2 connectivity/credentials and retry stanza-create manually."
                # Exit successfully - WAL archiving is working (degraded but operational)
                # Operators should monitor logs for this warning and fix repo2 connectivity
                exit 0
              else
                echo "[$(date -Iseconds)] CRITICAL: Failed to create or upgrade stanza even for repo1."
                echo "[$(date -Iseconds)] WAL archiving is BROKEN. Manual intervention required immediately."
                echo "[$(date -Iseconds)] Check: NFS mount (/mnt/nas-postgresql), PostgreSQL running, stanza configuration."
                exit 1
              fi
            fi
          else
            echo "[$(date -Iseconds)] Successfully created stanzas for both repositories"
          fi

          echo "[$(date -Iseconds)] Running final configuration check..."
          # Use info command instead of check to avoid waiting for WAL archiving
          # check command has 60s timeout waiting for WAL segments which can fail after PostgreSQL restart
          # info command just verifies stanza configuration is valid
          # Repo2 configuration now in /etc/pgbackrest.conf
          pgbackrest --stanza=main info
          echo "[$(date -Iseconds)] Stanza configuration verified successfully for both repositories"
        '';
        wantedBy = [ "multi-user.target" ];
      };

      # Post-preseed backup (creates fresh baseline after restoration)
      pgbackrest-post-preseed = {
        description = "Create fresh pgBackRest backup after pre-seed restoration";
        after = [ "postgresql.service" "pgbackrest-stanza-create.service" "network-online.target" "postgresql-preseed.service" ];
        wants = [ "postgresql.service" "network-online.target" ];
        requires = [ "postgresql.service" ];
        bindsTo = [ "postgresql.service" ];  # Stop if PostgreSQL goes down mid-run
        # Triggered by OnSuccess from postgresql-preseed instead of boot-time activation
        # This eliminates condition evaluation race and "skipped at boot" noise
        path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq pkgs.systemd ];

        # Only run if preseed completed but post-preseed backup hasn't been done yet
        unitConfig = {
          ConditionPathExists = [
            "/var/lib/postgresql/.preseed-completed"
            "!/var/lib/postgresql/.postpreseed-backup-done"
          ];
          # Proper NFS mount dependency for backup operations
          RequiresMountsFor = [ "/mnt/nas-postgresql" ];
          # Recovery from transient failures
          StartLimitIntervalSec = "600";
          StartLimitBurst = "5";
          # Trigger metrics collection on success to immediately update Prometheus
          OnSuccess = "pgbackrest-metrics.service";
        };

        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          RemainAfterExit = true;
          Environment = "PGHOST=/var/run/postgresql";
          # Add R2 credentials for repo2 backup
          EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
          # Restart on failure with proper backoff for recovery timing issues
          Restart = "on-failure";
          RestartSec = "60s";
          IPAddressDeny = [ "169.254.169.254" ];
        };

        script = ''
          #!/usr/bin/env bash
          set -euo pipefail

          # --- Structured Logging & Error Handling ---
          LOG_SERVICE_NAME="pgbackrest-post-preseed"
          METRICS_FILE="/var/lib/node_exporter/textfile_collector/postgresql_postpreseed.prom"

          log_json() {
            local level="$1"
            local event="$2"
            local message="$3"
            local details_json="''${4:-{}}"
            printf '{"timestamp":"%s","service":"%s","level":"%s","event":"%s","message":"%s","details":%s}\n' \
              "$(date -u --iso-8601=seconds)" \
              "''${LOG_SERVICE_NAME}" \
              "$level" \
              "$event" \
              "$message" \
              "$details_json"
          }

          write_metrics() {
            local status="$1"
            local duration="$2"
            local status_code=$([ "$status" = "success" ] && echo 1 || echo 0)
            cat > "''${METRICS_FILE}.tmp" <<EOF
# HELP postgresql_postpreseed_status Indicates the status of the last post-preseed backup (1 for success, 0 for failure).
# TYPE postgresql_postpreseed_status gauge
postgresql_postpreseed_status{stanza="main"} ''${status_code}
# HELP postgresql_postpreseed_last_duration_seconds Duration of the last post-preseed backup in seconds.
# TYPE postgresql_postpreseed_last_duration_seconds gauge
postgresql_postpreseed_last_duration_seconds{stanza="main"} ''${duration}
# HELP postgresql_postpreseed_last_completion_timestamp_seconds Timestamp of the last post-preseed backup completion.
# TYPE postgresql_postpreseed_last_completion_timestamp_seconds gauge
postgresql_postpreseed_last_completion_timestamp_seconds{stanza="main"} $(date +%s)
EOF
            mv "''${METRICS_FILE}.tmp" "$METRICS_FILE"
          }

          trap_error() {
            local exit_code=$?
            local line_no=$1
            local command="$2"
            log_json "ERROR" "script_error" "Script failed with exit code $exit_code at line $line_no: $command" \
              "{\"exit_code\": ''${exit_code}, \"line_number\": ''${line_no}, \"command\": \"$command\"}"
            write_metrics "failure" 0
            exit $exit_code
          }
          trap 'trap_error $LINENO "$BASH_COMMAND"' ERR
          # --- End Helpers ---

          log_json "INFO" "postpreseed_start" "Post-preseed backup process starting."

          # Verify that pre-seed actually restored data
          if [ ! -f /var/lib/postgresql/.preseed-completed ]; then
            log_json "ERROR" "preseed_marker_missing" "Pre-seed completion marker not found. This service should not have been triggered."
            exit 1
          fi

          restored_from=$(grep "restored_from=" /var/lib/postgresql/.preseed-completed | cut -d= -f2)
          if [ "$restored_from" = "existing_pgdata" ]; then
            log_json "INFO" "postpreseed_skipped" "Pre-seed marker indicates existing PGDATA was found. Skipping post-preseed backup." \
              '{"reason":"no_restoration_occurred"}'
            exit 0
          fi
          log_json "INFO" "preseed_marker_found" "Pre-seed marker indicates restoration from: $restored_from"

          # Wait for PostgreSQL to complete recovery and be ready for backup
          log_json "INFO" "wait_for_postgres" "Waiting for PostgreSQL to become ready..."
          if ! timeout 300 bash -c 'until pg_isready -q; do sleep 2; done'; then
            log_json "ERROR" "postgres_timeout" "PostgreSQL did not become ready within 300 seconds."
            exit 1
          fi
          log_json "INFO" "postgres_ready" "PostgreSQL is ready."

          # Wait for recovery completion (critical for post-restore backups)
          log_json "INFO" "wait_for_promotion" "Waiting for PostgreSQL recovery to complete..."
          TIMEOUT_SECONDS=1800  # 30 minutes - tune for worst-case WAL backlog
          INTERVAL_SECONDS=2
          deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))

          while true; do
            # Check if this is a standby that will never promote
            if [ -f "/var/lib/postgresql/16/standby.signal" ]; then
              log_json "ERROR" "promotion_failed" "standby.signal present - node will not promote" "{\"reason\":\"standby_configuration\"}"
              exit 2
            fi

            # Separate connection check from recovery status check for clearer diagnostics
            if ! psql -Atqc "SELECT 1;" >/dev/null 2>&1; then
              log_json "ERROR" "connection_failed" "Cannot connect to PostgreSQL - service may not be running" "{\"reason\":\"connection_failed\"}"
              exit 3
            fi

            # Check if PostgreSQL is still in recovery mode
            in_recovery=$(psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null)
            if [ $? -ne 0 ]; then
              log_json "ERROR" "query_failed" "Failed to query recovery status" "{\"reason\":\"query_failed\"}"
              exit 3
            fi

            if [ "$in_recovery" = "f" ]; then
              # Verify the database is writable (not read-only)
              read_only=$(psql -Atqc "SHOW default_transaction_read_only;" 2>/dev/null)
              if [ $? -ne 0 ]; then
                log_json "ERROR" "query_failed" "Failed to query transaction mode" "{\"reason\":\"query_failed\"}"
                exit 3
              fi

              if [ "$read_only" = "off" ]; then
                log_json "INFO" "promotion_complete" "PostgreSQL recovery completed successfully" "{\"in_recovery\":false,\"read_only\":false}"
                break
              else
                log_json "WARN" "promotion_partial" "Recovery complete but database is read-only" "{\"in_recovery\":false,\"read_only\":true}"
              fi
            else
              log_json "INFO" "promotion_waiting" "PostgreSQL still in recovery mode" "{\"in_recovery\":true}"
            fi

            # Check timeout
            if [ "$(date +%s)" -ge "$deadline" ]; then
              # Get last WAL replay position and timeline for diagnostics
              last_lsn=$(psql -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null || echo "unknown")
              timeline_id=$(psql -Atqc "SELECT timeline_id FROM pg_control_checkpoint();" 2>/dev/null || echo "unknown")
              log_json "ERROR" "promotion_timeout" "Timed out waiting for PostgreSQL recovery completion" "{\"timeout_seconds\":$TIMEOUT_SECONDS,\"last_wal_replay_lsn\":\"''${last_lsn}\",\"timeline_id\":\"''${timeline_id}\",\"hint\":\"check for missing WAL files or recovery configuration issues\"}"
              exit 1
            fi

            sleep "$INTERVAL_SECONDS"
          done

          # Determine current system-id
          cur_sysid="$(psql -Atqc "select system_identifier from pg_control_system()")"
          log_json "INFO" "system_id_check" "Checking for existing backups for current system-id." "{\"system_id\":\"$cur_sysid\"}"

          # Transform AWS env vars to pgBackRest format for repo2 operations
          export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
          export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"

          # Check each repository independently to ensure both have fresh backups
          # This prevents skipping repo2 if repo1 succeeds but repo2 failed previously
          INFO_JSON="$(pgbackrest --stanza=main --output=json info 2>/dev/null || echo '[]')"

          # Use single jq query to extract both repo counts efficiently
          COUNTS=$(echo "$INFO_JSON" | jq -r --arg sid "$cur_sysid" '
            .[] | .backup | map(select(.type == "full" and .database["system-id"] == ($sid|tonumber) and (.error // null) == null)) |
            {
              repo1: map(select(.repo == 1)) | length,
              repo2: map(select(.repo == 2)) | length
            } | "\(.repo1) \(.repo2)"
          ' 2>/dev/null || echo "0 0")

          read -r has_full_repo1 has_full_repo2 <<< "$COUNTS"

          start_time=$(date +%s)
          repo1_ok=false
          repo2_ok=false

          # Backup to repo1 if needed
          if [ "''${has_full_repo1:-0}" -gt 0 ]; then
            log_json "INFO" "backup_repo1_skipped" "Found existing full backup for repo1 (NFS)."
            repo1_ok=true
          else
            log_json "INFO" "backup_repo1_start" "No full backup found for repo1; starting backup to NFS..."
            if pgbackrest --stanza=main --type=full --repo=1 backup; then
              log_json "INFO" "backup_repo1_complete" "Repo1 backup completed"
              repo1_ok=true
            else
              log_json "ERROR" "backup_repo1_failed" "Repo1 backup failed"
            fi
          fi

          # Backup to repo2 if needed
          if [ "''${has_full_repo2:-0}" -gt 0 ]; then
            log_json "INFO" "backup_repo2_skipped" "Found existing full backup for repo2 (R2)."
            repo2_ok=true
          else
            log_json "INFO" "backup_repo2_start" "No full backup found for repo2; starting backup to R2..."
            # Repo2 configuration read from /etc/pgbackrest.conf
            # Credentials supplied via PGBACKREST_REPO2_S3_KEY environment variables
            if pgbackrest --stanza=main --type=full --repo=2 backup; then
              log_json "INFO" "backup_repo2_complete" "Repo2 backup completed"
              repo2_ok=true
            else
              log_json "ERROR" "backup_repo2_failed" "Repo2 backup failed"
            fi
          fi

          end_time=$(date +%s)
          duration=$((end_time - start_time))

          # Retry limit to prevent infinite restart loops
          MAX_RETRIES=5
          RETRY_FILE="/var/lib/postgresql/.postpreseed-retry-count"
          RETRY_LOCK="/var/lib/postgresql/.postpreseed-retry.lock"

          # Use flock for atomic retry counter operations to prevent race conditions
          (
            flock 200  # Acquire exclusive lock on file descriptor 200

            retries=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)

            # Only mark complete if BOTH repositories succeeded
            if [ "$repo1_ok" = true ] && [ "$repo2_ok" = true ]; then
              log_json "INFO" "backup_complete" "Post-preseed backup process completed successfully for both repositories." "{\"duration_seconds\":''${duration}}"
              write_metrics "success" "''${duration}"

              # Clean up retry counter on success
              rm -f "$RETRY_FILE"

              # Mark completion to prevent re-runs ONLY on full success
              touch /var/lib/postgresql/.postpreseed-backup-done
              log_json "INFO" "marker_created" "Completion marker created at /var/lib/postgresql/.postpreseed-backup-done"
              log_json "INFO" "postpreseed_complete" "Post-preseed backup process finished."
            else
              # Check if we've exceeded retry limit
              if [ "$retries" -ge "$MAX_RETRIES" ]; then
                log_json "CRITICAL" "postpreseed_gave_up" "Exceeded maximum retry attempts ($MAX_RETRIES). Stopping service to prevent infinite loop." "{\"failed_repo1\":$([ "$repo1_ok" = false ] && echo true || echo false),\"failed_repo2\":$([ "$repo2_ok" = false ] && echo true || echo false)}"
                write_metrics "failure" "''${duration}"

                # Create marker indicating permanent failure
                touch "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                echo "repo1_ok=$repo1_ok" > "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                echo "repo2_ok=$repo2_ok" >> "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                echo "retries=$retries" >> "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                echo "timestamp=$(date -Iseconds)" >> "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"

                rm -f "$RETRY_FILE"
                exit 0  # Exit successfully to stop the restart loop
              else
                # Increment retry counter atomically
                echo $((retries + 1)) > "$RETRY_FILE"
                log_json "ERROR" "postpreseed_failed" "Post-preseed backup failed for one or more repositories. Retry attempt $((retries + 1))/$MAX_RETRIES." "{\"failed_repo1\":$([ "$repo1_ok" = false ] && echo true || echo false),\"failed_repo2\":$([ "$repo2_ok" = false ] && echo true || echo false)}"
                write_metrics "failure" "''${duration}"
                exit 1  # Exit with failure to trigger systemd restart logic
              fi
            fi
          ) 200>"$RETRY_LOCK"  # Redirect file descriptor 200 to lock file
        '';
      };

      # Full backup
      pgbackrest-full-backup = {
        description = "pgBackRest full backup";
        after = [ "postgresql.service" "pgbackrest-stanza-create.service" ];
        wants = [ "postgresql.service" ];
        path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.systemd ];

        unitConfig = {
          RequiresMountsFor = [ "/mnt/nas-postgresql" ];
          # Trigger metrics collection on success to immediately update Prometheus
          OnSuccess = "pgbackrest-metrics.service";
        };
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
          IPAddressDeny = [ "169.254.169.254" ];
        };
        script = ''
          set -euo pipefail

          # Transform AWS env vars to pgBackRest format
          export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
          export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"

          echo "[$(date -Iseconds)] Starting full backup to repo1 (NFS)..."
          pgbackrest --stanza=main --type=full --repo=1 backup
          echo "[$(date -Iseconds)] Repo1 backup completed"

          echo "[$(date -Iseconds)] Starting full backup to repo2 (R2)..."
          # Repo2 configuration read from /etc/pgbackrest.conf
          # Now includes WAL archiving for complete offsite PITR capability
          pgbackrest --stanza=main --type=full --repo=2 backup
          echo "[$(date -Iseconds)] Full backup to both repos completed"
        '';
      };

      # Incremental backup
      pgbackrest-incr-backup = {
        description = "pgBackRest incremental backup";
        after = [ "postgresql.service" "pgbackrest-stanza-create.service" ];
        wants = [ "postgresql.service" ];
        path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.systemd ];

        unitConfig = {
          RequiresMountsFor = [ "/mnt/nas-postgresql" ];
          # Trigger metrics collection on success to immediately update Prometheus
          OnSuccess = "pgbackrest-metrics.service";
        };
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
          IPAddressDeny = [ "169.254.169.254" ];
        };
        script = ''
          set -euo pipefail

          # Transform AWS env vars to pgBackRest format
          export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
          export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"

          echo "[$(date -Iseconds)] Starting incremental backup to repo1 (NFS)..."
          pgbackrest --stanza=main --type=incr --repo=1 backup
          echo "[$(date -Iseconds)] Repo1 backup completed"

          echo "[$(date -Iseconds)] Starting incremental backup to repo2 (R2)..."
          # Repo2 configuration read from /etc/pgbackrest.conf
          # Now includes WAL archiving for complete offsite PITR capability
          pgbackrest --stanza=main --type=incr --repo=2 backup
          echo "[$(date -Iseconds)] Incremental backup to both repos completed"
        '';
      };

      # Differential backup
      # Differential backups removed - simplified to daily full + hourly incremental
      # Reduces backup window contention and operational complexity
      # Retention still appropriate: 7 daily fulls + hourly incrementals
    };

    # pgBackRest backup timers
    systemd.timers = {
      pgbackrest-full-backup = {
        description = "pgBackRest full backup timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "02:00";  # Daily at 2 AM
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };

      pgbackrest-incr-backup = {
        description = "pgBackRest incremental backup timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";  # Every hour
          Persistent = true;
          RandomizedDelaySec = "5m";
        };
      };

      # Differential backup timer removed - using simplified schedule
      # Daily full (2 AM) + Hourly incremental is sufficient for homelab
    };



    # General ZFS snapshot metrics exporter for all backup datasets
    # Monitors all datasets from backup.zfs.pools configuration
    # Provides comprehensive snapshot health metrics for Prometheus
    systemd.services.zfs-snapshot-metrics =
      let
        # Dynamically generate dataset list from backup.zfs.pools configuration
        # This ensures metrics stay in sync with backup configuration
        allDatasets = lib.flatten (
          map (pool:
            map (dataset: "${pool.pool}/${dataset}") pool.datasets
          ) config.modules.backup.zfs.pools
        );
        # Convert to bash array format
        datasetsArray = lib.concatMapStrings (ds: ''"${ds}" '') allDatasets;
      in
      {
        description = "Export ZFS snapshot metrics for all backup datasets";
        serviceConfig = {
          Type = "oneshot";
          User = "root";
        };
        script = ''
          set -euo pipefail

          METRICS_FILE="/var/lib/node_exporter/textfile_collector/zfs_snapshots.prom"
          METRICS_TEMP="$METRICS_FILE.tmp"

          # Start metrics file
          cat > "$METRICS_TEMP" <<'HEADER'
# HELP zfs_snapshot_count Number of snapshots per dataset
# TYPE zfs_snapshot_count gauge
HEADER

          # Datasets to monitor (dynamically generated from backup.nix)
          DATASETS=(${datasetsArray})

          # Count snapshots per dataset
          for dataset in "''${DATASETS[@]}"; do
            SNAPSHOT_COUNT=$(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name | ${pkgs.gnugrep}/bin/grep -c "^$dataset@" || echo 0)
            echo "zfs_snapshot_count{dataset=\"$dataset\"} $SNAPSHOT_COUNT" >> "$METRICS_TEMP"
          done

          # Add latest snapshot age metrics (using locale-safe Unix timestamps)
          cat >> "$METRICS_TEMP" <<'HEADER2'

# HELP zfs_snapshot_latest_timestamp Creation time of most recent snapshot per dataset (Unix timestamp)
# TYPE zfs_snapshot_latest_timestamp gauge
HEADER2

          for dataset in "''${DATASETS[@]}"; do
            # Get most recent snapshot name
            LATEST_SNAPSHOT=$(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name -s creation "$dataset" 2>/dev/null | tail -n 1 || echo "")
            if [ -n "$LATEST_SNAPSHOT" ]; then
              # Get creation time as Unix timestamp (locale-safe, uses -p for parseable output)
              LATEST_TIMESTAMP=$(${pkgs.zfs}/bin/zfs get -H -p -o value creation "$LATEST_SNAPSHOT" 2>/dev/null || echo 0)
              echo "zfs_snapshot_latest_timestamp{dataset=\"$dataset\"} $LATEST_TIMESTAMP" >> "$METRICS_TEMP"
            fi
          done

          # Add total space used by all snapshots per dataset
          cat >> "$METRICS_TEMP" <<'HEADER3'

# HELP zfs_snapshot_total_used_bytes Total space used by all snapshots for a dataset
# TYPE zfs_snapshot_total_used_bytes gauge
HEADER3

          for dataset in "''${DATASETS[@]}"; do
            TOTAL_USED=$(${pkgs.zfs}/bin/zfs list -Hp -t snapshot -o used -r "$dataset" 2>/dev/null | ${pkgs.gawk}/bin/awk '{sum+=$1} END {print sum}' || echo 0)
            echo "zfs_snapshot_total_used_bytes{dataset=\"$dataset\"} $TOTAL_USED" >> "$METRICS_TEMP"
          done

          mv "$METRICS_TEMP" "$METRICS_FILE"
        '';
        after = [ "zfs-mount.service" ];
        wants = [ "zfs-mount.service" ];
      };

    systemd.timers.zfs-snapshot-metrics = {
      description = "Collect ZFS snapshot metrics every 5 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Run 1 minute after snapshots (avoids race condition with pg-zfs-snapshot)
        OnCalendar = "*:1/5";
        Persistent = true;
      };
    };

    # =============================================================================
    # pgBackRest Monitoring Metrics (REVISED)
    # =============================================================================
    systemd.services.pgbackrest-metrics = {
      description = "Collect pgBackRest backup metrics for Prometheus";
      path = [ pkgs.jq pkgs.coreutils pkgs.pgbackrest ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        # Block access to EC2 metadata service to prevent timeout
        IPAddressDeny = [ "169.254.169.254" ];
      };
      environment = {
        # Repository metadata for metrics labels
        # Use METRICS_ prefix to avoid pgBackRest interpreting these as config options
        METRICS_REPO1_NAME = "NFS";
        METRICS_REPO1_LOCATION = "nas-1";
        METRICS_REPO2_NAME = "R2";
        METRICS_REPO2_LOCATION = "offsite";
      };
      script = ''
        set -euo pipefail

        METRICS_FILE="/var/lib/node_exporter/textfile_collector/pgbackrest.prom"
        METRICS_TEMP="''${METRICS_FILE}.tmp"

        # Run pgbackrest info, capturing JSON. Timeout prevents hangs on network issues.
        # All configuration (including repo2 S3 credentials) is read from /etc/pgbackrest.conf
        # which is generated by pgbackrest-config-generator.service
        INFO_JSON=$(timeout 300s pgbackrest --stanza=main --output=json info 2>&1)

        # Exit gracefully if command fails or returns empty/invalid JSON
        if ! echo "$INFO_JSON" | jq -e '.[0].name == "main"' > /dev/null; then
          echo "Failed to get valid pgBackRest info. Writing failure metric." >&2
          echo "Raw output from pgbackrest:" >&2
          echo "$INFO_JSON" >&2
          cat > "$METRICS_TEMP" <<EOF
# HELP pgbackrest_scrape_success Indicates if the pgBackRest info scrape was successful.
# TYPE pgbackrest_scrape_success gauge
pgbackrest_scrape_success{stanza="main"} 0
EOF
          mv "$METRICS_TEMP" "$METRICS_FILE"
          exit 0 # Exit successfully so systemd timer doesn't mark as failed
        fi

        # Prepare metrics file
        cat > "$METRICS_TEMP" <<'EOF'
# HELP pgbackrest_scrape_success Indicates if the pgBackRest info scrape was successful.
# TYPE pgbackrest_scrape_success gauge
# HELP pgbackrest_repo_info Static information about pgBackRest repositories.
# TYPE pgbackrest_repo_info gauge
# HELP pgbackrest_stanza_status Stanza status code (0: ok, 1: warning, 2: error).
# TYPE pgbackrest_stanza_status gauge
# HELP pgbackrest_repo_status Repository status code (0: ok, 1: missing, 2: error).
# TYPE pgbackrest_repo_status gauge
# HELP pgbackrest_repo_size_bytes Size of the repository in bytes.
# TYPE pgbackrest_repo_size_bytes gauge
# HELP pgbackrest_backup_last_good_completion_seconds Timestamp of the last successful backup.
# TYPE pgbackrest_backup_last_good_completion_seconds gauge
# HELP pgbackrest_backup_last_duration_seconds Duration of the last successful backup in seconds.
# TYPE pgbackrest_backup_last_duration_seconds gauge
# HELP pgbackrest_backup_last_size_bytes Total size of the database for the last successful backup.
# TYPE pgbackrest_backup_last_size_bytes gauge
# HELP pgbackrest_backup_last_delta_bytes Amount of data backed up for the last successful backup.
# TYPE pgbackrest_backup_last_delta_bytes gauge
# HELP pgbackrest_wal_max_lsn The last WAL segment archived, converted to decimal for graphing.
# TYPE pgbackrest_wal_max_lsn gauge
EOF

        echo 'pgbackrest_scrape_success{stanza="main"} 1' >> "$METRICS_TEMP"

        # Repository info metrics with descriptive labels from environment
        echo "pgbackrest_repo_info{stanza=\"main\",repo_key=\"1\",repo_name=\"''${METRICS_REPO1_NAME:-repo1}\",repo_location=\"''${METRICS_REPO1_LOCATION:-unknown}\"} 1" >> "$METRICS_TEMP"
        echo "pgbackrest_repo_info{stanza=\"main\",repo_key=\"2\",repo_name=\"''${METRICS_REPO2_NAME:-repo2}\",repo_location=\"''${METRICS_REPO2_LOCATION:-unknown}\"} 1" >> "$METRICS_TEMP"

        STANZA_JSON=$(echo "$INFO_JSON" | jq '.[0]')

        # Stanza-level metrics
        STANZA_STATUS=$(echo "$STANZA_JSON" | jq '.status.code')
        echo "pgbackrest_stanza_status{stanza=\"main\"} $STANZA_STATUS" >> "$METRICS_TEMP"

        # WAL archive metrics
        MAX_WAL=$(echo "$STANZA_JSON" | jq -r '.archive[0].max // "0"')
        if [ "$MAX_WAL" != "0" ]; then
            # Convert WAL hex (e.g., 00000001000000000000000A) to decimal for basic progress monitoring
            MAX_WAL_DEC=$((16#''${MAX_WAL:8}))
            echo "pgbackrest_wal_max_lsn{stanza=\"main\"} $MAX_WAL_DEC" >> "$METRICS_TEMP"
        fi

        # Per-repo and per-backup-type metrics using a single, efficient jq command
        echo "$STANZA_JSON" | jq -r '
          # First emit repo status metrics for all repos
          (.repo[] |
            "pgbackrest_repo_status{stanza=\"main\",repo_key=\"\(.key)\"} \(.status.code)"
          ),
          # Then process backups - group by repo and type to find latest of each
          ([.backup[] | select((.type | test("full|incr")) and (.error // null) == null)] |
            group_by(.database["repo-key"], .type)[] |
            sort_by(.timestamp.start) | .[-1] |
            (
              "pgbackrest_backup_last_good_completion_seconds{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.timestamp.stop)",
              "pgbackrest_backup_last_duration_seconds{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.timestamp.stop - .timestamp.start)",
              "pgbackrest_backup_last_size_bytes{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.info.size)",
              "pgbackrest_backup_last_delta_bytes{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.info.delta)",
              "pgbackrest_repo_size_bytes{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.info.repository.size)"
            )
          )
        ' >> "$METRICS_TEMP"

        # Count failed backups
        # HELP pgbackrest_backup_failed_total Total number of failed backups found in the last info scrape.
        # TYPE pgbackrest_backup_failed_total counter
        FAILED_COUNT=$(echo "$STANZA_JSON" | jq '[.backup[] | select(.error == true)] | length')
        echo "pgbackrest_backup_failed_total{stanza=\"main\"} $FAILED_COUNT" >> "$METRICS_TEMP"

        # Atomically replace the old metrics file
        mv "$METRICS_TEMP" "$METRICS_FILE"
      '';
      after = [ "postgresql.service" "pgbackrest-stanza-create.service" "mnt-nas\\x2dpostgresql.mount" ];
      wants = [ "postgresql.service" "mnt-nas\\x2dpostgresql.mount" ];
    };

    systemd.timers.pgbackrest-metrics = {
      description = "Collect pgBackRest metrics every 15 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/15";  # Every 15 minutes
        Persistent = true;
        RandomizedDelaySec = "2m";
      };
    };

    # Configure Caddy to load environment files with API tokens and auth credentials
    systemd.services.caddy.serviceConfig = {
      EnvironmentFile = [
        "/run/secrets/rendered/caddy-env"
        "-/run/caddy/monitoring-auth.env"
      ];
    };

    # Separate service to fix Caddy certificate permissions
    # Runs on a timer to handle certificates created after Caddy startup
    systemd.services.fix-caddy-cert-permissions = {
      description = "Fix Caddy certificate directory permissions";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };
      script = ''
        set -euo pipefail

        CERT_BASE="/var/lib/caddy/.local/share/caddy/certificates"

        # Only proceed if the directory exists
        if [ -d "$CERT_BASE" ]; then
          # Set default ACLs so new files/directories automatically inherit group permissions
          # d: = default ACLs (inherited by new files/dirs)
          # g:caddy:rX = grant caddy group read + execute (for directories only)
          ${pkgs.acl}/bin/setfacl -R -d -m g:caddy:rX "$CERT_BASE" || true

          # Apply the same ACLs to existing files/directories
          ${pkgs.acl}/bin/setfacl -R -m g:caddy:rX "$CERT_BASE" || true

          # Also fix parent directories to allow traversal
          ${pkgs.coreutils}/bin/chmod 750 /var/lib/caddy/.local 2>/dev/null || true
          ${pkgs.coreutils}/bin/chmod 750 /var/lib/caddy/.local/share 2>/dev/null || true
          ${pkgs.coreutils}/bin/chmod 750 /var/lib/caddy/.local/share/caddy 2>/dev/null || true
        fi
      '';
    };

    # Timer to run permission fix periodically (every 5 minutes)
    systemd.timers.fix-caddy-cert-permissions = {
      description = "Timer for fixing Caddy certificate permissions";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        Unit = "fix-caddy-cert-permissions.service";
      };
    };

    # Create environment file from SOPS secrets
    sops.templates."caddy-env" = {
      content = ''
        CLOUDFLARE_API_TOKEN=${lib.strings.removeSuffix "\n" config.sops.placeholder."networking/cloudflare/ddns/apiToken"}
        CADDY_LOKI_ADMIN_BCRYPT=${lib.strings.removeSuffix "\n" config.sops.placeholder."services/caddy/environment/loki-admin-bcrypt"}
        PGWEB_ADMIN_BCRYPT=${lib.strings.removeSuffix "\n" config.sops.placeholder."services/caddy/environment/pgweb-admin-bcrypt"}
      '';
      owner = config.services.caddy.user;
      group = config.services.caddy.group;
    };

    # Enable persistent journald storage for log retention across reboots
    # Critical for disaster recovery operation visibility and debugging
    services.journald = {
      storage = "persistent";
      extraConfig = ''
        SystemMaxUse=500M
        RuntimeMaxUse=100M
        MaxFileSec=1month
      '';
    };

    # Fix journald startup race condition with impermanence bind mounts
    # Ensure journald waits for /var/log to be properly mounted before starting
    systemd.services.systemd-journald.unitConfig.RequiresMountsFor = [ "/var/log/journal" ];

    system.stateVersion = "25.05";  # Set to the version being installed (new system, never had 23.11)
  };
}
