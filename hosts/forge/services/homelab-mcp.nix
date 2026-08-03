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
              "finances_decision_append"
              "finances_tickler_append"
              "finances_planned_append"
              "paperless_search"
              "paperless_get"
              "paperless_link"
              "signal_send"
            ];
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
