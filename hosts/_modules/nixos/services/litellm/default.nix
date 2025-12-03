# LiteLLM - Unified AI Gateway (Container-based)
#
# Containerized deployment using the official ghcr.io/berriai/litellm-database image.
# This version supports full database features unlike the native NixOS module.
#
# Features:
# - PostgreSQL integration for spend tracking, virtual keys, user management
# - SSO via PocketID (OIDC/JWT authentication, free for up to 5 users)
# - Generated config.yaml with environment variable references for secrets
# - ZFS storage management
# - Standard homelab integrations (reverse proxy, backup, preseed, notifications)
#
# The container expects config.yaml for model configuration while secrets
# are loaded from environment variables using the `os.environ/...` syntax.
#
# Reference: https://docs.litellm.ai/docs/proxy/deploy
# SSO Docs: https://docs.litellm.ai/docs/proxy/admin_ui_sso
#
{ config, lib, pkgs, podmanLib, ... }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    optional
    optionals
    optionalAttrs
    concatStringsSep
    ;

  cfg = config.modules.services.litellm;
  serviceName = "litellm";
  backend = config.virtualisation.oci-containers.backend;
  mainServiceUnit = "${backend}-${serviceName}.service";

  # LiteLLM container listens on port 4000 internally (hardcoded in image CMD)
  internalContainerPort = 4000;

  # Import shared types for standardized submodules
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Import storage helpers for preseed functionality
  storageHelpers = import ../../storage/helpers-lib.nix { inherit pkgs lib; };

  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };
  notificationsCfg = config.modules.notifications or { };
  hasCentralizedNotifications = notificationsCfg.enable or false;

  # Default dataset path based on storage module configuration
  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  datasetPath = cfg.datasetPath or defaultDatasetPath;

  # Environment directory for assembled secrets
  envDir = "/run/${serviceName}";
  envFile = "${envDir}/env";

  # Configuration directory
  configDir = "/var/lib/${serviceName}/config";
  configFile = "${configDir}/config.yaml";

  # Build model_list configuration for LiteLLM config.yaml
  # Uses os.environ/... syntax for API keys
  buildModelList = models: map (m: {
    model_name = m.name;
    litellm_params = {
      model = m.model;
    } // optionalAttrs (m.apiBase != null) {
      api_base = m.apiBase;
    } // optionalAttrs (m.apiKey != null) {
      # Reference environment variable by name using LiteLLM's syntax
      api_key = "os.environ/${m.apiKey}";
    } // optionalAttrs (m.apiVersion != null) {
      api_version = m.apiVersion;
    } // (m.extraParams or { });
  }) models;

  # Build the LiteLLM config.yaml content
  # This is a Nix attrset that will be converted to YAML
  litellmConfig = {
    model_list = buildModelList cfg.models;

    router_settings = cfg.routerSettings;

    litellm_settings = cfg.litellmSettings;

    general_settings = {
      # Master key from environment
      master_key = "os.environ/LITELLM_MASTER_KEY";

      # Database URL from environment (PostgreSQL)
      database_url = "os.environ/DATABASE_URL";
    } // optionalAttrs cfg.sso.enable {
      # SSO configuration (free for up to 5 users)
      # See: https://docs.litellm.ai/docs/proxy/admin_ui_sso
      ui_access_mode = "all";
      enable_jwt_auth = true;
    } // cfg.generalSettings;
  } // optionalAttrs cfg.sso.enable {
    # JWT authentication configuration for SSO
    environment_variables = {
      JWT_PUBLIC_KEY_URL = cfg.sso.jwksUrl;
    } // optionalAttrs (cfg.sso.audience != null) {
      JWT_AUDIENCE = cfg.sso.audience;
    };

    litellm_jwtauth = {
      # User identification from JWT
      user_id_jwt_field = cfg.sso.userIdField;
      user_email_jwt_field = cfg.sso.userEmailField;

      # Role/group management
      team_id_jwt_field = cfg.sso.teamIdField;
    } // optionalAttrs (cfg.sso.adminScope != null) {
      admin_jwt_scope = cfg.sso.adminScope;
    } // optionalAttrs (cfg.sso.allowedEmailDomains != [ ]) {
      user_allowed_email_domain = concatStringsSep "," cfg.sso.allowedEmailDomains;
      user_id_upsert = true;
    };
  };

  # Generate config.yaml file from Nix attrset
  configYaml = pkgs.writeText "litellm-config.yaml" (
    lib.generators.toYAML { } litellmConfig
  );

  # Recursively locate replication config from parent datasets (if any)
  findReplication = dsPath:
    if dsPath == "" || dsPath == null then null
    else
      let
        sanoidDatasets = config.modules.backup.sanoid.datasets or { };
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

  foundReplication = if datasetPath != null then findReplication datasetPath else null;
  replicationConfig =
    if foundReplication == null || !(config.modules.backup.sanoid.enable or false) then
      null
    else
      let
        datasetSuffix =
          if foundReplication.sourcePath == datasetPath then ""
          else lib.removePrefix "${foundReplication.sourcePath}/" datasetPath;
      in
      {
        targetHost = foundReplication.replication.targetHost;
        targetDataset =
          if datasetSuffix == "" then foundReplication.replication.targetDataset
          else "${foundReplication.replication.targetDataset}/${datasetSuffix}";
        sshUser = foundReplication.replication.targetUser or config.modules.backup.sanoid.replicationUser;
        sshKeyPath = config.modules.backup.sanoid.sshKeyPath or "/var/lib/zfs-replication/.ssh/id_ed25519";
        sendOptions = foundReplication.replication.sendOptions or "w";
        recvOptions = foundReplication.replication.recvOptions or "u";
      };

  # Build container environment variables
  # Note: PORT is not set because the image CMD hardcodes --port 4000
  containerEnv = {
    TZ = config.time.timeZone or "UTC";
    LITELLM_CONFIG_PATH = "/app/config.yaml";
  };

  # Build healthcheck options (use internal container port)
  # Note: /health requires API key auth, but /health/liveliness is unauthenticated
  healthcheckOptions = optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
    "--health-cmd=curl --fail --silent --max-time 5 http://127.0.0.1:${toString internalContainerPort}/health/liveliness || exit 1"
    "--health-interval=${cfg.healthcheck.interval}"
    "--health-timeout=${cfg.healthcheck.timeout}"
    "--health-retries=${toString cfg.healthcheck.retries}"
    "--health-start-period=${cfg.healthcheck.startPeriod}"
  ];

  # Default backend for reverse proxy
  defaultBackend = {
    scheme = "http";
    host = "127.0.0.1";
    port = cfg.port;
  };

  reverseProxyBackend =
    if cfg.reverseProxy != null then lib.attrByPath [ "backend" ] { } cfg.reverseProxy else { };

  effectiveBackend = lib.recursiveUpdate defaultBackend reverseProxyBackend;

