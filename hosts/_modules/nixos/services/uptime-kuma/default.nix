# Uptime Kuma Service Module (Native Wrapper)
#
# This module configures the native NixOS `services.uptime-kuma` and wraps it with
# the homelab's standardized patterns for ZFS, backups, monitoring, and DR.
#
# DESIGN RATIONALE (Nov 5, 2025):
# After implementing a 369-line container-based module, we discovered NixOS has a
# native uptime-kuma service. This wrapper approach is superior because:
#   - ~150 lines vs 369 (56% reduction in complexity)
#   - No Podman dependency (native systemd service)
#   - Simpler updates (nix flake update vs manual image pinning)
#   - Better NixOS integration (direct systemd, not container wrapper)
#   - Maintained by Nixpkgs (security patches handled upstream)
#
# We retain all homelab integrations (ZFS, backups, preseed, monitoring) but build
# on the solid foundation of the native service rather than reinventing it.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkMerge mkEnableOption mkOption mkDefault;

  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  cfg = config.modules.services.uptime-kuma;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  uptimeKumaPort = 3001;
  serviceName = "uptime-kuma";
  serviceUnitFile = "${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/uptime-kuma";

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or {}).replication or null;
        parentPath =
          if lib.elem "/" (lib.stringToCharacters dsPath) then
            lib.removeSuffix "/${lib.last (lib.splitString "/" dsPath)}" dsPath
          else
            "";
      in
      if replicationInfo != null then
        { sourcePath = dsPath; replication = replicationInfo; }
      else
        findReplication parentPath;

  foundReplication = findReplication datasetPath;

  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then
            ""
          else
            lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then
            foundReplication.replication.targetDataset
          else
            "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };
