# Atrium deployment consumption

This repository selects immutable Atrium versions and owns deployment values,
users/groups, secret-path references, isolated host composition and network/Caddy
wiring. Atrium owns controller/admission runtime, behavior/security/rotation and
version-compatibility tests, native helpers, orchestration and canonical evidence.
Home MCP and Whiskey implementations remain in their respective repositories.

The [Forge runtime foundation](atrium-forge-runtime.md) adds concrete protected
listeners, private custody, explicit bootstrap units and health/backup wiring.
It remains fail-closed on missing reviewed policy/native/model inputs and does
not activate or silently adopt production state.

## Package and helper contract

The Atrium input must provide:

* `packages.${system}.atrium-litellm-controller`, including
  `bin/atrium-litellm-controller`.
* `packages.${system}.atrium-litellm-admission`, including
  `bin/atrium-litellm-admission`.
* Existing `nixosModules.atrium` and `lib.render` interfaces.
* `nixosModules.litellm-admission`, preserving
  `services.atriumLitellmAdmission` options.
* `nixosModules.whiskey-egress-fixture`, preserving
  `services.atriumWhiskeyEgressFixture` options.
* `packages.${system}.pwa` and `nixosModules.pwa` for the public browser shell,
  generated public configuration and app-owned Caddy routing fragment.

`pkgs/default.nix` forwards the package exports directly. It has no local
controller/admission builder or fallback. No Python source path or host-created
Python environment is used to substitute for either exported package.

The consumer imports the generic modules from the pinned app. It retains
namespace selection, service UID, capability composition, environment removal
and credential-path values here. The app module owns the egress installer and
its implementation path; no new consumer `egressProgram` option is required.

## Deployment checks

The following Nix checks test consumption and host wiring, not product behavior:

* `atrium-n04-package-smoke` and `atrium-n05-package-smoke` require the exact app
  export, an executable CLI, and successful `--help` without runtime state.
* `atrium-n04-units` checks isolated reconciler package selection, arguments,
  users, state/credential paths and timer/service hardening.
* `atrium-n05-units` checks isolated admission package installation and protected
  settings-path references, including disabled-by-default configuration.
* `atrium-n06-units` checks namespace/path selection and service composition,
  including explicit capability resets and rejected stronger overrides.
* `atrium-forge-native-policy-compatibility` loads the current generated Forge
  policy through the installed Home MCP package's retained vendored parser.
  It checks all five native view bindings, six refusal/recovery cases, and the
  unchanged imported `Decision`/`PolicyDenied` definitions. It does not perform
  native authentication or replace the application's permit/deny suite.

