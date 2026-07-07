{ ... }:

{
  config = {
    # Promtail log shipping and aggregation agent
    # Configured directly on the individual module (not through observability meta-module)
    modules.services.promtail = {
      enable = true;

      # ZFS configuration
      zfs = {
        dataset = "tank/services/promtail";
        properties = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "false"; # Snapshots disabled for Promtail
        };
      };

      # Container log source configuration
      containers = {
        enable = true;
        source = "journald"; # Use systemd journal for container logs
      };

      # Journal configuration with noise reduction
      journal = {
        enable = true;
        maxAge = "12h";
        dropIdentifiers = [
          "systemd-logind"
          "systemd-networkd"
          "systemd-resolved"
          "systemd-timesyncd"
          "NetworkManager"
          "sshd" # Add sshd to reduce noise from frequent SSH connections
        ];
        labels = {
          job = "systemd-journal";
          host = "forge";
          environment = "homelab";
        };

        # Log-derived metrics for NFS soft-mount timeout detection.
        # /mnt/data is deliberately a soft NFS mount (see infrastructure/storage.nix)
        # so a hung NAS returns EIO instead of freezing the host — but those EIOs
        # can silently corrupt downloads. The kernel logs
        # "nfs: server nas.holthome.net not responding" on each timeout; count
        # them into a Prometheus counter exposed on Promtail's /metrics
        # (promtail_custom_nfs_server_not_responding_total), consumed by the
        # NFSSoftMountTimeouts alert in infrastructure/storage.nix.
        extraPipelineStages = [
          {
            match = {
              selector = ''{job="systemd-journal"} |~ "nfs: server .* not responding"'';
              stages = [
                {
                  metrics.nfs_server_not_responding_total = {
                    type = "Counter";
                    description = "Kernel NFS 'server not responding' messages (soft-mount timeouts, potential EIO to writers)";
                    # Keep the series alive well past the incident (default idle
                    # eviction is 5m, which would hide isolated timeouts)
                    max_idle_duration = "24h";
                    config = {
                      match_all = true;
                      action = "inc";
                    };
                  };
                }
              ];
            };
          }
        ];
      };

      # Disable syslog receiver to avoid duplicates (we tail files instead)
      syslog.enable = false;

      # Extra scrape configs for Omada relay logs
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

    # ZFS snapshot and replication configuration for Promtail dataset
    # NOTE (Gemini Pro 2.5 validated): Snapshots/replication DISABLED for Promtail
    # Rationale:
    # - Promtail stores live operational state (positions.yaml, wal/) that becomes stale instantly
    # - Restoring stale state causes permanent log LOSS (skips recent logs)
    # - Starting fresh causes duplication (annoying but self-recovering)
    # - In DR: provision new empty dataset, do NOT restore from snapshots
    # - Persistent storage still REQUIRED for normal operation
    modules.backup.sanoid.datasets."tank/services/promtail" = {
      autosnap = false; # Disable snapshots per Gemini Pro recommendation
      autoprune = false;
      recursive = false;
      # No replication - state should not be preserved in DR scenarios
    };
  };
}
