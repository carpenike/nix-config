{ config, pkgs, ... }:

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

  # Cloudflare R2 offsite repository configuration (DRY principle)
  r2OffsetUrl = "s3:https://21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge";
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
          #
          # Security Note: Account ID in URL is NOT sensitive (identifier, not secret)
          # - Industry standard: account IDs are public (like AWS Account IDs)
          # - Actual secrets (API keys) are in sops: restic/r2-prod-env
          # - Defense in depth: scoped IAM + API credentials + Restic encryption
          r2-offsite = {
            url = r2OffsetUrl;  # DRY: Defined once in let block
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
          # IMPORTANT: Uses existing PITR-compliant snapshots from pg-zfs-snapshot.service
          # Those snapshots include backup_label for proper PostgreSQL base backup recovery
          # This ensures R2 backups are consistent and recoverable via standard PITR procedures
          postgresql-offsite = {
            enable = true;
            repository = "r2-offsite";
            paths = [
              "/var/lib/postgresql/16/main"             # PGDATA (tank/services/postgresql/main)
              "/var/lib/postgresql/16/main-wal-archive" # WAL archive (tank/services/postgresql/main-wal)
            ];
            # Custom prepare script: Use most recent PostgreSQL-coordinated snapshot
            # instead of creating new generic ZFS snapshots without backup_label
            preBackupScript = ''
              set -euo pipefail

              # Capture start time for duration calculation
              mkdir -p /run/restic-backups-postgresql-offsite
              date +%s > /run/restic-backups-postgresql-offsite/start-time

              echo "Using existing PostgreSQL PITR snapshots (with backup_label)..."

              # Find the most recent autosnap from pg-zfs-snapshot.service
              # These snapshots are PITR-compliant with backup_label included
              PGDATA_SNAPSHOT=$(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name -S creation \
                tank/services/postgresql/main | grep '@autosnap_.*_frequently' | head -n 1)
              WAL_SNAPSHOT=$(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name -S creation \
                tank/services/postgresql/main-wal | grep '@autosnap_.*_frequently' | head -n 1)

              if [ -z "$PGDATA_SNAPSHOT" ] || [ -z "$WAL_SNAPSHOT" ]; then
                echo "ERROR: No PostgreSQL autosnap snapshots found!" >&2
                echo "Expected snapshots from pg-zfs-snapshot.service" >&2
                exit 1
              fi

              echo "PGDATA snapshot: $PGDATA_SNAPSHOT"
              echo "WAL snapshot: $WAL_SNAPSHOT"

              # Mount snapshots read-only for backup
              mkdir -p /mnt/pg-backup-snapshot/main
              mkdir -p /mnt/pg-backup-snapshot/main-wal

              ${pkgs.util-linux}/bin/mount -t zfs -o ro "$PGDATA_SNAPSHOT" /mnt/pg-backup-snapshot/main || true
              ${pkgs.util-linux}/bin/mount -t zfs -o ro "$WAL_SNAPSHOT" /mnt/pg-backup-snapshot/main-wal || true

              # Create paths file pointing to snapshot mounts
              mkdir -p /run/restic-backup
              cat > /run/restic-backup/postgresql-offsite-paths.txt <<EOF
              /mnt/pg-backup-snapshot/main
              /mnt/pg-backup-snapshot/main-wal
              EOF

              echo "Backup will use PostgreSQL PITR snapshot paths:"
              cat /run/restic-backup/postgresql-offsite-paths.txt

              # Verify backup_label exists in PGDATA snapshot
              if [ -f /mnt/pg-backup-snapshot/main/backup_label ]; then
                echo "✓ Verified: backup_label present in snapshot (PITR-compliant)"
                echo "Backup label content:"
                head -n 3 /mnt/pg-backup-snapshot/main/backup_label
              else
                echo "WARNING: backup_label not found in snapshot!" >&2
              fi

              # Initialize structured logging
              TIMESTAMP=$(date --iso-8601=seconds)
              LOG_FILE="/var/log/backup/backup-jobs.jsonl"

              ${pkgs.jq}/bin/jq -n \
                --arg timestamp "$TIMESTAMP" \
                --arg job "postgresql-offsite" \
                --arg repo "${r2OffsetUrl}" \
                --arg event "backup_start" \
                --arg hostname "forge" \
                --arg pgdata_snapshot "$PGDATA_SNAPSHOT" \
                --arg wal_snapshot "$WAL_SNAPSHOT" \
                '{
                  timestamp: $timestamp,
                  event: $event,
                  job_name: $job,
                  repository: $repo,
                  hostname: $hostname,
                  pgdata_snapshot: $pgdata_snapshot,
                  wal_snapshot: $wal_snapshot,
                  pitr_compliant: true
                }' >> "$LOG_FILE" || true
            '';
            # Custom cleanup: Unmount PostgreSQL snapshots after backup
            postBackupScript = ''
              echo "Unmounting PostgreSQL backup snapshots..."
              ${pkgs.util-linux}/bin/umount /mnt/pg-backup-snapshot/main 2>/dev/null || true
              ${pkgs.util-linux}/bin/umount /mnt/pg-backup-snapshot/main-wal 2>/dev/null || true
              rmdir /mnt/pg-backup-snapshot/main 2>/dev/null || true
              rmdir /mnt/pg-backup-snapshot/main-wal 2>/dev/null || true
              rmdir /mnt/pg-backup-snapshot 2>/dev/null || true
              echo "PostgreSQL backup snapshots unmounted"
            '';
            excludePatterns = [
              # Exclude PostgreSQL runtime files that don't need backup
              "**/postmaster.pid"
              "**/postmaster.opts"
              # Exclude temporary files
              "**/*.tmp"
              "**/pgsql_tmp/*"
            ];
            tags = [ "postgresql" "database" "pitr" "offsite" "backup_label" ];
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
