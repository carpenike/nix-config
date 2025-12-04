# Cloudflare Tunnel Implementation Plan

**Date**: November 11, 2025
**Status**: Planning / Research Complete

## Executive Summary

This document outlines the recommended approach for implementing Cloudflare Tunnel (cloudflared) into the NixOS homelab infrastructure, following established modular design patterns. The implementation was researched using Gemini 2.5 Pro and aligns with the existing architecture principles.

## Architecture Decision

### Selected Pattern: Cloudflare Tunnel as Complement to Caddy

```
Internet → Cloudflare Network → cloudflared → Caddy → Internal Service
```

**Key Benefits:**
- ✅ **Single Point of Truth**: Caddy remains the central reverse proxy for ALL traffic
- ✅ **Zero Code Duplication**: All proxy logic, authentication, and security stays in Caddy
- ✅ **Preserves Existing Features**: caddy-security/PocketID SSO, IP restrictions, structured backends all continue working
- ✅ **Simple Tunnel Config**: cloudflared only forwards hostnames to Caddy
- ✅ **Declarative Opt-in**: Services declare tunnel exposure via configuration

### Why Not Replace Caddy?

**Rejected Alternative**: `Internet → Cloudflare Network → cloudflared → Internal Service`

This would require:
- ❌ Duplicating reverse proxy logic in Cloudflare configuration
- ❌ Re-implementing caddy-security SSO integration
- ❌ Maintaining two authentication systems (Cloudflare Access + caddy-security)
- ❌ Splitting service configuration between Caddy and cloudflared
- ❌ Violating the "Single code path" design principle

## Implementation Overview

### 1. Module Changes

**Caddy Module** (`hosts/_modules/nixos/services/caddy/default.nix`):
- Add `cloudflare` submodule to `virtualHosts` options
- Services opt-in to tunnel exposure declaratively
- No changes to existing caddy-security, security, or backend logic

**cloudflared Module** (`hosts/_modules/nixos/services/cloudflared/default.nix`):
- Replace with declarative implementation
- Auto-discover services from Caddy virtualHosts
- Generate `config.yaml` from NixOS options
- Support multiple named tunnels
- Automatic ingress rule generation

### 2. Service Declaration Pattern

**Current Pattern** (Internal-only service):
```nix
modules.services.caddy.virtualHosts.grafana = {
  enable = true;
  hostName = "grafana.holthome.net";
  backend = { port = 3000; };
  caddySecurity = {
    enable = true;
    portal = "pocketid";
    policy = "default";
  };
};
```

**New Pattern** (External-accessible via tunnel):
```nix
modules.services.caddy.virtualHosts.grafana = {
  enable = true;
  hostName = "grafana.holthome.net";
  backend = { port = 3000; };
  caddySecurity = {
    enable = true;
    portal = "pocketid";
    policy = "default";
  };
  # NEW: Opt-in to Cloudflare Tunnel
  cloudflare = {
    enable = true;
    tunnel = "homelab";  # References tunnel defined in cloudflared module
  };
};
```

### 3. Host Configuration

**Tunnel Definition** (`hosts/forge/networking.nix` or similar):
```nix
{ config, ... }: {
  # Enable and configure Cloudflare Tunnel(s)
  modules.services.cloudflared = {
    enable = true;
    tunnels.homelab = {
      # Credentials managed by SOPS
      credentialsFile = config.sops.secrets."cloudflared/homelab-credentials".path;
      # Default backend is Caddy HTTP port
      defaultService = "http://127.0.0.1:80";
    };
  };

  # SOPS secret configuration
  sops.secrets."cloudflared/homelab-credentials" = {
    sopsFile = ./secrets.yaml;
    owner = config.systemd.services."cloudflared-homelab".serviceConfig.User;
    group = config.systemd.services."cloudflared-homelab".serviceConfig.Group;
  };
}
```

### 4. DNS Automation Enhancements (January 2025)

Recent improvements to the tunnel module add richer DNS automation without breaking the existing service declarations:

