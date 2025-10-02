{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.modules.services.podman.containerDefaults;
in
{
  options.modules.services.podman.containerDefaults = {
    enable = lib.mkEnableOption "default container configuration";

    logDriver = lib.mkOption {
      type = lib.types.enum [ "journald" "json-file" "k8s-file" "none" ];
      default = "journald";
      description = "Default logging driver for containers";
    };

    logTag = lib.mkOption {
      type = lib.types.str;
      default = "{{.Name}}";
      description = "Default log tag template for containers";
    };

    enableLogRotation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable logrotate for application logs in volumes";
    };

    logRotationDefaults = lib.mkOption {
      type = lib.types.attrs;
      default = {
        frequency = "daily";
        rotate = 7;
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        maxsize = "100M";
      };
      description = "Default logrotate settings for application logs";
    };

    # Resource limit defaults for homelab deployments
    defaultResourceLimits = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable default resource limits for containers to prevent resource exhaustion";
    };
  };

  config = lib.mkIf (cfg.enable && config.modules.services.podman.enable) {
    # Global container defaults via containers.conf
    virtualisation.containers.enable = true;
    virtualisation.containers.containersConf.settings = {
      containers = {
        log_driver = cfg.logDriver;
        log_tag = cfg.logTag;
      };
    };

    # Enhanced journald configuration for containers
    services.journald.extraConfig = ''
      # Increased rate limits for container logs
      RateLimitBurst=10000
      RateLimitInterval=30s
      # Storage limits
      SystemMaxUse=2G
      RuntimeMaxUse=1G
      # Better container log handling
      MaxLevelStore=info
      MaxLevelSyslog=info
    '';

    # Enable logrotate if needed
    services.logrotate.enable = cfg.enableLogRotation;
  };
}
