# Modular Caddy/Reverse Proxy Configuration

## Architecture Overview

Reverse proxy configuration is contributory: virtual hosts are registered from both:
- **Service modules** (`modules/nixos/services/*/`)
- **Host-specific configs** (`hosts/*/services/*.nix`)

Contributors write to `modules.services.caddy.virtualHosts.<name>`; the Caddy module aggregates all registrations and generates the Caddyfile. This keeps service registration declarative and co-located with each service while Caddy remains the single implementation point.

### Version 2.0 Improvements (2025-10)

The configuration has been enhanced with structured types and security improvements based on comprehensive code review:

✅ **Security Enhancements**:
- Safe TLS backend handling with explicit verification defaults (`backend.tls.verify`)
- Structured backend configuration (preferred over string-based `proxyTo`)
- Configurable HSTS per-service with sensible defaults (`security.hsts`)
- Structured custom headers (`security.customHeaders`)
- caddy-security integration for authentication enforcement (`caddySecurity`)
- Comprehensive validation and assertions

✅ **DRY Improvements**:
- Centralized ACME configuration (no per-vhost duplication)
- Factory-generated services register automatically via their `reverseProxy` option
- Consistent pattern matching storage and backup modules

✅ **Validation**:
- Every enabled vhost must declare a `backend`, a legacy `proxyTo`, or `handleOnly = true` with `extraConfig`
- Uniqueness and consistency checks across virtual hosts

## Key Components

### 1. Caddy Module
**Location**: `modules/nixos/services/caddy/default.nix`

Owns the registration interface and the implementation:
- `modules.services.caddy.virtualHosts.<name>` - Virtual host registration (attrset of submodules)
- Generates the Caddyfile from all registered virtual hosts
- Validates registrations with assertions at eval time

Each virtual host submodule supports:

| Option | Purpose |
|--------|---------|
| `enable` | Enable this virtual host |
| `hostName` | Fully qualified domain name (e.g. `myservice.holthome.net`) |
| `backend` | Structured backend: `{ scheme, host, port, tls }` (**preferred**) |
| `proxyTo` | Legacy string backend address (use `backend` instead) |
| `handleOnly` | No `reverse_proxy` directive; serve entirely from `extraConfig` |
| `auth` | Basic auth (`user`, `passwordHashEnvVar`) |
| `caddySecurity` | caddy-security portal/policy enforcement, bypass paths, API keys |
| `security` | HSTS configuration and custom headers |
| `extraConfig` | Additional raw Caddyfile directives |
| `cloudflare` | Expose via Cloudflare Tunnel |

### 2. Service Factory Integration
**Location**: `lib/service-factory.nix`

Factory-generated container services (`mylib.mkContainerService`) get Caddy registration automatically from their `reverseProxy` submodule option:

```nix
modules.services.myservice = {
  enable = true;
  reverseProxy = {
    enable = true;
    hostName = "myservice.holthome.net";
  };
};
```

This registers `modules.services.caddy.virtualHosts.myservice` with a structured `backend` pointing at the container's loopback-published port (the factory's `bindAddress` defaults to `127.0.0.1`, so Caddy is the LAN entry point). It also auto-contributes a Gatus status-page endpoint probing `https://<hostName>` (tunable via the factory's `gatus.{enable,interval,conditions}` options).

### 3. DNS Record Generation
**Locations**: `modules/nixos/services/caddy/dns-records.nix`, `lib/dns-aggregate.nix`

- **Per-host**: `modules.services.caddy.dnsRecords` (read-only) renders A records from the host's registered virtual hosts
- **Fleet-wide**: `lib/dns-aggregate.nix` scans all hosts' virtual host registrations and emits combined zone records

## Usage Patterns

### Pattern 1: Factory Service (Preferred for Containers)

For factory-generated services, just set the `reverseProxy` option — no direct Caddy wiring needed:

```nix
# hosts/forge/services/myservice.nix
modules.services.myservice = {
  enable = true;
  reverseProxy = {
    enable = true;
    hostName = "myservice.${config.networking.domain}";
  };
};
```

### Pattern 2: Direct Registration (Hand-Rolled Modules)

Service modules in `modules/nixos/services/*/` register directly with a structured backend:

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
    modules.services.caddy.virtualHosts.myservice = {
      enable = true;
      hostName = "myservice.${config.networking.domain}";
      backend = {
        scheme = "http";
        host = "127.0.0.1";
        port = 8080;
      };
    };

    # Service configuration
    systemd.services.myservice = { ... };
  };
}
```

### Pattern 3: Host-Specific Registration

Host config files can register virtual hosts the same way, including security headers:

```nix
# hosts/forge/services/dispatcharr.nix
{ config, lib, ... }:
{
  modules.services.caddy.virtualHosts.dispatcharr = {
    enable = true;
    hostName = "dispatcharr.${config.networking.domain}";
    backend = {
      scheme = "http";
      host = "127.0.0.1";
      port = 9191;
    };
    security.customHeaders = {
      X-Frame-Options = "SAMEORIGIN";
      X-Content-Type-Options = "nosniff";
    };
  };
}
```

### Pattern 4: Handle-Only Virtual Hosts

For hosts that serve content without proxying (redirects, static responses):

```nix
modules.services.caddy.virtualHosts.redirect = {
  enable = true;
  hostName = "old.${config.networking.domain}";
  handleOnly = true;
  extraConfig = ''
    redir https://new.${config.networking.domain}{uri} permanent
  '';
};
```

## Migrating Legacy Registrations

Prefer the structured `backend` over the legacy string options:

```nix
# Old (legacy, still works):
modules.services.caddy.virtualHosts.myservice = {
  proxyTo = "localhost:8080";
  httpsBackend = false;
};

# New (preferred):
modules.services.caddy.virtualHosts.myservice = {
  backend = {
    scheme = "http";
    host = "127.0.0.1";
    port = 8080;
  };
};
```

> **Historical note**: An earlier refactor introduced a standalone registry (`modules.reverseProxy.virtualHosts` via `modules/nixos/services/reverse-proxy/registry.nix`) and a `registerVirtualHost` helper (`lib/register-vhost.nix`). That indirection was removed — registration happens directly on `modules.services.caddy.virtualHosts`, and `lib/register-vhost.nix` and `lib/caddy-helpers.nix` were deleted as dead code.

## Benefits

1. **Contributory Architecture**
   - Services declare their own virtual hosts, co-located with their config
   - Caddy aggregates all contributions into a single Caddyfile
   - Single source of truth for virtual host definitions

2. **Structured, Validated Configuration**
   - Typed `backend` submodule instead of free-form strings
   - Assertions catch misconfigured vhosts at eval time
   - Security options (HSTS, headers, auth) are first-class

3. **Zero Boilerplate for Factory Services**
   - `reverseProxy = { enable = true; hostName = ...; }` is all a container service needs
   - Loopback-bound container ports plus Caddy as the LAN entry point by default
   - Gatus monitoring comes along for free

## DNS Record Generation

DNS records are automatically generated from registered virtual hosts:

1. **Per-Host**: `modules.services.caddy.dnsRecords` (reads from `modules.services.caddy.virtualHosts`)
2. **Fleet-Wide**: `lib/dns-aggregate.nix` scans all hosts' registrations
3. **Output**: `nix eval .#allCaddyDnsRecords --raw`

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