in
{
  options.modules.services.litellm = {
    enable = mkEnableOption "LiteLLM unified AI gateway (containerized with database)";

    # ==========================================================================
    # Container Configuration
    # ==========================================================================

    image = mkOption {
      type = types.str;
      default = "ghcr.io/berriai/litellm-database:main-stable@sha256:2d3ec2c7e6726e0e0b837c7635f43ab69ed7e1b74e72b00cb792b4186662bda8";
      description = ''
        Container image for LiteLLM. Use the -database variant for PostgreSQL support.
        Pinned to specific digest for reproducibility.
      '';
      example = "ghcr.io/berriai/litellm-database:main-v1.55.0@sha256:...";
    };

    user = mkOption {
      type = types.str;
      default = serviceName;
      description = "System user that owns LiteLLM state and runs auxiliary jobs.";
    };

    group = mkOption {
      type = types.str;
      default = serviceName;
      description = "Primary group for LiteLLM data.";
    };

    # ==========================================================================
    # Network Configuration
    # ==========================================================================

    port = mkOption {
      type = types.port;
      default = 4000;
      description = ''
        Host port for LiteLLM API server.
        Note: The container internally listens on port 4000 (hardcoded in image).
        This option controls which host port is mapped to the container.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address to bind the LiteLLM ports to.";
    };

    # ==========================================================================
    # Storage Configuration
    # ==========================================================================

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/${serviceName}";
      description = "Directory for LiteLLM persistent data.";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset backing LiteLLM data (used for auto-creation and replication).";
      example = "tank/services/litellm";
    };

    # ==========================================================================
    # Model Configuration
    # ==========================================================================

    models = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "User-friendly model name (what clients request).";
            example = "gpt-4o";
          };

          model = mkOption {
            type = types.str;
            description = "Provider-specific model identifier.";
            example = "azure/gpt-4o";
          };

          apiBase = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "API base URL (for Azure deployments).";
            example = "https://myresource.openai.azure.com";
          };

          apiKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Environment variable name containing API key (without os.environ/ prefix).";
            example = "AZURE_API_KEY";
          };

          apiVersion = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "API version (for Azure deployments).";
            example = "2024-08-01-preview";
          };

          extraParams = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = "Additional litellm_params for this model.";
            example = { rpm = 100; tpm = 10000; };
          };
        };
      });
      default = [ ];
      description = "List of AI models to expose through LiteLLM.";
    };

    routerSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        routing_strategy = "simple-shuffle";
        num_retries = 2;
        timeout = 300;
      };
      description = "LiteLLM router settings (fallbacks, load balancing).";
    };

    litellmSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        drop_params = true;
        set_verbose = false;
      };
      description = "LiteLLM general settings.";
    };

    generalSettings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Additional general_settings for config.yaml.";
    };

    # ==========================================================================
    # Database Configuration (PostgreSQL)
    # ==========================================================================

    database = {
      host = mkOption {
        type = types.str;
        default = "host.containers.internal";
        description = "Database host (use host.containers.internal for local PostgreSQL).";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "Database port.";
      };

      name = mkOption {
        type = types.str;
        default = serviceName;
        description = "Database name.";
      };

      user = mkOption {
        type = types.str;
        default = serviceName;
        description = "Database role/owner.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to the database password file (SOPS).";
      };

      manageDatabase = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically provision the PostgreSQL role/database.";
      };

      localInstance = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to add dependencies on the local PostgreSQL service.";
      };
    };

    # ==========================================================================
    # SSO Configuration (OIDC/JWT - free for up to 5 users)
    # ==========================================================================

    sso = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "SSO via JWT/OIDC authentication";

          jwksUrl = mkOption {
            type = types.str;
            default = "";
            example = "https://id.holthome.net/.well-known/openid-configuration/jwks";
            description = ''
              JWKS URL for JWT validation. For PocketID, this is typically:
              https://id.example.com/.well-known/openid-configuration/jwks
            '';
          };

          audience = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "litellm";
            description = "Expected JWT audience claim for validation.";
          };

          userIdField = mkOption {
            type = types.str;
            default = "sub";
            description = "JWT claim containing the user ID.";
          };

          userEmailField = mkOption {
            type = types.str;
            default = "email";
            description = "JWT claim containing the user email.";
          };

          teamIdField = mkOption {
            type = types.str;
            default = "groups";
            description = "JWT claim containing team/group information.";
          };

          adminScope = mkOption {
            type = types.nullOr types.str;
            default = "litellm-admin";
            example = "litellm-proxy-admin";
            description = "JWT scope/claim value that grants admin access.";
          };

          allowedEmailDomains = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "holthome.net" ];
            description = ''
              Email domains allowed to access. When set, enables user_id_upsert
              to auto-create users on first login.
            '';
          };
        };
      };
      default = { };
      description = ''
        SSO configuration using JWT/OIDC. Free for up to 5 users.
        See: https://docs.litellm.ai/docs/proxy/admin_ui_sso
      '';
    };

    # ==========================================================================
    # Secrets Configuration
    # ==========================================================================

    masterKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to file containing LiteLLM master key for admin access.
        If not provided, a random key will be auto-generated.
      '';
    };

    environmentFile = mkOption {
      type = types.path;
      description = "Path to file containing provider API keys (AZURE_API_KEY, OPENAI_API_KEY, etc.).";
      example = "/run/secrets/litellm/provider-keys";
    };

    # ==========================================================================
    # Container Configuration
    # ==========================================================================

    podmanNetwork = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Attach LiteLLM to a named Podman network.";
    };

    resources = mkOption {
      type = types.nullOr sharedTypes.containerResourcesSubmodule;
      default = null;
      description = "Podman resource limits for the LiteLLM container.";
    };

    healthcheck = mkOption {
      type = types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "60s";
      };
      description = "Container healthcheck configuration.";
    };

    # ==========================================================================
    # Standard Integration Submodules
    # ==========================================================================

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration.";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = mainServiceUnit;
        labels = {
          service = serviceName;
          service_type = "ai-gateway";
        };
      };
      description = "Log shipping configuration.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "LiteLLM AI gateway failed on ${config.networking.hostName}";
      };
      description = "Notification configuration.";
    };

    preseed = {
      enable = mkEnableOption "automatic restore before service start";

      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for preseed restore.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Restic password file.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Environment file for cloud credentials.";
      };

      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Preferred restore method order.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # ========================================================================
      # Assertions
      # ========================================================================
      assertions = [
        {
          assertion = cfg.database.passwordFile != null;
          message = "modules.services.litellm.database.passwordFile must be set.";
        }
        {
          assertion = cfg.environmentFile != null;
          message = "modules.services.litellm.environmentFile must be set (for provider API keys).";
        }
        {
          assertion = !cfg.sso.enable || cfg.sso.jwksUrl != "";
          message = "modules.services.litellm.sso.jwksUrl must be set when SSO is enabled.";
        }
      ];

      # ========================================================================
      # User and Group
      # ========================================================================

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        description = "LiteLLM service account";
      };

      users.groups.${cfg.group} = { };

      # ========================================================================
      # Directory Setup
      # ========================================================================

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
        "d ${configDir} 0750 ${cfg.user} ${cfg.group} -"
        "d ${envDir} 0700 root root -"
      ];

      # ========================================================================
      # ZFS Dataset Configuration
      # ========================================================================

      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "128K";
        compression = "zstd";
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # ========================================================================
      # PostgreSQL Database Provisioning
      # ========================================================================

      modules.services.postgresql.databases.${cfg.database.name} = mkIf cfg.database.manageDatabase {
        owner = cfg.database.user;
        ownerPasswordFile = cfg.database.passwordFile;
        permissionsPolicy = "owner-readwrite+readonly-select";
      };

      # ========================================================================
      # Container Configuration
      # ========================================================================

      virtualisation.oci-containers.containers.${serviceName} = podmanLib.mkContainer serviceName {
        image = cfg.image;

        environmentFiles = [ envFile ];

        environment = containerEnv;

        volumes = [
          # Mount generated config.yaml
          "${configFile}:/app/config.yaml:ro"
          # Mount data directory for any runtime state
          "${cfg.dataDir}:/app/data:rw"
        ];

        # Map host port to internal container port (4000 is hardcoded in image CMD)
        ports = [
          "${cfg.listenAddress}:${toString cfg.port}:${toString internalContainerPort}/tcp"
        ];

        resources = cfg.resources;

        extraOptions = optionals (cfg.podmanNetwork != null) [
          "--network=${cfg.podmanNetwork}"
        ] ++ healthcheckOptions;
      };

      # ========================================================================
      # Systemd Service Configuration
      # ========================================================================

      systemd.services."${mainServiceUnit}" = lib.mkMerge [
        {
          after = [ "network-online.target" "${serviceName}-env.service" ]
            ++ optional cfg.database.localInstance "postgresql.service"
            ++ optionals cfg.preseed.enable [ "${serviceName}-preseed.service" ];
          wants = [ "network-online.target" ]
            ++ optionals cfg.preseed.enable [ "${serviceName}-preseed.service" ];
          requires = [ "${serviceName}-env.service" ]
            ++ optionals (cfg.database.manageDatabase && cfg.database.localInstance) [ "postgresql-provision-databases.service" ];

          serviceConfig = {
            Restart = lib.mkForce "on-failure";
            RestartSec = "10s";
          };
        }
        (lib.mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
          unitConfig.OnFailure = [ "notify@${serviceName}-failure:%n.service" ];
        })
      ];

      # ========================================================================
      # Environment File Generator (oneshot service)
      # ========================================================================
      # Generates the environment file with secrets before container starts.
      # Uses PartOf to ensure this service restarts when container restarts.

      systemd.services."${serviceName}-env" = {
        description = "LiteLLM Environment File Generator";
        wantedBy = [ "multi-user.target" ];
        before = [ "${mainServiceUnit}" ];
        requiredBy = [ "${mainServiceUnit}" ];
        # PartOf ensures this service is stopped when container stops,
        # and the before+requiredBy ensures it starts before container
        partOf = [ "${mainServiceUnit}" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = serviceName;
          RuntimeDirectoryMode = "0700";
          StateDirectory = serviceName;
          StateDirectoryMode = "0700";

          LoadCredential = [
            "provider-keys:${cfg.environmentFile}"
            "db_password:${cfg.database.passwordFile}"
          ] ++ optional (cfg.masterKeyFile != null) "master-key:${cfg.masterKeyFile}";
        };

        script = ''
          set -euo pipefail
          tmp="${envFile}.tmp"
          trap 'rm -f "$tmp"' EXIT

          {
            # Load provider keys
            cat "$CREDENTIALS_DIRECTORY/provider-keys"

            # Database connection URL
            DB_PASS=$(cat "$CREDENTIALS_DIRECTORY/db_password")
            printf "DATABASE_URL=postgresql://${cfg.database.user}:%s@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}\n" "$DB_PASS"

            # Master key handling
            if [[ -f "$CREDENTIALS_DIRECTORY/master-key" ]]; then
              printf "LITELLM_MASTER_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/master-key")"
            else
              # Auto-generate master key if not provided
              MASTER_KEY_FILE="/var/lib/${serviceName}/master-key"
              if [[ ! -f "$MASTER_KEY_FILE" ]]; then
                head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32 > "$MASTER_KEY_FILE"
                chmod 600 "$MASTER_KEY_FILE"
              fi
              printf "LITELLM_MASTER_KEY=%s\n" "$(cat "$MASTER_KEY_FILE")"
            fi
          } > "$tmp"

          install -m 600 "$tmp" "${envFile}"
          echo "Environment file created at ${envFile}"

          # Also install the config.yaml file
          install -D -m 644 "${configYaml}" "${configFile}"
          echo "Config file installed at ${configFile}"
        '';
      };

      # ========================================================================
      # Notification Templates
      # ========================================================================

      modules.notifications.templates = mkIf (hasCentralizedNotifications && cfg.notifications != null && cfg.notifications.enable) {
        "${serviceName}-failure" = {
          enable = true;
          priority = "high";
          title = "❌ LiteLLM service failed";
          body = ''
            <b>Host:</b> ${config.networking.hostName}
            <b>Service:</b> ${mainServiceUnit}

            Check logs: <code>journalctl -u ${mainServiceUnit} -n 200</code>
          '';
        };
      };

      # ========================================================================
      # Backup Integration
      # ========================================================================

      modules.backup.restic.jobs = mkIf (cfg.backup != null && cfg.backup.enable) {
        ${serviceName} = {
          enable = true;
          repository = cfg.backup.repository;
          frequency = cfg.backup.frequency;
          retention = cfg.backup.retention;
          paths = if cfg.backup.paths != [ ] then cfg.backup.paths else [ cfg.dataDir ];
          excludePatterns = cfg.backup.excludePatterns;
          useSnapshots = cfg.backup.useSnapshots or true;
          zfsDataset = cfg.backup.zfsDataset or datasetPath;
          tags = cfg.backup.tags;
        };
      };

      # ========================================================================
      # Reverse Proxy (Caddy) Integration
      # ========================================================================

      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = effectiveBackend;
        auth = cfg.reverseProxy.auth;
        authelia = cfg.reverseProxy.authelia;
        security = cfg.reverseProxy.security;
        extraConfig = cfg.reverseProxy.extraConfig;
      };
    })

    # ==========================================================================
    # Preseed Service (Disaster Recovery)
    # ==========================================================================
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        inherit serviceName;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        inherit mainServiceUnit;
        replicationCfg = replicationConfig;
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
        inherit hasCentralizedNotifications;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
