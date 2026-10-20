# hosts/forge/services/openproject.nix
#
# OpenProject Community Edition on 'forge': the task queue for the Grok bots
# (Executive Assistant, Social Planner, Finances, Homelab Manager, Grok Bot).
# Module: modules/nixos/services/openproject/default.nix
# Runbook: docs/services/openproject.md (secrets, bootstrap, webhooks, MCP notes)
#
# Layout
# - podman: openproject-seeder (oneshot migrate+seed), openproject-web (puma,
#   2 workers), openproject-worker (GoodJob, also runs scheduled jobs)
# - PostgreSQL: shared forge instance, database `openproject` (pgBackRest)
# - Rails cache: shared forge Redis, DB index 2
# - Assets/attachments: tank/services/openproject (sanoid + syncoid + restic
#   to NAS + restic to R2)
#
# Access (see docs/services/openproject.md#access-model)
# - https://tasks.holthome.net via Caddy + Cloudflare tunnel `forge`
# - Browser UI behind PocketID (caddySecurity, admin group) as an outer gate;
#   OpenProject's own login still applies (OIDC login is Enterprise-only)
# - /api/*, /oauth/* and /health_checks/default bypass the gate: they are
#   authenticated by OpenProject itself (API tokens / OAuth bearer tokens) and
#   are what the mobile app and bot clients need

