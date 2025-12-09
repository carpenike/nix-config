# Modular Caddy/Reverse Proxy Configuration

## Architecture Overview

The reverse proxy configuration has been refactored to support modular service registration from both:
- **Service modules** (`modules/nixos/services/*/`)
- **Host-specific configs** (`hosts/*/service.nix`)

This design decouples service registration from the Caddy implementation, preventing circular dependencies and enabling clean separation of concerns.

### Version 2.0 Improvements (2025-10)

The configuration has been enhanced with structured types and security improvements based on comprehensive code review:

✅ **Security Enhancements**:
- Safe TLS backend handling with explicit verification defaults
- Structured backend configuration (no more string-based `proxyTo`)
- Required acknowledgment for insecure TLS (`acknowledgeInsecure`)
- Configurable HSTS per-service with sensible defaults
- Comprehensive validation and assertions

✅ **Backend Agnosticism**:
- Structured `securityHeaders` (attrset, not string blobs)
- Vendor extensions for Caddy-specific config (`vendorExtensions.caddy`)
- Generic options that can translate to any proxy backend

✅ **DRY Improvements**:
- Centralized ACME configuration (no per-vhost duplication)
- Specialized helpers (`mkPublicService`, `mkAuthenticatedService`, `mkSecureWebApp`)
- Consistent pattern matching storage and backup modules

✅ **Validation**:
- FQDN validation with regex
- Port range validation
- Uniqueness checks across virtual hosts
- Security acknowledgment requirements

## Key Components

### 1. Registry Module
**Location**: `modules/nixos/services/reverse-proxy/registry.nix`

Declares the shared registration interface:
- `modules.reverseProxy.domain` - Base domain for virtual hosts
- `modules.reverseProxy.virtualHosts.<name>` - Virtual host registration

This module is imported globally, so any config (module or host-level) can register virtual hosts without depending on Caddy.

### 2. Caddy Module (Updated)
**Location**: `modules/nixos/services/caddy/default.nix`

**Changes**:
- Removed `modules.services.caddy.virtualHosts` option (moved to registry)
- Added `mkRenamedOptionModule` alias for backward compatibility
- Reads virtual hosts from `config.modules.reverseProxy.virtualHosts`
- Generates Caddyfile from registry entries

**Backward Compatibility**: Existing service modules that write to `modules.services.caddy.virtualHosts` continue working via the alias.

### 3. Helper Function
**Location**: `lib/register-vhost.nix`

Provides a DRY registration helper (optional):

```nix
{ registerVirtualHost } = import ../lib/register-vhost.nix { inherit lib; };

config = registerVirtualHost {
  name = "myservice";
  subdomain = "myservice";
  port = 8080;
  domain = config.networking.domain;  # Optional
  httpsBackend = false;
  auth = null;
  headers = "";
  extraConfig = "";
  condition = true;  # Optional enable condition
};
```

### 4. DNS Aggregation (Updated)
**Location**: `lib/dns-aggregate.nix`

**Changes**:
- Now reads from `config.modules.reverseProxy.virtualHosts` (clean break)
- Still works with existing hosts due to the alias
- Generates DNS records from all registered virtual hosts across fleet

## Usage Patterns

### Pattern 1: Service Module Registration (Existing)

Service modules in `modules/nixos/services/*/` can register directly:

```nix
# modules/nixos/services/myservice/default.nix
{ config, lib, ... }:
let
  cfg = config.modules.services.myservice;
in
{
  options.modules.services.myservice = {
    enable = lib.mkEnableOption "myservice";
    # ... other options
  };

  config = lib.mkIf cfg.enable {
    # Direct registration (new path)
    modules.reverseProxy.virtualHosts.myservice = {
      enable = true;
      hostName = "myservice.${config.networking.domain}";
      proxyTo = "localhost:8080";
      httpsBackend = false;
      auth = null;
      extraConfig = "";
    };

    # OR use the old path (backward compatible via alias)
    modules.services.caddy.virtualHosts.myservice = { ... };

    # Service configuration
    systemd.services.myservice = { ... };
  };
}
```

### Pattern 2: Host-Specific Registration (New)

Host config files (e.g., `hosts/forge/dispatcharr.nix`) can now register:

