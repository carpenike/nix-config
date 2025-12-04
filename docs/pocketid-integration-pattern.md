# Pocket ID Integration Pattern

## Overview

Pocket ID pairs with the `caddy-security` plugin to provide passwordless SSO for every reverse proxy managed by this repository. Services enroll by setting `reverseProxy.caddySecurity` options; the global Caddy module handles the rest (session portal, authorization policies, and shared claim-to-role transforms).

## Key Features

- ✅ **Passkey-first authentication** powered by Pocket ID’s WebAuthn flow with optional SMTP recovery.
- ✅ **Centralized authorization** – services declare which `policy` applies and the portal enforces it before traffic reaches the backend.
- ✅ **Claim-based roles** – map Pocket ID group claims into Caddy Security roles without editing shared config files.
- ✅ **API bypass** – allow automation/IP-bound consumers to skip auth through explicit `allowedNetworks` and bypass resources.
- ✅ **Cross-host support** – any host can reference the same Pocket ID portal through the shared reverse proxy submodule.

## Architecture

1. **Pocket ID Service Module** (`hosts/_modules/nixos/services/pocketid/`)
   - Exposes the portal at `https://id.${domain}`
   - Stores SMTP + JWT secrets via SOPS
   - Publishes the OIDC discovery document for services that need full OAuth integration
2. **Caddy Security Portal** (`modules.services.caddy.security`)
   - Defines `portalHost`, TLS, and reusable authorization policies (`admins`, `users`, `bypass`)
   - Receives claim → role mappings contributed by each service
3. **Service Reverse Proxy Definitions**
   - Each service sets `reverseProxy = { enable = true; ...; caddySecurity = { ... }; }`
   - The shared Caddy module consumes those options and generates the correct site block + security transforms

## Implementation Steps

### 1. Configure Pocket ID

```nix
modules.services.pocketid = {
  enable = true;
  domain = "id.${config.networking.domain}";
  smtp = {
    host = "smtp.mailgun.org";
    port = 587;
    username = "pocketid@holthome.net";
    passwordFile = config.sops.secrets."pocketid/smtp_password".path;
  };
};
```

### 2. Enable the Global Portal

```nix
modules.services.caddy.security = {
  enable = true;
  portalHost = "id.${config.networking.domain}";
  policies = {
    admins.allowedGroups = [ "admins" ];
    users.allowedGroups = [ "admins" "users" ];
    bypass.allowedNetworks = [ "10.0.0.0/8" "192.168.0.0/16" ];
  };
};
```

### 3. Contribute Service-specific Requirements

```nix
modules.services.grafana = {
  enable = true;
  reverseProxy = {
    enable = true;
    hostName = "grafana.${config.networking.domain}";
    backend.port = 2342;
    caddySecurity = {
      enable = true;
      policy = "admins";
      claimRoles = [
        { claim = "groups"; value = "admins"; role = "admins"; }
      ];
      bypassPaths = [ "/api/health" ];
      allowedNetworks = [ "10.50.0.0/16" ];
    };
  };
};
```

The shared module translates `claimRoles` into `transform identity set roles` blocks, attaches the portal, and configures bypass routes using the `authorization policy` specified.

## API Bypass Pattern

Use bypasses sparingly: only endpoints that already have their own auth (e.g., Sonarr API keys) or are safe to expose inside trusted networks should skip Pocket ID.

```nix
reverseProxy.caddySecurity = {
  enable = true;
  policy = "users";
  bypassPaths = [ "/api" "/feed" ];
  bypassResources = [ "^/api/system/status$" ];
  allowedNetworks = [ "192.168.50.0/24" "10.0.0.0/8" ];
};
```

Behind the scenes the Caddy module emits:

- `transform request allow path` blocks for `bypassPaths`
- `allow resources` rules for regex patterns in `bypassResources`
- Optional IP-based ACLs leveraging `allowedNetworks`

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| Portal loop / repeated redirects | `hostName` mismatch or portal disabled | Confirm the service’s `hostName` matches the DNS record and that `modules.services.caddy.security.enable = true`. |
| User denied despite being in admins group | Missing `claimRoles` entry | Add `{ claim = "groups"; value = "admins"; role = "admins"; }` to the service block or extend the global policy. |
| API bypass ignored | IP not in `allowedNetworks` or path mismatch | Ensure `allowedNetworks` covers the client IP and that the path/regex includes leading slashes. |
| Pocket ID login fails with SMTP error | Missing or incorrect SMTP secret | Verify `config.sops.secrets."pocketid/smtp_password"` exists and restart the service. |

## Adding Authentication to New Services

1. **Add `reverseProxy.caddySecurity`** to the service module and configure the desired policy.
2. **Set `allowedGroups`** to restrict access to specific PocketID groups.
3. **Update documentation** (service README) to reflect Pocket ID requirements.
4. **Test passkey login end-to-end** before marking the service as production-ready.

## References

- [Pocket ID Docs](https://pocket-id.github.io/docs/)
- [Caddy Security Portal](https://caddyserver.com/docs/caddy-security)
- [`docs/authentication-sso-pattern.md`](./authentication-sso-pattern.md)