1. **Explicit registration modes** – `dnsRegistration.mode` accepts `"cli"`, `"api"`, or `"auto"` (prefers CLI when an origin cert exists). CLI runs now reuse a persistent cert inside the tunnel state directory unless `persistOriginCert = false`.
2. **Payload caching** – a JSON snapshot of the desired DNS state is stored on disk (default: `/var/lib/cloudflared-<tunnel>/dns-records.json`). When nothing changes, registration is skipped entirely.
3. **Per-host overrides** – every Caddy vhost can override zone, record target, TTL, proxied flag, comments, or disable registration via `modules.services.caddy.virtualHosts.<name>.cloudflare.dns.*`.
4. **Metrics + observability** – enable `dnsRegistration.metrics.enable` to emit Prometheus textfile gauges/counters (point it at `/var/lib/node_exporter/textfile_collector` if you want node-exporter to scrape it).
5. **Custom DNS defaults** – `dnsRegistration.defaults` lets you define shared TTL/proxied/comment/target values that hosts inherit unless overridden.

Example tunnel configuration with the new options:

```nix
modules.services.cloudflared.tunnels.forge = {
  id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
  credentialsFile = config.sops.secrets."cloudflared/forge".path;
  originCertFile = config.sops.secrets."cloudflared/origin-cert".path;
  persistOriginCert = true;

  dnsRegistration = {
    enable = true;
    mode = "auto";
    zoneName = "holthome.net";
    cache.file = "/var/lib/cloudflared-forge/dns-cache.json";
    defaults = {
      proxied = true;
      ttl = 120;
      comment = "Managed by Nix";
    };
    metrics = {
      enable = true;
      textfilePath = "/var/lib/node_exporter/textfile_collector/cloudflared_dns_forge.prom";
    };
  };
};
```

And a per-host override alongside the service declaration:

```nix
modules.services.caddy.virtualHosts.cooklangFederation.cloudflare = {
  enable = true;
  tunnel = "forge";
  dns = {
    ttl = 300;
    proxied = true;
    zoneName = "holthome.net";
    comment = "Cooklang Federation";
  };
};
```

Set `dns.register = false;` when you need to keep a hostname in the tunnel ingress but manage its DNS record elsewhere (for example, split-horizon zones on the LAN resolver).

## Technical Details

### Auto-Discovery Mechanism

The cloudflared module scans `config.modules.services.caddy.virtualHosts` to find services with:
1. `enable = true`
2. `cloudflare != null && cloudflare.enable == true`
3. `cloudflare.tunnel == tunnelName`

For each matching service, it generates an ingress rule:
```yaml
ingress:
  - hostname: grafana.holthome.net
    service: http://127.0.0.1:80
  - hostname: sonarr.holthome.net
    service: http://127.0.0.1:80
  # Catch-all to prevent origin IP leakage
  - service: http_status:404
```

### Generated config.yaml

The module generates a complete `config.yaml` for each tunnel:
```yaml
credentials-file: /run/secrets/cloudflared/homelab-credentials
ingress:
  - hostname: service1.holthome.net
    service: http://127.0.0.1:80
  - hostname: service2.holthome.net
    service: http://127.0.0.1:80
  - service: http_status:404
```

### Systemd Service Per Tunnel

Each tunnel gets its own systemd service: `cloudflared-{tunnelName}.service`

**Service Features:**
- Depends on `caddy.service` (ensures Caddy is running)
- Runs as dedicated `cloudflared` user
- Security hardening (PrivateTmp, ProtectSystem, etc.)
- Auto-restart on failure
- Type=notify for proper startup signaling

## Security Considerations

### 1. caddy-security/PocketID SSO Continues Working

**No Changes Required:**
- All authentication flows remain in Caddy
- Passwordless WebAuthn still works
- SSO authentication unchanged
- IP-based bypass rules continue to function

**Request Flow:**
```
User → Cloudflare → cloudflared → Caddy → caddy-security → Service
```

