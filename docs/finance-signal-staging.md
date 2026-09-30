# Finance Signal: configuration staging only

`hosts/forge/services/finance-signal.nix` defaults both gates **off**. Forge now
explicitly selects both declaration gates for **manual acceptance only**.
Declaring them starts no receiver or sender, opens no WebSocket, sends no
message, and never opens/migrates the existing production
`finances-context.db` (the existing nine context rows must remain untouched).
No production report/capture unit, timer, or boot target is installed here.

The paired MCP pin is `0.33.1`; the root-only transport secret was provisioned
from the exact existing registration, group IDs and verified human ACIs.
Live acceptance and any eventual cutover remain separate gates. An old pin
is rejected when either gate is enabled; no global pin acceptance is relaxed.
Hermes's sender, capture writer, credentials and history remain unchanged.
The existing **08:00 daily / Friday 16:00 America/New_York** report slots remain
the intended cadence, but are not activated by this module.

The receiver's IP sandbox must allow both loopback and the Signal service's
configured isolated Podman subnet. Published loopback traffic is DNATed before
the cgroup filter; a loopback-only allowance timed out in the real staging test.
The client still uses the loopback URL, and the host's existing UID firewall
remains in force. Do not replace the configured endpoint with a container IP.

## Entrypoint boundaries

| Executable | Contract |
|---|---|
| `homelab-finances-report` | Prepare-only `finances_reports.__main__`; used by the native preparation unit |
| `homelab-finances-signal` | Listener and read-only listener status |
| `homelab-finances-signal-report` | Durable jobs/status; exposed only through an explicit manual Ops preview unit here |

Do not replace the prepare-only entrypoint with the durable-job CLI. Its
`run --kind daily|weekly --native-config PATH --ops-preview --database TEST_DB`
interface is used by the manual `finance-signal-report-preview@` unit below.
Installing that unit neither starts it nor authorizes a send. Family delivery
is never activated by this staging module.

## Manual Ops delivery acceptance

With explicit consent, `systemctl start finance-signal-report-preview@weekly`
prepares and queues one Ops preview, including complete human-readable details
as a bounded plain-text attachment. Its wrapper forces `--ops-preview`, the
isolated staging database and `SIGNAL_REPORTS_ENABLED=false`; callers cannot
redirect it to Family. It passes only the transport coordinates plus the
already-projected native-reader paths. Accepted replays return the old receipt;
unknown/reserved sends are not automatically repeated.

Only one receive owner is allowed during capture acceptance. Pause the old
Hermes receiver with explicit operator approval, start the Ops staging receiver,
test notes and a reply to the known accepted weekly preview, then stop staging
and restore the previous receiver unless cutover is separately approved.
Document the interruption: messages arriving while disconnected may be lost;
without the durable `noted` acknowledgment the sender must resend. Do not claim
that this staging test changes production capture ownership.

## Explicit declaration gates

Only after reviewing the paired package and prerequisites may the parent enable:

```nix
services.financeSignalStaging.reportReader.enable = true;
services.financeSignalStaging.capture.enable = true;
```

These independently expose **manual-only** units, not running services. The
capture gate also declares the transport SOPS file; its encrypted value must
already have been provisioned by the parent before opening that gate.
There are no `WantedBy`/`RequiredBy` links, timers, activation scripts, or
tmpfiles bootstrap rules. Do not use `systemctl enable` or `enable --now`.
StateDirectory initialization occurs only when a manually requested consumer
starts, on the existing mounted/backed-up MCP dataset.

## Native reader and current runtime inputs

`finance-report-reader-config.service` is a mechanical root oneshot with **no
network**. It consumes the effective MCP unit's entire `environment` and ordered
`EnvironmentFile` list as **input only**, so normal systemd overrides and future
token/amount rotations remain authoritative. It does not import application
Settings or contact any backend. Only these fields are projected:

| Effective input | Native output |
|---|---|
| `HOMELAB_MCP_FINANCES_SIDECAR_BASE_URL` | `sidecar_base_url` (loopback HTTP origin) |
| `HOMELAB_MCP_FINANCES_SIDECAR_TOKEN` | `sidecar-token` file |
| `HOMELAB_MCP_FINANCES_REPO_URL` | `docs_remote` (credential-free HTTPS) |
| `HOMELAB_MCP_FINANCES_REPO_TOKEN` | `docs-token` file |
| `HOMELAB_MCP_FINANCES_FLOOR` | `floor` |
| `HOMELAB_MCP_FINANCES_AMAZON_BASELINE` | `amazon_baseline` |
| `HOMELAB_MCP_FINANCES_BUFFER_FLOOR` | `buffer_floor` |

