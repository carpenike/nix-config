# N03 model deployment compatibility

The N03 compatibility fixture remains default-off and isolated. Forge's
separate package installation is described below. The selected app input is immutable Atrium
`0700af39a7bf805c148eb362cecab0f8cef4eb21`; MCP338cbbdb and Whiskey273cf414
remain unchanged. This advances the application input to the accepted
current-state recovery work while retaining the owner's other flake updates.
Package/module selection is not a claim that Forge's live services now use
the isolated fixture or that a different live gateway version is qualified.

The app's [completed model/Whiskey recovery handoff](https://github.com/carpenike/atrium/blob/a17853656eb8023f0fcbecdcc6c63d645e033fec/harness/evidence/ATR-N07-model-whiskey-current-recovery-handoff.json)
records five actual native recovery groups at driver `3c55226`, with its
explicit core-runtime/deployment inputs and preserved history. The separate
[app-owned integrated cohort](https://github.com/carpenike/atrium/blob/0ff841bc633978a9691b0b9fbda02de155c91bf7/harness/evidence/ATR-N03-N07-integrated-handoff.json)
passes27 groups on app driver `11b7008` and this deployment's runtime source
`47c9a8f8`, without promoting a full Phase2 gate or activating services here.

## Forge package installation

[`hosts/forge/services/atrium.nix`](../../hosts/forge/services/atrium.nix)
imports the selected app's NixOS module and installs its actual
`atrium-resolver` and `atrium-litellm-controller` commands into Forge's system
generation. It selects the same packages for the optional runtime units.
Installing them does not initialize a database or signing identity, enroll
anyone, adopt native credentials, publish a registry, or start a listener.
The resolver, reconciler and its timer remain disabled.

The selected app still rejects non-isolated desired-state documents. Actual
runtime activation therefore also needs app-owned deployment-mode support and
real registry/trust/ownership values, not a relabeled synthetic fixture.
Forge's existing LiteLLM configuration selects `v1.100.1`; the linked native
Atrium evidence qualifies `v1.99.1`. This change does not downgrade the gateway
or claim that the different version is qualified.

`atrium-forge-preparation` evaluates the actual Forge configuration for package
selection and default-off runtime, policy and credential boundaries. It is a
deployment composition check, not a native permit/deny receipt.

Build Forge using the repository's remote build path:

```sh
task nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

This builds on Forge without activating the generation. `naf` uses the
repository's guarded deployment wrapper for activation; it has not been run
as part of this package preparation.

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
217-case catalog, complete current-source/runtime/fixture maps, committed final
UID/model anchors, immutable artifacts and real materialized module origins
before resource creation. Both product/controller identities must name the app.
Mixed Nix implementation identity or historical anchors are refused.

## Source and runtime limits

Nix unit/Caddy checks establish deployment composition only. The app's
source-only fixture tests consume explicit public host-generated JSON. Neither
is native acceptance. Existing65-second controller readback and90/100-second
caller budgets remain unchanged; end-to-end timing is still a runtime gate.

The27-group result is source-bound and includes real permits, denials and
recovery; it does not convert unavailable `/messages` modes or other independent
browser/adoption gates into completed work. Native execution and exact cleanup
are app-owned. Deployment checks themselves perform no native, Podman or lease
operation.

## Historical evidence

The [earlier source integration](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/ATR-N03-N07-readback-integration-handoff.json),
[five failed/partial model attempts](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/ATR-N03-N07-model-native-blocked-handoff.json)
and [C8/JTI handoff](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/nix-config/atrium_n03/n03-c8-native-6fac02ef-handoff.json)
remain byte-identical in the app, with original path/commit/hash mappings in its
[N03 import manifest](https://github.com/carpenike/atrium/blob/7c7685622f30b9c0369e51f04713a45c57387d15/harness/evidence/nix-config-n03-imports.json).
The prior22/27 is not relabeled or transferred. Historical and new receipts are
app-owned; deployment documentation keeps immutable links, not duplicate bodies.
