# Tautulli Service Module (Native Wrapper)
#
# This module configures the native NixOS `services.tautulli` and wraps it with
# the homelab's standardized patterns for ZFS, backups, monitoring, and DR.
#
# DESIGN RATIONALE:
# Tautulli has a native NixOS module (`services.tautulli`), so we wrap it rather
# than creating a container. This approach provides:
#   - Simpler updates (nix flake update vs manual image pinning)
#   - Better NixOS integration (direct systemd, not container wrapper)
#   - Maintained by Nixpkgs (security patches handled upstream)
#
# AUTHENTICATION:
# Tautulli does NOT support proxy auth bypass (like Sonarr/Radarr's AuthenticationMethod=External).
# Authentication must be handled by Tautulli itself (Plex auth or HTTP Basic).
# Using PocketID would result in double authentication, so we skip it.
#
# Reference: Gatus module for native wrapper pattern
{ lib
, mylib
, pkgs
, config
, ...
}:
let
  inherit (lib) mkIf mkMerge mkEnableOption mkOption mkDefault;

  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = mylib.types;

  cfg = config.modules.services.tautulli;
  notificationsCfg = config.modules.notifications;
  storageCfg = config.modules.storage;
  hasCentralizedNotifications = notificationsCfg.enable or false;
  tautulliPort = 8181;
  serviceName = "tautulli";
  serviceUnitFile = "${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/tautulli";

  # Recursively find the replication config from the most specific dataset path upwards.
  findReplication = dsPath:
    if dsPath == "" || dsPath == "." then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets;
        replicationInfo = (sanoidDatasets.${dsPath} or { }).replication or null;
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
  options.modules.services.tautulli = {
    enable = mkEnableOption "Tautulli Plex monitoring service";

    package = mkOption {
      type = lib.types.package;
      default = pkgs.tautulli;
      description = "The Tautulli package to use";
    };

    dataDir = mkOption {
      type = lib.types.path;
      default = "/var/lib/tautulli";
      description = "Path to Tautulli data directory";
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
        default = "120s";
        description = "Grace period for service initialization before health check failures count";
      };
    };

    # Standardized reverse proxy integration
    reverseProxy = mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Tautulli web interface";
    };

    # Standardized logging integration
    logging = mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnitFile;
        labels = {
          service = "tautulli";
          service_type = "media-monitoring";
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
        tags = mkDefault [ "media" "tautulli" "plex-monitoring" ];
        useSnapshots = mkDefault true;
        zfsDataset = mkDefault datasetPath;
        excludePatterns = mkDefault [
          "**/cache/**"
          "**/logs/**"
          "**/*.log"
        ];
      };
      description = "Backup configuration";
    };

    # Standardized notifications
    notifications = mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = { onFailure = [ "system-alerts" ]; };
        customMessages = { failure = "Tautulli Plex monitoring service failed on ${config.networking.hostName}"; };
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
          message = "Tautulli backup.enable requires backup.repository to be set.";
        }
        {
          assertion = !cfg.preseed.enable || cfg.preseed.repositoryUrl != "";
          message = "Tautulli preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = !cfg.preseed.enable || (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
          message = "Tautulli preseed.enable requires preseed.passwordFile to be set.";
        }
      ];

      # Enable the native NixOS Tautulli service
      services.tautulli = {
        enable = true;
        package = cfg.package;
        port = tautulliPort;
        dataDir = cfg.dataDir;
        configFile = "${cfg.dataDir}/config.ini"; # Use same directory as dataDir
        # Use our custom user/group for ZFS dataset ownership consistency
        user = "tautulli";
        group = "tautulli";
      };

      # Auto-register with Caddy reverse proxy
      modules.services.caddy.virtualHosts."tautulli" = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = tautulliPort;
        };
        # No auth - Tautulli has built-in authentication (Plex or HTTP Basic)
        # Using PocketID would require double-auth since Tautulli can't disable its auth
        auth = cfg.reverseProxy.auth or null;
        security = cfg.reverseProxy.security or { };
        extraConfig = cfg.reverseProxy.extraConfig or "";
      };

      # ZFS dataset management
      modules.storage.datasets.services."tautulli" = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimal for SQLite (Tautulli database)
        compression = "zstd";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = "tautulli";
        group = "tautulli";
        mode = "0750";
      };

      # Systemd service dependencies and notifications
      systemd.services."${serviceName}" = {
        unitConfig = {
          # Ensure ZFS mount is available before service starts
          RequiresMountsFor = [ cfg.dataDir ];
        } // (mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          OnFailure = [ "notify@tautulli-failure:%n.service" ];
        });
        wants = mkIf cfg.preseed.enable [ "preseed-tautulli.service" ];
        after = mkIf cfg.preseed.enable [ "preseed-tautulli.service" ];
      };

      # Create static user for tautulli (instead of default "plexpy")
      users.users.tautulli = {
        isSystemUser = true;
        group = "tautulli";
        description = "Tautulli service user";
      };

      users.groups.tautulli = { };

      # Health check timer (uses curl to verify web UI)
      systemd.timers.tautulli-healthcheck = mkIf cfg.healthcheck.enable {
        description = "Tautulli Health Check Timer";
        wantedBy = [ "timers.target" ];
        after = [ serviceUnitFile ];
        timerConfig = {
          OnActiveSec = cfg.healthcheck.startPeriod;
          OnUnitActiveSec = cfg.healthcheck.interval;
          Persistent = false;
        };
      };

      systemd.services.tautulli-healthcheck = mkIf cfg.healthcheck.enable {
        description = "Tautulli Health Check";
        after = [ serviceUnitFile ];
        requires = [ serviceUnitFile ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "tautulli-healthcheck" ''
            set -euo pipefail
            if ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 10 http://127.0.0.1:${toString tautulliPort}/; then
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
        "tautulli-failure" = {
          enable = mkDefault true;
          priority = mkDefault "high";
          title = mkDefault ''<b><font color="red">✗ Service Failed: Tautulli</font></b>'';
          body = mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>
            The Tautulli Plex monitoring service has entered a failed state.
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
        serviceName = "tautulli";
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
        owner = "tautulli";
        group = "tautulli";
      }
    ))

    # CRITICAL: Ensure proper directory access for ZFS-managed data directory
    # The native module creates tmpfiles with correct user/group since we set them above
    (mkIf cfg.enable {
      systemd.services."${serviceName}".serviceConfig = {
        # Explicitly grant write access to the data directory (for systemd sandboxing)
        ReadWritePaths = lib.mkForce [ cfg.dataDir ];
      };
    })
  ];
}
