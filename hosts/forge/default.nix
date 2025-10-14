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

    # Add postgres user to restic-backup group for R2 secret access
    # and node-exporter group for metrics file write access
    # Required for pgBackRest to read AWS credentials and write Prometheus metrics
    users.users.postgres.extraGroups = [ "restic-backup" "node-exporter" ];

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

          services = {
            # PostgreSQL data on dedicated dataset with optimized recordsize
            postgres = {
              recordsize = "8K";  # Match PostgreSQL page size for optimal performance
              compression = "lz4";
              mountpoint = "/var/lib/postgresql/16";  # Standard PostgreSQL data directory
              owner = "postgres";
              group = "postgres";
              mode = "0700";  # PostgreSQL requires 0700 permissions
              properties = {
                "com.sun:auto-snapshot" = "false";  # PostgreSQL backups via pgBackRest (application-consistent)
                logbias = "throughput";  # Optimize for database throughput over latency
                primarycache = "metadata";  # ARC caches metadata only; PostgreSQL handles data caching
                redundant_metadata = "most";  # Balance between redundancy and performance
                sync = "standard";  # Use ZIL for synchronous writes (PostgreSQL WAL)
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

          # PostgreSQL WAL archive - ZFS snapshots for fast local recovery
          # Note: PGDATA (main) is NOT snapshotted - we rely entirely on pgBackRest
          # for application-consistent, PITR-capable database backups.
          # Rationale:
          # - pgBackRest provides proper application-consistent backups
          # - ZFS snapshots of PGDATA are crash-consistent (less reliable)
          # - Reduces complexity and potential confusion during recovery
          # - WAL archive snapshots still useful for quick rollback of archive directory
                    # Removed tank/services/postgresql/main from snapshots
          # Rationale: pgBackRest provides proper application-consistent backups
          # ZFS snapshots of PGDATA are crash-consistent (less reliable)
          # For recovery, use pgBackRest exclusively

                    # Removed tank/services/postgresql/main-wal from snapshots
          # Rationale: This directory (/var/lib/postgresql/16/main-wal-archive/) is obsolete
          # pgBackRest archives WALs directly to /mnt/nas-backup/pgbackrest/archive/
          # The main-wal ZFS dataset is not being written to (last activity 7+ hours ago)
          # Safe to remove after verifying old WAL files are not needed

          # Explicitly disable snapshots on PostgreSQL dataset (rely on pgBackRest)
          "tank/services/postgresql" = {
            autosnap = false;
            autoprune = false;
            recursive = false;
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

    # pgBackRest - PostgreSQL Backup & Recovery
    # Replaces custom pg-backup-scripts with industry-standard tooling
    environment.systemPackages = [ pkgs.pgbackrest ];

    # pgBackRest configuration
    # Note: Only repo1 is in the global config because it's used for WAL archiving
    # repo2 (R2 S3) is configured via command-line flags in backup services only
    # This allows 'check' command to validate only repo1 (where WAL actually goes)
    #
    # WAL archiving strategy:
    # - Repo1 (NFS): Continuous WAL archiving for PITR
    # - Repo2 (R2): Receives WALs during backup jobs only (via --no-archive-check)
    # Trade-off: R2 has up to 1-hour RPO (limited by hourly incremental frequency)
    # Decision: Acceptable for homelab; reduces S3 API calls and complexity
    # Future consideration: Enable WAL archiving to R2 if offsite PITR becomes critical
    environment.etc."pgbackrest.conf".text = ''
      [global]
      repo1-path=/mnt/nas-backup/pgbackrest
      repo1-retention-full=7
      # Note: No differential backups (simplified schedule)

      # Archive async with local spool to decouple DB availability from NFS
      # If NFS is down, archive_command succeeds by writing to local spool
      # Background process flushes to repo1 when NFS is available
      archive-async=y
      spool-path=/var/lib/pgbackrest/spool

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

    # Temporary config for one-time stanza initialization
    # stanza-create command doesn't accept --repo flag, it operates on ALL repos in config
    # After stanzas are created in both repos, backup commands can use --repo=2 with flags
    environment.etc."pgbackrest-init.conf".text = ''
      [global]
      repo1-path=/mnt/nas-backup/pgbackrest
      repo1-retention-full=7
      repo1-retention-diff=4

      repo2-type=s3
      repo2-path=/pgbackrest
      repo2-s3-bucket=nix-homelab-prod-servers
      repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com
      repo2-s3-region=auto
      repo2-retention-full=30
      repo2-retention-diff=14

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

    # Declaratively manage pgBackRest repository directory and metrics file
    # Format: Type, Path, Mode, User, Group, Age, Argument
    # This ensures directories/files exist on boot with correct ownership/permissions
    systemd.tmpfiles.rules = [
      "d /mnt/nas-backup/pgbackrest 0750 postgres postgres - -"
      # Create local spool directory for async WAL archiving
      # Critical: Allows archive_command to succeed even when NFS is down
      "d /var/lib/pgbackrest 0750 postgres postgres - -"
      "d /var/lib/pgbackrest/spool 0750 postgres postgres - -"
      # Create pgBackRest log directory
      "d /var/log/pgbackrest 0750 postgres postgres - -"
      # Create metrics file and set ownership so postgres user can write to it
      # and node-exporter group can read it.
      "z /var/lib/node_exporter/textfile_collector/pgbackrest.prom 0644 postgres node-exporter - -"
    ];

    # pgBackRest systemd services
    systemd.services = {
      # Stanza creation (runs once at setup)
      pgbackrest-stanza-create = {
        description = "pgBackRest stanza initialization";
        after = [ "postgresql.service" "mnt-nas\\x2dbackup.mount" ];
        wants = [ "postgresql.service" "mnt-nas\\x2dbackup.mount" ];
        path = [ pkgs.pgbackrest pkgs.postgresql_16 ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          RemainAfterExit = true;
          # Load AWS credentials from SOPS secret
          EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
          # Block access to EC2 metadata service to prevent timeout
          IPAddressDeny = [ "169.254.169.254" ];
        };
        script = ''
          set -euo pipefail

          # Transform AWS env vars to pgBackRest format
          export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
          export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"

          # Directory is managed by systemd.tmpfiles.rules
          # stanza-create is idempotent - safe to run multiple times
          # It will create if missing, validate if exists, or repair if broken

          echo "[$(date -Iseconds)] Creating/validating stanza 'main' for all repositories..."
          # stanza-create doesn't accept --repo flag (error code 031)
          # It automatically operates on ALL repos defined in the config file
          # Using temporary config that includes both repo1 and repo2
          pgbackrest --config=/etc/pgbackrest-init.conf --stanza=main stanza-create

          echo "[$(date -Iseconds)] Running check with production config (repo1 only)..."
          # check validates all repos in global config (just repo1 where WAL archiving goes)
          pgbackrest --stanza=main check
        '';
        wantedBy = [ "multi-user.target" ];
      };

      # Full backup
      pgbackrest-full-backup = {
        description = "pgBackRest full backup";
        after = [ "postgresql.service" "mnt-nas\\x2dbackup.mount" "pgbackrest-stanza-create.service" ];
        wants = [ "postgresql.service" "mnt-nas\\x2dbackup.mount" ];
        path = [ pkgs.pgbackrest pkgs.postgresql_16 ];
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
          # repo2 doesn't have WAL archiving, so use --no-archive-check
          pgbackrest --stanza=main --type=full --repo=2 \
            --no-archive-check \
            --repo2-type=s3 \
            --repo2-path=/pgbackrest \
            --repo2-s3-bucket=nix-homelab-prod-servers \
            --repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com \
            --repo2-s3-region=auto \
            --repo2-retention-full=30 \
            backup
          echo "[$(date -Iseconds)] Full backup to both repos completed"
        '';
      };

      # Incremental backup
      pgbackrest-incr-backup = {
        description = "pgBackRest incremental backup";
        after = [ "postgresql.service" "mnt-nas\\x2dbackup.mount" "pgbackrest-stanza-create.service" ];
        wants = [ "postgresql.service" "mnt-nas\\x2dbackup.mount" ];
        path = [ pkgs.pgbackrest pkgs.postgresql_16 ];
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
          # repo2 doesn't have WAL archiving, so use --no-archive-check
          pgbackrest --stanza=main --type=incr --repo=2 \
            --no-archive-check \
            --repo2-type=s3 \
            --repo2-path=/pgbackrest \
            --repo2-s3-bucket=nix-homelab-prod-servers \
            --repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com \
            --repo2-s3-region=auto \
            --repo2-retention-full=30 \
            backup
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
        # Load AWS credentials from SOPS secret for repo2 access
        EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
        # Block access to EC2 metadata service to prevent timeout
        IPAddressDeny = [ "169.254.169.254" ];
      };
      script = ''
        set -euo pipefail

        METRICS_FILE="/var/lib/node_exporter/textfile_collector/pgbackrest.prom"
        METRICS_TEMP="''${METRICS_FILE}.tmp"

        # Transform AWS env vars to pgBackRest format for S3 repo access
        export PGBACKREST_REPO2_S3_KEY="''${AWS_ACCESS_KEY_ID:-}"
        export PGBACKREST_REPO2_S3_KEY_SECRET="''${AWS_SECRET_ACCESS_KEY:-}"

        # Run pgbackrest info, capturing JSON. Timeout prevents hangs on network issues.
        # Pass repo2 config via flags since it's not in global config
        # Credentials are provided via environment variables (see EnvironmentFile)
        INFO_JSON=$(timeout 300s pgbackrest --stanza=main --output=json \
          --repo2-type=s3 \
          --repo2-path=/pgbackrest \
          --repo2-s3-bucket=nix-homelab-prod-servers \
          --repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com \
          --repo2-s3-region=auto \
          info 2>&1)

        # Exit gracefully if command fails or returns empty/invalid JSON
        if ! echo "$INFO_JSON" | jq -e '.[0].name == "main"' > /dev/null; then
          echo "Failed to get valid pgBackRest info. Writing failure metric." >&2
          cat > "$METRICS_TEMP" <<EOF
# HELP pgbackrest_scrape_success Indicates if the pgBackRest info scrape was successful.
# TYPE pgbackrest_scrape_success gauge
pgbackrest_scrape_success{stanza="main",hostname="forge"} 0
EOF
          mv "$METRICS_TEMP" "$METRICS_FILE"
          exit 0 # Exit successfully so systemd timer doesn't mark as failed
        fi

        # Prepare metrics file
        cat > "$METRICS_TEMP" <<'EOF'
# HELP pgbackrest_scrape_success Indicates if the pgBackRest info scrape was successful.
# TYPE pgbackrest_scrape_success gauge
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

        echo 'pgbackrest_scrape_success{stanza="main",hostname="forge"} 1' >> "$METRICS_TEMP"

        STANZA_JSON=$(echo "$INFO_JSON" | jq '.[0]')

        # Stanza-level metrics
        STANZA_STATUS=$(echo "$STANZA_JSON" | jq '.status.code')
        echo "pgbackrest_stanza_status{stanza=\"main\",hostname=\"forge\"} $STANZA_STATUS" >> "$METRICS_TEMP"

        # WAL archive metrics
        MAX_WAL=$(echo "$STANZA_JSON" | jq -r '.archive[0].max // "0"')
        if [ "$MAX_WAL" != "0" ]; then
            # Convert WAL hex (e.g., 00000001000000000000000A) to decimal for basic progress monitoring
            MAX_WAL_DEC=$((16#''${MAX_WAL:8}))
            echo "pgbackrest_wal_max_lsn{stanza=\"main\",hostname=\"forge\"} $MAX_WAL_DEC" >> "$METRICS_TEMP"
        fi

        # Per-repo and per-backup-type metrics
        echo "$STANZA_JSON" | jq -c '.repo[]' | while read -r repo_json; do
          REPO_KEY=$(echo "$repo_json" | jq '.key')

          REPO_STATUS=$(echo "$repo_json" | jq '.status.code')
          echo "pgbackrest_repo_status{stanza=\"main\",repo_key=$REPO_KEY,hostname=\"forge\"} $REPO_STATUS" >> "$METRICS_TEMP"

          for backup_type in full diff incr; do
            LAST_BACKUP_JSON=$(echo "$STANZA_JSON" | jq \
              --argjson repo_key "$REPO_KEY" \
              --arg backup_type "$backup_type" \
              '[.backup[] | select(.database["repo-key"] == $repo_key and .type == $backup_type and .error == false)] | sort_by(.timestamp.start) | .[-1] // empty')

            if [ -n "$LAST_BACKUP_JSON" ] && [ "$LAST_BACKUP_JSON" != "null" ]; then
              LAST_COMPLETION=$(echo "$LAST_BACKUP_JSON" | jq '.timestamp.stop')
              START_TIME=$(echo "$LAST_BACKUP_JSON" | jq '.timestamp.start')
              DURATION=$((LAST_COMPLETION - START_TIME))
              DB_SIZE=$(echo "$LAST_BACKUP_JSON" | jq '.info.size')
              DELTA_SIZE=$(echo "$LAST_BACKUP_JSON" | jq '.info.delta')
              REPO_SIZE=$(echo "$LAST_BACKUP_JSON" | jq '.info.repository.size')

              echo "pgbackrest_backup_last_good_completion_seconds{stanza=\"main\",repo_key=$REPO_KEY,type=\"$backup_type\",hostname=\"forge\"} $LAST_COMPLETION" >> "$METRICS_TEMP"
              echo "pgbackrest_backup_last_duration_seconds{stanza=\"main\",repo_key=$REPO_KEY,type=\"$backup_type\",hostname=\"forge\"} $DURATION" >> "$METRICS_TEMP"
              echo "pgbackrest_backup_last_size_bytes{stanza=\"main\",repo_key=$REPO_KEY,type=\"$backup_type\",hostname=\"forge\"} $DB_SIZE" >> "$METRICS_TEMP"
              echo "pgbackrest_backup_last_delta_bytes{stanza=\"main\",repo_key=$REPO_KEY,type=\"$backup_type\",hostname=\"forge\"} $DELTA_SIZE" >> "$METRICS_TEMP"
              echo "pgbackrest_repo_size_bytes{stanza=\"main\",repo_key=$REPO_KEY,type=\"$backup_type\",hostname=\"forge\"} $REPO_SIZE" >> "$METRICS_TEMP"
            fi
          done
        done

        # Atomically replace the old metrics file
        mv "$METRICS_TEMP" "$METRICS_FILE"
      '';
      after = [ "postgresql.service" "pgbackrest-stanza-create.service" "mnt-nas\\x2dbackup.mount" ];
      wants = [ "postgresql.service" ];
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

    # Configure Caddy to load environment file with Cloudflare API token
    systemd.services.caddy.serviceConfig.EnvironmentFile = "/run/secrets/rendered/caddy-env";

    # Create environment file from SOPS secrets
    sops.templates."caddy-env" = {
      content = ''
        CLOUDFLARE_API_TOKEN=${lib.strings.removeSuffix "\n" config.sops.placeholder."networking/cloudflare/ddns/apiToken"}
      '';
      owner = config.services.caddy.user;
      group = config.services.caddy.group;
    };

    system.stateVersion = "25.05";  # Set to the version being installed (new system, never had 23.11)
  };
}
