# Authentication & SSO Pattern (Pocket ID + Caddy Security)


**Pattern Status:** ✅ Production Ready
**Last Updated:** 2025-11-06
**Version:** 2.0.0 (Pocket ID Migration)

Refer to `docs/pocketid-integration-pattern.md` for the detailed portal configuration.

## Core Components

1. **Pocket ID service** – Native passkey-first OIDC provider with encrypted storage and SMTP support for recovery emails.
2. **Caddy Security portal** – Applies policies (admins/users/bypass) and injects the necessary headers before traffic reaches services.
3. **Service modules** – Each service declares its authentication posture (full auth, API bypass, or no auth) through `reverseProxy.caddySecurity` options.

## Implementation Steps

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

Pocket ID automatically exposes its OIDC discovery document at `https://id.${domain}/.well-known/openid-configuration` and publishes passkey metadata for WebAuthn clients.

### 2. Manage Secrets with SOPS

```yaml
# secrets/pocketid.yaml
pocketid:
  jwt_secret: ENC[...]
  smtp_password: ENC[...]
```

```nix
sops.secrets = {
  "pocketid/jwt_secret" = {
    sopsFile = ./secrets/pocketid.yaml;
    owner = "pocket-id";
    group = "pocket-id";
  };
  "pocketid/smtp_password" = {
    sopsFile = ./secrets/pocketid.yaml;
    owner = "pocket-id";
    group = "pocket-id";
  };
};
```

### 3. Wire Caddy Security Policies

```nix
modules.infrastructure.caddySecurity = {
  enable = true;
  portalHost = "id.${config.networking.domain}";
  policies = {
    admins = {
      allowedGroups = [ "admins" ];
    };
    users = {
      allowedGroups = [ "admins" "users" ];
    };
  };
};
```

Policies translate Pocket ID group claims into allow/deny decisions before proxying requests.

### 4. Contribute Reverse Proxy Blocks per Service

```nix
let
  serviceEnabled = config.modules.services.grafana.enable or false;
in
{
  modules.services.grafana = {
    enable = true;
    reverseProxy = {
      enable = true;
      hostName = "grafana.${config.networking.domain}";
      caddySecurity = {
        enable = true;
        policy = "admins";
        claimRoles = {
          admins = "${config.networking.domain}#admins";
        };
      };
    };
  };

  config = lib.mkIf serviceEnabled {
    # Downstream contributions (datasets, monitoring, etc.)
  };
}
```

### 5. Deploy and Test

```fish
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
open https://id.${config.networking.domain}
```

Register a passkey, sign out, and confirm that protected services redirect through the Pocket ID portal.

## Service-Specific Guidance

### Mealie (Native OIDC)

```nix
modules.services.mealie = {
  oidc = {
    enable = true;
    configurationUrl = "https://id.${config.networking.domain}/.well-known/openid-configuration";
    clientIdFile = config.sops.secrets."mealie/oidc_client_id".path;
    clientSecretFile = config.sops.secrets."mealie/oidc_client_secret".path;
  };
};
```

Use Pocket ID’s application management UI to generate the client/secret pair and store both values with SOPS.

### Grafana (Proxy Auth)

```nix
services.grafana.settings = {
  auth.proxy = {
    enabled = true;
    header_name = "Remote-User";
    header_property = "username";
    auto_sign_up = true;
  };
  server.root_url = "https://grafana.${config.networking.domain}";
  server.serve_from_sub_path = true;
};
```

Grafana trusts the `Remote-User` header that Caddy injects after Pocket ID validation, eliminating the need for Grafana-side OIDC configuration.

### Glances (Caddy Portal Only)

```nix
reverseProxy.caddySecurity = {
  enable = true;
  policy = "admins";
  claimRoles = {
    admins = "${config.networking.domain}#admins";
  };
};
```

Lightweight services without OIDC support simply rely on the portal to enforce access.

## Troubleshooting

### Passkey Button Missing

**Possible causes:**

1. `modules.services.pocketid.webauthn.enablePasskeyLogin` is false.
2. Browser cached the previous session – try a private window.
3. User has no discoverable passkeys registered.

**Fix:** Ensure the `enablePasskeyLogin` flag is set, confirm SMTP works for enrollment emails, and have users re-register passkeys if necessary.

### API Bypass Not Honored

1. `allowedNetworks` is not configured on the service’s reverse proxy block.
2. Request originates from an unexpected IP range.
3. The bypass path does not match the service endpoint.

**Debug commands:**

```fish
ssh forge 'sudo journalctl -u caddy.service -f'
curl -H "X-Forwarded-For: 198.51.100.10" https://sonarr.${config.networking.domain}/api/system/status
```

### SMTP Test Failed

1. Wrong username/password or missing secret file.
2. Provider blocked the IP (check Mailgun logs).
3. Pocket ID service lacks network egress (firewall rules).

**Verify:**

```fish
ssh forge 'sudo systemctl show pocket-id.service | grep -i smtp'
ssh forge 'sudo cat /run/secrets/pocketid/smtp_password'
```

## Best Practices

- Use `policy = "admins"` for administrative portals and `"users"` for general applications.
- Store every credential (`client_id`, `client_secret`, SMTP passwords) in SOPS and reference them from modules.
- Keep Pocket ID and Caddy on the same host to reduce token round-trips and simplify certificate rotation.
- Always guard downstream resources (`modules.storage.datasets`, backup jobs, alert rules) with `lib.mkIf serviceEnabled` so disabling a service removes every integration.
- Run `task nix:build-<host>` before deploying to catch doc lint or evaluation errors early.

## References

- [Pocket ID Documentation](https://pocket-id.github.io/docs/)
- [Caddy Security Portal](https://caddyserver.com/docs/caddy-security)
- [WebAuthn (W3C)](https://www.w3.org/TR/webauthn/)

---

environment.SONARR__AUTHENTICATIONMETHOD = "External";
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
**Pattern Status:** ✅ Production Ready
**Last Updated:** 2025-11-06
**Version:** 2.0.0 (Pocket ID Migration)