### 2. IP Restrictions Preserved

Services with IP-restricted API bypass (like Sonarr, Radarr) continue working:
```nix
caddySecurity = {
  enable = true;
  portal = "pocketid";
  policy = "default";
  bypassPaths = [ "/api" "/feed" ];
  allowedNetworks = [
    "172.16.0.0/12"    # Docker networks
    "192.168.1.0/24"   # Local LAN
    "10.0.0.0/8"       # Internal VPN
  ];
};
```

**Note**: External access via tunnel will NOT bypass authentication for API endpoints. This is correct - API access should still require authentication for external requests.

### 3. Credential Management

**SOPS Integration:**
- Tunnel credentials stored in SOPS-encrypted secrets
- File ownership set to cloudflared user/group
- Credentials file path passed to cloudflared via config.yaml

**Example Secret Structure:**
```yaml
# hosts/forge/secrets.sops.yaml
cloudflared:
  homelab-credentials: |
    {
      "AccountTag": "...",
      "TunnelSecret": "...",
      "TunnelID": "...",
      "TunnelName": "homelab"
    }
```

### 4. Catch-All Protection

**Critical Security Feature:**
The auto-generated ingress ALWAYS includes a final catch-all rule:
```yaml
- service: http_status:404
```

This prevents accidental exposure of unlisted services and protects the origin IP from being leaked.

## Migration Strategy

### Phase 1: Module Implementation (This Phase)
1. ✅ Research complete (Gemini Pro consultation)
2. ⏳ Update Caddy module with `cloudflare` submodule
3. ⏳ Replace cloudflared module with declarative version
4. ⏳ Test build locally

### Phase 2: Infrastructure Setup
1. Create Cloudflare Tunnel via Cloudflare dashboard or CLI
2. Download tunnel credentials JSON
3. Encrypt credentials with SOPS
4. Add to host secrets configuration

### Phase 3: Service Migration (Gradual)
1. Start with non-critical service (e.g., test service)
2. Add `cloudflare.enable = true` to service config
3. Deploy and validate external access
4. Verify caddy-security/PocketID authentication still works
5. Migrate additional services incrementally

### Phase 4: Validation
1. External access from internet works
2. Internal LAN access still works (dual-path)
3. caddy-security/PocketID SSO functions correctly
4. IP-based bypass rules work for internal networks
5. Metrics and monitoring operational

## Compatibility Matrix

### What Stays the Same
- ✅ Caddy reverse proxy configuration
- ✅ caddy-security/PocketID SSO integration
- ✅ Passwordless WebAuthn authentication
- ✅ Security headers (HSTS, CSP, etc.)
- ✅ IP-based API bypass rules
- ✅ ACME DNS-01 certificate management
- ✅ Metrics collection (Prometheus)
- ✅ Log shipping (Loki/Promtail)
- ✅ Backup integration
- ✅ DNS record generation

### What Changes
- ✅ Services can opt-in to external access via tunnel
- ✅ New cloudflared systemd service(s) per tunnel
- ✅ Additional SOPS secret for tunnel credentials
- ✅ Services exposed via tunnel accessible from internet

### What's New
- ✅ Declarative tunnel configuration
- ✅ Automatic ingress rule generation
- ✅ Multi-tunnel support (e.g., production, staging)
- ✅ Service-level external access control

## Benefits Summary

### Operational Benefits
1. **No Firewall Management**: No need to open ports 80/443 on home router
2. **Dynamic IP Tolerance**: Home IP changes don't affect external access
3. **DDoS Protection**: Cloudflare network shields origin server
4. **Geographic Acceleration**: Cloudflare CDN provides global reach
5. **Automatic Failover**: Cloudflare handles tunnel connection issues

### Configuration Benefits
1. **Declarative**: All configuration in NixOS, version controlled
2. **Type-Safe**: Nix type checking prevents configuration errors
3. **Self-Documenting**: Service declarations show external accessibility
4. **Zero Duplication**: Single configuration path for all services
5. **Modular**: Follows established design patterns

