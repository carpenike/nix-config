# hosts/forge/services/litellm.nix
#
# LiteLLM on forge — the one endpoint every AI client on the LAN should be
# pointed at. Reusable module: modules/nixos/services/litellm/default.nix
# (read its header first). Rebuilt 2026-09-04 onto the service factory
# alongside the new copilot-api proxy.
#
# Model routes (what clients ask for → where it goes)
# ---------------------------------------------------
#   copilot/<id>          → copilot-api (Anthropic Messages path). Use for
#                           Claude models from the Copilot catalogue, e.g.
#                           copilot/claude-sonnet-4.5. `GET /v1/models` on
#                           copilot-api lists the current ids.
#   copilot-oai/<id>      → copilot-api (OpenAI chat path) for gpt-*/o*.
#   anthropic/<id>        → api.anthropic.com   (ANTHROPIC_API_KEY)
#   gemini/<id>           → Google AI Studio    (GOOGLE_API_KEY)
#   openai/<id>           → api.openai.com      (OPENAI_API_KEY)
#   claude-opus/-sonnet/-haiku
#                         → friendly aliases onto anthropic/…
#   <azure deployment>    → the ryholt-simplechat-aifoundry resource, one
#                           entry per deployment name that exists there.
#
# Provider wildcards replaced the 2025-era pinned list (claude-3, gemini-1.5
# …) so new model ids work without a deploy; the Azure entries stay explicit
# because a deployment name that is not deployed 404s.
#
# Clients
# -------
#   Claude Code:   ANTHROPIC_BASE_URL=https://llm.holthome.net
#                  ANTHROPIC_AUTH_TOKEN=<virtual key from the Admin UI>
#                  ANTHROPIC_MODEL=copilot/claude-sonnet-4.5   (or anthropic/…)
#   OpenAI SDKs:   base_url=https://llm.holthome.net/v1, api_key=<virtual key>
#
# Secrets (secrets.nix): litellm/provider-keys (env file), litellm/master_key,
# litellm/database_password, litellm/oidc-client-secret. The copilot-api
# client key is read straight from that service's generated key file.
#
# Exposure: loopback + Caddy on LAN addresses only, no caddySecurity (LiteLLM
# authenticates every API call with its own virtual keys; the Admin UI logs in
# through PocketID). Never in the Cloudflare tunnel.

{ config, lib, ... }:

let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  serviceName = "litellm";
  serviceEnabled = config.modules.services.${serviceName}.enable or false;
  serviceDomain = "llm.${config.networking.domain}";
  listenPort = 4100; # 4000 is TeslaMate

  copilotCfg = config.modules.services.copilot-api;
  copilotEnabled = copilotCfg.enable or false;
  copilotKeyFile =
    if copilotCfg.apiKeysFile or null != null
    then copilotCfg.apiKeysFile
    else "/var/lib/copilot-api/api-key";
  copilotBase = "http://copilot-api:${toString copilotCfg.port}";

  azureFoundry = "https://ryholt-simplechat-aifoundry.cognitiveservices.azure.com";
  azureDeployment = { name, apiVersion ? "2024-12-01-preview", modelInfo ? { } }: {
    inherit name modelInfo;
    model = "azure/${name}";
    apiBase = azureFoundry;
    apiKey = "AZURE_API_KEY";
    inherit apiVersion;
  };
