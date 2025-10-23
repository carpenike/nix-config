# Generate DNS records from Caddy virtual hosts for declarative BIND zone management
# This module exports a function that generates DNS A records from Caddy virtual hosts
# The records are meant to be included in the base BIND zone file (SOPS secret)
#
# Architecture:
# - Kubernetes services use external-dns + rndc for dynamic updates
# - Caddy virtual hosts use declarative zone records (this module)
{ lib, config, ... }:
with lib;
let
  cfg = config.modules.services.caddy;

  # Import shared DNS utilities (relative to repository root)
  dnsLib = import ../../../../../lib/dns.nix { inherit lib; };

  # Get the host's primary IP address from host configuration
  hostIP = config.my.hostIp or ""; # Empty string if not configured

  # Generate DNS A records from enabled virtual hosts
  # Returns newline-separated zone file entries
  generateDnsRecords = vhosts: domain:
    concatStringsSep "\n" (
      mapAttrsToList (name: vhost:
        if vhost.enable then
          let
            subdomain = dnsLib.extractSubdomain vhost.hostName domain;
            # Use relative name (subdomain only) for cleaner zone files
            recordName = if subdomain == vhost.hostName
                        then "${subdomain}."  # Absolute FQDN (fallback)
                        else subdomain;       # Relative subdomain
          in
          "${recordName}    IN    A    ${hostIP}"
        else ""
      ) vhosts
    );
in
{
  # Export the DNS records as a system option for BIND module consumption
  options.modules.services.caddy.dnsRecords = mkOption {
    type = types.lines;
    readOnly = true;
    description = "DNS A records generated from Caddy virtual hosts";
  };

  config = mkIf cfg.enable {
    # Generate DNS records from Caddy virtual hosts
    modules.services.caddy.dnsRecords = generateDnsRecords cfg.virtualHosts cfg.domain;
  };
}
