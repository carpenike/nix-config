# Homepage Dashboard - Native NixOS Service Wrapper
#
# This module wraps the native services.homepage-dashboard NixOS service and adds:
# - Standardized integration submodules (reverseProxy, backup, notifications)
# - Contributory pattern for services to register themselves
# - Host-level integration patterns (storage, monitoring, etc.)
#
# Architecture Decision:
# - Uses native NixOS module (services.homepage-dashboard) - NOT a container
# - Follows "native over containers" principle per modular-design-patterns.md
# - Homepage does NOT have native auth - relies on reverse proxy (Caddy + PocketID)
#
# Contributory Pattern:
# Other services can add themselves to the dashboard by setting:
#   modules.services.homepage.contributions.<serviceName> = { ... };
#
# Example:
#   modules.services.homepage.contributions.sonarr = {
#     group = "Media";
#     name = "Sonarr";
#     icon = "sonarr";
#     href = "https://sonarr.holthome.net";
#     description = "TV series management";
#     widget = {
#       type = "sonarr";
#       url = "http://localhost:8989";
#       key = "{{HOMEPAGE_VAR_SONARR_API_KEY}}";
#     };
#   };

{ lib, config, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mapAttrsToList;

  cfg = config.modules.services.homepage;

  # Import shared type definitions
  sharedTypes = import ../../../lib/types.nix { inherit lib; };

  # Convert contributions to Homepage services.yaml format
  # Groups contributions by their 'group' attribute
  contributionsToServices = contributions:
    let
      # Get unique groups
      groups = lib.unique (mapAttrsToList (_: c: c.group) contributions);

      # Build services for each group
      mkGroupServices = group:
        let
          # Filter contributions for this group
          groupContributions = lib.filterAttrs (_: c: c.group == group) contributions;
          # Convert each contribution to Homepage service format
          mkService = name: contrib: {
            "${contrib.name}" = {
              inherit (contrib) icon href description;
            } // lib.optionalAttrs (contrib.widget != null) {
              widget = contrib.widget;
            } // lib.optionalAttrs (contrib.server != null) {
              server = contrib.server;
            } // lib.optionalAttrs (contrib.container != null) {
              container = contrib.container;
            } // lib.optionalAttrs (contrib.siteMonitor != null) {
              siteMonitor = contrib.siteMonitor;
            } // lib.optionalAttrs (contrib.statusStyle != null) {
              statusStyle = contrib.statusStyle;
            };
          };
        in
        { "${group}" = mapAttrsToList mkService groupContributions; };
    in
    lib.foldl' (acc: group: acc ++ [ (mkGroupServices group) ]) [ ] groups;

  # Contribution submodule type
  contributionSubmodule = types.submodule {
    options = {
      group = mkOption {
        type = types.str;
        description = "Dashboard group/category for this service";
        example = "Media";
      };

      name = mkOption {
        type = types.str;
        description = "Display name for the service";
        example = "Sonarr";
      };

      icon = mkOption {
        type = types.str;
        description = "Icon name (from dashboard-icons or URL)";
        example = "sonarr";
      };

      href = mkOption {
        type = types.str;
        description = "URL to the service";
        example = "https://sonarr.holthome.net";
      };

      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Short description of the service";
        example = "TV series management";
      };

      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Docker server name for container status";
        example = "localhost";
      };

      container = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Container name for status monitoring";
        example = "sonarr";
      };

      siteMonitor = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "URL to monitor for uptime status";
        example = "http://localhost:8989";
      };

      statusStyle = mkOption {
        type = types.nullOr (types.enum [ "dot" "basic" "full" ]);
        default = null;
        description = "Style for status indicator";
      };

      widget = mkOption {
        type = types.nullOr (types.attrsOf types.anything);
        default = null;
        description = "Widget configuration for Homepage integration";
        example = {
          type = "sonarr";
          url = "http://localhost:8989";
          key = "{{HOMEPAGE_VAR_SONARR_API_KEY}}";
        };
      };
    };
  };

  # Enabled contributions only
  enabledContributions = lib.filterAttrs (_: _c: true) cfg.contributions;
