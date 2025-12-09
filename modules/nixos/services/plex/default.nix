{ lib
, mylib
, pkgs
, config
, ...
}:
let
  cfg = config.modules.services.plex;
  # Import shared type definitions
  sharedTypes = mylib.types;

  # Import storage helpers for preseed service generation
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  # Define storage configuration for consistent access
  storageCfg = config.modules.storage;

  # Construct the dataset path for plex
  datasetPath = "${storageCfg.datasets.parentDataset}/plex";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.plex = {
    enable = lib.mkEnableOption "Plex Media Server";

    package = lib.mkPackageOption pkgs "plex" { };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/plex";
      description = "Directory where Plex stores its data";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 32400;
      description = "Plex service port";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "plex";
      description = "System user to run Plex service";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "plex";
      description = "System group to run Plex service";
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/dev/dri" ];
      description = ''
        Device paths for hardware acceleration (VA-API /dev/dri).
        Default passes entire /dev/dri directory for robust device detection
        across reboots (device node numbers can change).
      '';
    };

    # Standardized integration submodules
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for external access";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null; # Plex does not expose native Prometheus metrics
      description = "Prometheus metrics collection (optional external exporter)";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "plex.service";
        labels = {
          service = "plex";
          service_type = "media_server";
        };
      };
      description = "Log shipping configuration for Plex";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Plex application data.

        Plex stores media metadata, watch history, and user preferences in a SQLite database.
        The database directory contains critical application state that cannot be easily recreated.

        Recommended settings:
        - enable: true (critical metadata and watch history)
        - useSnapshots: true (CRITICAL for SQLite database consistency)
        - zfsDataset: "tank/services/plex" (or your actual dataset path)
        - frequency: "weekly" (balance between protection and storage)
        - excludePatterns: Cache, Logs, Crash Reports, Updates, Transcode directories
          * Also exclude .LocalAdminToken (ephemeral, 600 permissions)
          * Also exclude Setup Plex.html (static file, 600 permissions)
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Plex service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Plex service events";
    };

    # ZFS integration pattern for declarative dataset management
    zfs = {
      dataset = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "tank/services/plex";
        description = "ZFS dataset to mount at dataDir";
      };

      recordsize = lib.mkOption {
        type = lib.types.str;
        default = "128K";
        description = "ZFS recordsize for Plex data (metadata-heavy)";
      };

      compression = lib.mkOption {
        type = lib.types.str;
        default = "lz4";
        description = "ZFS compression for Plex dataset";
      };

      properties = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "com.sun:auto-snapshot" = "false"; # Backups handled via Restic
          atime = "off";
        };
        description = "Additional ZFS dataset properties";
      };
    };

    # Optional systemd resource limits
    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.systemdResourcesSubmodule;
      default = {
        MemoryMax = "1G";
        CPUQuota = "50%";
      };
      description = "Systemd resource limits for Plex";
    };

    # Preseed configuration for disaster recovery
    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds. Examples:
          - [ "syncoid" "local" "restic" ] - Default, try replication first
          - [ "local" "restic" ] - Skip replication, try local snapshots first
          - [ "restic" ] - Restic-only (for air-gapped systems)
          - [ "local" "restic" "syncoid" ] - Local-first for quick recovery
        '';
      };
    };

    # Lightweight health monitoring with Prometheus textfile metrics
    monitoring = {
      enable = lib.mkEnableOption "monitoring for Plex";

      prometheus = {
        enable = lib.mkEnableOption "Prometheus metrics export via Node Exporter textfile collector";

        metricsDir = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/node_exporter/textfile_collector";
          description = "Directory for Node Exporter textfile metrics";
        };
      };

      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:32400/web";
        description = "Endpoint to probe for Plex health";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "minutely"; # systemd OnCalendar token
        description = "Healthcheck interval (systemd OnCalendar token, e.g., 'minutely', 'hourly')";
      };

    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Core Plex service using NixOS built-in module
      services.plex = {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        openFirewall = false; # Prefer reverse proxy exposure
        user = cfg.user;
        group = cfg.group;
        accelerationDevices = cfg.accelerationDevices;
      };

      # Auto-register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.plex = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.port;
        };

        # Pass-through auth/security from shared types
        auth = cfg.reverseProxy.auth;
        security = cfg.reverseProxy.security;

        # Caddy-specific headers for Plex compatibility
        extraConfig = lib.concatStringsSep "\n" [
          # Enable gzip for static assets (safe at site level)
          "encode gzip"
        ]
        + (if (cfg.reverseProxy.extraConfig or "") != "" then "\n" + cfg.reverseProxy.extraConfig else "");
      };

      # ZFS dataset auto-registration
      # Permissions must be set explicitly for ZFS mounts (StateDirectory doesn't apply to pre-mounted directories)
      modules.storage.datasets.services.plex = lib.mkIf (cfg.zfs.dataset != null) {
        recordsize = cfg.zfs.recordsize;
        compression = cfg.zfs.compression;
        mountpoint = cfg.dataDir;
        properties = cfg.zfs.properties;
        # Explicit permissions for ZFS-mounted datasets
        # StateDirectory only works for directories created by systemd, not pre-existing mounts
        owner = cfg.user;
        group = cfg.group;
        mode = "0750"; # rwxr-x--- allows backup user (group member) to read
      };

      # Backup auto-registration
      modules.backup.restic.jobs.plex = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        repository = cfg.backup.repository;
        paths = [ cfg.dataDir ];
        excludePatterns = cfg.backup.excludePatterns;
        tags = cfg.backup.tags;
        resources = {
          memory = "512M";
          memoryReservation = "256M";
          cpus = "1.0";
        };
      };

      # Firewall - localhost only
      networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ]
        ++ lib.optional (cfg.metrics != null && cfg.metrics.enable) cfg.metrics.port;

      # Optional systemd resource limits and file creation permissions
      systemd.services.plex.serviceConfig = lib.mkMerge [
        # File creation permissions: UMask 0027 ensures files created by service are 640 (rw-r-----)
        # This allows restic-backup user (member of plex group) to read data
        # Note: Directory ownership is managed by tmpfiles for ZFS-mounted datasets,
        # since StateDirectory only works for directories created by systemd.
        {
          StateDirectory = "plex";
          StateDirectoryMode = "0750";
          UMask = "0027";
        }
        (lib.mkIf (cfg.resources != null) {
          MemoryMax = cfg.resources.MemoryMax;
          MemoryLow = cfg.resources.MemoryReservation;
          CPUQuota = cfg.resources.CPUQuota;
          CPUWeight = cfg.resources.CPUWeight;
          IOWeight = cfg.resources.IOWeight;
        })
      ];

      # Ensure Plex starts after mounts and tmpfiles rules are applied
      systemd.services.plex.unitConfig = lib.mkMerge [
        (lib.mkIf (cfg.zfs.dataset != null) {
          RequiresMountsFor = [ cfg.dataDir ];
          After = [ "zfs-mount.service" "zfs-service-datasets.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          After = [ "preseed-plex.service" ];
          Wants = [ "preseed-plex.service" ];
        })
      ];

      # Fix VA-API library mismatch: avoid injecting system libva into Plex FHS runtime
      # Override upstream LD_LIBRARY_PATH and point only to driver directory; set LIBVA envs
      systemd.services.plex.environment = {
        LD_LIBRARY_PATH = lib.mkForce "/run/opengl-driver/lib/dri";
        LIBVA_DRIVER_NAME = config.modules.common.intelDri.driver or "iHD";
        LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
      };

      # Note: ownership/mode handled by storage module tmpfiles after mount

      # Ensure Plex waits for its dataDir mount (prevents race on ZFS mounts) - merged above

      # Healthcheck service exporting Prometheus textfile metrics
      systemd.services.plex-healthcheck = lib.mkIf cfg.monitoring.enable {
        description = "Plex healthcheck exporter";
        after = [ "plex.service" ];
        requires = [ "plex.service" ];
        path = with pkgs; [ curl coreutils ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          PrivateTmp = true;
          ProtectSystem = "strict";
          NoNewPrivileges = true;
          ReadWritePaths = lib.mkIf cfg.monitoring.prometheus.enable [ cfg.monitoring.prometheus.metricsDir ];
        };
        script = ''
                  set -euo pipefail
                  METRICS_DIR=${cfg.monitoring.prometheus.metricsDir}
                  METRICS_FILE="$METRICS_DIR/plex.prom"
                  TMP="$METRICS_FILE.tmp"

                  STATUS=0
                  if curl -fsS -m 10 "${cfg.monitoring.endpoint}" >/dev/null; then
                    STATUS=1
                  fi

                  TS=$(date +%s)
                  mkdir -p "$METRICS_DIR"
                  cat > "$TMP" <<EOF
          # HELP plex_up Plex health status (1=up, 0=down)
          # TYPE plex_up gauge
          plex_up{hostname="${config.networking.hostName}"} $STATUS

          # HELP plex_last_check_timestamp Last healthcheck timestamp
          # TYPE plex_last_check_timestamp gauge
          plex_last_check_timestamp{hostname="${config.networking.hostName}"} $TS
          EOF
                  mv "$TMP" "$METRICS_FILE"
        '';
      };

      systemd.timers.plex-healthcheck = lib.mkIf cfg.monitoring.enable {
        description = "Timer for Plex healthcheck";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.monitoring.interval;
          Persistent = true;
          RandomizedDelaySec = "30s";
        };
      };


      # Ensure plex user can read shared media group mounts, access GPU, and write metrics
      users.users.plex.extraGroups = lib.mkIf (config.users.users ? plex) (
        [ "media" "node-exporter" ]
        ++ lib.optionals (cfg.accelerationDevices != [ ]) [ "render" ]
      );

      # Validations
      assertions = [
        {
          assertion = (cfg.accelerationDevices == [ ]) || (config.hardware.graphics.enable or false);
          message = "Hardware acceleration requires hardware.graphics.enable = true";
        }
        {
          assertion = cfg.monitoring.prometheus.enable -> (config.services.prometheus.exporters.node.enable or false);
          message = "Prometheus metrics export requires Node Exporter to be enabled";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
          message = "Plex preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = cfg.preseed.enable -> (cfg.preseed.passwordFile != null);
          message = "Plex preseed.enable requires preseed.passwordFile to be set.";
        }
      ];
    })

    # Add the preseed service itself
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "plex";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "plex.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = cfg.zfs.recordsize;
          compression = cfg.zfs.compression;
        } // cfg.zfs.properties;
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = true; # Plex integrates with centralized alerting
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
