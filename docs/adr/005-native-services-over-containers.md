# ADR-005: Native Services Over Containers

**Status**: Accepted
**Date**: December 9, 2025
**Amended**: July 17, 2026
**Context**: NixOS homelab service implementation strategy

## Context

When adding a new service to the homelab, there are typically three implementation options:

1. **Native NixOS service**: Wrap or use the upstream NixOS module from nixpkgs
2. **Custom native service**: Run a package with a repository-owned systemd unit
3. **Container (Podman/Docker)**: Run the service in an OCI container

Both approaches work, but they have significantly different characteristics in terms of maintainability, integration, and operational complexity.

## Decision

> Prefer a suitable native NixOS deployment. When two implementations are
> operationally equivalent, native wins. Use a pinned container when it is the
> better-supported or lower-maintenance deployment.

A NixOS module merely existing does not make it suitable. Evaluate version and
feature parity, secrets, persistent state, database migrations, hardware access,
upstream support, operational observability, and ongoing maintenance ownership.

Follow this priority order when adding a new service:

### 1. Check for a Nixpkgs NixOS Module

If the module is operationally suitable, use the wrapper approach. For example,
Gatus has `services.gatus`, so its native module is preferred over a container.

### 2. Check for an Upstream NixOS Module

Treat a flake-supplied module maintained with the application as native.
Consider contributing a generally useful upstream module to nixpkgs.

### 3. Consider a Custom Native Systemd Service

Use this path when a suitable package exists and the application is a
straightforward single process. Prefer it when owning the unit and configuration
is less work than operating an image supply chain.

### 4. Use an OCI Container When It Is the Suitable Deployment

An OCI deployment is appropriate when:

- No practical NixOS module or package exists
- Upstream supports and tests the container deployment path
- Native packaging materially trails required features or security fixes
- The dependency or plugin ecosystem would be expensive to package
- A specific userspace is required for hardware or binary compatibility
- A documented native packaging issue exists
- Rapid upstream updates make a pinned image lower-maintenance

Native wins a tie; it does not win merely by existing. Every container exception
must document the deciding constraint and a concrete condition for revisiting
the decision.

### Dual Runtime Implementations

Do not expose a native/container `deploymentMode` by default. Supporting both
backends doubles important test and migration paths. A dual runtime is permitted
only for:

- A temporary, reversible migration
- An unresolved upstream incompatibility
- A host capability that genuinely changes the correct backend

Plex is the reference exception: Forge uses the container while native VA-API
transcoding is affected by a documented userspace/glibc incompatibility.

### Container Image Selection

When containers are necessary, prefer images in this order:

1. **home-operations images** (PREFERRED): `ghcr.io/home-operations/<service>`
   - Ubuntu 24.04 base with modern glibc
   - Consistent user model (runs as `nobody:nogroup` / 65534)
   - Well-maintained, security-focused
   - Pin with digest: `ghcr.io/home-operations/sonarr:4.0.14.2939@sha256:...`

2. **Official upstream images**: When home-operations doesn't provide one
   - Check for official images before third-party

3. **Avoid linuxserver.io images**: Unless no alternative exists
   - Inconsistent user model (PUID/PGID environment variables)
   - Alpine base can have compatibility issues
   - Less predictable update cadence

**Rationale**: home-operations images are specifically designed for homelab use, with:

- Predictable UID/GID handling via `--user` flag
- Modern glibc for VA-API hardware transcoding compatibility
- Smaller attack surface than feature-heavy alternatives
- Consistent patterns across all images

### Container Operating Requirements

Every enabled OCI deployment must have:

- A terminal `@sha256:<digest>` reference; prefer `version@sha256` when a
  meaningful release tag exists
- Explicit persistent-state mounts with declared ownership and permissions
- Non-root execution when supported by the image
- SOPS-backed secrets delivered at runtime rather than inline values
- An application-appropriate health check
- Resource limits based on expected or observed workload
- Image updates and vulnerability review independent of nixpkgs updates

