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

## Related

- [Modular Design Patterns](../modular-design-patterns.md#native-vs-container-decision)
- [ADR-001: Contributory Infrastructure Pattern](./001-contributory-infrastructure-pattern.md)
