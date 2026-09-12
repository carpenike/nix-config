# N03 model deployment compatibility

The N03 compatibility fixture remains default-off and isolated. Forge's
separate package installation is described below. The selected app inputs are
immutable Atrium `b06f153f5e219bfff30ed10d9acbbadea33b4b6a` and Home MCP
`23de14d586c668e1662294ff1f2a8d5da265cf24`; Whiskey273cf414 is unchanged.
The Atrium merge retains the exact reviewed `24ef385` tree, including explicit
1.100.1 compatibility, production metadata and the sidecar inode-recovery fix.
The accepted native companion tree is unchanged.
Other owner-selected flake inputs remain unchanged.
Package selection does not activate Forge's Atrium runtime or install the
isolated fixture into live services. Version qualification is recorded below.

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

The [owner identity bootstrap](atrium-identity-bootstrap.md) now derives its
native subject from Pocket ID's real management API and installs explicit
non-secret operator inputs. It does not initialize live state, create a client,
seed grants or turn on the resolver.

The selected app now supports explicitly configured production metadata, with
real paired adapter evidence linked below. Runtime activation still requires
actual registry/trust/ownership values, not a relabeled synthetic fixture.
Forge explicitly selects `services.atrium.litellmVersion = "v1.100.1"`,
matching its existing gateway image and the newly qualified app target below.
This does not install the admission hook into the running gateway or enable
reconciliation. Future resolver broker and admission settings must select the
same version explicitly; an unknown or mismatched version fails closed.

`atrium-forge-preparation` evaluates the actual Forge configuration for package
selection, the exact qualified gateway image, version-aware desired-state
generation and default-off runtime, policy and credential boundaries. The
generator check uses the existing isolated registry, not live registry
publication. It is a deployment composition check, not a native permit/deny
receipt. Changes to Forge's LiteLLM image also trigger this check in CI.

Build Forge using the repository's remote build path:

```sh
task nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

This builds on Forge without activating the generation. `naf` uses the
repository's guarded deployment wrapper for activation; it has not been run
as part of this package preparation.

## Qualified LiteLLM 1.100.1

The [app-owned version handoff](https://github.com/carpenike/atrium/blob/24ef385c7204f6e39bf44ed143b6f9586af181a5/harness/evidence/ATR-N05-11001-integration-handoff.json)
binds the actual controller, admission, protocol, worker, cache and streaming
permit/deny runs to manifest
`sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf`.
All 16 enabled protocol modes passed both-worker warm-cache denial and recovery.
Unversioned `/messages` remains unavailable (404), not a successful permit.

The final correlated follow-through passed seven phases and 24 requests after
correcting fixture readiness: both native worker catalogues must be visible
within the original 65-second budget before client keys or periodic work.
No product authorization, fallback or timing predicate was weakened. The older
underdiagnosed observation remains unclassified; it is not retroactively
explained by the later correction.

Native execution was Linux ARM64. Read-only Forge inspection confirmed
1.100.1/x86_64 and equality of all 20 inspected native auth/router/cache/stream
source files; this is not an additional AMD64 native run. Historical 1.99.1
defaults, fixtures and receipts remain unchanged and are not counted as 1.100.1
evidence. This version selection neither downgrades Forge nor adopts its
existing keys, teams or aliases.

## Qualified production metadata

The [app-owned integration handoff](https://github.com/carpenike/atrium/blob/1c5553362c3f3f8cde1faa2228da87ef408b5fb9/harness/evidence/ATR-N02-deployment-mode-integration.json)
keeps two separately executed native cohorts distinct:

- Seven fresh model/controller/admission/MCP groups at driver `dac6655`,
  runtime `a119f96`, native MCP `f961dc1` and fixture `5ccba5a9`, covering
  T5/T6/T7/T9/T11/T22 and actual producer/policy refusal-recovery pairs.
- Fixed-source installed sidecar runs at `3457131`: 72 production and 72
  independently executed default-isolated cases, including the approved
  recovery correction, with complete phase accounting and private cleanup.

Application PR36's final reviewed tree `bc36afd` is identical to merge4431882;
native PR77's `f961dc1` tree is identical to merge23de14d. The receipts retain
their actual executed revisions. These results qualify the deployment-metadata
extension, not a different gateway image, a new full-platform gate or live
adoption.

The optional `production-envelope.nix` fixture still requires its explicit,
immutable candidate inputs. It is not imported by Forge's live service module,
and its historical source guards are not changed by advancing host package pins.

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
