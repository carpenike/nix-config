{ pkgs
, config
, lib
, ...
}:
let
  inherit (lib) optionalAttrs;

  # Use the new unified backup system (modules.services.backup)
  backupEnabled = config.modules.services.backup.enable or false;
  resticEnabled = backupEnabled && (config.modules.services.backup.restic.enable or false);
  sanoidEnabled = config.modules.backup.sanoid.enable or false;
  alertingEnabled = config.modules.alerting.enable or false;
  dispatcharrEnabled = config.modules.services.dispatcharr.enable or false;
  homeAssistantEnabled = config.modules.services.home-assistant.enable or false;
  caddyEnabled = config.modules.services.caddy.enable or false;
  cloudflaredEnabled = config.modules.services.cloudflared.enable or false;
  cooklangEnabled = config.modules.services.cooklang.enable or false;
  cooklangFederationEnabled = config.modules.services.cooklangFederation.enable or false;
  homelabMcpEnabled = config.services.homelab-mcp.enable or false;
  hermesAgentEnabled = config.services.hermes-agent.enable or false;
  grafanaEnabled = config.modules.services.grafana.enable or false;
  grafanaOncallEnabled = config.modules.services.grafana-oncall.enable or false;
  pocketIdEnabled = config.modules.services.pocketid.enable or false;
  esphomeEnabled = config.modules.services.esphome.enable or false;
  sonarrEnabled = config.modules.services.sonarr.enable or false;
  radarrEnabled = config.modules.services.radarr.enable or false;
  prowlarrEnabled = config.modules.services.prowlarr.enable or false;
  recyclarrEnabled = config.modules.services.recyclarr.enable or false;
  teslamateEnabled = config.modules.services.teslamate.enable or false;
  zigbeeEnabled = config.modules.services.zigbee2mqtt.enable or false;
  zwaveEnabled = config.modules.services."zwave-js-ui".enable or false;
  mealieEnabled = config.modules.services.mealie.enable or false;
  minifluxEnabled = config.modules.services.miniflux.enable or false;
  n8nEnabled = config.modules.services.n8n.enable or false;
  openWebuiEnabled = config.modules.services.open-webui.enable or false;
  paperlessEnabled = config.modules.services.paperless.enable or false;
  paperlessAiEnabled = config.modules.services.paperless-ai.enable or false;
  emqxEnabled = config.modules.services.emqx.enable or false;
  sabnzbdEnabled = config.modules.services.sabnzbd.enable or false;
  actualEnabled = config.modules.services.actual.enable or false;
  filebrowserQuantumEnabled = config.modules.services.filebrowserQuantum.enable or false;
  autobrrEnabled = config.modules.services.autobrr.enable or false;
  quiEnabled = config.modules.services.qui.enable or false;
  unpackerrEnabled = config.modules.services.unpackerr.enable or false;
  whiskeyWhiskeyWhiskeyEnabled = config.services.whiskey-whiskey-whiskey.enable or false;
  ambitEnabled = config.services.ambit.enable or false;
  schoolhouseEnabled = config.services.schoolhouse.enable or false;
  ladingEnabled = config.services.lading.enable or false;
  # Opt-in: Partiful calendar sync for whiskey-whiskey-whiskey. See
  # hosts/forge/services/whiskeywhiskeywhiskey.nix for setup steps.
  # When true, the partiful_calendar_url SOPS key is required to exist.
  whiskeyWhiskeyWhiskeyPartifulEnabled = true;
  # Opt-in: Plex token for the whiskey `capture_plex_keys` MCP tool
  # (HOF-039). When true, the plex_token SOPS key is required to exist.
  # Setup: generate a SCOPED / managed-user Plex token (NOT the admin
  # token) per upstream's least-privilege guidance, encrypt it via
  #   sops hosts/forge/secrets.sops.yaml
  # under `whiskey-whiskey-whiskey: plex_token: ...`, then flip this to
  # true and `task nix:apply-nixos host=forge`. Unset = the MCP tool
  # degrades to "use the host `npm run capture:plex` CLI instead".
  whiskeyWhiskeyWhiskeyPlexEnabled = true;
  # Opt-in: Pushover host-push for the whiskey outbox auto-stage cron
  # (HOF-054). When the daily outbox tick stages auto-drafts, the bunker
  # sends ONE best-effort Pushover push so the host learns drafts are
  # waiting (a pointer to the review surface, never an approval path;
  # nothing is ever sent to guests). Upstream requires BOTH
  # WWW_PUSHOVER_TOKEN and WWW_PUSHOVER_USER or the feature no-ops.
  #
  # Channel separation: whiskey uses its OWN Pushover *application token*
  # (whiskey-whiskey-whiskey/pushover_token) so its pushes land on a
  # distinct channel (own name/icon/sound) instead of being intermixed
  # with Alertmanager/Gatus/Grafana traffic. The *recipient* is still the
  # shared homelab user-key (pushover/user-key) — same person/devices —
  # which is only declared when alerting is enabled. Setup: in Pushover
  # create an Application/API Token (e.g. "W.W.W. Bunker"), then
  #   sops hosts/forge/secrets.sops.yaml
  # and add under `whiskey-whiskey-whiskey: pushover_token: ...`.
  # Flip to false to suppress the push entirely.
  whiskeyWhiskeyWhiskeyPushoverEnabled = true;
  # Opt-in: op cover-image generation (HOF-063). The non-secret provider
  # selector lives in the service settings (IMAGE_GEN_PROVIDER, default
  # gemini); these toggles supply the provider API keys. Upstream resolves
  # the key for whichever provider a call uses (the IMAGE_GEN_PROVIDER
  # default OR a per-call `provider` override on the generate_op_cover MCP
  # tool), so all three keys can be present at once and per-call provider
  # switching works for any provider whose key is enabled here. Each key is
  # independently rotatable and renders its matching *_API_KEY env var only
  # when its toggle is true and the SOPS value exists. Enable gemini by
  # default (the locked HOF-063 default); flip openai/openrouter on to also
  # allow per-call overrides to those providers.
  whiskeyWhiskeyWhiskeyImageGenGeminiEnabled = true;
  whiskeyWhiskeyWhiskeyImageGenOpenaiEnabled = true;
  whiskeyWhiskeyWhiskeyImageGenOpenrouterEnabled = true;
  # NOTE: PARTIFUL_FIREBASE_AUTH was removed 2026-05-18. As of upstream
  # commit 7703b7b4 ("strict per-caller credential routing; remove
  # env-var + cross-host fallbacks") the Fastify server no longer reads
  # this env var at runtime. Per-host Partiful credentials are bound
  # exclusively via the in-app /me/partiful UI, encrypted at rest with
  # WWW_TOKEN_KEY (AAD-bound to the user). The env var only survives as
  # a dev/recon-script convenience that doesn't apply on forge.
  marginaliaEnabled = config.services.marginalia.enable or false;
  replogEnabled = config.services.replog.enable or false;
  homepageEnabled = config.modules.services.homepage.enable or false;
  plexEnabled = config.modules.services.plex.enable or false;
  scryptedEnabled = config.modules.services.scrypted.enable or false;
  tautulliEnabled = config.modules.services.tautulli.enable or false;
  tracearrEnabled = config.modules.services.tracearr.enable or false;
  tududiEnabled = config.modules.services.tududi.enable or false;
  litellmEnabled = config.modules.services.litellm.enable or false;
  atticPushEnabled = config.modules.services.attic-push.enable or false;
  pinchflatEnabled = config.modules.services.pinchflat.enable or false;
  kometaEnabled = config.modules.services.kometa.enable or false;
  searxngEnabled = config.modules.services.searxng.enable or false;
  githubRunnerEnabled = config.modules.services.github-runner.enable or false;
  postgresqlEnabled =
    (config.modules.services.postgresql.enable or false)
    || (config.services.postgresql.enable or false);
  r2CredentialsEnabled = resticEnabled || postgresqlEnabled;
  beszelAgentEnabled = config.modules.services.beszel.agent.enable or false;
  upsEnabled = config.power.ups.enable or false;
