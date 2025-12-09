---
agent: ask
description: Stand up a new host following the forge contribution pattern
---
# Host Onboarding Prompt

## Role
You are preparing a new host (or rebuilding an existing one) inside `nix-config`. Follow the forge architecture (core → infrastructure → services) and ensure storage, backup, and monitoring contributions are co-located with the host files.

## Inputs to Request
1. Hostname, role, and hardware details (CPU/RAM/disks).
2. Network info (IPs, interfaces, VLANs, DNS requirements).
3. Required services and dependencies.
4. Storage layout (ZFS pools/datasets) and replication expectations.
5. Deployment target (Taskfile host name, domain overrides).

## Workflow
1. Load `.github/copilot-instructions.md`, `.github/instructions/nixos-instructions.md`, and `.github/instructions/security-instructions.md`.
2. Review `hosts/forge/README.md` for architecture pattern and contribution rules.
3. Review `docs/repository-architecture.md` for high-level structure.
4. **Create host defaults library** using `lib/host-defaults.nix` as the factory:
   ```nix
   # hosts/<host>/lib/defaults.nix
   import ../../../lib/host-defaults.nix {
     inherit config lib;
     hostConfig = {
       zfsPool = "<pool>";           # e.g., "tank", "rpool", "data"
       servicesDataset = "<pool>/services";
       replication = {               # or null if no replication
         targetHost = "nas-1.holthome.net";
         targetDataset = "backup/<host>/zfs-recv";
       };
       backup = { repository = "nas-primary"; };
     };
   }
   ```
5. Plan the host layout:
   - `hosts/<host>/core/*.nix`
   - `hosts/<host>/infrastructure/*.nix`
   - `hosts/<host>/services/*.nix`
   - `hosts/<host>/lib/defaults.nix` (using the factory pattern)
6. Define persistence per `docs/persistence-quick-reference.md` and register datasets with `modules.storage.datasets`.
7. Wire backups using `docs/backup-system-onboarding.md` conventions.
8. Add monitoring hooks per `docs/monitoring-strategy.md` (systemd alerts, Gatus endpoint contributions, Prometheus rules).
9. Validate with `task nix:build-<host>` before recommending `task nix:apply-nixos host=<host> NIXOS_DOMAIN=holthome.net`.

## Host Architecture Patterns

Understand the two primary patterns before proceeding:

### Single-Disk Hosts (like Luna)
- Use **impermanence** with root rollback
- Service data in `modules.system.impermanence.directories`
- Pool: `rpool/safe/persist`

### Two-Disk Hosts (like Forge)
- Dedicated **tank** pool for services
- Service data in `modules.storage.datasets.services.<name>`
- ZFS replication to NAS via Sanoid/Syncoid
- Pool: `tank/services`

See `docs/adr/004-impermanence-host-level-control.md` for the architectural decision.

## Deliverables
- New host directory structure populated with core/infrastructure/service modules.
- Host defaults library (`lib/defaults.nix`) using the parameterized factory.
- Storage + backup + alert definitions co-located with the host.
- Summary of validation commands run and remaining follow-ups (e.g., create SOPS secrets).

## References
- `docs/repository-architecture.md` - High-level structure overview
- `docs/adr/README.md` - Architectural decision records
- `hosts/forge/README.md` - Reference host implementation
- `lib/host-defaults.nix` - Parameterized defaults factory
- `docs/modular-design-patterns.md`
- `docs/persistence-quick-reference.md`
- `docs/backup-system-onboarding.md`
- `docs/monitoring-strategy.md`
