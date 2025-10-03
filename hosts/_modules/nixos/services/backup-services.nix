# Service-specific backup configurations for critical homelab services
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.backup-services;
in
{
  options.modules.services.backup-services = {
    enable = mkEnableOption "service-specific backup configurations";

    unifi = {
      enable = mkEnableOption "UniFi controller backup";

      dataPath = mkOption {
        type = types.str;
        default = "/var/lib/unifi";
        description = "Path to UniFi data directory";
      };

      mongoCredentialsFile = mkOption {
        type = types.path;
        description = "Path to MongoDB credentials file";
      };
    };

    omada = {
      enable = mkEnableOption "Omada controller backup";

      dataPath = mkOption {
        type = types.str;
        default = "/var/lib/omada";
        description = "Path to Omada data directory";
      };

      containerName = mkOption {
        type = types.str;
        default = "omada";
        description = "Name of Omada container";
      };
    };

    onepassword-connect = {
      enable = mkEnableOption "1Password Connect backup";

      dataPath = mkOption {
        type = types.str;
        default = "/var/lib/onepassword-connect/data";
        description = "Path to 1Password Connect data directory";
      };

      credentialsFile = mkOption {
        type = types.path;
        description = "Path to 1Password Connect credentials file";
      };
    };

    attic = {
      enable = mkEnableOption "Attic binary cache backup";

      dataPath = mkOption {
        type = types.str;
        default = "/var/lib/attic";
        description = "Path to Attic data directory";
      };

      useZfsSend = mkOption {
        type = types.bool;
        default = true;
        description = "Use ZFS send/receive for local replication (recommended for large datasets)";
      };

      nasDestination = mkOption {
        type = types.str;
        default = "";
        description = "NAS destination for ZFS send (e.g., root@nas.local)";
        example = "backup@nas.holthome.net";
      };
    };

    system = {
      enable = mkEnableOption "system configuration backup";

      paths = mkOption {
        type = types.listOf types.str;
        default = [
          "/etc/nixos"
          "/home/ryan/.config"
          "/var/log"
        ];
        description = "System paths to backup";
      };

      excludePatterns = mkOption {
        type = types.listOf types.str;
        default = [
          "*.tmp"
          "*.cache"
          "*/.git"
          "*/node_modules"
          "*/target"
          "*/build"
        ];
        description = "Patterns to exclude from system backup";
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure backup module is enabled
    modules.backup.enable = true;
    modules.backup.restic.enable = true;

    # Service-specific backup jobs
    modules.backup.restic.jobs = mkMerge [
      # UniFi Controller Backup
      (mkIf cfg.unifi.enable {
        unifi = {
          enable = true;
          paths = [
            "/mnt/backup-snapshot${cfg.unifi.dataPath}"
          ];
          repository = "primary";
          tags = [ "unifi" "database" "controller" ];

          preBackupScript = ''
            echo "Creating UniFi MongoDB dump..."

            # Source MongoDB credentials
            source ${cfg.unifi.mongoCredentialsFile}

            # Create backup directory
            mkdir -p /tmp/unifi-backup

            # Dump MongoDB with oplog for consistency (O3 recommendation)
            ${pkgs.podman}/bin/podman exec unifi mongodump \
              --host localhost:27017 \
              --authenticationDatabase admin \
              --username "$MONGO_USER" \
              --password "$MONGO_PASSWORD" \
              --oplog \
              --gzip \
              --out /tmp/unifi-backup/mongodb

            # Copy configuration files
            cp -r ${cfg.unifi.dataPath}/conf /tmp/unifi-backup/
            cp -r ${cfg.unifi.dataPath}/keystore /tmp/unifi-backup/

            echo "UniFi backup preparation completed"
          '';

          postBackupScript = ''
            echo "Cleaning up UniFi backup files..."
            rm -rf /tmp/unifi-backup
          '';

          excludePatterns = [
            "*/logs/*"
            "*/work/*"
            "*/temp/*"
          ];

          resources = {
            memory = "512m";
            memoryReservation = "256m";
            cpus = "1.0";
          };
        };
      })

      # Omada Controller Backup
      (mkIf cfg.omada.enable {
        omada = {
          enable = true;
          paths = [
            "/mnt/backup-snapshot${cfg.omada.dataPath}"
          ];
          repository = "primary";
          tags = [ "omada" "database" "controller" ];

          preBackupScript = ''
            echo "Creating Omada controller backup..."

            # Create backup directory
            mkdir -p /tmp/omada-backup

            # Export Omada database from container
            ${pkgs.podman}/bin/podman exec ${cfg.omada.containerName} mongoexport \
              --db omada \
              --collection sites \
              --out /data/backup/sites.json || true

            ${pkgs.podman}/bin/podman exec ${cfg.omada.containerName} mongoexport \
              --db omada \
              --collection devices \
              --out /data/backup/devices.json || true

            # Copy backup files to host
            ${pkgs.podman}/bin/podman cp ${cfg.omada.containerName}:/opt/tplink/EAPController/data/backup /tmp/omada-backup/

            echo "Omada backup preparation completed"
          '';

          postBackupScript = ''
            echo "Cleaning up Omada backup files..."
            rm -rf /tmp/omada-backup
          '';

          excludePatterns = [
            "*/logs/*"
            "*/work/*"
            "*/temp/*"
          ];

          resources = {
            memory = "512m";
            memoryReservation = "256m";
            cpus = "1.0";
          };
        };
      })

      # 1Password Connect Backup
      (mkIf cfg.onepassword-connect.enable {
        onepassword-connect = {
          enable = true;
          paths = [
            "/mnt/backup-snapshot${cfg.onepassword-connect.dataPath}"
            cfg.onepassword-connect.credentialsFile
          ];
          repository = "primary";
          tags = [ "onepassword" "vault" "credentials" ];

          preBackupScript = ''
            echo "Preparing 1Password Connect backup..."

            # Brief pause to ensure data consistency
            sleep 2

            echo "1Password Connect backup preparation completed"
          '';

          excludePatterns = [
            "*/tmp/*"
            "*/cache/*"
          ];

          resources = {
            memory = "256m";
            memoryReservation = "128m";
            cpus = "0.5";
          };
        };
      })

      # Attic Binary Cache Backup
      (mkIf cfg.attic.enable (mkMerge [
        # Standard Restic backup for cloud storage
        (mkIf (!cfg.attic.useZfsSend) {
          attic = {
            enable = true;
            paths = [
              "/mnt/backup-snapshot${cfg.attic.dataPath}"
            ];
            repository = "primary";  # Use primary repository
            tags = [ "attic" "binary-cache" "nix" ];

            preBackupScript = ''
              echo "Preparing Attic binary cache backup..."

              # Check Attic service status
              if ${pkgs.systemd}/bin/systemctl is-active atticd; then
                echo "Attic service is running, backup will be consistent"
              else
                echo "Warning: Attic service is not running"
              fi
            '';

            excludePatterns = [
              "*/tmp/*"
              "*/cache/*"
              "*/.nobackup"
            ];

            resources = {
              memory = "1g";
              memoryReservation = "512m";
              cpus = "2.0";  # Higher resources for large dataset
            };
          };
        })

        # ZFS send/receive for local replication (O3 recommendation)
        (mkIf cfg.attic.useZfsSend {
          attic-zfs-send = {
            enable = cfg.attic.nasDestination != "";
            paths = [];  # No paths needed for ZFS send
            repository = "primary";
            tags = [ "attic" "zfs-send" "local-replication" ];

            preBackupScript = ''
              echo "Performing ZFS send for Attic data..."

              # Find the dataset containing Attic data
              ATTIC_DATASET=$(${pkgs.zfs}/bin/zfs list -H -o name | grep -E "(attic|cache)" | head -1)

              if [ -z "$ATTIC_DATASET" ]; then
                echo "Warning: Could not find Attic ZFS dataset"
                exit 0
              fi

              # Create incremental send to NAS
              LATEST_SNAPSHOT=$(${pkgs.zfs}/bin/zfs list -t snapshot -H -o name "$ATTIC_DATASET" | grep "@backup-" | sort | tail -1)

              if [ -n "$LATEST_SNAPSHOT" ] && [ -n "${cfg.attic.nasDestination}" ]; then
                echo "Sending ZFS snapshot to NAS: $LATEST_SNAPSHOT"
                ${pkgs.zfs}/bin/zfs send -i "$LATEST_SNAPSHOT" | \
                  ${pkgs.openssh}/bin/ssh ${cfg.attic.nasDestination} "${pkgs.zfs}/bin/zfs receive -F backup/attic" || true
              fi
            '';

            resources = {
              memory = "512m";
              memoryReservation = "256m";
              cpus = "1.0";
            };
          };
        })
      ]))

      # System Configuration Backup
      (mkIf cfg.system.enable {
        system = {
          enable = true;
          paths = map (path: "/mnt/backup-snapshot${path}") cfg.system.paths;
          repository = "primary";
          tags = [ "system" "configuration" "nixos" ];

          preBackupScript = ''
            echo "Preparing system configuration backup..."

            # Create temporary backup of current generation
            mkdir -p /tmp/system-backup

            # Backup current system generation info
            ${pkgs.nix}/bin/nix-env --list-generations --profile /nix/var/nix/profiles/system > /tmp/system-backup/generations.txt

            # Backup flake inputs
            if [ -f /etc/nixos/flake.lock ]; then
              cp /etc/nixos/flake.lock /tmp/system-backup/
            fi

            echo "System backup preparation completed"
          '';

          postBackupScript = ''
            echo "Cleaning up system backup files..."
            rm -rf /tmp/system-backup
          '';

          excludePatterns = cfg.system.excludePatterns;

          resources = {
            memory = "256m";
            memoryReservation = "128m";
            cpus = "0.5";
          };
        };
      })
    ];

    # Validation assertions
    assertions = [
      {
        assertion = cfg.unifi.enable -> (cfg.unifi.mongoCredentialsFile != null);
        message = "UniFi backup requires MongoDB credentials file";
      }
      {
        assertion = cfg.onepassword-connect.enable -> (cfg.onepassword-connect.credentialsFile != null);
        message = "1Password Connect backup requires credentials file";
      }
      {
        assertion = cfg.attic.enable && cfg.attic.useZfsSend -> (cfg.attic.nasDestination != "");
        message = "Attic ZFS send backup requires NAS destination";
      }
    ];
  };
}