Amounts are required finite, nonnegative, cent-precise current runtime inputs;
there are **no monetary defaults or copied planning figures**. Changed canonical
repo/context/ingestion paths or a finance-config override fail closed instead of
silently reading another policy. Missing/invalid inputs produce fixed safe error
names, never values, tracebacks, or environment dumps. An invalid refresh removes
the old `reader.json`; native preparation depends on successful fresh projection.

The owned `/run/finance-report-reader` directory is MCP-owned `0700`; its token
and peer-DSN files are `0400`, `reader.json` is `0600`. Its exact `NativeConfig`
also names the packaged finance policy (`finance_config_file: null`),
`household_finance`, canonical read-only ingestion state, `refs/heads/main`,
and the isolated persistent cache:

```text
/var/lib/homelab-mcp/finance-reports/docs.git
```

This is **not** `/var/lib/homelab-mcp/finances`, the canonical append-writer
checkout. That checkout, the context database, debt memo, OAuth stores and other
`/var/lib` state are hidden in the native preparer's mount namespace. Only its
own report directory is writable; canonical ingestion is bound read-only.

PostgreSQL follows the existing Money peer-reader pattern: OS `homelab-mcp`
maps to role `finance-report-reader`, database `homelab_finance`, with CONNECT,
schema USAGE, and SELECT on **`money_overview` and `export_runs` only**. It has
no password, writer credential, generic `readonly` membership, wildcard table
grant or default privilege. The existing exporter/schema/table provisioning
must already be operational. Existing roles and grants are not replaced.

**Trust boundary, not a new security principal:** these consumers reuse the
current MCP UID, the current shared sidecar token, and the existing docs PAT
(which also supports canonical appends). Do not call those credentials scoped
read-only, or claim UID isolation from MCP. The native producer restricts its
own operations to GET/fetch/SELECT. Projecting credentials does not revoke or
modify the original source credentials.

### Manual preparation (only after enabling the reader gate)

Run one preparation at a time:

```console
sudo systemctl start finance-report-prepare@daily.service
# Or, separately:
sudo systemctl start finance-report-prepare@weekly.service
```

The wrapper invokes `homelab-finances-report --kind daily|weekly --native-config
/run/finance-report-reader/reader.json` in a fresh process, with no MCP
environment files. Complete stdout (including a failed-gate artifact) goes only
to a unique `0600` JSON file under the `0700` directory
`/var/lib/homelab-mcp/finance-reports/artifacts/`. Stderr is not forwarded from
the producer, and neither stream is journaled as financial content. Inspect
artifacts only in an authorized private session; do not paste them into logs.
Exit 0 means prepared/quiet, **not delivered or all-green**; exit 2 means failed.
Input errors that produce no complete artifact, malformed output, and conflicting
status/exit codes publish no `.json` and return a fixed safe wrapper error name.
Nothing here queues or sends these artifacts.

## Ops-only capture: consent required before a start

The parent must provision the encrypted value for
**`homelab-mcp/finance-signal-env`** before enabling the capture gate. The gated
Nix declaration makes it root-owned `0400`. It contains **only**:

```text
HOMELAB_MCP_SIGNAL_NUMBER
HOMELAB_MCP_SIGNAL_GROUP_ID
HOMELAB_MCP_SIGNAL_OPS_GROUP_ID
HOMELAB_MCP_SIGNAL_BOT_UUID
HOMELAB_MCP_SIGNAL_CAPTURE_SENDERS
```

Use the exact existing REST family/Ops group IDs, canonical bot ACI, and a
comma-separated explicit list of allowed sender ACIs. No names, phone-number
inference or nearest-match ACLs. `BOT_UUID` and `CAPTURE_SENDERS` are the source
CLI's exact keys. No bank, Actual, OAuth, docs, model or writer credentials go
in this file. This change does not provision or inspect its encrypted contents.

