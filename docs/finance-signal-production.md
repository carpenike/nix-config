# Production finance Signal wiring

The [production module](../hosts/forge/services/finance-signal-production.nix)
is **opt-in, default off**. Forge now selects it explicitly for the approved
cutover. The parent retirement block masks Hermes runtime/recovery units while
preserving history and backups; the [manual staging module](finance-signal-staging.md)
remains installed but its receiver is stopped.
No deployment, notice, live Signal call, permission repair or migration is
performed by the offline tests.

The parent supplied the qualification evidence: Ops report and attachment
received, two durable acknowledgments confirmed, chatter ignored, and the nine
production context rows unchanged. Hermes was restored after that bounded test,
then stopped by the separately approved production cutover. First scheduled
daily/weekly delivery remains a future acceptance check, not a fixture claim.

Live monitoring requires the paired **MCP 0.33.2** clock correction. A listener
can write a new heartbeat during imports/SQLite startup; sampling the clock
before that read falsely labels it future-dated. Production status now samples
time after reading the heartbeat, while fixed-clock tests still reject genuinely
stale/future evidence. Never fix this by suppressing the listener-health alert.

## Parent-owned cutover

After offline qualification and the checks below, the parent may select the
following. Send **one authorized Family notice only after the replacement
receiver is verified healthy**:

```nix
services.financeSignalProduction = {
  enable = true;
  reportsNotBefore = "2026-10-01T00:00:00-04:00";
};
```

Keep the existing reader projection enabled; staging capture may be disabled:

```nix
services.financeSignalStaging = {
  reportReader.enable = true;
  capture.enable = false;
};
```

Production declares the **same existing** transport-only SOPS secret, with the
identical file, owner/group and `0400` mode used by staging. No encrypted value
is changed. Thus `capture.enable=false` does not remove production's five-key
environment. If manual staging capture remains installed, its identical
declaration merges harmlessly; it must have no boot links or receive timers
and must **not be running** at cutover.

**Exact Hermes assertion:** `!(config.systemd.services.hermes-agent.enable or
true)`. The effective systemd unit must be explicitly disabled:

```nix
systemd.services.hermes-agent.enable = lib.mkForce false;
```

Keep `services.hermes-agent.enable=true` to preserve its backup factory. It is
not the ownership gate. Merely stopping the process, disabling a gateway
setting or removing its boot link does not satisfy the systemd assertion.

The parent-owned Hermes retirement block currently keys off
`services.financeSignalProduction.enable` and disables these units. Keep that
coordination in the parent-owned file; do not duplicate it in this module.

**The parent also retires:** the log relay, daily/weekly seed and dry-run units,
`hermes-agent-sentinel-heartbeat`, `hermes-agent-mcp-recover`, both recovery
timers and any old failure-clearing/recovery hooks. Keep the upstream module
declared to avoid breaking its backup/heartbeat references. Preserve data,
backups, the service user, shared credentials/transport/OAuth endpoints and
pinned test input for rollback. The new module does not edit them.

Before any production start:

1. Record the qualified source pin: MCP **0.33.1**, including native
   `finance_signal.cli`, `report_job` and `status`. Pins/secrets are parent-owned.
2. Coordinate the receive gap and stop staging and Hermes. Verify neither old
   receive process is running. The production unit also conflicts with both
   names, but that is a last safeguard, not the ownership transition procedure.
3. Take/verify the existing protected MCP dataset backup. In an isolated copy,
   rehearse the native additive initialization and compare all original context
   IDs, row counts, authorship, open/consumed state and source checksums.
   Do not replace production with staging state.
4. Tighten **only** the existing
   `/var/lib/homelab-mcp/finances-context.db` from the reported `0644` to `0600`
   as a separately authorized parent operation. Preserve contents, owner and
   filename. Its parent must remain MCP-owned `0700`; any existing journals
   and adjacent native lock files must be MCP-owned `0600`. Never recursively
   chmod the dataset or silently repair an unsafe file.
5. Send the single family notice using the parent's bounded, authorized
   `SignalStore` + `SignalClient` job with its one approved store key, outside
   the report period. Never start the overdue September 30 report as a notice.
   Explain deterministic reports, no AI
   conversation, explicit `note:` or a supported reply to a known weekly
   report, and **no `noted` acknowledgment means resend**. Advisor conversation
   remains in VS Code/Claude mobile. No notice sender is installed here.
