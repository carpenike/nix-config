# Attic Binary Cache Server Configuration
{ config, lib, pkgs, mylib, ... }:

let
  cfg = config.modules.services.attic;
  # Import shared type definitions
  sharedTypes = mylib.types;
  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;
  # Storage configuration for dataset path
  storageCfg = config.modules.storage.datasets or { enable = false; };
  datasetPath =
    if storageCfg.enable or false
    then "${storageCfg.parentDataset or "rpool/safe/persist"}/attic"
    else null;
  mainServiceUnit = "atticd.service";
  hasCentralizedNotifications = config.modules.notifications.enable or false;
in
{
  options.modules.services.attic = {
    enable = lib.mkEnableOption "Attic binary cache server";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8080";
      description = "Address for Attic server to listen on";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/atticd";
      description = "Directory for Attic data";
    };

    storageType = lib.mkOption {
      type = lib.types.enum [ "local" "s3" ];
      default = "local";
      description = "Storage backend for cache artifacts";
    };

    storageConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Storage-specific configuration";
    };

    jwtSecretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the JWT HMAC secret (base64 encoded)";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Attic web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = null; # Attic doesn't expose Prometheus metrics by default
      description = "Prometheus metrics collection configuration for Attic";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "atticd.service";
        labels = {
          service = "attic";
          service_type = "binary_cache";
        };
      };
      description = "Log shipping configuration for Attic logs";
    };

    # Standardized backup integration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        frequency = "daily";
        tags = [ "cache" "attic" "nix" ];
        excludePatterns = [
          "**/*.tmp" # Exclude temporary files
          "**/locks/*" # Exclude lock files
        ];
      };
      description = "Backup configuration for Attic";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "infrastructure-alerts" ];
        };
        customMessages = {
          failure = "Attic binary cache server failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Attic service events";
    };

    # Preseed configuration for disaster recovery
    preseed = {
      enable = lib.mkEnableOption "automatic restore before service start";

      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "URL to Restic repository for preseed restore";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing the Restic repository password";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to environment file for remote repository credentials";
      };

      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = "Ordered list of restore methods to try";
      };
    };

    autoPush = {
      enable = lib.mkEnableOption "Automatically push system builds to cache";

      cacheName = lib.mkOption {
        type = lib.types.str;
        default = "homelab";
        description = "Name of the cache to push to";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.repositoryUrl != "";
        message = "Attic preseed.enable requires preseed.repositoryUrl to be set.";
      }) ++ (lib.optional cfg.preseed.enable {
        assertion = cfg.preseed.passwordFile != null;
        message = "Attic preseed.enable requires preseed.passwordFile to be set.";
      });
      # Create attic user and group
      users.users.attic = {
        description = "Attic binary cache server";
        group = "attic";
        home = cfg.dataDir;
        createHome = true;
        isSystemUser = true;
      };

      users.groups.attic = { };

      # Attic server configuration
      environment.etc."atticd/config.toml".text = ''
        # Attic Server Configuration

        listen = "${cfg.listenAddress}"

        [database]
        url = "sqlite://${cfg.dataDir}/server.db"

        [storage]
        type = "${cfg.storageType}"
        ${lib.optionalString (cfg.storageType == "local") ''
        path = "${cfg.dataDir}/storage"
        ''}
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k} = \"${v}\"") cfg.storageConfig)}

        [chunking]
        # NAR files are uploaded in chunks
        # This is the target chunk size for new uploads, in bytes
        nar-size-threshold = 65536    # 64 KiB

        # The minimum NAR size to trigger chunking
        # If 0, chunking is disabled entirely for new uploads.
        # If 1, all new uploads are chunked.
        min-size = 1048576            # 1 MiB

        # The preferred chunk size, in bytes
        avg-size = 65536              # 64 KiB

        # The maximum chunk size, in bytes
        max-size = 262144             # 256 KiB

        [compression]
        # Compression type: "none", "brotli", "gzip", "xz", "zstd"
        type = "zstd"
        level = 8
      '';

      # Create directories with proper permissions
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 attic attic -"
        "d ${cfg.dataDir}/storage 0755 attic attic -"
      ];

      # Attic server service
      systemd.services.atticd = {
        description = "Attic Binary Cache Server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ] ++ lib.optionals cfg.preseed.enable [ "preseed-attic.service" ];
        wants = lib.optionals cfg.preseed.enable [ "preseed-attic.service" ];

        serviceConfig = {
          Type = "simple";
          User = "attic";
          Group = "attic";
          Restart = "on-failure";
          RestartSec = 5;

          # Directory management
          StateDirectory = "atticd";
          StateDirectoryMode = "0755";

          # Security settings
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ cfg.dataDir ];

          # Ensure the user can access the database file
          UMask = "0022";

          # Use a wrapper script to read the JWT secret
          ExecStart = pkgs.writeShellScript "atticd-start" ''
            export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(cat ${cfg.jwtSecretFile})"
            exec ${pkgs.attic-server}/bin/atticd -f /etc/atticd/config.toml
          '';
        };

        # Run database migrations on first start or upgrades
        preStart = ''
          # Ensure directories exist with correct permissions
          mkdir -p ${cfg.dataDir}
          mkdir -p ${cfg.dataDir}/storage
          chown attic:attic ${cfg.dataDir}
          chown attic:attic ${cfg.dataDir}/storage
          chmod 755 ${cfg.dataDir}
          chmod 755 ${cfg.dataDir}/storage

          # Touch the database file to ensure it exists with correct ownership
          touch ${cfg.dataDir}/server.db
          chown attic:attic ${cfg.dataDir}/server.db
          chmod 644 ${cfg.dataDir}/server.db

          export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(cat ${cfg.jwtSecretFile})"
          ${pkgs.attic-server}/bin/atticd -f /etc/atticd/config.toml --mode db-migrations
        '';
      };

      # Register with Caddy using standardized pattern
      modules.services.caddy.virtualHosts.attic = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;

        # Use structured backend configuration from shared types
        backend = cfg.reverseProxy.backend;

        # Authentication configuration from shared types
        auth = cfg.reverseProxy.auth;

        # Security configuration from shared types with additional headers
        security = cfg.reverseProxy.security // {
          customHeaders = cfg.reverseProxy.security.customHeaders // {
            "X-Frame-Options" = "DENY";
            "X-Content-Type-Options" = "nosniff";
            "X-XSS-Protection" = "1; mode=block";
            "Referrer-Policy" = "strict-origin-when-cross-origin";
          };
        };

        # Additional Caddy configuration
        extraConfig = cfg.reverseProxy.extraConfig;
      };

      # Firewall configuration for direct access (if not using reverse proxy)
      networking.firewall = lib.mkIf (cfg.reverseProxy == null || !cfg.reverseProxy.enable) {
        allowedTCPPorts = [ (lib.toInt (lib.last (lib.splitString ":" cfg.listenAddress))) ];
      };

      # Auto-push service to push system builds to cache
      systemd.services.attic-auto-push = lib.mkIf cfg.autoPush.enable {
        description = "Auto-push system build to Attic cache";
        wantedBy = [ "multi-user.target" ];
        after = [ "atticd.service" ];
        path = with pkgs; [ attic-client ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = pkgs.writeShellScript "attic-auto-push" ''
            # Wait for attic service to be ready
            sleep 5

            # Push current system build to cache
            if ${pkgs.attic-client}/bin/attic push ${cfg.autoPush.cacheName} /run/current-system 2>/dev/null; then
              echo "Successfully pushed system build to cache"
            else
              echo "Failed to push to cache (this is normal on first deployment)"
            fi
          '';
        };
      };

      # Auto-push timer to periodically push builds
      systemd.timers.attic-auto-push = lib.mkIf cfg.autoPush.enable {
        description = "Auto-push system builds to Attic cache";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10min";
          OnUnitActiveSec = "1h";
        };
      };

      # Package requirements
      environment.systemPackages = with pkgs; [
        attic-client
        attic-server
      ];
    })

    # Preseed service for disaster recovery
    (lib.mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = "attic";
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = mainServiceUnit;
        replicationCfg = null; # Replication config handled at host level
        datasetProperties = {
          recordsize = "128K";
          compression = "zstd";
          "com.sun:auto-snapshot" = "true";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = hasCentralizedNotifications;
        owner = "attic";
        group = "attic";
      }
    ))
  ];
}
