{ config, lib, mylib, pkgs, ... }:
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
        && lib.elem "pgbackrest-full-r2-backup" serviceNames
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

  # The JSON manifest is evaluated at build time. It cannot see whether a
  # declared dataset exists on the pool, so a missing dataset still looks
  # fully covered. The timer below is the runtime half: one read-only
  # `zfs get` compared with the same properties the sync unit writes.
  realityExpectations =
    let
      managedService = lib.mapAttrsToList
        (name: dataset:
          let
            mountpoint = if dataset.mountpoint != null then dataset.mountpoint else "${datasetsCfg.parentMount}/${name}";
          in
          {
            dataset = "${datasetsCfg.parentDataset}/${name}";
            inherit mountpoint;
            canmount = dataset.properties.canmount or "on";
            properties = {
              inherit (dataset) recordsize compression;
              inherit mountpoint;
            } // dataset.properties;
          })
        datasetsCfg.services;
      managedUtility = lib.mapAttrsToList
        (datasetPath: dataset: {
          dataset = datasetPath;
          mountpoint = dataset.mountpoint;
          canmount = dataset.properties.canmount or "on";
          properties = {
            inherit (dataset) recordsize compression;
            mountpoint = dataset.mountpoint;
          } // dataset.properties;
        })
        datasetsCfg.utility;
      # Exists, and mounted when a mountpoint is declared. No property
      # expectations: these datasets are not created by the sync unit.
      external = lib.mapAttrsToList
        (datasetPath: dataset: {
          dataset = datasetPath;
          mountpoint = dataset.mountpoint;
          canmount = "on";
          properties = { };
        })
        protectionCfg.externalDatasets;
    in
    managedService ++ managedUtility ++ external;

  realityPropertyNames = lib.unique (
    [ "mountpoint" "mounted" "canmount" ]
    ++ lib.concatMap (entry: builtins.attrNames entry.properties) realityExpectations
  );

  realityScript = pkgs.writeShellScript "zfs-dataset-reality" ''
    set -uo pipefail
    ZFS=${lib.escapeShellArg "${pkgs.zfs}/bin/zfs"}
    HOST=${lib.escapeShellArg config.networking.hostName}
    OUT=/var/lib/node_exporter/textfile_collector/zfs_dataset_reality.prom
    mkdir -p "$(dirname "$OUT")"

    declare -A got=()
    checker_ok=1
    if ! raw=$("$ZFS" get -H -t filesystem -o name,property,value ${lib.escapeShellArg (lib.concatStringsSep "," realityPropertyNames)} 2>/dev/null); then
      checker_ok=0
      raw=""
      echo "zfs get failed; every declared dataset will be reported as a gap" >&2
    fi
    while IFS=$'\t' read -r name prop value; do
      [ -z "$name" ] && continue
      got["$name|$prop"]=$value
    done <<< "$raw"

    metrics=$(mktemp)
    check_one() {
      local ds="$1" mp="$2" canmount="$3"
      local exists=0 mount_ok=0 props_ok=1 line prop expected
      if [ -n "''${got[$ds|mountpoint]+x}" ]; then
        exists=1
      fi
      if [ "$exists" -eq 0 ]; then
        mount_ok=0
        props_ok=0
      elif [ "$mp" != "-" ] && [ "$mp" != "none" ] && [ "$mp" != "legacy" ] && [ "$canmount" = "on" ]; then
        if [ "''${got[$ds|mountpoint]}" = "$mp" ] && [ "''${got[$ds|mounted]:-}" = "yes" ]; then
          mount_ok=1
        fi
      else
        mount_ok=1
      fi
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        [ "$exists" -eq 0 ] && continue
        prop=''${line%%=*}
        expected=''${line#*=}
        if [ "''${got[$ds|$prop]:-}" != "$expected" ]; then
          echo "property mismatch on $ds: $prop expected [$expected] got [''${got[$ds|$prop]:-<missing>}]" >&2
          props_ok=0
        fi
      done
      # Missing or unmounted is the paging gap. A property the sync unit
      # could not set (it logs and continues) is reported separately so it
      # does not look like a missing dataset.
      local gap=0 prop_gap=0
      if [ "$exists" -eq 0 ] || [ "$mount_ok" -eq 0 ]; then
        gap=1
        echo "declared dataset gap: $ds exists=$exists mount=$mount_ok" >&2
      fi
      if [ "$props_ok" -eq 0 ]; then
        prop_gap=1
        echo "declared dataset property drift: $ds" >&2
      fi
      printf 'zfs_dataset_declared_ok{hostname="%s",dataset="%s",check="exists"} %s\n' "$HOST" "$ds" "$exists"
      printf 'zfs_dataset_declared_ok{hostname="%s",dataset="%s",check="mount"} %s\n' "$HOST" "$ds" "$mount_ok"
      printf 'zfs_dataset_declared_ok{hostname="%s",dataset="%s",check="properties"} %s\n' "$HOST" "$ds" "$props_ok"
      printf 'zfs_dataset_declared_gap{hostname="%s",dataset="%s"} %s\n' "$HOST" "$ds" "$gap"
      printf 'zfs_dataset_declared_property_mismatch{hostname="%s",dataset="%s"} %s\n' "$HOST" "$ds" "$prop_gap"
    }

    {
      echo "# HELP zfs_dataset_declared_ok 1 when that live-pool check matches the declaration"
      echo "# TYPE zfs_dataset_declared_ok gauge"
      echo "# HELP zfs_dataset_declared_gap 1 when a declared dataset is missing or not mounted at its mountpoint"
      echo "# TYPE zfs_dataset_declared_gap gauge"
      echo "# HELP zfs_dataset_declared_property_mismatch 1 when a declared property differs from the live value"
      echo "# TYPE zfs_dataset_declared_property_mismatch gauge"
      ${lib.concatMapStrings (entry: ''
        check_one ${lib.escapeShellArg entry.dataset} ${lib.escapeShellArg (if entry.mountpoint == null then "-" else entry.mountpoint)} ${lib.escapeShellArg entry.canmount} <<'PROPS'
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (prop: value: "${prop}=${value}") entry.properties)}
        PROPS
      '') realityExpectations}
      echo "# HELP zfs_dataset_reality_checker_ok 1 when zfs get succeeded"
      echo "# TYPE zfs_dataset_reality_checker_ok gauge"
      echo "zfs_dataset_reality_checker_ok{hostname=\"$HOST\"} $checker_ok"
      echo "# HELP zfs_dataset_reality_check_timestamp_seconds Unix time of the last pool comparison"
      echo "# TYPE zfs_dataset_reality_check_timestamp_seconds gauge"
      echo "zfs_dataset_reality_check_timestamp_seconds{hostname=\"$HOST\"} $(date +%s)"
    } > "$metrics"
    mv "$metrics" "$OUT"
  '';

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

    systemd.services.zfs-dataset-reality = {
      description = "Compare declared ZFS datasets with the live pool";
      after = [ "zfs-service-datasets.service" "zfs-service-datasets-sync.service" ];
      path = [ pkgs.coreutils pkgs.zfs ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = realityScript;
      };
    };

    systemd.timers.zfs-dataset-reality = {
      description = "Compare declared ZFS datasets with the live pool";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
        Persistent = true;
        AccuracySec = "1min";
      };
    };

    modules.alerting.rules = lib.mkIf (config.modules.alerting.enable or false) {
      "zfs-dataset-declared-gap" = {
        type = "promql";
        alertname = "ZfsDatasetDeclaredGap";
        expr = "zfs_dataset_declared_gap > 0";
        for = "15m";
        severity = "critical";
        labels = {
          service = "storage";
          category = "zfs";
        };
        annotations = {
          summary = "Declared ZFS dataset {{ $labels.dataset }} does not match the live pool on {{ $labels.hostname }}";
          description = "The protection manifest's tier coverage does not mean this dataset exists. The pool check failed: the dataset is missing or not mounted at its declared mountpoint. This check is read-only.";
          command = "journalctl -u zfs-dataset-reality.service -n 80; zfs list -o name,mountpoint,mounted; systemctl status zfs-service-datasets-sync.service";
        };
      };

      "zfs-dataset-property-mismatch" = {
        type = "promql";
        alertname = "ZfsDatasetPropertyMismatch";
        expr = "zfs_dataset_declared_property_mismatch > 0";
        for = "1h";
        severity = "low";
        labels = {
          service = "storage";
          category = "zfs";
        };
        annotations = {
          summary = "Declared ZFS property on {{ $labels.dataset }} differs from the live pool on {{ $labels.hostname }}";
          description = "The comparison is the same string check zfs-service-datasets-sync uses. A property that unit cannot set is logged and left in place, so this stays at low severity instead of paging.";
          command = "journalctl -u zfs-dataset-reality.service -n 80; zfs get all {{ $labels.dataset }}";
        };
      };

      "zfs-dataset-reality-stale" = {
        type = "promql";
        alertname = "ZfsDatasetRealityStale";
        expr = "(time() - zfs_dataset_reality_check_timestamp_seconds) > 1800";
        for = "15m";
        severity = "high";
        labels = {
          service = "storage";
          category = "zfs";
        };
        annotations = {
          summary = "ZFS dataset pool check has not reported on {{ $labels.hostname }}";
          description = "zfs-dataset-reality.timer has not written a fresh textfile in 30 minutes, so a missing dataset would look fully covered.";
          command = "systemctl status zfs-dataset-reality.timer zfs-dataset-reality.service";
        };
      };
    };
  };
}
