# modules/nixos/services/netvisor/default.nix
#
# NetVisor - Network discovery and visualization tool
# https://github.com/netvisor-io/netvisor
#
# Architecture:
# - Server container: Web UI, API, manages discovery sessions
# - Daemon container: Scans networks, requires host networking + privileged mode
# - PostgreSQL database: Stores discovered hosts, services, topology
#
# OIDC: Native support via oidc.toml (PocketID compatible)
#
{ lib, mylib, pkgs, config, podmanLib, ... }:

let
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  cfg = config.modules.services.netvisor;
  notificationsCfg = config.modules.notifications or { };
  hasCentralizedNotifications = notificationsCfg.enable or false;
  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };

  serviceName = "netvisor";
  backend = config.virtualisation.oci-containers.backend;

  # Service unit names for systemd dependencies
  serverServiceUnit = "${backend}-${serviceName}-server.service";

  # Default dataset path based on storage module configuration
  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  datasetPath = cfg.datasetPath or defaultDatasetPath;

  # Build replication config for preseed
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # Environment file locations
  envDir = "/run/${serviceName}";
  serverEnvFile = "${envDir}/server.env";
  daemonEnvFile = "${envDir}/daemon.env";

  # OIDC configuration file path
  oidcConfigPath = "${cfg.dataDir}/oidc.toml";
