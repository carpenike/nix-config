# ATR-N05 native admission fixtures

There are two distinct lanes. `native_runner.py` is the historical placement
probe documented below. `actual_native.py` loads the real admission package,
shared R04 profiles/cache, R07 feed, and R06/N04 protected producer methods.
Neither lane activates production services.

The actual lane verifies every packaged module/resource in its four wheels
against the local admission/controller source and the declared immutable
Atrium revision before loading them. A missing, changed, additional, or
corrupt artifact cannot silently stand in for the code named in a receipt.
Wheel hashes are included in evidence. The existing four wheel artifacts
under `.artifacts/admission-wheels` must be rebuilt when those sources change.

```sh
python -m pytest -q tests/atrium_n05/test_probe.py tests/atrium_n05/test_artifacts.py
python tests/atrium_n05/actual_native.py \
  --harness /path/to/atrium-r06 --spec /path/to/current-owner-spec.md \
  --protocol-only completions \
  --evidence tests/atrium_n05/results/n05-completions-NEW.json
```

Omit `--protocol-only` to execute the broader implemented matrix. Blocked or
native-unavailable protocol rows produce a partial result and nonzero exit,
not a passing all-protocol run.
`full_n05` remains explicitly incomplete until every required native route,
fault, permission, and ownership case is accounted for.

The completion-stream fixture sends usage only when requested, in a final
usage chunk, rather than duplicating it in every content chunk. Unsolicited
usage previously triggered a native usage-serialization failure. The stream
observer also accepts null text in terminal control chunks and rejects late
SSE errors instead of treating partial text as success. These are fixture
corrections; native authentication, decoding, caching, and admission are not
patched.

The clean-source [completion receipt](results/n05-completions-94e35f94.json)
records all four `/completions` and `/v1/completions` streaming/non-streaming
rows passing at `94e35f94bef1f6ddb8ea2c3f64eedbcbd64b5a3a`. Both native
workers supply warm-cache positive output and deny the signed-listed key
before provider calls or cached/SSE output. This resolves the earlier
completion-stream fixture blocker, not the remaining full N05 gate.

For a bounded decoder-only diagnosis, `completion_library_probe.py` runs the
actual pinned library and a loopback provider in one network-disabled
container. It emits exception types and code-frame locations, not exception
bodies or credentials. Supply `--harness` and a new `--evidence` path. This
diagnostic is **not** native authentication or N05 admission evidence.

`actual_native.py --review-only` exercises current ACL removal and native
expiry followed by clock rollback, with paired permit/deny requests through
both real workers. Only clock inputs are controlled in that fixture: native
authentication, key lookup, expiry logic, the adapter, and its durable state
remain actual implementations. Background polling is deliberately stopped
for this lane so it cannot hide a missing authentication-failure observation.
Neither the host nor shared VM clock is changed. Normal protocol runs retain
the actual background poller.

The [clean review-fix receipt](results/n05-review-bc5eb776.json) binds both
two-worker regressions to `bc5eb776c16024b8976967e3d4fad13c893fe071`.
It does not promote the remaining unexecuted N05 routes or fault cases.

## Bounded request-context and route accounting

```sh
PYTHONDONTWRITEBYTECODE=1 .artifacts/n05-venv/bin/python \
  tests/atrium_n05/focused_native.py --harness /path/to/atrium-r06 \
  --evidence tests/atrium_n05/results/n05-focused-NEW.json
PYTHONDONTWRITEBYTECODE=1 .artifacts/n05-venv/bin/python \
  tests/atrium_n05/actual_native.py --harness /path/to/atrium-r06 \
  --spec /path/to/current-owner-spec.md --context-only \
  --evidence tests/atrium_n05/results/n05-context-NEW.json
```

`focused_native.py` reuses the already installed pytest dependencies and verified
product/admission wheels in a network-disabled pinned container. All signing
fixtures and pytest runtime files live under its private `/run` tmpfs, not host
temporary directories or the repository. It runs the focused engine, callback,
provider, and wheel-provenance tests; this is not a substitute for native HTTP
permit/deny evidence.