in
{
  options.modules.services.homepage = {
    enable = mkEnableOption "Homepage dashboard";

    port = mkOption {
      type = types.port;
      default = 3003;
      description = "Port for Homepage dashboard to listen on";
    };

    # =========================================================================
    # Contributory Pattern: Other services register themselves here
    # =========================================================================

    contributions = mkOption {
      type = types.attrsOf contributionSubmodule;
      default = { };
      description = ''
        Services can register themselves with the dashboard by adding entries here.
        This creates a decentralized configuration where each service module
        contributes its own dashboard entry.

        Example in a service module:
          modules.services.homepage.contributions.sonarr = {
            group = "Media";
            name = "Sonarr";
            icon = "sonarr";
            href = "https://sonarr.holthome.net";
            widget = { type = "sonarr"; url = "http://localhost:8989"; key = "..."; };
          };
      '';
    };

    # =========================================================================
    # Direct Configuration (merged with contributions)
    # =========================================================================

    settings = mkOption {
      type = types.attrsOf types.anything;
      default = {
        title = "Homelab";
        favicon = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/homepage.png";
        headerStyle = "clean";
        layout = { };
      };
      description = "Homepage settings.yaml configuration";
    };

    bookmarks = mkOption {
      type = types.listOf types.anything;
      default = [ ];
      description = "Homepage bookmarks.yaml configuration";
    };

    widgets = mkOption {
      type = types.listOf types.anything;
      default = [ ];
      description = ''
        Homepage information widgets (top bar).
        Common widgets: resources, search, datetime, openmeteo, glances
      '';
      example = [
        { resources = { cpu = true; memory = true; disk = "/"; }; }
        { search = { provider = "duckduckgo"; target = "_blank"; }; }
      ];
    };

    services = mkOption {
      type = types.listOf types.anything;
      default = [ ];
      description = ''
        Additional services to add directly (merged with contributions).
        Use contributions pattern for service modules; use this for static entries.
      '';
    };

    docker = mkOption {
      type = types.nullOr (types.attrsOf types.anything);
      default = null;
      description = "Docker integration configuration for container status";
      example = {
        host = "unix:///var/run/podman/podman.sock";
      };
    };

    # =========================================================================
    # Environment and Secrets
    # =========================================================================

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to environment file containing secrets for widget API keys.
        Use HOMEPAGE_VAR_* prefix for variables to be substituted in config.

        Example file content:
          HOMEPAGE_VAR_SONARR_API_KEY=abc123...
          HOMEPAGE_VAR_RADARR_API_KEY=def456...
      '';
    };

    # =========================================================================
    # Standard Integration Submodules
    # =========================================================================

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Homepage web interface";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = ''
        Backup configuration for Homepage data.
        Homepage stores minimal state (bookmarks, custom CSS/JS) in /var/lib/homepage-dashboard.
        With declarative NixOS config, backups are optional but recommended for custom changes.
      '';
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "infrastructure-alerts" ];
        };
        customMessages = {
          failure = "Homepage dashboard failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Homepage service events";
    };
  };

  # ===========================================================================
  # Implementation
  # ===========================================================================

  config = mkIf cfg.enable {
    # -------------------------------------------------------------------------
    # Native NixOS Homepage Service
    # -------------------------------------------------------------------------

    services.homepage-dashboard = {
      enable = true;

      # Port configuration
      listenPort = cfg.port;

      # Allow requests from the configured reverse proxy hostname and localhost
      allowedHosts =
        let
          localhostHosts = "localhost:${toString cfg.port},127.0.0.1:${toString cfg.port}";
          proxyHost = if (cfg.reverseProxy != null && cfg.reverseProxy.enable)
            then ",${cfg.reverseProxy.hostName}"
            else "";
        in
        localhostHosts + proxyHost;

      # Merge direct settings with defaults
      settings = cfg.settings;

      # Merge contributed services with direct services
      services = cfg.services ++ (contributionsToServices enabledContributions);

      # Direct passthrough
      bookmarks = cfg.bookmarks;
      widgets = cfg.widgets;

      # Docker integration for container status (if configured)
      docker = cfg.docker;

      # Environment file for secrets (only set if configured)
    } // lib.optionalAttrs (cfg.environmentFile != null) {
      environmentFile = cfg.environmentFile;
    };

    # -------------------------------------------------------------------------
    # Reverse Proxy Integration (Caddy)
    # -------------------------------------------------------------------------

    modules.services.caddy.virtualHosts.homepage = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;

      backend = {
        host = "127.0.0.1";
        port = cfg.port;
        scheme = "http";
      };

      # Security/authentication from reverseProxy config
      caddySecurity = cfg.reverseProxy.caddySecurity or null;

      # Extra Caddy configuration
      extraConfig = cfg.reverseProxy.extraConfig or "";
    };

    # -------------------------------------------------------------------------
    # Systemd Service Hardening & Dependencies
    # -------------------------------------------------------------------------

    systemd.services.homepage-dashboard = {
      # Add notification on failure if centralized notifications enabled
      unitConfig = mkIf (
        (config.modules.notifications.enable or false) &&
        cfg.notifications != null &&
        cfg.notifications.enable
      ) {
        OnFailure = [ "notify@homepage-failure:%n.service" ];
      };

      # Homepage is lightweight; minimal hardening needed
      serviceConfig = {
        # Ensure clean shutdown
        TimeoutStopSec = 30;
      };
    };

    # -------------------------------------------------------------------------
    # Notification Template
    # -------------------------------------------------------------------------

    modules.notifications.templates = mkIf (
      (config.modules.notifications.enable or false) &&
      cfg.notifications != null &&
      cfg.notifications.enable
    ) {
      "homepage-failure" = {
        enable = lib.mkDefault true;
        priority = lib.mkDefault "high";
        title = lib.mkDefault ''<b><font color="red">✗ Service Failed: Homepage</font></b>'';
        body = lib.mkDefault ''
          <b>Host:</b> ''${hostname}
          <b>Service:</b> <code>''${serviceName}</code>

          The Homepage dashboard service has entered a failed state.

          <b>Quick Actions:</b>
          1. Check logs:
             <code>ssh ''${hostname} 'journalctl -u homepage-dashboard -n 100'</code>
          2. Restart service:
             <code>ssh ''${hostname} 'systemctl restart homepage-dashboard'</code>
        '';
      };
    };

    # -------------------------------------------------------------------------
    # Firewall (localhost only - reverse proxy handles external)
    # -------------------------------------------------------------------------

    # Homepage listens on configured port (default 3003)
    # No firewall ports needed - Caddy proxies from external
  };
}
