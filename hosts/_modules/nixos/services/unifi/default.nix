{
  pkgs,
  lib,
  config,
  podmanLib,
  ...
}:
let
  cfg = config.modules.services.unifi;
  unifiTcpPorts = [ 8080 8443 ];
  unifiUdpPorts = [ 3478 ];
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
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
        memoryReservation = "512m";
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
      default = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "network" "unifi" "config" ];
        preBackupScript = ''
          # Stop UniFi before backup to ensure consistent state
          systemctl stop podman-unifi.service || true
        '';
        postBackupScript = ''
          # Restart UniFi after backup
          systemctl start podman-unifi.service || true
        '';
      };
      description = "Backup configuration for UniFi Controller";
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

  config = lib.mkIf cfg.enable {
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

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      # UniFi-specific reverse proxy directives
      extraConfig = ''
        # Handle websockets for real-time updates
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        # WebSocket upgrade headers
        header_up Upgrade {>Upgrade}
        header_up Connection {>Connection}
      '';
    };

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
    networking.firewall.allowedTCPPorts = unifiTcpPorts;
    networking.firewall.allowedUDPPorts = unifiUdpPorts;
  };
}
