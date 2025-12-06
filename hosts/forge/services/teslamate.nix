# hosts/forge/services/teslamate.nix
#
# Host-specific configuration for TeslaMate on 'forge'.
# TeslaMate is a Tesla vehicle data logger and visualization tool.

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceEnabled = config.modules.services.teslamate.enable or false;
  serviceDomain = "teslamate.${domain}";
  dataset = "tank/services/teslamate";
  dataDir = "/var/lib/teslamate";
in
{
  config = lib.mkMerge [
    {
      modules.services.teslamate = {
        enable = true;
        dataDir = dataDir;
        datasetPath = dataset;
        image = "teslamate/teslamate:2.2.0@sha256:db111162f1037a8c8ce6fe56e538a4432b8a34d3d6176916ba22d42ef7ee4b78";
        encryptionKeyFile = config.sops.secrets."teslamate/encryption_key".path;

        database = {
          passwordFile = config.sops.secrets."teslamate/database_password".path;
          host = "host.containers.internal";
          manageDatabase = true;
          localInstance = true;
          schemaMigrations = {
            ensureTable = true;
            columnType = "bigint";
            insertedAtColumn = {
              columnType = "timestamp without time zone";
              defaultValue = "timezone('UTC', now())";
            };
            entries = [ "20240929084639" ];
          };
        };

        mqtt = {
          enable = true;
          host = "host.containers.internal";
          passwordFile = config.sops.secrets."teslamate/mqtt_password".path;
          aclTopics = [ "teslamate/#" ];
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = 4000;
          };
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

        # Resource limits - 7d peak (198M) × 2.5 = 495M, using 512M
        resources = {
          memory = "512M";
          memoryReservation = "256M";
          cpus = "0.5";
        };

        backup = forgeDefaults.mkBackupWithTags "teslamate" [ "teslamate" "telemetry" "forge" ];

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        notifications.enable = true;

        # Grafana integration with dedicated read-only user for security
        grafanaIntegration = {
          enable = true;
          user = "teslamate_grafana";
          passwordFile = config.sops.secrets."teslamate/grafana_password".path;
          host = "127.0.0.1"; # Grafana connects directly to PostgreSQL on localhost
        };
      };
    }

    (lib.mkIf serviceEnabled {
      # Dataset replication (sanoid contribution)
      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset "teslamate";

      # Service availability alert
      modules.alerting.rules."teslamate-service-down" =
        forgeDefaults.mkServiceDownAlert "teslamate" "TeslaMate" "Tesla vehicle telemetry";
    })

  ];
}
