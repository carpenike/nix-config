# Aggregates DNS records from all hosts' Caddy virtual hosts
# This provides a single source of truth for DNS records across the entire fleet
#
# Usage: Import this in flake.nix and pass all nixosConfigurations + darwinConfigurations
{ lib }:

hosts:
let
  # Import shared DNS utilities
  dnsLib = import ./dns.nix { inherit lib; };

  # Collect DNS records from a single host
  collectHostRecords = name: hostCfg:
    let
      # Use tryEval to safely access potentially undefined options
      ipResult = builtins.tryEval (hostCfg.config.my.hostIp or null);
      # NOTE: Changed from modules.services.caddy to modules.reverseProxy (clean break)
      registryResult = builtins.tryEval (hostCfg.config.modules.reverseProxy or null);
      caddyResult = builtins.tryEval (hostCfg.config.modules.services.caddy or null);

      # Extract values if evaluation succeeded
      hostIp = if ipResult.success then ipResult.value else null;
      registryCfg = if registryResult.success then registryResult.value else null;
      caddyCfg = if caddyResult.success then caddyResult.value else null;
      domain = if registryCfg != null then (registryCfg.domain or "holthome.net")
               else if caddyCfg != null then (caddyCfg.domain or "holthome.net")
               else "holthome.net";
    in
      # Only process hosts with virtual hosts configured and IP configured
      # Check Caddy is enabled (if caddy module is loaded) or if registry has vhosts
      if hostIp != null && registryCfg != null && (caddyCfg == null || caddyCfg.enable or false) then
        lib.mapAttrsToList (vhostName: vhost:
          if (vhost.enable or false) && (vhost.publishDns or true) then
            let
              subdomain = dnsLib.extractSubdomain vhost.hostName domain;
              # Use relative name for zone file
              recordName = if subdomain == vhost.hostName
                          then "${subdomain}."  # Absolute FQDN
                          else subdomain;        # Relative subdomain
            in
              "${recordName}    IN    A    ${hostIp}"
          else null
        ) (registryCfg.virtualHosts or {})
      else [];

  # Collect from all hosts and flatten
  allRecords = lib.flatten (lib.mapAttrsToList collectHostRecords hosts);

  # Filter out nulls and join with newlines
  validRecords = lib.filter (r: r != null) allRecords;
in
  lib.concatStringsSep "\n" validRecords
