# LiteLLM - Unified AI Gateway
#
# Wraps the native NixOS services.litellm module with homelab integration:
# - ZFS storage management
# - Reverse proxy configuration
# - Backup and disaster recovery
#
# IMPORTANT: Native NixOS mode runs LiteLLM in STATELESS mode only.
# The upstream NixOS module doesn't support database features because
# prisma-python requires runtime code generation which conflicts with
# NixOS's immutable store.
#
# Stateless mode provides:
# - Model routing and load balancing
# - Automatic failovers between providers
# - Streaming support
# - Per-request cost tracking (in-memory, not persisted)
# - Master key authentication
#
# For database features (spend tracking, user management, virtual keys),
# use the container version: ghcr.io/berriai/litellm:main-latest
#
# Reference: https://github.com/BerriAI/litellm
# Upstream NixOS module: nixos/modules/services/misc/litellm.nix
#
{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    optional
    ;

  cfg = config.modules.services.litellm;
  serviceName = "litellm";

  # Import shared types for standardized submodules
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Build the model_list configuration for LiteLLM
  # Maps user-friendly model names to provider-specific configurations
  buildModelList = models: map (m: {
    model_name = m.name;
    litellm_params = {
      model = m.model;
      api_base = m.apiBase or null;
      api_key = m.apiKey or null;
    } // (m.extraParams or { });
  }) models;

  # Build environment file content from provider secrets
  # This runs in preStart to assemble secrets without storing them in the Nix store
  buildEnvScript = ''
    set -euo pipefail

    # Start with provider keys from environmentFile
    if [[ -f "''${CREDENTIALS_DIRECTORY}/provider-keys" ]]; then
      cat "''${CREDENTIALS_DIRECTORY}/provider-keys" > "$RUNTIME_DIRECTORY/env"
    else
      touch "$RUNTIME_DIRECTORY/env"
    fi

    # Master key handling: use provided file or auto-generate
    if [[ -f "''${CREDENTIALS_DIRECTORY}/master-key" ]]; then
      # Use provided master key
      echo "LITELLM_MASTER_KEY=$(cat "''${CREDENTIALS_DIRECTORY}/master-key")" >> "$RUNTIME_DIRECTORY/env"
    else
      # Auto-generate master key if not exists
      MASTER_KEY_FILE="$STATE_DIRECTORY/master-key"
      if [[ ! -f "$MASTER_KEY_FILE" ]]; then
        ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '/+=' | ${pkgs.coreutils}/bin/head -c 32 > "$MASTER_KEY_FILE"
        chmod 600 "$MASTER_KEY_FILE"
      fi
      echo "LITELLM_MASTER_KEY=$(cat "$MASTER_KEY_FILE")" >> "$RUNTIME_DIRECTORY/env"
    fi

    chmod 600 "$RUNTIME_DIRECTORY/env"
  '';
in
{
  options.modules.services.litellm = {
    enable = mkEnableOption "LiteLLM unified AI gateway (stateless mode)";

    # ==========================================================================
    # Core Configuration
    # ==========================================================================

    user = mkOption {
      type = types.str;
      default = serviceName;
      description = "User account under which LiteLLM runs";
    };

    group = mkOption {
      type = types.str;
      default = serviceName;
      description = "Group under which LiteLLM runs";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port for LiteLLM API server";
    };

    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Host to bind the LiteLLM server to";
    };

    # ==========================================================================
    # Model Configuration
    # ==========================================================================

    models = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "User-friendly model name (what clients request)";
            example = "gpt-4o";
          };

          model = mkOption {
            type = types.str;
            description = "Provider-specific model identifier";
            example = "azure/gpt-4o";
          };

          apiBase = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "API base URL (for Azure deployments)";
            example = "https://myresource.openai.azure.com";
          };

          apiKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Environment variable name containing API key";
            example = "AZURE_API_KEY";
          };

          extraParams = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = "Additional litellm_params for this model";
            example = { api_version = "2024-02-15-preview"; };
          };
        };
      });
      default = [ ];
      description = "List of AI models to expose through LiteLLM";
    };

    routerSettings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "LiteLLM router settings (fallbacks, load balancing)";
      example = {
        routing_strategy = "simple-shuffle";
        num_retries = 3;
      };
    };

    litellmSettings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        drop_params = true;
        set_verbose = false;
      };
      description = "LiteLLM general settings";
    };

    # ==========================================================================
    # Secrets
    # ==========================================================================

    masterKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to file containing LiteLLM master key for admin access.
        If not provided, a random key will be auto-generated and stored
        in the state directory.
      '';
      example = "/run/secrets/litellm/master-key";
    };

    environmentFile = mkOption {
      type = types.path;
      description = "Path to file containing provider API keys (AZURE_API_KEY, OPENAI_API_KEY, etc.)";
      example = "/run/secrets/litellm/provider-keys";
    };

    # ==========================================================================
    # Storage Configuration
    # ==========================================================================

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/litellm";
      description = "Directory for LiteLLM data (auto-generated master key)";
    };

    zfs = {
      dataset = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tank/services/litellm";
        description = "ZFS dataset to use for LiteLLM data";
      };

      properties = mkOption {
        type = types.attrsOf types.str;
        default = {
          recordsize = "128K";
          compression = "lz4";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        description = "ZFS dataset properties";
      };
    };

    # ==========================================================================
    # Integration Submodules
    # ==========================================================================

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration";
    };

    preseed = {
      enable = mkEnableOption "automatic restore before service start";

      repositoryUrl = mkOption {
        type = types.str;
        default = "/mnt/nas-backup";
        description = "URL to Restic repository for preseed restore";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to Restic repository password file";
      };

      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Ordered list of restore methods to attempt";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # ==========================================================================
    # Core Service Configuration (Stateless Mode)
    # ==========================================================================
    {
      # Enable the native NixOS litellm service
      services.litellm = {
        enable = true;
        host = cfg.host;
        port = cfg.port;

        # Environment file is created by litellm-env oneshot service
        environmentFile = "/run/litellm/env";

        settings = {
          model_list = buildModelList cfg.models;
          router_settings = cfg.routerSettings;
          litellm_settings = cfg.litellmSettings;

          # Stateless mode: only master key, no database
          general_settings = {
            master_key = "os.environ/LITELLM_MASTER_KEY";
          };
        };
      };

      # ========================================================================
      # User and Group
      # ========================================================================

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = "/var/empty";
        description = "LiteLLM AI gateway service user";
      };

      users.groups.${cfg.group} = { };

      # ========================================================================
      # Directory Management
      # ========================================================================

      systemd.tmpfiles.rules = [
        "d /var/lib/${serviceName} 0750 ${cfg.user} ${cfg.group} -"
        "d /run/${serviceName} 0700 ${cfg.user} ${cfg.group} -"
      ];

      # ========================================================================
      # Environment File Generator (oneshot service)
      # ========================================================================
      # We create a separate oneshot service to generate the environment file
      # BEFORE litellm starts. This is needed because systemd validates
      # EnvironmentFile existence before running ExecStartPre.

      systemd.services.litellm-env = {
        description = "LiteLLM Environment File Generator";
        wantedBy = [ "multi-user.target" ];
        before = [ "litellm.service" ];
        requiredBy = [ "litellm.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = cfg.group;

          # Create runtime directory for env file
          RuntimeDirectory = serviceName;
          RuntimeDirectoryMode = "0700";

          # Create state directory for auto-generated master key
          StateDirectory = serviceName;
          StateDirectoryMode = "0700";

          # Permissions for secret files
          LoadCredential = [
            "provider-keys:${cfg.environmentFile}"
          ]
          ++ optional (cfg.masterKeyFile != null) "master-key:${cfg.masterKeyFile}";
        };

        script = buildEnvScript;
      };

      # Override systemd service to use static user
      systemd.services.litellm = {
        # Ensure env file is ready
        after = [ "litellm-env.service" ];
        requires = [ "litellm-env.service" ];

        serviceConfig = {
          # Use static user instead of DynamicUser for consistent ownership
          DynamicUser = lib.mkForce false;
          User = cfg.user;
          Group = cfg.group;

          # Disable automatic directory creation - we manage via tmpfiles
          RuntimeDirectory = lib.mkForce "";
          StateDirectory = lib.mkForce "";

          # Allow reading/writing data directory
          ReadWritePaths = [ "/var/lib/${serviceName}" "/run/${serviceName}" ];
        };
      };
    }

    # ==========================================================================
    # ZFS Storage Configuration
    # ==========================================================================
    (mkIf (cfg.zfs.dataset != null) {
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        properties = cfg.zfs.properties;
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };
    })

    # ==========================================================================
    # Reverse Proxy Configuration
    # ==========================================================================
    (mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = cfg.reverseProxy.backend;
        extraConfig = cfg.reverseProxy.extraConfig or "";
      };
    })
  ]);
}
