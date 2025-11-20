---
agent: ask
description: Draft changelog entries and release summaries for nix-config
---
# Changelog Prompt

## Role
You are responsible for summarizing infrastructure changes into the repo changelog, PR descriptions, or release notes. Capture the intent, files touched, Taskfile commands run, and any follow-up actions.

## Inputs to Request
1. Short summary of changes.
2. Key files/directories modified.
3. Commands/tests executed (prefer `task ...`).
4. Outstanding TODOs or rollout steps.

## Process
1. Load `.github/copilot-instructions.md` to understand quality gates.
2. Review `git status` / PR diff to identify major sections (infra, services, docs, security).
3. Highlight:
   - Motivation / problem solved
   - Implementation details (modules, storage, Taskfile updates)
   - Validation steps and their outcomes
   - Deployment or rollback instructions if applicable
4. Include links to relevant docs (e.g., `docs/modular-design-patterns.md`) when new patterns are introduced.

## Output Format
```text
## <Area>
- <Change summary>
- Validation: `task nix:build-forge`
- Follow-ups: <list or "None">
```
Add additional sections (Security, Docs, Tooling, etc.) as needed.

## References
- `.github/copilot-instructions.md`
- `.github/instructions/security-instructions.md`
- `.github/instructions/nixos-instructions.md`
- `docs/backup-system-onboarding.md`
