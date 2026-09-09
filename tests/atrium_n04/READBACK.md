# ATR-N04 native credential readback diagnostic

The observation mode is test-only: native credential endpoints, authentication,
cache, polling and provider behavior remain unchanged. The branch also contains
the bounded controller readback correction and its separate verification mode
below; exact metadata equality is still required. No production configuration
is changed, and no inference/provider process is created or called.

The driver uses the existing accepted N07 `Resources`, pinned LiteLLM/Postgres
images, database bootstrap and native readiness checks. Its worker-startup hook
wraps only ASGI response emission to attach actual PID, effective native reload
interval and Redis-presence observations. Requests, response bodies, endpoint
dispatch, native auth and caches remain unchanged. Worker-affine HTTPX
connections reuse the existing N05 keepalive settings.

One fresh database/gateway is used per one-worker and two-worker topology.
Both use empty initial models, native database storage, local response caching
and no Redis, as in the relevant N03 model setup. Native `proxy_admin` identity
`n03-controller-control` receives a distinct `default` control credential with
the actual N04 route set plus `/key/delete`, matching the N03 provisioner.
Master credentials are used only for native user/control-key bootstrap and
verification of that control key. All credential creation/readback observations
use the verified scoped management key. The controller's `Native.key` helper
intentionally refuses self-inspection, so bootstrap verification uses the
separate bootstrap identity rather than weakening that guard.

The native config is a private `0600` file inside the invocation tmpfs, as in
the N03 topology. Multiple spawned workers must be able to reopen its path;
the single-worker harness's process-local `/proc/self/fd` config is not used.

After readiness and worker discovery, exactly one synthetic `cc.*` credential
is created per topology. Immediate and three-second paced reads use the same
worker-affine connections. The budget is two observed native reload periods
plus three seconds (63 seconds on the pinned native default); no native clock
or interval changes are made. The real controller metadata builder and exact
`native_credential_not_applied` equality predicate are reused without bypass.

Only PID, HTTP status, row presence, field names/types, equality and canonical
hashes leave the private comparison. Native credentials and response bodies
remain in memory or the invocation-owned private tmpfs. Native source hashes,
version and reload defaults are checked against the pinned public revision.

After a source commit, clean tree and explicit coordinated lease:

```sh
PYTHONDONTWRITEBYTECODE=1 /path/to/existing/resolver/.venv/bin/python \
  tests/atrium_n04/readback_diagnostic.py \
  --harness /path/to/accepted/atrium \
  --spec /path/to/original/atrium-spec-v1.0.md \
  --evidence tests/atrium_n04/results/readback-NEW.json
```

The receipt records before/after container/network/volume/image inventories
for each topology and exact resource cleanup. Only the returned IDs and owned
network are removed. Cached images are not pruned; the lane requires its pinned
images to pre-exist. Preserve `ambit-db` and release only the invocation owner's
lease after independent absence/equality checks.

`lag_hypothesis_confirmed` requires immediate writer equality, an initially
missing other-worker row, no observed true metadata mismatch, and eventual
exact convergence. A mismatch/refusal or failure to converge is retained as a
different outcome, never relabeled as applied. This does not authorize a retry
policy change or establish complete N03/N07 gates.

## Confirmed native failure mode

Clean diagnostic source: `2c594588a97bfc9dca6ead27620a6e794de8a22e`.
The [complete receipt](results/readback-2c594588.json) confirms worker-local
read-after-write lag on the pinned native package with the scoped N03
management identity, local cache and default 30-second polling.

| Topology | Initial observation after the single credential POST | Convergence |
|---|---|---|
| One worker, PID 1 | Exact metadata match at 18 ms | Immediate |
| Two workers, writer PID 223 | Exact metadata match at 33 ms | Immediate on writer |
| Same two-worker run, reader PID 224 | HTTP 200 but credential row absent at 31 ms; actual equality guard rejects | Exact metadata match at 30,035 ms |

Both credential POSTs returned success. No present-but-different metadata was
observed, and no inference was requested. Metadata values and raw credentials
were not exported. This confirms a failure mechanism that produces the N04
guard's error; the original N03 failure receipt did not record a worker or row
presence and cannot retrospectively prove which worker handled that request.

The earlier [bootstrap identity failure](results/readback-11152856-first.json)
and [two-worker config failure](results/readback-04bc9faf.json) remain unchanged.
The first stopped before credential creation because `Native.key` correctly
refused self-inspection. The second retained a successful one-worker result
but no two-worker readback result. Neither is counted as the confirming run.

The [independent cleanup receipt](results/readback-cleanup-2c594588.json)
verifies all ten exact containers and five invocation networks from the three
attempts absent. Container, network, volume and image inventories match every
before/after baseline and the final independent read; `ambit-db` is unchanged.
The parent-owned fixture lease was released only after these checks.

