{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.modules.services.bind;
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  imports = [ ./shared.nix ]; # Import the shared options module

  options.modules.services.bind = {
    enable = lib.mkEnableOption "bind";
    package = lib.mkPackageOption pkgs "bind" { };
    config = lib.mkOption {
      type = lib.types.str;
      default = "";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null;
      description = "Prometheus metrics collection configuration";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "bind.service";
        labels = {
          service = "bind";
          service_type = "dns_server";
        };
      };
      description = "Log shipping configuration for BIND logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        repository = lib.mkDefault "nas-primary";
        frequency = lib.mkDefault "daily";
        tags = lib.mkDefault [ "dns" "bind" "config" ];
        preBackupScript = lib.mkDefault ''
          # Backup BIND configuration and zone files
          mkdir -p /tmp/bind-backup
          cp -r ${config.services.bind.directory}/*.{zone,conf} /tmp/bind-backup/ 2>/dev/null || true
        '';
      };
      description = "Backup configuration for BIND";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "critical-dns" ];
          onHealthCheck = [ "dns-monitoring" ];
        };
        customMessages = {
          failure = "BIND DNS server failed on ${config.networking.hostName}";
          healthCheck = "BIND health check failed - DNS resolution may be impacted";
        };
      };
      description = "Notification configuration for BIND service events";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.resolvconf.useLocalResolver = lib.mkForce false;

    # Clean up journal files
    systemd.services.bind = {
      preStart = lib.mkAfter ''
        rm -rf ${config.services.bind.directory}/*.jnl
      '';
    };

    services.bind = {
      enable = true;
      inherit (cfg) package;
      ipv4Only = true;
      configFile = pkgs.writeText "bind.cfg" cfg.config;
    };
  };
}