Rootless Podman, namespaces, and systemd hardening improve isolation, but an OCI
container is not a hard security boundary. Use a VM or microVM when the
requirement is isolation from untrusted code or a separate kernel boundary.

### Reviewed Container Exceptions

The 2026-07-17 deployment audit reviewed all active services. These native
candidates remain correctly containerized:

| Service | Current reason | Revisit when |
| --- | --- | --- |
| Plex | Container userspace provides working VA-API hardware transcoding | The native glibc/VA-API incompatibility is fixed and tested |
| Mealie | Deployed 3.20.1 is materially ahead of stable 3.9.2 and unstable 3.12.0 | Nixpkgs reaches feature/version parity and OIDC/PostgreSQL restore tests pass |
| UniFi | Proven 10.0.162 image owns its MongoDB/JRE lifecycle; stable native is 9.5.21 | Native provides a concrete operational benefit and a database/device migration rehearsal succeeds |

See [Deployment Runtime Policy Audit](../analysis/deployment-runtime-policy-audit.md)
for the complete evidence and re-audit triggers.

## Consequences

### Positive

- **Simpler implementation**: 46% less code in Gatus migration (native vs container)
- **No Podman dependency**: Removes container runtime complexity
- **Better systemd integration**: Native process management, journal logging
- **Automatic updates**: `nix flake update` updates the service
- **Native privilege management**: No container user mapping issues
- **Direct filesystem access**: No volume mount configuration
- **Better debugging**: Standard NixOS tooling applies
- **Pragmatic exceptions**: Containers remain first-class when upstream support
  or userspace compatibility makes them lower-maintenance

### Negative

- **Initial research required**: Must check nixpkgs before implementation
- **Periodic review required**: Native candidates and container exceptions can
  change as nixpkgs and upstream evolve
- **Upstream variability**: Some NixOS modules are better maintained than others
- **Two update surfaces**: Nix packages and OCI images require separate review

### Mitigations

- Keep migrations reversible until data restore and authentication are verified
- Test thoroughly before removing container implementation
- Use VMs or microVMs when a hard isolation boundary is required
- Enforce effective image digest pinning in flake checks

## Examples

### Good: Native Gatus Module

```nix
# Wraps native services.gatus with homelab patterns
config = mkIf cfg.enable {
  services.gatus = {
    enable = true;
    settings = {
      web.port = cfg.port;
      # Endpoints from contributory pattern
    };
  };

  # Add homelab integrations
  systemd.services.gatus = {
    after = [ "zfs-mount.service" ];
    serviceConfig.ReadWritePaths = [ cfg.dataDir ];
  };
};
```

### Avoid: Container When Native Is Equivalent

```nix
# BAD: Don't do this when services.gatus is operationally equivalent
virtualisation.oci-containers.containers.gatus = {
  image = "twinproduction/gatus:latest";
  volumes = [ "/var/lib/gatus:/data" ];
  # Complex port mapping, user mapping, etc.
};
```

### Good: home-operations Container (When Container is Justified)

```nix
# When containers are necessary, use home-operations with pinned digest
image = "ghcr.io/home-operations/sonarr:4.0.14.2939@sha256:abc123...";

# Use --user flag for consistent permissions (not PUID/PGID env vars)
extraOptions = [
  "--user=${toString cfg.uid}:${toString cfg.gid}"
];

# Mount data directory with correct ownership
volumes = [
  "${cfg.dataDir}:/config"
];
```

### Avoid: linuxserver.io Images

```nix
# BAD: linuxserver.io has inconsistent user model
image = "lscr.io/linuxserver/sonarr:latest";
environment = {
  PUID = "1000";  # Environment-based UID is fragile
  PGID = "1000";
};
```

## Related

- [Modular Design Patterns](../modular-design-patterns.md#native-vs-container-decision)
- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md)
- [Workarounds](../workarounds.md) - Documents when containers work around NixOS packaging issues