The context lane keeps the actual auth/router/cache/admission implementations.
It distinguishes:

* **Normal inference:** chat, completions, embeddings, responses, and
  `/v1/messages`, with streaming where applicable and both workers' warm native
  local caches. Native auth's `request_route` is authoritative; body transport,
  route, ownership, and administrator labels cannot select admission.
* **Native absence:** `/messages` has no native advertised handler. Its refusal
  is recorded separately, not treated as an enabled positive. The pinned product
  `1d620cd3` shared `INFERENCE_ROUTES` contains the ten ordinary paths with/without
  `/v1`; it does **not** include `/anthropic/v1/messages`. These are implementation
  route-enumeration facts, not mandates from the locked spec.
* **Raw passthrough:** default owned native route limits refuse
  `/anthropic/v1/messages`. A test-only native `/key/update` then widens route
  permission while verifying protected producers remain byte-identical. Actual
  admission still refuses owned child/admin/service keys, with and without forged
  common-processor labels. Verified non-owned legacy callers retain native
  passthrough, including streaming and GET `/anthropic/v1/models` without a model
  or common transport fields. Missing ownership input must still fail closed.
* **Disabled APIs:** explicit requests cover images, audio, rerank, moderation,
  alternate deployment/engine/Gemini paths, realtime handshakes/session APIs, and
  response compaction. Native 401 and 403 refusals are distinguished in evidence;
  neither upstream failure nor an unavailable route is an inference permit.

Only this legacy-compatibility lane supplies an isolated synthetic global
Anthropic provider credential/base. Its success is **not** owned per-alias/domain
routing evidence. Native passthrough selects the first applicable
`use_in_pass_through` provider/region credential, or a global environment credential;
`/anthropic/*` uses the global base URL. No global credential substitutes for N04's
owned alias expectations. Adopting that path would require an explicit
authenticated per-alias/domain implementation and its paired routing tests.

### Remaining native boundary: token counting

The initial native context receipt, [n05-context-initial.json](results/n05-context-initial.json),
records an owned request to `/v1/messages/count_tokens` returning **200**, with
**one provider request and zero admission callbacks**. This is not a positive
coverage result. Pinned source explains it:

* `proxy/auth/route_checks.py:549–572` accepts descendant paths of an
  `allowed_routes` entry, including descendants of `/v1/messages`.
* `proxy/anthropic_endpoints/endpoints.py:227–310` authenticates natively, then
  calls `internal_token_counter(..., call_endpoint=True)` directly, without the
  common processor or `async_pre_call_hook`.

The context lane also checks this path after a real signed deny and failed native
revocation, pairing it with the same key's ordinary chat permit/deny. The affected
gate must remain blocked until authenticated admission covers that handler
without removing native legacy behavior. No locked-contract impossibility or C8
amendment follows from this implementation gap.

Other remaining gates include exhaustive advertised-route accounting, legacy
WebSocket positive behavior, shared/Redis cache paths, and broader worker/restart
and R04/R07 fault coverage. `legacy_context_gate` reports the bounded compatibility
fix separately from `request_context_gate`, `full_protocol_gate`, and `full_n05`;
none of those broader gates is promoted by a legacy passthrough success.

### Clean-source context receipt

Both receipts below ran with a clean working tree at source commit
`27c312573d32d3082327484c09d424a85e6a6422`, against pinned **1.99.1** and
owner spec SHA-256 `7948bf3e47a1098db984bfd23e0b660d8fd0b818c317611e4de30d824536939e`:

* [Focused receipt](results/n05-context-focused-27c31257.json): **75 passed**,
  no skipped tests; signing fixtures confined to the native `/run` tmpfs.
