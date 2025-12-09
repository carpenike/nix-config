# modules/nixos/services/open-webui/default.nix
#
# Native NixOS wrapper for Open WebUI with multi-provider LLM support.
#
# Features:
# - Native OIDC via PocketID (or any OpenID Connect provider)
# - Multiple LLM backends: Azure AI Foundry, OpenAI, Anthropic, LM Studio
# - ZFS storage integration with proper recordsize for SQLite
# - Standard integrations: backup, monitoring, reverse proxy
#
# Complexity: Moderate (native wrapper with OIDC + multi-provider)
#
# Reference: Mealie module for OIDC pattern, Gatus for native wrapper pattern

{ config, lib, mylib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mkMerge optional optionalAttrs;

  cfg = config.modules.services.open-webui;
  serviceName = "open-webui";
  upstreamServiceName = "open-webui";

  # Import shared type definitions
  sharedTypes = mylib.types;

  # Environment file location (separate from main service's RuntimeDirectory
  # to avoid cleanup conflicts when the main service restarts)
  envDir = "/run/${serviceName}-secrets";
  envFile = "${envDir}/env";

  boolStr = b: if b then "true" else "false";

  # Build OIDC environment variables when enabled
  oidcEnv = optionalAttrs cfg.oidc.enable ({
    ENABLE_OAUTH_SIGNUP = boolStr cfg.oidc.signupEnabled;
    OAUTH_MERGE_ACCOUNTS_BY_EMAIL = boolStr cfg.oidc.mergeAccountsByEmail;
    OAUTH_PROVIDER_NAME = cfg.oidc.providerName;
    OPENID_PROVIDER_URL = cfg.oidc.configurationUrl;
    OAUTH_CLIENT_ID = cfg.oidc.clientId;
    # OAUTH_CLIENT_SECRET loaded via LoadCredential
    OAUTH_SCOPES = lib.concatStringsSep " " cfg.oidc.scopes;
    ENABLE_LOGIN_FORM = boolStr cfg.oidc.enableLoginForm;
  } // optionalAttrs cfg.oidc.roleManagement.enable {
    # Role management from OIDC claims
    ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
    OAUTH_ROLES_CLAIM = cfg.oidc.roleManagement.rolesClaim;
    OAUTH_ADMIN_ROLES = lib.concatStringsSep "," cfg.oidc.roleManagement.adminRoles;
  } // optionalAttrs (cfg.oidc.roleManagement.enable && cfg.oidc.roleManagement.allowedRoles != [ ]) {
    OAUTH_ALLOWED_ROLES = lib.concatStringsSep "," cfg.oidc.roleManagement.allowedRoles;
  });

  # Build Azure OpenAI environment when enabled
  #
  # IMPORTANT: Azure OpenAI configuration (Provider Type, API Version, etc.)
  # must be done in the Open WebUI Admin Settings → Connections UI.
  # Environment variables like AZURE_OPENAI_API_VERSION are NOT used for
  # the main chat/completions API - that config is stored in the database.
  #
  # What we CAN configure via environment:
  # - OPENAI_API_BASE_URL: Default base URL for connections (used as fallback)
  # - OPENAI_API_KEY: Default API key (loaded via credential)
  #
  # What must be configured in UI:
  # - Provider Type: "Azure OpenAI"
  # - API Version: e.g., "2024-12-01-preview"
  # - Model deployments and their names
  azureEnv = optionalAttrs cfg.azure.enable {
    ENABLE_OPENAI_API = "true";
    # Provide base URL as a default - actual Azure config is done in the UI
    OPENAI_API_BASE_URL = cfg.azure.endpoint;
    # OPENAI_API_KEY loaded via LoadCredential (Azure key)
  };

  # Build standard OpenAI environment when enabled (and Azure not overriding)
  openaiEnv = optionalAttrs (cfg.openai.enable && !cfg.azure.enable) {
    ENABLE_OPENAI_API = "true";
    # Uses default OpenAI base URL
    # OPENAI_API_KEY loaded via LoadCredential
  };

  # Build Anthropic environment when enabled
  # Note: ANTHROPIC_API_KEY is loaded via LoadCredential in preStart
  # Open WebUI auto-detects Claude models when the key is present

  # Build LM Studio / Ollama environment when enabled
  ollamaEnv = optionalAttrs cfg.ollama.enable {
    ENABLE_OLLAMA_API = "true";
    OLLAMA_BASE_URL = cfg.ollama.baseUrl;
  };

  # Build SearXNG web search environment when enabled
  searxngEnv = optionalAttrs cfg.searxng.enable {
    ENABLE_RAG_WEB_SEARCH = "True";
    RAG_WEB_SEARCH_ENGINE = "searxng";
    SEARXNG_QUERY_URL = cfg.searxng.queryUrl;
    RAG_WEB_SEARCH_RESULT_COUNT = toString cfg.searxng.resultCount;
    RAG_WEB_SEARCH_CONCURRENT_REQUESTS = toString cfg.searxng.concurrentRequests;
  };

  # Combine all environment variables
  # NOTE: The upstream NixOS open-webui module expects DATA_DIR to point to
  # a "/data" subdirectory under stateDir. It has a preStart migration that
  # moves legacy files (webui.db, cache, uploads, vector_db) into this subdirectory.
  # We MUST match this expectation to avoid the migration script moving files
  # out from under our DATA_DIR setting.
  combinedEnv = {
    # Base configuration - must match upstream's DATA_DIR convention
    DATA_DIR = "${cfg.dataDir}/data";
    WEBUI_URL = cfg.baseUrl;

    # User registration
    ENABLE_SIGNUP = boolStr cfg.enableSignup;

    # Default admin user (for initial setup)
    WEBUI_AUTH = "True";
  } // oidcEnv // azureEnv // openaiEnv // ollamaEnv // searxngEnv // cfg.extraEnvironment;

  # Build LoadCredential list for secrets
  credentials = lib.flatten [
    (optional (cfg.oidc.enable && cfg.oidc.clientSecretFile != null)
      "oidc_client_secret:${cfg.oidc.clientSecretFile}")
    (optional (cfg.azure.enable && cfg.azure.apiKeyFile != null)
      "azure_openai_key:${cfg.azure.apiKeyFile}")
    (optional (cfg.openai.enable && cfg.openai.apiKeyFile != null && !cfg.azure.enable)
      "openai_key:${cfg.openai.apiKeyFile}")
    (optional (cfg.anthropic.enable && cfg.anthropic.apiKeyFile != null)
      "anthropic_key:${cfg.anthropic.apiKeyFile}")
  ];

  # Check if we have any secrets that need to be in the environment file
  hasSecrets = (cfg.oidc.enable && cfg.oidc.clientSecretFile != null)
    || (cfg.azure.enable && cfg.azure.apiKeyFile != null)
    || (cfg.openai.enable && cfg.openai.apiKeyFile != null && !cfg.azure.enable)
    || (cfg.anthropic.enable && cfg.anthropic.apiKeyFile != null);

