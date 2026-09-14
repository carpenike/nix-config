# ATR-N03 — Atrium setup manifest and managed admission

This branch starts at final C10 PR1099 head
`3a7fcb6d7737e83c3aa145b1a3326f1c72aaa55c`. Nix owns the host values and
admission import; the app owns the packaged setup frontend, plan/verification
workflow and qualified Pocket ID adapter.
The [source-bound receipt](evidence/atrium-setup-manifest.json) includes the exact
exported manifest, placeholder contract, commit and check artifacts.

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

Existing C9/C10 schema/composition/adoption checks remain in use. These are
configuration/evaluation tests, not native setup execution or live admission
proof.

The final packaged frontend/adapter input and end-to-end setup qualification
are parent-owned. No app pin changes or full Forge build are performed until
that immutable package is supplied. Any eventual full Forge build uses the
existing remote Taskfile only; there is no full Linux closure build on the Mac.
