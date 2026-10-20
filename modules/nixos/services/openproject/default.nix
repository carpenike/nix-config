# NixOS module for OpenProject Community Edition
#
# OpenProject is a Rails application. Upstream ships official container images
# and a docker-compose layout; nixpkgs has neither a package nor a NixOS module
# (checked against nixos-25.11), so this module follows the upstream
# multi-process "slim" image layout with Podman, the same way
# modules/nixos/services/grafana-oncall wires its multi-container stack.
#
# Containers (all from the same pinned image):
# - openproject-seeder: oneshot, runs `./docker/prod/seeder` (schema load or
#   `db:migrate`, then `db:seed`). Runs before web/worker on every start and
#   re-runs on image change, so upgrades migrate before the app serves.
# - openproject-web:    puma (`./docker/prod/web`), clustered workers.
# - openproject-worker: GoodJob background worker (`./docker/prod/worker`);
#   GoodJob's built-in cron runs scheduled jobs, so upstream's separate `cron`
#   container (only an IMAP mail-receive loop) is intentionally not deployed.
#
# External dependencies (host-provided, not bundled):
# - PostgreSQL: the shared host instance (pgBackRest covers it cluster-wide)
# - Rails cache: the shared host Redis (upstream compose uses memcached; the
#   OpenProject setting `rails_cache_store` accepts `redis` natively)
#
# Secrets arrive via `environmentFile` (render it with sops.templates):
#   SECRET_KEY_BASE=...
#   DATABASE_URL=postgres://<user>:<password>@<host>:<port>/<db>?pool=N&encoding=unicode&reconnect=true
#   OPENPROJECT_SEED__ADMIN__USER__PASSWORD=...   (optional, first seed only)
#
{ config, lib, mylib, pkgs, ... }:
with lib;
let
  sharedTypes = mylib.types;
  storageHelpers = mylib.storageHelpers pkgs;
  serviceIds = mylib.serviceUids.openproject;

  cfg = config.modules.services.openproject;
  storageCfg = config.modules.storage or { };
  datasetsCfg = storageCfg.datasets or { };

  serviceName = "openproject";
  backend = config.virtualisation.oci-containers.backend;

  webContainer = "${serviceName}-web";
  workerContainer = "${serviceName}-worker";
  seederContainer = "${serviceName}-seeder";
  webUnit = "${backend}-${webContainer}";
  workerUnit = "${backend}-${workerContainer}";
  seederUnit = "${backend}-${seederContainer}";

  defaultDatasetPath =
    if datasetsCfg ? parentDataset then
      "${datasetsCfg.parentDataset}/${serviceName}"
    else
      null;

  datasetPath = cfg.datasetPath or defaultDatasetPath;

  replicationConfig = storageHelpers.mkReplicationConfig { inherit config datasetPath; };
  preseedUnit = "preseed-${serviceName}.service";
  allowEmptyBootstrap = storageHelpers.allowEmptyBootstrapFor {
    inherit config;
    datasetName = serviceName;
  };

  dbUnits = lib.optionals cfg.database.localInstance [
    "postgresql.service"
    "postgresql-provision-databases.service"
  ];
  cacheUnits = lib.optional (cfg.cache.localUnit != null) cfg.cache.localUnit;

  # Shared environment for every OpenProject process.
  openprojectEnvironment = {
    TZ = cfg.timezone;
    # The image's `app` user has a fixed home; we run as the registry UID, so
    # point HOME at the writable tmpfs instead.
    HOME = "/app/tmp";

    # Public URL handling behind Caddy (TLS terminated at Caddy / Cloudflare).
    OPENPROJECT_HOST__NAME = cfg.hostName;
    OPENPROJECT_HTTPS = "true"; # generated links + secure cookies use https
    # Caddy already emits HSTS and does the http->https redirect. Leaving
    # Rails' HSTS on would duplicate the header and force-redirect plain-http
    # loopback calls (Gatus, a host-local MCP server) to https.
    OPENPROJECT_HSTS = "false";
    OPENPROJECT_ADDITIONAL__HOST__NAMES = concatStringsSep " " cfg.additionalHostNames;

    # Rails cache
    OPENPROJECT_RAILS__CACHE__STORE = "redis";
    OPENPROJECT_CACHE__REDIS__URL = cfg.cache.redisUrl;
    OPENPROJECT_CACHE__NAMESPACE = serviceName;

    # Puma sizing (config/puma.rb reads Setting.web)
    OPENPROJECT_WEB_WORKERS = toString cfg.web.workers;
    OPENPROJECT_WEB_MIN__THREADS = toString cfg.web.minThreads;
    OPENPROJECT_WEB_MAX__THREADS = toString cfg.web.maxThreads;

    # GoodJob concurrency (upstream default is 20 threads -> 20 DB connections)
    OPENPROJECT_GOOD__JOB__MAX__THREADS = toString cfg.worker.maxThreads;

    # No IMAP / no collaborative-editing (hocuspocus) server deployed.
    IMAP_ENABLED = "false";

    OPENPROJECT_DEFAULT__LANGUAGE = "en";
    OPENPROJECT_LOG__LEVEL = cfg.logLevel;
  }
  // optionalAttrs (cfg.ssrfAllowlist != [ ]) {
    # Webhooks to private addresses are blocked by OpenProject's SSRF filter
    # unless explicitly allow-listed.
    OPENPROJECT_SSRF__PROTECTION__IP__ALLOWLIST = concatStringsSep " " cfg.ssrfAllowlist;
  }
  // cfg.extraEnvironment;

  commonVolumes = [ "${cfg.dataDir}:/var/openproject/assets" ];

  # The image is built for its own `app` user (uid 1000, which is `ryan` on
  # forge). Running as the registry UID keeps the dataset owned by a dedicated
  # account; /app/tmp is the only path under /app the processes write to.
  commonOptions = [ "--tmpfs=/app/tmp:rw,size=512m,mode=1777" ];

  resourceOptions = res: lib.optionals (res != null) ([
    "--memory=${res.memory}"
    "--cpus=${res.cpus}"
  ] ++ lib.optional (res.memoryReservation != null) "--memory-reservation=${res.memoryReservation}");

  preseedRequires = lib.optional (cfg.preseed.enable && !allowEmptyBootstrap) preseedUnit;
  preseedWants = lib.optional (cfg.preseed.enable && allowEmptyBootstrap) preseedUnit;
  preseedAfter = lib.optional cfg.preseed.enable preseedUnit;
