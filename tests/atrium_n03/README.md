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

The [source-only compatibility checkpoint](https://github.com/carpenike/atrium/blob/e5053dad17a5e604d3128286341806a2c7efb2ed/harness/evidence/ATR-N03-N07-app-layout-handoff.json)
binds app source `e1b7f65` and deployment source `0ac5ec6c`.
Handoff SHA-256:
`dd14c898938233c636138519ed1b31e9a1db1eec2e93de99d4584816b59df6cd`.
It records clean preparation,123 app/fixture source tests,64 deployment
assertions and two Caddy modes—not a native run. The receipt remains app-only.

## Resumed isolated proof — blocked

The [app-owned resumed handoff](https://github.com/carpenike/atrium/blob/6e4ce15db1bd4e0144f452608b9b41eb91718a79/harness/evidence/ATR-N03-N07-resumed-native-handoff.json)
binds app driver `1e53ab9b322ff837876c0eca9cc57361fff14094` and deployment
`966c634ec60006d3008b7be5ec0d2ec0a7a0ea88`.
Handoff SHA-256:
`4bfb902deeed309b8ee15ea8198c64aefbc425e53de1b4cd54506642b59f786f`.

Four clean-source native attempts completed22,24,26 and26 of27 groups.
The final key-info transport/outage group remains incomplete; no full N03/N07,
N05/N06 or Phase1 completion is claimed. All failures and exact-source maps
remain in the app. Independent cleanup proves20 containers/four network IDs
and names absent, all four inventories baseline-equal and `ambit-db` unchanged;
the owner-qualified fixture lease is released. No further native run is
authorized by this checkpoint.

Deployment revalidation passed64 assertions, both Caddy modes and the actual
selected MCP Settings check. App source checks passed94 focused cases and the
68-case CI selector; the unchanged canonical catalog collected exactly161.
Accepted main, the owner's WorldMonitor repair and MCP deployment check are
normally merged; primary nixpkgs/MCP/Whiskey and isolated LiteLLM1.99.1 pins are
unchanged. Only this immutable pointer is added here, never a new result body.

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
