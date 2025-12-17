# modules/nixos/services/searxng/default.nix
#
# Native NixOS wrapper for SearXNG privacy-respecting meta search engine.
#
# Features:
# - Wraps native services.searx NixOS module with homelab patterns
# - Redis rate limiter support (optional but recommended for bot protection)
# - Optimized settings for Open-WebUI integration (JSON format, no limiter)
# - Security headers and privacy-focused defaults
# - Enhanced UI: vim hotkeys, infinite scroll, auto dark/light theme
# - Optimized outgoing requests: 3s timeout, HTTP/2, connection pooling
# - Privacy plugins: Tracker URL remover, DOI rewrite, unit converter
# - ZFS storage integration
# - Standard integrations: backup, monitoring, reverse proxy
#
# Best practices incorporated from:
# - SearXNG official documentation
# - truxnell/nix-config (UI settings, outgoing tuning, plugins)
# - NixOS Wiki SearXNG examples
#
# Complexity: Simple (native wrapper, stateless search engine)
#
# Reference: Gatus module for native wrapper pattern
#
# Open-WebUI Integration:
#   SearXNG must have JSON format enabled in search.formats for Open-WebUI
#   to query it successfully. This module enables JSON by default.
#   Configure Open-WebUI with:
#     SEARXNG_QUERY_URL = "http://127.0.0.1:8888/search?q=<query>"

{ config, lib, mylib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mkMerge optionalAttrs;

  cfg = config.modules.services.searxng;
  serviceName = "searxng";

  # Storage helpers via mylib injection (centralized import)
  storageHelpers = mylib.storageHelpers pkgs;

  # Import shared type definitions
  sharedTypes = mylib.types;

  # Storage configuration
  storageCfg = config.modules.storage;
  datasetPath = "${storageCfg.datasets.parentDataset}/${serviceName}";

  # Build replication config for preseed (walks up dataset tree to find inherited config)
  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };

  # The main systemd service unit - when using uWSGI, the service is "uwsgi"
  mainServiceUnit = if cfg.runInUwsgi then "uwsgi.service" else "searx.service";

