{ config, lib, pkgs, ... }:
let
  cfg = config.modules.services.glances;
  # TODO: Re-enable shared types once nix store path issues are resolved
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

    # Standardized metrics collection pattern (simplified)
    metrics = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
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

    # Standardized reverse proxy integration (simplified)
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
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
      isSystemUser = true;
      group = "glances";
    };

    users.groups.glances = {};

    # Auto-register with Caddy reverse proxy if configured
    modules.services.caddy.virtualHosts.glances = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName or "${config.networking.hostName}.${config.networking.domain}";
      backend = cfg.reverseProxy.backend or {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };
      auth = cfg.reverseProxy.auth or null;
      security = cfg.reverseProxy.security or {};
      extraConfig = cfg.reverseProxy.extraConfig or "";
    };
  };
}
