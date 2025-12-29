{ config, lib, pkgs, ... }:

let
  domain = config.networking.domain;
  pocketIdBase = "https://id.${domain}";
  grafanaUrl = "https://grafana.${domain}";
  logoutRedirect = lib.strings.escapeURL grafanaUrl;
  serviceEnabled = config.modules.services.grafana.enable or false;
  # Use the new unified backup system (modules.services.backup)
  resticEnabled =
    (config.modules.services.backup.enable or false)
    && (config.modules.services.backup.restic.enable or false);
  # Import forge defaults for standardized helpers
  forgeDefaults = import ../../lib/defaults.nix { inherit config lib; };

  # OnCall configuration
  oncallEnabled = config.modules.services.grafana-oncall.enable or false;
  oncallApiUrl = "http://127.0.0.1:8094"; # OnCall engine internal URL
  # Use podman bridge IP - Grafana is bound to 10.89.0.1, not localhost
  grafanaInternalUrl = "http://10.89.0.1:3000";
  # Podman bridge IP - accessible from both host and containers
  # Required for OnCall plugin: the grafanaUrl in plugin settings is used by both
  # the plugin backend (on host) and synced to the OnCall engine DB (in container)
  grafanaPodmanBridgeUrl = "http://10.89.0.1:3000";
in
{
  config = lib.mkMerge [
    {
      # Grafana observability dashboard and visualization platform
      # Configured directly on the individual module (not through observability meta-module)
      modules.services.grafana = {
        enable = true;

        # Bind to podman bridge IP only - accessible from host (Caddy) and containers (OnCall)
        # Not exposed on main network interface or future IoT VLAN
        listenAddress = "10.89.0.1";

        # Open firewall for container access (podman bridge interfaces)
        openFirewall = true;

        # ZFS dataset for persistence
        zfs = {
          dataset = "tank/services/grafana";
          properties = {
            compression = "zstd";
            atime = "off";
            "com.sun:auto-snapshot" = "true";
          };
        };

        # Reverse proxy configuration
        reverseProxy = {
          enable = true;
          hostName = "grafana.${domain}";
          backend = {
            scheme = "http";
            host = "10.89.0.1"; # Must match listenAddress (podman bridge)
            port = 3000;
          };
          # No Caddy auth - Grafana uses OIDC authentication instead
          auth = null;
        };

        # Admin credentials
        secrets = {
          adminUser = "admin";
          adminPasswordFile = config.sops.secrets."grafana/admin-password".path;
        };

        # OIDC authentication via Pocket ID
        oidc = {
          enable = true;
          clientId = "grafana";
          clientSecretFile = config.sops.secrets."grafana/oidc_client_secret".path;
          authUrl = "${pocketIdBase}/authorize";
          tokenUrl = "${pocketIdBase}/api/oidc/token";
          apiUrl = "${pocketIdBase}/api/oidc/userinfo";
          scopes = [ "openid" "profile" "email" "groups" ];
          roleAttributePath = "contains(groups[*], 'admins') && 'Admin' || 'Viewer'";
          allowSignUp = false;
          signoutRedirectUrl = "${pocketIdBase}/api/oidc/end-session?post_logout_redirect_uri=${logoutRedirect}";
        };

        # Auto-configure datasources
        autoConfigure = {
          loki = true;
          prometheus = true;
        };

        # Backup configuration
        backup = {
          enable = true;
          repository = "nas-primary";
          frequency = "daily";
          tags = [ "monitoring" "grafana" "dashboards" ];
          useSnapshots = true;
          zfsDataset = "tank/services/grafana";
          excludePatterns = [
            "**/sessions/*"
            "**/png/*"
            "**/csv/*"
            "**/pdf/*"
          ];
        };

        # Preseed for disaster recovery
        preseed = lib.mkIf resticEnabled {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          restoreMethods = [ "syncoid" "local" ];
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication configuration for Grafana dataset
      # Contributes to host-level Sanoid configuration following the contribution pattern
      modules.backup.sanoid.datasets."tank/services/grafana" = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          inherit (forgeDefaults.replication) targetHost sendOptions recvOptions hostKey targetName targetLocation;
          targetDataset = "backup/forge/zfs-recv/grafana";
        };
      };

      # Homepage dashboard contribution
      modules.services.homepage.contributions.grafana = {
        group = "Monitoring";
        name = "Grafana";
        icon = "grafana";
        href = grafanaUrl;
        description = "Metrics visualization and dashboards";
        siteMonitor = "http://127.0.0.1:3000";
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.grafana = {
        name = "Grafana";
        group = "Monitoring";
        url = grafanaUrl;
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };

      # Prometheus service-down alert
      modules.alerting.rules."grafana-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "grafana" "Grafana" "metrics visualization";

      # OnCall plugin auto-installation and configuration
      # Required for OnCall plugin's service account authentication (Grafana 11+)
      systemd.services.grafana.environment = lib.mkIf oncallEnabled {
        # Preinstall the OnCall plugin at Grafana startup
        GF_PLUGINS_PREINSTALL_SYNC = "grafana-oncall-app";
        # Enable feature toggle for external service accounts (required for OnCall plugin)
        GF_FEATURE_TOGGLES_ENABLE = "externalServiceAccounts";
        # Enable managed service accounts in auth config
        GF_AUTH_MANAGED_SERVICE_ACCOUNTS_ENABLED = "true";
      };

      # One-shot service to configure the OnCall plugin after Grafana starts
      systemd.services.grafana-oncall-plugin-setup = lib.mkIf oncallEnabled {
        description = "Configure Grafana OnCall plugin";
        after = [ "grafana.service" "podman-grafana-oncall-engine.service" ];
        wants = [ "grafana.service" ];
        requires = [ "grafana.service" ];
        wantedBy = [ "multi-user.target" ];

        # Wait for Grafana to be ready, then configure the plugin
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "30s";
        };

        path = [ pkgs.curl pkgs.coreutils ];

        script = ''
          set -euo pipefail

          GRAFANA_URL="${grafanaInternalUrl}"
          ONCALL_URL="${oncallApiUrl}"

          # Read admin password from sops secret
          ADMIN_PASSWORD=$(cat ${config.sops.secrets."grafana/admin-password".path})

          echo "Waiting for Grafana to be ready..."
          for i in $(seq 1 30); do
            if curl -sf "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
              echo "Grafana is ready"
              break
            fi
            echo "Waiting for Grafana... ($i/30)"
            sleep 2
          done

          echo "Waiting for OnCall engine to be ready..."
          for i in $(seq 1 30); do
            if curl -sf "$ONCALL_URL/health/" >/dev/null 2>&1; then
              echo "OnCall engine is ready"
              break
            fi
            echo "Waiting for OnCall engine... ($i/30)"
            sleep 2
          done

          # Check if plugin is already configured
          PLUGIN_STATUS=$(curl -sf -u "admin:$ADMIN_PASSWORD" "$GRAFANA_URL/api/plugins/grafana-oncall-app/settings" 2>/dev/null || echo '{"enabled":false}')
          if echo "$PLUGIN_STATUS" | grep -q '"enabled":true'; then
            echo "OnCall plugin already enabled, checking connection..."
            # Trigger a sync to ensure connection is working
            curl -sf -X POST -u "admin:$ADMIN_PASSWORD" "$GRAFANA_URL/api/plugins/grafana-oncall-app/resources/plugin/sync" || true
            exit 0
          fi

          echo "Enabling OnCall plugin..."
          # stackId=5, orgId=100 are the magic values for OSS/self-hosted OnCall
          # grafanaUrl uses Podman bridge IP (10.89.0.1) so it's accessible from both:
          # - Grafana plugin backend (on host)
          # - OnCall engine container (synced to its DB during install)
          curl -sf -X POST -u "admin:$ADMIN_PASSWORD" \
            -H "Content-Type: application/json" \
            "$GRAFANA_URL/api/plugins/grafana-oncall-app/settings" \
            -d '{
              "enabled": true,
              "jsonData": {
                "stackId": 5,
                "orgId": 100,
                "onCallApiUrl": "'"$ONCALL_URL"'",
                "grafanaUrl": "${grafanaPodmanBridgeUrl}"
              }
            }'

          echo "Installing OnCall plugin backend..."
          curl -sf -X POST -u "admin:$ADMIN_PASSWORD" \
            "$GRAFANA_URL/api/plugins/grafana-oncall-app/resources/plugin/install"

          echo "OnCall plugin configured successfully"
        '';
      };
    })
  ];
}
