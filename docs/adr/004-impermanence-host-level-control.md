# ADR-004: Impermanence Host-Level Control

**Status**: Accepted
**Date**: December 9, 2025
**Context**: NixOS hosts with different storage architectures

## Context

The homelab has hosts with different storage architectures:

| Host | Disks | Root Pool | Service Storage |
|------|-------|-----------|-----------------|
| **Forge** | 2 | `rpool` (impermanent) | `tank/services/*` (persistent ZFS datasets) |
| **Luna** | 1 | `rpool` (impermanent) | `/persist/var/lib/*` (impermanence bind-mounts) |

The impermanence module initially had hardcoded service paths:

```nix
# Before: Hardcoded in modules/nixos/impermanence.nix
environment.persistence."${cfg.persistPath}" = {
  directories = [
    "/var/log"
    "/var/lib/cache"
    "/var/lib/nixos"
    "/var/lib/omada"      # ❌ Service-specific
    "/var/lib/unifi"      # ❌ Service-specific
    { directory = "/var/lib/caddy"; ... }
  ];
};
```

**Problem**: If Omada were deployed to Forge, the impermanence contribution would be meaningless (Forge uses ZFS datasets, not bind-mounts). The module was making assumptions about host architecture.

## Decision

Adopt **host-level control** for service persistence:

1. **Module declares core system paths** (logs, NixOS state, SSH keys)
2. **Host declares service persistence** based on its storage architecture
3. **Service modules remain agnostic** to storage implementation

### Implementation

```nix
# modules/nixos/impermanence.nix
options.modules.system.impermanence = {
  enable = lib.mkEnableOption "impermanence";

  # Contributory options
  directories = lib.mkOption {
    type = lib.types.listOf persistenceDirType;
    default = [];
  };
  files = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
  };
};

config = lib.mkIf cfg.enable {
  # Core system paths (always needed on impermanent hosts)
  modules.system.impermanence.directories = [
    "/var/log"
    "/var/lib/cache"
    "/var/lib/nixos"
  ];

  modules.system.impermanence.files = [
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_ed25519_key.pub"
    "/etc/ssh/ssh_host_rsa_key"
    "/etc/ssh/ssh_host_rsa_key.pub"
  ];

  # Aggregate all contributions
  environment.persistence."${cfg.persistPath}" = {
    directories = cfg.directories;
    files = cfg.files;
  };
};
```

```nix
# hosts/luna/default.nix
modules.system.impermanence = {
  enable = true;

  # Luna uses single-disk, needs bind-mounts for service data
  directories = [
    "/var/lib/omada"
    "/var/lib/unifi"
    { directory = "/var/lib/caddy"; user = "caddy"; group = "caddy"; mode = "0750"; }
  ];
};
```

```nix
# hosts/forge/services/sonarr.nix
# Forge uses ZFS datasets, no impermanence contribution needed
modules.storage.datasets.services.sonarr = {
  mountpoint = "/var/lib/sonarr";
  recordsize = "16K";
};
```

## Consequences

### Positive

- **Correct separation**: Host knows its storage architecture
- **Service agnostic**: Modules don't assume persistence method
- **Clear documentation**: Host config shows what needs persistence
- **No wasted config**: No impermanence paths for ZFS-backed services

### Negative

- **Manual tracking**: Must remember to add persistence for new services on Luna
- **Duplication potential**: Similar patterns across hosts

### Mitigations

- Document pattern with clear examples in host config
- Use comments to explain the two patterns (simple path vs ownership attrset)

## Decision Matrix

| Question | Answer | Action |
|----------|--------|--------|
| Single-disk host? | Yes | Add to `modules.system.impermanence.directories` |
| | No | Use `modules.storage.datasets` |
| Service runs as non-root? | Yes | Use `{ directory = ...; user = ...; }` form |
| | No | Use simple string path |

## Adding New Service Persistence (Luna)

```nix
# hosts/luna/default.nix
modules.system.impermanence.directories = [
  # Existing services
  "/var/lib/omada"
  "/var/lib/unifi"

  # New service (simple path)
  "/var/lib/newservice"

  # New service (with ownership)
  { directory = "/var/lib/otherservice"; user = "other"; group = "other"; mode = "0750"; }
];
```

## Related

- [ADR-001: Contributory Pattern](./001-contributory-infrastructure-pattern.md) - Impermanence now uses this
- [Repository Architecture](../repository-architecture.md) - Host architecture differences
- [Persistence Quick Reference](../persistence-quick-reference.md) - ZFS dataset patterns