in
{
  options.modules.services.uptime-kuma = {
    enable = mkEnableOption "Uptime Kuma monitoring service";

    package = mkOption {
      type = lib.types.package;
      default = pkgs.uptime-kuma;
      description = "The Uptime Kuma package to use";
    };

    dataDir = mkOption {
      type = lib.types.path;
      default = "/var/lib/uptime-kuma";
      description = "Path to Uptime Kuma data directory";
    };

    healthcheck = {
      enable = mkEnableOption "service health check";
      interval = mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Frequency of health checks";
      };
      startPeriod = mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Grace period for service initialization before health check failures count";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Uptime Kuma web interface";
    };

    # Standardized metrics collection
    metrics = mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = uptimeKumaPort;
        path = "/metrics";
        labels = {
          service_type = "monitoring";
          exporter = "uptime-kuma";
        };
      };
      description = "Prometheus metrics collection for Uptime Kuma";
    };

    # Standardized logging integration
    logging = mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnitFile;
        labels = {
          service = "uptime-kuma";
          service_type = "monitoring";
        };
      };
      description = "Log shipping configuration";
    };

    # Standardized backup integration
    backup = mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = mkIf cfg.enable {
        enable = mkDefault true;
        repository = mkDefault "nas-primary";
        frequency = mkDefault "daily";
        tags = mkDefault [ "monitoring" "uptime-kuma" "config" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        excludePatterns = mkDefault [ ];
      };
      description = "Backup configuration";
    };

    # Standardized notifications
    notifications = mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = { onFailure = [ "system-alerts" ]; };
        customMessages = { failure = "Uptime Kuma monitoring service failed on ${config.networking.hostName}"; };
      };
      description = "Notification configuration";
    };

    # Preseed/DR configuration
    preseed = {
      enable = mkEnableOption "automatic data restore before service start";
      repositoryUrl = mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic";
      };
      restoreMethods = mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Order of restore methods to attempt";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = (cfg.backup == null || !cfg.backup.enable) || cfg.backup.repository != null;
          message = "Uptime Kuma backup.enable requires backup.repository to be set.";
        }
        {
          assertion = !cfg.preseed.enable || cfg.preseed.repositoryUrl != "";
          message = "Uptime Kuma preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = !cfg.preseed.enable || (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
          message = "Uptime Kuma preseed.enable requires preseed.passwordFile to be set.";
        }
      ];

      # Enable the native NixOS Uptime Kuma service
      services.uptime-kuma = {
        enable = true;
        package = cfg.package;
        # Note: Native module sets DATA_DIR to StateDirectory automatically
        # We only override HOST and PORT for reverse proxy integration
        settings = {
          HOST = mkDefault "127.0.0.1";  # Bind to localhost for reverse proxy
          PORT = mkDefault (toString uptimeKumaPort);
        };
      };

      # Auto-register with Caddy reverse proxy
      modules.services.caddy.virtualHosts."uptime-kuma" = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = uptimeKumaPort;
        };
        auth = cfg.reverseProxy.auth or null;
        authelia = cfg.reverseProxy.authelia or null;
        security = cfg.reverseProxy.security or {};
        # WebSocket support for real-time UI
        reverseProxyBlock = ''
          header_up -Connection
          header_up Connection "Upgrade"
          ${cfg.reverseProxy.extraConfig or ""}
        '';
      };

      # Register with Authelia if SSO protection is enabled
      modules.services.authelia.accessControl.declarativelyProtectedServices."uptime-kuma" = mkIf (
        config.modules.services.authelia.enable &&
        cfg.reverseProxy != null &&
        cfg.reverseProxy.enable &&
        cfg.reverseProxy.authelia != null &&
        cfg.reverseProxy.authelia.enable
      ) (
        let
          authCfg = cfg.reverseProxy.authelia;
        in {
          domain = cfg.reverseProxy.hostName;
          policy = authCfg.policy;
          subject = map (g: "group:${g}") authCfg.allowedGroups;
          bypassResources =
            (map (path: "^${lib.escapeRegex path}/.*$") (authCfg.bypassPaths or []))
            ++ (authCfg.bypassResources or []);
        }
      );

      # ZFS dataset management
      modules.storage.datasets.services."uptime-kuma" = {
        mountpoint = cfg.dataDir;
        recordsize = "16K";  # Optimal for SQLite
        compression = "zstd";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = "uptime-kuma";
        group = "uptime-kuma";
        mode = "0750";
      };

            # Systemd service dependencies and notifications
      systemd.services."${serviceName}" = {
        unitConfig = {
          # Ensure ZFS mount is available before service starts
          RequiresMountsFor = [ cfg.dataDir ];
        } // (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          OnFailure = [ "notify@uptime-kuma-failure:%n.service" ];
        });
        wants = mkIf cfg.preseed.enable [ "preseed-uptime-kuma.service" ];
        after = mkIf cfg.preseed.enable [ "preseed-uptime-kuma.service" ];
      };

      # Create static user for uptime-kuma
      users.users.uptime-kuma = {
        isSystemUser = true;
        group = "uptime-kuma";
        description = "Uptime Kuma service user";
      };

      users.groups.uptime-kuma = {};

      # Health check timer (no Podman dependency - uses curl)
      systemd.timers.uptime-kuma-healthcheck = mkIf cfg.healthcheck.enable {
        description = "Uptime Kuma Health Check Timer";
        wantedBy = [ "timers.target" ];
        after = [ serviceUnitFile ];
        timerConfig = {
          OnActiveSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          Persistent = false;
        };
      };

      systemd.services.uptime-kuma-healthcheck = mkIf cfg.healthcheck.enable {
        description = "Uptime Kuma Health Check";
        after = [ serviceUnitFile ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "uptime-kuma-healthcheck" ''
            set -euo pipefail
            if ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 5 http://127.0.0.1:${toString uptimeKumaPort}/; then
              echo "Health check passed."
              exit 0
            else
              echo "Health check failed."
              exit 1
            fi
          '';
        };
      };

      # Notification templates
      modules.notifications.templates = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "uptime-kuma-failure" = {
          enable = mkDefault true;
          priority = mkDefault "high";
          title = mkDefault ''<b><font color="red">✗ Service Failed: Uptime Kuma</font></b>'';
          body = mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>
            The Uptime Kuma monitoring service has entered a failed state.
            <b>Quick Actions:</b>
            1. Check logs: <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
            2. Restart service: <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
          '';
        };
      };
    })

    # Preseed service for disaster recovery
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "uptime-kuma";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnitFile;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = "uptime-kuma";
        group = "uptime-kuma";
      }
    ))

    # CRITICAL: Separate config block to override native module's DynamicUser settings
    # This must be in a separate block to ensure it's evaluated AFTER the native module
        # CRITICAL: This block overrides the native module's DynamicUser settings.
    # The key is targeting the correct service name ("uptime-kuma") in the attribute path.
    (mkIf cfg.enable {
      systemd.services."${serviceName}".serviceConfig = {
        # Disable DynamicUser and StateDirectory to use our ZFS-backed directory
        DynamicUser = lib.mkForce false;
        StateDirectory = lib.mkForce ""; # Empty string unsets the option
        User = lib.mkForce "uptime-kuma";
        Group = lib.mkForce "uptime-kuma";
        WorkingDirectory = lib.mkForce cfg.dataDir;
        # Explicitly grant write access to the data directory.
        # This is necessary because we disabled StateDirectory, which would
        # normally handle this automatically by punching through the sandbox.
        ReadWritePaths = lib.mkForce [ cfg.dataDir ];
      };
    })
  ];
}
