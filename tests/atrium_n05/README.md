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
