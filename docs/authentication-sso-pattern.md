# Authentication & SSO Pattern

## Overview

This document describes the complete authentication and single sign-on (SSO) pattern using Authelia with passwordless WebAuthn support.

## Architecture Philosophy

**Design Principle**: Pull-based declarative configuration where services declare authentication requirements and the system automatically implements enforcement.

- **Services declare intent** → Opt-in via `reverseProxy.authelia.enable = true`
- **Caddy implements enforcement** → Centralized `forward_auth` middleware
- **Authelia validates identity** → Single source of truth for authentication

## Key Features

✅ **Passwordless Authentication** - WebAuthn/Passkey support with biometric verification
✅ **Flexible Policies** - One-factor (passwordless) or two-factor authentication
✅ **API Bypass with IP Restrictions** - Internal networks can access APIs without auth
✅ **Cross-Host Support** - Services on any host can use centralized Authelia
✅ **Automatic Registration** - Zero manual configuration of access control rules
✅ **SMTP Email Verification** - Required for 2FA device registration

## Authentication Methods

### 1. Passwordless (Recommended)

**How it works:**
- User clicks "Sign in with a passkey" on login page
- Browser prompts for biometric (fingerprint, Face ID) or device PIN
- Authenticated immediately without username/password

**Requirements:**
- Policy: `one_factor`
- WebAuthn passkey registered with `discoverable = true`
- Passkey secured with biometric/PIN (`user_verification: required`)

**Security:**
- Phishing-resistant (cryptographic challenge-response)
- Device-bound or synced via platform (iCloud Keychain, Windows Hello, etc.)
- Requires physical presence + biometric/PIN

### 2. Traditional Two-Factor

**How it works:**
- User enters username + password
- User provides second factor (TOTP app or WebAuthn)
- Authenticated after both factors verified

**Requirements:**
- Policy: `two_factor`
- Password configured in `users.yaml`
- Second factor registered (TOTP or WebAuthn)

### 3. Hybrid Mode (Current Default)

**How it works:**
- User can choose passwordless OR traditional authentication
- Login page shows both "Sign in with a passkey" and username/password fields
- Same security level (both satisfy `one_factor` policy)

**Configuration:**
```nix
policy = "one_factor";  # Allows both methods
```

## Authelia Module Configuration

### Core Service (`hosts/_modules/nixos/services/authelia/default.nix`)

```nix
modules.services.authelia = {
  enable = true;
  instance = "main";
  domain = "holthome.net";
  port = 9091;

  # WebAuthn / Passkey Configuration
  # Configured automatically in the module settings:
  # - enable_passkey_login = true (master switch for passwordless)
  # - selection_criteria.user_verification = "required" (biometric/PIN enforcement)
  # - selection_criteria.discoverability = "preferred" (prefer discoverable credentials)

  # SMTP for 2FA registration emails
  notifier = {
    type = "smtp";
    smtp = {
      host = "smtp.mailgun.org";
      port = 587;
      username = "authelia@holthome.net";
      passwordFile = config.sops.secrets."authelia/smtp_password".path;
      sender = "Authelia <authelia@holthome.net>";
      subject = "[Authelia] {title}";
    };
  };

  # Secrets (SOPS-managed)
  secrets = {
    jwtSecretFile = config.sops.secrets."authelia/jwt_secret".path;
    sessionSecretFile = config.sops.secrets."authelia/session_secret".path;
    storageEncryptionKeyFile = config.sops.secrets."authelia/storage_encryption_key".path;
  };

  # Reverse proxy for auth portal
  reverseProxy = {
    enable = true;
    hostName = "auth.holthome.net";
  };
};
```

### Host-Specific Configuration (`hosts/forge/authelia.nix`)

```nix
{
  modules.services.authelia = {
    enable = true;
    instance = "main";
    domain = "holthome.net";

    notifier = {
      type = "smtp";
      smtp = {
        host = "smtp.mailgun.org";
        port = 587;
        username = "authelia@holthome.net";
        passwordFile = config.sops.secrets."authelia/smtp_password".path;
        sender = "Authelia <authelia@holthome.net>";
      };
    };

    secrets = {
      jwtSecretFile = config.sops.secrets."authelia/jwt_secret".path;
      sessionSecretFile = config.sops.secrets."authelia/session_secret".path;
      storageEncryptionKeyFile = config.sops.secrets."authelia/storage_encryption_key".path;
    };

    reverseProxy = {
      enable = true;
      hostName = "auth.holthome.net";
    };
  };
}
```

