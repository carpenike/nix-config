# ATR-N03 — Atrium setup manifest and managed admission

This branch starts at final C10 PR1099 head
`3a7fcb6d7737e83c3aa145b1a3326f1c72aaa55c`. Nix owns the host values and
admission import; the app owns the packaged setup frontend, plan/verification
workflow and qualified Pocket ID adapter.
The [source-bound receipt](evidence/atrium-setup-manifest.json) includes the exact
exported manifest, placeholder contract, commit and check artifacts.
The [foundation-check correction receipt](evidence/atrium-setup-foundation-check.json)
records the later read-only unit and its separate source-bound evaluation.
The [final coordinated build receipt](evidence/atrium-setup-final-build.json)
records the selected implementations, focused checks and non-activated Forge
closure without rewriting either earlier receipt.

No live setup, native provisioning, initialization, service restart or
activation was performed here. The desired client and callback below are
explicit new setup defaults, **not discovered, registered or admitted objects**.

## One manifest, two surfaces

From any standard checkout of the deployment repository:

```sh
nix eval --json --option allow-import-from-derivation false .#lib.atriumSetupConfigs.forge
```

This evaluates host values without building the Linux closure, running services
or reading credentials. The identical value is installed as:

```text
/etc/atrium/bootstrap/setup.json
```

`hosts/forge/atrium/setup.nix` derives issuer/resource from the selected registry
authority and principal/subject/group membership from the explicit bootstrap
operator plan. Friendly group names come from the registry. The desired
membership plan is not a runtime group observation or a broader inference from
all eligible principals.

The agreed schema is version 1:

```json
{
  "schema_version": 1,
  "host": "forge",
  "installation": "atrium-forge",
  "pocket_id": {
    "issuer": "https://id.holthome.net",
    "resource": "https://atrium.holthome.net/resolver",
    "principal": "ryan",
    "subject": "9853582c-b3fe-4e47-8cd9-56174ecba18e",
    "client_id": "cc.atrium.operator",
    "redirect_uri": "http://127.0.0.1:18889/callback",
    "access_token_minutes": 14,
    "refresh_token_minutes": 60,
    "groups": [
      {
        "name": "atrium-personal-ryan",
        "friendly_name": "Ryan's Personal wing",
        "member_subjects": ["9853582c-b3fe-4e47-8cd9-56174ecba18e"]
      },
      {
        "name": "atrium-family",
        "friendly_name": "Family wing",
        "member_subjects": ["9853582c-b3fe-4e47-8cd9-56174ecba18e"]
      }
    ]
  },
  "deployment": {
    "admission_file": "hosts/forge/atrium/setup-admission.nix"
  },
  "initialization": {
    "ssh_target": "ryan@forge.holthome.net",
    "units": [
      "atrium-initialize",
      "atrium-trust-initialize",
      "atrium-seed-policy"
    ]
  }
}
```

The emitted manifest also has exactly one optional extension,
`required_secrets: [{ "name": "<runtime source reference>", "purpose": "<text>" }]`.
Here `name` is the absolute non-secret runtime **source path**, not a credential
value or a discovered provider identity. These four references are derived from
the actual model-controller/resolver wiring:

| `name` | Required purpose |
| --- | --- |
| `/run/secrets/atrium-litellm-resolver-management` | Resolver-only management before explicit model adoption |
| `/run/secrets/atrium-litellm-controller-management` | Controller-only management, never inference |
| `/run/secrets/atrium-personal-anthropic` | Distinct Personal wing provider credential |
| `/run/secrets/atrium-family-anthropic` | Distinct Family wing provider credential, never a shared client bearer |

These are later adapter-adoption prerequisites, not secrets that this setup
manifest generates, reads or provisions. The plan must make that distinction
clear. Provider/controller credentials, user resource tokens, ID-token group
evidence and privileged setup authorization remain separate.

## Plan before creating; verify before admitting

The frontend must show the proposed client, callback, lifetimes, groups,
memberships and actions before creating native objects. Manifest presence is
not evidence of registration, native permission, C10 group freshness or
successful verification.

Before even invoking the native adapter's plan or apply operation, the frontend
must confirm the exact admission file is Git-tracked in the selected deployment
checkout. An ignored or untracked lookalike is not acceptable; setup must not
force-stage it. The Nix placeholder is already tracked. Native test fixtures
must initialize a Git repository and add their safe placeholder explicitly.

