# Authentication & SSO Pattern (Pocket ID + Caddy Security)

**Pattern Status:** ✅ Production Ready
**Last Updated:** 2025-12-05
**Version:** 3.0.0 (Comprehensive Auth Patterns)

Refer to `docs/pocketid-integration-pattern.md` for the detailed portal configuration.

## Authentication Decision Framework

**Always research authentication options before implementing a service.** Use this priority order:

### Priority Order

| Priority | Pattern | When to Use | Example |
|----------|---------|-------------|---------|
| 1 | **Native OIDC** | Multi-user app with complex roles/permissions | paperless, mealie |
| 2 | **Trusted Header Auth** | Multi-user app supporting auth proxy (Remote-User) | grafana, organizr |
| 3 | **Disable Auth + caddySecurity** | Single-user app (PREFERRED) | arr apps, dashboards |
| 4 | **Hybrid Auth** (SSO + API key) | Auth can't be disabled but has API key | paperless-ai |
| 5 | **Built-in Auth Only** | Auth can't be disabled, no alternatives | plex |
| 6 | **No Auth** | Internal S2S services only | webhooks |

### Research Checklist

Before implementing auth for any service, answer these questions:

1. **Native OIDC/OAuth2 support?** - Does the app support OpenID Connect?
2. **Trusted header auth?** - Does it accept `Remote-User`, `X-Email` headers from proxy?
3. **Can auth be disabled?** - Look for `auth.enabled = false`, `DISABLE_AUTH=true`, etc.
4. **API key support?** - Can we inject an API key header to bypass auth?
5. **Multi-user needed?** - Do different users need different permissions?

## Core Components

1. **Pocket ID service** – Native passkey-first OIDC provider with encrypted storage and SMTP support for recovery emails.
2. **Caddy Security portal** – Applies policies (admins/users/bypass) and injects the necessary headers before traffic reaches services.
3. **Service modules** – Each service declares its authentication posture through `reverseProxy.caddySecurity` options.

## Implementation Patterns

### Pattern 1: Native OIDC (Multi-User with Roles)

**Use when:** App has complex per-user permissions (folders, meal plans, document access).

```nix
# Example: Mealie with native OIDC
modules.services.mealie = {
  oidc = {
    enable = true;
    configurationUrl = "https://id.${config.networking.domain}/.well-known/openid-configuration";
    clientIdFile = config.sops.secrets."mealie/oidc_client_id".path;
    clientSecretFile = config.sops.secrets."mealie/oidc_client_secret".path;
    autoSignup = true;
    autoRedirect = true;
  };
};
```

**SOPS secrets required:**
```yaml
mealie:
  oidc_client_id: "<from-pocketid-admin>"
  oidc_client_secret: "<from-pocketid-admin>"
```

### Pattern 2: Trusted Header Auth (Auth Proxy)

**Use when:** Multi-user app that trusts proxy-injected headers but doesn't have OIDC.

```nix
# Example: Grafana with auth.proxy
services.grafana.settings = {
  auth.proxy = {
    enabled = true;
    header_name = "Remote-User";
    header_property = "username";
    auto_sign_up = true;
  };
  server.root_url = "https://grafana.${config.networking.domain}";
};

# Caddy injects Remote-User after PocketID auth
modules.services.grafana.reverseProxy = {
  enable = true;
  hostName = "grafana.${config.networking.domain}";
  caddySecurity = forgeDefaults.caddySecurity.admins;
};
```

**Common trusted headers:**
- `Remote-User` - Standard CGI variable
- `X-Forwarded-User` - Common proxy header
- `X-Email` - Email-based identity
- `X-Forwarded-Email` - Alternative email header

### Pattern 3: Disable Auth + caddySecurity (PREFERRED for Single-User)

**Use when:** Single-user/household app where everyone has same permissions.

This is the **preferred pattern** for most homelab services - provides consistent SSO experience.

```nix
# Example: Sonarr with disabled native auth
modules.services.sonarr = {
  enable = true;
  # Disable native authentication
  authenticationMethod = "External";  # or "None", "DisabledForLocalAddresses"

  reverseProxy = {
    enable = true;
    hostName = "sonarr.${config.networking.domain}";
    # PocketID SSO via Caddy
    caddySecurity = forgeDefaults.caddySecurity.media;
  };
};
```

