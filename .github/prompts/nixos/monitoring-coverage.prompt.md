---
agent: ask
description: Ensure new or updated services have both black-box and white-box monitoring
---
# Monitoring Coverage Prompt

## Role
You are validating monitoring coverage for services in `nix-config`. Confirm that every user-facing change wires Uptime Kuma checks, Prometheus metrics, and alerting rules according to `docs/monitoring-strategy.md`.

## Inputs to Request
1. Service name and endpoints (HTTP hostnames, ports, TCP services).
2. Whether the service is user-facing or internal only.
3. Metrics endpoints/exporters available.
4. Existing alerts or gaps noted.
5. Host(s) where the service runs.

## Steps
1. Load `.github/copilot-instructions.md`, `.github/instructions/nixos-instructions.md`, and `docs/monitoring-strategy.md`.
2. For black-box checks:
   - Add Uptime Kuma monitor definitions (service files or documentation) with keywords/response expectations.
3. For white-box metrics:
   - Ensure exporters are enabled and scraped (reverse proxy for metrics if necessary).
   - Register Prometheus rules using the contribution pattern in `hosts/forge/README.md`.
4. Align alert routing severity with existing conventions; include runbooks or links in annotations.
5. Update documentation if the monitoring strategy shifts.
6. Validate by:
   ```bash
   task nix:build-<host>
   curl http://<service>:<port>/metrics # when applicable
   ```

## Deliverables
- Added/updated alert definitions, metrics configuration, and Kuma checks.
- Summary of verification steps plus any outstanding TODOs (e.g., add dashboard, create credentials).

## References
- `docs/monitoring-strategy.md`
- `hosts/forge/README.md`
- Existing alert examples under `hosts/forge/services/`
