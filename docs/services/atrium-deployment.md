# Atrium deployment consumption

This repository selects immutable Atrium versions and owns deployment values,
users/groups, secret-path references, isolated host composition and network/Caddy
wiring. Atrium owns controller/admission runtime, behavior/security/rotation and
version-compatibility tests, native helpers, orchestration and canonical evidence.
Home MCP and Whiskey implementations remain in their respective repositories.

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

Ordinary host configuration builds remain unchanged. Building an app package may
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

The pinned [Atrium source648048ee](https://github.com/carpenike/atrium/tree/648048ee609002f8b8c5af6d0d6b8c6cb97fc6cb)
exports the consumed packages and modules. Its
[`harness/evidence/nix-config-imports.json`](https://github.com/carpenike/atrium/blob/648048ee609002f8b8c5af6d0d6b8c6cb97fc6cb/harness/evidence/nix-config-imports.json)
records every original
repository/commit/path/SHA and canonical app path. The verified manifest SHA-256
is `bfc78448b3ac497d2a06d18af2cf399f5e65039ea4e03e4757877638e9d3b088`.
Original runtime, runbooks, tests and receipts remain in immutable
[nix-config source4e5994a](https://github.com/carpenike/nix-config/tree/4e5994afe48d6dbe13a0bd21fbf30bf9ff42b6ab).
The final deployment pin is immutable; earlier working-tree override evaluations
were provisional checks only, not the source selected by this deployment.

The earlier failed N03 cohorts and22-of-27 result remain historical. This
ownership correction neither promotes them nor authorizes another native run.