```nix
# hosts/forge/dispatcharr.nix
{ config, lib, ... }:
let
  dispatcharrEnabled = true;
  dispatcharrPort = 9191;
in
{
  config = lib.mkMerge [
    # Reverse proxy registration
    (lib.mkIf dispatcharrEnabled {
      modules.reverseProxy.virtualHosts.dispatcharr = {
        enable = true;
        hostName = "dispatcharr.${config.networking.domain}";
        proxyTo = "localhost:${toString dispatcharrPort}";
        httpsBackend = false;
        auth = null;
        extraConfig = ''
          header {
            X-Frame-Options "SAMEORIGIN"
            X-Content-Type-Options "nosniff"
          }
        '';
      };
    })

    # Service configuration
    {
      modules.services.dispatcharr = {
        enable = dispatcharrEnabled;
        # ... rest of config
      };
    }
  ];
}
```

### Pattern 3: Using the Helper Function

For even more concise registration:

```nix
{ config, lib, ... }:
let
  vhostHelper = import ../../../../lib/register-vhost.nix { inherit lib; };
  cfg = config.modules.services.myservice;
in
{
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (vhostHelper.registerVirtualHost {
      name = "myservice";
      subdomain = "myservice";
      port = cfg.port;
      domain = config.networking.domain;
      httpsBackend = false;
    })
    {
      # Service configuration
      systemd.services.myservice = { ... };
    }
  ]);
}
```

## Migration Guide

### Migrating Existing Service Modules

**Option A: No changes needed** (backward compatible via alias)
- Existing modules using `modules.services.caddy.virtualHosts` continue working

**Option B: Update to new path** (recommended)
```nix
# Old:
modules.services.caddy.virtualHosts.myservice = { ... };

# New:
modules.reverseProxy.virtualHosts.myservice = { ... };
```

### Adding New Services

**For service modules**: Use either path (new preferred)
**For host configs**: Use `modules.reverseProxy.virtualHosts.*`

## Benefits

1. **Decoupled Architecture**
   - Services don't depend on Caddy module
   - Host configs can register without module wrappers
   - Future flexibility to swap proxy backends

2. **No Circular Dependencies**
   - Registry is a standalone, shared interface
   - Service modules and host configs write to registry
   - Caddy reads from registry to generate config

3. **Backward Compatible**
   - Existing service modules work unchanged
   - Gradual migration path available
   - DNS aggregation continues functioning

4. **Clean Separation of Concerns**
   - Registration interface separate from implementation
   - Host-level and module-level use same interface
   - Single source of truth for virtual host definitions

5. **DRY with Helper**
   - Optional helper reduces boilerplate
   - Consistent registration pattern
   - Easy to extend with new features

## DNS Record Generation

DNS records are automatically generated from registered virtual hosts:

1. **Per-Host**: `modules.services.caddy.dnsRecords` (reads from registry)
2. **Fleet-Wide**: `lib/dns-aggregate.nix` scans all hosts' registry entries
3. **Output**: `nix eval .#allCaddyDnsRecords --raw`

The DNS aggregation now reads from `modules.reverseProxy.virtualHosts`, ensuring consistency across the fleet.

## Testing

Test the configuration:

```fish
# Check flake evaluation
nix flake check

# View generated DNS records
nix eval .#allCaddyDnsRecords --raw

# Build specific host
nixos-rebuild build --flake .#forge

# Preview Caddy configuration
ssh forge.holthome.net 'sudo cat /etc/caddy/Caddyfile'
```

## Files Modified

- ✅ **Created**: `modules/nixos/services/reverse-proxy/registry.nix`
- ✅ **Created**: `lib/register-vhost.nix`
- ✅ **Updated**: `modules/nixos/services/caddy/default.nix`
- ✅ **Updated**: `modules/nixos/services/caddy/dns-records.nix`
- ✅ **Updated**: `modules/nixos/services/default.nix`
- ✅ **Updated**: `lib/dns-aggregate.nix`
- ✅ **Updated**: `hosts/forge/dispatcharr.nix`

## Next Steps

1. **Test on forge**: Deploy and verify Dispatcharr is accessible
2. **Migrate other services**: Gradually update service modules to use new path
3. **Add authentication**: Configure basic auth for Dispatcharr if needed
4. **Monitor DNS**: Verify DNS records are generated correctly