The wrapper drops all inherited environment except those five fields and fixes:

| Key | Value |
|---|---|
| `HOMELAB_MCP_SIGNAL_BASE_URL` | `http://127.0.0.1:<modules.services.signal-api.port>` |
| `HOMELAB_MCP_SIGNAL_CAPTURE_ENABLED` | `true` |
| `HOMELAB_MCP_SIGNAL_CAPTURE_MODE` | `test` |
| `HOMELAB_MCP_SIGNAL_CAPTURE_TIMEZONE` | `America/New_York` |
| `HOMELAB_MCP_SIGNAL_CAPTURE_DB_PATH` | `/var/lib/homelab-mcp/finance-signal-staging/context.db` |
| `HOMELAB_MCP_FINANCES_CONTEXT_DB_PATH` | `/var/lib/homelab-mcp/finances-context.db` |
| `HOMELAB_MCP_SIGNAL_CAPTURE_TEST_GROUP_ID` | Exactly the supplied `OPS_GROUP_ID` |

It then executes **`homelab-finances-signal listen`**. Source validation rejects
invalid/missing identities, a bot in the sender allowlist, family/test group
confusion, and adoption of an existing unmarked context store. No retention
environment key is invented here: retention/delivery policy remains in the
paired source contract and parent work.

`finance-signal-capture-staging.service` reuses the existing permitted MCP UID
and restricts TCP to loopback. Its only writable persistent directory is
`finance-signal-staging`; other `/var/lib` state, all SOPS/credential files and
native reader projection are hidden behind private read-only `/var/lib` and
`/run` mounts (including alternate SOPS backing directories). The service manager
reads the dedicated transport EnvironmentFile before those mounts are applied.
It has `UMask=0077`, a 60-second graceful
stop, and at most three systemd starts per ten minutes with 30-second restart
delay. This does not make it a separate UID trust domain.

**Do not start it as configuration validation.** A real listener subscribes to
Signal receive and can acknowledge accepted Ops notes. The current transport
contract keeps Hermes as the receive owner; an additional staging receiver may
still affect receive delivery even though its writes are Ops/test-only. The
parent must obtain explicit user permission and coordinate receive ownership
before any WebSocket or send. This module does not stop/change Hermes.

After that separate authorization, the manual start/stop controls are:

```console
sudo systemctl start finance-signal-capture-staging.service
sudo systemctl stop finance-signal-capture-staging.service
```

For local, credential-free, read-only JSON status:

```console
sudo systemctl start finance-signal-staging-status.service
sudo journalctl -u finance-signal-staging-status.service -n 1 -o cat
```

The status command is `homelab-finances-signal status --database
/var/lib/homelab-mcp/finance-signal-staging/context.db`. It has no environment
file, writable state directory or network, and never initializes the database.
Read its JSON `ok`/state/counters, not merely systemd's oneshot result. A missing
store is expected before the first separately authorized listener start.
CLI exit 1 (attention) and 2 (unavailable/config error) remain failures; they are
not remapped to successful oneshot execution.
No service here prunes or migrates production context, credentials or history.

## Deferred production permission prerequisite

The parent reports that the existing production `finances-context.db` is `0644`
inside the private `0700` MCP directory. The new durable report job requires
`0600`. **Leave the production file's mode unchanged during staging.** At a
separately authorized production cutover, the parent must tighten only that
file's permissions while preserving its rows, schema and history; do not apply
a recursive permission change to the MCP directory.

The isolated staging database is created under `UMask=0077` and is already
`0600`. No production chmod, migration or repair is installed here.

## Offline validation

```console
bash tests/finance-signal/run.sh
```

Flake checks `finance-signal-staging-contract` and `finance-signal-staging-runtime`
cover enabled/disabled/old-release/UID gates, conditional SOPS declaration, exact peer grants,
mount and path boundaries, effective input inheritance, credential exclusion,
current runtime amount/token rotation, failed inputs, private artifacts, and
an unchanged synthetic nine-row context store, including its existing `0644`
file mode within a `0700` directory. Runtime tests use only synthetic
local files under the working directory and remove them afterward. The runtime
check includes Python lint/format and shell lint for the offline runner.
These checks are **not** a Forge deployment, live filesystem/ACL acceptance,
Signal delivery proof, or a measurement of the production database.
