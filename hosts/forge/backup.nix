{ config, ... }:

{
  config = {
    # Create restic-backup user and group
    users.users.restic-backup = {
      isSystemUser = true;
      group = "restic-backup";
      description = "Restic backup service user";
    };

    users.groups.restic-backup = {};

    # Mount NFS share from nas-1 for backups
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

    # Enable and configure the backup module
    modules.backup = {
      enable = true;

      # Configure ZFS snapshots for backup consistency
      zfs = {
        enable = true;
        pool = "rpool";
        datasets = [
          "safe/home"      # User home directories
          "safe/persist"   # System state and persistent data
          "local/nix"      # Nix store (optional, can be rebuilt)
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
        repositories = {
          nas-primary = {
            url = "/mnt/nas-backup";
            passwordFile = config.sops.secrets."restic/password".path;
            primary = true;
          };
        };

        # Define backup jobs
        jobs = {
          system = {
            enable = true;
            repository = "nas-primary";
            paths = [
              "/home"
              "/persist"
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
            repository = "nas-primary";
            paths = [ "/nix" ];
            tags = [ "nix" "forge" ];
            resources = {
              memory = "1g";
              memoryReservation = "512m";
              cpus = "1.0";
            };
          };
        };
      };

      # Enable monitoring and notifications
      monitoring = {
        enable = true;

        # Disable Prometheus metrics for now (enable when Node Exporter is set up)
        prometheus = {
          enable = false;
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
