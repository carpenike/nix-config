# N03 model deployment compatibility

This remains a default-off, isolated host definition, not a newly executed
native gate or production deployment. App candidate
`df1fa179059b45b3d435e92e5f08fcf2720d821c` and deployment candidate
`e5c1e5c619900413d7410219af4d00ce5b1d19b5` are normal-merged into the held
integration branches. MCP338cbbdb, Whiskey273cf414 and nixpkgs pins are unchanged.

## Repository boundary

The retained [`tests/atrium_n03`](../../tests/atrium_n03) Nix files own host
values, package/version selection, Caddy, units, users/groups, secret-path
references, publication directories, namespaces and deployment assertions.
`application.nix` checks selected package/module availability; it does not
qualify product source or acceptance evidence.

Controller/admission packages and the generic admission module come directly
from the pinned app exports. Gateway settings retain gateway ownership;
policy/CA keep their root provenance. Metadata and service-token groups remain
separate. Private custody, live publication paths, direct-backend separation and
default-off activation are unchanged.

All reusable Python/MJS N03 helpers, probes, synthetic providers, PKI/client
code, artifact builders, paired behavior cases and their tests now belong to
app `harness/n03_fixture`. The app driver receives this deployment configuration
explicitly and loads its own committed helper bytes. Native M*/W* code remains
in its own repository.

The app preflight—not a bare Nix readiness flag—requires the exact app-only
161-case catalog, complete current-source/runtime/fixture maps, committed final
UID/model anchors, immutable artifacts and real materialized module origins
before resource creation. Both product/controller identities must name the app.
Mixed Nix implementation identity or historical anchors are refused.

## Source and runtime limits

Nix unit/Caddy checks establish deployment composition only. The app's
source-only fixture tests consume explicit public host-generated JSON. Neither
is native acceptance. Existing65-second controller readback and90/100-second
caller budgets remain unchanged; end-to-end timing is still a runtime gate.

The parent app proof and its stated `/messages` limitations do not complete
this held N03 integration. A fresh authorized27-group run is required. This
compatibility tranche performs no native, Podman or lease operation.

## Historical evidence

The [earlier source integration](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/ATR-N03-N07-readback-integration-handoff.json),
[five failed/partial model attempts](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/ATR-N03-N07-model-native-blocked-handoff.json)
and [C8/JTI handoff](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/nix-config/atrium_n03/n03-c8-native-6fac02ef-handoff.json)
remain byte-identical in the app, with original path/commit/hash mappings in its
[N03 import manifest](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/nix-config-n03-imports.json).
The prior22/27 is not relabeled or transferred. Historical and new receipts are
app-owned; deployment documentation keeps immutable links, not duplicate bodies.
