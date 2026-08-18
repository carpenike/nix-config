# hosts/forge/services/actual.nix
#
# Host-specific configuration for Actual Budget on 'forge'.
# This module consumes the reusable abstraction defined in:
# modules/nixos/services/actual/default.nix
#
# Actual Budget is a privacy-focused personal finance app.
# Uses native OIDC via PocketID for authentication.
# Internal only - no Cloudflare Tunnel (finance data is sensitive).

{ config, inputs, lib, pkgs, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.actual.enable or false;

  # Service configuration values - single source of truth
  serviceName = "actual";
  dataDir = "/var/lib/actual";
  dataset = "tank/services/${serviceName}";
  port = 5006; # Actual Budget default port
  hostName = "budget.${config.networking.domain}";
  externalUrl = "https://${hostName}";
  internalUrl = "http://127.0.0.1:${toString port}";
in
{
  config = lib.mkMerge [
    {
      modules.services.actual = {
        enable = true;
        # WORKAROUND (2026-07-30): Pin 26.7 because 26.7 API clients upgraded
        # the budget schema, which the stable 26.6 web client cannot open.
        # Affects: Actual Budget web UI and API client compatibility
        # Upstream: https://github.com/actualbudget/actual/pull/8026
        # Check: Return to pkgs.actual-server when nixos-25.11 provides Actual
        # >= 26.7.0. See docs/workarounds.md.
        package = inputs.actual-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.actual-server;
        port = port;

        # OpenID remains primary for people; password supports headless API clients.
        allowedLoginMethods = [
          "password"
          "openid"
        ];

        # Native OIDC authentication via PocketID
        oidc = {
          enable = true;
          enforce = false;
          discoveryUrl = "https://id.holthome.net/.well-known/openid-configuration";
          clientId = "actual-budget";
          clientSecretFile = config.sops.secrets."actual/oidc-client-secret".path;
          serverHostname = externalUrl;
          # authMethod = "openid"; # Use "oauth2" if you get openid-grant-failed errors
        };

        # Reverse proxy configuration for external access via Caddy
        # No caddySecurity needed - using native OIDC
        reverseProxy = {
          enable = true;
          hostName = hostName;
          backend = {
            host = "127.0.0.1";
            port = port;
          };
        };

        # Backup configuration
        backup = forgeDefaults.mkBackupWithSnapshots "actual";

        # Enable failure notifications
        notifications.enable = true;

        # Enable self-healing restore from backups
        preseed = forgeDefaults.preseed;
      };
    }

    (lib.mkIf serviceEnabled {
      # ZFS dataset for Actual data
      # Must set owner/group/mode explicitly - StateDirectory can't change
      # permissions on pre-existing ZFS mountpoints
      modules.storage.datasets.services.${serviceName} = {
        mountpoint = dataDir;
        recordsize = "16K"; # SQLite database workload
        compression = "lz4";
        owner = config.modules.services.actual.user;
        group = config.modules.services.actual.group;
        mode = "0750";
        protection = {
          class = "critical";
          objectives = {
            onsiteRpoSeconds = 900;
            offsiteRpoSeconds = 86400;
            rtoSeconds = 7200;
          };
          requiredTiers = [
            "local-snapshot"
            "replication"
            "nas-backup"
            "offsite-backup"
            "automated-restore"
          ];
          consistency = "crash-consistent";
          validator = "actual-sqlite-integrity";
          allowEmptyBootstrap = false;
        };
      };

      # ZFS snapshot and replication configuration
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset serviceName;

      # Offsite copy to R2, on top of the NAS backup that
      # `mkBackupWithSnapshots` above already configures. This is what
      # satisfies the "offsite-backup" tier declared below.
      #
      # The ledger is the household's only record of its own finances and is
      # not reconstructible from anywhere else: the bank feeds carry a rolling
      # window, not history, and every categorisation, payee merge, rule and
      # reconciliation is hand-made. Onsite tiers all share one failure domain
      # (forge and nas-1 sit in the same house), so a fire or a theft takes
      # the snapshots, the replica and the NAS backup together.
      #
      # Small enough for this to be cheap — the budget is a single SQLite
      # database of a few tens of MB — and it uses the same snapshot-clone
      # read path as the NAS job, so it captures a consistent image rather
      # than a live database mid-write.
      modules.services.backup.restic.jobs."${serviceName}-offsite" = {
        enable = true;
        repository = "r2-offsite";
        paths = [ dataDir ];
        tags = [ serviceName "sqlite" "finances" "offsite" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      # Service-down alert using forgeDefaults helper (native systemd service)
      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert serviceName "Actual" "personal finance";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.${serviceName} = {
        group = "Home";
        name = "Actual Budget";
        icon = "actual-budget";
        href = externalUrl;
        description = "Personal finance";
        siteMonitor = internalUrl;
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.${serviceName} = {
        name = "Actual Budget";
        group = "Home";
        url = externalUrl;
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 1000"
        ];
      };
    })
  ];
}
