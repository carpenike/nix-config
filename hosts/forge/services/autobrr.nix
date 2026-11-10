# hosts/forge/services/autobrr.nix
#
# Host-specific configuration for Autobrr on 'forge'.
# Autobrr is an IRC announce bot for torrent automation.

{ config, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.autobrr.enable or false;
  inherit (config.networking) domain;
  # Host port published by the container. settings.port is what autobrr binds
  # inside the container; the factory maps this port to the same number.
  ircHealthUrl = "http://127.0.0.1:${toString config.modules.services.autobrr.port}/api/irc";
  ircHealthMetricsFile = "${config.modules.monitoring.nodeExporter.textfileCollector.directory}/autobrr_irc.prom";
  ircHealthPackage = pkgs.runCommand "autobrr-irc-health"
    {
      nativeBuildInputs = [ pkgs.python3 pkgs.ruff pkgs.prometheus.cli ];
    } ''
    mkdir -p source/autobrr
    touch source/autobrr/__init__.py
    cp ${./autobrr/irc_health.py} source/autobrr/irc_health.py
    cp ${./autobrr/test_irc_health.py} source/autobrr/test_irc_health.py
    ruff check source/autobrr
    ruff format --check source/autobrr
    cd source
    python3 -m unittest -v autobrr.test_irc_health
    install -Dm755 autobrr/irc_health.py "$out/bin/autobrr-irc-health"
    patchShebangs "$out/bin/autobrr-irc-health"
  '';
in
{
  config = lib.mkMerge [
    {
      modules.services.autobrr = {
        enable = true;
        podmanNetwork = forgeDefaults.podmanNetwork;
        healthcheck.enable = true;

        # Hairpin-NAT workaround: id.holthome.net resolves to forge's LAN IP
        # (10.20.0.30), but autobrr's podman bridge can't reach the LAN — so
        # OIDC discovery (https://id.holthome.net/.well-known/openid-configuration)
        # times out from inside the container. Override the hosts file to point
        # at the podman bridge IP where Caddy also listens. Same pattern as qui.
        extraHosts = {
          "id.${domain}" = "10.89.0.1";
        };

        settings = {
          host = "0.0.0.0";
          port = 7474;
          logLevel = "INFO";
          checkForUpdates = false; # Managed via Nix/Renovate
          sessionSecretFile = config.sops.secrets."autobrr/session-secret".path;
        };

        # Native PocketID OIDC integration
        oidc = {
          enable = true;
          issuer = "https://id.${config.networking.domain}";
          clientId = "autobrr";
          clientSecretFile = config.sops.secrets."autobrr/oidc-client-secret".path;
          redirectUrl = "https://autobrr.${config.networking.domain}/api/auth/oidc/callback";
          disableBuiltInLogin = false;
        };

        # Prometheus metrics
        metrics = {
          enable = true;
          host = "0.0.0.0";
          port = 9084; # qui uses 9074, so use 9084 for autobrr
        };

        # Config generator with SOPS secrets injection
        configGenerator.environmentFile = config.sops.templates."autobrr-env".path;

        reverseProxy = {
          enable = true;
          hostName = "autobrr.holthome.net";
        };

        backup = forgeDefaults.mkBackupWithSnapshots "autobrr";

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.autobrr.protection = {
        class = "standard";
        objectives = {
          onsiteRpoSeconds = 86400;
          offsiteRpoSeconds = null;
          rtoSeconds = 28800;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = "autobrr-state";
        allowEmptyBootstrap = false;
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets."tank/services/autobrr" = forgeDefaults.mkSanoidDataset "autobrr";

      # Service availability alert
      modules.alerting.rules."autobrr-service-down" =
        forgeDefaults.mkServiceDownAlert "autobrr" "Autobrr" "IRC announce bot";

      # autobrr v1.89.0 /metrics does not export per-network or per-channel
      # health. healthy/connected/enabled are process-wide totals, and the
      # channel series are per-network counts with no channel label. The only
      # series that names a channel is the last-announce timestamp, which is
      # omitted until that channel has announced — the missed-invite case.
      # Forge also does not scrape :9084. Read GET /api/irc instead (same
      # health object as the UI) and let node_exporter pick up the textfile.
      assertions = [{
        assertion = config.modules.monitoring.nodeExporter.textfileCollector.enable;
        message = "autobrr IRC health export needs the node exporter textfile collector";
      }];

      systemd.services.autobrr-irc-health = {
        description = "Export autobrr IRC network health for Prometheus";
        after = [
          "network-online.target"
          "podman-autobrr.service"
          "sops-install-secrets.service"
        ];
        wants = [ "network-online.target" "podman-autobrr.service" ];
        requires = [ "sops-install-secrets.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "node-exporter";
          Group = "node-exporter";
          LoadCredential = [
            "api_token:${config.sops.secrets."autobrr/api-key".path}"
          ];
          TimeoutStartSec = "30s";
          UMask = "0022";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ config.modules.monitoring.nodeExporter.textfileCollector.directory ];
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
        };
        # Exit 0 even when the API read fails: the textfile records
        # scrape_success=0, and a failed oneshot would also page via
        # SystemdUnitFailed (high) on every autobrr restart.
        script = ''
          exec ${ircHealthPackage}/bin/autobrr-irc-health \
            --url ${lib.escapeShellArg ircHealthUrl} \
            --token-file "$CREDENTIALS_DIRECTORY/api_token" \
            --metrics-file ${lib.escapeShellArg ircHealthMetricsFile}
        '';
      };

      systemd.timers.autobrr-irc-health = {
        description = "Collect autobrr IRC health every minute";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          AccuracySec = "10s";
          RandomizedDelaySec = "5s";
          Persistent = true;
          Unit = "autobrr-irc-health.service";
        };
      };

      # medium is this repo's warning tier (below high/critical).
      # 1h covers normal reconnects and invite retries without waiting out
      # a multi-day stuck join.
      modules.alerting.rules."autobrr-irc-channel-unmonitored" = {
        type = "promql";
        alertname = "AutobrrIrcChannelUnmonitored";
        expr = "autobrr_irc_channel_monitoring == 0";
        for = "1h";
        severity = "medium";
        labels = {
          service = "autobrr";
          category = "availability";
        };
        annotations = {
          summary = "autobrr is not monitoring {{ $labels.channel }} on {{ $labels.network }}";
          description = "Enabled channel {{ $labels.channel }} on IRC network {{ $labels.network }} has been disconnected or not joined for 1h. autobrr can stay connected while a missed invite leaves the announce channel unmonitored. Restart that network in autobrr. Disabled networks are not exported.";
        };
      };

      modules.alerting.rules."autobrr-irc-network-unhealthy" = {
        type = "promql";
        alertname = "AutobrrIrcNetworkUnhealthy";
        expr = ''
          (
            autobrr_irc_network_connected == 0
            or autobrr_irc_network_healthy == 0
          )
          unless on (network) (autobrr_irc_channel_monitoring == 0)
        '';
        for = "1h";
        severity = "medium";
        labels = {
          service = "autobrr";
          category = "availability";
        };
        annotations = {
          summary = "autobrr IRC network {{ $labels.network }} is unhealthy";
          description = "{{ $labels.network }} has been unhealthy for 1h and none of its enabled channels are reporting as unmonitored. It may be disconnected with no enabled channels, or connected with errors while channels still look joined. Restart the network in autobrr.";
        };
      };

      modules.alerting.rules."autobrr-irc-health-scrape-failed" = {
        type = "promql";
        alertname = "AutobrrIrcHealthScrapeFailed";
        expr = "autobrr_irc_health_scrape_success == 0";
        for = "15m";
        severity = "medium";
        labels = {
          service = "autobrr";
          category = "monitoring";
        };
        annotations = {
          summary = "autobrr IRC health check cannot read the API";
          description = "GET /api/irc has been failing for 15m, so channel alerts are blind. Check the autobrr/api-key secret and journalctl -u autobrr-irc-health.service.";
        };
      };

      modules.alerting.rules."autobrr-irc-health-stale" = {
        type = "promql";
        alertname = "AutobrrIrcHealthStale";
        expr = ''
          (time() - autobrr_irc_health_last_scrape_timestamp_seconds > 300)
          or absent(autobrr_irc_health_last_scrape_timestamp_seconds)
        '';
        for = "10m";
        severity = "medium";
        labels = {
          service = "autobrr";
          category = "monitoring";
        };
        annotations = {
          summary = "autobrr IRC health metrics are stale";
          description = "No autobrr IRC health collection has been recorded for over 5 minutes. Check systemctl status autobrr-irc-health.timer.";
        };
      };

      # Homepage dashboard contribution
      modules.services.homepage.contributions.autobrr = {
        group = "Downloads";
        name = "Autobrr";
        icon = "autobrr";
        href = "https://autobrr.holthome.net";
        description = "IRC announce bot";
        siteMonitor = "http://localhost:7474";
        widget = {
          type = "autobrr";
          url = "http://localhost:7474";
          key = "{{HOMEPAGE_VAR_AUTOBRR_API_KEY}}";
        };
      };
    })
  ];
}