* [Native receipt](results/n05-context-27c31257.json): **24 context/legacy cases**
  and **34 additional route forms** pass (the latter refused for child, native
  admin-owner, and service templates). All normal **16 available protocol/mode
  rows** pass permit/deny with both actual worker PIDs **222/223**, including warm
  native local caches. `/messages` remains separately unavailable in both modes.

Raw legacy streaming/non-streaming calls, forged-body variants, and the model-less
GET all pass on both workers. Owned raw requests remain 403 with no upstream or
SSE output even after native permission drift. A missing producer produces 503
for the otherwise working legacy GET; restoring the protected producer restores
native access. The initial legacy forged-body row's single-worker sampling limit
was corrected with a 100 ms gap between fresh connections, not by changing native
worker scheduling or admission.

**Two token-count checks remain blocked.** With real native revocation failure
pending, the same child key's chat request goes from 200 to admission-enforced
403, but `/v1/messages/count_tokens` still returns **200**, invokes admission
**zero times**, and attempts **POST `/v1/responses/input_tokens`** at the fixture
provider. The provider records the attempted request; this is not an authorized
provider-output claim. Native source hashes for the auth, normalization, raw
passthrough, and token-count boundaries are embedded in the receipt. The public
source hashes are rendered as explicit algorithm/digest objects to distinguish
them from credentials; the original captured receipt hash is retained, and no
observations or checksum values were changed.

Thus `legacy_context_gate=passed`, while `request_context_gate`,
`full_protocol_gate`, and `full_n05` remain incomplete; the native command exits
nonzero/partial. This tranche supplies the T26 request-context subset and
ordinary-endpoint T15/T25 pairs, **not complete T15/T20/T24/T25/T26/T30 closure**.
Follow-up must cover token-count dispatch after native authentication and before
its upstream call, preserving verified non-owned native behavior. No amendment
is proposed; the affected native boundary is handed back without further retries.

Both runs removed every exact owned container ID; the native run also removed
`atrium-harness-n05-adapter-454687f331082757-net`. Both retained the pre-existing
`ambit-db` container `a914bf6c7045` running unchanged. Cleanup receipts report zero
remaining owned resources; no production host configuration, other worktree,
shared VM/image, or household service was modified.

## Post-native-auth follow-up: bounded candidate stopped

The subsequent candidate is deliberately restricted to:

```sh
PYTHONDONTWRITEBYTECODE=1 .artifacts/n05-venv/bin/python \
  tests/atrium_n05/actual_native.py --harness /path/to/atrium-r06 \
  --spec /path/to/current-owner-spec.md --post-auth-only \
  --evidence tests/atrium_n05/results/n05-post-auth-NEW.json
```

**The initial candidate was blocked; the historical diagnostics below are not
passing native gate cases.** Subsequent control-identity work described below
reaches and exercises the post-auth boundary. Other lanes do not yet select its
startup override. The token-count provider double
now supports the standard authenticated `/v1/responses/input_tokens` response, so
a future legacy permit can require native provider output rather than the previous
local-tokenizer fallback.

The fixture prepares its actual R04/R07 and R06/N04 inputs in private `/run` tmpfs
before the gateway starts, since post-auth admission also encounters control
requests. Startup installation observations are separately authenticated. The
candidate warms the real lazy Anthropic router and wraps the original native HTTP
and WebSocket dependencies; it does not intercept manual auth-function calls.

| Diagnostic | Exact result |
| --- | --- |
| [First native attempt](results/n05-post-auth-initial.json) | Gateway readiness timed out; no inference cases ran. |
| [Actual-app graph check](results/n05-post-auth-focused-native-graph.json) | 85 focused cases passed; installation failed because `/v1/messages/count_tokens` was not yet registered by the native lazy loader. |
| [Corrected graph check](results/n05-post-auth-focused-lazy-graph.json) | 86 focused cases passed using the real native application graph. |
| [Second native attempt](results/n05-post-auth-second.json) | Workers **229/230** installed wrappers over **433 HTTP / 8 WebSocket dependency paths**. `/v1/models` then returned **503**; zero provider requests, no permit/deny cases executed. |

