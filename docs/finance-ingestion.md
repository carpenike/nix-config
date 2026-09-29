# Forge finance ingestion

`hosts/forge/services/finance-ingestion.nix` enables the deterministic ingestion
owner and independent monitoring. This is ingestion/readback infrastructure,
not the later shared-snapshot, checkpoint, or household-report pipeline.

## Activation prerequisites

- Pair this configuration with the MCP release providing `due`, `metrics`, and
  `run --distinguish-degraded`. The host assertion rejects older unit wiring;
  do not remove it or mix a newer module with an older CLI package.
- Provision `homelab-mcp/ingest-env` in Forge SOPS. It contains **only**
  `HOMELAB_MCP_FINANCES_SIDECAR_TOKEN`, matching the existing sidecar. Its
  runtime file is root-owned `0400`. Never reuse the full MCP/OAuth dotenv.
- Ryan confirmed the external 08:30 sweep is disabled. Keep a single scheduled
  bank-ingestion owner; coordinate interactive Actual/MCP callers separately.
- Preserve `/var/lib/homelab-mcp/finances-ingest/` and its backend identity,
  permissions, lock/established markers, and existing state. The controlled
  September 29 reservation forbids another POST before
  **2026-09-30 13:41:49 America/New_York**, or any later deadline in state.
  No migration, initialization, deletion, or clock adjustment may bypass it.
- Verify the `tank/services/homelab-mcp` mount and existing NAS/offsite backup
  custody. An active dataset initializer alone is not proof of a mounted
  dataset. Both units assert the mount before running.

The coordinator must provision, repin, and deploy together. Configuration/test
success is not live activation, bank freshness, or delivered notification proof.

## Schedule and outcomes

`homelab-mcp-finances-ingest.timer` checks every 15 minutes, persistently.
This is an **eligibility poll**, not a 15-minute bank-sync schedule. The CLI
keeps at least 86,400 seconds between durable POST reservations, including
failed attempts; unknown outcomes require explicit operator recovery.

`due` performs no HTTP and makes no success claim: exit 0 permits execution;
1 skips normal not-due/busy ticks; 255 fails on disabled, corrupt/missing state
or other genuine errors. `run --allow-bank-sync` retains exit 0 (success),
1 (degraded/failed), and 2 (refused). There is no systemd retry.

The upstream unit opts into `--distinguish-degraded`, which gives a durably
completed, verified known partial exit 3 only with at least one verified account.
JSON status stays `degraded`. Every unverified account must match an explicitly
reported bank failure; all-account failures, inventory, coverage and readback
defects still fail with exit 1. Only 3 is added to `SuccessExitStatus`; never add
1, because that also makes `due`'s normal skip eligible. Failed exit 1, refusal
exit 2, preconditions, credentials,
mount, timeout and signal failures remain failures. This avoids turning one
bank's attention result into a generic systemd outage. **Unit success is not
financial success**: durable evidence and verification metrics determine health.

## Independent evidence and alerts

`finance-ingest-metrics.timer` runs every two minutes, without credentials,
HTTP, MCP, OAuth, Agent Host, or a model. It reads atomic local state without
taking the writer lock. It runs as the existing backend UID but cannot write
the state in its filesystem view or use the network, and runtime secret paths
are hidden. This reuses the trusted backend identity, not a new credential-
isolation boundary.

Validated aggregate metrics are atomically renamed in
`/run/finance-ingest-metrics/`, mode `0640` with the node-exporter group.
A root-managed flat link in the existing textfile directory exposes them.
The backend gains neither membership in node-exporter's group nor write access
to the shared collector directory. Valid failure metrics survive a nonzero CLI
exit; malformed/empty output retains prior evidence and fails the collector.
The systemd failure alert detects publication failures, and the generated
timestamp detects old or absent evidence.

| Condition | Severity |
|---|---|
| Failed/incomplete pipeline report, all accounts unverified, or other verification failures | High |
| Unknown outcome / in-flight run beyond deadline plus two minutes | High |
| Refused/startup-failed worker, stopped or missing eligibility timer | High |
| No attempt 30 minutes beyond the durable next-attempt time | High |
| Collector read/write failure, or metrics absent / older than six minutes | High |
| Some accounts verified, only bank-attention exceptions | Low |

The known 21-verified / one-Santander-attention result is **partial, not an
outage or all-green**. Most recent reported evidence includes partial results;
it is not an all-accounts-success watermark. Normal in-flight work receives
deadline grace, not an unlimited suppression. Fixed alert labels reuse existing
Alertmanager grouping, escalation and Pushover routing; no per-poll notifications
or run-ID labels are introduced. Starting a retry does not resolve an existing
completed-run failure or bank-attention incident. Same-host monitoring does not
survive Forge loss; an off-host dead-man/host monitor remains necessary and is
not validated by this implementation.

## Investigation and export

Inspect the two timers, their journals, and the private durable report before
acting. Stop the **ingestion timer only** to pause automatic attempts; leave
the collector active so a stopped owner remains visible. Never clear state to
retry an uncertain POST. Repair a bank connection through the approved workflow,
without retrying inside the reservation.

The existing **05:30 America/New_York export remains GET-only and unchanged**.
No `OnSuccess` or unconditional post-service export hook is attached: a skipped
eligibility condition is not proof of an actual attempt, and a reported partial
is not a successful shared snapshot. After a verified actual attempt an operator
may start the existing `homelab-mcp-finances-export.service` for a read-only
dashboard refresh. Automatic snapshot/export checkpointing remains RB-21/RB-23
work; a recent export must never disguise stale bank data.

## Focused validation

With the paired MCP pin, run the `finance-ingestion-contract` and
`finance-ingestion-monitoring` flake checks for the local system. The latter
uses `promtool check/test rules` and offline publisher fixtures covering
partials, all-bank failures, other verification failures, deadline grace,
unknown outcomes, timer loss, missing/stale metrics and write failure.
Neither check contacts banks or starts production units. Follow the normal
guarded deployment procedure only after the remaining prerequisites are met;
verify a real device notification separately with explicit authorization.
