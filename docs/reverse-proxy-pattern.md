# Reverse Proxy Design Pattern

This document defines the standardized approach for integrating services with Caddy reverse proxy in this NixOS configuration.

## Design Philosophy

**Single Implementation Principle**: We use only Caddy as our reverse proxy. All service integrations register directly with the Caddy module using a consistent, structured pattern that eliminates syntax errors and provides type safety.

**Key Principles:**
- ✅ **Direct integration** - Services register with `modules.services.caddy.virtualHosts` directly
- ✅ **Structured configuration** - Type-safe backend and security options
- ✅ **Security by default** - HSTS enabled by default, structured security headers
- ✅ **Single code path** - One way to configure reverse proxy, eliminating maintenance burden
- ❌ **No abstractions** - No "backend-agnostic" registries or intermediate layers

## Standard Pattern

### Service Module Integration

Services should register their reverse proxy requirements using this exact pattern:

```nix
# In service module (e.g., hosts/_modules/nixos/services/myservice/default.nix)
modules.services.caddy.virtualHosts.${cfg.reverseProxy.subdomain} = mkIf cfg.reverseProxy.enable {
  enable = true;
  hostName = "${cfg.reverseProxy.subdomain}.${config.networking.domain or "holthome.net"}";

  # Structured backend configuration
  backend = {
    scheme = "http";  # or "https"
    host = cfg.listenAddress;  # usually "127.0.0.1" or "localhost"
    port = cfg.port;
    # Optional TLS settings for HTTPS backends
    tls = {
      verify = true;
      sni = null;
      caFile = null;
    };
  };

  # Authentication (optional)
  auth = cfg.reverseProxy.auth;  # null or { user = "..."; passwordHashEnvVar = "..."; }

  # Security headers (recommended)
  security = {
    # HSTS is enabled by default with sensible settings
    hsts.enable = true;  # Can be disabled if needed

    # Custom security headers
    customHeaders = {
      "X-Frame-Options" = "SAMEORIGIN";  # or "DENY" for higher security
      "X-Content-Type-Options" = "nosniff";
      "X-XSS-Protection" = "1; mode=block";
      "Referrer-Policy" = "strict-origin-when-cross-origin";
    };
  };

  # Caddy-specific directives inside reverse_proxy block (optional)
  reverseProxyBlock = ''
    header_up Host {upstream_hostport}
    header_up X-Real-IP {remote_host}
  '';

  # Additional site-level Caddy directives (optional)
  extraConfig = ''
    # Any additional Caddy directives for this virtual host
  '';
};
```

### Service Module Options

Services should provide these standard reverse proxy options:

```nix
options.modules.services.myservice = {
  # ... other service options ...

  reverseProxy = {
    enable = mkEnableOption "Caddy reverse proxy for MyService";

    subdomain = mkOption {
      type = types.str;
      default = "myservice";
      description = "Subdomain for the reverse proxy";
    };

    auth = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          user = mkOption {
            type = types.str;
            description = "Username for basic authentication";
          };
          passwordHashEnvVar = mkOption {
            type = types.str;
            description = "Environment variable containing bcrypt password hash";
          };
        };
      });
      default = null;
      description = "Authentication configuration";
    };
  };
};
```

## Caddy Module Options Reference

### Complete Option Structure

