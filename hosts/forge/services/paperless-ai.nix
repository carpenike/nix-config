# hosts/forge/services/paperless-ai.nix
#
# Host-specific configuration for Paperless-AI on 'forge'.
# Paperless-AI provides AI-powered document tagging for Paperless-ngx.
#
# Integration:
# - Connects to local Paperless-ngx instance (port 28981)
# - Uses LiteLLM gateway (llm.holthome.net) with gpt-5.1 model
# - Internal-only access via caddySecurity.home (PocketID SSO)
#
{ config, lib, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "paperless-ai.${domain}";
  dataset = "tank/services/paperless-ai";
  dataDir = "/var/lib/paperless-ai";
  listenPort = 3001;
  serviceEnabled = config.modules.services.paperless-ai.enable or false;
in
{
  config = lib.mkMerge [
    # =========================================================================
    # Service Configuration
    # =========================================================================
    {
      modules.services.paperless-ai = {
        enable = true;
        port = listenPort;

        # Storage
        dataDir = dataDir;

        # Use same user/group as paperless-ngx for shared permissions
        user = "paperless";
        group = "paperless";

        # =====================================================================
        # Paperless-ngx Integration
        # =====================================================================
        paperless = {
          # Connect to local paperless-ngx instance via container bridge
          apiUrl = "http://host.containers.internal:28981/api";
          tokenFile = config.sops.secrets."paperless-ai/paperless_token".path;
          # Paperless-ngx web UI username (must match the API token owner)
          username = "paperless-ai";
        };

        # =====================================================================
        # LLM Configuration (via LiteLLM gateway)
        # =====================================================================
        llm = {
          provider = "custom"; # OpenAI-compatible API
          baseUrl = "https://llm.${domain}/v1";
          model = "gpt-5.1";
          apiKeyFile = config.sops.secrets."paperless-ai/llm_api_key".path;
        };

        # =====================================================================
        # API Authentication
        # =====================================================================
        apiKeyFile = config.sops.secrets."paperless-ai/api_key".path;

        # =====================================================================
        # Scanning Configuration
        # =====================================================================
        scan = {
          interval = "*/30 * * * *"; # Every 30 minutes
          addAiProcessedTag = true;
          useExistingData = true;
        };

        # =====================================================================
        # Reverse Proxy with PocketID SSO
        # =====================================================================
        # PocketID handles authentication, then Caddy injects the x-api-key
        # header to bypass paperless-ai's internal auth (via API_KEY env var)
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = listenPort;
          };
          # PocketID SSO - requires "home" group membership
          caddySecurity = forgeDefaults.caddySecurity.home;
          # Inject the API key header to bypass internal paperless-ai auth
          reverseProxyBlock = ''
            header_up x-api-key {$PAPERLESS_AI_API_KEY}
          '';
        };

        # =====================================================================
        # Resource Limits
        # =====================================================================
        # Python/AI service with 6 gunicorn workers
        # Each worker can use 300-500MB during document processing
        resources = {
          memory = "2G";
          memoryReservation = "1G";
          cpus = "2.0";
        };

        # =====================================================================
        # Backup & DR
        # =====================================================================
        backup = forgeDefaults.mkBackupWithTags "paperless-ai" [ "documents" "paperless-ai" "forge" ];
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Notifications
        notifications.enable = true;
      };
    }

    # =========================================================================
    # Host-level Resources (guarded by service enable)
    # =========================================================================
    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "paperless-ai";

      # Service-down alert
      modules.alerting.rules."paperless-ai-service-down" =
        forgeDefaults.mkServiceDownAlert "paperless-ai" "Paperless-AI" "document tagging";

      # Homepage dashboard contribution
      modules.services.homepage.contributions.paperless-ai = {
        group = "Productivity";
        name = "Paperless AI";
        icon = "paperless-ngx"; # Use paperless icon (no dedicated paperless-ai icon)
        href = "https://${serviceDomain}";
        description = "AI-powered document tagging";
        siteMonitor = "http://127.0.0.1:${toString listenPort}";
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.paperless-ai = {
        name = "Paperless-AI";
        group = "Productivity";
        url = "https://${serviceDomain}/";
        interval = "60s";
        conditions = [ "[STATUS] == 200" ];
      };
    })
  ];
}
