# Obsidian headless Sync + vault MCP on forge.
#
# Off by default. Merging this file does not publish a vhost, start a unit,
# or require a new sops key. Flip modules.services.obsidian-vault.enable
# after the one-time steps in the module header. Publishing also requires
# mcp.tokenProvisioned, which declares sops secret obsidian-vault/mcp_token.
#
# Why there is no service-down alert on obsidian-sync: the unit is inactive
# on purpose until `ob login` writes the auth token (ConditionFileNotEmpty).
# mkSystemdServiceDownAlert matches state="active" == 0 for 2m, which would
# page the whole time the client is waiting for that login. A crash after
# login reaches state="failed" and the existing SystemdUnitFailed rule.
# The MCP unit only exists once the bearer is provisioned, so a down alert
# on it is a real outage.
#
# One NAS restic job plus sanoid replication. No second offsite restic job:
# the jobs already share the daily window, and Obsidian Sync is the remote
# replica of the vault. The dataset backup does include the Sync client's
# credential directory; restic encryption is what protects it.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  cfg = config.modules.services."obsidian-vault";
  serviceEnabled = cfg.enable or false;
  tokenProvisioned = cfg.mcp.tokenProvisioned or false;
  exposed = cfg.mcp.expose or false;
  serviceName = "obsidian-vault";
in
{
  config = lib.mkMerge [
    {
      modules.services."obsidian-vault" = {
        enable = false;

        # Intended public name and tunnel. Inert while enable is false, and
        # the module refuses enable + expose until the sops token exists.
        mcp = {
          expose = true;
          tokenProvisioned = false;
          tunnel = "forge";
        };

        backup = forgeDefaults.mkBackupWithTags serviceName [
          "notes"
          "obsidian"
          "forge"
        ];
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # New path: nothing is migrated onto this dataset. The first apply
      # creates it empty. `ob sync-setup` fills the vault afterwards.
      modules.storage.datasets.services."obsidian-vault" = {
        mountpoint = "/var/lib/obsidian-sync";
        recordsize = "128K";
        compression = "zstd";
        owner = "obsidian-sync";
        group = "obsidian-vault";
        mode = "0750";
        protection = {
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
          validator = null;
          # First deploy has no vault until the interactive sync-setup.
          allowEmptyBootstrap = true;
        };
      };

      modules.backup.sanoid.datasets."tank/services/${serviceName}" =
        forgeDefaults.mkSanoidDataset serviceName;
    })

    (lib.mkIf (serviceEnabled && tokenProvisioned) {
      modules.alerting.rules."obsidian-vault-mcp-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert
          "obsidian-vault-mcp"
          "ObsidianVaultMcp"
          "Obsidian vault MCP";
    })

    (lib.mkIf (serviceEnabled && tokenProvisioned && exposed) {
      # /health is the unauthenticated liveness route (status ok). It does
      # not touch the vault. The bearer-protected MCP path is not a probe.
      modules.services.gatus.contributions."obsidian-vault" = {
        name = "Obsidian vault MCP";
        group = "applications";
        url = "https://${cfg.hostName}/health";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[BODY].status == ok"
          "[RESPONSE_TIME] < 5000"
        ];
        alerts = [{
          type = "pushover";
          sendOnResolved = true;
          failureThreshold = 3;
          successThreshold = 1;
        }];
      };
    })
  ];
}
