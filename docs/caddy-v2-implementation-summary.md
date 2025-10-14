# Caddy Module v2.0 - Implementation Summary

## Changes Implemented (2025-10-13)

This document summarizes all changes made to the Caddy reverse proxy system based on comprehensive code review by Gemini 2.5 Pro and GPT-5.

### 🎯 Goals Achieved

✅ **Security Enhancements**
- Safe TLS backend handling with explicit verification defaults
- Required acknowledgment for insecure TLS configurations
- Comprehensive validation and assertions
- Configurable HSTS per virtual host

✅ **Backend Agnosticism**
- Structured options instead of string blobs
- Vendor extensions for proxy-specific config
- Generic headers that can translate to any backend

✅ **DRY Improvements**
- Centralized ACME configuration
- Specialized helper functions
- Consistent pattern matching storage and backup modules

✅ **Validation & Safety**
- FQDN validation with regex
- Port range validation (1-65535)
- Hostname uniqueness checks
- Security acknowledgment requirements

---

## Files Modified

### 1. Registry Module (Enhanced)
**File**: `hosts/_modules/nixos/services/reverse-proxy/registry.nix`

**Major Changes**:
- Replaced `proxyTo` (string) with structured `backend` config:
  - `scheme`: "http" | "https"
  - `host`: hostname/IP
  - `port`: 1-65535 (validated)
  - `tls`: verification, SNI, CA file options
- Replaced `headers` (types.lines) with `securityHeaders` (attrset)
- Added `security.hsts` configuration
- Added `vendorExtensions.caddy` for Caddy-specific config
- Added `publishDns` flag for DNS record control
- Implemented comprehensive validation:
  - FQDN regex validation
  - Port range checks
  - TLS verification acknowledgment requirement
  - Hostname uniqueness warnings

**Backward Compatibility**:
- `proxyTo`, `headers`, `extraConfig` marked deprecated with warnings
- Will continue working but generate deprecation warnings

### 2. Caddy Module (Enhanced)
**File**: `hosts/_modules/nixos/services/caddy/default.nix`

**Major Changes**:
- Added centralized ACME configuration:
  ```nix
  modules.services.caddy.acme = {
    provider = "cloudflare";
    resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
    credentials.envVar = "CLOUDFLARE_API_TOKEN";
  };
  ```
- Removed per-vhost ACME duplication
- Enhanced Caddyfile generation with:
  - Safe TLS backend transport handling
  - Structured security header generation
  - HSTS configuration per vhost
- Added helper functions:
  - `buildBackendUrl`: Convert structured config to URL
  - `generateTlsTransport`: Generate safe TLS config
  - `generateSecurityHeaders`: Convert attrset to headers

**Backward Compatibility**:
- Legacy `reverseProxy` option still supported
- Old string-based configs still work via vendor extensions

### 3. Helper Library (New)
**File**: `lib/caddy-helpers.nix`

**New Specialized Helpers**:

1. **`mkPublicService`**: Public services without auth
   - Security levels: minimal, standard, high
   - Automatic HSTS configuration
   - Standard security headers

2. **`mkAuthenticatedService`**: Admin interfaces with basic auth
   - High security by default
   - Comprehensive security headers
   - Built-in HSTS

3. **`mkSecureWebApp`**: Web applications
   - Optional authentication
   - CSP headers
   - Iframe control
   - Full security suite

4. **`mkHttpsBackendService`**: Services with HTTPS backends
   - Safe TLS verification defaults
   - Explicit insecure acknowledgment
   - SNI and CA support

5. **`registerVirtualHost`**: Legacy compatibility
   - Backward compatible with old helper
   - Maps to new structured config

### 4. DNS Aggregation (Updated)
**File**: `lib/dns-aggregate.nix`

**Changes**:
- Added `publishDns` flag check
- Maintained backward compatibility

### 5. Example Migration (Updated)
**File**: `hosts/forge/dispatcharr.nix`

