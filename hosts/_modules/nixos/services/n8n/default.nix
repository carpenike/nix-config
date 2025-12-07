# n8n workflow automation service module
#
# This module wraps the native NixOS n8n service with homelab-specific patterns:
# - ZFS storage integration for SQLite persistence
# - Caddy reverse proxy with PocketID SSO
# - Preseed/DR capability
# - Standard backup and alerting integrations
# - Community nodes support
#
# n8n does NOT support OIDC login or trusted header auth, so we use dual-layer:
# - Outer gate: caddySecurity (PocketID SSO)
# - Inner gate: Single admin account in n8n
#
# Architecture Decision: Native NixOS module wrapper preferred over container.
# Using pkgs.unstable.n8n for latest version.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.services.n8n;
  serviceName = "n8n";

  # Import shared types for standard submodules
  sharedTypes = import ../../../lib/types.nix { inherit lib; };
in
{
  options.modules.services.n8n = {
    enable = lib.mkEnableOption "n8n workflow automation service";

    # Core configuration
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/n8n";
      description = "Directory for n8n data (SQLite database, workflows, credentials)";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5678;
      description = "Port for n8n web interface";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "n8n.holthome.net";
      description = "Public hostname for n8n (used for webhook URLs)";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/New_York";
      description = "Timezone for n8n scheduling (important for cron nodes)";
    };

    # Secrets
    encryptionKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to environment file containing N8N_ENCRYPTION_KEY.
        This key encrypts stored credentials - MUST be backed up!

        File format (single line):
          N8N_ENCRYPTION_KEY=<your-hex-key>

        Generate key with: openssl rand -hex 32
        Then create file with: echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" > /path/to/file
      '';
    };

    # Community nodes
    communityNodesEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow installation of community-created nodes";
    };

    # Telemetry
    diagnosticsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable anonymous telemetry (required for Ask AI in Code node)";
    };

    # Version notifications
    versionNotificationsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Show notifications about new n8n versions";
    };

    # Standardized integrations
    reverseProxy = lib.mkOption {
      type = lib.types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Reverse proxy configuration for n8n web interface";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr sharedTypes.backupSubmodule;
      default = null;
      description = "Backup configuration for n8n data";
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr sharedTypes.notificationSubmodule;
      default = null;
      description = "Notification configuration for service events";
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

    # Extra environment variables
    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables to pass to n8n";
      example = {
        N8N_SMTP_HOST = "smtp.example.com";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Use native NixOS n8n service with unstable package for latest version
    services.n8n = {
      enable = true;

      # Environment configuration
      # NOTE: N8N_USER_FOLDER is set by the native module based on StateDirectory
      # We don't override it here to avoid read-only option conflicts
      environment = {
        # Core settings
        N8N_PORT = toString cfg.port;
        N8N_HOST = cfg.host;
        N8N_PROTOCOL = "https";
        N8N_EDITOR_BASE_URL = "https://${cfg.host}";
        WEBHOOK_URL = "https://${cfg.host}";

        # Timezone
        GENERIC_TIMEZONE = cfg.timezone;

        # Community nodes
        N8N_COMMUNITY_PACKAGES_ENABLED = if cfg.communityNodesEnabled then "true" else "false";

        # Telemetry and notifications (must be string "true"/"false")
        N8N_DIAGNOSTICS_ENABLED = if cfg.diagnosticsEnabled then "true" else "false";
        N8N_VERSION_NOTIFICATIONS_ENABLED = if cfg.versionNotificationsEnabled then "true" else "false";
      } // cfg.extraEnvironment;
    };

    # Override systemd service for ZFS integration, secrets, and custom user
    # NOTE: The native NixOS n8n module already includes security hardening
    # (NoNewPrivileges, PrivateTmp, ProtectSystem, etc.), so we only add:
    # - ZFS dependencies
    # - Unstable package
    # - Override DynamicUser for stable UID
    # - EnvironmentFile for encryption key
    systemd.services.n8n = {
      # Wait for ZFS datasets
      after = [ "local-fs.target" "zfs-mount.service" ];
      wants = [ "zfs-mount.service" ];

      # Use unstable package for latest version
      path = [ pkgs.unstable.n8n ];

      serviceConfig = {
        # Override DynamicUser for persistent storage with stable UID
        DynamicUser = lib.mkForce false;
        User = serviceName;
        Group = serviceName;

        # State directory (we manage via ZFS instead)
        StateDirectory = lib.mkForce "";

        # Add our data dir to ReadWritePaths (appends to native module's paths)
        ReadWritePaths = [ cfg.dataDir ];

        # Resource limits
        MemoryMax = "1G";
        MemoryHigh = "768M";

        # Load encryption key from environment file
        # The file should contain: N8N_ENCRYPTION_KEY=<key>
        EnvironmentFile = lib.mkIf (cfg.encryptionKeyFile != null) cfg.encryptionKeyFile;
      };

      # Create .n8n directory before n8n starts (n8n expects this to exist)
      preStart = ''
        # Create .n8n directory if needed (n8n expects this)
        mkdir -p ${cfg.dataDir}/.n8n
        chown ${serviceName}:${serviceName} ${cfg.dataDir}/.n8n
        chmod 0750 ${cfg.dataDir}/.n8n
      '';
    };

    # Create n8n user/group with stable UID
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      home = lib.mkForce "/var/empty";
      description = "n8n workflow automation service user";
    };

    users.groups.${serviceName} = { };

    # Ensure data directory and .n8n subdirectory exist with correct permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${serviceName} ${serviceName} - -"
      "d ${cfg.dataDir}/.n8n 0750 ${serviceName} ${serviceName} - -"
    ];

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
      paths = if cfg.backup.paths != [ ] then cfg.backup.paths else [ cfg.dataDir ];
      repository = cfg.backup.repository;
      tags = cfg.backup.tags or [ "automation" serviceName "sqlite" ];
      useSnapshots = cfg.backup.useSnapshots or true;
      zfsDataset = cfg.backup.zfsDataset or null;
    };

    # Firewall - only allow localhost access (behind reverse proxy)
    networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ];
  };
}
