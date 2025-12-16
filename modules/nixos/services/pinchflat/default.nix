# Pinchflat YouTube media manager module
#
# This module wraps the native NixOS Pinchflat service with homelab-specific patterns:
# - ZFS storage integration for SQLite database persistence
# - NFS mount dependency for media downloads to shared storage
# - Caddy reverse proxy with PocketID authentication
# - Built-in Prometheus metrics via ENABLE_PROMETHEUS environment variable
# - Standard backup, alerting, and preseed/DR integrations
#
# Architecture Decision: Native NixOS module wrapper (preferred over container)
# Pinchflat is an Elixir application with SQLite that has a native nixpkgs module.
#
# Usage:
#   modules.services.pinchflat = {
#     enable = true;
#     mediaDir = "/mnt/data/youtube";
#     reverseProxy = {
#       enable = true;
#       hostName = "pinchflat.holthome.net";
#       caddySecurity = forgeDefaults.caddySecurity.media;
#     };
#     backup = forgeDefaults.backup;
#   };
#
{ config, lib, mylib, pkgs, ... }:

let
  # Import pure storage helpers library (not a module argument to avoid circular dependency)
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  cfg = config.modules.services.pinchflat;
  serviceName = "pinchflat";

  # Import shared types for standard submodules
  sharedTypes = mylib.types;

  # Look up the NFS mount configuration if a dependency is declared
  nfsMountName = cfg.nfsMountDependency;
  nfsMountConfig = storageHelpers.mkNfsMountConfig { inherit config; nfsMountDependency = nfsMountName; };
