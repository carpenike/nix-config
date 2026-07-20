# modules/nixos/services/qui/default.nix
#
# qui - Modern web interface for qBittorrent
#
# Factory-based implementation (see lib/service-factory.nix).
{ lib
, mylib
, pkgs
, config
, podmanLib
, ...
}:

let
  # Resolved lazily after option evaluation - safe to reference here.
  quiPort = config.modules.services.qui.port;
in
mylib.mkContainerService {
  inherit lib mylib pkgs config podmanLib;

  name = "qui";
  description = "qui";

  spec = {
    # Core service configuration
    port = 7476;
    image = "ghcr.io/autobrr/qui:latest";
    operationalProfile = "media";
    displayName = "qui";
    function = "qbittorrent_ui";

    healthCommand = "wget --no-verbose --tries=1 --spider http://localhost:${toString quiPort}/health || exit 1";
    startPeriod = "30s";

    # ZFS tuning - 16K recordsize optimal for the SQLite database (qui.db),
    # lz4 for fast compression of database and config files.
    zfsRecordSize = "16K";
    zfsCompression = "lz4";

    # qui is lightweight but may consume more resources with multiple
    # qBittorrent instances or large torrent collections (>1000 torrents).
    resources = {
      memory = "512M";
      memoryReservation = "256M";
      cpus = "1.0";
    };

    environment = { cfg, ... }: {
      QUI__HOST = cfg.hostAddress;
      QUI__PORT = toString cfg.port;
      QUI__BASE_URL = cfg.baseUrl;
      QUI__LOG_LEVEL = cfg.logLevel;
      QUI__CHECK_FOR_UPDATES = if cfg.checkForUpdates then "true" else "false";
    } // lib.optionalAttrs cfg.metricsEnabled {
      QUI__METRICS_ENABLED = "true";
      QUI__METRICS_HOST = cfg.metricsHost;
      QUI__METRICS_PORT = toString cfg.metricsPort;
    } // lib.optionalAttrs (cfg.oidc != null && cfg.oidc.enabled) {
      QUI__OIDC_ENABLED = "true";
      QUI__OIDC_ISSUER = cfg.oidc.issuer;
      QUI__OIDC_CLIENT_ID = cfg.oidc.clientId;
      QUI__OIDC_REDIRECT_URL = cfg.oidc.redirectUrl;
      QUI__OIDC_DISABLE_BUILT_IN_LOGIN = if cfg.oidc.disableBuiltInLogin then "true" else "false";
    };

    # Own volume list (dataDir without explicit :rw, plus host-provided
    # extra volumes for cross-seed hardlink mode).
    skipDefaultConfigMount = true;
    volumes = cfg: [
      "${cfg.dataDir}:/config"
    ] ++ cfg.extraVolumes;

    # Extra /etc/hosts entries (hairpin NAT workaround)
    extraOptions = { cfg, ... }:
      lib.mapAttrsToList (host: ip: "--add-host=${host}:${ip}") cfg.extraHosts;
  };

  extraOptions = {
    extraHosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra /etc/hosts entries for the container.

        Useful for overriding DNS resolution when containers need to reach
        host services via internal bridge IPs (hairpin NAT workaround).
      '';
      example = {
        "id.holthome.net" = "10.89.0.1";
        "auth.example.com" = "10.89.0.1";
      };
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = ''
        Host address to bind to.
        Use "0.0.0.0" for container environments (allows external access).
        Use "localhost" or "127.0.0.1" for local-only access.
      '';
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "/";
      description = ''
        Base URL path for serving qui from a subdirectory.

        Examples:
        - "/" for root domain (https://qui.example.com/)
        - "/qui/" for subdirectory (https://example.com/qui/)

        Must include trailing slash when using subdirectory.
      '';
      example = "/qui/";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "ERROR" "WARN" "INFO" "DEBUG" "TRACE" ];
      default = "INFO";
      description = "Logging level for qui";
    };

    metricsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Prometheus metrics endpoint.

        Metrics are served on a separate port (default: 9074) with optional basic auth.
        Includes torrent counts by status, transfer speeds, and instance health.
      '';
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9074;
      description = "Port for Prometheus metrics endpoint (when metricsEnabled = true)";
    };

    metricsHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Bind address for metrics endpoint.
        Use "127.0.0.1" (recommended for security) or "0.0.0.0" if Prometheus runs externally.
      '';
    };

    oidc = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable OIDC single sign-on authentication";
          };

          issuer = lib.mkOption {
            type = lib.types.str;
            description = "OIDC issuer URL (e.g., https://auth.example.com/realms/main)";
          };

          clientId = lib.mkOption {
            type = lib.types.str;
            description = "OIDC client ID registered for qui";
          };

          clientSecretFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              Path to file containing OIDC client secret.
              Use SOPS or similar for secure secret management.

              SECURITY NOTE: This file will be mounted read-only at /run/secrets/oidc_client_secret
              inside the container. After the first run, you MUST manually edit config.toml in the
              data directory and set the 'client_secret' value under the [oidc] section to:
              "/run/secrets/oidc_client_secret"

              This application does not yet support reading secrets from files via environment
              variables (QUI__OIDC_CLIENT_SECRET_FILE pattern). This manual step prevents the
              secret from being exposed in container environment variables.
            '';
          };

          redirectUrl = lib.mkOption {
            type = lib.types.str;
            description = ''
              OIDC redirect URL - must match IdP configuration.
              Format: https://your-domain/api/auth/oidc/callback
              Include baseUrl if using subdirectory (e.g., https://host/qui/api/auth/oidc/callback)
            '';
          };

          disableBuiltInLogin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Hide local username/password login form when OIDC is enabled";
          };
        };
      });
      default = null;
      description = "OpenID Connect (OIDC) authentication configuration";
    };

    externalProgramAllowList = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ "/var/empty" ];
      description = ''
        Whitelist of executable paths allowed in torrent context menu external programs.

        Can include:
        - Direct paths to binaries: /usr/local/bin/sonarr
        - Directory paths (allows any executable inside): /home/user/bin

        SECURITY NOTE: The upstream application treats an empty list as "allow any path",
        which is insecure. This module defaults to a safe, non-existent path (/var/empty)
        to disable the feature. To use external programs, override this option with your
        desired executable paths.

        This setting is stored in config.toml which the UI cannot edit for security.
      '';
      example = [ "/usr/local/bin/sonarr" "/home/user/scripts" ];
    };

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional volume mounts for the qui container.

        Use this to provide qui with access to the media filesystem for
        cross-seed hardlink/reflink mode, which requires local filesystem access.

        Format: "/host/path:/container/path[:options]"
      '';
      example = [ "/mnt/media:/mnt/media:ro" ];
    };

    checkForUpdates = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Check for qui updates on startup.
        Disable for air-gapped systems or when using container auto-updates.
      '';
    };

    # Backups are configured explicitly by hosts (overrides the factory
    # default of enabled). qui has a built-in qBittorrent backup/restore
    # feature; this option is for qui's own state only.
    backup = lib.mkOption {
      type = lib.types.nullOr mylib.types.backupSubmodule;
      default = null;
      description = "Backup configuration for qui data (config.toml, qui.db, tracker-icons)";
    };

    # Scrape registration is opt-in and separate from qui's own
    # metricsEnabled toggle (overrides the factory default of enabled).
    metrics = lib.mkOption {
      type = lib.types.nullOr mylib.types.metricsSubmodule;
      default = null;
      description = ''
        Prometheus metrics collection configuration for qui.

        When qui.metricsEnabled = true, qui exposes metrics on qui.metricsPort.
        This option controls whether to register qui with Prometheus scraping.
      '';
    };
  };

  extraConfig = cfg: {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.baseUrl;
        message = "qui baseUrl must be an absolute path starting with '/' (e.g., '/' or '/qui/').";
      }
      {
        assertion = cfg.baseUrl == "/" || lib.hasSuffix "/" cfg.baseUrl;
        message = "qui baseUrl must end with a trailing slash ('/') when using subdirectory paths (e.g., '/qui/').";
      }
      {
        assertion = let path = lib.removeSuffix "/" cfg.baseUrl; in path == "" || !lib.hasSuffix "/" path;
        message = "qui baseUrl contains redundant trailing slashes (e.g., '//' or '/qui//').";
      }
      {
        assertion = cfg.oidc == null || !cfg.oidc.enabled || (builtins.isPath cfg.oidc.clientSecretFile || builtins.isString cfg.oidc.clientSecretFile);
        message = "qui OIDC authentication requires oidc.clientSecretFile to be set.";
      }
      {
        assertion = cfg.oidc == null || !cfg.oidc.enabled || (cfg.oidc.issuer != "" && lib.hasPrefix "http" cfg.oidc.issuer);
        message = "qui OIDC authentication requires oidc.issuer to be a valid URL starting with 'http' (e.g., 'https://auth.example.com/realms/main').";
      }
      {
        assertion = cfg.oidc == null || !cfg.oidc.enabled || cfg.oidc.clientId != "";
        message = "qui OIDC authentication requires oidc.clientId to be set.";
      }
      {
        assertion = cfg.oidc == null || !cfg.oidc.enabled || (cfg.oidc.redirectUrl != "" && lib.hasPrefix "http" cfg.oidc.redirectUrl);
        message = "qui OIDC authentication requires oidc.redirectUrl to be a valid URL starting with 'http' (e.g., 'https://qui.example.com/api/auth/oidc/callback').";
      }
    ];

    # qui's home is its data directory (pre-factory behavior)
    users.users.qui = {
      home = cfg.dataDir;
      createHome = true;
    };

    virtualisation.oci-containers.containers.qui = {
      # OIDC client secret via SOPS template
      environmentFiles = lib.optionals (cfg.oidc != null && cfg.oidc.enabled) [
        config.sops.templates."qui-env".path
      ];
      # Prometheus metrics endpoint on a separate port
      ports = lib.optionals cfg.metricsEnabled [
        "${cfg.metricsHost}:${toString cfg.metricsPort}:${toString cfg.metricsPort}"
      ];
    };

    systemd.services."${config.virtualisation.oci-containers.backend}-qui" = {
      serviceConfig.RestartSec = "10s";
    };

    # Preserve the pre-factory notification wording
    modules.notifications.templates."qui-failure" =
      lib.mkIf (config.modules.notifications.enable or false && cfg.notifications != null && cfg.notifications.enable) {
        body = ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The qui qBittorrent interface service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u ''${serviceName} -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart ''${serviceName}'</code>
        '';
      };
  };
}