Pinned native source explains the concrete control-identity blocker:
`proxy/auth/user_api_key_auth.py:1799–1827` replaces the authenticated master key
and its hash with `LITELLM_PROXY_MASTER_KEY_ALIAS`. The candidate's digest-only
admission rejects that sentinel. A focused guardrail test reproduces this shape
and deliberately refuses to turn native `proxy_admin` status into an exemption.

The two-native-attempt limit was reached. No third native attempt, master-role
bypass, global endpoint disablement, or amendment was attempted. The next bounded
implementation must establish a trusted control-identity association while
preserving the original native identity, then execute the proposed token-count,
legacy, cache/worker, freshness and failed-auth clock tests. Until then, both the
candidate and the full N05 gate remain incomplete. These failure receipts record
dirty diagnostic sources and cannot substitute for clean-source native acceptance.

Both native attempts removed their exact container/network resources and retained
`ambit-db` (`a914bf6c7045`) running unchanged. Public source/graph diagnostics are
preserved under `.artifacts/n05-post-auth-pinned-source`,
`.artifacts/n05-post-auth-source-inspection.json`, and
`.artifacts/n05-native-graph-inspection.json`.

The [clean focused receipt](results/n05-post-auth-focused-0b34a052.json) binds
**87 passing focused tests** to clean source
`0b34a05245f6a83b8c55200d8feece996f605913`, including the actual native application
graph and the deliberately fail-closed master-alias regression. Its container
cleanup passed with `ambit-db` unchanged. This is **not** a clean native HTTP
receipt: token-count permit/deny, normal endpoint/cache/worker, and failed-auth
clock revalidation for the candidate remain unexecuted. No third native HTTP
attempt was made after the agreed limit. Nix/workflow wiring was not changed,
and the candidate startup environment setting was not activated at that revision.

### Subsequent native control-identity completion

The adapter now resolves the reserved, natively verified master marker to the
runtime master fingerprint **only inside protected ownership lookup**. It checks
native virtual-key provenance and does not mutate the native identity or publish
the master fingerprint in observer events. An admin role alone is not sufficient;
known-owned fingerprints and unavailable ownership still fail closed.

The explicit post-auth lane subsequently reaches all nine permit/deny groups,
including real legacy token counting and owned child/admin/service refusal after
signed denial and actual native-revocation failure. The service case uses a real
signed principal deny and an actual failed native delete, not a fabricated R06
broker association or an assertion that the R07 service-key queue is integrated.

Protocol coverage retains a real TCP connection to each observed native worker
and checks that subsequent cache, denial and recovery requests stay on that PID.
This avoids relying on shared-socket accept fairness to rediscover the second
worker for every request. All sixteen enabled protocol/mode rows pass on both
workers. The two `/messages` rows remain verified native refusals, not positive
coverage of a nonexistent route; the full N05 gate remains explicitly incomplete.

Final review and complete integration are still required before enabling the new
startup boundary outside this isolated lane. The historical blocked receipts above
are retained rather than rewritten as successful evidence.

`--post-auth-review-only` repeats the real ACL-removal and native-expiry/clock-
rollback regressions with the dependency boundary installed. Both workers remain
subject to the same current policy and durable clock after this additional gate;
no host or VM clock is changed.

Clean source `ea0341b270bd93c07eb45e9831f91a69d944ffe8` is bound by:

* [Post-auth HTTP and protocol receipt](results/n05-post-auth-ea0341b2.json):
  nine post-auth groups and sixteen enabled protocol/mode rows pass in both
  workers. The aggregate remains partial because `/messages` is absent.
* [Post-auth ACL/clock receipt](results/n05-post-auth-review-ea0341b2.json):
  both native regressions pass in both workers with zero denied provider effects.
