{ lib
, pkgs
, config
, podmanLib
, ...
}:
let
  # Import pure storage helpers library
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };
  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Only cfg is needed at top level for mkIf condition
  cfg = config.modules.services.autobrr;
in
{
  options.modules.services.autobrr = {
    enable = lib.mkEnableOption "Autobrr";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/autobrr";
      description = "Path to Autobrr data directory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "919";
      description = "User account under which Autobrr runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group under which Autobrr runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/autobrr/autobrr:latest";
      description = ''
        Full container image name including tag or digest.

        Best practices:
        - Pin to specific version tags
        - Use digest pinning for immutability
        - Avoid 'latest' tag for production systems

        Use Renovate bot to automate version updates with digest pinning.
      '';
      example = "ghcr.io/autobrr/autobrr:v1.42.0@sha256:f3ad4f59e6e5e4a...";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for the container";
    };

    resources = lib.mkOption {
      type = lib.types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "128M"; # Based on 7d peak (26M) × 2.5 = 65M, with headroom
        memoryReservation = "64M";
        cpus = "0.5";
      };
      description = "Resource limits for the container";
    };

    podmanNetwork = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the Podman network to attach the container to.
        Enables DNS resolution between containers on the same network.
        This allows autobrr to resolve download clients by container name.
      '';
      example = "media-services";
    };

    healthcheck = lib.mkOption {
      type = lib.types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "30s";
        onFailure = "kill";
      };
      description = "Container healthcheck configuration. Uses Podman native health checks with automatic restart on failure.";
    };

    # Declarative settings for config.toml generation
    settings = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Host address for Autobrr to listen on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 7474;
        description = "Port for Autobrr to listen on (internal to container).";
      };
      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Optional base URL for reverse proxy setups (e.g., "/autobrr/").
          Not needed for subdomain configurations.
        '';
      };
      logLevel = lib.mkOption {
        type = lib.types.enum [ "ERROR" "WARN" "INFO" "DEBUG" "TRACE" ];
        default = "INFO";
        description = "Logging verbosity level.";
      };
      checkForUpdates = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable in-app update checks.
          Set to false as updates are managed declaratively via Nix and Renovate.
        '';
      };
      sessionSecretFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the session secret.
          This is CRITICAL for session security and must be a random string.
          Managed via sops-nix.
        '';
        example = "config.sops.secrets.\"autobrr/session-secret\".path";
      };
    };

    # OIDC authentication configuration
    oidc = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "OIDC authentication";
          issuer = lib.mkOption {
            type = lib.types.str;
            description = "OIDC issuer URL (e.g., https://auth.example.com)";
          };
          clientId = lib.mkOption {
            type = lib.types.str;
            description = "OIDC client ID";
          };
          clientSecretFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              Path to file containing OIDC client secret.
              Managed via sops-nix.
            '';
          };
          redirectUrl = lib.mkOption {
            type = lib.types.str;
            description = "OIDC redirect URL (callback URL)";
            example = "https://autobrr.example.com/api/auth/oidc/callback";
          };
          disableBuiltInLogin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Disable the built-in login form.
              Only works when OIDC is enabled.
            '';
          };
        };
      });
      default = null;
      description = "OIDC authentication configuration for SSO via Authelia";
    };

    # Standardized reverse proxy integration
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Autobrr web interface";
    };

    # Standardized metrics collection pattern
    metrics = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable Prometheus metrics collection";
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Host for the metrics server to listen on.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 9074;
            description = "Port for the metrics server to listen on.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            default = "/metrics";
            description = "Path for metrics endpoint";
          };
          labels = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Additional Prometheus labels";
          };
        };
      });
      default = {
        enable = true;
        host = "0.0.0.0";
        port = 9074;
        path = "/metrics";
        labels = {
          service_type = "automation";
          function = "irc_grabber";
        };
      };
      description = "Prometheus metrics collection configuration for Autobrr";
    };

    # Standardized logging integration
    logging = lib.mkOption {
      type = lib.types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        driver = "journald";
      };
      description = "Logging configuration for Autobrr";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "media-alerts" ];
        };
        customMessages = {
          failure = "Autobrr IRC announce bot failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Autobrr service events";
    };

    # Standardized backup configuration
    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Autobrr data.

        Autobrr stores configuration, filters, and IRC connection state in its database.

        Recommended recordsize: 16K (optimal for database files)
      '';
    };

    # Dataset configuration
    dataset = lib.mkOption {
      type = lib.types.nullOr sharedTypes.datasetSubmodule;
      default = null;
      description = "ZFS dataset configuration for Autobrr data directory";
    };

    preseed = {
      enable = lib.mkEnableOption "automatic data restore before service start";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        description = "Restic repository URL for restore operations";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to Restic password file";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional environment file for Restic (e.g., for B2 credentials)";
      };
      restoreMethods = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" "restic" ];
        description = ''
          Order and selection of restore methods to attempt. Methods are tried
          sequentially until one succeeds. Examples:
          - [ "syncoid" "local" "restic" ] - Default, try replication first
          - [ "local" "restic" ] - Skip replication, try local snapshots first
          - [ "restic" ] - Restic-only (for air-gapped systems)
          - [ "local" "restic" "syncoid" ] - Local-first for quick recovery
        '';
      };
    };
  };

  config =
    let
      # Move config-dependent variables here to avoid infinite recursion
      storageCfg = config.modules.storage;
      autobrrPort = 7474;
      mainServiceUnit = "${config.virtualisation.oci-containers.backend}-autobrr.service";
      datasetPath = "${storageCfg.datasets.parentDataset}/autobrr";
      configFile = "${cfg.dataDir}/config.toml";

      # Recursively find the replication config
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

      hasCentralizedNotifications = config.modules.notifications.alertmanager.enable or false;
    in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.settings.sessionSecretFile != null;
            message = "Autobrr requires settings.sessionSecretFile to be set for session security.";
          }
          {
            assertion = cfg.reverseProxy != null -> cfg.reverseProxy.enable;
            message = "Autobrr reverse proxy must be explicitly enabled when configured";
          }
          {
            assertion = cfg.backup != null -> cfg.backup.enable;
            message = "Autobrr backup must be explicitly enabled when configured";
          }
          {
            assertion = cfg.preseed.enable -> (cfg.preseed.repositoryUrl != "");
            message = "Autobrr preseed.enable requires preseed.repositoryUrl to be set.";
          }
          {
            assertion = cfg.preseed.enable -> (builtins.isPath cfg.preseed.passwordFile || builtins.isString cfg.preseed.passwordFile);
            message = "Autobrr preseed.enable requires preseed.passwordFile to be set.";
          }
        ];

        warnings =
          (lib.optional (cfg.reverseProxy == null) "Autobrr has no reverse proxy configured. Service will only be accessible locally.")
          ++ (lib.optional (cfg.backup == null) "Autobrr has no backup configured. IRC filters and configurations will not be protected.");

        # Create ZFS dataset for Autobrr data
        modules.storage.datasets.services.autobrr = {
          mountpoint = cfg.dataDir;
          recordsize = "16K"; # Optimal for configuration files
          compression = "zstd";
          properties = {
            "com.sun:auto-snapshot" = "true";
          };
          owner = cfg.user;
          group = cfg.group;
          mode = "0750";
        };

        # Create system user for Autobrr
        users.users.autobrr = {
          uid = lib.mkDefault (lib.toInt cfg.user);
          group = cfg.group;
          isSystemUser = true;
          description = "Autobrr service user";
        };

        # Create system group for Autobrr
        users.groups.autobrr = {
          gid = lib.mkDefault (lib.toInt cfg.user);
        };

        # Config generator service - creates config only if missing
        # This preserves UI changes (indexers, filters, IRC connections) while ensuring correct initial configuration
        systemd.services.autobrr-config-generator = {
          description = "Generate Autobrr configuration if missing";
          before = [ mainServiceUnit ];
          serviceConfig = {
            Type = "oneshot";
            User = cfg.user;
            Group = cfg.group;
            EnvironmentFile = config.sops.templates."autobrr-env".path;
            ExecStart = pkgs.writeShellScript "generate-autobrr-config" ''
                        set -eu
                        CONFIG_FILE="${configFile}"
                        CONFIG_DIR=$(dirname "$CONFIG_FILE")

                        # Only generate if config doesn't exist
                        if [ ! -f "$CONFIG_FILE" ]; then
                          echo "Config missing, generating from Nix settings..."
                          mkdir -p "$CONFIG_DIR"

                          # Secrets injected via environment variables from sops template
                          # AUTOBRR__SESSION_SECRET and AUTOBRR__OIDC_CLIENT_SECRET available

                          # Generate config using heredoc
                          cat > "$CONFIG_FILE" << EOF
              # Autobrr configuration - generated by Nix
              # Changes to indexers, filters, and IRC connections are preserved
              # Base configuration is declaratively managed

              # Network configuration
              host = "${cfg.settings.host}"
              port = ${toString cfg.settings.port}
              ${lib.optionalString (cfg.settings.baseUrl != "") ''baseUrl = "${cfg.settings.baseUrl}"''}

              # Logging
              logLevel = "${cfg.settings.logLevel}"

              # Update management (disabled - using Nix/Renovate)
              checkForUpdates = ${if cfg.settings.checkForUpdates then "true" else "false"}

              # Session security
              sessionSecret = "$AUTOBRR__SESSION_SECRET"

              # OIDC authentication
              ${lib.optionalString (cfg.oidc != null && cfg.oidc.enable) ''
              oidcEnabled = true
              oidcIssuer = "${cfg.oidc.issuer}"
              oidcClientId = "${cfg.oidc.clientId}"
              oidcClientSecret = "$AUTOBRR__OIDC_CLIENT_SECRET"
              oidcRedirectUrl = "${cfg.oidc.redirectUrl}"
              oidcDisableBuiltInLogin = ${if cfg.oidc.disableBuiltInLogin then "true" else "false"}
              ''}
              ${lib.optionalString (cfg.oidc == null || !cfg.oidc.enable) ''
              oidcEnabled = false
              ''}

              # Metrics configuration
              ${lib.optionalString (cfg.metrics != null && cfg.metrics.enable) ''
              metricsEnabled = true
              metricsHost = "${cfg.metrics.host}"
              metricsPort = "${toString cfg.metrics.port}"
              ''}
              ${lib.optionalString (cfg.metrics == null || !cfg.metrics.enable) ''
              metricsEnabled = false
              ''}
              EOF

                          chmod 640 "$CONFIG_FILE"
                          echo "Configuration generated at $CONFIG_FILE"
                        else
                          echo "Config exists at $CONFIG_FILE, preserving existing file"
                        fi
            '';
          };
        };

        # Autobrr container configuration
        # Note: This image does not use PUID/PGID - must use --user flag
        virtualisation.oci-containers.containers.autobrr = podmanLib.mkContainer "autobrr" {
          image = cfg.image;
          environment = {
            TZ = cfg.timezone;
          };
          volumes = [
            "${cfg.dataDir}:/config:rw"
          ];
          ports = [ "${toString autobrrPort}:7474" ]
            ++ (lib.optional (cfg.metrics != null && cfg.metrics.enable) "${toString cfg.metrics.port}:${toString cfg.metrics.port}");
          log-driver = "journald";
          extraOptions =
            [
              # Autobrr container doesn't support PUID/PGID - use --user flag
              "--user=${cfg.user}:${toString config.users.groups.${cfg.group}.gid}"
            ]
            ++ (lib.optionals (cfg.podmanNetwork != null) [
              # Connect to Podman network for inter-container DNS resolution
              "--network=${cfg.podmanNetwork}"
            ])
            ++ (lib.optionals (cfg.resources != null) [
              "--memory=${cfg.resources.memory}"
              "--memory-reservation=${cfg.resources.memoryReservation}"
              "--cpus=${cfg.resources.cpus}"
            ])
            ++ (lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
              "--health-cmd=curl --fail http://localhost:7474/api/healthz/liveness || exit 1"
              "--health-interval=${cfg.healthcheck.interval}"
              "--health-timeout=${cfg.healthcheck.timeout}"
              "--health-retries=${toString cfg.healthcheck.retries}"
              "--health-start-period=${cfg.healthcheck.startPeriod}"
              "--health-on-failure=${cfg.healthcheck.onFailure}"
            ]);
        };

        # Systemd service dependencies and security
        systemd.services."${mainServiceUnit}" = lib.mkMerge [
          (lib.mkIf (cfg.podmanNetwork != null) {
            requires = [ "podman-network-${cfg.podmanNetwork}.service" ];
            after = [ "podman-network-${cfg.podmanNetwork}.service" ];
          })
          {
            requires = [ "network-online.target" ];
            after = [ "network-online.target" "autobrr-config-generator.service" ];
            wants = [ "autobrr-config-generator.service" ];
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "10s";
            };
          }
        ];

        # Integrate with centralized Caddy reverse proxy if configured
        modules.services.caddy.virtualHosts.autobrr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
          enable = true;
          hostName = cfg.reverseProxy.hostName;
          backend = {
            scheme = "http";
            host = "127.0.0.1";
            port = autobrrPort;
          };
          auth = cfg.reverseProxy.auth;
          caddySecurity = cfg.reverseProxy.caddySecurity;
          security = cfg.reverseProxy.security;
          extraConfig = cfg.reverseProxy.extraConfig;
        };

        # Backup integration using standardized restic pattern
        modules.backup.restic.jobs = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
          autobrr = {
            enable = true;
            paths = [ cfg.dataDir ];
            repository = cfg.backup.repository;
            frequency = cfg.backup.frequency;
            tags = cfg.backup.tags;
            excludePatterns = cfg.backup.excludePatterns;
            useSnapshots = cfg.backup.useSnapshots;
            zfsDataset = cfg.backup.zfsDataset;
          };
        };
      })

      # Preseed service
      (lib.mkIf (cfg.enable && cfg.preseed.enable) (
        storageHelpers.mkPreseedService {
          serviceName = "autobrr";
          dataset = datasetPath;
          mountpoint = cfg.dataDir;
          mainServiceUnit = mainServiceUnit;
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
          owner = cfg.user;
          group = cfg.group;
        }
      ))
    ];
}
