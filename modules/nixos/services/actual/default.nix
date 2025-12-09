# Actual Budget service module
#
# Native NixOS service wrapper with homelab patterns:
# - ZFS storage integration for budget data
# - Caddy reverse proxy with PocketID OIDC authentication
# - Standard backup/preseed/monitoring integrations
#
# Architecture Decision: Uses native services.actual from nixpkgs,
# wrapped with homelab patterns (ZFS, backup, preseed, monitoring).
#
# Authentication: Actual Budget supports native OpenID Connect.
# This module configures OIDC via PocketID for SSO.
# See: https://actualbudget.org/docs/config/oauth-auth/
#
{ config, lib, mylib, ... }:

let
  cfg = config.modules.services.actual;
  serviceName = "actual";

  # Import shared types for standard submodules
  sharedTypes = mylib.types;

in
{
  options.modules.services.actual = {
    enable = lib.mkEnableOption "Actual Budget personal finance app";

    user = lib.mkOption {
      type = lib.types.str;
      default = serviceName;
      description = "User account under which Actual runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = serviceName;
      description = "Group under which Actual runs";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 932;
      description = "UID for Actual service user (stable for ZFS)";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 932;
      description = "GID for Actual service group (stable for ZFS)";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/actual";
      description = "Path to Actual data directory";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5006;
      description = "Port for Actual web interface";
    };

    # =========================================================================
    # OpenID Connect Configuration
    # =========================================================================

    oidc = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "OpenID Connect authentication";

          discoveryUrl = lib.mkOption {
            type = lib.types.str;
            description = "OpenID Connect discovery URL";
            example = "https://id.holthome.net/.well-known/openid-configuration";
          };

          clientId = lib.mkOption {
            type = lib.types.str;
            description = "OAuth2 client ID from your identity provider";
            example = "actual-budget";
          };

          clientSecretFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to file containing the OAuth2 client secret";
            example = "/run/secrets/actual-oidc-secret";
          };

          serverHostname = lib.mkOption {
            type = lib.types.str;
            description = "Public URL of Actual server (for OIDC redirect)";
            example = "https://budget.holthome.net";
          };

          authMethod = lib.mkOption {
            type = lib.types.enum [ "openid" "oauth2" ];
            default = "openid";
            description = ''
              Authentication method to use. Use 'openid' for standard OIDC providers.
              Use 'oauth2' for providers like GitHub or if you get 'openid-grant-failed' errors.
              Some providers (like Authelia with certain configs) may require 'oauth2'.
            '';
          };
        };
      };
      default = { };
      description = "OpenID Connect configuration for Actual Budget";
    };

    # =========================================================================
    # Standard Integration Submodules
    # =========================================================================

    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for Actual web interface";
    };

    metrics = lib.mkOption {
      type = lib.types.nullOr sharedTypes.metricsSubmodule;
      default = {
        enable = true;
        port = cfg.port;
        path = "/";
        labels = {
          service = serviceName;
          service_type = "finance";
          function = "budget_management";
        };
      };
      description = "Prometheus metrics configuration (Actual doesn't have native metrics, used for auto-discovery)";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for Actual data";
    };

    # Standardized notifications
    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels = {
          onFailure = [ "admin-alerts" ];
        };
        customMessages = {
          failure = "Actual Budget failed on ${config.networking.hostName}";
        };
      };
      description = "Notification configuration for Actual service events";
    };

    # Preseed/DR capability
    preseed = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "automatic restore before service start";

          repositoryUrl = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "URL to Restic repository for preseed restore";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing Restic repository password";
          };

          restoreMethods = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "syncoid" "local" "restic" ]);
            default = [ "syncoid" "local" ];
            description = "Ordered list of restore methods to attempt";
          };
        };
      };
      default = { };
      description = "Preseed/DR restore configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Use native NixOS Actual service
    services.actual = {
      enable = true;
      openFirewall = false; # We handle firewall ourselves

      settings = {
        hostname = "127.0.0.1"; # Only listen on localhost (behind reverse proxy)
        port = cfg.port;
      } // lib.optionalAttrs cfg.oidc.enable {
        # OIDC configuration via native settings format
        # The NixOS module supports _secret for secure file-based secrets
        loginMethod = "openid";
        openId = {
          discoveryURL = cfg.oidc.discoveryUrl;
          client_id = cfg.oidc.clientId;
          client_secret._secret = cfg.oidc.clientSecretFile;
          server_hostname = cfg.oidc.serverHostname;
          authMethod = cfg.oidc.authMethod; # 'openid' or 'oauth2' based on provider
        };
      };
    };

    # Override systemd service for ZFS integration and stable user
    systemd.services.actual = {
      # Wait for ZFS datasets
      after = [ "local-fs.target" "zfs-mount.service" ];
      wants = [ "zfs-mount.service" ];

      serviceConfig = {
        # Override DynamicUser for persistent storage with stable UID
        DynamicUser = lib.mkForce false;
        User = cfg.user;
        Group = cfg.group;

        # Explicit state/runtime directories with correct ownership
        # RuntimeDirectory is needed for config.json with expanded secrets
        StateDirectory = lib.mkForce serviceName;
        StateDirectoryMode = lib.mkForce "0750";
        RuntimeDirectory = lib.mkForce serviceName;
        RuntimeDirectoryMode = lib.mkForce "0750";

        # Working directory for data storage
        WorkingDirectory = cfg.dataDir;

        # Security hardening - allow reading secret files
        ReadWritePaths = [ cfg.dataDir "/run/${serviceName}" ];
      };
    };

    # Create actual user/group with stable UID/GID
    users.users.${cfg.user} = {
      isSystemUser = true;
      uid = cfg.uid;
      group = cfg.group;
      home = lib.mkForce "/var/empty";
      description = lib.mkForce "Actual Budget service user";
    };

    users.groups.${cfg.group} = {
      gid = cfg.gid;
    };

    # Caddy reverse proxy integration
    modules.services.caddy.virtualHosts.${serviceName} = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
      enable = true;
      hostName = cfg.reverseProxy.hostName;
      backend = cfg.reverseProxy.backend;
      caddySecurity = cfg.reverseProxy.caddySecurity or null;
      extraConfig = cfg.reverseProxy.extraConfig or "";
    };

    # Backup integration
    modules.backup.restic.jobs.${serviceName} = lib.mkIf (cfg.backup != null && cfg.backup.enable) {
      enable = true;
      paths = [ cfg.dataDir ];
      repository = cfg.backup.repository;
      tags = cfg.backup.tags or [ "finance" serviceName "budget" ];
      useSnapshots = cfg.backup.useSnapshots or true;
      zfsDataset = cfg.backup.zfsDataset or null;
    };

    # Firewall - only allow localhost access (internal service behind reverse proxy)
    networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ];
  };
}