in
{
  options.modules.services.searxng = {
    enable = mkEnableOption "SearXNG privacy-respecting meta search engine";

    port = mkOption {
      type = types.port;
      default = 8888;
      description = "Port for SearXNG web interface.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/searxng";
      description = "Directory for SearXNG data (settings cache, favicons).";
    };

    runInUwsgi = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run SearXNG in uWSGI for better performance.
        Recommended for production/homelab use.
        The built-in HTTP server logs all queries by default.
        Note: Internally maps to services.searx.configureUwsgi.
      '';
    };

    # Redis rate limiter
    redisCreateLocally = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Configure a local Redis server for SearXNG rate limiting and bot protection.
        Recommended for public instances, optional for private/internal use.
        When false, the limiter is disabled for better Open-WebUI performance.
      '';
    };

    # Secret key for CSRF protection
    secretKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to file containing SearXNG secret key for CSRF protection.
        If null, a default (insecure) key is used.
        Generate with: openssl rand -hex 32
      '';
    };

    # Search engine settings
    settings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Additional SearXNG settings to merge with defaults.
        These are merged with the base configuration optimized for Open-WebUI.
        See https://docs.searxng.org/admin/settings/settings.html
      '';
      example = {
        search.autocomplete = "google";
        search.safe_search = 1;
        engines = [
          { name = "google"; disabled = false; }
          { name = "bing"; disabled = false; }
        ];
      };
    };

    # Base URL for generating links
    baseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://search.holthome.net";
      description = "External URL for SearXNG (used for generating links).";
    };

    # Standardized integrations
    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for SearXNG web interface.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for SearXNG data.";
    };

    # Notifications
    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "infrastructure-alerts" ];
        };
        customMessages = {
          failure = "SearXNG search service failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for SearXNG service events.";
    };

    # Preseed/DR capability
    preseed = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "automatic data restore before service start";

          repositoryUrl = mkOption {
            type = types.str;
            default = "";
            description = "URL to Restic repository for preseed restore.";
          };

          passwordFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to file containing Restic repository password.";
          };

          restoreMethods = mkOption {
            type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
            default = [ "syncoid" "local" ];
            description = "Ordered list of restore methods to attempt.";
          };
        };
      };
      default = { };
      description = "Preseed/DR restore configuration.";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # Validations
      assertions = [
        {
          assertion = cfg.secretKeyFile != null;
          message = "modules.services.searxng.secretKeyFile must be set for CSRF protection.";
        }
      ];

      # Enable native NixOS SearXNG service
      services.searx = {
        enable = true;
        package = pkgs.searxng;

        # Redis for rate limiting (optional)
        redisCreateLocally = cfg.redisCreateLocally;

        # Environment file for secret key
        environmentFile = cfg.secretKeyFile;

        # SearXNG settings optimized for Open-WebUI integration
        # Based on best practices from community and truxnell/nix-config
        settings = lib.recursiveUpdate
          {
            # Server settings
            server = {
              port = cfg.port;
              bind_address = "127.0.0.1";
              secret_key = "@SEARXNG_SECRET@"; # Replaced from environment file
              # Limiter disabled for internal use (Open-WebUI won't be rate limited)
              # Enable if using Redis for public instances
              limiter = cfg.redisCreateLocally;
              image_proxy = true;
              http_protocol_version = "1.1";
              method = "POST"; # POST is more private than GET
              # Security headers (best practice)
              default_http_headers = {
                X-Content-Type-Options = "nosniff";
                X-Download-Options = "noopen";
                X-Robots-Tag = "noindex, nofollow";
                Referrer-Policy = "no-referrer";
              };
            } // optionalAttrs (cfg.baseUrl != null) {
              base_url = cfg.baseUrl;
            };

            # UI settings (truxnell-inspired with best practices)
            ui = {
              static_use_hash = true;
              default_theme = "simple";
              default_locale = "en";
              center_alignment = true;
              hotkeys = "vim"; # Vim keybindings for power users
              infinite_scroll = true;
              query_in_title = true;
              theme_args.simple_style = "auto"; # Auto dark/light mode
            };

            # Search settings - CRITICAL: JSON format for Open-WebUI
            search = {
              safe_search = 0;
              autocomplete = "duckduckgo"; # Privacy-focused autocomplete
              autocomplete_min = 4;
              default_lang = "en";
              ban_time_on_fail = 5; # Seconds to ban failing engine
              max_ban_time_on_fail = 120; # Max ban duration
              # IMPORTANT: JSON format MUST be enabled for Open-WebUI integration
              formats = [ "html" "json" "csv" "rss" ];
            };

            # Outgoing request settings (optimized for homelab)
            # Based on SearXNG docs and community best practices
            outgoing = {
              request_timeout = 3.0; # Slightly longer than default 2.0 for more results
              max_request_timeout = 10.0; # Cap for slow engines
              pool_connections = 100; # Default is fine
              pool_maxsize = 15; # Slightly higher than default 10
              enable_http2 = true;
            };

            # General settings
            general = {
              debug = false;
              instance_name = "SearXNG";
              enable_metrics = true; # Enable for monitoring
            };

            # Enabled plugins (best practice set)
            enabled_plugins = [
              "Basic Calculator"
              "Hash plugin"
              "Tor check plugin"
              "Open Access DOI rewrite"
              "Unit converter plugin"
              "Tracker URL remover"
            ];
          }
          cfg.settings;

        # uWSGI configuration for production
        configureUwsgi = cfg.runInUwsgi;
        uwsgiConfig = mkIf cfg.runInUwsgi {
          http = "127.0.0.1:${toString cfg.port}";
          socket = "/run/searx/searx.sock";
          chmod-socket = "660";
        };
      };

      # Override systemd service for ZFS integration
      systemd.services.uwsgi = mkIf cfg.runInUwsgi {
        after = [ "local-fs.target" "zfs-mount.service" ];
        wants = [ "zfs-mount.service" ];
      };

      # Create searxng user/group (native module creates "searx" user)
      # We'll use the native user but ensure proper permissions

      # ZFS storage dataset
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = cfg.dataDir;
        recordsize = "16K"; # Config files and small state
        compression = "zstd";
        properties = {
          "com.sun:auto-snapshot" = "true";
        };
        owner = "searx"; # Native module uses "searx" user
        group = "searx";
        mode = "0750";
      };

      # Caddy reverse proxy integration
      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = cfg.reverseProxy.backend or {
          scheme = "http";
          host = "127.0.0.1";
          port = cfg.port;
        };
        caddySecurity = cfg.reverseProxy.caddySecurity or null;
        extraConfig = cfg.reverseProxy.extraConfig or "";
      };

      # Backup integration
      modules.backup.restic.jobs.${serviceName} = mkIf (cfg.backup != null && cfg.backup.enable) {
        enable = true;
        paths = [ cfg.dataDir ];
        repository = cfg.backup.repository;
        tags = cfg.backup.tags or [ "infrastructure" serviceName "search" ];
        useSnapshots = cfg.backup.useSnapshots or true;
        zfsDataset = cfg.backup.zfsDataset or null;
      };

      # Firewall - only allow localhost access (internal service via reverse proxy)
      networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ];
    })

    # Preseed service for DR
    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        serviceName = serviceName;
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
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = (config.modules.notifications.enable or false);
        owner = "searx";
        group = "searx";
      }
    ))
  ];
}
