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
    ./qui.nix            # qui - Modern qBittorrent web interface with OIDC
    ./cloudflare-tunnel.nix  # Cloudflare Tunnel for external access
    ./services/sonarr.nix    # Sonarr TV series management
    ./services/prowlarr.nix  # Prowlarr indexer manager
    ./services/radarr.nix    # Radarr movie manager
    ./services/bazarr.nix      # Bazarr subtitle manager
    ./services/recyclarr.nix   # Recyclarr TRaSH guides automation
    ./services/qbittorrent.nix # qBittorrent download client
    ./services/cross-seed.nix  # cross-seed torrent automation
    ./services/tqm.nix         # tqm torrent lifecycle management
    ./services/qbit-manage.nix # qbit-manage (DISABLED - migrated to tqm)
    ./services/sabnzbd.nix     # SABnzbd usenet downloader
    ./services/overseerr.nix   # Overseerr media request management
    ./services/autobrr.nix     # Autobrr IRC announce bot
    ./services/profilarr.nix   # Profilarr profile sync for *arr services
    ./services/tdarr.nix       # Tdarr transcoding automation
    ./services/pgbackrest.nix  # pgBackRest PostgreSQL backup system
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

    # Shared media group for *arr services and download clients
    # Shared media group for *arr services
    # GID 65537 (993 was taken by alertmanager)
    users.groups.media = {
      gid = 65537;
    };

    # Add postgres user to restic-backup group for R2 secret access
    # and node-exporter group for metrics file write access
    # Required for pgBackRest to read AWS credentials and write Prometheus metrics
    users.users.postgres.extraGroups = [ "restic-backup" "node-exporter" ];

    # Add restic-backup user to media group for backup access
    # Media services (sonarr, radarr, bazarr, prowlarr, qbittorrent, recyclarr, etc.)
    # all run as group "media" (GID 65537) with 0750 directory permissions
    # Also add monitoring service groups (grafana, loki, promtail)
    users.users.restic-backup.extraGroups = [
      "media"      # All *arr services, qbittorrent, recyclarr, etc.
      "grafana"    # Grafana dashboards and database
      "loki"       # Loki log storage
      "promtail"   # Promtail positions file
    ];

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

          # qBittorrent torrent download client configuration data
          # Enable snapshots and replication for application settings
          # NOTE: Downloads are NOT backed up (transient data on NFS)
          "tank/services/qbittorrent" = {
            useTemplate = [ "services" ];
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/qbittorrent";
              sendOptions = "wp";
              recvOptions = "u";
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # SABnzbd usenet download client configuration data
          # Enable snapshots and replication for application settings
          # NOTE: Downloads are NOT backed up (transient data on NFS)
          "tank/services/sabnzbd" = {
            useTemplate = [ "services" ];
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/sabnzbd";
              sendOptions = "wp";
              recvOptions = "u";
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
              targetName = "NFS";
              targetLocation = "nas-1";
            };
          };

          # cross-seed automatic cross-seeding daemon
          # Stores cache database and generated torrent files
          "tank/services/cross-seed" = {
            useTemplate = [ "services" ];
            recursive = false;
            autosnap = true;
            autoprune = true;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/zfs-recv/cross-seed";
              sendOptions = "wp";
              recvOptions = "u";
              hostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
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
              restoreMethods = [ "syncoid" "local" ]; # Restic excluded: preserve ZFS lineage, use only for manual DR
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
              restoreMethods = [ "syncoid" "local" ]; # Restic excluded: preserve ZFS lineage, use only for manual DR
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
