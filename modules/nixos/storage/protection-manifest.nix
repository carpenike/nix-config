{ config, lib, mylib, ... }:
let
  datasetsCfg = config.modules.storage.datasets;
  protectionCfg = config.modules.storage.protection;
  allJobs = lib.attrByPath [ "modules" "services" "backup" "_internal" "allJobs" ] { } config;
  repositories = lib.attrByPath [ "modules" "services" "backup" "repositories" ] { } config;
  sanoidEnabled = lib.attrByPath [ "modules" "backup" "sanoid" "enable" ] false config;
  sanoidDatasets = lib.attrByPath [ "modules" "backup" "sanoid" "datasets" ] { } config;
  serviceNames = builtins.attrNames config.systemd.services;

  serviceEntries = lib.mapAttrsToList
    (name: dataset: {
      dataset = "${datasetsCfg.parentDataset}/${name}";
      inherit name;
      kind = "service";
      mountpoint = if dataset.mountpoint != null then dataset.mountpoint else "${datasetsCfg.parentMount}/${name}";
      protection = dataset.protection;
    })
    datasetsCfg.services;

  utilityEntries = lib.mapAttrsToList
    (datasetPath: dataset: {
      dataset = datasetPath;
      name = datasetPath;
      kind = "utility";
      mountpoint = dataset.mountpoint;
      protection = dataset.protection;
    })
    datasetsCfg.utility;

  managedEntries = serviceEntries ++ utilityEntries;
  managedByPath = lib.listToAttrs (map
    (entry: {
      name = entry.dataset;
      value = entry;
    })
    managedEntries);

  declaredPaths = lib.unique (
    (map (entry: entry.dataset) managedEntries)
    ++ builtins.attrNames sanoidDatasets
    ++ builtins.attrNames protectionCfg.externalDatasets
  );

  entryForPath = datasetPath:
    let
      managed = managedByPath.${datasetPath} or null;
      external = protectionCfg.externalDatasets.${datasetPath} or null;
      name = if managed != null then managed.name else datasetPath;
      kind = if managed != null then managed.kind else "external";
      mountpoint =
        if managed != null then managed.mountpoint
        else if external != null then external.mountpoint
        else null;
      protection =
        if managed != null then managed.protection
        else if external != null then external.protection
        else null;
      usesPgBackRest = protection != null && protection.mechanism.name == "pgbackrest";
      pgBackRestNas = usesPgBackRest
        && lib.elem "pgbackrest-full-backup" serviceNames
        && lib.elem "pgbackrest-incr-backup" serviceNames;
      pgBackRestOffsite = usesPgBackRest
        && lib.elem "pgbackrest-full-backup" serviceNames
        && lib.elem "pgbackrest-incr-r2-backup" serviceNames;
      preseedUnit =
        if external != null && external.preseedUnit != null
        then external.preseedUnit
        else if usesPgBackRest then "postgresql-preseed"
        else if kind == "service" then "preseed-${name}"
        else null;
      jobs = lib.filterAttrs
        (_jobName: job:
          (job.zfsDataset or null) == datasetPath
          || (mountpoint != null && lib.elem mountpoint (job.paths or [ ])))
        allJobs;
      backupJobs = lib.mapAttrsToList
        (jobName: job:
          let
            repository = repositories.${job.repository} or null;
          in
          {
            name = jobName;
            inherit (job) frequency repository useSnapshots;
            repositoryKnown = repository != null;
            repositoryType = if repository != null then repository.type else "unknown";
          })
        jobs;
      sanoid = sanoidDatasets.${datasetPath} or null;
      coverage = {
        localSnapshot = sanoidEnabled
          && sanoid != null
          && (sanoid.autosnap or false)
          && ((sanoid.useTemplate or [ ]) != [ ] || (sanoid.retention or { }) != { });
        replication = sanoidEnabled && sanoid != null && (sanoid.replication or null) != null;
        nasBackup = pgBackRestNas || lib.any (job: job.repositoryType == "local") backupJobs;
        offsiteBackup = pgBackRestOffsite || lib.any
          (job: lib.elem job.repositoryType [ "s3" "b2" "rest" ])
          backupJobs;
        automatedRestore = preseedUnit != null
          && lib.elem preseedUnit serviceNames
          && (config.systemd.services.${preseedUnit}.enable or true);
        independentRestore = external != null && external.independentRestore;
        externalBootstrap = external != null && external.externalBootstrap;
        pgBackRest = pgBackRestNas && pgBackRestOffsite;
      };
      tierSatisfied = tier: {
        local-snapshot = coverage.localSnapshot;
        replication = coverage.replication;
        nas-backup = coverage.nasBackup;
        offsite-backup = coverage.offsiteBackup;
        automated-restore = coverage.automatedRestore;
        independent-restore = coverage.independentRestore;
        external-bootstrap = coverage.externalBootstrap;
      }.${tier};
      requiredTiers = if protection != null then protection.requiredTiers else [ ];
    in
    {
      dataset = datasetPath;
      inherit name kind mountpoint backupJobs coverage requiredTiers;
      classification = if protection == null then "unclassified" else protection.class;
      policy = protection;
      missingRequiredTiers = builtins.filter (tier: !(tierSatisfied tier)) requiredTiers;
    };

  entries = map entryForPath declaredPaths;
  entriesByPath = lib.listToAttrs (map
    (entry: {
      name = entry.dataset;
      value = entry;
    })
    entries);
  classified = builtins.filter (entry: entry.policy != null) entries;
  unclassified = builtins.filter (entry: entry.policy == null) entries;
  unknownRepositories = lib.concatMap
    (entry: map
      (job: {
        dataset = entry.dataset;
        inherit (job) repository;
        job = job.name;
      })
      (builtins.filter (job: !job.repositoryKnown) entry.backupJobs))
    entries;
  classes = [ "system" "critical" "standard" "ephemeral" ];
  manifest = {
    schemaVersion = 1;
    host = config.networking.hostName;
    datasets = entriesByPath;
    summary = {
      total = builtins.length entries;
      classified = builtins.length classified;
      unclassified = map (entry: entry.dataset) unclassified;
      byClass = lib.genAttrs classes
        (class: builtins.length (builtins.filter (entry: entry.classification == class) entries));
      missingRequiredTiers = lib.listToAttrs (map
        (entry: {
          name = entry.dataset;
          value = entry.missingRequiredTiers;
        })
        (builtins.filter (entry: entry.missingRequiredTiers != [ ]) entries));
      inherit unknownRepositories;
    };
  };
in
{
  options.modules.storage.protection = {
    externalDatasets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          mountpoint = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Mountpoint for a protected dataset managed outside modules.storage.datasets.";
          };

          preseedUnit = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Systemd restore unit for this external dataset.";
          };

          externalBootstrap = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether recovery is implemented by an external bootstrap workflow.";
          };

          independentRestore = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether restore has been proven independent of the primary backup tier.";
          };

          protection = lib.mkOption {
            type = lib.types.nullOr mylib.types.protectionPolicySubmodule;
            default = null;
            description = "Protection policy for this external dataset.";
          };
        };
      });
      default = { };
      description = "Protection declarations for datasets managed outside the storage module.";
    };

    manifest = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      default = { };
      description = "Evaluated dataset protection manifest.";
    };
  };

  config = lib.mkIf datasetsCfg.enable {
    modules.storage.protection.manifest = manifest;
    environment.etc."homelab/protection-manifest.json" = {
      text = builtins.toJSON manifest;
      mode = "0444";
    };
  };
}