in
{
  options.modules.services.netvisor = {
    enable = lib.mkEnableOption "NetVisor network discovery and visualization";

    # Container images
    serverImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/mayanayza/netvisor-server:v0.11.6@sha256:3ccb0ce3fbca84a06c28e2adbf7983b78628399414a2472ae4f506b7e3e8d0c5";
      description = "NetVisor server container image with digest for immutability.";
    };

    daemonImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/mayanayza/netvisor-daemon:v0.11.6@sha256:496978ccb06ed0b0665f2edeef7c5eef1635511d1fced4e29b022eae33dcbe9b";
      description = "NetVisor daemon container image with digest for immutability.";
    };

    # User/group configuration
    user = lib.mkOption {
      type = lib.types.str;
      default = "netvisor";
      description = "System user that owns NetVisor data.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "netvisor";
      description = "Primary group for NetVisor data.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 935;
      description = "UID for the netvisor user.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 935;
      description = "GID for the netvisor group.";
    };

    # Data directory
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/netvisor";
      description = "Base directory for NetVisor persistent data.";
    };

    datasetPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset backing NetVisor data.";
      example = "tank/services/netvisor";
    };

    # Server configuration
    server = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 60072;
        description = "Port for the NetVisor server to listen on.";
      };

      publicUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://netvisor.${config.networking.domain}";
        description = "Public URL for NetVisor (used for callbacks, emails).";
      };

      disableRegistration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Disable new user registration after initial setup.";
      };

      useSecureCookies = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable HTTPS-only cookies (required when behind reverse proxy with TLS).";
      };

      logLevel = lib.mkOption {
        type = lib.types.enum [ "trace" "debug" "info" "warn" "error" ];
        default = "info";
        description = "Server logging verbosity.";
      };
    };

    # Daemon configuration
    daemon = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 60073;
        description = "Port for the NetVisor daemon to listen on.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "forge-daemon";
        description = "Name for this daemon instance.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "Push" "Pull" ];
        default = "Push";
        description = "Daemon operation mode (Push: server pushes work, Pull: daemon requests work).";
      };

      heartbeatInterval = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Seconds between heartbeat updates to server.";
      };

      concurrentScans = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Maximum parallel host scans. Auto-detected if null.";
      };

      scanSubnets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "List of subnets to scan (configured via UI, documented here for reference).";
        example = [ "10.20.0.0/16" "10.30.0.0/16" ];
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Public URL where the server can reach this daemon.
          If null, auto-detected from network interfaces.

          Set this explicitly on hosts with many interfaces (e.g., Podman veth interfaces
          with 169.254.x.x addresses) to ensure the daemon registers with the correct IP.
        '';
        example = "http://10.20.0.30:60073";
      };

      bindAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          IP address to bind the daemon to. If null, binds to 0.0.0.0.

          Set this to limit which interface the daemon listens on.
        '';
        example = "10.20.0.30";
      };
    };

    # Database configuration
    database = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "netvisor";
        description = "PostgreSQL database name.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "netvisor";
        description = "PostgreSQL user for NetVisor.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "host.containers.internal";
        description = "PostgreSQL host from container perspective.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the PostgreSQL password.";
      };

      manageDatabase = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to auto-provision the database via the PostgreSQL module.";
      };
    };

    # OIDC configuration
    oidc = {
      enable = lib.mkEnableOption "OIDC authentication via PocketID";

      providerName = lib.mkOption {
        type = lib.types.str;
        default = "Holthome SSO";
        description = "Display name for the OIDC provider in the UI.";
      };

      providerSlug = lib.mkOption {
        type = lib.types.str;
        default = "pocketid";
        description = "URL slug for the OIDC provider (lowercase, no spaces).";
      };

      issuerUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://id.${config.networking.domain}";
        description = "OIDC issuer URL (PocketID base URL).";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "netvisor";
        description = "OIDC client ID.";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the OIDC client secret.";
      };

      logoUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/pocketid.svg";
        description = "Logo URL for the OIDC provider button.";
      };
    };

    # Timezone
    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the containers.";
    };

    # Resource limits
    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "512M";
        memoryReservation = "256M";
        cpus = "2.0";
      };
      description = "Resource limits for the server container.";
    };

    daemonResources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1G";
        memoryReservation = "512M";
        cpus = "2.0";
      };
      description = "Resource limits for the daemon container (scanning is memory-intensive).";
    };

    # Healthcheck configuration
    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "60s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration for the server.";
    };

    # Standardized submodules
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for NetVisor web interface.";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 60072;
        path = "/api/health";
        labels = {
          service = serviceName;
          service_type = "infrastructure";
          function = "network_discovery";
        };
      };
      description = "Prometheus metrics configuration.";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serverServiceUnit;
        labels = {
          service = serviceName;
          service_type = "infrastructure";
        };
      };
      description = "Log shipping configuration.";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for NetVisor data.";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "NetVisor service failed on ${config.networking.hostName}";
      };
      description = "Notification configuration for service events.";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic password file.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic credentials.";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Order and selection of restore methods to attempt.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.database.passwordFile != null;
          message = "modules.services.netvisor.database.passwordFile must be set.";
        }
        {
          assertion = !cfg.oidc.enable || cfg.oidc.clientSecretFile != null;
          message = "modules.services.netvisor.oidc.clientSecretFile is required when OIDC is enabled.";
        }
      ];

      # Create system user and group
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        uid = cfg.uid;
        home = "/var/empty";
        createHome = false;
        description = "NetVisor service account";
      };

      users.groups.${cfg.group} = {
        gid = cfg.gid;
      };

      # Create data directories
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
        "d ${cfg.dataDir}/data 0750 ${cfg.user} ${cfg.group} -"
        # Daemon config directory - mounted as /root/.config/daemon in container
        "d ${cfg.dataDir}/daemon-config 0750 ${cfg.user} ${cfg.group} -"
      ];

      # ZFS dataset for persistent storage
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "zstd";
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # PostgreSQL database provisioning
      modules.services.postgresql.databases.${cfg.database.name} = lib.mkIf cfg.database.manageDatabase {
        owner = cfg.database.user;
        ownerPasswordFile = cfg.database.passwordFile;
        permissionsPolicy = "owner-only";
      };

      # OIDC configuration file generation
      systemd.services."netvisor-oidc-config" = lib.mkIf cfg.oidc.enable {
        description = "Generate NetVisor OIDC configuration";
        wantedBy = [ "multi-user.target" ];
        before = [ "${backend}-${serviceName}-server.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          LoadCredential = [
            "oidc_secret:${cfg.oidc.clientSecretFile}"
          ];
        };
        script = ''
          CLIENT_SECRET=$(cat "$CREDENTIALS_DIRECTORY/oidc_secret")

          cat > "${oidcConfigPath}" << EOF
          [[oidc_providers]]
          name = "${cfg.oidc.providerName}"
          slug = "${cfg.oidc.providerSlug}"
          logo = "${cfg.oidc.logoUrl}"
          issuer_url = "${cfg.oidc.issuerUrl}"
          client_id = "${cfg.oidc.clientId}"
          client_secret = "$CLIENT_SECRET"
          EOF

          chown ${cfg.user}:${cfg.group} "${oidcConfigPath}"
          chmod 640 "${oidcConfigPath}"
        '';
      };

      # Environment file generation service
      systemd.services."netvisor-env" = {
        description = "Generate NetVisor environment files";
        wantedBy = [ "multi-user.target" ];
        before = [ "${backend}-${serviceName}-server.service" "${backend}-${serviceName}-daemon.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          LoadCredential = [
            "db_password:${cfg.database.passwordFile}"
          ];
        };
        script = ''
          install -d -m 700 "${envDir}"

          DB_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/db_password")

          # Server environment
          cat > "${serverEnvFile}" << EOF
          NETVISOR_DATABASE_URL=postgresql://${cfg.database.user}:$DB_PASSWORD@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}
          EOF

          chmod 600 "${serverEnvFile}"

          # Daemon environment (API key will be auto-generated by server)
          cat > "${daemonEnvFile}" << EOF
          # Daemon connects to server, API key assigned via UI
          EOF

          chmod 600 "${daemonEnvFile}"
        '';
      };

      # Register with Caddy reverse proxy
      modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.server.port;
        };
        auth = cfg.reverseProxy.auth;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        security = cfg.reverseProxy.security;
        # Workaround for NetVisor OIDC bug: inject terms_accepted=true when missing
        # The frontend doesn't always include this parameter, causing serde deserialization errors
        # See: https://github.com/netvisor-io/netvisor (report upstream when fixed)
        extraConfig = ''
          # Fix NetVisor OIDC terms_accepted bug
          @oidc_missing_terms {
            path /api/auth/oidc/*/authorize
            not query terms_accepted=*
          }
          rewrite @oidc_missing_terms {path}?{query}&terms_accepted=true

          ${if cfg.reverseProxy.extraConfig != null then cfg.reverseProxy.extraConfig else ""}
        '';
      };

      # NetVisor Server container
      virtualisation.oci-containers.containers."${serviceName}-server" = podmanLib.mkContainer "${serviceName}-server" {
        image = cfg.serverImage;
        environmentFiles = [ serverEnvFile ];
        environment = {
          TZ = cfg.timezone;
          NETVISOR_SERVER_PORT = toString cfg.server.port;
          NETVISOR_PUBLIC_URL = cfg.server.publicUrl;
          NETVISOR_LOG_LEVEL = cfg.server.logLevel;
          NETVISOR_USE_SECURE_SESSION_COOKIES = lib.boolToString cfg.server.useSecureCookies;
          NETVISOR_DISABLE_REGISTRATION = lib.boolToString cfg.server.disableRegistration;
          NETVISOR_WEB_EXTERNAL_PATH = "/app/static";
          # Integrated daemon URL (daemon runs on host network)
          NETVISOR_INTEGRATED_DAEMON_URL = "http://host.containers.internal:${toString cfg.daemon.port}";
          # Client IP source for accurate logging behind reverse proxy
          # NOTE: We intentionally do NOT set NETVISOR_CLIENT_IP_SOURCE here.
          # When set to RightmostXForwardedFor/etc, axum-client-ip rejects ALL requests
          # without X-Forwarded-For header with HTTP 500. This breaks daemon registration
          # since daemons connect directly (not via Caddy). The server can still get
          # client IPs from headers when present (Caddy adds them), but won't fail
          # when headers are missing (direct daemon connections).
        };
        volumes = [
          "${cfg.dataDir}/data:/data:rw"
        ] ++ lib.optionals cfg.oidc.enable [
          "${oidcConfigPath}:/oidc.toml:ro"
        ];
        ports = [
          "127.0.0.1:${toString cfg.server.port}:${toString cfg.server.port}"
        ];
        resources = cfg.resources;
        extraOptions = [
          "--pull=newer"
        ] ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          ''--health-cmd=sh -c 'curl -sf http://127.0.0.1:${toString cfg.server.port}/api/health || exit 1' ''
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ];
      };

      # NetVisor Daemon container (requires host network for scanning)
      virtualisation.oci-containers.containers."${serviceName}-daemon" = podmanLib.mkContainer "${serviceName}-daemon" {
        image = cfg.daemonImage;
        environmentFiles = [ daemonEnvFile ];
        environment = {
          TZ = cfg.timezone;
          NETVISOR_SERVER_URL = "http://127.0.0.1:${toString cfg.server.port}";
          NETVISOR_DAEMON_PORT = toString cfg.daemon.port;
          NETVISOR_PORT = toString cfg.daemon.port;
          NETVISOR_BIND_ADDRESS = if cfg.daemon.bindAddress != null then cfg.daemon.bindAddress else "0.0.0.0";
          NETVISOR_NAME = cfg.daemon.name;
          NETVISOR_MODE = cfg.daemon.mode;
          NETVISOR_HEARTBEAT_INTERVAL = toString cfg.daemon.heartbeatInterval;
          NETVISOR_LOG_LEVEL = cfg.server.logLevel;
        } // lib.optionalAttrs (cfg.daemon.concurrentScans != null) {
          NETVISOR_CONCURRENT_SCANS = toString cfg.daemon.concurrentScans;
        } // lib.optionalAttrs (cfg.daemon.url != null) {
          # Explicit daemon URL prevents auto-detection issues on hosts with many interfaces
          # (e.g., Podman veth interfaces with 169.254.x.x link-local addresses)
          NETVISOR_DAEMON_URL = cfg.daemon.url;
        };
        volumes = [
          # Podman socket for container discovery (Docker-compatible API)
          # Note: Use Podman socket since NixOS uses Podman by default
          "/run/podman/podman.sock:/var/run/docker.sock:ro"
          # Daemon config persistence
          "${cfg.dataDir}/daemon-config:/root/.config/daemon:rw"
        ];
        resources = cfg.daemonResources;
        extraOptions = [
          "--pull=newer"
          # Host network required for network scanning
          "--network=host"
          # Privileged required for raw socket access (scanning)
          "--privileged"
          # Health check for daemon
          ''--health-cmd=sh -c 'curl -sf http://127.0.0.1:${toString cfg.daemon.port}/api/health || exit 1' ''
          "--health-interval=30s"
          "--health-timeout=10s"
          "--health-retries=5"
          "--health-start-period=30s"
          "--health-on-failure=kill"
        ];
      };

      # Systemd service dependencies
      systemd.services."${backend}-${serviceName}-server" = {
        requires = [ "netvisor-env.service" "postgresql.service" ];
        after = [ "netvisor-env.service" "postgresql.service" ]
          ++ lib.optionals cfg.oidc.enable [ "netvisor-oidc-config.service" ];
        wants = lib.optionals cfg.oidc.enable [ "netvisor-oidc-config.service" ];

        # Failure notifications
        unitConfig = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          OnFailure = [ "notify@netvisor-failure:%n.service" ];
        };
      };

      systemd.services."${backend}-${serviceName}-daemon" = {
        requires = [ "netvisor-env.service" "${backend}-${serviceName}-server.service" ];
        after = [ "netvisor-env.service" "${backend}-${serviceName}-server.service" ];

        # Failure notifications
        unitConfig = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          OnFailure = [ "notify@netvisor-failure:%n.service" ];
        };
      };

      # Notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "netvisor-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: NetVisor</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The NetVisor network discovery service has entered a failed state.

            <b>Quick Actions:</b>
            1. Check logs:
               <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service:
               <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Preseed service for disaster recovery
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serverServiceUnit;
        replicationCfg = replicationConfig;
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
  ];
}