* [Focused native-SDK receipt](results/n05-focused-ea0341b2.json):
  91 existing-runner cases pass on the pinned image.

All three runs verified exact component wheel bytes and cleaned their own
resources. These receipts do not claim unexecuted manual-auth, legacy WebSocket,
network, or cross-adapter gate coverage.

## Historical placement probe

This is an isolated, **unimported test probe**, not N05 implementation or
production wiring. It does not install the R04 deny feed, compute administrator
outage eligibility, reconcile ownership, or replace native authentication.
No amendment is proposed merely because a candidate fails.

## Pinned source and candidate

`inspect_source.py` reads actual source from the N01/N07 digest-pinned LiteLLM
image in a small network-disabled container, verifies package **1.99.1**, and
records file hashes. No current online documentation selects the hook.

The inspected source establishes this candidate chain:

* `proxy/proxy_server.py:10010–10035`: both chat routes depend on native
  `user_api_key_auth` and pass the resulting `UserAPIKeyAuth` to the processor.
* `proxy/auth/user_api_key_auth.py:1866–1880`: normal native bearer keys are hashed
  and resolved by the native identity store.
* `proxy/common_request_processing.py:2214–2229`: pre-call processing is awaited.
  Its `1863–1867` call awaits `ProxyLogging.pre_call_hook`.
* `proxy/utils.py:1721–1740`: the concrete `CustomLogger.async_pre_call_hook`
  override is awaited; its exceptions propagate.
* `proxy/common_request_processing.py:2252–2279`: the separate *moderation* task
  runs alongside inference **after** that boundary. It is not this candidate.
* `utils.py:1707–1722`: the library output-cache lookup/early return occurs in the
  downstream LLM invocation. Runtime cache/worker coverage still needs proof.

The probe registers a direct `CustomLogger` subclass through the supported
`litellm_settings.callbacks` configuration. It reads only the native
`user_api_key_dict.api_key` hash and native metadata; client labels cannot select
the fixture deny rule. An authenticated fixture observer toggles a deterministic
deny set and records native worker PID/hash/context. This is placement
instrumentation, **not a substitute authorization/feed adapter**.

## Reuse and isolation

The supervisor reads only the explicit immutable N07 commit
`5eb22c6e5e0e9308f9b177471775ac71d8ae5ed8` from the supplied Atrium repository.
It materializes public orchestration files under `.artifacts`, verifies their
hashes, and reuses `harness.litellm_native.run` and `Resources`. It never reads
current R06 broker/fix code or changes another worktree.

Only orchestration is extended: the same native CLI runs `--num_workers 2`;
native LiteLLM's own local output cache is enabled; a public custom-hook module
is supplied in a private container `/run` tmpfs; and the non-actuating provider
supports finite OpenAI SSE responses and authenticated counters/instrumentation.
Native auth, worker scheduling, router, and cache implementations are untouched.
Runtime keys remain memory/stdin/environment only. Container output logs are
disabled; recorded evidence contains no bearer or provider credential.

The first full attempt stopped at gateway startup before any coverage case.
The one-worker harness's `/proc/self/fd` config is unsuitable for the native
Uvicorn multi-process spawn path (`proxy/proxy_cli.py:1406–1411`). The probe now
uses a private `/run/atrium-n05/config.json` beside the callback module, readable
by actual spawned workers. It contains environment references, not runtime keys.
This is a bootstrap prerequisite correction, not a failed hook/cache candidate.

Every full-stack start refuses a shared VM already running a fixture other than
`ambit-db`. Exact `Resources` IDs/invocation labels control cleanup, and metadata
before/after checks preserve all pre-existing containers. No VM/image removal,
production networking, household write, or paid model call is involved.

## Probe and evidence

Use the existing harness dependency versions (`httpx 0.28.1`, `pydantic 2.13.5`,
`pytest 9.1.1`, read from the pinned resolver lock). Run from this worktree:

