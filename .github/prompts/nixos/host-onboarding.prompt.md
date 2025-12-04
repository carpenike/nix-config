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
3. Plan the host layout:
   - `hosts/<host>/core/*.nix`
   - `hosts/<host>/infrastructure/*.nix`
   - `hosts/<host>/services/*.nix`
4. Define persistence per `docs/persistence-quick-reference.md` and register datasets with `modules.storage.datasets`.
5. Wire backups using `docs/backup-system-onboarding.md` conventions.
6. Add monitoring hooks per `docs/monitoring-strategy.md` (systemd alerts, Gatus endpoint contributions, Prometheus rules).
7. Validate with `task nix:build-<host>` before recommending `task nix:apply-nixos host=<host> NIXOS_DOMAIN=holthome.net`.

## Deliverables
- New host directory structure populated with core/infrastructure/service modules.
- Storage + backup + alert definitions co-located with the host.
- Summary of validation commands run and remaining follow-ups (e.g., create SOPS secrets).

## References
- `hosts/forge/README.md`
- `docs/modular-design-patterns.md`
- `docs/persistence-quick-reference.md`
- `docs/backup-system-onboarding.md`
- `docs/monitoring-strategy.md`
