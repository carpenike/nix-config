# modules/nixos/services/go2rtc/default.nix
#
# go2rtc - Camera streaming application with RTSP, WebRTC, HLS support
#
# This module wraps the native NixOS services.go2rtc to provide:
# - Standardized integration with homelab infrastructure (Caddy, monitoring, backup)
# - Simplified stream configuration
# - ZFS storage integration
#
# Architecture: Native wrapper (per ADR-005)
# The upstream NixOS module handles the core service; we add homelab patterns.

{ lib, mylib, pkgs, config, ... }:

let
  sharedTypes = mylib.types;
  storageHelpers = mylib.storageHelpers pkgs;

  cfg = config.modules.services.go2rtc;
  storageCfg = config.modules.storage;
  notificationsCfg = config.modules.notifications;

  serviceName = "go2rtc";
  serviceUnit = "${serviceName}.service";
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  hasCentralizedNotifications = notificationsCfg.enable or false;

  defaultHostname =
    let
      domain = config.networking.domain or null;
    in
    if domain == null || domain == "" then "go2rtc.local" else "go2rtc.${domain}";

  # Build replication config for preseed
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
in
{
  options.modules.services.go2rtc = {
    enable = lib.mkEnableOption "go2rtc streaming relay (native NixOS module wrapper)";

    package = lib.mkPackageOption pkgs "go2rtc" { };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = defaultHostname;
      description = "Hostname for reverse proxy registration.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/go2rtc";
      description = "Directory for go2rtc configuration and state.";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 1984;
      description = "Port for go2rtc API/WebUI.";
    };

    rtspPort = lib.mkOption {
      type = lib.types.port;
      default = 8554;
      description = "Port for RTSP server.";
    };

    webrtcPort = lib.mkOption {
      type = lib.types.port;
      default = 8555;
      description = "Port for WebRTC connections.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open firewall ports for go2rtc.

        Opens: apiPort (TCP), rtspPort (TCP), webrtcPort (TCP/UDP)

        Required for:
        - LAN clients accessing RTSP streams directly
        - WebRTC connections from browsers
        - API access from other hosts

        If using only via reverse proxy (Caddy), leave disabled.
      '';
    };

    streams = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        front_door = "rtsp://scrypted.local:8554/front_door";
        backyard = "rtsp://scrypted.local:8554/backyard";
      };
      description = ''
        Camera stream sources. Keys are stream names, values are source URLs.
        Streams from Scrypted use its RTSP rebroadcast URLs.
      '';
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Additional go2rtc configuration merged with module defaults.
        See https://github.com/AlexxIT/go2rtc for full options.
      '';
    };

    manageStorage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically manage ZFS dataset for go2rtc state.";
    };

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Optional reverse proxy configuration for the go2rtc WebUI.";
    };

    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = serviceUnit;
        labels = {
          service = serviceName;
          service_type = "streaming";
        };
      };
      description = "Log shipping configuration.";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "go2rtc streaming relay failed on ${config.networking.hostName}";
      };
      description = "Notification configuration for service failures.";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for go2rtc state (minimal data, usually not needed).";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Restic repository URL for restore operations.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Restic password file.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic.";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Order of restore methods to attempt.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Core service configuration
    {
      assertions = [
        {
          assertion = !(cfg.preseed.enable && cfg.preseed.repositoryUrl == "");
          message = "go2rtc preseed.enable requires preseed.repositoryUrl to be set.";
        }
        {
          assertion = !(cfg.preseed.enable && cfg.preseed.passwordFile == null);
          message = "go2rtc preseed.enable requires preseed.passwordFile to be set.";
        }
      ];

      # Enable native NixOS go2rtc service
      services.go2rtc = {
        enable = true;
        package = cfg.package;
        settings = lib.recursiveUpdate
          {
            api.listen = ":${toString cfg.apiPort}";
            rtsp.listen = ":${toString cfg.rtspPort}";
            webrtc.listen = ":${toString cfg.webrtcPort}";
            streams = cfg.streams;
            ffmpeg.bin = "${pkgs.ffmpeg}/bin/ffmpeg";
          }
          cfg.extraSettings;
      };

      # Ensure go2rtc user exists for proper ownership
      users.users.go2rtc = {
        isSystemUser = true;
        group = "go2rtc";
        home = cfg.dataDir;
        description = "go2rtc streaming service";
      };
      users.groups.go2rtc = { };

      # Systemd service customization
      systemd.services.go2rtc = lib.mkMerge [
        {
          serviceConfig = {
            StateDirectory = "go2rtc";
            StateDirectoryMode = "0750";
          };
        }
        # Failure notifications
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@go2rtc-failure:%n.service" ];
        })
        # Preseed dependency
        (lib.mkIf cfg.preseed.enable {
          wants = [ "preseed-go2rtc.service" ];
          after = [ "preseed-go2rtc.service" ];
        })
      ];

      # Register notification template
      modules.notifications.templates = lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "go2rtc-failure" = {
          enable = lib.mkDefault true;
          priority = lib.mkDefault "high";
          title = lib.mkDefault ''<b><font color="red">✗ Service Failed: go2rtc</font></b>'';
          body = lib.mkDefault ''
            <b>Host:</b> ''${hostname}
            <b>Service:</b> <code>''${serviceName}</code>

            The go2rtc streaming relay has entered a failed state.
            Camera WebRTC feeds to Home Assistant may be unavailable.

            <b>Quick Actions:</b>
            1. Check logs: <code>journalctl -u go2rtc -n 100</code>
            2. Restart: <code>systemctl restart go2rtc</code>
          '';
        };
      };

      # ZFS storage (minimal - go2rtc has little persistent state)
      modules.storage.datasets.services.go2rtc = lib.mkIf cfg.manageStorage {
        mountpoint = cfg.dataDir;
        recordsize = "16K";
        compression = "lz4";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = "go2rtc";
        group = "go2rtc";
        mode = "0750";
      };

      # Firewall rules for LAN access (opt-in)
      networking.firewall = lib.mkIf cfg.openFirewall {
        allowedTCPPorts = [ cfg.apiPort cfg.rtspPort cfg.webrtcPort ];
        allowedUDPPorts = [ cfg.webrtcPort ]; # WebRTC uses UDP
      };

      # Reverse proxy registration
      modules.services.caddy.virtualHosts.go2rtc = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName or cfg.hostname;
        backend = {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.apiPort;
        };
        auth = cfg.reverseProxy.auth;
        security = cfg.reverseProxy.security;
        caddySecurity = cfg.reverseProxy.caddySecurity;
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Backup integration (if configured)
      modules.backup.restic.jobs.go2rtc = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        repository = cfg.backup.repository;
        paths = [ cfg.dataDir ];
        frequency = cfg.backup.frequency;
        retention = cfg.backup.retention;
        tags = cfg.backup.tags or [ "go2rtc" "streaming" "config" ];
        useSnapshots = cfg.backup.useSnapshots;
        zfsDataset = cfg.backup.zfsDataset;
      };
    }

    # Preseed service for disaster recovery
    (lib.mkIf cfg.preseed.enable (
      storageHelpers.mkPreseedService {
        serviceName = "go2rtc";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = serviceUnit;
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "16K";
          compression = "lz4";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = "go2rtc";
        group = "go2rtc";
      }
    ))
  ]);
}
