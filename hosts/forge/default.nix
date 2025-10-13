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
    ./postgresql.nix
    ./dispatcharr.nix
  ];

  config = {
    # Primary IP for DNS record generation
    my.hostIp = "10.20.0.30";

    networking = {
      hostName = hostname;
      hostId = "1b3031e7";  # Preserved from nixos-bootstrap
      useDHCP = true;
      firewall.enable = false;
      domain = "holthome.net";
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
        ]
        ++ ifGroupsExist [
          "network"
        ];
    };
    users.groups.ryan = {
      gid = 1000;
    };

    system.activationScripts.postActivation.text = ''
      # Must match what is in /etc/shells
      chsh -s /run/current-system/sw/bin/fish ryan
    '';

    modules = {
      # Explicitly enable ZFS filesystem module
      filesystems.zfs = {
        enable = true;
        mountPoolsAtBoot = [ "rpool" "tank" ];
        # Use default rpool/safe/persist for system-level /persist
      };

      # Storage dataset management
      # forge uses the tank pool (2x NVME) for service data
      # tank/services acts as a logical parent (not mounted)
      # Individual services mount to standard FHS paths
      storage = {
        datasets = {
          enable = true;
          parentDataset = "tank/services";
          parentMount = "/srv";  # Fallback for services without explicit mountpoint
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
            };
          };

          # Service data - all *arr services and their data
          "tank/services" = {
            useTemplate = [ "services" ];
            recursive = true;  # Snapshot all child datasets (sonarr, radarr, etc.)
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/services";
              sendOptions = "wp";  # w = raw send, p = preserve properties (recordsize, compression, etc.)
              recvOptions = "u";
            };
          };

          # PostgreSQL data directory - high-frequency snapshots with pg_backup coordination
          # Snapshots are handled by a dedicated systemd service to ensure the database
          # connection is held open, which is required for pg_backup_start.
          # Sanoid is configured to NOT snapshot this dataset directly, but it WILL
          # still manage pruning of the snapshots created by our custom service.
          "tank/services/postgresql/main" = {
            useTemplate = [ "wal-frequent" ]; # For pruning policy
            recursive = false;
            autosnap = false; # IMPORTANT: Handled by pg-zfs-snapshot.service
            autoprune = true; # Sanoid will still prune snapshots
            # pre/post snapshot scripts are removed.
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/services/postgresql/main";
              sendOptions = "wp";
              recvOptions = "u";
            };
          };

          # PostgreSQL WAL archive - high-frequency snapshots for PITR
          # Override the parent template with more frequent snapshots
          # This provides 5-minute RPO for database recovery
          "tank/services/postgresql/main-wal" = {
            useTemplate = [ "wal-frequent" ];
            recursive = false;
            replication = {
              targetHost = "nas-1.holthome.net";
              targetDataset = "backup/forge/services/postgresql/main-wal";
              sendOptions = "wp";
              recvOptions = "u";
            };
          };
        };

        # Monitor pool health and alert on degradation
        healthChecks = {
          enable = true;
          interval = "15min";
        };
      };

      system.impermanence.enable = true;

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
        backup = {
          enable = true;
          repository = "nas-primary";  # Primary NFS backup repository
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

    # Boot-time check for stale backup_label before PostgreSQL starts
    systemd.services.pg-check-stale-backup-label = {
      description = "Check for stale PostgreSQL backup_label before startup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.pg-backup-scripts}/bin/pg-check-stale-backup-label";
        RemainAfterExit = true;
      };
      # Run before PostgreSQL starts, after ZFS mounts
      before = [ "postgresql.service" ];
      after = [ "zfs-mount.service" ];
      wantedBy = [ "multi-user.target" ];
    };

    # Custom service for taking application-consistent PostgreSQL snapshots
    systemd.services.pg-zfs-snapshot = {
      description = "Take coordinated ZFS snapshots of PostgreSQL";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${pkgs.pg-backup-scripts}/bin/pg-zfs-snapshot tank/services/postgresql/main";
      };
      # Ensure postgres and zfs are ready
      after = [ "postgresql.service" "zfs-mount.service" ];
      wants = [ "postgresql.service" "zfs-mount.service" ];
    };

    systemd.timers.pg-zfs-snapshot = {
      description = "Run coordinated PostgreSQL ZFS snapshot every 5 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/5";
        Persistent = true; # Run on next boot if a run was missed
      };
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
            echo "zfs_snapshot_count{dataset=\"$dataset\",hostname=\"forge\"} $SNAPSHOT_COUNT" >> "$METRICS_TEMP"
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
              echo "zfs_snapshot_latest_timestamp{dataset=\"$dataset\",hostname=\"forge\"} $LATEST_TIMESTAMP" >> "$METRICS_TEMP"
            fi
          done

          # Add total space used by all snapshots per dataset
          cat >> "$METRICS_TEMP" <<'HEADER3'

# HELP zfs_snapshot_total_used_bytes Total space used by all snapshots for a dataset
# TYPE zfs_snapshot_total_used_bytes gauge
HEADER3

          for dataset in "''${DATASETS[@]}"; do
            TOTAL_USED=$(${pkgs.zfs}/bin/zfs list -Hp -t snapshot -o used -r "$dataset" 2>/dev/null | ${pkgs.gawk}/bin/awk '{sum+=$1} END {print sum}' || echo 0)
            echo "zfs_snapshot_total_used_bytes{dataset=\"$dataset\",hostname=\"forge\"} $TOTAL_USED" >> "$METRICS_TEMP"
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

    system.stateVersion = "25.05";  # Set to the version being installed (new system, never had 23.11)
  };
}