in
{
  config = lib.mkMerge [
    {
      modules.services.litellm = {
        # Re-enabled 2026-09-04 (was off since 2026-06-01 as an unused
        # gateway) to front copilot-api for Claude Code and the household
        # agents. Memory is capped at 2G below.
        enable = true;

        # Pin container image (Renovate will update)
        image = "ghcr.io/berriai/litellm:v1.99.1@sha256:a53a7d3ffebede1925bd3ee8a21e4a7b9b63e2e68ec883af136edcccb6eeb82c";

        port = listenPort;

        # Shared bridge: reaches copilot-api by container name, and lets
        # other containers reach `litellm:4000`.
        podmanNetwork = forgeDefaults.podmanNetwork;

        # Provider credentials and the master key via sops (secrets.nix)
        environmentFile = config.sops.secrets."litellm/provider-keys".path;
        masterKeyFile = config.sops.secrets."litellm/master_key".path;

        # The copilot-api client key, owned by that service.
        extraCredentialFiles = lib.optionalAttrs copilotEnabled {
          COPILOT_API_KEY = copilotKeyFile;
        };

        database = {
          host = "host.containers.internal";
          port = 5432;
          name = "litellm";
          user = "litellm";
          passwordFile = config.sops.secrets."litellm/database_password".path;
          manageDatabase = true;
          localInstance = true;
        };

        # The container must reach id.holthome.net for the SSO token
        # exchange; public DNS points at Cloudflare, which hairpin NAT can't
        # reach. Caddy listens on the Podman bridge IP for exactly this.
        extraHosts = {
          "id.holthome.net" = "10.89.0.1";
        };

        # Admin UI SSO through PocketID (free tier, ≤5 users). API traffic
        # uses virtual keys; JWT API auth is enterprise-only and not used.
        sso.adminUi = {
          enable = true;
          clientId = "litellm";
          clientSecretFile = config.sops.secrets."litellm/oidc-client-secret".path;
          authorizationEndpoint = "https://id.holthome.net/authorize";
          tokenEndpoint = "https://id.holthome.net/api/oidc/token";
          userinfoEndpoint = "https://id.holthome.net/api/oidc/userinfo";
          redirectUri = "https://${serviceDomain}/sso/callback";
          scope = "openid profile email";
          # Role claim is ignored upstream (docs/workarounds.md); grant admin
          # by user id instead.
          proxyAdminId = "ryan";
        };

        generalSettings = {
          # Config-defined models are mirrored into the DB so the Admin UI
          # can show and test them.
          store_model_in_db = true;
          proxy_batch_write_at = 60;
          disable_error_logs = true;
          database_connection_pool_limit = 10;
        };

        models =
          # --- GitHub Copilot via copilot-api (same Podman network) ---------
          lib.optionals copilotEnabled [
            {
              name = "copilot/*";
              model = "anthropic/*";
              apiBase = copilotBase;
              apiKey = "COPILOT_API_KEY";
            }
            {
              name = "copilot-oai/*";
              model = "openai/*";
              apiBase = "${copilotBase}/v1";
              apiKey = "COPILOT_API_KEY";
            }
          ]
          # --- Azure AI Foundry deployments --------------------------------
          ++ [
            (azureDeployment { name = "gpt-4o"; })
            (azureDeployment { name = "gpt-5"; })
            (azureDeployment { name = "gpt-5-chat"; })
            (azureDeployment { name = "gpt-5-codex"; })
            (azureDeployment { name = "gpt-5-pro"; })
            (azureDeployment { name = "gpt-5.1"; })
            (azureDeployment { name = "gpt-5.1-codex"; apiVersion = "2025-04-01-preview"; })
            (azureDeployment { name = "o3-mini"; apiVersion = "2025-01-01-preview"; })
            (azureDeployment { name = "text-embedding-3-small"; modelInfo = { mode = "embedding"; }; })

            # --- Direct providers: wildcards + aliases -----------------------
            { name = "anthropic/*"; model = "anthropic/*"; apiKey = "ANTHROPIC_API_KEY"; }
            { name = "gemini/*"; model = "gemini/*"; apiKey = "GOOGLE_API_KEY"; }
            { name = "openai/*"; model = "openai/*"; apiKey = "OPENAI_API_KEY"; }

            { name = "claude-opus"; model = "anthropic/claude-opus-5"; apiKey = "ANTHROPIC_API_KEY"; }
            { name = "claude-sonnet"; model = "anthropic/claude-sonnet-5"; apiKey = "ANTHROPIC_API_KEY"; }
            { name = "claude-haiku"; model = "anthropic/claude-haiku-4-5-20251001"; apiKey = "ANTHROPIC_API_KEY"; }
          ];

        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          # No caddySecurity: virtual keys on the API, SSO on the UI.
        };

        # 2026-09-04: the first start of v1.99 under the old 1G cap was
        # OOM-killed twice, 16s in, while Prisma ran migrations — the kernel
        # logged the litellm process at ~740MB anon RSS in a 1G cgroup, so the
        # 2025 observation (~470MB avg / 660MB peak) no longer holds for
        # startup. 2G matches the host floor for containers; steady state
        # should settle well below it.
        resources = {
          memory = "2G";
          memoryReservation = "1G";
          cpus = "1.0";
        };

        backup = forgeDefaults.mkBackupWithSnapshots serviceName;
        notifications.enable = true;
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];
      };
    }

    (lib.mkIf serviceEnabled {
      # The dataset only holds the generated master key (when no sops key is
      # set) and scratch; everything of value is in PostgreSQL (pgBackRest).
      modules.storage.datasets.services.${serviceName}.protection = {
        class = "standard";
        objectives = {
          onsiteRpoSeconds = 86400;
          offsiteRpoSeconds = null;
          rtoSeconds = 28800;
        };
        requiredTiers = [
          "local-snapshot"
          "replication"
          "nas-backup"
          "automated-restore"
        ];
        consistency = "crash-consistent";
        validator = null;
        allowEmptyBootstrap = true;
      };

      modules.backup.sanoid.datasets."tank/services/${serviceName}" =
        forgeDefaults.mkSanoidDataset serviceName;

      modules.alerting.rules."${serviceName}-service-down" =
        forgeDefaults.mkServiceDownAlert serviceName "LiteLLM" "AI gateway";

      # Make sure copilot-api's key exists before we try to load it.
      systemd.services.litellm-env = lib.mkIf copilotEnabled {
        after = [ "copilot-api-keys.service" ];
        wants = [ "copilot-api-keys.service" ];
      };

      modules.services.homepage.contributions.${serviceName} = {
        group = "Infrastructure";
        name = "LiteLLM";
        icon = "litellm";
        href = "https://${serviceDomain}/ui";
        description = "AI gateway: virtual keys, spend, model routing";
        siteMonitor = "http://localhost:${toString listenPort}/health/liveliness";
      };

      modules.services.gatus.contributions.${serviceName} = {
        name = "LiteLLM";
        group = "Infrastructure";
        url = "http://127.0.0.1:${toString listenPort}/health/liveliness";
        interval = "300s";
        conditions = [ "[STATUS] == 200" ];
      };
    })
  ];
}
