{ lib, config, pkgs, ... }:

{
  imports = [
    # Hardware & Disk Configuration
    (import ./disko-config.nix {
      disks = [ "/dev/disk/by-id/nvme-Samsung_SSD_950_PRO_512GB_S2GMNX0H803986M" "/dev/disk/by-id/nvme-WDS100T3X0C-00SJG0_200278801343" ];
      inherit lib;  # Pass lib here
    })
    ../../profiles/hardware/intel-gpu.nix

    # Core System Configuration
    ./core/networking.nix
    ./core/boot.nix
    ./core/users.nix
    ./core/packages.nix
    ./core/hardware.nix

    # Infrastructure (Cross-cutting operational concerns)
    ./infrastructure/backup.nix
    ./infrastructure/storage.nix      # ZFS storage management and Sanoid templates
    ./infrastructure/monitoring-ui.nix
    ./infrastructure/observability  # Prometheus, Alertmanager, Grafana, Loki, Promtail

    # Secrets
    ./secrets.nix

    # Application Services
    ./services/postgresql.nix      # PostgreSQL database
    ./services/pgbackrest.nix      # pgBackRest PostgreSQL backup system
    ./services/dispatcharr.nix     # Dispatcharr service
    ./services/plex.nix            # Plex media server
    ./services/uptime-kuma.nix     # Uptime monitoring and status page
    ./services/ups.nix             # UPS monitoring configuration
    ./services/pgweb.nix           # PostgreSQL web management interface
    ./services/authelia.nix        # SSO authentication service
    ./services/qui.nix             # qui - Modern qBittorrent web interface with OIDC
    ./services/cloudflare-tunnel.nix  # Cloudflare Tunnel for external access
    ./services/sonarr.nix          # Sonarr TV series management
    ./services/prowlarr.nix        # Prowlarr indexer manager
    ./services/radarr.nix          # Radarr movie manager
    ./services/bazarr.nix          # Bazarr subtitle manager
    ./services/recyclarr.nix       # Recyclarr TRaSH guides automation
    ./services/qbittorrent.nix     # qBittorrent download client
    ./services/cross-seed.nix      # cross-seed torrent automation
    ./services/tqm.nix             # tqm torrent lifecycle management
    ./services/qbit-manage.nix     # qbit-manage (DISABLED - migrated to tqm)
    ./services/sabnzbd.nix         # SABnzbd usenet downloader
    ./services/overseerr.nix       # Overseerr media request management
    ./services/autobrr.nix         # Autobrr IRC announce bot
    ./services/profilarr.nix       # Profilarr profile sync for *arr services
    ./services/tdarr.nix           # Tdarr transcoding automation
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.30";

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

          # qBittorrent container service down
          "qbittorrent-service-down" = {
            type = "promql";
            alertname = "QbittorrentServiceDown";
            expr = ''
              container_service_active{service="qbittorrent"} == 0
            '';
            for = "2m";
            severity = "high";
            labels = { service = "qbittorrent"; category = "container"; };
            annotations = {
              summary = "qBittorrent service is down on {{ $labels.instance }}";
              description = "Torrent download client is not running. Check: systemctl status podman-qbittorrent.service";
              command = "systemctl status podman-qbittorrent.service && journalctl -u podman-qbittorrent.service --since '30m'";
            };
          };

          # SABnzbd container service down
          "sabnzbd-service-down" = {
            type = "promql";
            alertname = "SabnzbdServiceDown";
            expr = ''
              container_service_active{service="sabnzbd"} == 0
            '';
            for = "2m";
            severity = "high";
            labels = { service = "sabnzbd"; category = "container"; };
            annotations = {
              summary = "SABnzbd service is down on {{ $labels.instance }}";
              description = "Usenet download client is not running. Check: systemctl status podman-sabnzbd.service";
              command = "systemctl status podman-sabnzbd.service && journalctl -u podman-sabnzbd.service --since '30m'";
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
          localPath = "/mnt/data";  # Mount point for shared NAS data (contains media/, backups/, etc.)
          group = "media";
          mode = "02775";  # setgid bit ensures new files inherit media group
          mountOptions = [ "nfsvers=4.2" "timeo=60" "retry=5" "rw" "noatime" ];
        };
      };

      # Podman containerization with DNS-enabled networking
      virtualization.podman = {
        enable = true;
        networks = {
          "media-services" = {
            driver = "bridge";
            # DNS resolution is enabled by default for bridge networks
            # Containers on this network can reach each other by container name
          };
        };
      };

      # ZFS snapshot and replication management now configured in infrastructure/storage.nix
      # and distributed across service files (contribution pattern)
      # Service-specific Sanoid configs: observability/*.nix, services/*.nix

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

      # Media management services
      # Sonarr configuration moved to ./services/sonarr.nix
      # Prowlarr configuration moved to ./services/prowlarr.nix
      # Radarr configuration moved to ./services/radarr.nix
      # Bazarr configuration moved to ./services/bazarr.nix
      # Recyclarr configuration moved to ./services/recyclarr.nix

      # Download clients and torrent tools
      # qBittorrent configuration moved to ./services/qbittorrent.nix
      # cross-seed configuration moved to ./services/cross-seed.nix
      # tqm configuration moved to ./services/tqm.nix
      # qbit-manage configuration moved to ./services/qbit-manage.nix
      # SABnzbd configuration moved to ./services/sabnzbd.nix
      # Overseerr configuration moved to ./services/overseerr.nix
      # Autobrr configuration moved to ./services/autobrr.nix
      # Profilarr configuration moved to ./services/profilarr.nix
      # Tdarr configuration moved to ./services/tdarr.nix

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
          # media group now defined at top level with GID 65537 for *arr services
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
    # pgBackRest PostgreSQL backup system - configuration moved to ./services/pgbackrest.nix
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
