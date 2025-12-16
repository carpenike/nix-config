# hosts/forge/services/n8n.nix
#
# Host-specific configuration for the n8n workflow automation service on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/n8n/default.nix
#
# ARCHITECTURE:
# - Native NixOS service (wrapped with homelab patterns)
# - SQLite storage on ZFS for persistence
# - LAN-only access (not exposed via Cloudflare Tunnel)
# - n8n's built-in authentication is sufficient (no SSO needed)
# - Community nodes enabled for extended functionality
#
# Retains all homelab integrations: ZFS, backups, preseed, monitoring, Caddy reverse proxy.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.n8n.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.n8n = {
        # FIXME: Temporarily disabled - n8n 1.122.5 in nixpkgs-unstable has broken build
        # The n8n-editor-ui package fails to build due to vite/rolldown compatibility issues
        # Re-enable once upstream nixpkgs fixes the package
        # Tracking: https://github.com/NixOS/nixpkgs/issues/n8n
        enable = false;

        # Core settings
        host = "n8n.holthome.net";
        timezone = "America/New_York";

        # Encryption key environment file (SOPS managed)
        # Format: N8N_ENCRYPTION_KEY=<hex-key>
        encryptionKeyFile = config.sops.secrets."n8n/encryption_key_env".path;

        # Community nodes enabled (per user request)
        communityNodesEnabled = true;

        # Disable telemetry and version notifications
        diagnosticsEnabled = false;
        versionNotificationsEnabled = false;

        # Reverse proxy integration via Caddy (LAN-only, no SSO needed)
        # n8n has mandatory built-in authentication, so caddySecurity is redundant
        reverseProxy = {
          enable = true;
          hostName = "n8n.holthome.net";
          backend = {
            host = "127.0.0.1";
            port = 5678;
          };
          # No caddySecurity - n8n enforces its own authentication
          # and this service is LAN-only (not exposed via Cloudflare Tunnel)
        };

        # Backup using forgeDefaults helper with automation tags
        backup = forgeDefaults.mkBackupWithTags "n8n" [ "automation" "workflows" "n8n" "forge" ];

        # Enable self-healing restore from backups
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf serviceEnabled {
      # ZFS dataset for service data
      modules.storage.datasets.services.n8n = {
        mountpoint = "/var/lib/n8n";
        recordsize = "16K"; # Optimal for SQLite database
        compression = "lz4";
        owner = "n8n";
        group = "n8n";
        mode = "0750";
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/n8n" =
        forgeDefaults.mkSanoidDataset "n8n";

      # Service-down alert using forgeDefaults helper (native systemd service)
      modules.alerting.rules."n8n-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "n8n" "N8N" "workflow automation";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.n8n = {
        group = "Automation";
        name = "n8n";
        icon = "n8n";
        href = "https://n8n.holthome.net";
        description = "Workflow automation";
        siteMonitor = "http://localhost:5678";
      };

      # Gatus black-box monitoring contribution
      modules.services.gatus.contributions.n8n = {
        name = "n8n";
        group = "Automation";
        url = "https://n8n.holthome.net";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
        ];
      };
    })
  ];
}
