# LiteLLM - Unified AI Gateway for Forge
#
# Provides a unified API gateway for multiple AI providers:
# - Azure OpenAI (GPT-4o, GPT-5 variants, o3-mini, embeddings)
# - Anthropic Claude
# - Google Gemini
# - OpenAI
#
# STATELESS MODE: This uses the native NixOS module which runs LiteLLM
# without database features. Provides routing, failover, and streaming.
# For spend tracking/user management, use the container version.
#
# Features:
# - ZFS storage with optimized recordsize
# - Local-only access (no Cloudflare Tunnel)
# - Auto-generated master key
#
{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceEnabled = config.modules.services.litellm.enable or false;
in
{
  config = lib.mkMerge [
    # =========================================================================
    # Service Configuration
    # =========================================================================
    {
      modules.services.litellm = {
        enable = true;
        port = 4100; # 8080=qbittorrent, 4000=teslamate

        # Master key is auto-generated and stored in state directory
        # Provider credentials via SOPS (defined in secrets.nix)
        environmentFile = config.sops.secrets."litellm/provider-keys".path;

        # =====================================================================
        # Model Configuration
        # =====================================================================
        # Azure OpenAI deployments
        models = [
          # GPT-4o - Latest GPT-4 multimodal
          {
            name = "gpt-4o";
            model = "azure/gpt-4o";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          # GPT-5 variants
          {
            name = "gpt-5";
            model = "azure/gpt-5";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          {
            name = "gpt-5-chat";
            model = "azure/gpt-5-chat";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          {
            name = "gpt-5-codex";
            model = "azure/gpt-5-codex";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          {
            name = "gpt-5-pro";
            model = "azure/gpt-5-pro";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          {
            name = "gpt-5.1";
            model = "azure/gpt-5.1";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          {
            name = "gpt-5.1-codex";
            model = "azure/gpt-5.1-codex";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          # Reasoning model
          {
            name = "o3-mini";
            model = "azure/o3-mini";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }
          # Embeddings
          {
            name = "text-embedding-3-small";
            model = "azure/text-embedding-3-small";
            apiKey = "AZURE_API_KEY";
            extraParams = { api_version = "2024-08-01-preview"; };
          }

          # Anthropic Claude models
          {
            name = "claude-3-opus";
            model = "anthropic/claude-3-opus-20240229";
            apiKey = "ANTHROPIC_API_KEY";
          }
          {
            name = "claude-3-sonnet";
            model = "anthropic/claude-3-sonnet-20240229";
            apiKey = "ANTHROPIC_API_KEY";
          }
          {
            name = "claude-3-haiku";
            model = "anthropic/claude-3-haiku-20240307";
            apiKey = "ANTHROPIC_API_KEY";
          }
          {
            name = "claude-3.5-sonnet";
            model = "anthropic/claude-3-5-sonnet-20241022";
            apiKey = "ANTHROPIC_API_KEY";
          }
          {
            name = "claude-sonnet-4";
            model = "anthropic/claude-sonnet-4-20250514";
            apiKey = "ANTHROPIC_API_KEY";
          }
          {
            name = "claude-opus-4";
            model = "anthropic/claude-opus-4-20250514";
            apiKey = "ANTHROPIC_API_KEY";
          }

          # Google Gemini models
          {
            name = "gemini-pro";
            model = "gemini/gemini-pro";
            apiKey = "GOOGLE_API_KEY";
          }
          {
            name = "gemini-1.5-pro";
            model = "gemini/gemini-1.5-pro";
            apiKey = "GOOGLE_API_KEY";
          }
          {
            name = "gemini-1.5-flash";
            model = "gemini/gemini-1.5-flash";
            apiKey = "GOOGLE_API_KEY";
          }
          {
            name = "gemini-2.0-flash";
            model = "gemini/gemini-2.0-flash";
            apiKey = "GOOGLE_API_KEY";
          }
          {
            name = "gemini-2.5-pro";
            model = "gemini/gemini-2.5-pro-preview-06-05";
            apiKey = "GOOGLE_API_KEY";
          }

          # OpenAI direct models (fallback/comparison)
          {
            name = "openai-gpt-4o";
            model = "gpt-4o";
            apiKey = "OPENAI_API_KEY";
          }
          {
            name = "openai-gpt-4-turbo";
            model = "gpt-4-turbo";
            apiKey = "OPENAI_API_KEY";
          }
        ];

        # Router settings for load balancing and fallbacks
        routerSettings = {
          routing_strategy = "simple-shuffle";
          num_retries = 2;
          timeout = 300;
        };

        litellmSettings = {
          drop_params = true;
          set_verbose = false;
        };

        # =====================================================================
        # ZFS Storage
        # =====================================================================
        zfs.dataset = "tank/services/litellm";

        # =====================================================================
        # Reverse Proxy (Local Only - No Cloudflare)
        # =====================================================================
        reverseProxy = {
          enable = true;
          hostName = "llm.holthome.net";
          backend = {
            host = "127.0.0.1";
            port = 4100;
          };
        };

        # =====================================================================
        # Backup Configuration (for auto-generated master key)
        # =====================================================================
        backup = forgeDefaults.backup;
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };

      # Secrets are defined in secrets.nix (centralized pattern)
    }

    # =========================================================================
    # Infrastructure Contributions (guarded by service enable)
    # =========================================================================
    (lib.mkIf serviceEnabled {
      # ZFS snapshot and replication to NAS
      modules.backup.sanoid.datasets."tank/services/litellm" =
        forgeDefaults.mkSanoidDataset "litellm";

      # Service monitoring alert
      modules.alerting.rules."litellm-service-down" =
        forgeDefaults.mkSystemdServiceDownAlert "litellm" "LiteLLM" "AI gateway";
    })
  ];
}