Only after the qualified native workflow verifies the created client may the
frontend replace the managed admission fragment with the narrow result:

```text
{ ... }: { services.atriumForge.groupEvidence.clientIds = [ verified-created-client ]; }
```

`verified-created-client` above denotes the frontend's actual verified value,
not a literal default or an ID supplied by this repository. The frontend owns
the exact safe Nix serialization. It must not add flags, grants, groups,
authority mappings, lifetime widening or other configuration.

No automatic Git commit is authorized. The operator reviews the changed
tracked fragment and its diff. Model/native/Whiskey adoption switches remain
disabled; filling C10 client admission is not adapter adoption or a live
activation decision.

## Exact tracked safe placeholder

`hosts/forge/services/atrium.nix` imports the tracked relative file
`hosts/forge/atrium/setup-admission.nix`. Initially it is a no-op module, so
`services.atriumForge.groupEvidence` remains `null` and the existing
unconfigured startup/adoption refusal remains active.

The exact safe-placeholder bytes are ASCII/UTF-8, LF endings, final LF, with
no BOM or extra blank lines:

```text
# Managed by atrium setup; no client is admitted until verified.
{ ... }: { }
```

Escaped representation:

```text
"# Managed by atrium setup; no client is admitted until verified.\n{ ... }: { }\n"
```

Length: **78 bytes**.

SHA-256:
`2a268c80ad7c1bd389b7ed6bd85f9f9101603a5126e07591c303b64589705125`.

The frontend must validate that `admission_file` is relative to the selected
deployment repository, resolves inside it, contains no symlink path, and is
the expected managed/safe file. Matching a filename or this comment alone is
not enough to authorize overwriting arbitrary owner edits. A changed or
unrelated fragment must refuse replacement unless separately recognized as
the frontend's known-owned result under its explicit ownership contract.
No unrelated file, primary checkout or existing owner configuration is changed
by the manifest exporter.

## Existing foundation checks and explicit initialization

The optional app-owned `--initialize-host` flow first verifies that the deployed
resolver configuration has the expected issuer, resource and verified client
admission. The operator must therefore apply the generated Nix configuration
before this flow can initialize the host; setup does not deploy it automatically.

`atrium-foundation-check.service` runs the fixed command:

```sh
atrium-resolver --config /etc/atrium/bootstrap/foundation.json check-foundation \
  --enrollment /etc/atrium/bootstrap/identity.json --installation atrium-forge
```

The installation argument comes from `runtime.installation`, not the frontend.
This manual, network-isolated oneshot uses resolver UID1060 and the initializer's
private hardening. It requires the existing resolver mount, database and
foundation marker. Its state tree is read-only, with no `StateDirectory`
creation/chowning or writable state exception. It has no timer, boot dependency,
initialization command or cached successful state. A failed check has a named
high-severity alert; it does not cause repair, migration or regeneration.

The parent-owned command validates existing SQL integrity, exact migration
hashes, configured authority/enrollment/bootstrap, deny generation and actual
resolver signing keyring. Before marking first initialization complete, and on
a known repeat, the frontend must run this check followed by the existing
`atrium-trust-check.service` under its separate TLS UID1061. A TLS check alone
is not resolver signing proof.

The manifest's `initialization.units` remains exactly the three explicit
initializers. These two fixed checks are not extra arbitrary manifest commands.
The selected app implementation below supplies the corrected read-only command.
Nix wiring does not itself prove the command ran or initialize any host state.

## Validation and handoff

`atrium-forge-setup` uses the existing Nix check runner. It checks exact root
and nested schema keys, exported/installed value parity, source-derived
identity/group values, relative admission path, placeholder bytes/hash and
actual host-module import.

Configured/unconfigured cases prove that naming `cc.atrium.operator` in a
manifest does not admit it. A test-only verified-result module admits only its
explicit fixture client, removes only the missing-client preflight, and
preserves registry/budgets/provider references, grants, identity enrollment,
group-observation declarations, adoption flags and TLS/firewall behavior.
All three initialization units remain manual, not boot dependencies.

Foundation-check assertions cover the exact command, existing mount/state
requirements, initializer hardening parity, resolver/TLS UID separation,
read-only state without directory creation, repeatable network-free execution,
manual invocation, failure alert and existing backup protection.

