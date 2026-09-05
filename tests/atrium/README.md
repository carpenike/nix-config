# ATR-N02 isolated registry values

These are **isolated declarations owned by forge**, not enabled forge services.
The values live under `hosts/forge/atrium/` but are deliberately not imported by
`hosts/forge/default.nix` or any live service. No deployment, key/team
mutation, refresh migration, firewall change, real child account, or paid model
call is performed. The test host does not start a resolver or reconciler.

## Placement and consumption

- `hosts/forge/atrium/registry-isolated.nix`: concrete `personal:ryan` /
  `family:holt` values and permission templates, consuming an **Atrium flake**,
  not copied option/validator code. `tests/atrium/registry.nix` imports this one
  declaration rather than maintaining a parallel copy.
- `host.nix`: isolated NixOS module fixture importing
  `atrium.nixosModules.atrium`; it asserts the fixture hostname and disabled runtime
  components. It is never imported by `hosts/forge`.
- `evaluate.nix`: real Nix permit/deny and generated-policy checks. The root flake's
  `checks.<system>.atrium-registry-values` supplies its immutable private Atrium
  input. A caller may instead supply an exact reference for an isolated local
  review. No live service is enabled.

The root flake pins the published `atr/N02-registry-module` commit and follows
the existing stable nixpkgs input; no unrelated input is updated. HTTPS Git
transport uses the operator's existing Git credential helper for this private
repository. No GitHub token is written to configuration or passed on a command
line.

```sh
nix build --no-link --builders '' .#checks.aarch64-darwin.atrium-registry-values
```

For a separate immutable local review, use the module commit from the paired
ATR-N02 report:

```sh
nix eval --json --file tests/atrium/evaluate.nix \
  --apply 'evaluate: (evaluate {
    atriumFlake = "git+file:///absolute/path/to/atrium?rev=<accepted-commit>";
  }).report'
```

The same interface accepts a published private Git flake reference. Local
overrides do not modify the root lock file or import the fixture into live forge
configuration.

Inspect the R01 input without embedding another schema:

```sh
nix eval --json --file tests/atrium/evaluate.nix \
  --apply 'evaluate: (evaluate {
    atriumFlake = "git+file:///absolute/path/to/atrium?rev=<accepted-commit>";
  }).documents.resolver'
```

Atrium's `nix/README.md` documents the complete v2 JSON contract and publication
paths under `/etc/atrium/desired-state/`. Nix option names are camelCase; wire fields
are snake_case; all identifiers remain canonical. Display labels use **wing**.

## Values and explicit limitations

The two new fixture team IDs are `cc.personal.ryan` and `cc.family.holt`, with
`owner = "command-center"`. They are desired-state identifiers, not allocated
native IDs, adoption approval, or evidence of protected runtime ownership. N04
must establish installation-qualified native bindings and reject name collisions
without adopting existing objects. Existing teams, keys, aliases and consumers
remain unowned and unchanged. Alias targets declare required
domain/provider/account/credential relationships.

Canonical `ryan` is the fixture administrator; `fixture-child` is an explicitly
synthetic child. Both native subject bindings and the Pocket ID issuer are fake.
Human roles follow `admin`/`adult`/`child`; service principals have no human roles.
Principal `groups` are a Nix ceiling: R01 must retain the separate runtime
membership mirror from Pocket ID rather than overwrite it from these declarations.
All remote endpoints and provider hosts are `.invalid` doubles. The credential
paths under `/run/atrium-fixture/` are declarations only; no files, SOPS secrets, or
signing material are created or read. Budgets and rotation timings are synthetic
test ceilings, not approved live household policy.

One Home MCP deployment has explicit admin, adult, and child views. The admin
profile is available only to the fixture administrator; the same administrator
using the child view still receives only its declared read scope. Every instance
declares its canonical owner, affinity, and read/write ceiling. Owner metadata is
not an implicit ACL grant. Views declare server dispatch enforcement; real adapter
conformance is still blocked.

MCP scope/tool/resource data comes from Atrium's synthetic source-handler fixture,
**not** a manually maintained
copy of `mcp/src/homelab_mcp/scope_definitions.py`. Production source-export and
dispatch integration belongs to M03/S03 and must use the same deployed source
revision. Cross-domain views and real Entra/Work IQ integration stay disabled.

Whiskey text has a domain-owned model-service template with a live runtime key
path and bounded rotation overlap. The OpenAI/Gemini/OpenRouter image exception
IDs point to non-actuating `.invalid` providers and credential-path fixtures. N06
must supply and exercise actual inventory-reviewed outbound policy later.
`egress.enforcement` is a declaration, **not** proof of installed controls or
image-only modality enforcement. No undeclared provider fallback is configured.

## Evidence and blockers

Current schema-2 evaluation passes **18 paired static mutations and 19 structural
assertions**. The matching Atrium implementation passes **29 permit checks, 209
deny checks, and 18 module assertions**, including the restored ownership,
affinity, read/write, view enforcement, role, child-model and fallback invariants.
The evaluator rejects schema 1 and legacy unclassified source catalogs.
The verified schema-2 Atrium input is
**`f19c8ad5186774d092cbfe8e04dccf4aacf51150`**, consumed through an immutable local
Git flake reference; the report returned this exact `atrium_revision`.

**Historical schema-1 evidence, not the current input:** initial N02 validation
used Nix **2.31.5** and the immutable local Atrium flake
revision **`cd342959658f2697b2ac2dca5091f75c65d2d9d2`**. The report returned that
exact `atrium_revision`, all twelve permit/deny pairs passed, and all thirteen
structural/module assertions passed. Atrium's own matching revision passed
seventeen permit checks, 169 deny checks, and eighteen module assertions, with
`nix flake check --no-build --all-systems` evaluating all four architecture outputs.
No check result is represented as a runtime gate pass.

`evaluate.nix` checks eighteen paired static mutations (including the structural
counterparts of T5/T6/T7/T9/T11/T22) and nineteen additional structural/module
assertions. The valid complete registry is each mutation's permit twin. It
publishes `runtime_gate_evidence = false` and the actual Atrium input revision.

All runtime T5/T6/T7/T9/T11/T22 cases remain **blocked** pending real resolver
policy/brokers, Home MCP scopes, the owned LiteLLM controller/admission hook, and
the isolated ATR-N07 harness. Nothing here is runtime gate evidence or approval
for cutover. No amendment is proposed.

The existing `task nix:build-nixos` uses a remote live build/target host; it is not
used for this isolated evaluation. The targeted `nix eval` above validates this
ticket without contacting forge or evaluating unrelated private live inputs.
