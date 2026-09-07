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
The callback consumes the native authenticated hash/team and the native-rebuilt
request URL/method. It does not accept identity/ownership/administrator labels
from the request body.

## Current boundaries

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

**Native coverage is not yet complete.** The earlier committed placement probe
proved only the supported chat/local-cache/two-worker hook location. It is not
evidence of this adapter's full R04/R06/N04 integration or every native protocol.
