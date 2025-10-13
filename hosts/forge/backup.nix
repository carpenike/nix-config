{ config, ... }:

# Forge Backup Configuration
#
# This configuration integrates PostgreSQL into the existing Restic-based backup system
# instead of using pgBackRest, leveraging our sophisticated backup infrastructure.
#
# Key Decision: Extend Restic vs Add pgBackRest
# After critical evaluation (see conversation with Gemini Pro), we chose to extend
# our existing Restic system because:
# 1. We already have PITR-compliant PostgreSQL snapshots (pg-backup-scripts)
# 2. Unified operational model: single dashboard, alerting, verification
# 3. Existing monitoring/notifications/verification infrastructure
# 4. Monthly restore testing already validates end-to-end recovery
# 5. Simpler to operate: add 1 repo + 1 job vs entire new tool stack
#
# PostgreSQL Backup Strategy:
# - Local: ZFS snapshots every 5 minutes via pg-zfs-snapshot.service
# - Local DR: Syncoid replication to nas-1 every 15 minutes
# - Offsite DR: Restic to Cloudflare R2 (this file)
#
# PITR Recovery Process from R2:
# 1. restic restore <snapshot_id> --target /var/lib/postgresql/16/main
# 2. restic restore latest --target /tmp/wal --include /var/lib/postgresql/16/main-wal-archive
# 3. Create recovery.signal in PGDATA
# 4. Set restore_command and recovery_target_time in postgresql.conf
# 5. Start PostgreSQL
#
# Setup Requirements:
# 1. Create Cloudflare R2 bucket: "nix-homelab-backups"
# 2. Generate R2 API token (read/write access)
# 3. Add to secrets.sops.yaml:
#    restic/r2-env: |
#      AWS_ACCESS_KEY_ID=<your_key>
#      AWS_SECRET_ACCESS_KEY=<your_secret>
# 4. Deploy configuration and verify first backup succeeds

let
  # Reference centralized primary backup repository config from default.nix
  # See hosts/forge/default.nix for the single source of truth
  primaryRepoName = "nas-primary";
  primaryRepoUrl = "/mnt/nas-backup";
  primaryRepoPasswordFile = config.sops.secrets."restic/password".path;