## Service Integration Pattern

### Basic Protection (Passwordless)

**Use case:** Single-user homelab, convenience-focused

```nix
modules.services.sonarr = {
  enable = true;

  reverseProxy = {
    enable = true;
    hostName = "sonarr.holthome.net";

    authelia = {
      enable = true;
      instance = "main";
      authDomain = "auth.holthome.net";
      policy = "one_factor";  # Allow passwordless with passkey
      allowedGroups = [ "admins" "users" ];
    };
  };
};
```

### API Bypass with IP Restrictions

**Use case:** Allow internal automation while protecting external access

```nix
modules.services.sonarr = {
  enable = true;

  reverseProxy = {
    enable = true;
    hostName = "sonarr.holthome.net";

    authelia = {
      enable = true;
      policy = "one_factor";
      allowedGroups = [ "admins" "users" ];

      # Bypass auth for API endpoints
      bypassPaths = [ "/api" "/feed" ];

      # BUT restrict API access to internal networks only
      allowedNetworks = [
        "172.16.0.0/12"    # Docker networks
        "192.168.1.0/24"   # Home LAN
        "10.0.0.0/8"       # Internal VPN
      ];
    };
  };
};
```

### High-Security Protection

**Use case:** Sensitive services requiring two factors

```nix
modules.services.grafana = {
  enable = true;

  reverseProxy = {
    enable = true;
    hostName = "grafana.holthome.net";

    authelia = {
      enable = true;
      policy = "two_factor";  # Require password + 2FA
      allowedGroups = [ "admins" ];
      # No API bypass for high-security services
    };
  };
};
```

## Implementation Details

### 1. Caddy Integration (`hosts/_modules/nixos/services/caddy/default.nix`)

**Centralized forward_auth generation:**

```nix
# For each protected service, generate forward_auth middleware
extraConfig = lib.optionalString hasAuthelia ''
  forward_auth ${autheliaUrl} {
    uri /api/verify?rd=https://${vhost.authelia.authDomain}
    copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
  }

  # IP-restricted API bypass (if configured)
  ${lib.optionalString hasAllowedNetworks ''
    @internalApi {
      ${lib.concatMapStringsSep "\n    " (net: "remote_ip ${net}") allowedNetworks}
      ${lib.concatMapStringsSep "\n    " (path: "path ${path}*") bypassPaths}
    }
    handle @internalApi {
      reverse_proxy ${backendUrl}
    }
  ''}
'';
```

### 2. Authelia Access Control

**Automatic rule generation from service configurations:**

```nix
access_control = {
  default_policy = "deny";

  rules =
    # User-defined explicit rules first
    (map (rule: { ... }) cfg.accessControl.rules)
    ++
    # Auto-generated rules from services (bypass paths first, then main policy)
    (lib.flatten (lib.mapAttrsToList (serviceName: svc:
      # Bypass rule (higher priority)
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

### 3. WebAuthn Configuration

**Module settings for passwordless authentication:**

```nix
webauthn = {
  disable = false;
  enable_passkey_login = true;  # Master switch (v4.39.0+)
  display_name = "Authelia";
  attestation_conveyance_preference = "indirect";

  selection_criteria = {
    user_verification = "required";     # Enforce biometric/PIN
    discoverability = "preferred";      # Prefer discoverable credentials
  };

  timeout = "60s";
};
```

## User Workflow

### Initial Setup

1. **Access a protected service** (e.g., `https://sonarr.holthome.net`)
2. **Redirect to Authelia** (`https://auth.holthome.net`)
3. **Log in with username + password** (first time only)
4. **Navigate to Settings → Two-Factor Authentication**
5. **Register a Passkey** (browser will prompt for biometric/PIN)
6. **Verify email** (if SMTP configured) to activate 2FA
7. **Log out**

### Subsequent Access (Passwordless)

1. **Access a protected service**
2. **Redirect to Authelia login page**
3. **Click "Sign in with a passkey"**
4. **Authenticate with biometric/PIN** (browser prompt)
5. **Redirected back to service** (no password needed)

### Fallback (Traditional)