in
{
  options.modules.services.open-webui = {
    enable = mkEnableOption "Open WebUI - self-hosted AI chat interface";

    package = mkOption {
      type = types.package;
      default = pkgs.open-webui;
      defaultText = lib.literalExpression "pkgs.open-webui";
      description = "The Open WebUI package to use. Use pkgs.unstable.open-webui for latest version.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address to bind to.";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port for the Open WebUI service.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/open-webui";
      description = "Directory for Open WebUI persistent data (SQLite database, uploads).";
    };

    user = mkOption {
      type = types.str;
      default = "open-webui";
      description = "User account under which Open WebUI runs.";
    };

    group = mkOption {
      type = types.str;
      default = "open-webui";
      description = "Group under which Open WebUI runs.";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "ZFS dataset path for Open WebUI data. When set, configures ZFS storage.";
    };

    baseUrl = mkOption {
      type = types.str;
      default = "http://localhost:8080";
      example = "https://chat.holthome.net";
      description = "External URL for Open WebUI (used for OAuth callbacks, links, etc.).";
    };

    enableSignup = mkOption {
      type = types.bool;
      default = false;
      description = "Allow public user registration (should be false when using OIDC).";
    };

    # -------------------------------------------------------------------
    # OIDC Configuration
    # -------------------------------------------------------------------
    oidc = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "OpenID Connect authentication";

          configurationUrl = mkOption {
            type = types.str;
            default = "";
            example = "https://id.holthome.net/.well-known/openid-configuration";
            description = "OIDC provider discovery URL.";
          };

          clientId = mkOption {
            type = types.str;
            default = "open-webui";
            description = "OIDC client ID.";
          };

          clientSecretFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to file containing OIDC client secret.";
          };

          providerName = mkOption {
            type = types.str;
            default = "SSO";
            description = "Display name for the SSO login button.";
          };

          scopes = mkOption {
            type = types.listOf types.str;
            default = [ "openid" "profile" "email" ];
            description = "OIDC scopes to request.";
          };

          signupEnabled = mkOption {
            type = types.bool;
            default = true;
            description = "Auto-provision users on first OIDC login.";
          };

          mergeAccountsByEmail = mkOption {
            type = types.bool;
            default = true;
            description = "Merge OIDC accounts with existing accounts by email.";
          };

          enableLoginForm = mkOption {
            type = types.bool;
            default = false;
            description = "Show username/password form alongside SSO button.";
          };

          # Role management via OIDC claims
          roleManagement = {
            enable = mkEnableOption "sync roles from OIDC claims";

            rolesClaim = mkOption {
              type = types.str;
              default = "groups";
              description = "OIDC claim containing user roles/groups.";
            };

            adminRoles = mkOption {
              type = types.listOf types.str;
              default = [ "admins" ];
              example = [ "admins" "administrators" ];
              description = "Claim values that grant admin role in Open WebUI.";
            };

            allowedRoles = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "users" "admins" ];
              description = "Claim values allowed to access Open WebUI. Empty means all authenticated users.";
            };
          };
        };
      };
      default = { };
      description = "OpenID Connect configuration for PocketID or other providers.";
    };

    # -------------------------------------------------------------------
    # LLM Provider: Azure AI Foundry / Azure OpenAI
    #
    # IMPORTANT: Azure OpenAI has limited environment variable support.
    # The full Azure configuration (Provider Type, API Version, model
    # deployments) must be done in the Open WebUI Admin UI:
    #   Admin Settings → Connections → Add Connection
    #   - Provider Type: "Azure OpenAI"
    #   - API Version: e.g., "2024-12-01-preview"
    #
    # This NixOS option only provides the endpoint URL and API key as
    # defaults. The UI configuration is stored in Open WebUI's database.
    # -------------------------------------------------------------------
    azure = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Azure AI Foundry / Azure OpenAI integration";

          endpoint = mkOption {
            type = types.str;
            default = "";
            example = "https://my-resource.openai.azure.com";
            description = ''
              Azure OpenAI endpoint URL (base URL only, without path).
              This is set as OPENAI_API_BASE_URL and used as the default.

              IMPORTANT: After deployment, you must configure the connection
              in Open WebUI Admin Settings → Connections:
              - Set Provider Type to "Azure OpenAI"
              - Set API Version (e.g., 2024-12-01-preview for o-series models)

              Example: https://my-resource.openai.azure.com
            '';
          };

          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to file containing Azure OpenAI API key.";
          };
        };
      };
      default = { };
      description = ''
        Azure AI Foundry / Azure OpenAI configuration.

        Note: Only the endpoint URL and API key can be set via NixOS.
        The API version and provider type must be configured in the
        Open WebUI Admin Settings UI after deployment.
      '';
    };

    # -------------------------------------------------------------------
    # LLM Provider: OpenAI
    # -------------------------------------------------------------------
    openai = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "OpenAI API integration";

          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to file containing OpenAI API key.";
          };
        };
      };
      default = { };
      description = ''
        OpenAI API configuration.
        Note: If Azure is also enabled, Azure takes precedence for OPENAI_API_KEY.
      '';
    };

    # -------------------------------------------------------------------
    # LLM Provider: Anthropic (Claude)
    # -------------------------------------------------------------------
    anthropic = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Anthropic Claude API integration";

          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to file containing Anthropic API key.";
          };
        };
      };
      default = { };
      description = "Anthropic Claude API configuration.";
    };

    # -------------------------------------------------------------------
    # LLM Provider: Ollama / LM Studio
    # -------------------------------------------------------------------
    ollama = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Ollama / LM Studio integration";

          baseUrl = mkOption {
            type = types.str;
            default = "http://localhost:11434";
            example = "http://mac-mini.holthome.net:1234/v1";
            description = ''
              Base URL for Ollama or LM Studio API.
              LM Studio uses OpenAI-compatible API at port 1234.
            '';
          };
        };
      };
      default = { };
      description = "Ollama or LM Studio (local models) configuration.";
    };

    # -------------------------------------------------------------------
    # Web Search Integration: SearXNG
    # -------------------------------------------------------------------
    searxng = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "SearXNG web search integration for RAG";

          queryUrl = mkOption {
            type = types.str;
            default = "http://localhost:8080/search?q=<query>";
            example = "http://searxng.internal:8080/search?q=<query>";
            description = ''
              SearXNG search query URL. Must include `<query>` placeholder.
              The SearXNG instance must have JSON format enabled in settings.yml.
            '';
          };

          resultCount = mkOption {
            type = types.int;
            default = 3;
            description = "Maximum number of search results to return.";
          };

          concurrentRequests = mkOption {
            type = types.int;
            default = 10;
            description = "Maximum concurrent requests to SearXNG.";
          };
        };
      };
      default = { };
      description = ''
        SearXNG web search integration for RAG (Retrieval-Augmented Generation).
        When enabled, Open WebUI can search the web to provide context for responses.
        Requires a running SearXNG instance with JSON format enabled.
      '';
    };

    # -------------------------------------------------------------------
    # Extra environment variables
    # -------------------------------------------------------------------
    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables for Open WebUI.";
    };

    # -------------------------------------------------------------------
    # Standard integrations
    # -------------------------------------------------------------------
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Caddy integration.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Restic backup configuration.";
    };

    logging = mkOption {
      type = types.nullOr sharedTypes.loggingSubmodule;
      default = {
        enable = true;
        journalUnit = "${upstreamServiceName}.service";
        labels = {
          service = serviceName;
          service_type = "ai-chat";
        };
      };
      description = "Log shipping configuration.";
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "Open WebUI failed on ${config.networking.hostName}";
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
        description = "Ordered list of restore strategies.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # Assertions for required configuration
      assertions = [
        {
          assertion = !(cfg.oidc.enable && cfg.oidc.clientSecretFile == null);
          message = "modules.services.open-webui.oidc.clientSecretFile must be set when OIDC is enabled.";
        }
        {
          assertion = !(cfg.azure.enable && cfg.azure.apiKeyFile == null);
          message = "modules.services.open-webui.azure.apiKeyFile must be set when Azure is enabled.";
        }
        {
          assertion = !(cfg.openai.enable && cfg.openai.apiKeyFile == null && !cfg.azure.enable);
          message = "modules.services.open-webui.openai.apiKeyFile must be set when OpenAI is enabled (without Azure).";
        }
        {
          assertion = !(cfg.anthropic.enable && cfg.anthropic.apiKeyFile == null);
          message = "modules.services.open-webui.anthropic.apiKeyFile must be set when Anthropic is enabled.";
        }
        {
          assertion = !(cfg.searxng.enable && !(lib.hasInfix "<query>" cfg.searxng.queryUrl));
          message = "modules.services.open-webui.searxng.queryUrl must contain '<query>' placeholder when SearXNG is enabled.";
        }
      ];

      # ========================================================================
      # User and Group
      # ========================================================================

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = "/var/empty";
        description = "Open WebUI service user";
      };

      users.groups.${cfg.group} = { };

      # ========================================================================
      # Environment File Generator (oneshot service)
      # ========================================================================
      # We create a separate oneshot service to generate the environment file
      # BEFORE open-webui starts. This is needed because systemd validates
      # EnvironmentFile existence before running ExecStartPre.

      systemd.services.open-webui-env = mkIf hasSecrets {
        description = "Open WebUI Environment File Generator";
        wantedBy = [ "multi-user.target" ];
        before = [ "${upstreamServiceName}.service" ];
        requiredBy = [ "${upstreamServiceName}.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "${serviceName}-secrets";
          RuntimeDirectoryMode = "0700";
          LoadCredential = credentials;
        };

        script = ''
          set -euo pipefail
          tmp="${envFile}.tmp"
          trap 'rm -f "$tmp"' EXIT

          {
            ${lib.optionalString (cfg.oidc.enable && cfg.oidc.clientSecretFile != null) ''
              printf "OAUTH_CLIENT_SECRET=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/oidc_client_secret")"
            ''}
            ${lib.optionalString (cfg.azure.enable && cfg.azure.apiKeyFile != null) ''
              printf "OPENAI_API_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/azure_openai_key")"
            ''}
            ${lib.optionalString (cfg.openai.enable && cfg.openai.apiKeyFile != null && !cfg.azure.enable) ''
              printf "OPENAI_API_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/openai_key")"
            ''}
            ${lib.optionalString (cfg.anthropic.enable && cfg.anthropic.apiKeyFile != null) ''
              printf "ANTHROPIC_API_KEY=%s\n" "$(cat "$CREDENTIALS_DIRECTORY/anthropic_key")"
            ''}
          } > "$tmp"

          install -m 600 "$tmp" ${envFile}
          echo "Environment file created at ${envFile}"
        '';
      };

      # ========================================================================
      # Native Open WebUI Service
      # ========================================================================

      # Enable the native NixOS Open WebUI service
      services.open-webui = {
        enable = true;
        package = cfg.package;
        host = cfg.host;
        port = cfg.port;
        environment = combinedEnv;
        # Environment file for secrets (created by open-webui-env.service)
        # Only set if we have secrets, otherwise null (upstream handles this)
        environmentFile = if hasSecrets then envFile else null;
      };

      # Override systemd service for ZFS, static user, and dependencies
      systemd.services.${upstreamServiceName} = {
        # Wait for ZFS mount and environment file
        after = lib.optionals (cfg.datasetPath != null) [ "zfs-mount.service" ]
          ++ lib.optionals hasSecrets [ "open-webui-env.service" ];
        wants = lib.optionals (cfg.datasetPath != null) [ "zfs-mount.service" ];
        requires = lib.optionals hasSecrets [ "open-webui-env.service" ];

        serviceConfig = {
          # Use static user instead of DynamicUser for ZFS dataset ownership
          DynamicUser = lib.mkForce false;
          User = cfg.user;
          Group = cfg.group;

          # State directory management
          StateDirectory = lib.mkForce "open-webui";
          StateDirectoryMode = "0750";

          # Allow reading/writing data directory
          ReadWritePaths = [ cfg.dataDir ];
        };
      };

      # ========================================================================
      # ZFS Dataset Configuration
      # ========================================================================

      modules.storage.datasets.services.${serviceName} = mkIf (cfg.datasetPath != null) {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Optimized for SQLite
        compression = "zstd";
        properties."com.sun:auto-snapshot" = "true";
        # Set ownership for ZFS dataset (native services need this since
        # StateDirectory can't manage ZFS mounts)
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      # Reverse proxy registration with Caddy
      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = cfg.reverseProxy.backend;
        # Note: Do NOT use Caddy auth layer - Open WebUI handles auth via OIDC
      };

      # Backup integration
      modules.backup.restic.jobs.${serviceName} = mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        paths = [ cfg.dataDir ];
        repository = cfg.backup.repository;
        tags = cfg.backup.tags or [ serviceName "ai-chat" ];
        excludePatterns = cfg.backup.excludePatterns or [
          "**/cache/**"
          "**/*.log"
        ];
      };
    })
  ];
}