### Security Benefits
1. **Origin IP Hidden**: Cloudflare proxies all external traffic
2. **TLS Termination**: Two layers (Cloudflare + Caddy)
3. **Rate Limiting**: Can add Cloudflare rate limiting rules
4. **WAF Available**: Optional Web Application Firewall
5. **Centralized Auth**: All authentication still via caddy-security/PocketID

## Anti-Patterns to Avoid

### ❌ DON'T: Create Per-Service Tunnel Configurations
```nix
# BAD: Duplicates ingress configuration
modules.services.cloudflared.services = {
  grafana = {
    hostname = "grafana.holthome.net";
    service = "http://localhost:3000";
  };
};
```

**Why**: Violates DRY principle, duplicates Caddy configuration

### ❌ DON'T: Bypass Caddy for Tunnel Traffic
```nix
# BAD: Points directly to service
defaultService = "http://127.0.0.1:3000";  # Service port
```

**Why**: Loses all Caddy features (auth, headers, metrics)

### ❌ DON'T: Mix Authentication Systems
```nix
# BAD: Using both Cloudflare Access and caddy-security
cloudflare.access = { enable = true; };
caddySecurity = { enable = true; };
```

**Why**: Redundant, confusing, harder to maintain

### ❌ DON'T: Hard-Code Tunnel Names in Services
```nix
# BAD: Service knows about specific tunnel
cloudflare.tunnel = "homelab-production-tunnel-2024";
```

**Why**: Makes service configuration environment-specific

**Better**: Use a canonical tunnel name per environment:
```nix
cloudflare.tunnel = "homelab";  # Same name across all envs
```

## Future Enhancements

### Potential Additions (Post-MVP)
1. **Multiple Tunnel Support**: Different tunnels for different environments
2. **Conditional Exposure**: Enable tunnel access based on build-time flags
3. **Metrics Integration**: Cloudflare Tunnel metrics exported to Prometheus
4. **Health Checks**: Cloudflare can health-check tunnel endpoints
5. **Access Policies**: Optional Cloudflare Access integration (if needed)

### Integration Opportunities
1. **DNS Record Sync**: Auto-update DNS records when tunnel configured
2. **Monitoring Alerts**: Alert when tunnel disconnects
3. **Backup Validation**: Include tunnel config in backup system
4. **Documentation**: Auto-generate service access documentation

## References

### Documentation
- [Modular Design Patterns](./modular-design-patterns.md) - Core design principles
- [Reverse Proxy Pattern](./reverse-proxy-pattern.md) - Caddy integration patterns
- [PocketID Integration Pattern](./pocketid-integration-pattern.md) - SSO configuration

### External Resources
- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [cloudflared GitHub](https://github.com/cloudflare/cloudflared)
- [NixOS Service Hardening](https://nixos.wiki/wiki/Security)

### Research Source
- Gemini 2.5 Pro consultation (November 11, 2025)
- Architecture analysis and recommendations
- Implementation patterns aligned with existing codebase

## Next Steps

### Immediate Actions
1. Review this implementation plan
2. Validate architecture decisions with team/self
3. Set up test Cloudflare Tunnel in dashboard
4. Implement module changes in development branch
5. Test with single non-critical service

### Decision Points
- [ ] Approve architecture pattern (tunnel complements Caddy)
- [ ] Approve service declaration pattern (cloudflare submodule)
- [ ] Approve auto-discovery mechanism
- [ ] Approve security approach (all auth via caddy-security/PocketID)
- [ ] Choose initial tunnel name convention

### Before Production
- [ ] Module implementation complete and tested
- [ ] Tunnel credentials configured in SOPS
- [ ] Documentation updated
- [ ] Monitoring alerts configured
- [ ] Backup system includes tunnel config
- [ ] Rollback plan documented

---

**Document Owner**: Ryan
**Last Updated**: November 11, 2025
**Review Cadence**: After initial implementation, then as needed