The controller follow-up is a bounded, read-only convergence check after the
single successful credential mutation, preserving exact metadata equality and
fail-closed exhaustion. It must not repeat the mutating POST, accept missing
or different metadata as success, change native cache/poll behavior, or weaken
authentication. The observation-only diagnostic above predates that correction
and is not evidence that the corrected controller has executed.

### Initial native scheduler phase

The nominal 30-second interval is not a maximum initial convergence time.
The pinned native `scheduled_job_stagger.py` offsets each worker's interval
trigger by less than one period. The [scheduled-refresh observation](results/readback-schedule-7a13524d.json)
recorded a worker with 42.299 seconds remaining before its first refresh,
despite the unchanged 30-second setting. Another worker's row appeared after
its observed scheduled refresh, without a refresh error or metadata change.

The [35-second candidate failure](results/readback-convergence-bd3cc790.json)
is preserved: single-worker success and permanent-mismatch refusal worked, but
the pinned non-writer remained missing past that budget. The controller budget
is therefore 65 seconds for the default pinned schedule: one interval, up to
one additional startup phase, and five seconds of slack. Native scheduling and
cache settings are not changed, and exhaustion still refuses the operation.

## Bounded-controller verification mode

After reviewing the controller's convergence correction, the same source-bound
runner can add `--verify-convergence`. It still creates one native credential
per topology. The actual `Native.wait_for_credential` method reads through a
test-only transport adapter that keeps the request on the observed worker
connection; native HTTP responses, authentication, metadata and cache state
are not mocked or rewritten.

The two-worker permit must exercise an initially missing non-writer row and
wait for exact metadata convergence. A separate call intentionally expects
different metadata for the same existing credential and must exhaust the
bounded wait with `native_credential_not_applied`, without another POST.
Its observations are recorded separately so the deliberate expected-value
mismatch is not called native metadata corruption. This mode requires its
own clean source and native receipt; the earlier observation-only receipt
does not prove the corrected controller.

The [corrected client receipt](results/readback-convergence-b3f66bc1.json) at
source `b3f66bc1c4b428e6a4c25f706af1bc850fea7277` passed both topologies.
The actual client returned in 4 ms on one worker and 31.116 seconds on the
initially missing non-writer in the two-worker topology. Permanent wrong
metadata was refused after 65.002 and 65.005 seconds, respectively, with one
credential POST per topology and no inference.

The [handoff](results/readback-convergence-handoff.json) and
[all-attempt cleanup](results/readback-fix-cleanup-b3f66bc1.json) retain the
failed shorter-budget and observer-bootstrap attempts. All 24 exact containers
and 12 invocation networks are absent, and every captured container, network,
volume and image inventory matches the final independent check.

## Full-controller verification mode

The helper proof above does not cover `Controller.run`'s mandatory infrastructure
re-read: an initial exact writer response can be followed by a missing row on
another worker. The corrected caller preserves the first credential POST's
absolute 65-second deadline across all new credentials and that final check.
It requires one fresh snapshot with every new credential exact; previously
owned credentials still fail immediately on absence or metadata drift.

Use `--verify-controller --runtime PRIVATE_EXISTING_PARENT` instead of
`--verify-convergence` to run the actual
controller, `Desired` parser, private ownership ledger, protected association
reader and publication APIs. This mode derives disjoint, infrastructure-only
cases from the existing N02-generated fixture. No model templates are enabled,
so it does not issue inference/service keys or claim their rotation. The
generated input and all fixture/runtime sources are fingerprinted.
The runtime parent must pass the real protected-directory guard, outside
repositories and the Nix store, with no writable-by-others ancestor. `/tmp`
is not a suitable private-state root; the guard is not relaxed for tests.

Both one- and two-worker topologies execute a permit and an adverse twin.
Each case allows exactly one controller credential POST. All control traffic
uses the actual scoped management identity. A test-only HTTP transport keeps
initial readback on the writer, then routes the mandatory credential re-read
and its retries to the observed other worker. Native headers, request/response
bodies, authentication, cache and scheduler behavior remain unchanged. Other
infrastructure operations stay on the writer to isolate this credential race;
this is not a claim about all native management-cache paths.

The two-worker permit must observe writer-exact, post-create reader-missing,
then reader-exact, and verify both actual controller publications. The adverse
twin deletes only its own newly created native credential through the real
native endpoint immediately before the mandatory re-read. This explicit fault
uses the bootstrap identity, not expanded controller privileges. The caller
must refuse permanent absence at the original deadline and publish neither
bindings nor service associations. The elapsed observation allows one second
of scheduling/measurement tolerance, not an extra authorization allowance.
No POST is retried, native responses are not mocked, and no inference is called.

Per-case private temporary directories are removed even on failure; the normal
exact-container/network and before/after-inventory cleanup remains required.
A source-bound `--verify-controller` receipt, not the historical helper result,
is required before accepting the caller correction.
