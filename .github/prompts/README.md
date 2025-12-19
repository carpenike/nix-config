# Prompt Library

This directory contains reusable prompt bundles for GitHub Copilot Chat, MCP tools, and any future AI assistants we adopt. Each prompt captures the context, guardrails, and doc links that Copilot must load before working inside this repository.

## Structure

```text
.github/prompts/
  README.md                 # This file
  nixos/                    # Service + host automation prompts
  security/                 # Reviews, incident response, SOPS workflows
  docs/                     # Release notes, changelog + pattern docs
  ci/                       # Validation + automation helpers
```

Each prompt file follows this pattern:

```markdown
---
agent: ask
description: Short purpose statement
---
# Title

## Role
Describe the role/expertise the assistant must assume.

## Inputs
Enumerate the details the human must provide when invoking the prompt.

## Constraints
List the guardrails (Taskfile commands, SOPS rules, doc references, etc.).

## Deliverables
Spell out the expected outputs.

## References
Link to the repo docs/instructions the assistant must read.
```

## Usage

1. Open GitHub Copilot Chat (or another assistant that can reference repo files).
2. Run `/prompt <relative-path>` (for example `/prompt nixos/service-module`) to load the file.
3. Provide the service-specific details requested in the "Inputs" section.
4. Keep the referenced docs open so Copilot can cite them when generating code.

## Contribution Guidelines

- **Keep prompts small and focused.** Create a new file when a workflow diverges.
- **Link to canonical docs.** Use relative paths (e.g., `../../docs/modular-design-patterns.md`).
- **Document changes.** Mention prompt updates in PR descriptions and changelogs when relevant.
- **Validate instructions.** After editing a prompt, run it in Copilot Chat to ensure the flow still works.

### Available Prompts (quick reference)

- `nixos/service-module` – end-to-end service scaffolding
- `nixos/host-onboarding` – create/rebuild host layout
- `nixos/storage-backup` – datasets + Restic/Sanoid hooks
- `nixos/monitoring-coverage` – Kuma + Prometheus coverage
- `security/audit` – pre-merge security checklist
- `security/secret-rotation` – SOPS-managed rotations
- `docs/changelog` – changelog/release note helper
- `docs/pattern-update` – update architecture docs
- `ci/validation` – run required validation commands

### Related Documentation

- `docs/workarounds.md` – Temporary workarounds and overrides tracking (monthly review)
