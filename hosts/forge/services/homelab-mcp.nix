# hosts/forge/services/homelab-mcp.nix
#
# Homelab MCP server — bridge that exposes selected homelab APIs
# (cooklang, gatus, future categories) as MCP tools Claude can call.
#
# Architecture (v0.2 — embedded OAuth provider, NO Cloudflare Access):
#
#   Claude (iOS / web)
#     │ Streamable HTTP + Bearer JWT
#     │
#     │ ┌─────────────────────────────────────────────────────────────┐
#     │ │ OAuth dance (one-time per Claude session):                  │
#     │ │   1. Claude POSTs /oauth/register (RFC 7591 DCR)            │
#     │ │   2. Claude GETs /oauth/authorize w/ PKCE                   │
#     │ │   3. homelab-mcp 302s to PocketID for passkey login          │
#     │ │   4. PocketID 302s back to /oauth/callback                  │
#     │ │   5. homelab-mcp 302s to Claude w/ a one-shot auth code     │
#     │ │   6. Claude POSTs /oauth/token (PKCE verifier)              │
#     │ │   7. homelab-mcp mints a 24h RS256 JWT                      │
#     │ └─────────────────────────────────────────────────────────────┘
#     ▼
#   Cloudflare Tunnel → forge → Caddy (mcp.holthome.net)
#     │ HTTP, localhost-only
#     ▼
#   homelab-mcp.service (this module)
#     │ JWTAuthMiddleware validates against own public key (no network
#     │ call per request; key is loaded once at startup)
#     │ then dispatches to a tool handler
#     ▼
#   ├── cook.holthome.net      (recipe browse / shopping list)
#   ├── fedcook.holthome.net   (federation search across 62 feeds)
#   ├── gatus.holthome.net     (uptime monitoring)
#   └── /data/cooklang/recipes/claude/  (save_recipe writes here)
#
# Tool name convention: <category>_<verb>_<object>. See
# carpenike/mcp/AGENTS.md for the registry pattern.
#
# Bootstrap (one-time):
#   1. In PocketID admin UI, create an OIDC client:
#        - Callback URL: https://mcp.holthome.net/oauth/callback
#        - Scopes: openid email profile
#      Copy the resulting Client ID and Client Secret.
#   2. Set HOMELAB_MCP_POCKETID_CLIENT_ID below to the Client ID.
#   3. Re-encrypt this host's secrets.sops.yaml with the env file
#      containing at minimum:
#        HOMELAB_MCP_POCKETID_CLIENT_SECRET=<from PocketID UI>
#      Optionally (preferred for production — key never touches disk):
#        HOMELAB_MCP_OAUTH_SIGNING_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
#   4. Cloudflare Tunnel + DNS ingress are declarative below — no
#      manual CF dashboard step required.
{ config, inputs, lib, options, pkgs, ... }:

let
  serviceName = "homelab-mcp";
  dataDir = "/var/lib/${serviceName}";
  dataset = "tank/services/${serviceName}";
  serviceDomain = "mcp.${config.networking.domain}";
  listenAddr = "127.0.0.1";
  # Upstream default is 9200 (avoids the well-known prometheus
  # node_exporter port 9100). We surface it here so the Caddy backend
  # below has a single source of truth.
  listenPort = 9200;
  actualSidecarPort = 9210;
  actualSidecarUnit = "homelab-mcp-actual-sidecar";
  actualSidecarSupported = options.services.homelab-mcp ? actualSidecar;
  actualSidecarEnabled = config.services.homelab-mcp.actualSidecar.enable or false;
  # Same rollback guard as the sidecar above: the option arrives with
  # homelab-mcp 0.21.0, and a pin predating it must still evaluate.
  financesExportSupported = options.services.homelab-mcp ? financesExport;
  financeDb = "homelab_finance";
  financeRole = "homelab-mcp-export";
  financeGrafanaRole = "grafana-household-finance";
  financeSchema = "household_finance";
  financeDashboards = import ./household-finance-dashboards.nix { inherit pkgs; };
