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
  grafanaEnabled = config.modules.services.grafana.enable or false;
  grafanaOncallEnabled = config.modules.services.grafana-oncall.enable or false;
  pocketIdEnabled = config.modules.services.pocketid.enable or false;
  esphomeEnabled = config.modules.services.esphome.enable or false;
  sonarrEnabled = config.modules.services.sonarr.enable or false;
  radarrEnabled = config.modules.services.radarr.enable or false;
  prowlarrEnabled = config.modules.services.prowlarr.enable or false;
  bazarrEnabled = config.modules.services.bazarr.enable or false;
  recyclarrEnabled = config.modules.services.recyclarr.enable or false;
  teslamateEnabled = config.modules.services.teslamate.enable or false;
  zigbeeEnabled = config.modules.services.zigbee2mqtt.enable or false;
  zwaveEnabled = config.modules.services."zwave-js-ui".enable or false;
  mealieEnabled = config.modules.services.mealie.enable or false;
  n8nEnabled = config.modules.services.n8n.enable or false;
  openWebuiEnabled = config.modules.services.open-webui.enable or false;
  paperlessEnabled = config.modules.services.paperless.enable or false;
  paperlessAiEnabled = config.modules.services.paperless-ai.enable or false;
  emqxEnabled = config.modules.services.emqx.enable or false;
  crossSeedEnabled = config.modules.services."cross-seed".enable or false;
  sabnzbdEnabled = config.modules.services.sabnzbd.enable or false;
  actualEnabled = config.modules.services.actual.enable or false;
  autobrrEnabled = config.modules.services.autobrr.enable or false;
  quiEnabled = config.modules.services.qui.enable or false;
  unpackerrEnabled = config.modules.services.unpackerr.enable or false;
  homepageEnabled = config.modules.services.homepage.enable or false;
  plexEnabled = config.modules.services.plex.enable or false;
  tautulliEnabled = config.modules.services.tautulli.enable or false;
  litellmEnabled = config.modules.services.litellm.enable or false;
  atticPushEnabled = config.modules.services.attic-push.enable or false;
  pinchflatEnabled = config.modules.services.pinchflat.enable or false;
  kometaEnabled = config.modules.services.kometa.enable or false;
  postgresqlEnabled =
    (config.modules.services.postgresql.enable or false)
    || (config.services.postgresql.enable or false);
  r2CredentialsEnabled = resticEnabled || postgresqlEnabled;
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
        // optionalAttrs crossSeedEnabled {
          "cross-seed/api-key" = {
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

          # LLM API key for LiteLLM gateway
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
        // optionalAttrs quiEnabled {
          "qui/oidc-client-secret" = {
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
        // optionalAttrs bazarrEnabled {
          "bazarr-env" = {
            content = ''
              SONARR_API_KEY=${config.sops.placeholder."sonarr/api-key"}
              RADARR_API_KEY=${config.sops.placeholder."radarr/api-key"}
            '';
            mode = "0400"; # root-only readable
            owner = "root";
            group = "root";
          };
        }
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
              # Omada SDN controller widget (runs on luna, accessed remotely)
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