6. Evaluate/build the **combined parent configuration**, review the first
   scheduled slots, then perform the authorized cutover. Leave this gate off
   until all prerequisites pass.

The proposed timestamp owes these first reports:

| Kind | First report at | Completion deadline |
|---|---|---|
| daily | `2026-10-01T08:00:00-04:00` | `2026-10-01T08:15:00-04:00` |
| weekly | `2026-10-02T16:00:00-04:00` | `2026-10-02T16:15:00-04:00` |

These are the native completion cutoffs. Missed-purpose monitoring adds the
unit's 45-second stop grace: **08:15:45 / Friday 16:15:45**, observed on the
next collector/scrape evaluation. That grace never extends permission to send.

`reportsNotBefore` is an **operational cutover instant**, not a reminder or
catch-up request. Move it to the actually approved cutover if necessary before
enabling. Do not advance it later to hide a missed report.

## Runtime and custody

| Unit | Contract |
|---|---|
| `finance-signal-capture.service` | Boot-started native `homelab-finances-signal listen`, production mode, canonical context DB |
| `finance-signal-report@daily.service` | Native scheduled daily purpose |
| `finance-signal-report@weekly.service` | Native scheduled weekly purpose |
| `finance-signal-metrics.service` | Two-minute local read-only status collector |

Report slots remain **08:00 daily / Friday 16:00 America/New_York**. Each timer
checks eligibility at minutes **00, 05 and 10** of that slot:

```text
daily:  OnCalendar=*-*-* 08:00,05,10:00 America/New_York
weekly: OnCalendar=Fri *-*-* 16:00,05,10:00 America/New_York
```

These are bounded attempts of **one report, not three messages**. The native
job returns the existing accepted/quiet outcome without another POST; only a
retryable failed preparation regenerates on a later attempt. A reserved,
unknown or failed send never causes a new POST. `Persistent=false`, no jitter
and `Restart=no` remain unchanged; there is no retry loop or late catch-up.

The wrapper uses the native slot function before starting; the source's
send/completion window stays strictly **900 seconds**. Each oneshot is bounded
to 270 seconds plus a 45-second stop and cannot overlap itself. A tick during
an active unit does not queue another run; the native adjacent report lease
also serializes both kinds and manual invocations.

The exact report invocation is:

```text
homelab-finances-signal-report run --kind daily|weekly --native-config /run/finance-report-reader/reader.json --send
```

Its clean explicit environment sets `HOMELAB_MCP_SIGNAL_REPORTS_ENABLED=true`
and the canonical context/report DB path. Native code commits artifact and Ops
detail intent before sending, sends Ops attachment first, and blocks Family
after failed/unknown Ops delivery. Failed/unknown/reserved POSTs are never
retried automatically. A quiet daily purpose still needs its Ops details.
REST acceptance is **not device delivery**.

All three consumers use **only**
`/run/secrets/homelab-mcp/finance-signal-env` as their EnvironmentFile:
`HOMELAB_MCP_SIGNAL_{NUMBER,GROUP_ID,OPS_GROUP_ID,BOT_UUID,CAPTURE_SENDERS}`.
The launcher allowlists those five keys and fixes the mode/path gates.
No `.env`, MCP environment, bank, OAuth or model credential is loaded by these
consumers. The existing root `finance-report-reader-config` remains the sole
projection of effective MCP source inputs into private native reader files.
The report process binds those files and PostgreSQL socket read-only, uses the
existing SELECT-only `finance-report-reader` role, and retains the separate
private `/var/lib/homelab-mcp/finance-reports/docs.git` cache.

Capture gets neither native reader files nor bank/ingestion paths. Its only
network allowance is loopback **plus the configured Signal localAccess subnet**,
because loopback publication is DNATed before filtering. The endpoint remains
the existing loopback URL; the host's MCP-UID guard remains authoritative.
There are no image/transport changes.

**This is the existing MCP UID trust domain.** Canonical SQLite journals and
`.signal-listener.lock` / `.signal-report.lock` require writes in the MCP
directory. Known unrelated OAuth, bank-state, append-checkout and staging paths
are hidden; other host state and secret backing directories are masked.
These mount restrictions do not turn the shared UID, sidecar token or docs PAT
into a new isolated/read-only credential principal. No canonical filename,
database, source schema or backup location is changed. Both writers use
`UMask=0077`; startup rejects unsafe/missing storage instead of creating a DB.
Capture restarts on failure after 30 seconds, at most three starts per ten
minutes, and has 60 seconds to stop.

