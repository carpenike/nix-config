{
  pkgs,
  lib,
  config,
  podmanLib,
  ...
}:
let
  cfg = config.modules.services.unifi;
  storageCfg = config.modules.storage;
  datasetPath = "${storageCfg.datasets.parentDataset}/unifi";
  mainServiceUnit = "${config.virtualisation.oci-containers.backend}-unifi.service";
  hasCentralizedNotifications = config.modules.notifications.enable or false;
  unifiTcpPorts = [ 8080 8443 ];
  unifiUdpPorts = [ 3478 ];
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
in
{
  options.modules.services.unifi = {
    enable = lib.mkEnableOption "unifi";
    credentialsFile = lib.mkOption {
      type = lib.types.path;
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/unifi/data";
    };
    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/unifi/logs";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "999";
      description = "User ID to own the data and log directories";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "999";
      description = "Group ID to own the data and log directories";
    };
    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1g";
  memoryReservation = "512M";
        cpus = "1.0";
      };
      description = "Resource limits for the Unifi container (recommended for homelab stability)";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for UniFi Controller web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8443;
        path = "/api/s/default/stat/health";
        labels = {
          service_type = "network_controller";
          exporter = "unifi";
          function = "wifi_management";
        };
      };
      description = "Prometheus metrics collection configuration for UniFi Controller";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "podman-unifi.service";
        labels = {
          service = "unifi";
          service_type = "network_controller";
        };
      };
      description = "Log shipping configuration for UniFi Controller logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "network" "unifi" "config" ];
        # CRITICAL: Enable ZFS snapshots for MongoDB database consistency
        useSnapshots = lib.mkDefault true;
        zfsDataset = lib.mkDefault "tank/services/unifi";
        excludePatterns = lib.mkDefault [
          "**/logs/**"           # Exclude log files
          "**/tmp/**"            # Exclude temporary files
          "**/work/**"           # Exclude work directories
        ];
      };
      description = "Backup configuration for UniFi Controller";
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
          failure = "UniFi Controller failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for UniFi Controller service events";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.repositoryUrl != "";
        message = "UniFi preseed.enable requires preseed.repositoryUrl to be set.";
      }) ++ (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.passwordFile != null;
        message = "UniFi preseed.enable requires preseed.passwordFile to be set.";
      });

      modules.services.podman.enable = true;

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.unifi = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = {
        scheme = "https";  # UniFi uses HTTPS
        host = "127.0.0.1";
        port = 8443;
        tls.verify = false;  # UniFi uses self-signed certificate by default
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Authelia SSO configuration from shared types
      authelia = cfg.reverseProxy.authelia;

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      # UniFi-specific reverse proxy directives
      reverseProxyBlock = ''
        # Handle websockets for real-time updates
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        # WebSocket upgrade headers
        header_up Upgrade {>Upgrade}
        header_up Connection {>Connection}
      '';
    };

    # Register with Authelia if SSO protection is enabled
    modules.services.authelia.accessControl.declarativelyProtectedServices.unifi = lib.mkIf (
      config.modules.services.authelia.enable &&
      cfg.reverseProxy != null &&
      cfg.reverseProxy.enable &&
      cfg.reverseProxy.authelia != null &&
      cfg.reverseProxy.authelia.enable
    ) (
      let
        authCfg = cfg.reverseProxy.authelia;
      in {
        domain = cfg.reverseProxy.hostName;
        policy = authCfg.policy;
        subject = map (g: "group:${g}") authCfg.allowedGroups;
        bypassResources =
          (map (path: "^${lib.escapeRegex path}/.*$") (authCfg.bypassPaths or []))
          ++ (authCfg.bypassResources or []);
      }
    );

    # Ensure directories exist before services start
    systemd.tmpfiles.rules =
      podmanLib.mkLogDirTmpfiles {
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
      makeUnifiDataDir = lib.stringAfter [ "var" ] ''
        mkdir -p "${cfg.dataDir}"
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
      '';
    } // podmanLib.mkLogDirActivation {
      name = "Unifi";
      path = cfg.logDir;
      user = cfg.user;
      group = cfg.group;
    };

    # Configure logrotate for UniFi application logs
    services.logrotate.settings = podmanLib.mkLogRotate {
      containerName = "unifi";
      logDir = cfg.logDir;
      user = cfg.user;
      group = cfg.group;
    };

    virtualisation.oci-containers.containers.unifi = podmanLib.mkContainer "unifi" {
      image = "ghcr.io/jacobalberty/unifi-docker:v8.4.62";
      environment = {
        "TZ" = "America/New_York";
      };
      autoStart = true;
      ports = [ "8080:8080" "8443:8443" "3478:3478/udp" ];
      volumes = [
        "${cfg.dataDir}:/unifi"
        "${cfg.logDir}:/logs"
      ];
      resources = cfg.resources;
    };

    systemd.services.${mainServiceUnit} = lib.mkMerge [
      (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        unitConfig.OnFailure = [ "notify@unifi-failure:%n.service" ];
      })
      (lib.mkIf cfg.preseed.enable {
        wants = [ "preseed-unifi.service" ];
        after = [ "preseed-unifi.service" ];
      })
    ];

    networking.firewall.allowedTCPPorts = unifiTcpPorts;
    networking.firewall.allowedUDPPorts = unifiUdpPorts;
    }

    # Add the preseed service itself
    (lib.mkIf cfg.preseed.enable (
      storageHelpers.mkPreseedService {
        serviceName = "unifi";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = null;  # Replication config handled at host level
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
