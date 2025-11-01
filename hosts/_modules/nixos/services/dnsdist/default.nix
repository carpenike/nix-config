{
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.dnsdist;
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  imports = [ ./shared.nix ];

  options.modules.services.dnsdist = {
    enable = lib.mkEnableOption "dnsdist";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
    };
    listenPort = lib.mkOption {
      type = lib.types.int;
      default = 53;
    };
    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8083;
        path = "/metrics";
        labels = {
          service_type = "dns_proxy";
          exporter = "dnsdist";
          function = "load_balancing";
        };
      };
      description = "Prometheus metrics collection configuration for dnsdist";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for dnsdist web interface";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "dnsdist.service";
        labels = {
          service = "dnsdist";
          service_type = "dns_proxy";
        };
      };
      description = "Log shipping configuration for dnsdist logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "dns" "dnsdist" "config" ];
      };
      description = "Backup configuration for dnsdist";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "critical-dns" ];
        };
        customMessages = {
          failure = "dnsdist DNS load balancer failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for dnsdist service events";
    };
  };

  config = lib.mkIf cfg.enable {
    services.dnsdist.enable = true;
    services.dnsdist.listenAddress = cfg.listenAddress;
    services.dnsdist.listenPort = cfg.listenPort;
    services.dnsdist.extraConfig = cfg.config;
    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
    networking.firewall.allowedUDPPorts = [ cfg.listenPort ];
  };

}
