# ATR-N05 bounded request-hook coverage probe

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
