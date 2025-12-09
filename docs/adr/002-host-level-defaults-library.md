# ADR-002: Host-Level Defaults Library

**Status**: Accepted
**Date**: December 9, 2025
**Context**: NixOS homelab with multiple hosts requiring similar patterns

## Context

The `forge` host developed a comprehensive defaults library (`hosts/forge/lib/defaults.nix`) providing helper functions for:

- ZFS replication configuration
- Backup policies
- Alert generation
- Caddy security settings
- Preseed/DR configuration

As we prepared to add additional hosts (nas-0, nas-1), we faced a choice:

1. **Copy-paste**: Duplicate the defaults library for each host
2. **Centralize**: Extract common logic to a shared location

## Decision

Create a **parameterized factory function** in `lib/host-defaults.nix` that generates host-specific defaults based on configuration parameters.

### Structure

```nix
# lib/host-defaults.nix - Shared factory (all logic lives here)
{ config, lib, hostConfig }:
let
  zfsPool = hostConfig.zfsPool or "rpool";
  replication = hostConfig.replication or null;
  backup = hostConfig.backup or { repository = "default"; };
in
{
  mkSanoidDataset = serviceName: { ... };
  mkServiceDownAlert = name: displayName: desc: { ... };
  backup = { enable = true; repository = backup.repository; };
  # ... 250+ lines of helper logic
}
```

```nix
# hosts/forge/lib/defaults.nix - Thin wrapper (host-specific values only)
{ config, lib }:
import ../../../lib/host-defaults.nix {
  inherit config lib;
  hostConfig = {
    zfsPool = "tank";
    servicesDataset = "tank/services";
    replication = {
      targetHost = "nas-1.holthome.net";
      targetDataset = "backup/forge/zfs-recv";
    };
    backup = { repository = "nas-primary"; };
  };
}
```

```nix
# hosts/nas-1/lib/defaults.nix - Different host, same pattern
{ config, lib }:
import ../../../lib/host-defaults.nix {
  inherit config lib;
  hostConfig = {
    zfsPool = "data";
    servicesDataset = "data/services";
    replication = {
      targetHost = "nas-0.holthome.net";  # Cross-replicate
      targetDataset = "backup/nas-1/zfs-recv";
    };
    backup = { repository = "b2-offsite"; };  # Different target
  };
}
```

## Consequences

### Positive

- **Single source of truth**: All helper logic in one place
- **Easy new hosts**: ~45 lines to get full defaults library
- **Consistent patterns**: All hosts use same helper functions
- **Clear separation**: Host values separate from implementation

### Negative

- **Indirection**: Must look at two files to understand a host's defaults
- **Learning curve**: Factory pattern less obvious than direct code

### Mitigations

- Document in `docs/repository-architecture.md`
- Keep host wrapper files minimal and well-commented
- Use descriptive parameter names in `hostConfig`

## Configuration Parameters

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `zfsPool` | Primary ZFS pool name | `"tank"`, `"data"`, `"rpool"` |
| `servicesDataset` | Parent dataset for services | `"tank/services"` |
| `replication.targetHost` | Syncoid destination host | `"nas-1.holthome.net"` |
| `replication.targetDataset` | Syncoid destination dataset | `"backup/forge/zfs-recv"` |
| `backup.repository` | Default Restic repository | `"nas-primary"`, `"b2-offsite"` |
| `backup.mountPath` | NAS mount path for backups | `"/mnt/nas-backup"` |
| `impermanence.persistPath` | Impermanence persist location | `"/persist"` |

## Related

- [Repository Architecture](../repository-architecture.md) - Overall structure
- [ADR-001: Contributory Pattern](./001-contributory-infrastructure-pattern.md) - How services use defaults
