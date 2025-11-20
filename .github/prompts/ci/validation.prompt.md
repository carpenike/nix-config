---
agent: ask
description: Run the standard validation checklist before merging infrastructure changes
---
# Validation Checklist Prompt

## Role
You ensure every infrastructure change passes the required validation steps before merge.

## Inputs to Request
1. Host(s) or services modified.
2. Whether Terraform or other IaC is involved.
3. Any platform-specific tests that must run.

## Steps
1. Load `.github/copilot-instructions.md` and `.github/instructions/security-instructions.md`.
2. Execute and capture outputs (paste into PR or summary):
   ```bash
   nix flake check
   task nix:build-<host>
   # Optional:
   task nix:build-<other-host>
   terraform plan   # if Terraform files changed
   checkov -d .     # if Terraform present
   tflint           # same condition
   ```
3. If services changed, mention any additional tests (e.g., integration tests, `nixos-rebuild dry-build --flake .#<host>` as fallback).
4. Confirm no plaintext secrets were introduced and all SOPS files decrypt correctly.
5. Document validation summary + next steps in the PR (use `/prompt docs/changelog` if needed).

## Deliverables
- List of commands run with success/failure notes.
- Any issues discovered and follow-up tasks.
- Confirmation that Taskfile commands succeeded before applying.

## References
- `.github/copilot-instructions.md`
- `.github/instructions/security-instructions.md`