in
{
  config = {
    environment.systemPackages = [
      pkgs.sops
      pkgs.age
    ];

    sops = {
      defaultSopsFile = ./secrets.sops.yaml;
      age.sshKeyPaths = [
        "/etc/ssh/ssh_host_ed25519_key"
      ];
      secrets =
        { }
        // optionalAttrs resticEnabled {
          # Restic backup password (used for local NFS and R2 encryption)
          "restic/password" = {
            mode = "0400";
            owner = "restic-backup";
            group = "restic-backup";
          };

        }
        // optionalAttrs esphomeEnabled {
          "esphome/secrets.yaml" = {
            mode = "0400";
            owner = "esphome";
            group = "esphome";
            restartUnits = [ "esphome-sync-secrets.service" "podman-esphome.service" ];
          };
        }
        // optionalAttrs atticPushEnabled {
          # Attic binary cache push token for automatic cache population
          "attic/push-token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs r2CredentialsEnabled {
          # Cloudflare R2 API credentials for offsite backups
          # Bucket: nix-homelab-prod-servers (forge, luna, nas-1)
          # Contains: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (R2 is S3-compatible)
          # Security: Scoped token with access ONLY to production-servers bucket
          # Used by: restic-backup service AND pgBackRest (postgres user needs read access)
          "restic/r2-prod-env" = {
            mode = "0440";
            owner = "restic-backup";
            group = "restic-backup";
          };

          # Future: additional R2 credential files live here as well
        }
        // optionalAttrs sanoidEnabled {
          # ZFS replication SSH key
          # Ephemeral secret (preferred): do not set a persistent path so sops-nix
          # writes the decrypted key under /run/secrets and we reference it via
          # config.sops.secrets."zfs-replication/ssh-key".path
          "zfs-replication/ssh-key" = {
            mode = "0600";
            owner = "zfs-replication";
            group = "zfs-replication";
          };
        }
        // optionalAttrs alertingEnabled {
          # Pushover notification credentials (for Alertmanager)
          # Alertmanager needs to read these files
          "pushover/token" = {
            mode = "0440";
            owner = "root";
            group = "alertmanager";
          };
          "pushover/user-key" = {
            mode = "0440";
            owner = "root";
            group = "alertmanager";
          };

          # Healthchecks.io webhook URL for dead man's switch
          "monitoring/healthchecks-url" = {
            mode = "0440";
            owner = "root";
            group = "alertmanager";
          };
        }
        // optionalAttrs beszelAgentEnabled {
          # Beszel agent SSH key (generated in hub UI)
          # Used by agent to authenticate with hub for metrics push
          "beszel/agent-key" = {
            mode = "0400";
            owner = "beszel-agent";
            group = "beszel-agent";
            restartUnits = [ "beszel-agent.service" ];
          };
        }
        // optionalAttrs dispatcharrEnabled {
          # PostgreSQL database passwords
          # Group-readable so postgresql-provision-databases.service (runs as postgres user)
          # can hash the file for change detection. PostgreSQL server reads via pg_read_file()
          # which has superuser privileges and doesn't need filesystem permissions.
          "postgresql/dispatcharr_password" = {
            mode = "0440"; # owner+group read
            owner = "root";
            group = "postgres";
          };
        }
        // optionalAttrs homeAssistantEnabled {
          "postgresql/home-assistant_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "home-assistant/env" = {
            mode = "0400";
            owner = "hass";
            group = "hass";
            restartUnits = [ "home-assistant.service" ];
          };

          "home-assistant/mqtt-password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Bearer token for development/scripting (VS Code, Copilot, etc.)
          # Readable by ryan for interactive use
          "home-assistant/bearer-token" = {
            mode = "0400";
            owner = "ryan";
            group = "users";
          };
        }
        // optionalAttrs caddyEnabled {
          # Cloudflare API token for Caddy DNS-01 ACME challenges
          # Reusing the same token structure as Luna for consistency
          "networking/cloudflare/ddns/apiToken" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };

          # Loki Basic Auth password hash for Caddy reverse proxy (environment variable)
          "services/caddy/environment/loki-admin-bcrypt" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };

          # Prometheus API key for backup taskfile (used by Caddy static API key auth)
          "prometheus/api-keys/backup-taskfile" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };

          # Loki Basic Auth password hash for Caddy reverse proxy (file-based)
          "caddy/loki-admin-bcrypt" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };
        }
        // optionalAttrs cloudflaredEnabled {
          # Cloudflare Tunnel credentials (JSON file)
          # Contains: AccountTag, TunnelSecret, TunnelID, TunnelName
          # Created via: cloudflared tunnel create forge
          "networking/cloudflare/forge-credentials" = {
            mode = "0400";
            owner = config.users.users.cloudflared.name;
            group = config.users.groups.cloudflared.name;
          };

          "networking/cloudflare/origin-cert" = {
            mode = "0400";
            owner = config.users.users.cloudflared.name;
            group = config.users.groups.cloudflared.name;
          };

          # Cloudflare API token used by the tunnel's DNS automation helper.
          # Required permissions: Zone -> DNS -> Edit
          # Required zone resources: every zone that has a vhost routed through
          # the forge tunnel (currently holthome.net + whiskeywhiskeywhiskey.org).
          # Distinct from networking/cloudflare/ddns/apiToken (Caddy ACME); kept
          # separate so each consumer can be rotated independently.
          "networking/cloudflare/tunnel-dns-api-token" = {
            mode = "0400";
            owner = config.users.users.cloudflared.name;
            group = config.users.groups.cloudflared.name;
          };

          # Homepage widget credentials
          # API token requires: Account.Cloudflare Tunnel:Read permission
          # Account ID can be found in Cloudflare dashboard URL or forge-credentials JSON (AccountTag)
          "networking/cloudflare/homepage-api-token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "networking/cloudflare/account-id" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs cooklangEnabled {
          "resilio/cooklang-secret" = {
            mode = "0400";
            owner = "rslsync";
            group = config.modules.services.cooklang.group;
          };
        }
        // optionalAttrs (cooklangEnabled && (config.modules.services.cooklang.git.enable or false)) {
          "cooklang/git-deploy-key" = {
            mode = "0400";
            owner = config.modules.services.cooklang.user;
            group = config.modules.services.cooklang.group;
          };
        }
        // optionalAttrs homelabMcpEnabled {
          # Env file for homelab-mcp. Contains the PocketID OIDC client
          # secret (required) and optionally the OAuth RSA signing key
          # + session secret. Format is a plain dotenv consumable by
          # systemd's EnvironmentFile=. The MCP service runs as the
          # `homelab-mcp` system user managed by the upstream module.
          #
          # Minimum content (re-encrypt via `sops hosts/forge/secrets.sops.yaml`):
          #   HOMELAB_MCP_POCKETID_CLIENT_SECRET=<from PocketID admin UI>
          # Optional:
          #   HOMELAB_MCP_FINANCES_SIDECAR_TOKEN=<shared Actual sidecar token>
          #   HOMELAB_MCP_FINANCES_REPO_TOKEN=<GitHub token; contents:write>
          #   HOMELAB_MCP_FINANCES_FLOOR=<private monthly spending floor>
          #   HOMELAB_MCP_FINANCES_AMAZON_BASELINE=<private monthly Amazon baseline>
          #   HOMELAB_MCP_FINANCES_BUFFER_FLOOR=<private checking buffer floor>
          #   HOMELAB_MCP_PAPERLESS_TOKEN=<dedicated Paperless service-user token>
          #   HOMELAB_MCP_OAUTH_SIGNING_KEY=<RSA private PEM, escaped \n>
          #   HOMELAB_MCP_OAUTH_SESSION_SECRET=<urlsafe-base64 32+ bytes>
          "homelab-mcp/env" = {
            mode = "0400";
            owner = "homelab-mcp";
            group = "homelab-mcp";
            restartUnits = [ "homelab-mcp.service" ];
          };

          # Actual sidecar credentials. This dotenv is consumed only by the
          # homelab-mcp Actual sidecar unit.
          # Required keys: ACTUAL_PASSWORD, ACTUAL_BUDGET_SYNC_ID,
          # ACTUAL_ENCRYPTION_PASSWORD, and SIDECAR_TOKEN. SIDECAR_TOKEN must
          # equal HOMELAB_MCP_FINANCES_SIDECAR_TOKEN in homelab-mcp/env.
          "homelab-mcp/actual-env" = {
            mode = "0400";
            owner = "homelab-mcp";
            group = "homelab-mcp";
          };
        }
        // optionalAttrs cooklangFederationEnabled {
          "github/cooklang-token" = {
            mode = "0400";
            owner = config.modules.services.cooklangFederation.user;
            group = config.modules.services.cooklangFederation.group;
          };
        }
        // optionalAttrs grafanaEnabled {
          # Grafana admin password
          "grafana/admin-password" = {
            mode = "0400";
            owner = "grafana";
            group = "grafana";
          };

          # Grafana OIDC client secret (must match identity provider)
          "grafana/oidc_client_secret" = {
            mode = "0400";
            owner = "grafana";
            group = "grafana";
          };
        }
        // optionalAttrs grafanaOncallEnabled {
          # Grafana OnCall Django secret key (32+ characters for encryption)
          "grafana-oncall/secret_key" = {
            mode = "0400";
            owner = "grafana-oncall";
            group = "grafana-oncall";
          };

          # Grafana OnCall Prometheus metrics exporter secret
          # Owned by prometheus so Prometheus can scrape OnCall metrics
          "grafana-oncall/metrics_secret" = {
            mode = "0400";
            owner = "prometheus";
            group = "prometheus";
          };

          # Grafana OnCall Alertmanager integration webhook URL
          # Used by Alertmanager to send alerts to OnCall
          "grafana-oncall/alertmanager-webhook-url" = {
            mode = "0400";
            owner = "alertmanager";
            group = "alertmanager";
          };
        }
        // optionalAttrs pocketIdEnabled {
          # Pocket ID secrets
          "pocketid/environment" = {
            mode = "0400";
            owner = "pocket-id";
            group = "pocket-id";
          };

          "pocketid/encryption_key" = {
            mode = "0400";
            owner = "pocket-id";
            group = "pocket-id";
          };

          "pocketid/smtp_password" = {
            mode = "0400";
            owner = "pocket-id";
            group = "pocket-id";
          };

          "caddy/pocket-id-client-secret" = {
            mode = "0400";
            owner = "caddy";
            group = "caddy";
          };
        }
        // optionalAttrs sonarrEnabled {
          # *arr service API keys (for cross-service integration)
          # Sonarr injects these via SONARR__AUTH__APIKEY env vars
          "sonarr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs radarrEnabled {
          "radarr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs prowlarrEnabled {
          "prowlarr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs plexEnabled {
          # Plex token for API access (used by Homepage widget)
          # Get token from: https://www.plexopedia.com/plex-media-server/general/plex-token/
          "plex/token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs pinchflatEnabled {
          # Pinchflat environment variables
          # Contains: SECRET_KEY_BASE (required, generate with: openssl rand -hex 64)
          #           YOUTUBE_API_KEY (optional, for faster metadata fetching)
          "pinchflat/env" = {
            mode = "0400";
            owner = "pinchflat";
            group = "media";
            restartUnits = [ "pinchflat.service" ];
          };
        }
        // optionalAttrs actualEnabled {
          # Actual Budget OIDC client secret from PocketID
          # Create client at: id.holthome.net with redirect URI:
          # https://budget.holthome.net/openid/callback
          "actual/oidc-client-secret" = {
            mode = "0400";
            owner = "actual";
            group = "actual";
            restartUnits = [ "actual.service" ];
          };
        }
        // optionalAttrs filebrowserQuantumEnabled {
          "filebrowser-quantum/oidc-client-secret" = {
            mode = "0400";
            owner = "filebrowser-quantum";
            group = "media";
            restartUnits = [ "filebrowser-quantum.service" ];
          };
        }
        // optionalAttrs tautulliEnabled {
          # Tautulli API key for Homepage widget
          # Get from: Tautulli Settings > Web Interface > API
          "tautulli/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs kometaEnabled {
          # TMDb API key for Kometa metadata lookups
          # Get from: https://www.themoviedb.org/settings/api
          "tmdb/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Trakt API credentials for Kometa list integration
          # Create app at: https://trakt.tv/oauth/applications/new
          "trakt/client-id" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "trakt/client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs homepageEnabled {
          # Mikrotik API password for Homepage widget
          # Created on Mikrotik: /user add name=homepage group=read password=xxx
          "mikrotik/homepage-password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Omada SDN Controller credentials for Homepage widget
          # Create a read-only user in Omada controller: Settings -> Admins -> Add Admin
          "omada/homepage-username" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "omada/homepage-password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs teslamateEnabled {
          "teslamate/database_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "teslamate/encryption_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "teslamate/grafana_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "teslamate/mqtt_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs tracearrEnabled {
          # MaxMind GeoIP license key for IP geolocation
          "tracearr/maxmind_license_key" = {
            mode = "0400";
            owner = "tracearr";
            group = "tracearr";
          };

          # Database password for external PostgreSQL
          # group=postgres and mode=0440 required so postgresql-provision-databases can read it
          "tracearr/db_password" = {
            mode = "0440";
            owner = "tracearr";
            group = "postgres";
          };

          # JWT secret for authentication tokens (external mode)
          # Generate with: openssl rand -hex 32
          "tracearr/jwt_secret" = {
            mode = "0400";
            owner = "tracearr";
            group = "tracearr";
          };

          # Cookie secret for session management (external mode)
          # Generate with: openssl rand -hex 32
          "tracearr/cookie_secret" = {
            mode = "0400";
            owner = "tracearr";
            group = "tracearr";
          };
        }
        // optionalAttrs tududiEnabled {
          # Initial admin password for Tududi
          # Generate with: openssl rand -base64 32
          "tududi/admin_password" = {
            mode = "0400";
            owner = "tududi";
            group = "tududi";
          };

          # Django session secret for Tududi
          # Generate with: openssl rand -hex 64
          "tududi/session_secret" = {
            mode = "0400";
            owner = "tududi";
            group = "tududi";
          };
        }
        // optionalAttrs zigbeeEnabled {
          "zigbee2mqtt/mqtt_password" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };

          "zigbee2mqtt/network_key" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };

          "zigbee2mqtt/pan_id" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };

          "zigbee2mqtt/ext_pan_id" = {
            mode = "0400";
            owner = "zigbee2mqtt";
            group = "zigbee2mqtt";
          };
        }
        // optionalAttrs zwaveEnabled {
          "zwave-js-ui/mqtt_password" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/session_secret" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s0_legacy_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_unauthenticated_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_authenticated_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_access_control_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_long_range_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };

          "zwave-js-ui/s2_long_range_access_control_key" = {
            mode = "0400";
            owner = "zwave-js-ui";
            group = "zwave-js-ui";
          };
        }
        // optionalAttrs scryptedEnabled {
          # Scrypted MQTT password for Home Assistant integration
          # Scrypted runs as root in the container, so root ownership is appropriate
          "scrypted/mqtt_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs mealieEnabled {
          # Mealie service secrets
          "mealie/database_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "mealie/smtp_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "mealie/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "mealie/openai_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs minifluxEnabled {
          # Miniflux RSS reader secrets
          # Admin credentials file (env format: ADMIN_USERNAME=xxx\nADMIN_PASSWORD=xxx)
          # Disable adminCredentials.enable after OIDC admin is linked
          "miniflux/admin_credentials" = {
            mode = "0400";
            owner = "miniflux";
            group = "miniflux";
          };

          # OIDC client secret from PocketID
          "miniflux/oidc_client_secret" = {
            mode = "0400";
            owner = "miniflux";
            group = "miniflux";
          };
        }
        // optionalAttrs n8nEnabled {
          # n8n workflow automation secrets
          # Environment file format: N8N_ENCRYPTION_KEY=<hex-key>
          # Generate with: echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)"
          # CRITICAL: This key encrypts stored credentials - MUST be backed up!
          "n8n/encryption_key_env" = {
            mode = "0400";
            owner = "n8n";
            group = "n8n";
          };
        }
        // optionalAttrs openWebuiEnabled {
          # Open WebUI service secrets - OIDC is always required when enabled
          "open-webui/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (openWebuiEnabled && (config.modules.services.open-webui.azure.enable or false)) {
          # Azure OpenAI API key (only when Azure provider enabled)
          "open-webui/azure_openai_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (openWebuiEnabled && (config.modules.services.open-webui.anthropic.enable or false)) {
          # Anthropic API key (only when Anthropic provider enabled)
          "open-webui/anthropic_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (openWebuiEnabled && (config.modules.services.open-webui.openai.enable or false)) {
          # OpenAI API key (only when OpenAI provider enabled)
          "open-webui/openai_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs searxngEnabled {
          # SearXNG secret key for CSRF protection (environment file format)
          "searxng/secret-key" = {
            mode = "0400";
            owner = "searx";
            group = "searx";
          };
        }
        // optionalAttrs litellmEnabled {
          # LiteLLM AI Gateway secrets
          # Uses PostgreSQL for spend tracking, virtual keys, and user management

          # Provider API keys (environment file format)
          # Contains: AZURE_API_KEY, ANTHROPIC_API_KEY, GOOGLE_API_KEY, OPENAI_API_KEY
          "litellm/provider-keys" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # PostgreSQL database password (litellm user)
          "litellm/database_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          # Master key for API authentication (optional - auto-generated if not set)
          "litellm/master_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # OIDC client secret for Admin UI SSO (PocketID)
          "litellm/oidc-client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs paperlessEnabled {
          # Paperless-ngx service secrets
          "paperless/database_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          "paperless/admin_password" = {
            mode = "0400";
            owner = "paperless";
            group = "paperless";
          };

          "paperless/oidc_client_secret" = {
            mode = "0400";
            owner = "paperless";
            group = "paperless";
          };
        }
        // optionalAttrs paperlessAiEnabled {
          # Paperless-AI service secrets
          # API token for accessing Paperless-ngx (generate in Paperless admin)
          "paperless-ai/paperless_token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Anthropic API key used directly by Paperless-AI
          "paperless-ai/llm_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # API key for paperless-ai's own REST API (secures its endpoints)
          "paperless-ai/api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs emqxEnabled {
          "emqx/dashboard_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs sabnzbdEnabled {
          "sabnzbd/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "sabnzbd/usenet/username" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "sabnzbd/usenet/password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs autobrrEnabled {
          "autobrr/session-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "autobrr/oidc-client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "autobrr/api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs hermesAgentEnabled {
          # Dedicated Anthropic API key for native Claude inference.
          "hermes-agent/anthropic-api-key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Raw Signal internal group ID for the isolated Advisor Test chat.
          "hermes-agent/advisor-test-group-id" = {
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "hermes-agent.service" ];
          };

          # Dedicated BotFather token for the Hermes Telegram adapter.
          "hermes-agent/telegram-bot-token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Confidential Homelab MCP client secret for the read-only `hermes`
          # OAuth scope. Projected into the root-only Hermes env template.
          "hermes-agent/homelab-mcp-oauth-client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Least-privilege projection of the three HOMELAB_MCP_SIGNAL_*
          # values into Hermes's native SIGNAL_* names. The canonical group
          # send target is `group.` plus Base64 of signal-cli's raw Base64
          # groupInfo.groupId, so the Hermes projection strips the prefix and
          # decodes the suffix exactly once. SIGNAL_ALLOWED_USERS currently
          # contains Ryan only; append the partner number here when supplied.
          # Do not pass the full homelab-mcp env to Hermes.
          "hermes-agent/signal-env" = {
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [
              "hermes-agent.service"
              "hermes-agent-weekly-pulse-seed.service"
              "hermes-agent-daily-finance-sentinel-seed.service"
            ];
          };
        }
        // optionalAttrs whiskeyWhiskeyWhiskeyEnabled {
          # Operation W.W.W. secrets. All seven are required at service start.
          # See hosts/forge/services/whiskeywhiskeywhiskey.nix for setup steps.
          # Assembled into a single EnvironmentFile via the sops.templates entry
          # "whiskey-whiskey-whiskey-env" below.
          "whiskey-whiskey-whiskey/anthropic_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "whiskey-whiskey-whiskey/api_token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "whiskey-whiskey-whiskey/session_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "whiskey-whiskey-whiskey/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # AES-256-GCM key (64-char hex / 32 bytes) for encrypting
          # per-host Partiful refresh tokens stored in the app DB.
          # Generated via `openssl rand -hex 32`. Rotating it forces
          # every host to re-bind via the /me/partiful UI; the legacy
          # PARTIFUL_FIREBASE_AUTH env-var fallback is unaffected.
          "whiskey-whiskey-whiskey/token_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # HMAC-SHA256 key (64-char hex / 32 bytes) for signing the
          # 5-word share-URL keys used by the public-op share page
          # (/o/:slug/:keywords). Generated via `openssl rand -hex 32`.
          # Rotating it invalidates every share URL in the wild.
          # Independent blast radius from token_key and session_secret
          # by design.
          "whiskey-whiskey-whiskey/public_token_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # HMAC-SHA256 key (64-char hex / 32 bytes) for signing the
          # 5-minute preview→commit confirm tokens minted by every
          # Partiful write tool (send_partiful_blast, post_partiful_activity,
          # invite_partiful_guests, delete_partiful_event,
          # create_partiful_event). Server REFUSES TO START without it.
          # Generated via `openssl rand -hex 32`. Rotating it invalidates
          # any in-flight preview tokens (5-minute window); sessions,
          # stored Partiful credentials, and public op URLs are unaffected.
          # Independent blast radius from the other WWW_*_KEY env vars
          # by design.
          "whiskey-whiskey-whiskey/gate_token_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (whiskeyWhiskeyWhiskeyEnabled && whiskeyWhiskeyWhiskeyPartifulEnabled) {
          # Partiful personal ICS calendar feed URL. Treated as a credential
          # per upstream warning. Consumed via the env template below.
          "whiskey-whiskey-whiskey/partiful_calendar_url" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (whiskeyWhiskeyWhiskeyEnabled && whiskeyWhiskeyWhiskeyPlexEnabled) {
          # Scoped Plex token for the `capture_plex_keys` MCP tool (HOF-039).
          # App-global (Anthropic-key trust tier), NOT the per-host Partiful
          # pattern. Use a SCOPED / managed-user token, never the admin
          # token, to keep the server's blast radius small. Consumed via the
          # env template below.
          "whiskey-whiskey-whiskey/plex_token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (whiskeyWhiskeyWhiskeyEnabled && whiskeyWhiskeyWhiskeyPushoverEnabled) {
          # Dedicated Pushover *application token* for the whiskey outbox
          # auto-stage push (HOF-054). Gives whiskey its own channel
          # (name/icon/sound) distinct from the shared homelab alerting
          # application. The recipient stays the shared pushover/user-key,
          # so only the token lives here. Create it in Pushover → Create an
          # Application/API Token. Consumed via the env template below.
          "whiskey-whiskey-whiskey/pushover_token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (whiskeyWhiskeyWhiskeyEnabled && whiskeyWhiskeyWhiskeyImageGenGeminiEnabled) {
          # Gemini API key for op cover-image generation (HOF-063). Plain
          # Gemini API key (no Vertex/GCP project). Maps to GEMINI_API_KEY in
          # the env template. A platform-side spend cap is recommended as
          # defense in depth. Consumed via the env template below.
          "whiskey-whiskey-whiskey/gemini_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (whiskeyWhiskeyWhiskeyEnabled && whiskeyWhiskeyWhiskeyImageGenOpenaiEnabled) {
          # OpenAI API key for op cover-image generation (HOF-063). Maps to
          # OPENAI_API_KEY in the env template; only needed if a generate_op_cover
          # call uses provider=openai. Consumed via the env template below.
          "whiskey-whiskey-whiskey/openai_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs (whiskeyWhiskeyWhiskeyEnabled && whiskeyWhiskeyWhiskeyImageGenOpenrouterEnabled) {
          # OpenRouter API key for op cover-image generation (HOF-063). Maps to
          # OPENROUTER_API_KEY in the env template; only needed if a
          # generate_op_cover call uses provider=openrouter. Consumed via the
          # env template below.
          "whiskey-whiskey-whiskey/openrouter_api_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs ambitEnabled {
          # Password for the dedicated Ambit PostgreSQL role. Keep this value
          # URL-safe because it is interpolated into DATABASE_URL below.
          # Group readability is required by the database provisioning unit.
          "ambit/db_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          # Shared household browser login passphrase.
          "ambit/passphrase" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Cookie signing secret; generate with `openssl rand -hex 48`.
          "ambit/session_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Secret for Ambit's dedicated PocketID OIDC client.
          "ambit/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs schoolhouseEnabled {
          # Schoolhouse — Schoology parent-account ingest.
          #
          # Everything here is either a credential or an identifier for a
          # minor, which is why none of it lives in services/schoolhouse.nix:
          # the Nix store is world-readable and this flake is public.

          # Owner password for the `schoolhouse` Postgres role. group=postgres
          # so postgresql-provision-databases can read it at activation.
          "schoolhouse/db_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          # Parent Schoology login (app.schoology.com — the NATIVE parent
          # account created with a 12-digit Parent Access Code, not an FCPS
          # SSO account).
          "schoolhouse/schoology_username" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
          "schoolhouse/schoology_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # JSON object mapping Schoology child uid -> display name, e.g.
          #   {"12345678":"First","23456789":"Second"}
          # The uids come from /iapi/parent/info; the service overwrites the
          # names from Schoology on the first run, so these are only a
          # bootstrap. Secret because they identify minors.
          "schoolhouse/children" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Password for the `homelab-mcp` login role on the schoolhouse
          # database (readonly membership: SELECT only). Consumed by the
          # school_* tools in homelab-mcp via the template below.
          # group=postgres so postgresql-provision-databases can read it.
          "schoolhouse/reader_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          # JSON object mapping child uid -> per-child iCal share URL, or {}.
          # These are CAPABILITY URLs: anyone holding one reads that child's
          # calendar without authenticating. Treat exactly like a password.
          "schoolhouse/ical_feeds" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs ladingEnabled {
          # lading — Amazon order + transaction ingest.
          #
          # The Amazon credential below is the sharpest secret on this host:
          # username + password + TOTP seed CAN PLACE ORDERS AND CHANGE
          # SHIPPING ADDRESSES. There is no read-only Amazon account and no
          # scoped token. It is deliberately NOT in homelab-mcp's environment
          # file — see hosts/forge/services/lading.nix for the reasoning.

          # Owner password for the `lading` Postgres role. Any strong random
          # value; keep it URL-SAFE because it is interpolated into
          # LADING_DATABASE_URL below — `openssl rand -hex 32` is safe,
          # `-base64 32` is NOT (it emits +, / and =, which change the meaning
          # of a URL userinfo field and yield a confusing connect failure).
          # group=postgres so postgresql-provision-databases can read it at
          # activation.
          "lading/db_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          # Password for the `homelab-mcp` login role on the lading database
          # (readonly membership: SELECT only). Consumed by the amazon_* tools
          # in homelab-mcp. Also URL-safe — `openssl rand -hex 32`.
          # group=postgres so provisioning can read it.
          "lading/reader_password" = {
            mode = "0440";
            owner = "root";
            group = "postgres";
          };

          # ── per-account Amazon credentials ────────────────────────
          # Namespaced by account, so a second account is symmetric with the
          # first rather than a differently-shaped special case:
          #
          #   lading/db_password        shared — ONE database
          #   lading/reader_password    shared — ONE readonly role
          #   lading/<account>/amazon_*  per account
          #
          # The two above are genuinely shared (every account writes to the
          # same store and homelab-mcp reads all of it through one role);
          # everything below belongs to exactly one Amazon login. Rendering
          # them as nested YAML also means `sops hosts/forge/secrets.sops.yaml`
          # shows one block per account, which is what you want when adding
          # the second one.

          # Amazon account email.
          "lading/ryan/amazon_username" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Amazon account password.
          "lading/ryan/amazon_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Base32 TOTP seed from Login & Security -> Two-Step Verification
          # -> Authenticator App -> "Can't scan the barcode?". Amazon displays
          # it in space-separated groups; upstream normalises spaces, quotes
          # and hyphens and validates it as base32 at startup, so paste it
          # however Amazon shows it.
          #
          # WITHOUT this an OTP challenge cannot be solved unattended and the
          # timer run fails rather than prompting.
          "lading/ryan/amazon_otp_secret_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Costco warehouse receipts for this account — a SECOND, unrelated
          # credential, and much milder than the Amazon one above: it reads
          # order history and cannot place an order or change an address.
          #
          # The value is the JSON blob captured from a signed-in browser:
          #
          #   {"oid": "...", "client_id": "...", "refresh_token": "..."}
          #
          # See "Costco: the read path is proven" in the upstream repo's
          # AGENTS.md for the one-line DevTools console snippet that produces
          # it. Capturing it is deliberately a manual, human act — an agent
          # reading a refresh token out of a browser is indistinguishable from
          # stealing one, and it trips credential-exfiltration guards.
          #
          # **THIS IS A SEED AND ONLY A SEED.** Azure B2C rotates the refresh
          # token on every redemption, so the live value changes on every run
          # and is written back to the unit's StateDirectory. The upstream
          # module installs this file ONLY when no live token exists yet;
          # copying it on every start would restore a spent token and the next
          # refresh would fail `invalid_grant` days later, looking like an
          # expiry rather than a self-inflicted overwrite.
          #
          # The captured token is good for 90 days, so re-seeding is a roughly
          # twice-yearly manual act — the same cadence as the Amazon cookie
          # jar, and for the same reason.
          "lading/ryan/costco_tokens" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Steffi's Amazon account. Same three keys, same shapes — the
          # symmetry is the point: a second account is a sibling block, not a
          # differently-named special case.
          "lading/steffi/amazon_username" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
          "lading/steffi/amazon_password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
          "lading/steffi/amazon_otp_secret_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # Steffi's Costco membership — a SECOND membership, not a second
          # card on ryan's. Costco attaches a warehouse receipt to the
          # membership number scanned at the register, so each membership has
          # its own online account and neither can see the other's trips.
          #
          # Measured before adding this: with only ryan's membership synced,
          # 40.5% of the household's Costco charges had a receipt, and the
          # matched and unmatched trips alternated week by week for fifteen
          # months. Every receipt that WAS present matched its charge exactly,
          # so this is a coverage gap and not an accuracy one.
          #
          # Same SEED semantics as ryan's — see that key. B2C rotates on every
          # redemption, the live value lives in this unit's StateDirectory,
          # and the module installs this file only when no live token exists.
          "lading/steffi/costco_tokens" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs marginaliaEnabled {
          # Marginalia auth secrets (HOF-006). Both are required at service
          # start in production. See hosts/forge/services/marginalia.nix for
          # setup steps. Assembled into a single EnvironmentFile via the
          # sops.templates entry "marginalia-env" below.

          # OAuth client secret for Marginalia's OWN PocketID client (a NEW
          # client distinct from Whiskey's). From the PocketID admin UI.
          "marginalia/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # HS256 signing key for the browser session cookie (>=32 random
          # chars; generate via `openssl rand -hex 48`). Rotating it
          # invalidates all live sessions.
          "marginalia/session_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # HMAC key for the HOF-015 pavilion dashboard capability URLs (the
          # read-only `/api/dashboard/<words>` kiosk/TV view). NOT part of the
          # production boot guard: unset just 503s that route. When present,
          # the `get_dashboard_url` MCP tool mints bookmarkable kiosk links.
          # Self-generated random key (`openssl rand -hex 32`); independent
          # rotation blast radius from session_secret (rotating only
          # invalidates outstanding dashboard URLs).
          "marginalia/dashboard_token_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs replogEnabled {
          # RepLog admin-bootstrap credentials. Consumed by the upstream
          # module ONLY on the very first boot — once a user row exists
          # in the SQLite DB, replog ignores these and you can safely
          # remove them from secrets.sops.yaml. See
          # hosts/forge/services/replog.nix for setup steps.
          "replog/admin_user" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "replog/admin_pass" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          "replog/admin_email" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # AES key (32+ random bytes; base64 or hex) that encrypts
          # sensitive settings stored in the DB (LLM API keys, etc.).
          # Auto-generated by replog if absent — we pin it so a DB
          # restore onto a fresh host stays decryptable without having
          # to chase the original key. Generate via:
          #   openssl rand -hex 32
          "replog/secret_key" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # PocketID OIDC client secret for RepLog's webui login
          # (ADR 019 / HOF-012). Issued by the PocketID admin UI when the
          # `replog` OIDC client is created. Non-secret issuer + client ID
          # live in services.replog.settings; only the secret lands here.
          "replog/oidc_client_secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs quiEnabled {
          "qui/oidc-client-secret" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs githubRunnerEnabled {
          # GitHub Actions runner personal access token
          # Fine-grained PAT with "Self-hosted runners" read+write permission
          # Create at: https://github.com/settings/tokens?type=beta
          "github/runner-token" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs upsEnabled {
          # UPS monitoring SNMP community string (replaces hardcoded 'public')
          # Change from default 'public' for improved security
          # Configure on APC Network Management Card: Configuration -> Network -> SNMP
          "ups/snmp-community" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };

          # UPS monitoring password for upsmon user
          # Used for local upsd communication in standalone mode
          "ups/upsmon-password" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        }
        // {
          # Per-user secrets (always present, not gated on a service flag)
          # GitHub personal access token for ryan's interactive shell.
          # Read at login by home/_modules/shell/bash/default.nix and exported
          # as GH_TOKEN, which the `gh` CLI consumes natively (no `gh auth
          # login` required, and no oauth_token written to managed config).
          "users/ryan/github-token" = {
            mode = "0400";
            owner = "ryan";
            group = "users";
          };

          # GitHub PAT for nix-daemon to fetch private flake inputs.
          # Value is a complete nix.conf line, e.g.:
          #   access-tokens = github.com=github_pat_xxx
          # Consumed via `nix.extraOptions = "!include ${...path}"` in
          # hosts/forge/default.nix. Root-only because nix-daemon runs as
          # root; the !include avoids leaking the token into the
          # world-readable /etc/nix/nix.conf. Currently required for the
          # private carpenike/whiskey-whiskey-whiskey upstream.
          "nix/access-tokens" = {
            mode = "0400";
            owner = "root";
            group = "root";
          };
        };

      # Templates for generating .env files for containers.
      # This is the correct pattern for injecting secrets into the environment
      # of OCI containers, as it defers secret injection until system activation time.
      templates =
        { }
        // optionalAttrs sonarrEnabled {
          "sonarr-env" = {
            content = ''
              SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr/api-key"}
              SONARR__LOG__LEVEL=Info
              SONARR__UPDATE__BRANCH=master
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs radarrEnabled {
          "radarr-env" = {
            content = ''
              RADARR__AUTH__APIKEY=${config.sops.placeholder."radarr/api-key"}
              RADARR__LOG__LEVEL=Info
              RADARR__UPDATE__BRANCH=master
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs prowlarrEnabled {
          "prowlarr-env" = {
            content = ''
              PROWLARR__AUTH__APIKEY=${config.sops.placeholder."prowlarr/api-key"}
              PROWLARR__LOG__LEVEL=Info
              PROWLARR__UPDATE__BRANCH=master
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        # bazarr-env removed - Bazarr doesn't auto-configure from environment variables
        # API keys must be configured manually in Bazarr web UI: Settings -> Sonarr/Radarr
        // optionalAttrs recyclarrEnabled {
          "recyclarr-env" = {
            content = ''
              SONARR_MAIN_SONARR_API_KEY=${config.sops.placeholder."sonarr/api-key"}
              RADARR_MAIN_RADARR_API_KEY=${config.sops.placeholder."radarr/api-key"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs quiEnabled {
          "qui-env" = {
            content = ''
              QUI__OIDC_CLIENT_SECRET=${config.sops.placeholder."qui/oidc-client-secret"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs sabnzbdEnabled {
          "sabnzbd-env" = {
            content = ''
              SABNZBD__API_KEY=${config.sops.placeholder."sabnzbd/api-key"}
              SABNZBD__USENET__USERNAME=${config.sops.placeholder."sabnzbd/usenet/username"}
              SABNZBD__USENET__PASSWORD=${config.sops.placeholder."sabnzbd/usenet/password"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs autobrrEnabled {
          "autobrr-env" = {
            content = ''
              AUTOBRR__SESSION_SECRET=${config.sops.placeholder."autobrr/session-secret"}
              AUTOBRR__OIDC_CLIENT_SECRET=${config.sops.placeholder."autobrr/oidc-client-secret"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs hermesAgentEnabled {
          "hermes-agent-env" = {
            content = ''
              ANTHROPIC_API_KEY=${config.sops.placeholder."hermes-agent/anthropic-api-key"}
              TELEGRAM_BOT_TOKEN=${config.sops.placeholder."hermes-agent/telegram-bot-token"}
              HOMELAB_MCP_OAUTH_CLIENT_SECRET=${config.sops.placeholder."hermes-agent/homelab-mcp-oauth-client-secret"}
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "hermes-agent.service" ];
          };
        }
        // optionalAttrs whiskeyWhiskeyWhiskeyEnabled {
          # EnvironmentFile assembled at activation from individually-rotatable
          # SOPS secrets. systemd reads this before privileges drop into the
          # service's DynamicUser, so it must be root-only.
          "whiskey-whiskey-whiskey-env" = {
            content = ''
              ANTHROPIC_API_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/anthropic_api_key"}
              WWW_API_TOKEN=${config.sops.placeholder."whiskey-whiskey-whiskey/api_token"}
              WWW_SESSION_SECRET=${config.sops.placeholder."whiskey-whiskey-whiskey/session_secret"}
              WWW_OIDC_CLIENT_SECRET=${config.sops.placeholder."whiskey-whiskey-whiskey/oidc_client_secret"}
              WWW_TOKEN_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/token_key"}
              WWW_PUBLIC_TOKEN_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/public_token_key"}
              WWW_GATE_TOKEN_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/gate_token_key"}
              ${lib.optionalString whiskeyWhiskeyWhiskeyPartifulEnabled
                "PARTIFUL_CALENDAR_URL=${config.sops.placeholder."whiskey-whiskey-whiskey/partiful_calendar_url"}"}
              ${lib.optionalString whiskeyWhiskeyWhiskeyPlexEnabled
                "PLEX_TOKEN=${config.sops.placeholder."whiskey-whiskey-whiskey/plex_token"}"}
              ${lib.optionalString whiskeyWhiskeyWhiskeyImageGenGeminiEnabled
                "GEMINI_API_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/gemini_api_key"}"}
              ${lib.optionalString whiskeyWhiskeyWhiskeyImageGenOpenaiEnabled
                "OPENAI_API_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/openai_api_key"}"}
              ${lib.optionalString whiskeyWhiskeyWhiskeyImageGenOpenrouterEnabled
                "OPENROUTER_API_KEY=${config.sops.placeholder."whiskey-whiskey-whiskey/openrouter_api_key"}"}
              ${lib.optionalString (whiskeyWhiskeyWhiskeyPushoverEnabled && alertingEnabled)
                "WWW_PUSHOVER_TOKEN=${config.sops.placeholder."whiskey-whiskey-whiskey/pushover_token"}"}
              ${lib.optionalString (whiskeyWhiskeyWhiskeyPushoverEnabled && alertingEnabled)
                "WWW_PUSHOVER_USER=${config.sops.placeholder."pushover/user-key"}"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
            # Restart the service when the assembled env file changes so it
            # re-reads the EnvironmentFile. Without this, sops-nix re-renders
            # the file at activation but the running unit keeps its old
            # environment — e.g. a newly-added PLEX_TOKEN (or any rotated key)
            # is silently ignored until the next manual restart.
            restartUnits = [ "whiskey-whiskey-whiskey.service" ];
          };
        }
        // optionalAttrs ambitEnabled {
          # systemd reads this root-only EnvironmentFile before switching to
          # Ambit's DynamicUser. Secret values never enter the Nix store.
          "ambit-env" = {
            content = ''
              DATABASE_URL=postgresql://ambit:${config.sops.placeholder."ambit/db_password"}@127.0.0.1:5432/ambit
              AMBIT_PASSPHRASE=${config.sops.placeholder."ambit/passphrase"}
              SESSION_SECRET=${config.sops.placeholder."ambit/session_secret"}
              AMBIT_OIDC_CLIENT_SECRET=${config.sops.placeholder."ambit/oidc_client_secret"}
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "ambit.service" ];
          };
        }
        // optionalAttrs schoolhouseEnabled {
          # TWO env files on purpose. The ingest unit holds the Schoology
          # password, the child ids and the iCal capability URLs; the MCP unit
          # gets the database DSN and nothing else. The MCP server never
          # authenticates to Schoology, so it has no business being able to.
          #
          # systemd reads both as root before dropping to the `schoolhouse`
          # system user, so they are root-only.
          "schoolhouse-ingest-env" = {
            content = ''
              SCHOOLHOUSE_DATABASE_URL=postgresql://schoolhouse:${config.sops.placeholder."schoolhouse/db_password"}@127.0.0.1:5432/schoolhouse
              SCHOOLHOUSE_SCHOOLOGY_USERNAME=${config.sops.placeholder."schoolhouse/schoology_username"}
              SCHOOLHOUSE_SCHOOLOGY_PASSWORD=${config.sops.placeholder."schoolhouse/schoology_password"}
              SCHOOLHOUSE_CHILDREN=${config.sops.placeholder."schoolhouse/children"}
              SCHOOLHOUSE_ICAL_FEEDS=${config.sops.placeholder."schoolhouse/ical_feeds"}
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "schoolhouse-ingest.service" ];
          };

          "schoolhouse-health-env" = {
            content = ''
              SCHOOLHOUSE_DATABASE_URL=postgresql://schoolhouse:${config.sops.placeholder."schoolhouse/db_password"}@127.0.0.1:5432/schoolhouse
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "schoolhouse.service" ];
          };

          # lading — each sync unit holds ONE account's Amazon credential;
          # the health unit holds only a DSN. Splitting them is the point: the
          # always-on process has no business holding a password that can
          # place orders, and neither does a second account.
          #
          # TO ADD A SECOND ACCOUNT (e.g. Steffi), three things:
          #   1. Three new sops keys above, mirroring the ryan block exactly:
          #        lading/steffi/amazon_username
          #        lading/steffi/amazon_password
          #        lading/steffi/amazon_otp_secret_key
          #      (db_password and reader_password stay shared — one database,
          #      one readonly role.)
          #   2. A "lading-sync-steffi-env" template below, copying the ryan
          #      one and swapping the placeholders. Do NOT add a second set of
          #      credentials to an existing template: one file per account is
          #      what keeps a leak worth exactly one account.
          #   3. Uncomment the `steffi` entry in services/lading.nix.
          #      LADING_ACCOUNT comes from the attribute name there.
          #
          # The account LABEL is not secret and lives in `settings` in
          # services/lading.nix (the health unit needs it too, to report a
          # configured account before its first sync). A SECOND Amazon account
          # means a second key set, a second template and a second unit —
          # never two credentials in one file.
          "lading-sync-ryan-env" = {
            content = ''
              LADING_DATABASE_URL=postgresql://lading:${config.sops.placeholder."lading/db_password"}@127.0.0.1:5432/lading
              LADING_AMAZON_USERNAME=${config.sops.placeholder."lading/ryan/amazon_username"}
              LADING_AMAZON_PASSWORD=${config.sops.placeholder."lading/ryan/amazon_password"}
              LADING_AMAZON_OTP_SECRET_KEY=${config.sops.placeholder."lading/ryan/amazon_otp_secret_key"}
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "lading-sync-ryan.service" ];
          };

          "lading-sync-steffi-env" = {
            content = ''
              LADING_DATABASE_URL=postgresql://lading:${config.sops.placeholder."lading/db_password"}@127.0.0.1:5432/lading
              LADING_AMAZON_USERNAME=${config.sops.placeholder."lading/steffi/amazon_username"}
              LADING_AMAZON_PASSWORD=${config.sops.placeholder."lading/steffi/amazon_password"}
              LADING_AMAZON_OTP_SECRET_KEY=${config.sops.placeholder."lading/steffi/amazon_otp_secret_key"}
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "lading-sync-steffi.service" ];
          };

          "lading-health-env" = {
            content = ''
              LADING_DATABASE_URL=postgresql://lading:${config.sops.placeholder."lading/db_password"}@127.0.0.1:5432/lading
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "lading.service" ];
          };

          # Read-only DSN handed to homelab-mcp for the school_* tools.
          # A TEMPLATE rather than a line in the hand-maintained
          # homelab-mcp/env dotenv, so the password here can never drift from
          # the role password provisioned in services/schoolhouse.nix — both
          # interpolate the same secret.
          "homelab-mcp-schoolhouse-env" = {
            content = ''
              HOMELAB_MCP_SCHOOLHOUSE_DATABASE_URL=postgresql://homelab-mcp:${config.sops.placeholder."schoolhouse/reader_password"}@127.0.0.1:5432/schoolhouse
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "homelab-mcp.service" ];
          };

          # Read-only DSN handed to homelab-mcp for the amazon_* tools. Same
          # reasoning as the schoolhouse one above: a TEMPLATE, so this
          # password cannot drift from the role provisioned in
          # services/lading.nix — both interpolate lading/reader_password.
          #
          # The role is `homelab-mcp-lading`, NOT the shared `homelab-mcp`
          # that schoolhouse uses: a Postgres role is cluster-wide with one
          # password, so two stores provisioning the same role against
          # different secrets makes it flap with provisioning order. See
          # services/lading.nix. Separate roles fix the password, not
          # visibility — `readonly` grants SELECT across databases.
          #
          # It holds `readonly` membership, so the always-on process that
          # controls the house is physically incapable of rewriting purchase
          # history. It also never sees the Amazon credential itself, which
          # lives only in lading's own sync unit.
          "homelab-mcp-lading-env" = {
            content = ''
              HOMELAB_MCP_AMAZON_DATABASE_URL=postgresql://homelab-mcp-lading:${config.sops.placeholder."lading/reader_password"}@127.0.0.1:5432/lading
            '';
            mode = "0400";
            owner = "root";
            group = "root";
            restartUnits = [ "homelab-mcp.service" ];
          };
        }
        // optionalAttrs marginaliaEnabled {
          # EnvironmentFile assembled at activation from individually-rotatable
          # SOPS secrets. systemd reads this before privileges drop into the
          # service's DynamicUser, so it must be root-only. The matching
          # non-secret auth settings live in services/marginalia.nix.
          "marginalia-env" = {
            content = ''
              MARGINALIA_OIDC_CLIENT_SECRET=${config.sops.placeholder."marginalia/oidc_client_secret"}
              MARGINALIA_SESSION_SECRET=${config.sops.placeholder."marginalia/session_secret"}
              MARGINALIA_DASHBOARD_TOKEN_KEY=${config.sops.placeholder."marginalia/dashboard_token_key"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
            # Restart the service when the assembled env file changes so it
            # re-reads the EnvironmentFile (mirrors the whiskey fix above —
            # without this a rotated secret is silently ignored until a
            # manual restart).
            restartUnits = [ "marginalia.service" ];
          };
        }
        // optionalAttrs replogEnabled {
          # EnvironmentFile assembled at activation from individually-rotatable
          # SOPS secrets. systemd reads this before privileges drop into the
          # service's DynamicUser, so it must be root-only.
          #
          # The REPLOG_ADMIN_* trio is only consumed on the first boot
          # (until a user row exists in the DB). After the first
          # successful login, you can drop those three keys from
          # secrets.sops.yaml and re-apply — replog ignores them on
          # subsequent boots.
          "replog-env" = {
            content = ''
              REPLOG_ADMIN_USER=${config.sops.placeholder."replog/admin_user"}
              REPLOG_ADMIN_PASS=${config.sops.placeholder."replog/admin_pass"}
              REPLOG_ADMIN_EMAIL=${config.sops.placeholder."replog/admin_email"}
              REPLOG_SECRET_KEY=${config.sops.placeholder."replog/secret_key"}
              REPLOG_OIDC_CLIENT_SECRET=${config.sops.placeholder."replog/oidc_client_secret"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs unpackerrEnabled {
          # Unpackerr environment file with arr API keys
          # Uses UN_ prefix for environment variables
          # See: https://unpackerr.zip/docs/install/configuration
          "unpackerr/env" = {
            content = lib.concatStringsSep "\n" (lib.filter (x: x != "") [
              # Global settings
              "UN_DEBUG=false"
              "UN_LOG_FILE="
              "UN_LOG_FILES=0"
              "UN_LOG_FILE_MB=0"
              "UN_QUIET=false"
              "UN_ACTIVITY=false"
              "UN_START_DELAY=1m"
              "UN_RETRY_DELAY=5m"
              "UN_MAX_RETRIES=3"
              "UN_PARALLEL=1"
              "UN_FILE_MODE=0644"
              "UN_DIR_MODE=0755"
              "TZ=${config.time.timeZone}"
              "PUID=917"
              "PGID=65537"
              # Sonarr integration
              (lib.optionalString sonarrEnabled "UN_SONARR_0_URL=http://sonarr:8989")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_API_KEY=${config.sops.placeholder."sonarr/api-key"}")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_PATHS_0=/data/qb/downloads")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_PROTOCOLS=torrent,usenet")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_TIMEOUT=10s")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_DELETE_ORIG=false")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_DELETE_DELAY=5m")
              (lib.optionalString sonarrEnabled "UN_SONARR_0_SYNCTHING=false")
              # Radarr integration
              (lib.optionalString radarrEnabled "UN_RADARR_0_URL=http://radarr:7878")
              (lib.optionalString radarrEnabled "UN_RADARR_0_API_KEY=${config.sops.placeholder."radarr/api-key"}")
              (lib.optionalString radarrEnabled "UN_RADARR_0_PATHS_0=/data/qb/downloads")
              (lib.optionalString radarrEnabled "UN_RADARR_0_PROTOCOLS=torrent,usenet")
              (lib.optionalString radarrEnabled "UN_RADARR_0_TIMEOUT=10s")
              (lib.optionalString radarrEnabled "UN_RADARR_0_DELETE_ORIG=false")
              (lib.optionalString radarrEnabled "UN_RADARR_0_DELETE_DELAY=5m")
              (lib.optionalString radarrEnabled "UN_RADARR_0_SYNCTHING=false")
            ]);
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs homepageEnabled {
          # Homepage dashboard widget API keys
          # Re-uses existing arr service secrets for widget integration
          # Homepage reads HOMEPAGE_VAR_* directly as values (not file paths)
          "homepage-env" = {
            content = lib.concatStringsSep "\n" (lib.filter (x: x != "") [
              (lib.optionalString sonarrEnabled "HOMEPAGE_VAR_SONARR_API_KEY=${config.sops.placeholder."sonarr/api-key"}")
              (lib.optionalString radarrEnabled "HOMEPAGE_VAR_RADARR_API_KEY=${config.sops.placeholder."radarr/api-key"}")
              (lib.optionalString prowlarrEnabled "HOMEPAGE_VAR_PROWLARR_API_KEY=${config.sops.placeholder."prowlarr/api-key"}")
              (lib.optionalString sabnzbdEnabled "HOMEPAGE_VAR_SABNZBD_API_KEY=${config.sops.placeholder."sabnzbd/api-key"}")
              (lib.optionalString plexEnabled "HOMEPAGE_VAR_PLEX_TOKEN=${config.sops.placeholder."plex/token"}")
              (lib.optionalString tautulliEnabled "HOMEPAGE_VAR_TAUTULLI_API_KEY=${config.sops.placeholder."tautulli/api-key"}")
              (lib.optionalString autobrrEnabled "HOMEPAGE_VAR_AUTOBRR_API_KEY=${config.sops.placeholder."autobrr/api-key"}")
              (lib.optionalString cloudflaredEnabled "HOMEPAGE_VAR_CLOUDFLARED_API_TOKEN=${config.sops.placeholder."networking/cloudflare/homepage-api-token"}")
              (lib.optionalString cloudflaredEnabled "HOMEPAGE_VAR_CLOUDFLARED_ACCOUNT_ID=${config.sops.placeholder."networking/cloudflare/account-id"}")
              # Omada SDN controller widget
              "HOMEPAGE_VAR_OMADA_USERNAME=${config.sops.placeholder."omada/homepage-username"}"
              "HOMEPAGE_VAR_OMADA_PASSWORD=${config.sops.placeholder."omada/homepage-password"}"
              # Mikrotik router widget (always enabled when homepage is enabled)
              "HOMEPAGE_VAR_MIKROTIK_PASSWORD=${config.sops.placeholder."mikrotik/homepage-password"}"
            ]);
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
        // optionalAttrs kometaEnabled {
          # Kometa environment file for container secrets
          # Used for Plex, TMDb, and Trakt API credentials
          "kometa-env" = {
            content = lib.concatStringsSep "\n" (lib.filter (x: x != "") [
              "KOMETA_PLEX_URL=http://plex:32400"
              "KOMETA_PLEX_TOKEN=${config.sops.placeholder."plex/token"}"
              "KOMETA_TMDB_API_KEY=${config.sops.placeholder."tmdb/api-key"}"
              "KOMETA_TRAKT_CLIENT_ID=${config.sops.placeholder."trakt/client-id"}"
              "KOMETA_TRAKT_CLIENT_SECRET=${config.sops.placeholder."trakt/client-secret"}"
            ]);
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        };
    };
  };
}
