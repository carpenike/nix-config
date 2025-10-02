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
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          memory = lib.mkOption {
            type = lib.types.str;
            default = "1g";
            description = "Memory limit for the container (e.g., '512m', '1g')";
          };
          memoryReservation = lib.mkOption {
            type = lib.types.str;
            default = "512m";
            description = "Memory reservation (soft limit) for the container";
          };
          cpus = lib.mkOption {
            type = lib.types.str;
            default = "1";
            description = "CPU limit in cores (e.g., '0.5', '1', '2')";
          };
        };
      });
      default = {
        memory = "1g";
        memoryReservation = "512m";
        cpus = "1";
      };
      description = "Resource limits for the Unifi container (recommended for homelab stability)";
    };

    # Reverse proxy integration options
    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy integration for UniFi";
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "unifi";
        description = "Subdomain to use for the reverse proxy";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "UniFi Controller HTTPS port for reverse proxy";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    modules.services.podman.enable = true;

    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      hostName = "${cfg.reverseProxy.subdomain}.${config.modules.services.caddy.domain or config.networking.domain or "holthome.net"}";
      proxyTo = "https://localhost:${toString cfg.reverseProxy.port}";
      httpsBackend = true; # UniFi uses HTTPS
      headers = ''
        # Handle websockets for real-time updates
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        # UniFi specific headers
        header_up Upgrade {>Upgrade}
        header_up Connection {>Connection}
      '';
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
