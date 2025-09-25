# DNSDist Shared Configuration

This document explains the DNSDist shared configuration pattern implemented for holthome.net infrastructure.

## Overview

The DNSDist shared configuration eliminates ~100+ lines of duplicate complex DNS routing logic between hosts while maintaining flexibility for host-specific customization.

## Configuration Structure

### Shared Infrastructure (All Hosts)
- Security polling disable
- Local BIND server (port 5391)
- Local AdGuard server (port 5390)
- CloudFlare DoH servers (general & kids safe)
- Packet cache configuration
- Basic routing rules for local domains
- ECS (EDNS Client Subnet) settings

### Host-Specific Options
- Additional DNS servers (e.g., RV DNS for Luna)
- Domain-specific routing rules
- Network subnet routing with different pools
- Extra configuration lines

## Usage Example

```nix
# hosts/luna/default.nix
modules.services.dnsdist = {
  enable = true;
  shared = {
    enable = true;

    # Luna has RV DNS server
    additionalServers = [{
      address = "192.168.88.1:53";
      pool = "rv";
      options = ''
        healthCheckMode = "lazy",
        checkInterval = 1800,
        # ... other options
      '';
    }];

    # Domain routing
    domainRouting = {
      "holtel.io" = "rv";
    };

    # Network routing
    networkRouting = [
      { subnet = "10.10.0.0/16"; pool = "adguard"; description = "lan"; }
      { subnet = "10.35.0.0/16"; pool = "cloudflare_general"; description = "guest vlan"; dropAfter = true; }
      # ... more rules
    ];
  };
};
```

## Configuration Options

### Basic Options
- `bindPort`: Local BIND server port (default: 5391)
- `adguardPort`: Local AdGuard server port (default: 5390)
- `localDomains`: Domains routed to BIND (default: ["unifi", "holthome.net", "10.in-addr.arpa"])

### Cache Options
- `cacheSize`: Packet cache size (default: 10000)
- `cacheMaxTTL`: Maximum TTL in seconds (default: 86400)
- `cacheTemporaryFailureTTL`: Temporary failure TTL (default: 60)

### Routing Options
- `networkRouting`: List of subnet-to-pool routing rules
- `domainRouting`: Domain-to-pool routing map
- `additionalServers`: Extra DNS servers beyond standard ones

### Advanced Options
- `extraConfig`: Additional DNSDist configuration lines

## Benefits

1. **Consistency**: All hosts use the same DNS hierarchy and routing logic
2. **Maintainability**: Single source of truth for DNS infrastructure
3. **Flexibility**: Easy host-specific customization without duplication
4. **Type Safety**: NixOS module system validates all options

## Migration Status

- ✅ **Luna**: Migrated to shared configuration
- ⚠️ **Rydev**: Has config file but DNSDist service not enabled
  - Config file: `/hosts/rydev/config/dnsdist.conf`
  - To enable: Add `dnsdist.enable = true` to rydev's configuration

## Notes

The rydev host has a DNSDist configuration file but the service is not enabled in its NixOS configuration. This may be intentional (development host) or an oversight. If DNSDist should be enabled on rydev, the shared configuration pattern can be applied there as well.