```sh
python -m pytest -q tests/atrium_n05/test_probe.py
python tests/atrium_n05/inspect_source.py --harness /path/to/atrium-r06
python tests/atrium_n05/native_runner.py \
  --harness /path/to/atrium-r06 --spec /path/to/current-owner-spec.md \
  --evidence tests/atrium_n05/results/n05-native-<revision>.json
```

For each of `/v1/chat/completions` and `/chat/completions`, in non-streaming and
streaming modes, the runner:

1. Rejects an invalid native key without a hook invocation or provider call.
2. Opens fresh TCP connections until **both actual worker PIDs** produce native
   warm-cache positive responses with zero provider requests.
3. Enables fixture denial without changing the cached request; both warm workers
   must return HTTP 403, zero provider requests, and no cached/SSE content.
4. Removes the fixture deny; both workers must return the retained cached output,
   preserving the positive twin without upstream calls.

The table in the committed native evidence distinguishes observed paths from
unexecuted APIs. A passing candidate here is **not the final production hook**:
other enabled inference protocols, shared/Redis caches, additional workers,
R04/C1 feed admission/outages, native-revocation failure integration, ownership
history, and independent management-route restrictions remain outside this pass.

## Observed result

The clean source revision `a8cefd788214a1d7bb07618ab4cbd05ae486e11a` passed
against actual pinned LiteLLM **1.99.1**. Full evidence is
[`results/n05-native-a8cefd78.json`](results/n05-native-a8cefd78.json).
Native worker PIDs **222 and 223** each supplied warm local-cache positives,
pre-output denials, and cache-preserving recovery for every row:

| Protocol | Mode | Actual worker/cache paths | Denied result | Status |
| --- | --- | --- | --- | --- |
| `/v1/chat/completions` | Non-streaming | Both workers; warmed native local output cache | HTTP 403; zero provider calls; no cached output | Proven |
| `/v1/chat/completions` | Streaming | Both workers; warmed native local output cache | HTTP 403 before SSE; zero provider calls/output | Proven |
| `/chat/completions` | Non-streaming | Both workers; warmed native local output cache | HTTP 403; zero provider calls; no cached output | Proven |
| `/chat/completions` | Streaming | Both workers; warmed native local output cache | HTTP 403 before SSE; zero provider calls/output | Proven |
| Native invalid-key authentication | Each row above | Native verifier, before placement hook | HTTP 401; zero hook calls and provider calls | Proven |
| `/v1/completions`, `/completions` | All modes | Advertised by actual OpenAPI; not requested | — | Unexecuted |
| `/v1/embeddings`, `/embeddings` | All modes | Advertised by actual OpenAPI; not requested | — | Unexecuted |
| `/v1/responses`, `/responses`, `/v1/messages` | All modes | Advertised by actual OpenAPI; not requested | — | Unexecuted |
| Images, audio, rerank, other advertised APIs | All modes | Not requested | — | Unexecuted |
| Shared/Redis caches, other worker counts/restarts | All protocols | Not configured in this bounded probe | — | Unexecuted |
| R04 feed/cache/outage/admin policy and ownership lookup | All protocols | Not implemented by the fixture deny set | — | Unimplemented |

The four rows made eight cold provider calls total (one per worker per row),
then observed 21 warm-cache positives. All **33 fixture-denied requests** returned
403 with zero provider calls, and every recovery used retained cache with zero
provider calls. Four invalid-native-key requests remained native 401 failures
and never reached the hook.

Conclusion: `CustomLogger.async_pre_call_hook` is a **proven pre-admission
candidate for these chat/local-cache/two-worker paths**, not a final selection
for all enabled endpoints. No alternative candidate was needed after this
successful placement proof. The initial startup-only failure remains recorded
separately, rather than being treated as failed hook coverage or impossibility.
Exact container/network cleanup passed; `ambit-db` remained running unchanged.
No production source/service, R06 fix, N04 implementation, VM, or image was changed.
