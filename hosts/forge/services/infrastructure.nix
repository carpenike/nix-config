# Infrastructure Device Widgets for Homepage
#
# This file contains Homepage widget contributions for infrastructure devices
# that don't have dedicated service modules (routers, switches, NAS, etc.)
#
# These are read-only monitoring widgets - no services are deployed.
# Credentials are managed via SOPS and injected through Homepage environment.

{ config, lib, ... }:

let
  homepageEnabled = config.modules.services.homepage.enable or false;
in
{
  config = lib.mkIf homepageEnabled {
    # Mikrotik RB5009 Core Router
    # Shows: CPU load, memory usage, uptime, DHCP leases
    # Credentials: mikrotik/homepage-password in SOPS
    # Router config: /user add name=homepage group=read password=xxx
    # NOTE: Using HTTP because RouterOS REST API over HTTPS causes ECONNRESET
    # on some firmware versions. Since this is internal network, HTTP is acceptable.
    modules.services.homepage.contributions.mikrotik = {
      group = "Infrastructure";
      name = "Mikrotik Router";
      icon = "mikrotik";
      href = "https://10.20.0.1";
      description = "RB5009 Core Router";
      widget = {
        type = "mikrotik";
        url = "http://10.20.0.1"; # HTTP for REST API (HTTPS causes ECONNRESET)
        username = "homepage";
        password = "{{HOMEPAGE_VAR_MIKROTIK_PASSWORD}}";
      };
    };

    # Caddy Reverse Proxy
    # Shows: Active requests, upstreams, request/response stats
    # No authentication required - uses local admin API
    modules.services.homepage.contributions.caddy = {
      group = "Infrastructure";
      name = "Caddy";
      icon = "caddy";
      href = "https://caddy.holthome.net";
      description = "Reverse Proxy";
      widget = {
        type = "caddy";
        url = "http://localhost:2019";
      };
    };

    # Cloudflare Tunnel
    # Shows: Tunnel status, connections, latency
    # Credentials: networking/cloudflare/homepage-api-token and account-id in SOPS
    # API token requires: Account.Cloudflare Tunnel:Read permission
    modules.services.homepage.contributions.cloudflared = {
      group = "Infrastructure";
      name = "Cloudflare Tunnel";
      icon = "cloudflare";
      href = "https://one.dash.cloudflare.com";
      description = "External Access";
      widget = {
        type = "cloudflared";
        accountid = "{{HOMEPAGE_VAR_CLOUDFLARED_ACCOUNT_ID}}";
        tunnelid = "349603ab-49ed-4e49-bb76-6d803d8b978e";
        key = "{{HOMEPAGE_VAR_CLOUDFLARED_API_TOKEN}}";
      };
    };

    # Omada SDN Controller (runs on luna)
    # Shows: Connected devices, clients, alerts
    # Credentials: omada/homepage-username and omada/homepage-password in SOPS
    # Create a read-only user in Omada controller for Homepage
    modules.services.homepage.contributions.omada = {
      group = "Infrastructure";
      name = "Omada";
      icon = "omada";
      href = "https://omada.holthome.net";
      description = "SDN Controller";
      widget = {
        type = "omada";
        url = "https://omada.holthome.net";
        username = "{{HOMEPAGE_VAR_OMADA_USERNAME}}";
        password = "{{HOMEPAGE_VAR_OMADA_PASSWORD}}";
        site = "SLC"; # Site name in Omada controller
      };
    };

    # Future infrastructure widgets can be added here:
    # - TrueNAS / Synology NAS
    # - Managed switches
    # - Access points (if not using Omada/UniFi controller)
    # - PDUs
    # - etc.
  };
}
