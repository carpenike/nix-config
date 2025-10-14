# Caddy Module v2.0 - Usage Examples

## Quick Start with Specialized Helpers

The easiest way to register services is using the specialized helpers from `lib/caddy-helpers.nix`:

### Public Service (No Auth)

```nix
{ config, lib, ... }:
let
  caddyHelpers = import ../../../../lib/caddy-helpers.nix { inherit lib; };
in
{
  config = caddyHelpers.mkPublicService {
    name = "myapp";
    subdomain = "myapp";
    port = 3000;
    securityLevel = "standard";  # minimal | standard | high
  };
}
```

### Authenticated Admin Interface

```nix
{ config, lib, ... }:
let
  caddyHelpers = import ../../../../lib/caddy-helpers.nix { inherit lib; };
in
{
  config = caddyHelpers.mkAuthenticatedService {
    name = "admin";
    subdomain = "admin";
    port = 8080;
    authUser = "admin";
    authPasswordHashEnvVar = "ADMIN_PASSWORD_HASH";
  };
}
```

### Secure Web Application

```nix
{ config, lib, ... }:
let
  caddyHelpers = import ../../../../lib/caddy-helpers.nix { inherit lib; };
in
{
  config = caddyHelpers.mkSecureWebApp {
    name = "webapp";
    subdomain = "app";
    port = 8080;
    requireAuth = false;
    allowFraming = false;  # Set true if embedding in iframes needed
  };
}
```

### HTTPS Backend (e.g., Omada, Unifi)

```nix
{ config, lib, ... }:
let
  caddyHelpers = import ../../../../lib/caddy-helpers.nix { inherit lib; };
in
{
  config = caddyHelpers.mkHttpsBackendService {
    name = "omada";
    subdomain = "omada";
    port = 8043;
    verifyTls = false;  # Self-signed cert
    acknowledgeInsecure = true;  # Required when verifyTls = false
    securityLevel = "standard";
  };
}
```

## Manual Configuration (Structured)

For custom requirements, configure directly:

### Basic HTTP Service

```nix
{ config, lib, ... }:
{
  modules.reverseProxy.virtualHosts.myservice = {
    enable = true;
    hostName = "myservice.${config.networking.domain}";

    backend = {
      scheme = "http";
      host = "localhost";
      port = 8080;
    };

    securityHeaders = {
      X-Frame-Options = "SAMEORIGIN";
      X-Content-Type-Options = "nosniff";
    };

    security.hsts = {
      enable = true;
      maxAge = 15552000;  # 6 months
      includeSubDomains = true;
    };
  };
}
```

### HTTPS Backend with Custom CA

```nix
{ config, lib, ... }:
{
  modules.reverseProxy.virtualHosts.secure-app = {
    enable = true;
    hostName = "secure.${config.networking.domain}";

    backend = {
      scheme = "https";
      host = "localhost";
      port = 8443;
      tls = {
        verify = true;  # ✅ Safe default
        caFile = /path/to/ca.crt;  # Custom CA
        sni = "internal.example.com";  # SNI override
      };
    };

    securityHeaders = {
      X-Frame-Options = "DENY";
      X-Content-Type-Options = "nosniff";
      Referrer-Policy = "strict-origin-when-cross-origin";
    };
  };
}
```

### Service with Authentication

```nix
{ config, lib, ... }:
{
  modules.reverseProxy.virtualHosts.admin = {
    enable = true;
    hostName = "admin.${config.networking.domain}";

    backend = {
      scheme = "http";
      host = "localhost";
      port = 8080;
    };

    auth = {
      user = "admin";
      passwordHashEnvVar = "ADMIN_PASSWORD_HASH";
    };

    securityHeaders = {
      X-Frame-Options = "DENY";
      X-Content-Type-Options = "nosniff";
      X-XSS-Protection = "1; mode=block";
    };
  };
}
```

### Disable DNS Publishing

```nix
{
  modules.reverseProxy.virtualHosts.internal = {
    enable = true;
    hostName = "internal.local";
    publishDns = false;  # Don't generate DNS records

    backend = {
      scheme = "http";
      host = "localhost";
      port = 9000;
    };
  };
}
```

## Advanced: Caddy-Specific Extensions

For Caddy-specific features, use vendor extensions:

```nix
{
  modules.reverseProxy.virtualHosts.advanced = {
    enable = true;
    hostName = "advanced.${config.networking.domain}";

    backend = {
      scheme = "http";
      host = "localhost";
      port = 8080;
    };

    # Backend-agnostic configuration
    securityHeaders = {
      X-Frame-Options = "SAMEORIGIN";
    };

    # Caddy-specific extensions
    vendorExtensions.caddy = {
      # Custom directives in reverse_proxy block
      reverseProxyBlock = ''
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
      '';

      # Custom directives at site level
      extraConfig = ''
        # Rate limiting
        rate_limit {
          zone dynamic {
            key {remote_host}
            events 100
            window 1m
          }
        }
      '';
    };
  };
}
```