**Environment variable patterns to look for:**
- `SONARR__AUTH__METHOD = "External"`
- `DISABLE_AUTH = "true"`
- `authentication = "None"`
- `auth.enabled = false`

### Pattern 4: Hybrid Auth (SSO + API Key Injection)

**Use when:** Auth can't be disabled but service accepts API key header.

```nix
# Example: paperless-ai
modules.services.paperless-ai = {
  enable = true;
  apiKeyFile = config.sops.secrets."paperless-ai/api_key".path;

  reverseProxy = {
    enable = true;
    hostName = "paperless-ai.${config.networking.domain}";
    caddySecurity = forgeDefaults.caddySecurity.home;
    # Inject API key to bypass internal auth
    reverseProxyBlock = ''
      header_up x-api-key {$PAPERLESS_AI_API_KEY}
    '';
  };
};
```

**How it works:**
1. User hits `https://paperless-ai.holthome.net`
2. Caddy redirects to PocketID for SSO
3. After auth, Caddy injects `x-api-key` header
4. Service accepts request as authenticated
5. User sees UI without additional login

**Note:** All users share the same API key identity - no per-user permissions.

### Pattern 5: Built-in Auth Only (Last Resort)

**Use when:** Auth can't be disabled and no API key/proxy auth support.

```nix
# Example: Plex (has its own user system)
modules.services.plex = {
  enable = true;
  # No caddySecurity - Plex handles its own auth
  reverseProxy = {
    enable = true;
    hostName = "plex.${config.networking.domain}";
    # No caddySecurity here
  };
};
```

**When this is acceptable:**
- App has comprehensive user management (Plex, Jellyfin)
- Users need app-specific features tied to their account
- App doesn't support any proxy auth patterns

## Setup Steps

### 1. Enable Pocket ID

```nix
modules.services.pocketid = {
  enable = true;
  domain = "id.${config.networking.domain}";
  dataDir = "/var/lib/pocket-id";
  smtp = {
    host = "smtp.mailgun.org";
    port = 587;
    username = "pocket-id@holthome.net";
    passwordFile = config.sops.secrets."pocketid/smtp_password".path;
  };
};
```

### 2. Configure Caddy Security Policies

```nix
modules.infrastructure.caddySecurity = {
  enable = true;
  portalHost = "id.${config.networking.domain}";
  policies = {
    admins = { allowedGroups = [ "admins" ]; };
    users = { allowedGroups = [ "admins" "users" ]; };
    media = { allowedGroups = [ "admins" "users" "media" ]; };
    home = { allowedGroups = [ "admins" "users" "home" ]; };
  };
};
```

### 3. Use forgeDefaults Helpers

```nix
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
in
{
  modules.services.myapp.reverseProxy = {
    enable = true;
    hostName = "myapp.${config.networking.domain}";
    caddySecurity = forgeDefaults.caddySecurity.home;  # or .media, .admin
  };
}
```

## Troubleshooting

### Passkey Button Missing

1. Check `modules.services.pocketid.webauthn.enablePasskeyLogin` is true
2. Try incognito/private window (cached session)
3. Re-register passkeys if needed

### API Bypass Not Working

1. Verify `allowedNetworks` configuration
2. Check request origin IP
3. Confirm bypass path matches endpoint

### Double Login Prompt

1. Service has native auth enabled + caddySecurity
2. **Fix:** Disable native auth (Pattern 3) or remove caddySecurity

### Remote-User Header Not Trusted

1. App requires trusted proxy configuration
2. Add your Caddy IP to app's trusted proxies list
3. Check header name matches what app expects

## Best Practices

1. **Prefer Pattern 3** (disable auth + caddySecurity) for single-user apps
2. **Use Pattern 2** (trusted headers) for multi-user when simpler than OIDC
3. **Store all secrets in SOPS** - never inline credentials
4. **Guard contributions** with `lib.mkIf serviceEnabled`
5. **Test auth flow** after deployment: logout, clear cookies, re-authenticate

## References

- [Pocket ID Documentation](https://pocket-id.github.io/docs/)
- [Caddy Security Portal](https://caddyserver.com/docs/caddy-security)
- [WebAuthn (W3C)](https://www.w3.org/TR/webauthn/)
- `.github/prompts/nixos/service-module.prompt.md` - Service module patterns
