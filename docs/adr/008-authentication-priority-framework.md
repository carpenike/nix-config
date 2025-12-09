# ADR-008: Authentication Priority Framework

**Status**: Accepted
**Date**: 2025-12-09
**Context**: SSO and authentication patterns for homelab services

## Context

Homelab services have varying authentication capabilities:

- Some support OIDC natively
- Some accept trusted headers from reverse proxies
- Some can disable authentication entirely
- Some have built-in auth that cannot be disabled

Without a consistent framework, each service ends up with ad-hoc authentication decisions, leading to:

- Security inconsistencies
- Duplicate password management
- Poor SSO experience
- Maintenance burden

## Decision

**Establish a priority-ordered authentication framework based on service capabilities.**

### Priority Order

| Priority | Pattern | When to Use | Example |
|----------|---------|-------------|---------|
| 1 | **Native OIDC** | Multi-user app with complex roles/permissions | Paperless, Mealie |
| 2 | **Trusted Header Auth** | Multi-user app supporting auth proxy headers | Grafana, Organizr |
| 3 | **Disable Auth + caddySecurity** | Single-user/household app (PREFERRED) | Sonarr, Radarr |
| 4 | **Hybrid Auth** (SSO + API key) | Auth can't be disabled but has API key | Paperless-AI |
| 5 | **Built-in Auth Only** | Auth can't be disabled, no alternatives | Plex |
| 6 | **No Auth** | Internal S2S services only | Webhooks |

### Research Checklist

Before implementing auth for any service, answer these questions:

1. **Native OIDC/OAuth2 support?** - Does the app support OpenID Connect?
2. **Trusted header auth?** - Does it accept `Remote-User`, `X-Email` headers?
3. **Can auth be disabled?** - Look for `auth.enabled = false`, `DISABLE_AUTH=true`
4. **API key support?** - Can we inject an API key header to bypass auth?
5. **Multi-user needed?** - Do different users need different permissions?

## Consequences

### Positive

- **Consistent SSO experience**: Pocket ID handles most authentication
- **Reduced password fatigue**: Fewer service-specific passwords
- **Clear decision process**: Research checklist prevents ad-hoc decisions
- **Security by design**: Authentication decisions are explicit

### Negative

- **Research required**: Must investigate each service's capabilities
- **Complexity for multi-user**: OIDC setup requires client registration
- **Some services unsupported**: Built-in auth only (Priority 5) breaks SSO

### Mitigations

- Document auth capabilities in service module comments
- Use `forgeDefaults.caddySecurity.*` helpers for common patterns
- Keep Pocket ID client registration in SOPS secrets

## Implementation Patterns

### Pattern 3: Disable Auth + caddySecurity (PREFERRED for Single-User)

Most homelab services are single-user household apps. Prefer this pattern:

```nix
modules.services.sonarr = {
  enable = true;
  authenticationMethod = "None";  # Disable built-in auth

  reverseProxy = {
    enable = true;
    hostName = "sonarr.${config.networking.domain}";
    caddySecurity = forgeDefaults.caddySecurity.media;  # PocketID auth
  };
};
```

### Pattern 1: Native OIDC (Multi-User)

For apps with per-user permissions:

```nix
modules.services.mealie = {
  oidc = {
    enable = true;
    configurationUrl = "https://id.${domain}/.well-known/openid-configuration";
    clientIdFile = config.sops.secrets."mealie/oidc_client_id".path;
    clientSecretFile = config.sops.secrets."mealie/oidc_client_secret".path;
    autoSignup = true;
  };
};
```

### Pattern 2: Trusted Header Auth

For apps that trust proxy-injected headers:

```nix
services.grafana.settings = {
  auth.proxy = {
    enabled = true;
    header_name = "Remote-User";
    auto_sign_up = true;
  };
};

modules.services.grafana.reverseProxy = {
  enable = true;
  caddySecurity = forgeDefaults.caddySecurity.admins;  # Injects Remote-User
};
```

## caddySecurity Groups

Three predefined groups via `forgeDefaults.caddySecurity`:

| Group | Access Level | Use For |
|-------|-------------|---------|
| `media` | Media group members | Sonarr, Radarr, Plex, etc. |
| `admin` | Admin group members | Grafana, infrastructure tools |
| `home` | Home group members | Home automation, household apps |

## Related

- [Authentication SSO Pattern](../authentication-sso-pattern.md) - Full documentation
- [Pocket ID Integration Pattern](../pocketid-integration-pattern.md) - OIDC provider setup
- [ADR-002: Host-Level Defaults Library](./002-host-level-defaults-library.md) - caddySecurity helpers