## Security Best Practices

### ✅ DO: Use Safe Defaults

```nix
backend = {
  scheme = "https";
  host = "localhost";
  port = 8443;
  tls = {
    verify = true;  # ✅ Always verify by default
  };
};
```

### ❌ DON'T: Disable TLS Verification Without Acknowledgment

```nix
# This will FAIL validation:
backend = {
  scheme = "https";
  tls = {
    verify = false;  # ❌ Requires acknowledgeInsecure = true
  };
};

# This is correct (but use sparingly):
backend = {
  scheme = "https";
  tls = {
    verify = false;
    acknowledgeInsecure = true;  # ✅ Explicit acknowledgment required
  };
};
```

### ✅ DO: Use Structured Security Headers

```nix
# ✅ Backend-agnostic
securityHeaders = {
  X-Frame-Options = "DENY";
  X-Content-Type-Options = "nosniff";
};

# ❌ Caddy-specific (deprecated)
headers = ''
  header {
    X-Frame-Options "DENY"
  }
'';
```

### ✅ DO: Choose Appropriate Security Levels

```nix
# Public blog/content site
mkPublicService {
  securityLevel = "standard";  # Balanced
};

# Admin interface
mkAuthenticatedService {
  # Automatically uses "high" security
};

# Embedded widget (needs to allow framing)
mkSecureWebApp {
  allowFraming = true;  # Explicit opt-in
};
```

## Host-Level ACME Configuration

Configure ACME once per host instead of per-vhost:

```nix
# hosts/forge/default.nix
{
  modules.services.caddy = {
    enable = true;

    acme = {
      provider = "cloudflare";  # or "http", "zerossl", "letsencrypt"
      resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
      credentials = {
        envVar = "CLOUDFLARE_API_TOKEN";
      };
    };
  };
}
```

## Migration from v1.0

### Old (Deprecated)

```nix
modules.reverseProxy.virtualHosts.myservice = {
  enable = true;
  hostName = "myservice.holthome.net";
  proxyTo = "localhost:8080";  # ❌ String-based
  httpsBackend = false;  # ❌ Insecure by default
  headers = ''  # ❌ Caddy-specific string
    header {
      X-Frame-Options "DENY"
    }
  '';
  extraConfig = "...";  # ❌ Caddy-specific
};
```

### New (v2.0)

```nix
modules.reverseProxy.virtualHosts.myservice = {
  enable = true;
  hostName = "myservice.holthome.net";

  # ✅ Structured backend
  backend = {
    scheme = "http";
    host = "localhost";
    port = 8080;
    tls.verify = true;  # Safe default
  };

  # ✅ Backend-agnostic headers
  securityHeaders = {
    X-Frame-Options = "DENY";
  };

  # ✅ Caddy-specific in vendor extensions
  vendorExtensions.caddy = {
    extraConfig = "...";
  };
};
```

Or better yet, use helpers:

```nix
let
  caddyHelpers = import ../lib/caddy-helpers.nix { inherit lib; };
in
  caddyHelpers.mkPublicService {
    name = "myservice";
    subdomain = "myservice";
    port = 8080;
    securityLevel = "high";
  }
```

## Validation Errors

The new system provides helpful validation:

### Invalid Hostname

```
error: Virtual host 'myservice' has invalid hostname 'my service.com'.
       Must be a valid FQDN.
```

### Insecure TLS Without Acknowledgment

```
error: Virtual host 'omada' disables TLS verification without acknowledgment.
       When backend.tls.verify = false, you must set backend.tls.acknowledgeInsecure = true.
       WARNING: Disabling TLS verification is insecure and should only be used
       for trusted internal services.
```

### Duplicate Hostnames

```
warning: Duplicate hostname 'app.holthome.net' found in reverse proxy virtual hosts.
         This may cause conflicts.
```

## Testing

```bash
# Check configuration
nix flake check

# Build specific host
nixos-rebuild build --flake .#forge

# Preview generated Caddyfile
ssh forge.holthome.net 'sudo cat /etc/caddy/Caddyfile'

# Check DNS records
nix eval .#allCaddyDnsRecords --raw

# Test service
curl -I https://myservice.holthome.net
```

## See Also

- [Main Documentation](./modular-caddy-config.md)
- [Storage Module Guide](./storage-module-guide.md) - Similar structured pattern
- [Backup System](./backup-system-onboarding.md) - Helper function pattern
