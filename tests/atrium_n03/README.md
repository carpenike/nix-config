# N03 isolated deployment configuration

This directory owns host values, version selection, unit/namespace composition,
Caddy configuration and deployment checks. It does not own Python/MJS
acceptance helpers or a second product test suite.

## Retained deployment files

* `fixture.nix`, `models.nix`, `pins.json`: synthetic host values, service and
  binary-artifact version selections.
* `application.nix`: exact selected app package/module availability only.
  Canonical source/evidence qualification is mandatory in the app preflight.
* `host.nix`, `model-host.nix`: isolated service, credential-path, UID/group,
  publication-directory and namespace wiring; model activation remains default-off.
* `caddy.nix`, `runtime-tools.nix`, `operations.nix`: network entrypoints,
  declared tools and non-activating operational references.
* `evaluate.nix`, `model-evaluate.nix`: deployment assertions only.

The two Caddy checks and unit/configuration checks remain in the flake. They do
not run app pytest suites, initialize credentials, claim a lease or activate
native services.

## App-owned acceptance

Reusable helpers, synthetic upstreams, PKI/client/probe code, artifact builders,
paired cases and the seven-group catalog now live in Atrium
`harness/n03_fixture`. The general driver is app `harness.n03_models`, which
requires this deployment checkout/revision explicitly.

New proof is emitted only in app `harness/evidence`. The app's strict preflight
binds app-owned runtime/fixture sources and committed canonical UID/model
anchors; no Nix package-availability flag substitutes for that qualification.
MCP and Whiskey implementations stay in their native repositories.

## Immutable history

Existing `results/` files are historical and remain byte-identical. They include
the [bounded C8/JTI result](results/n03-c8-native-6fac02ef.json) and
[earlier model integration failures](results/ATR-N03-N07-model-native-blocked-handoff.json).
Neither those results nor the earlier22/27 transfer to the new app layout.
Original helper source remains available at immutable nix-config
`a7c94cf479aafe1b5528f42aeb53f87f87e4f455`.

See [host/network wiring](../../docs/services/atrium-foundation.md) and
[model deployment](../../docs/services/atrium-model-preparation.md). A new
explicit parent authorization is required before any native run.
