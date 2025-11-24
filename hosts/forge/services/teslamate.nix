{ config, lib, ... }:
let
  inherit (config.networking) domain;
  serviceEnabled = config.modules.services.teslamate.enable;
  serviceDomain = "teslamate.${domain}";
  dataset = "tank/services/teslamate";
  dataDir = "/var/lib/teslamate";
  replicationTargetHost = "nas-1.holthome.net";
  replicationTargetDataset = "backup/forge/zfs-recv/teslamate";
  replicationHostKey = "nas-1.holthome.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKUPQfbZFiPR7JslbN8Z8CtFJInUnUMAvMuAoVBlllM";
  resticEnabled =
    (config.modules.backup.enable or false)
    && (config.modules.backup.restic.enable or false);
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

        backup = {
          enable = true;
          repository = "nas-primary";
          zfsDataset = dataset;
          tags = [ "teslamate" "telemetry" ];
        };

        preseed = lib.mkIf resticEnabled {
          enable = true;
          repositoryUrl = "/mnt/nas-backup";
          passwordFile = config.sops.secrets."restic/password".path;
          restoreMethods = [ "syncoid" "local" "restic" ];
        };

        notifications.enable = true;
      };
    }

    (lib.mkIf serviceEnabled {
      # Dataset replication (sanoid contribution)
      modules.backup.sanoid.datasets.${dataset} = {
        useTemplate = [ "services" ];
        recursive = false;
        autosnap = true;
        autoprune = true;
        replication = {
          targetHost = replicationTargetHost;
          targetDataset = replicationTargetDataset;
          hostKey = replicationHostKey;
          sendOptions = "wp";
          recvOptions = "u";
          targetName = "NFS";
          targetLocation = "nas-1";
        };
      };
    })

  ];
}