1. **Access a protected service**
2. **Redirect to Authelia login page**
3. **Enter username + password** (manual input)
4. **Provide 2FA if policy requires** (TOTP or WebAuthn)
5. **Redirected back to service**

## Security Model

### Authentication Strength

**Passwordless (one_factor):**
- Passkey with `user_verification: required`
- Equivalent to: Something you have (device) + something you are (biometric) or something you know (PIN)
- Satisfies NIST AAL2 requirements
- Phishing-resistant

**Traditional Two-Factor (two_factor):**
- Password (something you know)
- TOTP/WebAuthn (something you have/are)
- Satisfies NIST AAL2+ requirements

### API Security

**Three-tier protection:**

1. **External users**: Must authenticate via Authelia (full SSO flow)
2. **Internal networks**: Can access API endpoints without auth (IP-restricted)
3. **No API key leakage risk**: Even with leaked key, external access still blocked

**Implementation:**
```nix
bypassPaths = [ "/api" "/feed" ];           # What to bypass
allowedNetworks = [ "192.168.1.0/24" ];     # Who can bypass
```

**Caddy generates:**
```
@internalApi {
  remote_ip 192.168.1.0/24
  path /api*
}
handle @internalApi {
  reverse_proxy ${backend}  # Skip forward_auth
}
```

## Policy Guidelines

### When to use `one_factor`

✅ Personal homelab (single user)
✅ Convenience-focused services (*arr apps, dashboards)
✅ Services with frequent access
✅ When passwordless is desired

### When to use `two_factor`

✅ Financial/sensitive data access
✅ Admin panels with write access
✅ Compliance requirements
✅ Multi-user environments

### When to use `bypass`

⚠️ **Use sparingly!** Only for:
- Public content (blogs, status pages)
- Health check endpoints
- Webhook receivers (with other security like HMAC verification)

## SMTP Configuration

**Required for:**
- 2FA device registration email verification
- Password reset emails
- Security notifications

**Recommended provider:**
- Mailgun (5,000 emails/month free tier)
- SendGrid, AWS SES, or any SMTP provider

**Configuration:**
```nix
notifier = {
  type = "smtp";
  smtp = {
    host = "smtp.mailgun.org";
    port = 587;
    username = "authelia@holthome.net";
    passwordFile = config.sops.secrets."authelia/smtp_password".path;
    sender = "Authelia <authelia@holthome.net>";
    subject = "[Authelia] {title}";
  };
};
```

## Secrets Management

**Required secrets (SOPS-managed):**

```yaml
# secrets.yaml
authelia:
  jwt_secret: <random-64-char-string>
  session_secret: <random-64-char-string>
  storage_encryption_key: <random-64-char-string>
  smtp_password: <mailgun-api-key>
```

**Secret declarations:**

```nix
# hosts/forge/secrets.nix
sops.secrets = {
  "authelia/jwt_secret" = {
    sopsFile = ./secrets.yaml;
    owner = "authelia-main";
    group = "authelia-main";
  };
  "authelia/session_secret" = {
    sopsFile = ./secrets.yaml;
    owner = "authelia-main";
    group = "authelia-main";
  };
  "authelia/storage_encryption_key" = {
    sopsFile = ./secrets.yaml;
    owner = "authelia-main";
    group = "authelia-main";
  };
  "authelia/smtp_password" = {
    sopsFile = ./secrets.yaml;
    owner = "authelia-main";
    group = "authelia-main";
  };
};
```

## Application-Specific Configuration

### Sonarr/Radarr/*arr Apps

**Disable internal authentication:**

```nix
environment = {
  SONARR__AUTHENTICATIONMETHOD = "External";
  # Trust upstream Authelia authentication
};
```

**Manual configuration file update (if needed):**
```xml
<Config>
  <AuthenticationMethod>External</AuthenticationMethod>
</Config>
```

### Grafana

**Proxy authentication:**
```nix
auth.proxy = {
  enabled = true;
  header_name = "Remote-User";
  header_property = "username";
  auto_sign_up = true;
};
```

### Prometheus/Alertmanager

**No internal auth needed:**
- Rely entirely on Caddy + Authelia
- No exposed ports except through reverse proxy

## Troubleshooting

### "Sign in with a passkey" button not appearing

