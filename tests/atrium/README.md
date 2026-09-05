# ATR-N02 isolated registry values

These are **test-only declarations**, not forge configuration. Nothing here is
imported by the root flake, forge, or any live service. No deployment, key/team
mutation, refresh migration, firewall change, real child account, or paid model
call is performed. The test host does not start a resolver or reconciler.

## Placement and consumption

- `registry.nix`: concrete `personal:ryan` / `family:holt` values and permission
  templates, consuming an **Atrium flake**, not copied option/validator code.
- `host.nix`: isolated NixOS module fixture importing
  `atrium.nixosModules.atrium`; it asserts the fixture hostname and disabled runtime
  components. It is never imported by `hosts/forge`.
- `evaluate.nix`: real Nix permit/deny and generated-policy checks. The caller must
  supply an exact Atrium flake reference. It consumes that flake's locked nixpkgs,
  avoiding changes to live inputs or unrelated dependency updates.

Use the accepted Atrium module commit from the paired ATR-N02 report:

```sh
nix eval --json --file tests/atrium/evaluate.nix \
  --apply 'evaluate: (evaluate {
    atriumFlake = "git+file:///absolute/path/to/atrium?rev=<accepted-commit>";
  }).report'
```

The same interface accepts an **approved, published** private GitHub commit ref.
No public availability or unpublished commit is assumed. Until the parent
publishes and supplies that ref, keep this caller-pinned interface; do not guess a
remote URL/ref or import the fixture into live forge configuration.

Inspect the R01 input without embedding another schema:

```sh
nix eval --json --file tests/atrium/evaluate.nix \
  --apply 'evaluate: (evaluate {
    atriumFlake = "git+file:///absolute/path/to/atrium?rev=<accepted-commit>";
  }).documents.resolver'
```

Atrium's `nix/README.md` documents the complete v1 JSON contract and publication
paths under `/etc/atrium/desired-state/`. Nix option names are camelCase; wire fields
are snake_case; all identifiers remain canonical. Display labels use **wing**.

## Values and explicit limitations

The two new fixture team IDs are `cc.personal.ryan` and `cc.family.holt`, with
`owner = "command-center"`. They are an authoritative managed inventory, not an
adoption rule. Existing teams, keys, aliases and consumers remain unowned and
unchanged. Alias targets assert domain/provider/account/credential ownership.

Canonical `ryan` is the fixture administrator; `fixture-child` is an explicitly
synthetic child. Both native subject bindings and the Pocket ID issuer are fake.
All remote endpoints and provider hosts are `.invalid` doubles. The credential
paths under `/run/atrium-fixture/` are declarations only; no files, SOPS secrets, or
signing material are created or read. Budgets and rotation timings are synthetic
test ceilings, not approved live household policy.

One Home MCP deployment has adult and child views. MCP scope/tool/resource data
comes from Atrium's synthetic source-handler fixture, **not** a manually maintained
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

Initial N02 validation used Nix **2.31.5** and the immutable local Atrium flake
revision **`cd342959658f2697b2ac2dca5091f75c65d2d9d2`**. The report returned that
exact `atrium_revision`, all twelve permit/deny pairs passed, and all thirteen
structural/module assertions passed. Atrium's own matching revision passed
seventeen permit checks, 169 deny checks, and eighteen module assertions, with
`nix flake check --no-build --all-systems` evaluating all four architecture outputs.
No check result is represented as a runtime gate pass.

`evaluate.nix` checks twelve paired static mutations (including the structural
counterparts of T5/T6/T7/T9/T11/T22) and thirteen additional structural/module
assertions. The valid complete registry is each mutation's permit twin. It
publishes `runtime_gate_evidence = false` and the actual Atrium input revision.

All runtime T5/T6/T7/T9/T11/T22 cases remain **blocked** pending real resolver
policy/brokers, Home MCP scopes, the owned LiteLLM controller/admission hook, and
the isolated ATR-N07 harness. Nothing here is runtime gate evidence or approval
for cutover. No amendment is proposed.

The existing `task nix:build-nixos` uses a remote live build/target host; it is not
used for this isolated evaluation. The targeted `nix eval` above validates this
ticket without contacting forge or evaluating unrelated private live inputs.
