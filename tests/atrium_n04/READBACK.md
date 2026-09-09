# ATR-N04 native credential readback diagnostic

Test-only: no change to the accepted controller guard, credential endpoints,
native authentication, cache, polling, production configuration or provider
behavior. No inference/provider process is created or called.

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