**Changes**:
- Migrated from string-based `proxyTo` to structured `backend`
- Converted string headers to `securityHeaders` attrset
- Added explicit `security.hsts` configuration
- Demonstrates new patterns

### 6. Documentation (New)
**Files Created**:
- `docs/caddy-v2-usage-examples.md`: Comprehensive usage guide
- Updated `docs/modular-caddy-config.md` with v2.0 improvements

---

## Migration Guide

### Quick Migration (Use Helpers)

**Before (v1.0)**:
```nix
modules.reverseProxy.virtualHosts.myapp = {
  enable = true;
  hostName = "myapp.holthome.net";
  proxyTo = "localhost:8080";
  httpsBackend = false;
  headers = ''
    header {
      X-Frame-Options "DENY"
    }
  '';
};
```

**After (v2.0 - Recommended)**:
```nix
let
  caddyHelpers = import ../lib/caddy-helpers.nix { inherit lib; };
in
  caddyHelpers.mkPublicService {
    name = "myapp";
    subdomain = "myapp";
    port = 8080;
    securityLevel = "high";
  }
```

### Manual Migration (Full Control)

**After (v2.0 - Manual)**:
```nix
modules.reverseProxy.virtualHosts.myapp = {
  enable = true;
  hostName = "myapp.holthome.net";

  backend = {
    scheme = "http";
    host = "localhost";
    port = 8080;
    tls.verify = true;  # Safe default
  };

  securityHeaders = {
    X-Frame-Options = "DENY";
  };

  security.hsts = {
    enable = true;
    maxAge = 31536000;
    includeSubDomains = true;
  };
};
```

### HTTPS Backend Migration

**Before (v1.0 - INSECURE)**:
```nix
httpsBackend = true;  # Automatically disables verification!
```

**After (v2.0 - SECURE)**:
```nix
backend = {
  scheme = "https";
  host = "localhost";
  port = 8443;
  tls = {
    verify = true;  # ✅ Safe default
    # OR for self-signed:
    # verify = false;
    # acknowledgeInsecure = true;  # Required!
  };
};
```

### Centralized ACME

**Before (v1.0)**:
```nix
# Duplicated in every vhost:
tls {
  dns cloudflare {env.CLOUDFLARE_API_TOKEN}
  resolvers 1.1.1.1:53 8.8.8.8:53
}
```

**After (v2.0)**:
```nix
# Once per host:
modules.services.caddy.acme = {
  provider = "cloudflare";
  resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
  credentials.envVar = "CLOUDFLARE_API_TOKEN";
};
```

---

## Validation Examples

### ✅ Pass: Safe Configuration
```nix
backend = {
  scheme = "https";
  tls.verify = true;  # ✅ Safe
};
```

### ❌ Fail: Insecure Without Acknowledgment
```nix
backend = {
  scheme = "https";
  tls.verify = false;  # ❌ Missing acknowledgeInsecure
};
```
**Error**: `Virtual host 'myapp' disables TLS verification without acknowledgment...`

### ✅ Pass: Explicit Acknowledgment
```nix
backend = {
  scheme = "https";
  tls = {
    verify = false;
    acknowledgeInsecure = true;  # ✅ Explicit
  };
};
```

### ❌ Fail: Invalid FQDN
```nix
hostName = "my app.com";  # Spaces not allowed
```
**Error**: `Virtual host 'myapp' has invalid hostname 'my app.com'. Must be a valid FQDN.`

### ⚠️ Warn: Duplicate Hostname
```nix
# In two different files:
hostName = "app.holthome.net";
```
**Warning**: `Duplicate hostname 'app.holthome.net' found in reverse proxy virtual hosts...`

---

## Testing Results

### Forge Build Status
✅ Successfully builds with new configuration
✅ Dispatcharr migrated to new structured format
✅ All validations working correctly

### Known Issues
- Luna configuration needs review (pre-existing, unrelated to changes)