The Forge foundation is covered by `atrium-forge-preparation`,
`atrium-forge-caddy`, and `atrium-identity-bootstrap`. These distinguish missing
policy/adoption from readiness and preserve retained native services.
`atrium-forge-client-views` checks the separate finance/scribe/status declarations,
manual grant append, unchanged unadopted Hermes configuration and exact-target
adopted aliases. See [bounded native clients](atrium-forge-cloud.md#bounded-native-finance-clients);
it neither applies grants nor migrates credentials.
Building an app package may
run tests defined by that app's own package expression; nix-config does not copy
or invoke a parallel controller/admission/product pytest suite.

```sh
nix build --builders '' --no-link --no-write-lock-file \
  .#checks.x86_64-linux.atrium-n04-package-smoke \
  .#checks.x86_64-linux.atrium-n05-package-smoke \
  .#checks.x86_64-linux.atrium-n04-units \
  .#checks.x86_64-linux.atrium-n05-units \
  .#checks.x86_64-linux.atrium-n06-units
```

These checks do not activate services, run native/Podman acceptance, modify live
credentials or claim any T-case. App behavior and native acceptance run under
the app-owned harness with separate explicit authorization.

## Browser hosting and owner registration

`hosts/forge/services/atrium-pwa.nix` consumes the app's static package and
`services.atriumPwa` module. Caddy serves the exact shell/assets and
`/client-config.json`; existing resolver APIs/JWKS and private-route blocks
remain in place. Callback/configuration documents are not cached, the popup
opener is preserved, and Atrium access logging is discarded. No second web
daemon, token vault, cookie-auth proxy, device enrollment or grant seeding is
introduced.

The declared new public client is **`cc.atrium.browser`**, not a replacement for
`cc.atrium.operator`. The browser's ID is appended to C10 and the native Whiskey
adapter receives the exact `https://atrium.holthome.net` browser origin.
This configuration does **not** register a client at Pocket ID or prove that
an existing client with that name belongs to this deployment.

Before first browser use, the owner must create the dedicated client in the
existing Pocket ID installation, or verify an already owner-created matching
registration. Do not adopt a conflicting client or recreate either API resource:

| Setting | Value |
| --- | --- |
| Client ID | `cc.atrium.browser` |
| Public client / PKCE | Enabled; no client secret; browser uses S256 |
| Exact callback | `https://atrium.holthome.net/auth/callback` |
| Access-token lifetime | 14 native minutes, as in the qualified browser fixture; never 60 native minutes, which Pocket ID can round beyond the 3600-second ceiling |
| Refresh-token lifetime | 60 minutes; the browser discards returned refresh tokens and never refreshes silently |
| Login restrictions | Retain the reviewed Atrium login-group restrictions; do not change group membership |
| Resolver API resource | Existing `https://atrium.holthome.net/resolver` |
| Whiskey API resource | Existing `https://whiskeywhiskeywhiskey.org/api/mcp` |
| Grants on both resources | User-delegated access only; client/machine access disabled |
| Requested scopes | `openid groups`; no additional native scope gate |

Use the normal build and owner-operated activation after reviewing the pin:

```sh
task nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

Do **not** rerun foundation initialization or reset credentials, deny history,
native sessions or existing grants. Browser registration is separate from the
operator foundation setup flow. To disable only the browser, explicitly set
`services.atriumPwa.enable = lib.mkForce false`; the resolver, native routes,
operator admission and adopted services remain intact.

`atrium-pwa-wiring` checks public metadata, additive client admission, native
audiences/origin, existing API/private routing, disabled behavior and unchanged
policy/state declarations. Pre-adoption/first-setup fixtures explicitly disable
the browser rather than pretending the new client existed during their
historical operator-only preparation.

The app's [original popup-failure receipt](https://github.com/carpenike/atrium/blob/9954c5642b2ba75052f306f46529b418c3944f1d/docs/evidence/ATR-P06-Caddy-popup-9057788-blocked.md)
preserves the original Caddy popup failure; the corrected app selects
COOP `unsafe-none` without weakening its origin/source/state/nonce checks.
The later successful native evidence is retained by
[carpenike/atrium#67](https://github.com/carpenike/atrium/pull/67): 47 groups
through actual Chromium and a real WPE WebKit mobile-configured engine with
native Whiskey `7624fe0`. This is not iOS/Android-device, passkey UX or WebKit
offline/installation qualification.

The original P06 proposal built Forge but its broader checks still failed on
stale selected pins and an overly broad whole-source vendor comparison. The
release follow-up updates `tests/atrium_n03/pins.json` to the actual selected
application and native consumer. These are current composition expectations,
not historical runtime receipts.

Home MCP's `1762ecb` dependency and its artifact lock remain unchanged. The
current app's credential profiles, policy schema and native-policy wire code
are byte-identical to that vendor source; its PWA/discovery additions do not
make the entire `nix`, `profiles` and `resolver` trees identical. Instead,
`native-vendor-compatibility.json` lists exactly the eleven reviewed changed or
added files, with old and current digests and source identities. Every unlisted
member and digest must still match. Negative controls reject changed credential
contracts, unreviewed additions and a different vendor revision.

The installed-native policy check complements that source comparison with the
actual consuming parser and unchanged imported decision/error definitions.
Whole-flake evaluation is now required to pass; the browser checks do not
bypass failed foundation/controller jobs. Original source-bound receipts and
the original P06 baseline failures retain their dates and outcomes.

The owner's later Whiskey selections (`c3c2ac8`, `35ed2d8`, then `870616d`) are
not the earlier `7624fe0` used by the 47 browser groups. The comparison through `c3c2ac8`
keeps native authentication, companion/deny policy, dependency lock and
credential-profile artifacts unchanged. Its operation projection adds
`approxEndTime`; Atrium's bounded parser still selects only
`id`, `title`, `realDate`, `startTime` and `status`. This source comparison is
not a new 47-group browser run or a claim that unrelated Whiskey features were
qualified by P06. The later telemetry/dependency and screening-nomination
updates received separate source and installed-package qualification; they do
not inherit an older compiled manifest merely because the application name is
unchanged.

The selected Whiskey release is
[`b681741`](https://github.com/carpenike/whiskey-whiskey-whiskey/commit/b681741ab76af6b1bfb9b6a938293870f2e8d7d4),
merging the qualification-only repair of the owner's `870616d` runtime.
Its [source-bound receipt](https://github.com/carpenike/whiskey-whiskey-whiskey/blob/b681741ab76af6b1bfb9b6a938293870f2e8d7d4/docs/evidence/ATR-W03-generation-manifest-870616d.json)
records 238 generation, 159 native and 245 changed-boundary cases, with one
pre-existing native unit skip distinguished from the executed cases. Actual
installed Darwin checks pass all twenty compiled hashes and twelve generation
cases, including private-runtime and byte-drift refusals, with zero background
inference. Separate installed migration and JWT/HTTPS read probes cover the
changed database/service boundary. All 151 executable server modules match the
owner's runtime; no application logic or dependency version was changed by the
repair. Existing application CI now runs the same compiled-contract checker
after its build, without bypassing mismatches.

The earlier `c3c2ac8` and `35ed2d8` receipts remain historical. None of these
source, installed-native or CI results relabels the original 47 browser groups.
The final deployment selection also passed the existing installed Linux
Whiskey cutover guest and Forge build on **2026-09-23**; source-build CI and
Darwin results were not substituted for those Linux checks:

* `atrium-whiskey-cutover` passed all nine preparation and seven host/network
  groups, the twenty installed compiled hashes and twelve generation cases,
  and the private-runtime refusal. Its actual Linux Node 22.22.2 process made
  six synthetic generation requests and two background validations, with zero
  background inference. The guest cleaned up normally. The exact derivation
  is `02hnd0vzgz0ak3xmbaz80anzmbj52nzb-vm-test-run-atrium-owner-whiskey-cutover`;
  its output is `slr7wk8pkm2h2fnicnf0mn46qzvihsi8-vm-test-run-atrium-owner-whiskey-cutover`.
* `atrium-forge-native-policy-compatibility` passed its five installed-native
  view bindings, six refusals and recovery on Linux, producing
  `a5h890mjw5kccwf8p3h0ppdbgdb8wm6p-atrium-native-policy-compatibility`.
* All-system whole-flake evaluation, current source/pin checks, isolated units
  and model preparation, fourteen browser wiring checks, and composed normal
  and adopted Caddy checks passed.
* The normal remote Forge build produced
  `4icc6lahl6z2rcbhp5ri0wv2n7nw4a49-nixos-system-forge-25.11.20260630.b6018f8`.
  This was a build only, not activation.

These checks use the selected `b681741` application package and retain the
original failed stale-manifest Linux run as historical evidence. They do not
register the browser client, exercise household credentials, make paid model
requests, or assert that the browser has been deployed.

## Personal Money overview (FIN-UX-01)

The Money proposal consumes Atrium's bounded overview and Home MCP 0.27.0.
It declares one additional native view, `personal-money`, on
`/cc/views/personal-money`, with only the source-owned
`atrium-personal-money` scope and read-only access. Its non-delegable grant
belongs explicitly to Ryan's Personal wing; it is not Family access or a
read-only alias of the finance/advisor credential. Existing native views and
the default `/mcp` resource retain their scopes and targets.

The backend reads the export-owned `household_finance.money_overview` snapshot,
not the Actual sidecar's sync-on-read paths. The dedicated
`atrium-money-reader` PostgreSQL role has CONNECT/USAGE and SELECT on that one
table only. It has no password or shared `readonly` membership. A local peer
mapping admits only the `homelab-mcp` service identity; no database credential
is exposed to the PWA. Table creation consumes Home MCP's exact `overview.sql`
definition as the existing export owner. No ledger or reporting history is
deleted or migrated.

The exact PWA origin is provided to native Money transport only when browser
hosting and native adoption are enabled. Native mTLS issuance remains private;
the browser receives the ordinary short-lived, target-bound native credential.
The existing source/vendor comparison and installed policy-reader checks still
apply, including rejection of unreviewed source changes.

### Owner activation after the source/deployment PRs are clean

Do not activate a draft proposal or bypass a failed release check. Once the
coordinated source/deployment selections are merged, use the existing owner
workflow:

```sh
task nix:prepare-atrium-native
task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
```

Preparation retains the existing native profile, signing material, refresh/
deny history and existing grants. Its exact append plan now includes Money;
it does not rerun foundation enrollment or register another Pocket ID browser
client. This is an explicit owner command, not a boot-triggered grant.
The current `atrium-grant-finance-clients` unit still uses `seed-policy --append`.
An explicit principal grant must be revoked explicitly; group removal alone
does not revoke it.

The table may initially be empty until the normal scheduled finance export
publishes a Money snapshot. The PWA reports that state. Do not trigger bank
sync or invoke the exporter merely by opening or refreshing Money.
No existing finance Desktop/Hermes configuration or Grafana dashboard is retired.

### Qualification and limits

The [Atrium Money receipt](https://github.com/carpenike/atrium/blob/46f1a12eaa19bfec1da0aa9e5913519177db1660/docs/evidence/FIN-UX-01-native-browser-51f0809.md)
records ten genuine built-client/native groups, including signed denial with
zero SQL reads, genuine late-response clearing and real credential expiry.
The native package has separate real PostgreSQL permission/atomicity and
installed native permit/deny checks. These do not relabel the original 47 PWA
groups or qualify physical mobile devices, household financial sources,
new accounts, bank-sync controls or financial write actions.

The proposal's all-system evaluation and targeted browser/view/cloud-schema/
native-policy/preparation checks pass. The normal remote build produced
`/nix/store/ig3vgv9rx0wbn05ds5230yaqjf7afq5k-nixos-system-forge-25.11.20260630.b6018f8`
without activation. Exact selected inputs and final CI/guest outcomes are
recorded in the release PR; a build alone is not an authorization gate.
The real Linux native-preparation guest also passed all 17 retained groups
with the Money plan: four explicit native grants plus the untouched ordinary
grant, refusal of partial/mismatched plans, retained original cutover time,
unchanged signing/history, and replay refusal after reopening.
Its output is
`/nix/store/20whfzalfvmc1r2lz04i2cb189i6gv5s-vm-test-run-atrium-owner-native-cutover`.

## Host-generated fixture boundary

The retained functions `tests/atrium_n04/fixture.nix` and
`tests/atrium_n06/fixture.nix` take `{ atrium }`. They return the generated registry,
resolver/model configuration and `sourceRegistry`; N06 additionally returns its
host-selected `egress` policy. `tests/atrium/registry.nix` remains the shared
synthetic deployment registry.

App-owned runners must consume explicit generated configuration rather than
importing product source from nix-config. Existing N04 behavior tests support an
`ATRIUM_N04_GENERATED_FIXTURE` JSON input; the app owner controls their standalone
fixtures and runner interfaces. Deployment checks do not invoke a second
acceptance driver here.
The app's `lib.isolatedTestRegistry`, `lib.litellmControllerFixture` and
`lib.whiskeyEgressFixture` exports serve app-owned synthetic tests; the consumer
continues to own its actual host registry/configuration values.

## Source and historical evidence

After explicit owner transfer confirmation, local product package directories,
generic N05/N06 module copies and product test/evidence duplicates were removed.
The six deployment Nix files and shared host registry remain. The21 runtime
Python/project files were checked against the accepted source; all68 historical
JSON results were compared with their original Git blobs and app canonical
destinations. Twelve reused an existing canonical copy and56 were imported once.

The original relocation [Atrium sourcedf1fa179](https://github.com/carpenike/atrium/tree/df1fa179059b45b3d435e92e5f08fcf2720d821c)
established the consumed package and module interfaces. Its
[`harness/evidence/nix-config-imports.json`](https://github.com/carpenike/atrium/blob/df1fa179059b45b3d435e92e5f08fcf2720d821c/harness/evidence/nix-config-imports.json)
records every original
repository/commit/path/SHA and canonical app path. The verified manifest SHA-256
is `bfc78448b3ac497d2a06d18af2cf399f5e65039ea4e03e4757877638e9d3b088`.
Original runtime, runbooks, tests and receipts remain in immutable
[nix-config source4e5994a](https://github.com/carpenike/nix-config/tree/4e5994afe48d6dbe13a0bd21fbf30bf9ff42b6ab).
The final deployment pin is immutable; earlier working-tree override evaluations
were provisional checks only, not the source selected by this deployment.

The app's [relocation handoff](https://github.com/carpenike/atrium/blob/df1fa179059b45b3d435e92e5f08fcf2720d821c/harness/evidence/ATR-N07-app-owned-handoff.json)
records fresh, source-bound producer/UID, controller, model, admission and egress
evidence, including exact cleanup and explicit unsupported-protocol limits.
Those product results are referenced, not copied into this deployment repo.

The earlier failed N03 cohorts and22-of-27 result remain historical. This
ownership correction neither promotes them nor authorizes another native run.

The earlier alias-convergence slice advanced only Atrium to immutable
`df39edf4e783222700e658951088b0651f65d02a`, containing the accepted
[native alias-convergence correction and current publication qualification](https://github.com/carpenike/atrium/blob/df39edf4e783222700e658951088b0651f65d02a/harness/evidence/ATR-N04-alias-handoff.json).
All other lock inputs and host policy values were unchanged by that update.
Its217-case/UID/model evidence supersedes the old controller qualification,
not the historical receipts themselves. N03's integrated acceptance and any
production activation remain separate gates.
