# hosts/forge/services/open-webui.nix
#
# Host-specific configuration for Open WebUI on 'forge'.
# Open WebUI is a self-hosted AI chat interface with multi-provider LLM support.
#
# Features:
# - PocketID SSO (native OIDC)
# - Azure AI Foundry, OpenAI, and Anthropic Claude
# - LM Studio on mac-mini.holthome.net (disabled by default, enable when ready)
# - Public access via Cloudflare Tunnel

{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "chat.${domain}";
  dataset = "tank/services/open-webui";
  dataDir = "/var/lib/open-webui";
  pocketIdIssuer = "https://id.${domain}";
  listenAddr = "127.0.0.1";
  listenPortNumber = 8085; # Avoid 8080 which is used by qbittorrent
  serviceEnabled = config.modules.services.open-webui.enable or false;
in
{
  config = lib.mkMerge [
    {
      modules.services.open-webui = {
        enable = true;
        package = pkgs.unstable.open-webui;
        host = listenAddr;
        port = listenPortNumber;
        dataDir = dataDir;
        datasetPath = dataset;
        baseUrl = "https://${serviceDomain}";
        enableSignup = false; # Users provision via OIDC

        oidc = {
          enable = true;
          configurationUrl = "${pocketIdIssuer}/.well-known/openid-configuration";
          clientId = "open-webui";
          clientSecretFile = config.sops.secrets."open-webui/oidc_client_secret".path;
          providerName = "Holthome SSO";
          scopes = [ "openid" "profile" "email" "groups" ]; # Include groups for role sync
          signupEnabled = true; # Auto-provision users on first OIDC login
          mergeAccountsByEmail = true;
          enableLoginForm = false; # SSO only

          # Sync admin role from PocketID groups
          # Use Open WebUI-specific group names to avoid conflicts with other OIDC clients
          roleManagement = {
            enable = true;
            rolesClaim = "groups"; # PocketID uses "groups" claim
            adminRoles = [ "open-webui-admins" ]; # Users in "open-webui-admins" group become admins
            allowedRoles = [ "open-webui-users" "open-webui-admins" ]; # Only these groups can access Open WebUI
          };
        };

        # Azure AI Foundry - Primary LLM provider
        # NOTE: After deployment, you must configure Azure in the Admin UI:
        #   Admin Settings → Connections → Edit default connection
        #   - Set Provider Type: "Azure OpenAI"
        #   - Set API Version: "2024-12-01-preview" (for o-series models)
        azure = {
          enable = true;
          endpoint = "https://ryholt-simplechat-aifoundry.cognitiveservices.azure.com/";
          apiKeyFile = config.sops.secrets."open-webui/azure_openai_key".path;
        };

        # OpenAI - Secondary provider (Azure takes precedence for OPENAI_API_KEY)
        # Disable for now since Azure uses the same env var
        openai = {
          enable = false;
          # apiKeyFile = config.sops.secrets."open-webui/openai_api_key".path;
        };

        # Anthropic Claude (disabled - no apiKeyFile when disabled)
        anthropic = {
          enable = false;
          # apiKeyFile = config.sops.secrets."open-webui/anthropic_api_key".path;
        };

        # LM Studio on mac-mini (disabled until you set it up)
        ollama = {
          enable = false;
          baseUrl = "http://mac-mini.holthome.net:1234/v1";
        };

        # SearXNG web search integration for RAG
        # SearXNG is deployed locally at port 8888 with JSON format enabled
        searxng = {
          enable = true;
          queryUrl = "http://127.0.0.1:8888/search?q=<query>";
          resultCount = 5;
          concurrentRequests = 10;
        };

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = listenAddr;
            port = listenPortNumber;
          };
        };

        backup = forgeDefaults.mkBackupWithTags "open-webui" [ "ai" "chat" "open-webui" "forge" ];

        notifications.enable = true;

        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    # Infrastructure contributions - guarded by service enable
    (lib.mkIf serviceEnabled {
      # ZFS dataset with SQLite-optimized recordsize
      modules.storage.datasets.services."open-webui" = {
        mountpoint = dataDir;
        recordsize = "16K"; # Optimized for SQLite
        compression = "zstd";
        properties."com.sun:auto-snapshot" = "true";
        owner = "open-webui";
        group = "open-webui";
        mode = "0750";
      };

      # Sanoid snapshot/replication to NAS
      modules.backup.sanoid.datasets."tank/services/open-webui" =
        forgeDefaults.mkSanoidDataset "open-webui";

      # Service-down alert
      modules.alerting.rules."open-webui-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "open-webui" "OpenWebUI" "AI chat interface";

      # Cloudflare Tunnel for public access
      modules.services.caddy.virtualHosts.open-webui.cloudflare = {
        enable = true;
        tunnel = "forge";
      };
    })
  ];
}
