---
agent: ask
description: Add storage datasets, backups, and replication hooks for a service
---
# Storage + Backup Contribution Prompt

## Role
You specialize in the persistence layer for `nix-config`. For any service change, ensure ZFS datasets, Restic jobs, and (optionally) Sanoid/Syncoid replication match the repo standards.

## Inputs to Request
1. Service name and data directory.
2. ZFS pool hierarchy (tank vs rpool) and desired properties (recordsize, compression, atime).
3. Backup targets (repository name, frequency, snapshot needs).
4. Replication or preseed requirements.
5. Validation commands already run.

## Key Patterns

### Using `mylib.storageHelpers`

Service modules should use the storage helpers library:

```nix
{ config, lib, mylib, ... }:
let
  storageHelpers = mylib.storageHelpers;

  # Walk dataset tree to find inherited replication config
  replicationConfig = storageHelpers.mkReplicationConfig {
    inherit config;
    datasetPath = "tank/services/${serviceName}";
  };

  # Resolve NFS mount dependency
  nfsMountConfig = storageHelpers.mkNfsMountConfig {
    inherit config;
    nfsMountDependency = cfg.nfsMountDependency;
  };
in
```

### Host Defaults Library

For hosts like forge, use the centralized defaults:

```nix
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
in
{
  modules.backup.sanoid.datasets."tank/services/<service>" =
    forgeDefaults.mkSanoidDataset "<service>";

  backup = forgeDefaults.mkBackupWithSnapshots "<service>";
}
```

## Steps
1. Load `.github/instructions/nixos-instructions.md`, `.github/instructions/security-instructions.md`, and `docs/persistence-quick-reference.md`.
2. Review `docs/repository-architecture.md` for storage architecture patterns.
3. Declare datasets under `modules.storage.datasets.services.<name>` with owner/group/mode rules (native vs container) and ZFS properties.
4. If using snapshots, wire `modules.backup.restic` + `useSnapshots` and include dataset references as required by `docs/backup-system-onboarding.md`.
5. Add monitoring/alerts for backup success (Prometheus rules or systemd timers) per `docs/monitoring-strategy.md`.
6. Document any secrets needed for repositories (must go through SOPS). Do **not** inline credentials.
7. Validate with:
   ```bash
   nix flake check
   task nix:build-<host>
   systemctl list-timers | grep restic
   ```
   Capture outputs in the PR summary.

## Deliverables
- Updated service module or host file with dataset + backup definitions.
- Notes on SOPS secrets to create and replication steps.
- Confirmation of validation commands and remaining follow-ups.

## References
- `docs/repository-architecture.md` - High-level structure
- `docs/adr/README.md` - Architectural decision records
- `lib/host-defaults.nix` - Parameterized defaults factory
- `modules/nixos/storage/helpers-lib.nix` - Storage helper functions
- `docs/persistence-quick-reference.md`
- `docs/backup-system-onboarding.md`
- `docs/modular-design-patterns.md`
- `hosts/forge/README.md`