in
{
  imports = [
    inputs.homelab-mcp.nixosModules.default
  ];

  config = lib.mkMerge [
    {
      services.homelab-mcp = {
        enable = true;
        package = inputs.homelab-mcp.packages.${pkgs.stdenv.hostPlatform.system}.default;

        host = listenAddr;
        port = listenPort;

        # Used as the OAuth issuer + JWT audience + RFC 9728 resource URL.
        # Must match the URL Cloudflare Tunnel / Caddy exposes externally.
        publicBaseUrl = "https://${serviceDomain}";

        # Cooklang recipes root, surfaced to the app only to compute
        # recipe-relative paths. The cooklang tools reach recipes over
        # cook.holthome.net's HTTP API and never touch this path on disk,
        # so no group membership / filesystem permission is required
        # (the upstream `recipesGroup` option was removed in 0.4.0).
        recipesDir = config.modules.services.cooklang.recipeDir or "/data/cooklang/recipes";

        # Non-secret declarative settings (visible in /nix/store).
        # PocketID issuer + client ID are not sensitive (the client ID
        # appears in every auth URL Claude constructs).
        settings = {
          HOMELAB_MCP_POCKETID_ISSUER = "https://id.holthome.net";
          # Client ID registered in PocketID admin UI (display name
          # also "mcp"). Not sensitive — it appears in every auth URL.
          HOMELAB_MCP_POCKETID_CLIENT_ID = "mcp";
          HOMELAB_MCP_COOKLANG_BASE_URL = "https://cook.holthome.net";
          HOMELAB_MCP_FEDERATION_BASE_URL = "https://fedcook.holthome.net";
          HOMELAB_MCP_GATUS_BASE_URL = "https://gatus.holthome.net";
          # Grocy REST API base. The /api path is intentionally exempt from
          # the PocketID gate (see hosts/forge/services/grocy.nix
          # caddySecurity.bypassPaths); the grocy_* tools authenticate with
          # the GROCY-API-KEY header sourced from the env file below.
          HOMELAB_MCP_GROCY_BASE_URL = "https://grocy.holthome.net/api";
          # Home Assistant REST/WebSocket API base. The ha.holthome.net vhost
          # is a plain reverse-proxy pass-through (no PocketID gate at Caddy),
          # so HA's own bearer-token auth gates the API. The ha_* tools
          # authenticate with the long-lived token (HOMELAB_MCP_HA_TOKEN)
          # sourced from the env file below.
          HOMELAB_MCP_HA_BASE_URL = "https://ha.holthome.net";
          # Finances and Paperless integration endpoints.
          HOMELAB_MCP_FINANCES_SIDECAR_BASE_URL = "http://127.0.0.1:${toString actualSidecarPort}";
          HOMELAB_MCP_FINANCES_REPO_URL = "https://github.com/carpenike/finances.git";
          HOMELAB_MCP_PAPERLESS_BASE_URL = "https://paperless.${config.networking.domain}";

          # Hardening (recommended once the ha_* tools can actuate a
          # physical control plane). Neither value is a secret.
          #
          # Restrict who may complete a PocketID login and mint a bearer
          # token to named users (matched against PocketID's `email`
          # claim). Empty upstream default = any PocketID user. Parsed as
          # JSON by pydantic, so this must be a JSON array literal.
          HOMELAB_MCP_OAUTH_USER_ALLOWLIST = ''["ryan@ryanholt.net", "stefanie@stefanieholt.com"]'';
          HOMELAB_MCP_RESTRICTED_SCOPE_RESOURCES = builtins.toJSON {
            advisor = [ "finances://" ];
          };
          # Actual account name -> that card's last four digits, for the
          # amazon_* matcher. The key must be the account name EXACTLY as the
          # ledger spells it; the lookup is exact-match after lowercasing.
          #
          # Load-bearing, not decoration: `exact` confidence is only reachable
          # when the matcher can verify the card, and it verifies it through
          # this map. Leave it empty and every match tops out at `probable` —
          # which is what the first real run against the ledger hit, and
          # reasonably mistook for a property of the algorithm.
          #
          # Not a secret. Four digits of a card number authorise nothing and
          # already appear in the lading store; keeping it here rather than in
          # sops means the mapping is reviewable in the config that uses it.
          HOMELAB_MCP_AMAZON_ACCOUNT_LAST4 = builtins.toJSON {
            "Chase Amazon" = "4772";
          };
          # Shrink issued bearer-token lifetime from the 24h default to 4h.
          # Refresh tokens (30d, rotated on every use) mean this does not
          # force interactive re-login — it only shortens the window a
          # leaked access token stays valid.
          HOMELAB_MCP_OAUTH_ACCESS_TOKEN_LIFETIME_SECONDS = 4 * 60 * 60;
          # Server-side dispatch boundary for Hermes. Its local include list
          # mirrors this for UX, but this middleware allowlist is authoritative.
          # Hermes v0.19 requests every advertised OAuth scope, so both local
          # aliases share this bounded read-only scope; platform_toolsets and
          # each alias's tools.include enforce their disjoint per-gateway views.
          HOMELAB_MCP_RESTRICTED_SCOPES = builtins.toJSON {
            advisor = [
              "finances_sync_status"
              "finances_monthly_summary"
              "finances_recurring"
              "finances_trend"
              "finances_debt_status"
              "finances_transactions"
              "finances_categorize"
              "finances_rules_list"
              "finances_rule_create"
              "finances_rule_delete"
              "finances_payees"
              "finances_payee_merge"
              "finances_buffer"
              "finances_breaches"
              "finances_room"
              "finances_reconcile"
              "finances_subscriptions"
              "finances_net_worth"
              "finances_payoff_projection"
              "finances_docs_get"
              "finances_context_add"
              "finances_context_list"
              "finances_context_consume"
              "finances_clarify_candidates"
              "finances_ticklers"
              # The daily 08:00 alarm, decided in code rather than in the cron
              # prompt. In BOTH scopes: hermes calls it and renders its lines,
              # and an advisor session needs the same verdict — and the
              # `evidence` behind it — to explain or challenge a morning.
              "finances_sentinel"
              "finances_decision_append"
              "finances_tickler_append"
              "finances_planned_append"
              "paperless_search"
              "paperless_get"
              "paperless_link"
              # amazon_* — what was actually in the box behind an Amazon
              # charge. The advisor needs these to categorize sensibly; it
              # calls finances_transactions, then hands the charges to
              # amazon_match_charges in one batch. Read-only against lading's
              # store; the Amazon credential is not reachable from here.
              "amazon_match_charges"
              "amazon_get_order"
              "amazon_search_items"
              "amazon_list_orders"
              "amazon_get_sync_status"
              # costco_* / samsclub_* — same rationale as amazon_*: the
              # advisor matches ledger charges to receipts. costco_* was an
              # oversight omission when the category shipped (caught during
              # the samsclub build, 2026-08-09); an advisor-scoped token
              # could not call it while unrestricted user tokens could.
              "costco_match_charges"
              "costco_get_receipt"
              "costco_list_receipts"
              "costco_search_items"
              "costco_get_sync_status"
              "costco_price_history"
              "samsclub_match_charges"
              "samsclub_get_receipt"
              "samsclub_list_receipts"
              "samsclub_search_items"
              "samsclub_get_sync_status"
              # fidelity_* — positions/summary for net-worth work; advisor
              # yes, hermes NEVER (finances repo DECISIONS 2026-08-08:
              # net-worth detail gets at least the enforcement purchase
              # history gets).
              "fidelity_positions"
              "fidelity_summary"
              "signal_send"
            ];
            # DELIBERATELY NO amazon_* HERE, and do not add them while
            # "filling out the list". Purchase history leaks gifts before they
            # are given, medical supplies, and anything anyone bought; the
            # unattended agent that composes the weekly Signal pulse has no
            # business reading it. Same reasoning that keeps school_* out.
            hermes = [
              "finances_sync_status"
              "finances_monthly_summary"
              "finances_recurring"
              "finances_debt_status"
              "finances_breaches"
              "finances_buffer"
              "finances_room"
              "finances_context_add"
              "finances_context_list"
              "finances_clarify_candidates"
              "finances_ticklers"
              # The sentinel composes the four reads above and decides; the
              # cron prompt only renders what comes back. The four sources
              # stay listed because the weekly pulse reads them directly.
              # This middleware allowlist is authoritative — the tool is
              # 403 at tools/call without it, however the alias is
              # configured client-side.
              "finances_sentinel"
              "homelab_list_status"
            ];
          };
        };

        # Sops-managed env file containing at minimum:
        #   HOMELAB_MCP_POCKETID_CLIENT_SECRET=<from PocketID admin UI>
        # Required for the grocy_* tools:
        #   HOMELAB_MCP_GROCY_API_KEY=<from Grocy → Settings → Manage API keys>
        #     Authenticates to grocy.holthome.net/api via the GROCY-API-KEY
        #     header. The /api path is exempt from PocketID at Caddy (see
        #     hosts/forge/services/grocy.nix), so the key alone gates the API.
        # Required for the ha_* tools:
        #   HOMELAB_MCP_HA_TOKEN=<long-lived access token from a dedicated HA user>
        #     Create in HA under the user's Profile → Security → Long-lived
        #     access tokens. Use a dedicated non-admin user for read/query
        #     tools; an admin user is only required if you want the HA
        #     automation/service-call tools. Sent as an Authorization: Bearer
        #     header to ha.holthome.net.
        # Required for the finances/Paperless tools:
        #   HOMELAB_MCP_FINANCES_SIDECAR_TOKEN=<shared sidecar token>
        #   HOMELAB_MCP_FINANCES_REPO_TOKEN=<GitHub token; contents:write>
        #     Stored only inside the SOPS-encrypted `homelab-mcp/env` dotenv.
        #     contents:read serves governance docs; contents:write is required
        #     for finances_decision_append and finances_planned_append.
        #   HOMELAB_MCP_FINANCES_FLOOR=<private monthly spending floor>
        #   HOMELAB_MCP_FINANCES_AMAZON_BASELINE=<private monthly Amazon baseline>
        #   HOMELAB_MCP_FINANCES_BUFFER_FLOOR=<private checking buffer floor>
        #   HOMELAB_MCP_PAPERLESS_TOKEN=<dedicated Paperless service-user token>
        # Optionally:
        #   HOMELAB_MCP_OAUTH_SIGNING_KEY=<RSA PEM, escaped \n>
        #     If absent, the service auto-generates and persists a
        #     fresh 2048-bit RSA key at /var/lib/homelab-mcp/signing-key.pem
        #     on first start.
        #   HOMELAB_MCP_OAUTH_SESSION_SECRET=<urlsafe-base64 32+ bytes>
        #     If absent, a fresh key is generated per process — fine
        #     because OAuth in-flight state TTLs out in 120s anyway.
        environmentFile = config.sops.secrets."homelab-mcp/env".path;
      };

      # The school_* tools read the schoolhouse database (owned by the
      # schoolhouse service) as a role with `readonly` membership. The DSN
      # arrives as a SECOND EnvironmentFile rather than another line in the
      # hand-maintained homelab-mcp/env dotenv, so the password can never
      # drift from the role provisioned in services/schoolhouse.nix — both
      # interpolate the same sops secret.
      #
      # NOTE: school_* is deliberately absent from the `hermes` entry in
      # HOMELAB_MCP_RESTRICTED_SCOPES below. The ambient household agent must
      # not be able to read three children's grades; interactive access is
      # already bounded by the OAuth user allowlist.
      systemd.services.homelab-mcp.serviceConfig.EnvironmentFile = lib.mkForce [
        config.sops.secrets."homelab-mcp/env".path
        config.sops.templates."homelab-mcp-schoolhouse-env".path
        config.sops.templates."homelab-mcp-lading-env".path
      ];


      # Caddy vhost — pure pass-through. Auth is enforced by the MCP
      # server itself (its own OAuth provider issues bearer tokens; the
      # JWT middleware validates them against the local public key).
      # No SSO guard at Caddy because the OAuth flow would loop if we
      # tried to add one in front.
      modules.services.caddy.virtualHosts.${serviceName} = {
        enable = true;
        hostName = serviceDomain;
        backend = {
          host = listenAddr;
          port = listenPort;
        };
        # Cloudflare Tunnel integration auto-registers
        # mcp.holthome.net → <tunnel-uuid>.cfargotunnel.com via the
        # existing networking/cloudflare/tunnel-dns-api-token sops
        # secret, and adds the ingress rule to the forge tunnel config.
        # No manual dashboard step required.
        cloudflare = {
          enable = true;
          tunnel = "forge";
        };
      };
    }

    # Keep rollback pins that predate the Actual sidecar option evaluable.
    (lib.optionalAttrs actualSidecarSupported {
      services.homelab-mcp.actualSidecar = {
        enable = true;
        serverUrl = "https://budget.${config.networking.domain}";
        environmentFile = config.sops.secrets."homelab-mcp/actual-env".path;
      };
    })

    # ── nightly finances export ───────────────────────────────────────
    # A JOB, not an MCP tool. It reads the Actual sidecar and lading and
    # projects derived metrics into its own Postgres schema for Grafana. The
    # 05:30 slot is load-bearing: after lading's overnight Amazon sync, so
    # per-person spend sees last night's orders, and before the morning sweep,
    # so the sweep and the dashboard read the same numbers.
    #
    # Same rollback guard as the sidecar above.
    (lib.optionalAttrs financesExportSupported {
      services.homelab-mcp.financesExport = {
        enable = true;
        # Local time on purpose. A UTC expression drifts an hour across DST
        # and would land the export on the wrong side of the morning sweep
        # for half the year.
        onCalendar = "*-*-* 05:30:00 America/New_York";
        # Its OWN env file, not the service's. The job needs one thing the
        # server must never hold — a database credential that can write — and
        # the server needs a PocketID client secret and a GitHub token the job
        # has no use for. Splitting them keeps each file worth exactly what it
        # opens.
        #
        # NOTE the module also needs the sidecar token and the lading DSN,
        # which live in the two files below; the unit reads all three.
        environmentFile = config.sops.templates."homelab-mcp-export-env".path;
      };

      # Order behind the database provisioner. A oneshot that starts before
      # its database exists fails loudly, which is fine once — but it would
      # fail every deploy-day morning, and that is how an alert gets trained
      # away. The sidecar ordering is already in the upstream unit; adding it
      # here again would only duplicate the dependency.
      systemd.services.homelab-mcp-finances-export = {
        after = [ "postgresql-provision-databases.service" ];
        requires = [ "postgresql-provision-databases.service" ];
        serviceConfig.EnvironmentFile = lib.mkForce [
          config.sops.templates."homelab-mcp-export-env".path
          # The sidecar token: the job reads the register over loopback and
          # the sidecar refuses an unauthenticated caller.
          config.sops.secrets."homelab-mcp/env".path
          # The lading reader DSN, for per-person Amazon attribution. Without
          # it the job still runs and files Amazon spend as unattributed,
          # recording the degradation rather than silently dropping it.
          config.sops.templates."homelab-mcp-lading-env".path
        ];
      };
    })

    # The export's DESTINATION. Declared unconditionally — it is a database,
    # not a feature flag, and provisioning it before the flake pin carrying
    # the job lands is harmless (an empty database costs nothing, and the
    # first run creates its own schema inside it).
    #
    # `owner-only`: nothing else on this host has any business reading the
    # household's balance sheet. Notably NOT `owner-readwrite+readonly-select`
    # — the cluster-wide `readonly` group is exactly that, cluster-wide, and
    # granting it here would hand every existing reader role (including the
    # one the always-on MCP server uses for Amazon history) a view of the
    # household's net worth. When a Grafana datasource is wired, give it its
    # own role and its own grant on `household_finance`.
    {
      modules.services.postgresql.databases.${financeDb} = {
        owner = financeRole;
        ownerPasswordFile = config.sops.secrets."homelab-mcp/export_db_password".path;
        permissionsPolicy = "owner-only";

        additionalRoles.${financeGrafanaRole} = {
          passwordFile = config.sops.secrets."homelab-mcp/grafana_db_password".path;
          grantRoles = [ ];
        };

        # The exporter normally creates this schema on its first run. Creating
        # it here as the exporter role makes fresh-host grants deterministic:
        # database provisioning runs before the exporter by design.
        customSql.preConfig = [
          ''
            CREATE SCHEMA IF NOT EXISTS ${financeSchema} AUTHORIZATION "${financeRole}";
            ALTER SCHEMA ${financeSchema} OWNER TO "${financeRole}";
          ''
        ];

        databasePermissions.${financeGrafanaRole} = [ "CONNECT" ];
        schemaPermissions.${financeSchema}.${financeGrafanaRole} = [ "USAGE" ];
        tablePermissions."${financeSchema}.*".${financeGrafanaRole} = [ "SELECT" ];

        # The exporter may add or replace projection tables in later releases.
        # Keep Grafana readable without granting it membership in any shared
        # cluster role or access to any schema beyond household_finance.
        defaultPrivileges.householdFinanceGrafana = {
          owner = financeRole;
          schema = financeSchema;
          tables.${financeGrafanaRole} = [ "SELECT" ];
        };

        # Visual treatment references Sure (https://github.com/we-promise/sure,
        # AGPL-3.0): restrained balance-sheet hierarchy and its green/amber/red/
        # blue finance palette. No Sure source code is copied into the suite.
        grafanaDatasources = [{
          name = "Household Finance";
          uid = "household-finance";
          integrationName = "household-finance";
          datasourceKey = "household-finance";
          credentialName = "household-finance-db-password";
          folder = "Household Finance";
          host = "127.0.0.1";
          port = 5432;
          database = financeDb;
          user = financeGrafanaRole;
          passwordFile = config.sops.secrets."homelab-mcp/grafana_db_password".path;
          sslMode = "disable";
          jsonData = {
            # Grafana 12's Postgres frontend reads the default database from
            # jsonData even though the backend still uses the top-level field.
            database = financeDb;
            postgresVersion = 1700;
            maxOpenConns = 5;
            maxIdleConns = 2;
            connMaxLifetime = 14400;
          };
          dashboards = [{
            name = "Household Finance";
            folder = "Household Finance";
            path = financeDashboards;
            attrName = "household-finance";
          }];
        }];
      };
    }

    # Service-down alert (native systemd service, not a container).
    (lib.mkIf (config.services.homelab-mcp.enable or false) (
      let
        forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
      in
      {
        systemd.services.homelab-mcp = {
          after = [ "zfs-service-datasets.service" ];
          requires = [ "zfs-service-datasets.service" ];
          unitConfig.RequiresMountsFor = [ dataDir ];
          # Streamable HTTP clients hold long-lived event streams open. Bound
          # deploy shutdowns instead of waiting systemd's 90-second default.
          serviceConfig.TimeoutStopSec = "10s";
        };

        modules.storage.datasets.services.${serviceName} = {
          mountpoint = dataDir;
          recordsize = "16K";
          compression = "zstd";
          properties = {
            atime = "off";
            "com.sun:auto-snapshot" = "true";
          };
          owner = serviceName;
          group = serviceName;
          mode = "0700";
        };

        modules.backup.sanoid.datasets.${dataset} =
          forgeDefaults.mkSanoidDataset serviceName;

        modules.services.backup.restic.jobs.${serviceName} = {
          enable = true;
          repository = forgeDefaults.backup.repository;
          paths = [ dataDir ];
          tags = [ serviceName "sqlite" "finances" "forge" ];
          frequency = "daily";
          useSnapshots = true;
          zfsDataset = dataset;
        };

        # Signal replies are the only source for this context, so retain an
        # offsite copy in addition to the standard NAS backup.
        modules.services.backup.restic.jobs."${serviceName}-offsite" = {
          enable = true;
          repository = "r2-offsite";
          paths = [ dataDir ];
          tags = [ serviceName "sqlite" "finances" "offsite" "forge" ];
          frequency = "daily";
          useSnapshots = true;
          zfsDataset = dataset;
        };

        modules.alerting.rules."homelab-mcp-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "homelab-mcp" "HomelabMCP" "Claude tools bridge";
      }
    ))

    # The sidecar enable flag also owns monitoring activation so a rollback to
    # a revision without the unit cannot leave a stale probe behind.
    (lib.mkIf actualSidecarEnabled {
      systemd.services.${actualSidecarUnit} = {
        startLimitBurst = 3;
        startLimitIntervalSec = 900;
        serviceConfig = {
          StartLimitBurst = lib.mkForce [ ];
          StartLimitIntervalSec = lib.mkForce [ ];
        };
      };

      modules.services.gatus.contributions.${actualSidecarUnit} = {
        name = "Homelab MCP Actual Sidecar";
        group = "applications";
        url = "http://127.0.0.1:${toString actualSidecarPort}/health";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[BODY].ok == true"
          "[BODY].budget_loaded == true"
          "[BODY].version_ok == true"
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
