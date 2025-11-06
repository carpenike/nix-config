# Authelia SSO Integration Pattern

## Overview

This document describes the modular, opt-in pattern for protecting services with Authelia SSO authentication. The implementation supports both local and cross-host Authelia instances.

## Key Features

✅ **Optional & Modular** - Services can easily opt-in via `reverseProxy.authelia.enable = true`
✅ **Cross-Host Support** - Services on one host can use Authelia on another host
✅ **API Bypass** - Supports bypassing authentication for specific paths (APIs, RSS feeds, etc.)
✅ **Automatic Rule Registration** - Access control rules are automatically generated and merged
✅ **No Helper Functions Needed** - Uses standardized submodule pattern
✅ **Backward Compatible** - Existing services without Authelia continue working

## Architecture

### 1. Type Definition (`hosts/_modules/lib/types.nix`)

The `reverseProxySubmodule` now includes an optional `authelia` submodule:

```nix
reverseProxySubmodule = types.submodule {
  options = {
    # ... existing options ...

    authelia = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          enable = mkEnableOption "Authelia SSO protection";

          instance = mkOption {
            type = types.str;
            default = "main";
            description = "Authelia instance name (supports multi-instance)";
          };

          autheliaHost = mkOption {
            type = types.str;
            default = "127.0.0.1";
            description = "Hostname where Authelia is running (supports cross-host)";
          };

          autheliaPort = mkOption {
            type = types.port;
            default = 9091;
          };

          autheliaScheme = mkOption {
            type = types.enum [ "http" "https" ];
            default = "http";
          };

          authDomain = mkOption {
            type = types.str;
            description = "Domain for authentication portal";
            example = "auth.holthome.net";
          };

          policy = mkOption {
            type = types.enum [ "bypass" "one_factor" "two_factor" ];
            default = "one_factor";
            description = "Authentication policy";
          };

          allowedGroups = mkOption {
            type = types.listOf types.str;
            default = [ "users" ];
            description = "Groups allowed to access this service";
          };

          bypassPaths = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "URL paths to bypass authentication";
            example = [ "/api" "/feed" "/rss" ];
          };

          bypassResources = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Regex patterns for bypass (more flexible)";
            example = [ "^/api/.*$" ];
          };
        };
      });
      default = null;
      description = "Authelia SSO protection (null = disabled)";
    };
  };
};
```

### 2. Service Module Integration

Each service module checks its `reverseProxy.authelia` configuration and:

1. **Adds forward_auth to Caddy registration** (with bypass routes if needed)
2. **Registers with Authelia** via `declarativelyProtectedServices`

Example implementation (from `sonarr/default.nix`):

```nix
# Caddy registration with Authelia support
modules.services.caddy.virtualHosts.sonarr = lib.mkIf (cfg.reverseProxy != null && cfg.reverseProxy.enable) (
  let
    hasAuthelia = cfg.reverseProxy.authelia != null && cfg.reverseProxy.authelia.enable;
    authCfg = cfg.reverseProxy.authelia;
    autheliaUrl = if hasAuthelia then
      "${authCfg.autheliaScheme}://${authCfg.autheliaHost}:${toString authCfg.autheliaPort}"
      else "";
    authRedirectUrl = if hasAuthelia then
      "https://${authCfg.authDomain}"
      else "";
  in {
    enable = true;
    hostName = cfg.reverseProxy.hostName;
    backend = { /* ... */ };

    # Disable basic auth if Authelia is enabled
    auth = if hasAuthelia then null else cfg.reverseProxy.auth;

    # Generate forward_auth configuration
    extraConfig = if hasAuthelia then ''
      # Bypass authentication for specific paths
      ${lib.optionalString (authCfg.bypassPaths != []) ''
      @bypass path ${lib.concatStringsSep " " authCfg.bypassPaths}
      route @bypass {
        reverse_proxy 127.0.0.1:${toString sonarrPort}
      }
      ''}

      # Forward auth for all other requests
      forward_auth ${autheliaUrl} {
        uri /api/verify?rd=${authRedirectUrl}
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
      }
    '' else cfg.reverseProxy.extraConfig;
  }
);

# Authelia rule registration
modules.services.authelia.accessControl.declarativelyProtectedServices.sonarr = lib.mkIf (
  cfg.reverseProxy != null &&
  cfg.reverseProxy.enable &&
  cfg.reverseProxy.authelia != null &&
  cfg.reverseProxy.authelia.enable
) {
  domain = cfg.reverseProxy.hostName;
  policy = authCfg.policy;
  subjects = map (g: "group:${g}") authCfg.allowedGroups;
  bypassResources =
    (map (path: "^${lib.escapeRegex path}/.*$") authCfg.bypassPaths)
    ++ authCfg.bypassResources;
};
```

### 3. Authelia Module Aggregation

The Authelia module automatically merges declarative rules with user-defined rules:

```nix
# In authelia/default.nix
access_control = {
  default_policy = cfg.accessControl.defaultPolicy;
  rules =
    # User-defined explicit rules (first priority)
    (map (rule: { /* ... */ }) cfg.accessControl.rules)
    ++
    # Auto-generated rules from service reverseProxy.authelia configs
    (lib.flatten (lib.mapAttrsToList (serviceName: svc:
      # Bypass rules first (higher priority)
      (lib.optionals (svc.bypassResources != []) [{
        domain = [ svc.domain ];
        policy = "bypass";
        resources = svc.bypassResources;
      }])
      ++
      # Main policy rule
      [{
        domain = [ svc.domain ];
        policy = svc.policy;
        subject = svc.subject;
      }]
    ) cfg.accessControl.declarativelyProtectedServices));
};
```

## Usage Examples

### Basic Protection (Username + Password)