```nix
modules.services.caddy.virtualHosts.<name> = {
  enable = mkEnableOption "this virtual host";

  hostName = mkOption {
    type = types.str;
    description = "Fully qualified domain name";
    example = "grafana.holthome.net";
  };

  backend = mkOption {
    type = types.submodule {
      options = {
        scheme = mkOption {
          type = types.enum [ "http" "https" ];
          default = "http";
          description = "Backend protocol";
        };
        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "Backend host address";
        };
        port = mkOption {
          type = types.port;
          description = "Backend port";
        };
        tls = mkOption {
          type = types.submodule {
            options = {
              verify = mkOption {
                type = types.bool;
                default = true;
                description = "Verify backend TLS certificate";
              };
              sni = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Override TLS Server Name Indication";
              };
              caFile = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "Path to custom CA certificate file";
              };
            };
          };
          default = {};
          description = "TLS settings for HTTPS backends";
        };
      };
    };
    description = "Structured backend configuration";
  };

  auth = mkOption {
    type = types.nullOr (types.submodule {
      options = {
        user = mkOption { type = types.str; };
        passwordHashEnvVar = mkOption { type = types.str; };
      };
    });
    default = null;
    description = "Basic authentication configuration";
  };

  security = mkOption {
    type = types.submodule {
      options = {
        hsts = mkOption {
          type = types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Enable HSTS";
              };
              maxAge = mkOption {
                type = types.int;
                default = 15552000;  # 6 months
                description = "HSTS max-age in seconds";
              };
              includeSubDomains = mkOption {
                type = types.bool;
                default = true;
                description = "Include subdomains in HSTS";
              };
              preload = mkOption {
                type = types.bool;
                default = false;
                description = "Enable HSTS preload";
              };
            };
          };
          default = {};
          description = "HTTP Strict Transport Security settings";
        };
        customHeaders = mkOption {
          type = types.attrsOf types.str;
          default = {};
          description = "Custom security headers at site level";
        };
      };
    };
    default = {};
    description = "Security configuration";
  };

  reverseProxyBlock = mkOption {
    type = types.lines;
    default = "";
    description = "Directives for inside the reverse_proxy block";
    example = ''
      header_up Host {upstream_hostport}
      header_up X-Real-IP {remote_host}
    '';
  };

  extraConfig = mkOption {
    type = types.lines;
    default = "";
    description = "Additional site-level Caddy directives";
  };
};
```

## Common Patterns

### Web Applications (Grafana, Dispatcharr, etc.)

```nix
modules.services.caddy.virtualHosts.myapp = {
  enable = true;
  hostName = "myapp.holthome.net";
  backend = {
    host = "127.0.0.1";
    port = 3000;
  };
  security.customHeaders = {
    "X-Frame-Options" = "SAMEORIGIN";
    "X-Content-Type-Options" = "nosniff";
    "X-XSS-Protection" = "1; mode=block";
    "Referrer-Policy" = "strict-origin-when-cross-origin";
  };
};
```

### API Services (Loki, Prometheus, etc.)

```nix
modules.services.caddy.virtualHosts.myapi = {
  enable = true;
  hostName = "myapi.holthome.net";
  backend = {
    host = "127.0.0.1";
    port = 3100;
  };
  auth = {
    user = "admin";
    passwordHashEnvVar = "API_PASSWORD_HASH";
  };
  reverseProxyBlock = ''
    header_up Host {upstream_hostport}
    header_up X-Real-IP {remote_host}
  '';
  security.customHeaders = {
    "X-Frame-Options" = "DENY";
    "X-Content-Type-Options" = "nosniff";
  };
};
```

### HTTPS Backends

```nix
modules.services.caddy.virtualHosts.secure-backend = {
  enable = true;
  hostName = "secure.holthome.net";
  backend = {
    scheme = "https";
    host = "internal-service";
    port = 8443;
    tls = {
      verify = false;  # For self-signed certs
      sni = "internal.local";
    };
  };
  reverseProxyBlock = ''
    header_up Host {upstream_hostport}
  '';
};
```

## Configuration Generation

The Caddy module generates this Caddyfile structure:

```caddy
myapp.holthome.net {
  # ACME TLS configuration
  tls {
    dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    resolvers 1.1.1.1:53 8.8.8.8:53
  }

  # Security headers (site level)
  header {
    Strict-Transport-Security "max-age=15552000; includeSubDomains"
    X-Frame-Options "SAMEORIGIN"
    X-Content-Type-Options "nosniff"
    X-XSS-Protection "1; mode=block"
    Referrer-Policy "strict-origin-when-cross-origin"
  }

  # Basic authentication (if configured)
  basic_auth {
    admin {env.PASSWORD_HASH}
  }

  # Reverse proxy to backend
  reverse_proxy http://127.0.0.1:3000 {
    header_up Host {upstream_hostport}
    header_up X-Real-IP {remote_host}
  }

  # Additional site-level directives
  # (from extraConfig)
}
```