{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceName = "openproject";
  serviceEnabled = config.modules.services.openproject.enable or false;
  serviceDomain = "tasks.${domain}";
  dataset = "tank/services/${serviceName}";
  dataDir = "/var/lib/${serviceName}";
  listenPort = 8072;

  # Shared Redis DB index (see hosts/forge/services/redis.nix)
  redisDb = 2;

  # Future MCP wrapper (Ryan's own server around API v3). Disabled stub:
  # flipping this on reserves the vhost/tunnel route and the SSRF allow-list
  # entry webhooks need, but the unit below refuses to start until a real
  # package replaces the placeholder. See docs/services/openproject.md#mcp-wrapper.
  mcpEnabled = false;
  mcpDomain = "tasks-mcp.${domain}";
  mcpListenPort = 8073;
  # Webhook receiver must be reachable from the containers (podman0 gateway),
  # not just loopback; OpenProject posts to http://host.containers.internal:<port>.
  mcpWebhookPort = 8074;

  # Remove trailing newlines from SOPS placeholders
  clean = lib.strings.removeSuffix "\n";
in
{
  config = lib.mkMerge [
    {
      # Secrets are declared in ../secrets.nix; this renders the env file the
      # containers read. DB password is hex-only, so no URL encoding needed.
      sops.templates."openproject-env" = {
        content = ''
          SECRET_KEY_BASE=${clean config.sops.placeholder."openproject/secret_key_base"}
          DATABASE_URL=postgres://openproject:${clean config.sops.placeholder."openproject/database_password"}@host.containers.internal:5432/openproject?pool=10&encoding=unicode&reconnect=true
          OPENPROJECT_SEED__ADMIN__USER__PASSWORD=${clean config.sops.placeholder."openproject/admin_password"}
        '';
      };

      modules.services.openproject = {
        enable = true;
        # Official image, slim variant (no bundled Postgres/memcached/Apache).
        image = "openproject/openproject:17.9.2-slim@sha256:7b50be7ff67dd0c7e264b09e15591d5f192bbd5802c0233469ab77eaeabf03ba";
        inherit dataDir listenPort;
        datasetPath = dataset;
        hostName = serviceDomain;
        # Host-local clients (Gatus, the future MCP wrapper) call
        # http://127.0.0.1:${listenPort} directly; Rails' host authorization
        # must accept that Host header.
        additionalHostNames = [ "127.0.0.1" "localhost" ];
        environmentFile = config.sops.templates."openproject-env".path;

        cache = {
          redisUrl = "redis://host.containers.internal:6379/${toString redisDb}";
          localUnit = "redis-default.service";
        };

        # Upstream defaults to 2 workers x 4-16 threads and 20 GoodJob threads;
        # trimmed for a 6-user instance. Worst case DB connections:
        # web 2x5 + worker 5 + seeder = ~16 of PostgreSQL's 100.
        web = {
          workers = 2;
          minThreads = 2;
          maxThreads = 5;
          # Upstream minimum is 4 GB for the whole stack. Forge has ~8 GiB
          # free today; these caps bound the stack at ~4 GiB steady state.
          resources = {
            memory = "2560M";
            memoryReservation = "1G";
            cpus = "2.0";
          };
        };
        worker = {
          maxThreads = 5;
          resources = {
            memory = "1536M";
            memoryReservation = "512M";
            cpus = "1.5";
          };
        };

        # Outgoing webhooks to the host (10.88.0.1 = podman0 gateway) are only
        # needed once the MCP wrapper / bot-routine receiver exists.
        ssrfAllowlist = lib.optional mcpEnabled "10.88.0.1/32";

        extraEnvironment = {
          # Bots and Ryan are created by an admin; no self-registration.
          OPENPROJECT_SELF__REGISTRATION = "0";
          OPENPROJECT_APP__TITLE = "Holthome Tasks";
          OPENPROJECT_USER__DEFAULT__TIMEZONE = "America/New_York";
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = listenPort;
          };
          # NOTE: bypassPaths are prefix matches ("<path>*"). Use "/oauth/"
          # with the slash: a bare "/oauth" would also swallow caddy-security's
          # own /oauth2/* callback and break the PocketID login.
          caddySecurity = forgeDefaults.caddySecurity.admin // {
            bypassPaths = [ "/api/" "/oauth/" "/health_checks/default" ];
          };
        };

        backup = forgeDefaults.mkBackupWithTags serviceName [ "openproject" "tasks" "forge" ];
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
        notifications.enable = true;
      };

      # Shared PostgreSQL. OpenProject's migrations also issue
      # CREATE EXTENSION IF NOT EXISTS for these; pre-creating them as
      # superuser keeps that a no-op for the non-superuser owner role.
      modules.services.postgresql.databases.${serviceName} = {
        owner = serviceName;
        ownerPasswordFile = config.sops.secrets."openproject/database_password".path;
        extensions = [ "btree_gist" "pg_trgm" "unaccent" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # Attachments only - work packages, users, tokens and webhooks live in
      # PostgreSQL (pgBackRest, PITR). A restore must pair this dataset with a
      # database recovery point from the same time.
      modules.storage.datasets.services.${serviceName}.protection = {
        class = "standard";
        objectives = {
          onsiteRpoSeconds = 86400;
          offsiteRpoSeconds = 86400;
          rtoSeconds = 28800;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "offsite-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = null;
        # The first deploy starts from an empty dataset (the seeder creates
        # the schema in PostgreSQL; files/ is empty until something is
        # attached). Flip to false once the first backups exist so a lost
        # dataset fails closed instead of silently starting empty.
        allowEmptyBootstrap = true;
      };

      modules.backup.sanoid.datasets.${dataset} = forgeDefaults.mkSanoidDataset serviceName;

      # Offsite copy of the attachments (the DB already goes to R2 via
      # pgBackRest repo2).
      modules.services.backup.restic.jobs."${serviceName}-offsite" = {
        enable = true;
        repository = "r2-offsite";
        paths = [ dataDir ];
        tags = [ serviceName "tasks" "offsite" "forge" ];
        frequency = "daily";
        useSnapshots = true;
        zfsDataset = dataset;
      };

      modules.alerting.rules = {
        "openproject-web-down" =
          forgeDefaults.mkServiceDownAlert "openproject-web" "OpenProjectWeb" "task queue web/API";
        "openproject-worker-down" =
          forgeDefaults.mkServiceDownAlert "openproject-worker" "OpenProjectWorker" "background job worker (webhooks, notifications, scheduled jobs)";
        # Oneshot with RemainAfterExit: inactive means migrate/seed failed and
        # web/worker are being held back.
        "openproject-seeder-down" =
          forgeDefaults.mkSystemdServiceDownAlert "podman-openproject-seeder" "OpenProjectSeeder" "database migrate/seed step";
      };

      modules.services.homepage.contributions.${serviceName} = {
        group = "Productivity";
        name = "OpenProject";
        icon = "openproject";
        href = "https://${serviceDomain}";
        description = "Bot task queue";
        siteMonitor = "http://127.0.0.1:${toString listenPort}/health_checks/default";
      };

      modules.services.gatus.contributions = {
        # App liveness, independent of Caddy and the tunnel
        ${serviceName} = {
          name = "OpenProject";
          group = "Productivity";
          url = "http://127.0.0.1:${toString listenPort}/health_checks/default";
          interval = "60s";
          conditions = [ "[STATUS] == 200" ];
        };
        # End-to-end through Caddy (bypass path) - what the mobile app and
        # remote clients depend on
        "${serviceName}-external" = {
          name = "OpenProject (public)";
          group = "Productivity";
          url = "https://${serviceDomain}/health_checks/default";
          interval = "300s";
          conditions = [ "[STATUS] == 200" "[RESPONSE_TIME] < 3000" ];
        };
      };

      modules.services.caddy.virtualHosts.${serviceName}.cloudflare = {
        enable = true;
        tunnel = "forge";
      };
    })

    # ---------------------------------------------------------------------
    # MCP wrapper stub (disabled). Ryan's own MCP server around API v3:
    # per-bot API tokens, slimmed HAL+JSON, atomic claim via PATCH with
    # lockVersion (409 on conflict). Replace the placeholder unit with the
    # real package, add its secrets to ../secrets.nix, then set mcpEnabled.
    # ---------------------------------------------------------------------
    (lib.mkIf (serviceEnabled && mcpEnabled) {
      systemd.services.openproject-mcp = {
        description = "OpenProject MCP wrapper (placeholder)";
        after = [ "podman-openproject-web.service" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          OPENPROJECT_URL = "http://127.0.0.1:${toString listenPort}";
          LISTEN = "127.0.0.1:${toString mcpListenPort}";
          WEBHOOK_LISTEN = "10.88.0.1:${toString mcpWebhookPort}";
        };
        script = ''
          echo "openproject-mcp is a placeholder; ship the real server first" >&2
          exit 1
        '';
        serviceConfig = {
          Type = "simple";
          DynamicUser = true;
        };
      };

      networking.firewall.interfaces."podman0".allowedTCPPorts = [ mcpWebhookPort ];

      modules.services.caddy.virtualHosts.openproject-mcp = {
        enable = true;
        hostName = mcpDomain;
        backend = {
          host = "127.0.0.1";
          port = mcpListenPort;
        };
        # Machine clients authenticate to the MCP server itself (OAuth, as
        # in homelab-mcp.nix) - no caddySecurity browser gate.
        cloudflare = {
          enable = true;
          tunnel = "forge";
        };
      };
    })
  ];
}
