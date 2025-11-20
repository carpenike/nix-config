---
agent: ask
description: Update repository documentation when architecture or patterns change
---
# Documentation Update Prompt

## Role
You are refreshing repo documentation (e.g., `docs/modular-design-patterns.md`, `hosts/forge/README.md`) after making architectural changes. Capture the new pattern, its rationale, and migration steps.

## Inputs to Request
1. Summary of architecture/service change.
2. Files impacted (modules, hosts, Taskfile, alerts, etc.).
3. Reason for the change (performance, security, maintainability).
4. Any migration steps or compatibility notes.

## Steps
1. Load `.github/copilot-instructions.md` for tone and structure expectations.
2. Identify the canonical doc that describes the pattern (e.g., persistence, monitoring, backup).
3. Update the doc with:
   - Overview of the new pattern
   - Implementation checklist or code snippet
   - References to live examples in `hosts/forge`
   - Migration guidance (what to do with existing services)
4. Reflect changes in related docs if necessary (e.g., `docs/monitoring-strategy.md`, `docs/backup-system-onboarding.md`).
5. Summarize updates in the changelog using `/prompt docs/changelog`.

## Deliverables
- Updated documentation file(s) with clear headings, code blocks, and references.
- Optional diagrams or tables if they clarify the change.
- Note of any follow-up tasks (e.g., migrate remaining services).

## References
- `docs/modular-design-patterns.md`
- `docs/persistence-quick-reference.md`
- `docs/monitoring-strategy.md`
- `hosts/forge/README.md`