## Monitoring and recovery

The collector calls the paired **read-only** listener `status.read_status` and
`report_job.read_report_status`. It resolves current Family **and Ops**
fingerprints from transport coordinates, not stored historical destinations.
It never subscribes, sends, migrates, acknowledges or repairs anything. It has
no network, writable context directory, native reader credentials or public
MCP/OAuth dependency.

Ten fixed aggregate gauge families are published atomically to
`/run/finance-signal-metrics/finance_signal.prom`:

- `finance_signal_check_timestamp_seconds`
- `finance_signal_path_healthy`
- `finance_signal_listener_status_available`
- `finance_signal_listener_healthy`
- `finance_signal_ack_attention`
- `finance_signal_report_status_available{kind="daily|weekly"}`
- `finance_signal_report_fulfilled{kind="daily|weekly"}`
- `finance_signal_report_attention{kind="daily|weekly"}`
- `finance_signal_report_deadline_timestamp_seconds{kind="daily|weekly"}`
- `finance_signal_report_next_slot_timestamp_seconds{kind="daily|weekly"}`

The actual `kind` label has exactly two values, `daily` and `weekly`. No IDs,
phones, fingerprints, messages or context rows are exported. The next-slot
gauge is the machine-readable **next report at** field.

Before the first slot at/after cutover, the corresponding deadline is zero:
no report is owed and old/missing/failed report state cannot page. After a slot
becomes eligible, only native current-slot fulfillment counts. An old failure
or accepted receipt cannot satisfy a newer slot; an unfulfilled purpose is
HIGH after the 15-minute native deadline plus 45 seconds of stop grace.
A known retryable preparation failure stays visibly unfulfilled but does not
page between the three attempts. Its systemd failed state does not bypass that
grace; report failures are monitored by purpose/outcome, not an unconditional
failed-unit alarm. Unavailable evidence, non-retryable failures and failed,
unknown or reserved sends remain immediately actionable. Disconnected/stale
listeners and failed/unknown/overdue ACKs are HIGH independently.

Path health uses filesystem checks independently of native status, and the
collector has no dependency on the listener or mounted dataset being healthy.
Missing/stale collector evidence and failed capture/collector units have
independent HIGH rules.
The existing Alertmanager -> OnCall path is reused, with no new notifier.
This same-host collector is not an off-host dead-man or a new phone-delivery
acceptance test.

The private setgid metrics directory is `2750 homelab-mcp:node-exporter`;
only its aggregate `0640` file is linked into the existing textfile directory.
MCP gains no write access to another collector's directory, and node-exporter
gains no context access.

For diagnosis, inspect native metadata-only status using the paired package's
`homelab-finances-signal status --database /var/lib/homelab-mcp/finances-context.db`
as the MCP UID. Report status requires current destination fingerprints; the
collector computes them locally without journaling coordinates. Do not paste
reader files, environment contents or artifacts into logs. Never clear an
outbox reservation or rerun an ambiguous send to make an alarm disappear.

If rollback is necessary, disable/stop production report timers and capture
before restoring **one** previous owner. Preserve canonical DB, native leases,
attempts, receipts and all context; do not overwrite them from the pre-cutover
backup. Reconcile the receive gap honestly; without `noted`, the sender must
resend. Keep local monitoring until its replacement is verified.

## Offline qualification

```console
bash tests/finance-signal-production/run.sh
```

Flake checks: `finance-signal-production-contract` and
`finance-signal-production-runtime`. They cover opt-in and ownership gates,
exact unit/timer/path/environment contracts, native status reads, bootstrap
and DST slot calculations, unknown/stale/missing/current and old outcomes,
atomic publication and permissions, PromQL thresholds, and the paired
source-owned report-job/listener tests with mock transports. Test state is
synthetic and temporary; tests never use production coordinates or files.

The macOS Nix sandbox strips setgid, so that environment explicitly skips the
real setgid-publication test. Run the same Python suite using the paired
package's Python environment outside that sandbox as well; all permission
assertions remain mandatory there and in Linux checks. Production permission
checks are never relaxed.

These checks do not claim Linux mount-namespace acceptance, a completed
production migration, first scheduled delivery, or newly verified phone paging.