```nix
services.myservice = {
  enable = true;
  reverseProxy = {
    enable = true;
    hostName = "myservice.holthome.net";

    authelia = {
      enable = true;
      authDomain = "auth.holthome.net";
      policy = "one_factor";
      allowedGroups = [ "users" ];
    };
  };
};
```

### Two-Factor Authentication Required

```nix
reverseProxy.authelia = {
  enable = true;
  authDomain = "auth.holthome.net";
  policy = "two_factor";  # Require 2FA
  allowedGroups = [ "admins" ];
};
```

### API Bypass for Integrations

```nix
reverseProxy.authelia = {
  enable = true;
  authDomain = "auth.holthome.net";
  policy = "one_factor";
  allowedGroups = [ "users" ];

  # Allow API access without authentication
  bypassPaths = [ "/api" "/feed" "/rss" ];
};
```

### Cross-Host Authelia

```nix
# Service on host A using Authelia on host B
reverseProxy.authelia = {
  enable = true;
  autheliaHost = "auth-server.holthome.net";  # Different host
  autheliaPort = 9091;
  autheliaScheme = "https";  # Cross-host typically uses HTTPS
  authDomain = "auth.holthome.net";
  policy = "one_factor";
  allowedGroups = [ "users" ];
};
```

### Admin-Only Service

```nix
reverseProxy.authelia = {
  enable = true;
  authDomain = "auth.holthome.net";
  policy = "two_factor";
  allowedGroups = [ "admins" ];  # Only admins can access
};
```

### Complex Bypass Patterns

```nix
reverseProxy.authelia = {
  enable = true;
  authDomain = "auth.holthome.net";
  policy = "one_factor";
  allowedGroups = [ "users" ];

  # Path-based bypass (simple)
  bypassPaths = [ "/api" ];

  # Regex-based bypass (advanced)
  bypassResources = [
    "^/api/.*$"           # All API endpoints
    "^/feed/.*\\.xml$"    # RSS feeds
    "^/health$"           # Health check
  ];
};
```

## Migration Guide

### From mkAutheliaProtectedService Helper

**Old (broken - helper function):**
```nix
let
  caddyHelpers = import ../lib/caddy-helpers.nix { inherit lib; };
in
  caddyHelpers.mkAutheliaProtectedService {
    name = "sonarr";
    subdomain = "sonarr";
    port = 8989;
    require2FA = false;
    allowedGroups = [ "admins" "users" ];
  }
```

**New (working - submodule):**
```nix
modules.services.sonarr = {
  enable = true;
  reverseProxy = {
    enable = true;
    hostName = "sonarr.holthome.net";

    authelia = {
      enable = true;
      authDomain = "auth.holthome.net";
      policy = "one_factor";  # or "two_factor" for require2FA = true
      allowedGroups = [ "admins" "users" ];
      bypassPaths = [ "/api" ];  # Don't forget API bypass for *arr apps!
    };
  };
};
```

## Implementation Checklist

To add Authelia support to a service module:

- [ ] Service uses `sharedTypes.reverseProxySubmodule` for its reverseProxy option
- [ ] Caddy registration checks `cfg.reverseProxy.authelia.enable`
- [ ] Generate `forward_auth` directive with proper Authelia URL
- [ ] Handle `bypassPaths` with Caddy `@bypass` matcher and `route` block
- [ ] Disable basic auth when Authelia is enabled (`auth = if hasAuthelia then null else ...`)
- [ ] Register with `modules.services.authelia.accessControl.declarativelyProtectedServices`
- [ ] Convert groups to `group:name` subject format
- [ ] Generate bypass resources from both `bypassPaths` and `bypassResources`

## Example: Full Service Module Implementation

See `/Users/ryan/src/nix-config/hosts/_modules/nixos/services/sonarr/default.nix` lines 312-393 for the complete implementation pattern.

## Benefits

1. **Modular**: Each service independently opts into SSO protection
2. **Flexible**: Supports different policies per service (bypass, 1FA, 2FA)
3. **Cross-Host**: Services can use Authelia on different hosts
4. **API-Friendly**: Easy bypass configuration for automation
5. **Type-Safe**: All options are properly typed and validated
6. **Automatic**: Rules are generated and merged automatically
7. **Backward Compatible**: Services without Authelia continue working unchanged

## Troubleshooting

### Forward Auth Not Working

Check that:
1. Authelia is running and accessible at the configured host/port
2. `authDomain` matches your Authelia instance hostname
3. Service's `hostName` is in Authelia's access control rules
4. User is in one of the `allowedGroups`

### API Endpoints Require Auth

Make sure you've configured `bypassPaths` or `bypassResources`:

```nix
bypassPaths = [ "/api" "/feed" "/rss" ];
```

### Cross-Host Connection Issues

When using Authelia on a different host:
- Use HTTPS if crossing network boundaries
- Verify firewall rules allow connection to Authelia port
- Check DNS resolution for `autheliaHost`

### Rules Not Applied

The Authelia service must be restarted after changes:

```bash
ssh forge.holthome.net "sudo systemctl restart authelia-main"
```

## Security Considerations

1. **Default Deny**: Authelia defaults to `deny` for unmatched requests
2. **Bypass Carefully**: Only bypass paths that are truly public or have their own auth
3. **Group Management**: Regularly audit group memberships
4. **2FA for Admins**: Use `policy = "two_factor"` for admin-only services
5. **Cross-Host HTTPS**: Always use HTTPS when Authelia is on a different host

## Future Enhancements

- [ ] Add support for per-service custom rules (networks, methods, etc.)
- [ ] Support multiple Authelia instances per host
- [ ] Auto-detect common bypass patterns by service type
- [ ] Integration with OIDC clients
- [ ] Session duration overrides per service
