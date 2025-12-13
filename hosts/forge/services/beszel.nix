{ config, lib, ... }:
# Beszel Configuration for forge
#
# Beszel provides lightweight server monitoring with:
# - Docker/Podman container stats
# - Historical data with configurable retention
# - Configurable alerts (CPU, memory, disk, bandwidth, temperature)
# - Multi-user support with OAuth/OIDC via Pocket ID
#
# ARCHITECTURE:
# - Native NixOS service (wrapped with homelab patterns)
# - Hub: Web dashboard on port 8096 (PocketBase-based)
# - Agent: Local monitoring agent on port 45876
# - Internal-only access (no Cloudflare Tunnel)
#
# POST-DEPLOYMENT SETUP:
# 1. Access /_/#/settings to configure OIDC with Pocket ID
# 2. Create OIDC client in Pocket ID with callback: https://monitor.holthome.net/api/oauth2-redirect
# 3. In PocketBase: Collections > Users > Options > OAuth2 > Add oidc provider
# 4. See: https://pocket-id.org/docs/client-examples/beszel
#
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  hubEnabled = config.modules.services.beszel.hub.enable or false;
  agentEnabled = config.modules.services.beszel.agent.enable or false;
  serviceDomain = "monitor.${config.networking.domain}";
  hubPort = 8096;
in
{
  config = lib.mkMerge [
    {
      # ========================================================================
      # Hub Configuration
      # ========================================================================
      modules.services.beszel.hub = {
        enable = true;

        # Use port 8096 (8090 used by Gatus, 8095 by Termix)
        port = hubPort;

        # OIDC configuration (actual setup in PocketBase UI after first boot)
        oidc = {
          enable = true;
          disablePasswordAuth = false; # Keep password auth until OIDC is configured
          userCreation = true; # Allow new users via OIDC
        };

        # Reverse proxy via Caddy (internal only)
        # NOTE: No caddySecurity - Beszel handles auth natively via PocketBase OIDC
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = hubPort;
          };
        };

        # Prometheus metrics (Beszel exposes metrics at /api/metrics)
        metrics = {
          enable = true;
          port = hubPort;
          path = "/api/metrics";
          labels = {
            service = "beszel";
            service_type = "monitoring";
            function = "server_monitoring";
          };
        };

        # Backup using forgeDefaults helper with monitoring tags
        backup = forgeDefaults.mkBackupWithTags "beszel" (forgeDefaults.backupTags.monitoring ++ [ "beszel" "pocketbase" ]);

        # Enable self-healing restore from backups
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };

      # ========================================================================
      # Agent Configuration (monitor forge itself)
      # ========================================================================
      modules.services.beszel.agent = {
        enable = true;

        # Default port 45876
        port = 45876;

        # Key will be configured after hub setup via SOPS
        # The hub provides the key when adding a new system
        keyFile = config.sops.secrets."beszel/agent-key".path;

        # Configure for Podman container monitoring
        environment = {
          # Use Podman socket for container stats
          DOCKER_HOST = "unix:///run/podman/podman.sock";
        };
      };
    }

    # Infrastructure contributions (guarded by service enable)
    (lib.mkIf hubEnabled {
      # ZFS dataset for hub data (PocketBase/SQLite)
      modules.storage.datasets.services.beszel = {
        mountpoint = "/var/lib/beszel";
        recordsize = "16K"; # Optimal for SQLite/PocketBase
        compression = "zstd";
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/beszel" =
        forgeDefaults.mkSanoidDataset "beszel";

      # Service-down alert for hub
      modules.alerting.rules."beszel-hub-down" =
        forgeDefaults.mkSystemdServiceDownAlert "beszel" "BeszelHub" "server monitoring hub";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.beszel = {
        group = "Monitoring";
        name = "Beszel";
        icon = "beszel";
        href = "https://${serviceDomain}";
        description = "Server monitoring dashboard";
        siteMonitor = "http://localhost:${toString hubPort}";
      };

      # Gatus black-box monitoring contribution
      modules.services.gatus.contributions.beszel = {
        name = "Beszel";
        group = "Monitoring";
        url = "https://${serviceDomain}";
        interval = "60s";
        conditions = [ "[STATUS] == 200" ];
      };
    })

    (lib.mkIf agentEnabled {
      # Service-down alert for agent
      modules.alerting.rules."beszel-agent-down" =
        forgeDefaults.mkSystemdServiceDownAlert "beszel-agent" "BeszelAgent" "server monitoring agent";
    })
  ];
}