in
{
  config = {
    # Create restic-backup user and group
    users.users.restic-backup = {
      isSystemUser = true;
      group = "restic-backup";
      description = "Restic backup service user";
    };

    users.groups.restic-backup = {};

    # Mount NFS shares from nas-1 for backups
    fileSystems."/mnt/nas-backup" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/restic";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"  # Unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s"
      ];
    };

    fileSystems."/mnt/nas-docs" = {
      device = "nas-1.holthome.net:/mnt/backup/forge/docs";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rw"
        "noatime"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"  # Unmount after 10 minutes idle
        "x-systemd.mount-timeout=30s"
      ];
    };

    # Enable and configure the backup module
    modules.backup = {
      enable = true;

      # Configure ZFS snapshots for backup consistency (multi-pool support)
      zfs = {
        enable = true;
        pools = [
          # Boot pool datasets
          {
            pool = "rpool";
            datasets = [
              "safe/home"      # User home directories
              "safe/persist"   # System state and persistent data
              # local/nix excluded - fully reproducible from NixOS configuration
            ];
          }
          # Service data pool
          {
            pool = "tank";
            datasets = [
              "services/sonarr"           # Sonarr media management service
              "services/postgresql/main"  # PostgreSQL PGDATA (PITR-compliant snapshots via pg-zfs-snapshot)
              "services/postgresql/main-wal"  # PostgreSQL WAL archive for point-in-time recovery
            ];
          }
        ];
        retention = {
          daily = 7;
          weekly = 4;
          monthly = 3;
        };
      };

      # Configure Restic backups
      restic = {
        enable = true;

        globalSettings = {
          compression = "auto";
          readConcurrency = 2;
          retention = {
            daily = 14;
            weekly = 8;
            monthly = 6;
            yearly = 2;
          };
        };

        # Define backup repositories
        # Note: Repository details defined inline from config.sops.secrets to avoid _module.args circular dependency
        repositories = {
          ${primaryRepoName} = {
            url = primaryRepoUrl;
            passwordFile = primaryRepoPasswordFile;
            primary = true;
          };

          # Cloudflare R2 for offsite geographic redundancy
          # Zero egress fees make restore testing and actual DR affordable
          #
          # Bucket Organization: Per-Environment Strategy
          # - production-servers: forge, luna, nas-1 (critical infrastructure)
          # - edge-devices: nixpi (monitoring/edge services)
          # - workstations: rydev, rymac (development machines)
          #
          # Security: Each bucket has scoped API token (least privilege)
          # - Compromised workstation cannot access server backups
          # - Separate credentials per environment tier
          r2-offsite = {
            url = "s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge";
            passwordFile = primaryRepoPasswordFile;  # Reuse same Restic encryption password
            environmentFile = config.sops.secrets."restic/r2-prod-env".path;  # Production bucket credentials
            primary = false;  # Secondary repository for DR
          };
        };

        # Define backup jobs
        jobs = {
          system = {
            enable = true;
            repository = primaryRepoName;
            paths = [
              "/home"
              "/persist"
              "/var/lib/backup-docs"  # Backup the documentation for DR
            ];
            excludePatterns = [
              # Exclude cache directories
              "**/.cache"
              "**/.local/share/Trash"
              "**/Cache"
              "**/cache"
              # Exclude build artifacts
              "**/.direnv"
              "**/result"
              "**/target"
              "**/node_modules"
              # Exclude temporary files
              "**/*.tmp"
              "**/*.temp"
            ];
            tags = [ "system" "forge" "nixos" ];
            resources = {
              memory = "512m";
              memoryReservation = "256m";
              cpus = "1.0";
            };
          };

          nix-store = {
            enable = false;  # Optional: enable if you want to backup Nix store
            repository = primaryRepoName;
            paths = [ "/nix" ];
            tags = [ "nix" "forge" ];
            resources = {
              memory = "1g";
              memoryReservation = "512m";
              cpus = "1.0";
            };
          };

          # PostgreSQL offsite backup to Cloudflare R2
          # Leverages existing ZFS snapshot coordination via backup.zfs.pools
          # pg-zfs-snapshot.service already ensures PITR-compliant snapshots with backup_label
          # Restic backs up: PGDATA + WAL archive for complete point-in-time recovery
          postgresql-offsite = {
            enable = true;
            repository = "r2-offsite";
            paths = [
              "/var/lib/postgresql/16"  # Includes both main and main-wal-archive subdirectories
            ];
            excludePatterns = [
              # Exclude PostgreSQL runtime files that don't need backup
              "**/postmaster.pid"
              "**/postmaster.opts"
              # Exclude temporary files
              "**/*.tmp"
              "**/pgsql_tmp/*"
            ];
            tags = [ "postgresql" "database" "pitr" "offsite" ];
            resources = {
              memory = "512m";
              memoryReservation = "256m";
              cpus = "0.5";
            };
          };
        };
      };

      # Enable monitoring and notifications
      monitoring = {
        enable = true;

        # Enable Prometheus metrics via Node Exporter textfile collector
        prometheus = {
          enable = true;
          metricsDir = "/var/lib/node_exporter/textfile_collector";
        };

        # Error analysis
        errorAnalysis = {
          enable = true;
        };

        logDir = "/var/log/backup";
      };

      # Enable automated verification
      verification = {
        enable = true;
        schedule = "weekly";
        checkData = false;  # Set to true for thorough data verification (slow)
        checkDataSubset = "5%";
      };

      # Enable restore testing
      restoreTesting = {
        enable = true;
        schedule = "monthly";
        sampleFiles = 5;
        testDir = "/tmp/restore-tests";
      };

      # Performance settings
      performance = {
        cacheDir = "/var/cache/restic";
        cacheSizeLimit = "5G";
        ioScheduling = {
          enable = true;
          ioClass = "idle";
          priority = 7;
        };
      };

      # Enable documentation generation
      documentation = {
        enable = true;
        outputDir = "/var/lib/backup-docs";
      };

      # Backup schedule
      schedule = "daily";
    };
  };
}
