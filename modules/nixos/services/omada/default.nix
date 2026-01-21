{ pkgs
, lib
, mylib
, config
, podmanLib
, ...
}:
let
  cfg = config.modules.services.omada;
  storageCfg = config.modules.storage;
  datasetPath = "${storageCfg.datasets.parentDataset}/omada";
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-omada.service";
  hasCentralizedNotifications = config.modules.notifications.enable or false;
  omadaTcpPorts = [ 8043 8843 29814 ];
  omadaUdpPorts = [ 29810 ];
  # Import shared type definitions
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
in
{
  options.modules.services.omada = {
    enable = lib.mkEnableOption "omada";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/omada/data";
    };
    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/omada/log";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "508";
      description = "User ID to own the data and log directories (omada:omada in container)";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "508";
      description = "Group ID to own the data and log directories (omada:omada in container)";
    };
    blockOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the system activation should wait for Omada to fully start.
        Set to false to prevent deployment failures when Omada takes time to initialize.
      '';
    };
    restartDelay = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        How long to wait before restarting the service after a failure.
        Increase this on resource-constrained systems.
      '';
    };
    resources = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          memory = lib.mkOption {
            type = lib.types.str;
            default = "512m";
            description = "Memory limit for the container (e.g., '512m', '1g')";
          };
          memoryReservation = lib.mkOption {
            type = lib.types.str;
            default = "256m";
            description = "Memory reservation (soft limit) for the container";
          };
          cpus = lib.mkOption {
            type = lib.types.str;
            default = "0.75";
            description = "CPU limit in cores (e.g., '0.5', '1', '2')";
          };
        };
      });
      default = {
        memory = "512M";
        memoryReservation = "256M";
        cpus = "0.75";
      };
      description = "Resource limits for the Omada container (recommended for homelab stability)";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Omada Controller web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8043;
        path = "/api/info";
        labels = {
          service_type = "network_controller";
          exporter = "omada";
          function = "access_point_management";
        };
      };
      description = "Prometheus metrics collection configuration for Omada Controller";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-omada.service";
        labels = {
          service = "omada";
          service_type = "network_controller";
        };
      };
      description = "Log shipping configuration for Omada Controller logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "network" "omada" "config" ];
        # CRITICAL: Enable ZFS snapshots for MongoDB database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/omada";
        excludePatterns = lib.mkDefault [
          "**/logs/**" # Exclude log files
          "**/tmp/**" # Exclude temporary files
          "**/work/**" # Exclude work directories
        ];
      };
      description = "Backup configuration for Omada Controller";
    };

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
          sequentially until one succeeds.
        '';
      };
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "network-alerts" ];
        };
        customMessages = {
          failure = "Omada Controller failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Omada Controller service events";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.repositoryUrl != "";
        message = "Omada preseed.enable requires preseed.repositoryUrl to be set.";
      }) ++ (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.passwordFile != null;
        message = "Omada preseed.enable requires preseed.passwordFile to be set.";
      });

      modules.services.podman.enable = true;

      # Automatically register with Caddy reverse proxy if enabled
      modules.services.caddy.virtualHosts.omada = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = {
          scheme = "https"; # Omada uses HTTPS
          host = "127.0.0.1";
          port = 8043;
          tls.verify = false; # Omada uses self-signed certificate by default
        };

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

        # Security configuration from shared types
        security = cfg.reverseProxy.security;

        # Omada-specific reverse proxy directives
        reverseProxyBlock = ''
          # Handle websockets for real-time updates
          header_up Host {upstream_hostport}
          header_up X-Real-IP {remote_host}
          # Fix redirects by rewriting Location headers from backend
          header_down Location {http.request.scheme}://{http.request.host}{http.request.uri}
        '';
      };

      # Ensure directories exist before services start
      systemd.tmpfiles.rules =
        podmanLib.mkLogDirTmpfiles
          {
            path = cfg.dataDir;
            user = cfg.user;
            group = cfg.group;
          }
        ++ podmanLib.mkLogDirTmpfiles {
          path = cfg.logDir;
          user = cfg.user;
          group = cfg.group;
        };

      system.activationScripts = {
        makeOmadaDataDir = lib.stringAfter [ "var" ] ''
          mkdir -p "${cfg.dataDir}"
          chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
        '';
      } // podmanLib.mkLogDirActivation {
        name = "Omada";
        path = cfg.logDir;
        user = cfg.user;
        group = cfg.group;
      };

      # Configure logrotate for Omada application logs
      services.logrotate.settings = podmanLib.mkLogRotate {
        containerName = "omada";
        logDir = cfg.logDir;
        user = cfg.user;
        group = cfg.group;
      };

      # Omada Controller with embedded MongoDB
      virtualisation.oci-containers.containers.omada = podmanLib.mkContainer "omada" {
        image = "docker.io/mbentley/omada-controller:6.1.0.19@sha256:a11e623b8193582555abfa8bd02c0b57b143f4dcaa0aeab2bcba945952dc822a";
        environment = {
          "TZ" = "America/New_York";
          # Using embedded MongoDB (default behavior when MONGO_EXTERNAL is not set)
        };
        autoStart = true;
        ports = [ "8043:8043" "8843:8843" "29814:29814" "29810:29810/udp" ];
        volumes = [
          "${cfg.dataDir}:/opt/tplink/EAPController/data"
          "${cfg.logDir}:/opt/tplink/EAPController/logs"
        ];
        resources = cfg.resources;
      };

      # Override systemd service to handle Omada's initialization behavior
      systemd.services."${config.virtualisation.oci-containers.backend}-omada" = lib.mkMerge [
        {
          after = lib.mkForce [ "network-online.target" ];
          wants = lib.mkForce [ "network-online.target" ];

          # Allow more restart attempts during activation
          unitConfig = {
            StartLimitIntervalSec = "10m";
            StartLimitBurst = 5;
          };

          # Increase timeouts for slow initialization
          serviceConfig = {
            # Give Omada more time to start (default is 0 = infinity)
            TimeoutStartSec = lib.mkForce "5m";

            # Give Omada more time to gracefully shut down (default is 120s)
            TimeoutStopSec = lib.mkForce "3m";

            # If it fails, wait before restarting to avoid rapid restart loops
            RestartSec = cfg.restartDelay;

            # Override the default "always" restart behavior to prevent rapid restart loops
            Restart = lib.mkForce "on-failure";
          };

          # Add a post-start script to verify Omada is responding
          postStart = podmanLib.mkHealthCheck {
            port = 8043;
            protocol = "https";
            retries = 60;
            delay = 5;
          };
        }
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@omada-failure:%n.service" ];
        })
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-omada.service" ];
          after = [ "preseed-omada.service" ];
        })
      ];

      # If not blocking on activation, start Omada after the main system is up
      # This prevents deployment failures due to Omada's slow initialization
      systemd.targets.omada-ready = lib.mkIf (!cfg.blockOnActivation) {
        description = "Omada Controller Ready";
        after = [ "${config.virtualisation.oci-containers.backend}-omada.service" ];
        wants = [ "${config.virtualisation.oci-containers.backend}-omada.service" ];
      };

      networking.firewall.allowedTCPPorts = omadaTcpPorts;
      networking.firewall.allowedUDPPorts = omadaUdpPorts;
    }

    # Add the preseed service itself
    (lib.mkIf cfg.preseed.enable (
      storageHelpers.mkPreseedService {
        serviceName = "omada";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = null; # Replication config handled at host level
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ]);
}
