{ config, lib, mylib, pkgs, ... }:
let
  cfg = config.modules.services.glances;
  # Service UID/GID from centralized registry
  serviceIds = mylib.serviceUids.glances;
  # Import shared type definitions
  sharedTypes = mylib.types;
in
{
  options.modules.services.glances = {
    enable = lib.mkEnableOption "Glances system monitoring";

    port = lib.mkOption {
      type = lib.types.port;
      default = 61208;
      description = "Port for Glances web interface (binds to localhost only)";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--disable-plugin" "docker" ];
      description = "Extra command-line arguments for the glances command";
    };

    resources = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        MemoryMax = "256M";
        CPUQuota = "30%";
      };
      description = "Resource limits for the Glances systemd service";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 61208; # Same as web interface - Glances exports metrics on /api/3/metrics
        path = "/api/3/metrics";
        labels = {
          service_type = "system_monitoring";
          exporter = "glances";
        };
      };
      description = "Prometheus metrics collection configuration";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Glances web interface";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install glances
    environment.systemPackages = [ pkgs.glances ];

    # Glances web service
    systemd.services.glances-web = {
      description = "Glances Web Server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.glances}/bin/glances -w --bind 127.0.0.1 --port ${toString cfg.port} ${lib.escapeShellArgs cfg.extraArgs}";
        Restart = "always";
        User = "glances";
        Group = "glances";

        # Security Hardening
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;

        # Resource Limits
        MemoryMax = cfg.resources.MemoryMax;
        CPUQuota = cfg.resources.CPUQuota;
      };
    };

    # Create user for glances
    users.users.glances = {
      uid = serviceIds.uid;
      isSystemUser = true;
      group = "glances";
    };

    users.groups.glances = {
      gid = serviceIds.gid;
    };

    # Auto-register with Caddy reverse proxy if configured
    modules.services.caddy.virtualHosts.glances = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName or "${config.networking.hostName}.${config.networking.domain}";

      # Use structured backend configuration from shared types
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };

      # Authentication from shared types
      auth = cfg.reverseProxy.auth;

      # Security configuration
      security = cfg.reverseProxy.security;

      extraConfig = cfg.reverseProxy.extraConfig;
    };
  };
}
