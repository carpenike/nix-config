# hosts/forge/services/homelab-mcp.nix
#
# Homelab MCP server — Cloudflare-Access-authenticated bridge that
# exposes selected homelab APIs (cooklang, gatus, future categories)
# as MCP tools Claude can call.
#
# Architecture:
#
#   Claude.ai (iOS / web)
#     │ OAuth 2.1 + PKCE
#     ▼
#   Cloudflare Access (Access for SaaS / OIDC)   ← federates upstream
#     │                                            to PocketID for the
#     │ Cf-Access-Jwt-Assertion + Bearer JWT       passkey login UX
#     ▼
#   Cloudflare Tunnel → forge → Caddy (mcp.holthome.net)
#     │ HTTP, localhost-only
#     ▼
#   homelab-mcp.service (this module)
#     │ validates the CF Access JWT (per-app issuer + JWKS, RS256)
#     │ then dispatches to a tool handler
#     ▼
#   ├── cook.holthome.net      (recipe browse / shopping list)
#   ├── fedcook.holthome.net   (federation search across 62 feeds)
#   ├── gatus.holthome.net     (uptime monitoring)
#   └── /data/cooklang/recipes/claude/  (save_recipe writes here)
#
# Tool name convention: <category>_<verb>_<object>. See
# carpenike/mcp/AGENTS.md for the registry pattern that makes adding
# new tool categories cheap.
#
# Bootstrap:
#   1. Cloudflare dashboard side is already done (PocketID OIDC client,
#      CF Access "PocketID" login method, Access for SaaS app named
#      "Cooklang MCP" with the policy "Allow Ryan").
#   2. The OIDC client ID (64-char hex) was sops-encrypted into this
#      host's secrets.sops.yaml as homelab-mcp.cf-access-app-id.
#   3. DNS + tunnel ingress are declarative below — no manual CF
#      hostname is required (see cloudflare.tunnel block).
{ config, inputs, lib, pkgs, ... }:

let
  serviceName = "homelab-mcp";
  serviceDomain = "mcp.${config.networking.domain}";
  listenAddr = "127.0.0.1";
  # Upstream default is 9200 (avoids the well-known prometheus
  # node_exporter port 9100). We don't override it; surface it here
  # so the Caddy backend below has a single source of truth.
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

        # MCP user joins the cooklang group via the upstream module's
        # `recipesGroup` option (default "cooklang") so save_recipe
        # writes work. Confirmed via `getent group cooklang` on forge.
        recipesDir = config.modules.services.cooklang.recipeDir or "/data/cooklang/recipes";
        recipesGroup = config.modules.services.cooklang.group or "cooklang";

        # Non-secret declarative settings (visible in /nix/store).
        # CF Access team subdomain identifies WHICH cloudflareaccess.com
        # namespace owns our app; not sensitive.
        settings = {
          HOMELAB_MCP_CF_ACCESS_TEAM = "bigheadltd";
          HOMELAB_MCP_PUBLIC_BASE_URL = "https://${serviceDomain}";
          HOMELAB_MCP_COOKLANG_BASE_URL = "https://cook.holthome.net";
          HOMELAB_MCP_FEDERATION_BASE_URL = "https://fedcook.holthome.net";
          HOMELAB_MCP_GATUS_BASE_URL = "https://gatus.holthome.net";
        };

        # Sops-managed env file containing:
        #   HOMELAB_MCP_CF_ACCESS_APP_ID=<64-char OIDC Client ID from CF dashboard>
        #
        # Strictly speaking the App ID is not a secret (it appears in
        # every auth URL Claude constructs), but it's environment-
        # specific configuration that would leak the Access app's
        # identity if the Nix store were ever shared, so we route it
        # through sops alongside any future actual-secret values.
        environmentFile = config.sops.secrets."homelab-mcp/env".path;
      };

      # Caddy vhost — pure pass-through. Auth is enforced by the MCP
      # server itself (JWT middleware validates the CF Access bearer
      # token against the per-app JWKS). No SSO guard at Caddy because
      # the OAuth flow would loop if we tried.
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
