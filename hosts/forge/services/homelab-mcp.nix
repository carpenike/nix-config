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
{ config, inputs, lib, pkgs, ... }:

let
  serviceName = "homelab-mcp";
  serviceDomain = "mcp.${config.networking.domain}";
  listenAddr = "127.0.0.1";
  # Upstream default is 9200 (avoids the well-known prometheus
  # node_exporter port 9100). We surface it here so the Caddy backend
  # below has a single source of truth.
  listenPort = 9200;
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

        # MCP user joins the cooklang group via the upstream module's
        # `recipesGroup` option (default "cooklang") so save_recipe
        # writes work. Confirmed via `getent group cooklang` on forge.
        recipesDir = config.modules.services.cooklang.recipeDir or "/data/cooklang/recipes";
        recipesGroup = config.modules.services.cooklang.group or "cooklang";

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
        };

        # Sops-managed env file containing at minimum:
        #   HOMELAB_MCP_POCKETID_CLIENT_SECRET=<from PocketID admin UI>
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

    # Service-down alert (native systemd service, not a container).
    (lib.mkIf (config.services.homelab-mcp.enable or false) (
      let
        forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
      in
      {
        modules.alerting.rules."homelab-mcp-service-down" =
          forgeDefaults.mkSystemdServiceDownAlert "homelab-mcp" "HomelabMCP" "Claude tools bridge";
      }
    ))
  ];
}