in
{
  options.modules.services.pinchflat = {
    enable = lib.mkEnableOption "Pinchflat YouTube media manager";

    # Storage configuration
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/pinchflat";
      description = "Directory for Pinchflat configuration and database";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/pinchflat/media";
      description = ''
        Directory where Pinchflat downloads videos.
        Typically set to an NFS mount path like "/mnt/data/youtube".
      '';
    };

    # Network configuration
    port = lib.mkOption {
      type = lib.types.port;
      default = 8945;
      description = "Port for Pinchflat web interface";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warning" "error" ];
      default = "info";
      description = "Pinchflat log level";
    };

    # User configuration
    user = lib.mkOption {
      type = lib.types.str;
      default = "pinchflat";
      description = "User account under which Pinchflat runs";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 930;
      description = "UID for pinchflat user (must be unique and consistent across hosts)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Primary group for Pinchflat (use 'media' for NFS access)";
    };

    # NFS mount dependency for media storage
    nfsMountDependency = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "media";
      description = ''
        Name of the NFS mount to depend on for media storage.
        When set, the service will wait for the NFS mount to be available.
      '';
    };

    # ZFS dataset configuration
    zfs = {
      enable = lib.mkEnableOption "ZFS dataset for Pinchflat data" // { default = true; };

      dataset = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "tank/services/pinchflat";
        description = "ZFS dataset for Pinchflat configuration and database";
      };

      recordsize = lib.mkOption {
        type = lib.types.str;
        default = "16K";
        description = "ZFS recordsize - 16K recommended for SQLite databases";
      };

      compression = lib.mkOption {
        type = lib.types.str;
        default = "lz4";
        description = "ZFS compression algorithm";
      };
    };

    # Secrets configuration
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to secrets file containing environment variables:
        - SECRET_KEY_BASE (required, 64+ bytes)
        - YOUTUBE_API_KEY (optional, for faster metadata fetching)

        Generate SECRET_KEY_BASE with: openssl rand -hex 64
      '';
    };

    # Extra environment variables
    extraConfig = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
      default = { };
      example = {
        ENABLE_PROMETHEUS = true;
        YT_DLP_WORKER_CONCURRENCY = 2;
      };
      description = "Additional environment variables for Pinchflat";
    };

    # Prometheus metrics configuration
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = 8945;
        path = "/metrics";
        labels = {
          service_type = "media";
          exporter = "pinchflat";
          function = "youtube";
        };
      };
      description = "Prometheus metrics configuration. Pinchflat exposes native /metrics endpoint.";
    };

    # Reverse proxy configuration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Caddy integration";
    };

    # Backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration using unified backup system";
    };

    # Notification configuration
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification configuration for service events";
    };

    # Preseed/DR configuration
    preseed = {
      enable = lib.mkEnableOption "automatic restore before service start";

      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/nas-backup";
        description = "URL to Restic backup repository for preseed restore";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic repository password file";
      };

      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = ''
          Restore methods to try in order.
          Policy: Exclude "restic" - offsite restore is manual DR only.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Assertions for required configuration
    assertions = [
      {
        assertion = cfg.secretsFile != null;
        message = "modules.services.pinchflat.secretsFile must be set with SECRET_KEY_BASE";
      }
      {
        assertion = nfsMountName == null || nfsMountConfig != null;
        message = "Pinchflat nfsMountDependency '${nfsMountName}' does not exist in modules.storage.nfsMounts.";
      }
    ];

    # Enable the native NixOS Pinchflat service
    services.pinchflat = {
      enable = true;
      port = cfg.port;
      mediaDir = cfg.mediaDir;
      logLevel = cfg.logLevel;
      secretsFile = cfg.secretsFile;
      selfhosted = false; # We provide proper secrets
      # Pass through user/group to native module (available in nixos-25.11+)
      # Since we use non-default values, WE are responsible for creating them
      user = cfg.user;
      group = cfg.group;

      # Pass through extra configuration with Prometheus enabled
      extraConfig = cfg.extraConfig // (lib.optionalAttrs (cfg.metrics != null && cfg.metrics.enable) {
        ENABLE_PROMETHEUS = true;
      });
    };

    # Create pinchflat user with stable UID and media group membership
    # Use mkForce to override native module's conditional user creation
    users.users.${cfg.user} = lib.mkForce {
      isSystemUser = true;
      uid = cfg.uid;
      group = cfg.group;
      # Extra groups ensure media group access for NFS even if primary group differs
      extraGroups = lib.optionals (cfg.group != "media") [ "media" ];
      home = "/var/empty";
      description = "Pinchflat YouTube media manager service user";
    };

    # Ensure media group exists (shared with other media services)
    users.groups.media = {
      gid = lib.mkDefault 65537; # Shared media group
    };

    # Override systemd service for ZFS and NFS dependencies
    systemd.services.pinchflat = {
      # Wait for ZFS and NFS mounts
      after = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ]
        ++ lib.optionals (nfsMountConfig != null) [ nfsMountConfig.mountUnitName ];
      wants = lib.optionals (cfg.zfs.dataset != null) [ "zfs-mount.service" ]
        ++ lib.optionals (nfsMountConfig != null) [ nfsMountConfig.mountUnitName ];
      requires = lib.optionals (nfsMountConfig != null) [ nfsMountConfig.mountUnitName ];

      serviceConfig = {
        # Disable DynamicUser - we manage our own user with stable UID
        DynamicUser = lib.mkForce false;
        User = lib.mkForce cfg.user;
        Group = lib.mkForce cfg.group;

        # Allow reading/writing to NFS media directory and data directory
        ReadWritePaths = [ cfg.dataDir ] ++ lib.optionals (nfsMountConfig != null) [ cfg.mediaDir ];
      };
    };

    # ZFS dataset configuration
    modules.storage.datasets.services.${serviceName} = lib.mkIf (cfg.zfs.enable && cfg.zfs.dataset != null) {
      mountpoint = cfg.dataDir;
      recordsize = cfg.zfs.recordsize;
      compression = cfg.zfs.compression;
      owner = cfg.user;
      group = cfg.group;
      mode = "0750";
    };

    # Caddy reverse proxy registration
    modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      # Use structured backend configuration - Pinchflat uses HTTP locally
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = cfg.port;
      };

      # Authentication configuration from shared types
      auth = cfg.reverseProxy.auth or null;

      # PocketID / caddy-security configuration
      caddySecurity = cfg.reverseProxy.caddySecurity or null;

      # Security configuration from shared types
      security = cfg.reverseProxy.security or null;

      extraConfig = cfg.reverseProxy.extraConfig or "";
    };

    # NOTE: Gatus contributions should be set in host config,
    # not auto-generated here. See hosts/forge/README.md for contribution pattern.

    # Prometheus scrape target (auto-discovered via observability module)
    # Pinchflat exposes native /metrics endpoint when ENABLE_PROMETHEUS=true

    # Firewall - only expose on localhost
    networking.firewall = {
      interfaces.lo.allowedTCPPorts = [ cfg.port ];
    };
  };
}
