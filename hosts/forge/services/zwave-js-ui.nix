# hosts/forge/services/zwave-js-ui.nix
#
# Z-Wave JS UI on 'forge'. Since 2026-11-25 it runs in the k8s cluster
# (carpenike/k8s-gitops ADR 0018, docs/apps/home-automation.md, "3. Z-Wave
# JS UI"), on the sled the USB stick moved to. The settings below stay as
# the record of what Forge ran and for rollback; the cluster runs on a copy
# of /var/lib/zwave-js-ui.
#
# Home Assistant is still on Forge and dials the WebSocket server on
# localhost:3002. `zwave-forward-cluster` keeps that address working: it
# listens on loopback only (the server has no authentication, so it is never
# on the LAN) and relays to the cluster LoadBalancer `zwave-js-ui-forge`
# (10.45.10.31), which accepts only Forge's address. Delete it when Home
# Assistant moves to the cluster.
#
# The dataset is kept as the rollback copy, still snapshotted, replicated and
# backed up under the same names (the block at the end, gated on the service
# being off). Only the `automated-restore` tier is dropped: it is the preseed
# unit, which has no service left to precede.
#
# Rollback: scale the cluster's zwave-js-ui to 0 and move the stick back,
# then set modules.services."zwave-js-ui".enable back to true and put
# "zwave-js-ui" back in containersByRestartSec."5" in
# core/systemd-restart-policy.nix and in failClosedUnits in flake.nix. After
# days in the cluster, copy the volume back first.

{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  dataset = "tank/services/zwave-js-ui";
  dataDir = "/var/lib/zwave-js-ui";
  controllerAddress = "/dev/serial/by-id/usb-0658_0200-if00";
  frontendDomain = "zwave.${domain}";
  serviceEnabled = config.modules.services."zwave-js-ui".enable or false;
  unstablePkgs = pkgs.unstable;
  # k8s-gitops kubernetes/apps/home-automation/zwave-js-ui/app/service-forge.yaml
  clusterServer = "10.45.10.31:3002";
in
{
  config = lib.mkMerge [
    {
      modules.services."zwave-js-ui" = {
        enable = false;
        dataDir = dataDir;
        package = unstablePkgs.zwave-js-ui;

        reverseProxy = {
          enable = true;
          hostName = frontendDomain;
          caddySecurity = {
            enable = true;
            portal = "pocketid";
            policy = "admins";
            claimRoles = [
              {
                claim = "groups";
                value = "admins";
                role = "admins";
              }
            ];
          };
        };

        ui = {
          listenAddress = "127.0.0.1";
          port = 8091;
        };

        serial.device = controllerAddress;

        zwave.serverPort = 3002;

        mqtt = {
          enable = true;
          baseTopic = "zwave";
          username = "zwave-js-ui";
          passwordFile = config.sops.secrets."zwave-js-ui/mqtt_password".path;
        };

        security = {
          sessionSecretFile = config.sops.secrets."zwave-js-ui/session_secret".path;
          s0LegacyKeyFile = config.sops.secrets."zwave-js-ui/s0_legacy_key".path;
          s2UnauthenticatedKeyFile = config.sops.secrets."zwave-js-ui/s2_unauthenticated_key".path;
          s2AuthenticatedKeyFile = config.sops.secrets."zwave-js-ui/s2_authenticated_key".path;
          s2AccessControlKeyFile = config.sops.secrets."zwave-js-ui/s2_access_control_key".path;
          s2LongRangeKeyFile = config.sops.secrets."zwave-js-ui/s2_long_range_key".path;
          s2LongRangeAccessControlKeyFile = config.sops.secrets."zwave-js-ui/s2_long_range_access_control_key".path;
        };

        backup = forgeDefaults.mkBackupWithTags "zwave-js-ui" [ "zwave" "automation" "forge" ];

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications = {
          enable = true;
          channels.onFailure = [ "critical-alerts" ];
          customMessages.failure = ''
            Z-Wave JS UI failed on ${config.networking.hostName}.
            Use `journalctl -u zwave-js-ui -n 200` for details.
          '';
        };
      };
    }

    (lib.mkIf serviceEnabled {
      modules.storage.datasets.services.zwave-js-ui.protection = {
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
        validator = "zwave-js-ui-state";
        allowEmptyBootstrap = false;
      };

      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "zwave-js-ui";

      modules.alerting.rules."zwave-js-ui-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "zwave-js-ui" "ZwaveJsUi" "Z-Wave device bridge";
    })

    (lib.mkIf (!serviceEnabled) {
      # Home Assistant on Forge -> cluster Z-Wave JS UI. Loopback only, both
      # address families, because "localhost" may resolve to either.
      systemd.services.zwave-forward-cluster = {
        description = "Forward localhost:3002 to the cluster Z-Wave JS UI";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        script = ''
          ${pkgs.socat}/bin/socat TCP4-LISTEN:3002,bind=127.0.0.1,fork,reuseaddr,keepalive TCP:${clusterServer},keepalive &
          ${pkgs.socat}/bin/socat TCP6-LISTEN:3002,bind=[::1],fork,reuseaddr,keepalive TCP:${clusterServer},keepalive &
          wait -n
        '';
        serviceConfig = {
          Restart = "always";
          RestartSec = 5;
          DynamicUser = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
          MemoryMax = "128M";
        };
      };

      modules.alerting.rules."zwave-forward-cluster-down" =
        forgeDefaults.mkSystemdServiceDownAlert "zwave-forward-cluster" "ZwaveForwardCluster" "Z-Wave WebSocket forwarder to the cluster";

      # Retention while the service runs in the cluster: the same dataset,
      # sanoid/syncoid and Restic job (`service-zwave-js-ui`, the name backup
      # discovery gave it) as when it ran here. The user keeps its uid from
      # /var/lib/nixos/uid-map.
      users.users."zwave-js-ui" = {
        isSystemUser = true;
        group = "zwave-js-ui";
        description = "Z-Wave JS UI user (moved to k8s; data owner)";
        home = "/var/empty";
      };
      users.groups."zwave-js-ui" = { };

      modules.storage.datasets.services.zwave-js-ui = {
        mountpoint = dataDir;
        recordsize = "16K";
        compression = "zstd";
        properties = { "com.sun:auto-snapshot" = "true"; };
        owner = "zwave-js-ui";
        group = "zwave-js-ui";
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
          ];
          consistency = "crash-consistent";
          validator = "zwave-js-ui-state";
          allowEmptyBootstrap = true;
          notes = ''
            Moved to the k8s cluster 2026-11-25. This dataset is the rollback
            copy as of the cutover; delete it in a follow-up after a week.
          '';
        };
      };

      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "zwave-js-ui";

      modules.services.backup.restic.jobs.service-zwave-js-ui = {
        enable = true;
        inherit (forgeDefaults.backup) repository;
        paths = [ dataDir ];
        tags = [ "zwave-js-ui" "zwave" "automation" "forge" ];
        excludePatterns = [ "**/log/**" "**/tmp/**" ]
          ++ config.modules.services.backup.serviceDiscovery.globalExcludes;
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };
    })
  ];
}
