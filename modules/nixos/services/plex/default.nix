{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:
let
  cfg = config.modules.services.plex;
  # Import shared type definitions
  sharedTypes = mylib.types;

  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  # Define storage configuration for consistent access
  storageCfg = config.modules.storage;

  # Construct the dataset path for plex
  datasetPath = "${storageCfg.datasets.parentDataset}/plex";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # Container mode helpers
  isContainerMode = cfg.deploymentMode == "container";
  isNativeMode = cfg.deploymentMode == "native";
  containerServiceUnit = "${config.virtualisation.oci-containers.backend}-plex.service";
  nativeServiceUnit = "plex.service";
  mainServiceUnit = if isContainerMode then containerServiceUnit else nativeServiceUnit;

  # NFS mount configuration lookup (for container mode media access)
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig = storageHelpers.mkNfsMountConfig { inherit config; nfsMountDependency = nfsMountName; };
in
{
  options.modules.services.plex = {
    enable = lib.mkEnableOption "Plex Media Server";

    # =========================================================================
    # DEPLOYMENT MODE
    # =========================================================================
    # Choose between native NixOS module or Podman container deployment.
    # Container mode is recommended when VA-API hardware transcoding is needed,
    # as the native mode has a glibc version mismatch issue (nixpkgs #468070).
    # =========================================================================

    deploymentMode = lib.mkOption {
      type = lib.types.enum [ "native" "container" ];
      default = "native";
      description = ''
        Deployment mode for Plex Media Server.

        - native: Uses NixOS services.plex module with bubblewrap sandbox.
          Note: VA-API hardware transcoding is currently broken due to
          glibc version mismatch (nixpkgs #468070). Software transcoding works.

        - container: Uses Podman container from home-operations/containers.
          VA-API hardware transcoding works because the container uses
          Ubuntu 24.04 with matching glibc. Recommended for hardware transcoding.
      '';
    };

    # =========================================================================
    # CONTAINER-SPECIFIC OPTIONS
    # =========================================================================
    # These options only apply when deploymentMode = "container"
    # =========================================================================

    container = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/home-operations/plex:1.42.2.10156-f737b826c";
        description = ''
          Container image for Plex (home-operations).
          Pin to specific version with digest for immutability.
          Use Renovate bot to automate version updates.
        '';
        example = "ghcr.io/home-operations/plex:1.42.2.10156-f737b826c@sha256:...";
      };

      claimToken = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Plex claim token for initial server setup.
          Get one from https://plex.tv/claim (valid for 4 minutes).
          Only needed for first-time setup; can be removed after.
        '';
      };

      advertiseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "URL to advertise to Plex.tv for external access";
        example = "https://plex.example.com:443";
      };

      allowedNetworks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Networks that don't require authentication";
        example = [ "192.168.1.0/24" "10.0.0.0/8" ];
      };

      purgeCodecs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Purge codecs folder on startup (useful after Plex updates)";
      };

      preferences = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Additional Plex preferences to set via PLEX_PREFERENCE_* env vars.
          Format: { PreferenceKey = "value"; } becomes PLEX_PREFERENCE_1="PreferenceKey=value"
        '';
        example = { TranscoderTempDirectory = "/transcode"; };
      };

      resources = lib.mkOption {
        type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
        default = {
          memory = "4G";
          memoryReservation = "2G";
          cpus = "4.0";
        };
        description = "Container resource limits";
      };

      healthcheck = lib.mkOption {
        type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
        default = {
          enable = true;
          interval = "30s";
          timeout = "10s";
          retries = 3;
          startPeriod = "120s";
          onFailure = "kill";
        };
        description = "Container healthcheck configuration";
      };

      timezone = lib.mkOption {
        type = lib.types.str;
        default = "America/New_York";
        description = "Timezone for the container";
      };
    };

    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the NFS mount defined in `modules.storage.nfsMounts` to use for media.
        This will automatically set `mediaDir` and systemd dependencies.
        Primarily used in container mode for media library access.
      '';
      example = "media";
    };

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/media";
      description = "Path to media library (used in container mode for volume mount)";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach this container to (container mode only).
        Enables DNS resolution to other containers on the same network.
      '';
      example = "media-services";
    };

    # =========================================================================
    # SHARED OPTIONS (both modes)
    # =========================================================================

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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open firewall ports for direct Plex access.

        Opens: main port (cfg.port, default 32400) TCP
        Optionally: additional ports for GDM, DLNA, Roku, network discovery

        Note: When using reverse proxy (Caddy), this is typically NOT needed
        for external access. Only enable if you need:
        - Direct LAN client access (Smart TVs, game consoles)
        - DLNA discovery and streaming
        - Plex's GDM network discovery
        - Roku direct connection

        For security, consider leaving disabled if all clients use the
        reverse proxy URL (https://plex.yourdomain.com).
      '';
    };

    openFirewallDiscovery = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open additional ports for Plex network discovery.

        Opens:
        - 1900 UDP: DLNA/SSDP discovery
        - 5353 UDP: Bonjour/mDNS
        - 32410-32414 UDP: GDM network discovery (Plex clients)
        - 32469 TCP: DLNA media streaming

        Only needed when openFirewall is also true and you want
        automatic device discovery on the local network.
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
      # Note: journalUnit is set dynamically in config based on deploymentMode
      # Native mode: plex.service, Container mode: podman-plex.service
      default = {
        enable = true;
        journalUnit = null; # Set dynamically in config section based on deploymentMode
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
    # =========================================================================
    # SHARED CONFIGURATION (both native and container modes)
    # =========================================================================
    (lib.mkIf cfg.enable {
      # Set journalUnit dynamically based on deployment mode for log shipping
      modules.services.plex.logging.journalUnit = lib.mkIf (cfg.logging != null && cfg.logging.enable) (
        lib.mkDefault mainServiceUnit
      );

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

        # Plex-specific reverse_proxy block directives
        # Best practices: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
        reverseProxyBlock = ''
          # Forward client IP for Plex remote access and geo-location
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}

          # Streaming optimization: disable buffering for immediate media delivery
          # -1 = low-latency mode: flush immediately after each write, don't cancel on client disconnect
          flush_interval -1

          # Large buffer for high-bitrate 4K/HDR streaming bursts
          # Default is too small for media; 8MB handles transcoded chunks efficiently
          transport http {
            response_header_timeout 0
            read_timeout 0
            write_timeout 0
          }
        '';

        # Site-level Caddy directives
        extraConfig = lib.concatStringsSep "\n" [
          # Enable gzip for static web assets (Caddy automatically skips compressed media)
          "encode gzip"
        ]
        + (if (cfg.reverseProxy.extraConfig or "") != "" then "\n" + cfg.reverseProxy.extraConfig else "");
      };

      # ZFS dataset auto-registration (shared between both modes)
      # Permissions must be set explicitly for ZFS mounts (StateDirectory doesn't apply to pre-mounted directories)
      modules.storage.datasets.services.plex = lib.mkIf (cfg.zfs.dataset != null) {
        recordsize = cfg.zfs.recordsize;
        compression = cfg.zfs.compression;
        mountpoint = cfg.dataDir;
        properties = cfg.zfs.properties;
        # Explicit permissions for ZFS-mounted datasets
        owner = cfg.user;
        group = cfg.group;
        mode = "0750"; # rwxr-x--- allows backup user (group member) to read
      };

      # Backup auto-registration (shared between both modes)
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

      # Firewall configuration (shared between both modes)
      networking.firewall = lib.mkMerge [
        # Always allow localhost access (for Caddy reverse proxy)
        {
          interfaces.lo.allowedTCPPorts = [ cfg.port ]
            ++ lib.optional (cfg.metrics != null && cfg.metrics.enable) cfg.metrics.port;
        }
        # Direct LAN access (opt-in)
        (lib.mkIf cfg.openFirewall {
          allowedTCPPorts = [ cfg.port ];
        })
        # Network discovery ports (opt-in, requires openFirewall)
        (lib.mkIf (cfg.openFirewall && cfg.openFirewallDiscovery) {
          allowedTCPPorts = [ 32469 ]; # DLNA
          allowedUDPPorts = [
            1900 # DLNA/SSDP discovery
            5353 # Bonjour/mDNS
            32410
            32411
            32412
            32413
            32414 # GDM network discovery
          ];
        })
      ];

      # Create /transcode directory for Plex transcoding (both modes)
      systemd.tmpfiles.rules = [
        "d /transcode 0755 ${cfg.user} ${cfg.group} - -"
      ];

      # Automatically set mediaDir from the NFS mount configuration if specified
      modules.services.plex.mediaDir = lib.mkIf (nfsMountConfig != null) (lib.mkDefault nfsMountConfig.localPath);

      # Validations (shared)
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
        # Container mode validations
        {
          assertion = isContainerMode -> (nfsMountName == null || nfsMountConfig != null);
          message = "Plex nfsMountDependency '${toString nfsMountName}' does not exist in modules.storage.nfsMounts.";
        }
      ];
    })

    # =========================================================================
    # NATIVE MODE CONFIGURATION
    # =========================================================================
    (lib.mkIf (cfg.enable && isNativeMode) {
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

      # Optional systemd resource limits and file creation permissions
      systemd.services.plex.serviceConfig = lib.mkMerge [
        # File creation permissions: UMask 0027 ensures files created by service are 640 (rw-r-----)
        # This allows restic-backup user (member of plex group) to read data
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

      # WORKAROUND (2025-12-31): VA-API library mismatch in native mode
      # The NixOS system libva is built with glibc 2.38+ which has __isoc23_sscanf symbol
      # not available in Plex's bundled FHS glibc. This breaks hardware transcoding.
      # Upstream: https://github.com/NixOS/nixpkgs/issues/468070
      # Only expose the driver directory to avoid loading incompatible libva.so
      systemd.services.plex.environment = {
        LD_LIBRARY_PATH = lib.mkForce "/run/opengl-driver/lib/dri";
        LIBVA_DRIVER_NAME = config.modules.common.intelDri.driver or "iHD";
        LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
      };

      # Healthcheck service exporting Prometheus textfile metrics (native mode)
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
    })

    # =========================================================================
    # CONTAINER MODE CONFIGURATION
    # =========================================================================
    (lib.mkIf (cfg.enable && isContainerMode) {
      # Create local user to match container UID for file ownership
      users.users.${cfg.user} = {
        uid = lib.mkDefault 65534; # nobody in container
        group = cfg.group;
        isSystemUser = true;
        description = "Plex service user (container mode)";
        extraGroups = [ "media" "render" "video" ];
      };

      users.groups.${cfg.group} = lib.mkIf (cfg.group != "media") {
        gid = lib.mkDefault 65534;
      };

      # Plex container using home-operations image
      virtualisation.oci-containers.containers.plex = podmanLib.mkContainer "plex" {
        image = cfg.container.image;

        environment = lib.filterAttrs (_: v: v != null) ({
          TZ = cfg.container.timezone;
          # Plex claim token for initial setup
          PLEX_CLAIM_TOKEN = cfg.container.claimToken;
          # Advertise URL for external access
          PLEX_ADVERTISE_URL = cfg.container.advertiseUrl;
          # Allowed networks (no auth required)
          PLEX_NO_AUTH_NETWORKS =
            if cfg.container.allowedNetworks != [ ]
            then lib.concatStringsSep "," cfg.container.allowedNetworks
            else null;
          # Purge codecs on startup
          PLEX_PURGE_CODECS = if cfg.container.purgeCodecs then "true" else null;
        } // (lib.listToAttrs (lib.imap1
          (i: pref:
            lib.nameValuePair "PLEX_PREFERENCE_${toString i}" "${pref.name}=${pref.value}"
          )
          (lib.mapAttrsToList (name: value: { inherit name value; }) cfg.container.preferences))));

        volumes = [
          # Config directory - home-operations uses /config which maps to
          # /config/Library/Application Support/Plex Media Server internally
          "${cfg.dataDir}:/config:rw"
          # Transcode directory
          "/transcode:/transcode:rw"
          # Media library (if configured)
        ] ++ lib.optional (nfsMountConfig != null || cfg.mediaDir != "/mnt/media") "${cfg.mediaDir}:/data:ro";

        ports = [
          "${toString cfg.port}:32400"
        ];

        resources = cfg.container.resources;

        extraOptions = [
          "--pull=newer"
          # GPU passthrough for hardware transcoding (VA-API)
          # This is the main reason to use container mode - it works!
        ] ++ lib.optionals (cfg.accelerationDevices != [ ]) (
          lib.concatMap (dev: [ "--device=${dev}:${dev}" ]) cfg.accelerationDevices
        ) ++ lib.optionals (cfg.accelerationDevices != [ ]) [
          # Add video and render groups for GPU access
          "--group-add=video"
          "--group-add=render"
        ] ++ lib.optionals (cfg.container.healthcheck != null && cfg.container.healthcheck.enable) [
          # Health check using Plex web interface
          ''--health-cmd=curl -fsS http://127.0.0.1:32400/web/index.html >/dev/null''
          "--health-interval=${cfg.container.healthcheck.interval}"
          "--health-timeout=${cfg.container.healthcheck.timeout}"
          "--health-retries=${toString cfg.container.healthcheck.retries}"
          "--health-start-period=${cfg.container.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.container.healthcheck.onFailure}"
        ] ++ lib.optionals (cfg.podmanNetwork != null) [
          "--network=${cfg.podmanNetwork}"
        ];
      };

      # Systemd service dependencies for container
      systemd.services."${config.virtualisation.oci-containers.backend}-plex" = lib.mkMerge [
        # Podman network dependency
        (lib.mkIf (cfg.podmanNetwork != null) {
          requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
          after = [ "podman-network-${cfg.podmanNetwork}.service" ];
        })
        # NFS mount dependency
        (lib.mkIf (nfsMountConfig != null) {
          requires = [ nfsMountConfig.mountUnitName ];
          after = [ nfsMountConfig.mountUnitName ];
        })
        # ZFS mount dependency
        (lib.mkIf (cfg.zfs.dataset != null) {
          unitConfig = {
            RequiresMountsFor = [ cfg.dataDir ];
            After = [ "zfs-mount.service" "zfs-service-datasets.service" ];
          };
        })
        # Preseed dependency
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-plex.service" ];
          after = [ "preseed-plex.service" ];
        })
        # Failure notifications
        (lib.mkIf (config.modules.notifications.enable or false) {
          unitConfig.OnFailure = [ "notify@plex-failure:%n.service" ];
        })
      ];

      # Healthcheck service for container mode (Prometheus textfile metrics)
      systemd.services.plex-healthcheck = lib.mkIf cfg.monitoring.enable {
        description = "Plex healthcheck exporter (container mode)";
        after = [ containerServiceUnit ];
        requires = [ containerServiceUnit ];
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
        description = "Timer for Plex healthcheck (container mode)";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.monitoring.interval;
          Persistent = true;
          RandomizedDelaySec = "30s";
        };
      };
    })

    # Add the preseed service itself (works for both native and container modes)
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "plex";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit; # Dynamic based on deployment mode
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
