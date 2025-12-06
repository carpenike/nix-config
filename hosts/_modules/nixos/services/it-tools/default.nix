# IT-Tools - Collection of useful web-based developer utilities
#
# IT-Tools provides 45+ web-based tools for developers including:
# - UUID generators, Base64 encoders, JWT parsers
# - Password generators, QR code generators
# - Color converters, hash generators, and more
#
# This service is completely stateless - no persistent data required.
# All tools run client-side in the browser.
#
# Usage:
#   modules.services.it-tools = {
#     enable = true;
#     reverseProxy = {
#       enable = true;
#       hostName = "it-tools.holthome.net";
#     };
#   };

{ lib
, config
, podmanLib
, ...
}:
let
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.it-tools;
  serviceName = "it-tools";
  backend = config.virtualisation.oci-containers.backend;
  containerPort = 80; # IT-Tools listens on port 80 inside the container
  domain = config.networking.domain or null;
  defaultHostname = if domain == null || domain == "" then "it-tools.local" else "it-tools.${domain}";
in
{
  options.modules.services.it-tools = {
    enable = lib.mkEnableOption "IT-Tools - web-based developer utilities collection";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8380;
      description = "Host port to expose IT-Tools web interface";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "corentinth/it-tools:latest@sha256:8b8128748339583ca951af03dfe02a9a4d7363f61a216226fc28030731a5a61f";
      description = ''
        Full container image name including tag and digest for immutability.

        Best practices:
        - Pin to specific version tags with digests
        - Use Renovate bot to automate version updates

        Note: IT-Tools uses rolling releases, so pinning with digest is important.
      '';
      example = "corentinth/it-tools:latest@sha256:...";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = defaultHostname;
      description = "Friendly hostname used for reverse proxy and alerts.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "128M";
        memoryReservation = "64M";
        cpus = "0.5";
      };
      description = ''
        Resource limits for the container.
        IT-Tools is lightweight and serves static content, so minimal resources are needed.
      '';
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "10s";
      };
      description = "Container health check configuration. IT-Tools starts quickly.";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for IT-Tools web interface";
    };
  };

  config = lib.mkIf cfg.enable {
    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.it-tools = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # PocketID / caddy-security configuration (if needed)
      caddySecurity = cfg.reverseProxy.caddySecurity;

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      extraConfig = cfg.reverseProxy.extraConfig;
    };

    # IT-Tools container configuration
    # Note: IT-Tools is completely stateless - no volumes needed
    virtualisation.oci-containers.containers.it-tools = podmanLib.mkContainer serviceName {
      image = cfg.image;

      environment = {
        TZ = cfg.timezone;
      };

      # Map host port to container port 80
      ports = [ "${toString cfg.port}:${toString containerPort}" ];

      # No volumes needed - IT-Tools is stateless

      extraOptions =
        (lib.optionals (cfg.resources != null) [
          "--memory=${cfg.resources.memory}"
          "--memory-reservation=${cfg.resources.memoryReservation}"
          "--cpus=${cfg.resources.cpus}"
        ])
        ++ (lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
          "--health-cmd=wget --no-verbose --tries=1 --spider http://127.0.0.1:${toString containerPort}/ || exit 1"
          "--health-interval=${cfg.healthcheck.interval}"
          "--health-timeout=${cfg.healthcheck.timeout}"
          "--health-retries=${toString cfg.healthcheck.retries}"
          "--health-start-period=${cfg.healthcheck.startPeriod}"
          "--health-on-failure=${cfg.healthcheck.onFailure}"
        ]);
    };

    # Override systemd service for better integration
    systemd.services."${backend}-${serviceName}" = {
      description = "IT-Tools - Web-based developer utilities";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