Existing C9/C10 schema/composition/adoption checks remain in use. These are
configuration/evaluation tests, not native setup execution or live admission
proof.

## First coordinated setup implementation inputs

The first fully built parent-supplied implementation inputs were pinned together in
`flake.nix`, generated `flake.lock` and `tests/atrium_n03/pins.json`:

| Component | Immutable implementation |
| --- | --- |
| Atrium setup, resolver and shared artifacts | `ec5ecea928a2e845236b4dc26d67f8424ec41436` |
| MCP tested artifact consumer | `21329a5a5857b801104b17bf6876babd31644559` |
| Whiskey, unchanged | `472f877952a363321c76ce580ce41dd0810e08b8` |

The full native vendor revision must equal the selected Atrium input. The
existing assertion is unchanged; later evidence-only heads are not substituted
for these tested implementations. Earlier C10 qualification metadata and the
original manifest/foundation receipts retain their original source bindings.

Parent-owned installed setup qualification reports 30 checks over 20 invocations
against Pocket ID 2.14, including native PKCE and canonical HTTPS C10. Its receipt
is `operator/tests/evidence/operator-installed-setup-20260914-attempt2.json` in
Atrium PR46's evidence commit `df7e02c`, with product source identical to the
selected implementation. MCP PR80's evidence head
`287f421d507c5d5bfe5a08e1dc2c548c3f066fb7` records 75 fresh installed
native/shared cases at `docs/evidence/ATR-M04-setup-artifacts.json`. These are
parent-owned results, not executions by this deployment branch.

The corrected app accepts required-secret names as runtime source paths and
inspects resolver signing/SQLite state without creating lock files, sidecars or
history. The read-only host unit is not widened to accommodate the earlier
defects. No host initializer or native provisioning command is run by Nix
consumption checks or the build.

Deployment validation uses the existing focused Darwin checks with
`allow-import-from-derivation=false`. The full Forge build runs only after the
implementation commit, through the existing remote Taskfile. Building a closure
does not activate it, admit the proposed client or change any adoption flag.

That coordinated input implementation is
`d851351f64cb9be41b396a977c64d212eb2edf82`. All 12 selected existing Nix checks
and the setup package passed in one Darwin invocation, including 206 deployment
assertions. The actual installed setup parser also accepted and round-tripped
the unchanged exported manifest with all four runtime secret references.

The prescribed remote build completed from that committed implementation:

```text
/nix/store/6sw88y37qcvawgwsl1bn9brfcxg90j4w-nixos-system-forge-25.11.20260630.b6018f8
```

Derivation:
`/nix/store/rnmphrrz9nirrf7iwcw7sgsx8hdyrs65-nixos-system-forge-25.11.20260630.b6018f8.drv`.
The remote artifact contains the matching setup manifest, six valid policy
documents, the unchanged read-only foundation unit and missing-client startup
refusal. Forge's active system remained unchanged. No host initialization,
client admission, adoption or native setup command was performed.

## Merge-candidate inputs and required public CI

After preserving current main `a51bdca9ed9d139e3bb0e076968b574ba1181f33` in
merge `fe3140e6340de9152da60d204a8487c593b1f525`, the promotion candidate pins:

| Component | Immutable implementation |
| --- | --- |
| Atrium | `1762ecb82cccc9c3aef3545f119ffe0f4e9e1682` |
| MCP artifacts | `8523ee680e4531dd33e132435c36666464e2174c` |
| Whiskey, unchanged | `472f877952a363321c76ce580ce41dd0810e08b8` |

The app change corrects a device-challenge expiry test to use each challenge's
own expiry, including the one-second creation gap; it does not change runtime
behavior. The parent reports 44 device-challenge cases passing and byte-identical
shared payload members and six MCP exports. The full native-vendor/app equality
assertion, policy/adoption defaults and concurrent upstream updates remain intact.

Promotion requires actual GitHub `Lint` and `Nix Build Successful` success on the
fixed PR head. The earlier remote artifact and receipts above remain bound to
their original source; they do not replace these required statuses. CI evidence
is retained on the PR without changing its head after the workflow starts. No
rule bypass, automatic upgrade timer change, activation or service restart is
part of this work.