**Possible causes:**
1. ❌ `enable_passkey_login = true` not set
2. ❌ Policy set to `two_factor` (forces password first)
3. ❌ No discoverable passkey registered
4. ❌ Browser cache (try incognito mode)

**Solution:**
```nix
# Module configuration
webauthn.enable_passkey_login = true;

# Service configuration
authelia.policy = "one_factor";
```

### Passkey registration failing

**Possible causes:**
1. ❌ SMTP not configured (email verification required)
2. ❌ Old WebAuthn credential needs re-registration
3. ❌ Browser doesn't support WebAuthn

**Solution:**
- Configure SMTP notifier
- Re-register passkey from Settings → Two-Factor Authentication
- Ensure `discoverable = true` in registration

### API bypass not working

**Possible causes:**
1. ❌ `allowedNetworks` not configured
2. ❌ Request coming from unexpected IP
3. ❌ Path pattern mismatch

**Debug:**
```bash
# Check Caddy logs
ssh forge 'sudo journalctl -u caddy.service -f'

# Verify request IP
curl -H "X-Forwarded-For: $(curl -s ifconfig.me)" https://sonarr.example.com/api/system/status
```

### SMTP authentication failing

**Possible causes:**
1. ❌ Wrong username (use `authelia@domain`, not `postmaster@domain`)
2. ❌ Password file empty or wrong path
3. ❌ Environment variable not set

**Debug:**
```bash
# Check environment variables
ssh forge 'sudo systemctl show authelia-main.service | grep SMTP'

# Check password file exists and has content
ssh forge 'sudo cat /run/secrets/authelia/smtp_password'
```

## Migration from Unprotected Services

### Step 1: Add Authelia Block

```nix
reverseProxy = {
  enable = true;
  hostName = "service.holthome.net";

  # Add this block
  authelia = {
    enable = true;
    policy = "one_factor";
    allowedGroups = [ "admins" "users" ];
  };
};
```

### Step 2: Configure Application

For *arr apps:
```nix
environment.SONARR__AUTHENTICATIONMETHOD = "External";
```

### Step 3: Deploy and Test

```bash
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

### Step 4: Register Passkey

1. Visit `https://auth.holthome.net`
2. Log in with username/password
3. Navigate to Settings → Two-Factor Authentication
4. Register passkey
5. Verify email (if SMTP configured)

### Step 5: Test Passwordless

1. Log out
2. Visit protected service
3. Click "Sign in with a passkey"
4. Authenticate with biometric/PIN

## Best Practices

✅ **Use `one_factor` policy for personal homelabs** - Passwordless is secure and convenient
✅ **Enable API bypass with IP restrictions** - Allows automation without compromising security
✅ **Configure SMTP for 2FA registration** - Required for proper passkey enrollment
✅ **Register discoverable passkeys** - Required for passwordless authentication
✅ **Use SOPS for secret management** - Never commit secrets to git
✅ **Test in incognito mode** - Avoids browser cache issues

❌ **Don't use `bypass` policy without IP restrictions** - Defeats the purpose of SSO
❌ **Don't use `two_factor` if passwordless is desired** - Forces password entry
❌ **Don't expose Authelia port directly** - Always use reverse proxy
❌ **Don't skip SMTP configuration** - Breaks 2FA registration workflow

## Future Enhancements

### Planned Features

- [ ] OIDC provider for services that support OAuth2
- [ ] Multi-domain session support (remove deprecation warning)
- [ ] WebAuthn credential management UI
- [ ] Backup/recovery code generation
- [ ] Session management dashboard
- [ ] LDAP backend support (if needed)

### Experimental Features (Authelia 4.39+)

```nix
# Treat passkey with user verification as two-factor
webauthn.experimental_enable_passkey_uv_two_factors = true;
```

**Note:** This will be replaced by custom policies in future Authelia versions.

## References

- [Authelia Documentation](https://www.authelia.com/configuration/prologue/introduction/)
- [WebAuthn Specification](https://www.w3.org/TR/webauthn/)
- [NIST Digital Identity Guidelines](https://pages.nist.gov/800-63-3/)
- [Caddy Forward Auth](https://caddyserver.com/docs/caddyfile/directives/forward_auth)

---

**Pattern Status**: ✅ Production Ready
**Last Updated**: 2025-11-06
**Version**: 1.0.0 (Passwordless Support)
