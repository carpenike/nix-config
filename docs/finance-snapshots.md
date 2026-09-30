# Forge post-ingestion snapshots

`homelab-mcp-finances-snapshot.timer` checks every five minutes. It runs the
existing exporter with **`--after-ingestion --json --ingestion-state
/var/lib/homelab-mcp/finances-ingest/state.json`**. It never starts ingestion,
reserves bank quota, or attaches an `OnSuccess` hook (systemd also fires that
hook after an `ExecCondition` skip).

## Before activation

Pair this wiring with MCP **0.32.0 or later**, including its tested JSON v1
contract, shared PostgreSQL advisory lock and transactional projection/checkpoint.
The host rejects older packages. Publication, the real pin/lock update and
deployment belong to the coordinator; offline tests are not live acceptance.
Do not bypass accepted-pin or vendored-source checks to deploy a candidate.

The poll inherits the **effective nightly unit's entire environment and ordered
EnvironmentFile list**, including the host's export writer DSN, floor settings,
sidecar token and lading reader DSN. It uses that same MCP UID/GID and database
rights. No secret permissions, roles or group memberships are added. This
preserves the existing exporter's trust boundary, not a newly isolated identity.

The existing MCP dataset must be mounted. Its ingestion state, established
marker, lock and governance checkout are read-only to this unit; there is no
`StateDirectory` creation or bank-state repair. Source/configuration errors fail
closed. The only filesystem write allowance is `/run/finance-snapshot-metrics`.
The wrapper atomically replaces `finance_snapshot.prom` as `0640` under the
existing `2750 MCP:node-exporter` directory pattern, exposed by a root-managed
flat symlink. It never logs captured JSON/stderr or publishes private identifiers.

## Evidence and alerts

- The CLI skips already-published runs and waits during active ingestion or
  once the next bank pull is eligible, so reporting retries cannot keep
  leasing an old generation ahead of its ingestion owner.
  A known partial can be checkpointed without implying all banks are healthy.
- **`export_failed` is authoritative even on a zero-exit no-op.** A retained
  failure makes the wrapper fail its unit; only new successful exporter evidence
  resolves it. Ordinary waiting is not an export failure.
- `finance_snapshot_check_timestamp_seconds` is observer liveness, **not**
  snapshot freshness. The last-success and checkpoint timestamps come only
  from validated committed evidence; unknown timestamps are zero.
- Invalid/missing/future-dated JSON, process errors or the **210-second** child
  deadline publish unavailable/failure gauges. Atomic publication failure keeps
  the prior file and fails the unit. Systemd bounds the entire oneshot at
  **240 seconds**, kills its cgroup, and never overlaps or restarts it.
- HIGH alerts cover unavailable status, recorded failure, failed unit,
  absent/stale (>15 minutes) or future-dated checks, and stopped/missing timer.
  A completed ingestion older than 15 minutes whose
  `finance_ingest_last_reported_timestamp_seconds` exceeds the published
  ingestion checkpoint also alerts, except while a bank run is in flight.
  Recorded export failures remain visible through that wait.

These fixed aggregate labels use the existing Alertmanager → Grafana OnCall →
phone route. No notifier or per-poll notification is added. Same-host monitoring
does not establish an off-host dead-man.

## Investigation and remaining acceptance

Inspect `systemctl status homelab-mcp-finances-snapshot.{timer,service}`, the
safe action/exit diagnostics in the journal, aggregate file/link permissions and private CLI/database
evidence. Pausing this timer does not pause ingestion or the nightly export.
Never delete state/checkpoints or issue a bank POST to repair a snapshot.

The unconditional **05:30 America/New_York** export and its timer are unchanged.
Its source reads (and manual unconditional exports) are **not leased against an
overlapping bank pull**. They share the database writer lock, but that does not
make live source reads a bank snapshot. A shell `flock` around the entire nightly
CLI would hold the bank lock while waiting for PostgreSQL; that unsafe shortcut
is deliberately absent. Coordinate manual/nightly consistency with the owner.

Run `finance-snapshot-contract` and `finance-snapshot-monitoring` flake checks
alongside the existing ingestion checks. They cover wiring, release refusal,
offline wrapper fixtures and PromQL. Remaining live gates: coordinator's full
baseline and source/package pairing, read-only state/lock access under the real
UID, node-exporter visibility, idempotent checkpoint publication (including a
partial), preserved failure through no-ops, and authorized end-to-end phone
delivery. No production units, banks or live database are touched by these tests.