### Test Commands
```bash
# Validate configuration
nix flake check

# Build specific host
nixos-rebuild build --flake .#forge

# Preview generated Caddyfile
ssh forge.holthome.net 'sudo cat /etc/caddy/Caddyfile'

# Check DNS records
nix eval .#allCaddyDnsRecords --raw
```

---

## Benefits Realized

### Security
1. **Safe TLS Defaults**: Backend TLS verification enabled by default
2. **Explicit Insecure**: Required acknowledgment for disabling verification
3. **Structured Headers**: Type-safe security header configuration
4. **Configurable HSTS**: Per-service HSTS control with safe defaults

### Maintainability
1. **Structured Types**: attrsets instead of string blobs
2. **Validation**: Comprehensive checks catch errors early
3. **DRY**: Centralized ACME, specialized helpers reduce boilerplate
4. **Backend Agnostic**: Can migrate to Traefik/nginx without rewriting services

### Consistency
1. **Matches Storage Module**: Same structured pattern as datasets.nix
2. **Matches Backup Helpers**: Same helper pattern as backup-helpers.nix
3. **Clear Separation**: Registry (what) vs Implementation (how)

---

## Next Steps (Optional Future Enhancements)

### Priority: Medium
- [ ] Create migration script for bulk service updates
- [ ] Add rate limiting options to registry
- [ ] Add health check configuration
- [ ] Support IPv6 (AAAA records)

### Priority: Low
- [ ] Add WAF integration options
- [ ] Support multiple backend hosts (load balancing)
- [ ] Add circuit breaker configuration
- [ ] Generate monitoring dashboards from registry

---

## Review Feedback Summary

### Gemini 2.5 Pro (Critical Review)
**Score**: 9/10

**Key Points**:
- ✅ Architecture is sound
- ✅ Decoupling goals achieved
- ❌ Original registry used string blobs (NOW FIXED)
- ❌ Missing validation (NOW ADDED)
- Recommendation: Adopt structured types like storage module ✅ **IMPLEMENTED**

### GPT-5 (Architectural Review)
**Score**: High confidence

**Key Points**:
- ✅ Clear separation of concerns
- ✅ Backward compatibility well handled
- ❌ Insecure TLS defaults (NOW FIXED)
- ❌ ACME duplication (NOW CENTRALIZED)
- ❌ Missing validation (NOW COMPREHENSIVE)
- Recommendation: Follow storage module patterns ✅ **IMPLEMENTED**

---

## Comparison: Before vs After

| Aspect | v1.0 (Before) | v2.0 (After) |
|--------|---------------|--------------|
| **Backend Config** | String `proxyTo` | Structured `backend.*` |
| **Headers** | String blob | Attrset `securityHeaders` |
| **TLS Backend** | Insecure by default | Safe by default |
| **ACME** | Per-vhost duplication | Centralized config |
| **Validation** | Minimal | Comprehensive |
| **Security** | Implicit | Explicit acknowledgment |
| **Backend Agnostic** | No (Caddy-specific) | Yes (structured) |
| **Helpers** | Basic | Specialized (4 types) |
| **Pattern Match** | Partial | Full (storage/backup) |

---

## Documentation

**Created**:
- ✅ `/docs/caddy-v2-usage-examples.md` - Comprehensive usage guide
- ✅ Updated `/docs/modular-caddy-config.md` - Architecture overview
- ✅ This implementation summary

**Updated**:
- ✅ `hosts/forge/dispatcharr.nix` - Example migration

---

## Acknowledgments

This refactoring was based on comprehensive code review by:
- **Gemini 2.5 Pro**: Critical analysis and design pattern comparison
- **GPT-5**: Architectural review and security analysis

Both models identified the same core issues and recommended similar solutions, validating the implementation approach.

---

## Questions or Issues?

Refer to:
1. `/docs/caddy-v2-usage-examples.md` for usage patterns
2. `/docs/modular-caddy-config.md` for architecture details
3. `/lib/caddy-helpers.nix` for helper function signatures
4. `/hosts/forge/dispatcharr.nix` for real-world example
