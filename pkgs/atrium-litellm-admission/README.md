# Isolated owned-key admission

This package is opt-in and has no imported production wiring. The separate
`package.nix` requires the actual Atrium resolver and profile packages as inputs;
there is no copied verifier/cache implementation. The unimported fixture module
is `tests/atrium_n05/module.nix`.

`ATRIUM_ADMISSION_SETTINGS` names an OS-protected runtime JSON document. Configure
`schema_version:1`, `isolated:true`, installation/native issuer, a private
`runtime_directory`, current N02 `policy_path`/publisher UID, and a list of
producer IDs/kinds/paths/publisher UIDs. Producer kinds are `resolver` (R06's rich
`admission-associations.json`) and `controller-service` (N04's separate
`service-associations.json`). The signing issuer, feed URL and JWKS URL are
configured independently. Poll interval is at most 20 seconds; the combined
parallel feed/JWKS fetch has one timeout of at most five seconds.

Initialize history explicitly using:

```sh
atrium-litellm-admission --settings /protected/runtime/settings.json initialize
```

Initialization is never an HTTP operation or a missing-state fallback. Register
`atrium_admission.hook.admission` through the supported LiteLLM callbacks setting.
The callback consumes the native authenticated hash/team and `request_route`,
which pinned native authentication derives from the ASGI path. Its normalization
preserves the exact ordinary inference paths, including distinct `/v1` prefixes.
An explicit route/callback-type pair identifies supported owned HTTP inference;
the body cannot select transport provenance, identity, ownership, or administrator
eligibility. In particular, raw passthrough's `proxy_server_request` field is
caller-controlled and is never trusted.

## Current boundaries

### Post-native-auth candidate: blocked, not selected

`atrium_admission.bootstrap.install` is an **unvalidated candidate**, exercised only
by the explicit `--post-auth-only` native fixture lane. Do not wire its worker
startup hook into a deployment yet. Ordinary fixture lanes retain pre-call-only
placement and its documented token-count gap.

The candidate uses pinned LiteLLM's `LITELLM_WORKER_STARTUP_HOOKS` seam and
FastAPI's dependency override registry. It awaits the original HTTP/WebSocket
authentication functions, retaining their security dependencies and resolved
signature annotations, then returns the same native identity on success. There
is no recursive `Depends(original)` override, replacement verifier, or native
route-check patch. Native reservation release is reused when the additional
gate rejects before dispatch.

The Anthropic router is lazy in 1.99.1. Bootstrap uses the same native loader as
its middleware and `/lazy/warm` before inspecting the actual token-count
dependency. It does not rewrite that handler or disable legacy counting.

Two bounded native attempts did not reach the permit/deny matrix. In the second,
both workers installed the wrappers, but native master-key `/v1/models` requests
returned 503. Pinned `user_api_key_auth.py:1799–1827` deliberately substitutes
`LITELLM_PROXY_MASTER_KEY_ALIAS` for the master key **and its hash** in the returned
identity. That alias is not the digest required by the current protected-history
lookup; the candidate therefore refuses it instead of assuming it is legacy.

Follow-up must bind the authenticated native control identity to a verifiable
protected identity/association without a native-role-only or client-label
exemption, then execute the real legacy/count/normal/cache/clock twins. A scoped
native admin-owned key must not inherit a controller exemption. No such exemption
or C8 amendment is implemented here. Direct manual auth calls and other native
auth dependencies also remain outside the dependency-wrapper coverage claim.

If this candidate is completed, integration would require
`LITELLM_WORKER_STARTUP_HOOKS=atrium_admission.bootstrap:install` alongside the
existing callback and protected settings. This is a future wiring requirement,
not an instruction to activate the currently blocked candidate.

### Existing pre-call engine

Producer high-water marks and complete owned-identity history survive workers
and restart in a private, locked, atomically replaced state file. Omission never
erases ownership; conflicting/rebound/rolled-back inputs cannot restore access.
The rich R06 snapshot is change-driven and has no invented age expiry. N04's
service snapshot retains its actual signed-age-independent 300-second publication
deadline. Controller provenance cannot confer human/admin status.

At each request, the current protected input universe must be verifiable.
Non-owned means absent from every verified complete producer and all historical
owned IDs, not a missing `cc.*` label. If a producer is missing/corrupt/stale,
unknown ownership is refused rather than assumed legacy. This intentionally
requires fresh ownership verification; it does not promise legacy availability
when that verification is unavailable. A deny-feed outage alone does not affect
verified non-owned credentials.

Ownership is resolved before owned model/context requirements. Verified non-owned
callbacks retain native behavior even without a model, common-processor transport
fields, or a supported owned callback type. Unsupported owned contexts are refused
before output or inference whenever this callback is invoked.

Raw `/anthropic/*` passthrough remains legacy-only. Its native provider-global
credential/destination selection is not N04's per-alias/domain routing. An owned
credential remains refused there even if native route permissions drift wider
than its protected association. This does not disable the native legacy endpoint
or promise context isolation.

Owned admission requires the allowed lifecycle, unexpired protected credential,
current N02 principal/template/instance/authority/device bindings, exact target,
native team, model, route, lifetime and budget ceiling. Only eligible human
administrator state can enter the C1 freshness exception.

Current instance/template ACL membership and the principal's generated
per-domain template/model allowlist are checked on every request. Historical
issuance does not preserve access after a current N02 ceiling is removed.

The clock high-water advances at the start and completion of feed attempts,
including failed fetches or parsing, and before request admission. Native
1.99.1 also awaits `async_post_call_failure_hook` on authentication rejection;
the adapter records time there without treating the failed identity as
authorized or replacing the native error. A failed clock publication keeps
the observation in memory for recovery and emits a bounded local error.
Unchanged observations do not rewrite the state file.

The actual shared `DenyCache`, `PublicKeys`, `AuthorizationContext` and
`DurableAlertLog` implement feed verification/admission. Cached signed public
policy and its trusted public keys persist across workers/restart. Invalid
updates retain the original verified snapshot and age. No token skew is added
to freshness. Real durable alert failure never permits an admin exception.

Known denies never become permits through missing producers, cold cache, stale
cache, or service/native-host roles. Runtime state, signing/control data, and raw
keys are not Nix-store/package inputs. This package stores no raw native key or
private signing material.

**Native coverage is not yet complete.** The bounded context matrix exercises
normal protocols, raw legacy compatibility, and disabled native routes separately.
It found that `/v1/messages/count_tokens` admits an owned key without invoking
this callback and attempts a provider request. Native `allowed_routes` entries
match path prefixes, so `/v1/messages` also admits this subroute at native auth.
The handler calls `internal_token_counter` directly. This requires an additional
native authenticated admission boundary; changing this callback cannot protect a
handler that never invokes it. See `tests/atrium_n05/README.md`. Do not promote
N05 or globally disable legacy endpoints to conceal this gap.