in
{
  options.modules.services.openproject = {
    enable = mkEnableOption "OpenProject Community Edition";

    image = mkOption {
      type = types.str;
      description = ''
        OpenProject container image. Use the `-slim` variant (no bundled
        PostgreSQL/memcached/Apache) and pin it as tag@sha256 digest.
      '';
      example = "openproject/openproject:17.9.2-slim@sha256:...";
    };

    user = mkOption {
      type = types.str;
      default = serviceName;
      description = "System user owning the OpenProject assets dataset.";
    };

    uid = mkOption {
      type = types.int;
      default = serviceIds.uid;
      description = "Static UID (from lib/service-uids.nix) the containers run as.";
    };

    group = mkOption {
      type = types.str;
      default = serviceName;
      description = "System group owning the OpenProject assets dataset.";
    };

    gid = mkOption {
      type = types.int;
      default = serviceIds.gid;
      description = "Static GID (from lib/service-uids.nix) the containers run as.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/openproject";
      description = "Persistent assets directory (attachments live in ./files), mounted at /var/openproject/assets.";
    };

    datasetPath = mkOption {
      type = types.nullOr types.str;
      default = defaultDatasetPath;
      description = "ZFS dataset backing dataDir.";
      example = "tank/services/openproject";
    };

    timezone = mkOption {
      type = types.str;
      default = "America/New_York";
      description = "Container timezone.";
    };

    hostName = mkOption {
      type = types.str;
      example = "tasks.holthome.net";
      description = "Public host name (OPENPROJECT_HOST__NAME); used for links, OAuth redirects and Rails host authorization.";
    };

    additionalHostNames = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra Host headers Rails accepts (DNS-rebinding protection). Add the
        loopback names a host-local client (e.g. an MCP wrapper) uses.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address the web container is published on.";
    };

    listenPort = mkOption {
      type = types.port;
      default = 8072;
      description = "Host port the web container (container port 8080) is published on.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Environment file carrying SECRET_KEY_BASE and DATABASE_URL (and
        optionally OPENPROJECT_SEED__ADMIN__USER__PASSWORD). Render it with
        sops.templates; never put the values in the Nix store.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional non-secret OPENPROJECT_* settings.";
    };

    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warn" "error" "fatal" ];
      default = "info";
      description = "OpenProject log level.";
    };

    ssrfAllowlist = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "10.88.0.1/32" ];
      description = ''
        Private IPs/CIDRs outgoing webhooks may reach. OpenProject blocks
        RFC1918/loopback webhook targets by default (SSRF protection).
      '';
    };

    database.localInstance = mkOption {
      type = types.bool;
      default = true;
      description = "PostgreSQL runs on this host (adds unit ordering on postgresql + provisioning).";
    };

    cache = {
      redisUrl = mkOption {
        type = types.str;
        example = "redis://host.containers.internal:6379/2";
        description = "Redis URL for the Rails cache store.";
      };

      localUnit = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "redis-default.service";
        description = "Host unit providing the cache, for start ordering.";
      };
    };

    web = {
      workers = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Puma worker processes.";
      };
      minThreads = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Puma minimum threads per worker.";
      };
      maxThreads = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Puma maximum threads per worker (keep <= the DATABASE_URL pool).";
      };
      resources = mkOption {
        type = types.nullOr sharedTypes.containerResourcesSubmodule;
        default = {
          memory = "2560M";
          memoryReservation = "1G";
          cpus = "2.0";
        };
        description = "Resource limits for the web container.";
      };
    };

    worker = {
      maxThreads = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "GoodJob worker threads (keep <= the DATABASE_URL pool).";
      };
      resources = mkOption {
        type = types.nullOr sharedTypes.containerResourcesSubmodule;
        default = {
          memory = "1536M";
          memoryReservation = "512M";
          cpus = "1.5";
        };
        description = "Resource limits for the background worker container.";
      };
    };

    seeder.resources = mkOption {
      type = types.nullOr sharedTypes.containerResourcesSubmodule;
      default = {
        memory = "1536M";
        memoryReservation = null;
        cpus = "2.0";
      };
      description = "Resource limits for the migrate/seed oneshot.";
    };

    healthcheck = mkOption {
      type = types.nullOr sharedTypes.healthcheckSubmodule;
      default = {
        enable = true;
        interval = "30s";
        timeout = "10s";
        retries = 3;
        startPeriod = "300s";
      };
      description = "Web container healthcheck (GET /health_checks/default).";
    };

    reverseProxy = mkOption {
      type = types.nullOr sharedTypes.reverseProxySubmodule;
      default = null;
      description = "Caddy reverse proxy registration.";
    };

    backup = mkOption {
      type = types.nullOr sharedTypes.backupSubmodule;
      default = {
        enable = true;
        repository = "nas-primary";
        tags = [ "openproject" "tasks" ];
      };
      description = "Restic backup of the assets dataset (discovered by modules.services.backup). The database is covered by pgBackRest.";
    };

    preseed = {
      enable = mkEnableOption "automatic assets restore before first start";
      repositoryUrl = mkOption {
        type = types.str;
        default = "";
        description = "Restic repository URL for restore";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to Restic password file";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional environment file for Restic";
      };
      restoreMethods = mkOption {
        type = types.listOf (types.enum [ "syncoid" "local" "restic" ]);
        default = [ "syncoid" "local" ];
        description = "Ordered list of restore methods to attempt";
      };
    };

    notifications = mkOption {
      type = types.nullOr sharedTypes.notificationSubmodule;
      default = {
        enable = true;
        channels.onFailure = [ "system-alerts" ];
        customMessages.failure = "OpenProject failed on ${config.networking.hostName}";
      };
      description = "Notification configuration for service events";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.environmentFile != null;
          message = "modules.services.openproject.environmentFile must be set (SECRET_KEY_BASE + DATABASE_URL via sops.templates).";
        }
        {
          assertion = hasInfix "@sha256:" cfg.image;
          message = "modules.services.openproject.image must be pinned by digest (tag@sha256:...).";
        }
      ];

      users.users.${cfg.user} = {
        isSystemUser = true;
        uid = cfg.uid;
        group = cfg.group;
        home = cfg.dataDir;
        description = "OpenProject service user";
      };
      users.groups.${cfg.group}.gid = cfg.gid;

      modules.storage.datasets.services.${serviceName} = mkIf (datasetPath != null) {
        mountpoint = cfg.dataDir;
        recordsize = "128K"; # attachments: whole-file reads/writes
        compression = "zstd";
        owner = cfg.user;
        group = cfg.group;
        mode = "0750";
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.dataDir}/files 0750 ${cfg.user} ${cfg.group} - -"
      ];

      virtualisation.oci-containers.containers = {
        ${seederContainer} = {
          image = cfg.image;
          autoStart = false; # pulled in by web/worker
          user = "${toString cfg.uid}:${toString cfg.gid}";
          environment = openprojectEnvironment;
          environmentFiles = [ cfg.environmentFile ];
          volumes = commonVolumes;
          cmd = [ "./docker/prod/seeder" ];
          extraOptions = commonOptions ++ resourceOptions cfg.seeder.resources;
        };

        ${webContainer} = {
          image = cfg.image;
          autoStart = true;
          user = "${toString cfg.uid}:${toString cfg.gid}";
          environment = openprojectEnvironment;
          environmentFiles = [ cfg.environmentFile ];
          volumes = commonVolumes;
          ports = [ "${cfg.listenAddress}:${toString cfg.listenPort}:8080" ];
          cmd = [ "./docker/prod/web" ];
          extraOptions = commonOptions
            ++ resourceOptions cfg.web.resources
            ++ lib.optionals (cfg.healthcheck != null && cfg.healthcheck.enable) [
            "--health-cmd=curl -fsS http://127.0.0.1:8080/health_checks/default || exit 1"
            "--health-interval=${cfg.healthcheck.interval}"
            "--health-timeout=${cfg.healthcheck.timeout}"
            "--health-retries=${toString cfg.healthcheck.retries}"
            "--health-start-period=${cfg.healthcheck.startPeriod}"
          ];
        };

        ${workerContainer} = {
          image = cfg.image;
          autoStart = true;
          user = "${toString cfg.uid}:${toString cfg.gid}";
          environment = openprojectEnvironment;
          environmentFiles = [ cfg.environmentFile ];
          volumes = commonVolumes;
          cmd = [ "./docker/prod/worker" ];
          extraOptions = commonOptions ++ resourceOptions cfg.worker.resources;
        };
      };

      systemd.services = {
        # Migrate + seed before anything serves. RemainAfterExit keeps it
        # "active" so web/worker can Require it; restartTriggers re-runs it
        # (and so the migrations) whenever the image changes (issue #852).
        ${seederUnit} = {
          requires = preseedRequires;
          wants = dbUnits ++ cacheUnits ++ preseedWants;
          after = dbUnits ++ cacheUnits ++ preseedAfter;
          before = [ "${webUnit}.service" "${workerUnit}.service" ];
          restartTriggers = [ cfg.image ];
          unitConfig.RequiresMountsFor = [ cfg.dataDir ];
          serviceConfig = {
            Type = lib.mkForce "oneshot";
            Restart = lib.mkForce "no";
            RemainAfterExit = lib.mkForce true;
            # First boot loads the schema and seeds; allow it time.
            TimeoutStartSec = lib.mkForce "30min";
          };
        };

        ${webUnit} = {
          requires = [ "${seederUnit}.service" ] ++ preseedRequires;
          wants = dbUnits ++ cacheUnits ++ preseedWants;
          after = [ "${seederUnit}.service" ] ++ dbUnits ++ cacheUnits ++ preseedAfter;
          unitConfig.RequiresMountsFor = [ cfg.dataDir ];
        };

        ${workerUnit} = {
          requires = [ "${seederUnit}.service" ] ++ preseedRequires;
          wants = dbUnits ++ cacheUnits ++ preseedWants;
          after = [ "${seederUnit}.service" ] ++ dbUnits ++ cacheUnits ++ preseedAfter;
          unitConfig.RequiresMountsFor = [ cfg.dataDir ];
        };
      };

      modules.services.caddy.virtualHosts.${serviceName} = mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) {
        enable = true;
        hostName = cfg.reverseProxy.hostName;
        backend = {
          host = cfg.reverseProxy.backend.host or cfg.listenAddress;
          port = cfg.reverseProxy.backend.port or cfg.listenPort;
        };
        caddySecurity = cfg.reverseProxy.caddySecurity or null;
        extraConfig = cfg.reverseProxy.extraConfig or null;
      };
    })

    (mkIf (cfg.enable && cfg.preseed.enable) (
      storageHelpers.mkPreseedService {
        inherit serviceName allowEmptyBootstrap;
        dataset = datasetPath;
        mountpoint = cfg.dataDir;
        mainServiceUnit = "${seederUnit}.service";
        replicationCfg = replicationConfig;
        datasetProperties = {
          recordsize = "128K";
          compression = "zstd";
        };
        resticRepoUrl = cfg.preseed.repositoryUrl;
        resticPasswordFile = cfg.preseed.passwordFile;
        resticEnvironmentFile = cfg.preseed.environmentFile;
        resticPaths = [ cfg.dataDir ];
        restoreMethods = cfg.preseed.restoreMethods;
        hasCentralizedNotifications = (config.modules.notifications or { }).enable or false;
        owner = cfg.user;
        group = cfg.group;
      }
    ))
  ];
}
