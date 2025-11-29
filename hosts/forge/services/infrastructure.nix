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
    modules.services.homepage.contributions.mikrotik = {
      group = "Infrastructure";
      name = "Mikrotik Router";
      icon = "mikrotik";
      href = "https://10.20.0.1";
      description = "RB5009 Core Router";
      widget = {
        type = "mikrotik";
        url = "https://10.20.0.1";
        username = "homepage";
        password = "{{HOMEPAGE_VAR_MIKROTIK_PASSWORD}}";
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
