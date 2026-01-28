# modules/nixos/services/autobrr/default.nix
#
# Autobrr - IRC announce bot for torrent automation
#
# This module uses the service factory pattern for standardized container service
# configuration with custom extensions for OIDC authentication and metrics.
#
# FACTORY PATTERN:
# - Inherits: Standard options (dataDir, resources, healthcheck, reverseProxy, backup, etc.)
# - Custom: settings submodule (OIDC, session secret, metrics), config generator
#
# Architecture:
# - Long-running daemon with WebUI (port 7474)
# - Config generator creates config.toml if missing (preserves user customizations)
# - OIDC authentication via PocketID
# - Prometheus metrics on separate port (default 9084)
#
# Host configuration example:
#   modules.services.autobrr = {
#     enable = true;
#     configGenerator.environmentFile = config.sops.templates."autobrr-env".path;
#     settings.sessionSecretFile = config.sops.secrets."autobrr/session-secret".path;
#     oidc = {
#       enable = true;
#       issuer = "https://id.example.com";
#       clientId = "autobrr";
#       clientSecretFile = config.sops.secrets."autobrr/oidc-client-secret".path;
#       redirectUrl = "https://autobrr.example.com/api/auth/oidc/callback";
#     };
#   };
#
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "autobrr";
  description = "IRC announce bot for torrent automation";

  spec = {
    port = 7474;
    image = "ghcr.io/autobrr/autobrr:v1.72.0@sha256:9964eab1afccc22bbf6a5d44566a08faa26316aa90a13bdc6a40cb8a5dada129";

    category = "downloads";
    displayName = "Autobrr";
    function = "announce-bot";

    # ZFS dataset properties
    zfsRecordSize = "16K";
    zfsCompression = "zstd";

    # Container configuration
    runAsRoot = false; # Uses --user flag, not PUID/PGID

    # Autobrr doesn't need NFS mount for downloads - it's an IRC announce bot
    # that monitors channels and triggers other clients, not a download client itself
    volumes = _cfg: [ ];

    # Health check endpoint
    healthEndpoint = "/api/healthz/liveness";

    # Default resources (based on observed usage: 26M peak × 2.5 = 65M)
    resources = {
      memory = "128M";
      memoryReservation = "64M";
      cpus = "0.5";
    };

    # Backup excludes
    backupExcludePatterns = [
      "**/cache/**"
    ];

    # Start period - autobrr starts quickly
    startPeriod = "30s";

    # Enable config generator
    hasConfigGenerator = true;
  };

  # Extra options beyond factory defaults
  extraOptions = {
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
        type = lib.types.nullOr lib.types.path;
        default = null;
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
            type = lib.types.nullOr lib.types.path;
            default = null;
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
      description = "OIDC authentication configuration for SSO via PocketID/Authelia";
    };

    # Metrics configuration - autobrr exposes on a separate port from main WebUI
    # This overrides the factory's standard metrics option with app-specific config
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
            default = 9084;
            description = "Port for the metrics server to listen on (separate from WebUI port).";
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
        port = 9084;
        path = "/metrics";
        labels = {
          service_type = "automation";
          function = "irc_grabber";
        };
      };
      description = "Prometheus metrics collection configuration for Autobrr";
    };
  };

  # Service-specific configuration
  extraConfig = cfg:
    let
      configFile = "${cfg.dataDir}/config.toml";
    in
    {
      assertions = [
        {
          assertion = cfg.settings.sessionSecretFile != null;
          message = "Autobrr requires settings.sessionSecretFile to be set for session security.";
        }
        {
          assertion = cfg.configGenerator.environmentFile != null;
          message = "Autobrr requires configGenerator.environmentFile to be set (typically a SOPS template) for secret injection.";
        }
      ];

      # Config generator script for config.toml
      modules.services.autobrr.configGenerator.script = ''
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

      # Add metrics port mapping to container when metrics enabled
      virtualisation.oci-containers.containers.autobrr.ports =
        lib.mkIf (cfg.metrics != null && cfg.metrics.enable)
          (lib.mkAfter [ "${toString cfg.metrics.port}:${toString cfg.metrics.port}" ]);
    };
}
