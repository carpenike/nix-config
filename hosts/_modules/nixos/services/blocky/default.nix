{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.blocky;
  yamlFormat = pkgs.formats.yaml { };
  configFile = yamlFormat.generate "config.yaml" cfg.config;
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  options.modules.services.blocky = {
    enable = lib.mkEnableOption "blocky";
    package = lib.mkPackageOption pkgs "blocky" { };
    config = lib.mkOption {
      inherit (yamlFormat) type;
      default = {};
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 4000;
        path = "/metrics";
        labels = {
          service_type = "dns_filter";
          exporter = "blocky";
          function = "ad_blocking";
        };
      };
      description = "Prometheus metrics collection configuration for Blocky";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Blocky web interface";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "blocky.service";
        labels = {
          service = "blocky";
          service_type = "dns_filter";
        };
      };
      description = "Log shipping configuration for Blocky logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "dns" "blocky" "config" ];
      };
      description = "Backup configuration for Blocky";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "dns-alerts" ];
        };
        customMessages = {
          failure = "Blocky DNS filter failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Blocky service events";
    };
  };

  config = lib.mkIf cfg.enable {
    # Automatically register with Caddy reverse proxy if enabled
    modules.services.caddy.virtualHosts.blocky = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration from shared types
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = 4000;  # Blocky default port
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth;

      # Security configuration from shared types
      security = cfg.reverseProxy.security;

      extraConfig = cfg.reverseProxy.extraConfig;
    };

    systemd.services.blocky = {
      description = "A DNS proxy and ad-blocker for the local network";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${cfg.package}/bin/blocky --config ${configFile}";
        Restart = "on-failure";

        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
    };
  };
}