## Migration from Old Patterns

### From Legacy Registry Pattern

**OLD (deprecated):**
```nix
modules.reverseProxy.virtualHosts.myservice = {
  backend = { scheme = "http"; host = "localhost"; port = 3000; };
  securityHeaders = { "X-Frame-Options" = "SAMEORIGIN"; };
  vendorExtensions.caddy.reverseProxyBlock = "header_up Host {upstream_hostport}";
};
```

**NEW (correct):**
```nix
modules.services.caddy.virtualHosts.myservice = {
  backend = { host = "127.0.0.1"; port = 3000; };
  security.customHeaders = { "X-Frame-Options" = "SAMEORIGIN"; };
  reverseProxyBlock = "header_up Host {upstream_hostport}";
};
```

### From Legacy Caddy Pattern

**OLD (broken):**
```nix
modules.services.caddy.virtualHosts.myservice = {
  proxyTo = "localhost:3000";
  extraConfig = ''
    header {
      X-Frame-Options "SAMEORIGIN"
    }
  '';
};
```

**NEW (correct):**
```nix
modules.services.caddy.virtualHosts.myservice = {
  backend = { host = "127.0.0.1"; port = 3000; };
  security.customHeaders = { "X-Frame-Options" = "SAMEORIGIN"; };
};
```

## Best Practices

### Security Headers

**Always include these security headers for web applications:**
```nix
security.customHeaders = {
  "X-Frame-Options" = "SAMEORIGIN";  # or "DENY" for APIs
  "X-Content-Type-Options" = "nosniff";
  "X-XSS-Protection" = "1; mode=block";
  "Referrer-Policy" = "strict-origin-when-cross-origin";
};
```

### Authentication

**Use SOPS for password hashes:**
```nix
# In host secrets
sops.secrets."caddy/myservice_password" = {
  sopsFile = ./secrets.sops.yaml;
  mode = "0440";
  owner = "caddy";
  group = "caddy";
};

# In service config
auth = {
  user = "admin";
  passwordHashEnvVar = "MYSERVICE_PASSWORD_HASH";
};
```

### Service-Specific Headers

**For APIs that need specific headers:**
```nix
reverseProxyBlock = ''
  header_up Host {upstream_hostport}
  header_up X-Real-IP {remote_host}
  header_up X-Forwarded-Proto {scheme}
'';
```

### Host Binding

**Always bind services to localhost:**
```nix
# In service config
listenAddress = "127.0.0.1";  # or "localhost"

# In reverse proxy
backend = {
  host = "127.0.0.1";  # Match service binding
  port = cfg.port;
};
```

## Troubleshooting

### Common Issues

1. **Headers in wrong place** - Use `security.customHeaders` for site-level headers, `reverseProxyBlock` for proxy-level headers
2. **Missing HSTS** - HSTS is enabled by default, disable explicitly if needed
3. **Authentication not working** - Verify environment variable is set and hash is correct
4. **Service unreachable** - Check backend host/port matches service binding

### Validation

```bash
# Check Caddy configuration syntax
nix eval .#nixosConfigurations.forge.config.services.caddy.extraConfig --raw

# Validate NixOS configuration
nix flake check

# Test deployment
nix build .#nixosConfigurations.forge.config.system.build.toplevel
```

## DNS Integration

The Caddy module automatically integrates with DNS record generation:

```nix
# DNS records are automatically generated for each virtual host
# Available via: nix eval .#allCaddyDnsRecords --raw
# Manual addition to SOPS zone file still required
```

## Examples

See these reference implementations:
- **Grafana**: `hosts/_modules/nixos/services/grafana/default.nix`
- **Loki**: `hosts/_modules/nixos/services/loki/default.nix`
- **Monitoring**: `hosts/forge/monitoring-ui.nix`

This pattern provides type safety, eliminates syntax errors, ensures security by default, and maintains a single, maintainable code path for reverse proxy integration.
