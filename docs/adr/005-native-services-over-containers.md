# ADR-005: Native Services Over Containers

**Status**: Accepted
**Date**: 2025-12-09
**Context**: Service implementation strategy

## Context

When adding a new service to the homelab, there are typically two implementation options:

1. **Native NixOS service**: Wrap or use the upstream NixOS module from nixpkgs
2. **Container (Podman/Docker)**: Run the service in an OCI container

Both approaches work, but they have significantly different characteristics in terms of maintainability, integration, and operational complexity.

## Decision

**Always prefer native NixOS services over containerized implementations when available.**

Follow this priority order when adding a new service:

1. **Check for native NixOS module** (`search.nixos.org/options`)
   - If found and sufficient: Use wrapper approach (PREFERRED)
   - Example: Gatus has `services.gatus` - use this instead of container

2. **If native module doesn't exist**, check upstream
   - Some projects maintain their own NixOS modules
   - Consider contributing a module to nixpkgs

3. **Only use containers when**:
   - No native NixOS module exists or is practical
   - Service explicitly requires containerization (security isolation)
   - Rapid prototyping before creating native module
   - NixOS packaging has known issues (e.g., Plex glibc mismatch - see workarounds.md)

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

## Consequences

### Positive

- **Simpler implementation**: 46% less code in Gatus migration (native vs container)
- **No Podman dependency**: Removes container runtime complexity
- **Better systemd integration**: Native process management, journal logging
- **Automatic updates**: `nix flake update` updates the service
- **Native privilege management**: No container user mapping issues
- **Direct filesystem access**: No volume mount configuration
- **Better debugging**: Standard NixOS tooling applies

### Negative

- **Initial research required**: Must check nixpkgs before implementation
- **Migration effort**: Existing containers may need rewriting
- **Upstream variability**: Some NixOS modules are better maintained than others
- **Less isolation**: Containers provide stronger security boundaries

### Mitigations

- Document container version as `.container-backup` when migrating
- Test thoroughly before removing container implementation
- For security-critical services, explicit isolation may justify containers

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

### Avoid: Container When Native Exists

```nix
# BAD: Don't do this when services.gatus exists
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
