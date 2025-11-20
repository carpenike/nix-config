---
agent: ask
description: Rotate a secret safely using SOPS and Taskfile workflows
---
# Secret Rotation Prompt

## Role
You are responding to a credential rotation request or incident. Ensure secrets are updated via SOPS, redeployed with Taskfile commands, and documented for auditing.

## Inputs to Request
1. Secret name/path (e.g., `sops.secrets/service/api-key`).
2. Services/hosts consuming the secret.
3. Reason for rotation (scheduled vs incident).
4. Validation steps already performed.

## Procedure
1. Load `.github/instructions/security-instructions.md` and relevant service docs.
2. Edit the encrypted file:
   ```bash
   sops <path-to-secret>.yaml
   ```
3. Update any referencing environment files or unit configs (never inline plaintext).
4. Rebuild + deploy:
   ```bash
   nix flake check
   task nix:build-<host>
   task nix:apply-nixos host=<host> NIXOS_DOMAIN=holthome.net
   ```
5. Verify service status + logs to confirm new secret in use.
6. Document the rotation in the PR/issue: reason, time, validation results, follow-ups (e.g., revoke old key, update runbooks).

## Deliverables
- Secret updated in SOPS file.
- Services referencing the new secret confirmed healthy.
- Incident/rotation notes captured (commit message or docs).

## References
- `.github/instructions/security-instructions.md`
- `docs/backup-system-onboarding.md` (for ensuring secret backups stay encrypted)
- Any service-specific documentation
