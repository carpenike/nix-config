# hosts/forge/services/retired-to-cluster.nix
#
# Data retention for the services that moved from Forge to the k8s cluster.
#
#   retired: 2026-11-08    keep until: 2026-11-15    then: delete in a follow-up
#
# What moved (carpenike/k8s-gitops):
#   #5765  homelab-mcp (server, Actual sidecar, finances ingest/export/
#          snapshots, finance-signal capture/reports) and signal-api
#   #5780  schoolhouse and lading
#   #5781  Grafana and Grafana OnCall
#   #5766  postgres17 holds schoolhouse, lading, homelab_finance and
#          finances_context
#
# The services are gone from Forge. Their DATA is not: this file keeps every
# dataset they owned declared, snapshotted, replicated and backed up, exactly
# as it was, for the one-week rollback window. Rollback is `git revert` of the
# retirement PR; the data it would come back to is still here and still
# protected. Only the protection policy's `automated-restore` tier is dropped
# (signal-api, grafana-oncall): it promises a preseed unit that refills the
# dataset before the service starts, and there is no service to start.
#
# Why keep the declarations rather than just drop them: dropping a
# declaration would not destroy anything (modules/nixos/storage/datasets.nix
# only creates and reconciles; nothing here runs `zfs destroy` on an
# undeclared dataset, and ZFS keeps mounting it from its own mountpoint
# property). But it would also stop the snapshots, the syncoid replication to
# nas-1 and the Restic jobs, and drop the datasets out of the protection
# manifest, so the rollback week would run on the last pre-cutover copies
# with nothing watching them. Keeping the declarations costs a few idle
# timers for a week.
#
# PostgreSQL is different and needs nothing here: the provisioner
# (modules/nixos/services/postgresql/databases.nix) only CREATEs and GRANTs and
# never drops a database or a role, so the `schoolhouse`, `lading` and
# `homelab_finance` databases stay in Forge's cluster untouched, and pgBackRest
# keeps backing them up with everything else.
#
# Not on a dataset, and never was: /var/lib/schoolhouse. schoolhouse used a
# plain StateDirectory on the root dataset, which initrd rolls back on every
# boot (impermanence), so it has never survived a reboot. Its real state is the
# Postgres database. If the raw-HTML archive in it matters, copy it off before
# the next reboot (see the PR's cutover plan).
#
# Each block yields to the real service definition (it is gated on that
# service being disabled), so re-importing a retired module -- a rollback, or
# the Atrium fixtures in tests/atrium_n03/forge-retired -- does not declare
# anything twice.
{ config, inputs, lib, mylib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (forgeDefaults.backup) repository;
  globalExcludes = config.modules.services.backup.serviceDiscovery.globalExcludes;
  retentionNote = ''
    Retired 2026-11-08: the service moved to the k8s cluster. This dataset is
    kept, snapshotted and backed up until 2026-11-15 as the rollback copy;
    delete it in a follow-up after that.
  '';

  homelabMcpRunning = config.services.homelab-mcp.enable;
  ladingRunning = config.services.lading.enable or false;
  signalApiRunning = config.modules.services.signal-api.enable;
  grafanaRunning = config.modules.services.grafana.enable;
  onCallRunning = config.modules.services.grafana-oncall.enable;

  signalApiIds = mylib.serviceUids.signal-api;
  onCallIds = mylib.serviceUids.grafana-oncall;
in
{
  # Options only: services.homelab-mcp.enable stays false, so the upstream
  # module creates nothing. The Atrium modules (services/atrium*.nix) still
  # define services.homelab-mcp.* under their (off) adoption gates, and a
  # definition of an undeclared option is an error even inside mkIf false.
  imports = [ inputs.homelab-mcp.nixosModules.default ];

  config = lib.mkMerge [
    # ── homelab-mcp: /var/lib/homelab-mcp ────────────────────────────────
    # OAuth state, signing key, finances ingest reservation, finance-signal
    # capture/report state. Same dataset, snapshots and both Restic jobs the
    # service declared (formerly services/homelab-mcp.nix).
    (lib.mkIf (!homelabMcpRunning) {
      # The upstream module created this user; keep it so the dataset keeps a
      # named owner (and modules.onDemandUpgrade's request directory, which
      # is owned by it, still resolves). Its uid comes back from
      # /var/lib/nixos/uid-map, as it always did.
      users.users.homelab-mcp = {
        isSystemUser = true;
        group = "homelab-mcp";
        description = "homelab-mcp service user (retired to k8s; data owner)";
        home = "/var/lib/homelab-mcp";
        createHome = false;
      };
      users.groups.homelab-mcp = { };

      modules.storage.datasets.services.homelab-mcp = {
        mountpoint = "/var/lib/homelab-mcp";
        recordsize = "16K";
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "homelab-mcp";
        group = "homelab-mcp";
        mode = "0700";
      };

      modules.backup.sanoid.datasets."tank/services/homelab-mcp" =
        forgeDefaults.mkSanoidDataset "homelab-mcp";

      modules.services.backup.restic.jobs.homelab-mcp = {
        enable = true;
        inherit repository;
        paths = [ "/var/lib/homelab-mcp" ];
        tags = [ "homelab-mcp" "sqlite" "finances" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/homelab-mcp";
      };
      modules.services.backup.restic.jobs.homelab-mcp-offsite = {
        enable = true;
        repository = "r2-offsite";
        paths = [ "/var/lib/homelab-mcp" ];
        tags = [ "homelab-mcp" "sqlite" "finances" "offsite" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/homelab-mcp";
      };
    })

    # ── lading: /var/lib/lading ───────────────────────────────────────────
    # Rotating Costco/Sam's tokens and the Amazon cookie jar, one directory
    # per account. Formerly services/lading.nix.
    (lib.mkIf (!ladingRunning) {
      users.users.lading = {
        isSystemUser = true;
        group = "lading";
        description = "lading service user (retired to k8s; data owner)";
      };
      users.groups.lading = { };

      modules.storage.datasets.services.lading = {
        mountpoint = "/var/lib/lading";
        recordsize = "16K";
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "lading";
        group = "lading";
        mode = "0700";
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
          ];
          consistency = "crash-consistent";
          validator = null;
          allowEmptyBootstrap = true;
          notes = ''
            Holds rotating Costco/Sam's Club refresh tokens and a live Amazon
            cookie jar. Treat the contents as credentials.
          '' + retentionNote;
        };
      };

      modules.backup.sanoid.datasets."tank/services/lading" =
        forgeDefaults.mkSanoidDataset "lading";

      modules.services.backup.restic.jobs.lading = {
        enable = true;
        inherit repository;
        paths = [ "/var/lib/lading" ];
        tags = [ "lading" "credentials" "finances" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/lading";
      };
    })

    # ── signal-api: /var/lib/signal-api ──────────────────────────────────
    # The Signal bot's registration keys. The container ran as the pinned
    # uid from lib/service-uids.nix, so the dataset is owned by that number.
    # Formerly services/signal-api.nix plus the container factory's defaults.
    (lib.mkIf (!signalApiRunning) {
      users.users.signal-api = {
        uid = signalApiIds.uid;
        group = "signal-api";
        isSystemUser = true;
        description = "Signal REST API service user (retired to k8s; data owner)";
      };
      users.groups.signal-api.gid = signalApiIds.gid;

      modules.storage.datasets.services.signal-api = {
        mountpoint = "/var/lib/signal-api";
        recordsize = "16K";
        compression = "zstd";
        properties = {
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = toString signalApiIds.uid;
        group = "signal-api";
        mode = "0700";
        protection = {
          class = "critical";
          objectives = {
            onsiteRpoSeconds = 900;
            offsiteRpoSeconds = 86400;
            rtoSeconds = 7200;
          };
          # `automated-restore` dropped: it is satisfied by a preseed unit
          # that refills the dataset before the container starts, and there
          # is no container here any more.
          requiredTiers = [
            "local-snapshot"
            "replication"
            "nas-backup"
            "offsite-backup"
          ];
          consistency = "crash-consistent";
          validator = "signal-api-registration";
          allowEmptyBootstrap = true;
          notes = ''
            Registration state is not reproducible from any other source.
          '' + retentionNote;
        };
      };

      modules.backup.sanoid.datasets."tank/services/signal-api" =
        forgeDefaults.mkSanoidDataset "signal-api";

      # Same job names as before (the first was generated by backup discovery
      # from the service's `backup` option), so the timer set is unchanged.
      modules.services.backup.restic.jobs.service-signal-api = {
        enable = true;
        inherit repository;
        paths = [ "/var/lib/signal-api" ];
        tags = [ "signal-api" "signal" "messaging" "forge" ];
        excludePatterns = globalExcludes;
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/signal-api";
      };
      modules.services.backup.restic.jobs.signal-api-offsite = {
        enable = true;
        repository = "r2-offsite";
        paths = [ "/var/lib/signal-api" ];
        tags = [ "signal-api" "signal" "offsite" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/signal-api";
      };
    })

    # ── Grafana: /var/lib/grafana ─────────────────────────────────────────
    # grafana.db (users, folders, UI-made dashboards, the OnCall plugin's
    # settings). Formerly infrastructure/observability/grafana.nix plus
    # modules/nixos/services/grafana.
    (lib.mkIf (!grafanaRunning) {
      # nixpkgs' services.grafana created this user with its fixed uid.
      # restic-backup is also a member of this group (core/users.nix).
      users.users.grafana = {
        uid = config.ids.uids.grafana;
        group = "grafana";
        isSystemUser = true;
        description = "Grafana user (retired to k8s; data owner)";
        home = "/var/empty";
      };
      users.groups.grafana = { };

      modules.storage.datasets.services.grafana = {
        mountpoint = "/var/lib/grafana";
        recordsize = "128K";
        compression = "zstd";
        properties = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        owner = "grafana";
        group = "grafana";
        mode = "0750";
      };

      modules.backup.sanoid.datasets."tank/services/grafana" =
        forgeDefaults.mkSanoidDataset "grafana";

      modules.services.backup.restic.jobs.service-grafana = {
        enable = true;
        inherit repository;
        paths = [ "/var/lib/grafana" ];
        tags = [ "grafana" "monitoring" "grafana" "dashboards" ];
        excludePatterns = [
          "**/sessions/*"
          "**/png/*"
          "**/csv/*"
          "**/pdf/*"
        ] ++ globalExcludes;
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/grafana";
      };
    })

    # ── Grafana OnCall: /var/lib/grafana-oncall ──────────────────────────
    # OnCall's SQLite database (schedules, escalation chains, integrations)
    # plus redis/celery state. Formerly services/grafana-oncall.nix plus
    # modules/nixos/services/grafana-oncall.
    (lib.mkIf (!onCallRunning) {
      users.users.grafana-oncall = {
        uid = onCallIds.uid;
        group = "grafana-oncall";
        isSystemUser = true;
        description = "Grafana OnCall service user (retired to k8s; data owner)";
      };
      users.groups.grafana-oncall.gid = onCallIds.gid;

      modules.storage.datasets.services.grafana-oncall = {
        mountpoint = "/var/lib/grafana-oncall";
        recordsize = "16K";
        compression = "zstd";
        owner = "grafana-oncall";
        group = "grafana-oncall";
        mode = "0750";
        protection = {
          class = "standard";
          objectives = {
            onsiteRpoSeconds = 86400;
            offsiteRpoSeconds = null;
            rtoSeconds = 28800;
          };
          # `automated-restore` dropped, as for signal-api above.
          requiredTiers = [
            "local-snapshot"
            "replication"
            "nas-backup"
          ];
          consistency = "crash-consistent";
          validator = "grafana-oncall-sqlite";
          allowEmptyBootstrap = false;
          notes = retentionNote;
        };
      };

      modules.backup.sanoid.datasets."tank/services/grafana-oncall" =
        forgeDefaults.mkSanoidDataset "grafana-oncall";

      modules.services.backup.restic.jobs.service-grafana-oncall = {
        enable = true;
        inherit repository;
        paths = [ "/var/lib/grafana-oncall" ];
        tags = [ "grafana-oncall" "oncall" "incident-response" "monitoring" "forge" ];
        excludePatterns = globalExcludes;
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = "tank/services/grafana-oncall";
      };
    })
  ];
}
