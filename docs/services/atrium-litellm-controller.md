# ATR-N04 — Owned LiteLLM controller

**Isolated phase-1 implementation; not a production deployment or a completed
phase-2 gate.** Implements §5.3/§6.4, A.3(d/f), C2/C3, and N01's authoritative
inventory. The owner-edited Atrium specification is read-only. No amendment is
proposed. Production LiteLLM configuration, including its independent newer
version, is unchanged.

## Components and trust

- `pkgs/atrium-litellm-controller/`: dependency-free Python controller and CLI.
- `hosts/forge/atrium/litellm-controller-isolated.nix`: **not imported by Forge**.
  It consumes Atrium's existing Nix module/options/generator, supplies the real
  package, deploy trigger and one-second timer, and guards the isolated hostname.
- `tests/atrium_n04/`: N02-generated concrete fixture, unit evaluation, and real
  pinned-native acceptance with the existing N07 infrastructure.

Native teams, credential references and model/deployment IDs are allocated and
journaled **before** creation. The protected inventory, not a desired `cc.*` ID,
name, native role, or `cc.owner`, proves ownership. There are zero adoptions.
Existing same-name teams and superficially managed keys remain unowned. Existing
authorized runtime keys are discovered through R06's protected issuance state,
not a deployment-time key list.

The controller reads the complete native model-info result, including matching
wildcard/shared bindings. An extra unowned binding, changed native credential
reference, or unverified account/backend causes refusal. It never repairs an
owned key by changing an unowned team or alias. Named native credential references
bind the protected domain/provider/account declaration to the exact native model
ID; masked credential values are **not** evidence of account ownership.

Owned binding updates preserve their native ID and journal the pending
expectation for crash recovery. Changing a binding's domain or removing a backend
from a still-active alias requires a new exclusive alias/credential identity;
the controller will not invoke native model deletion, whose collateral alias
cleanup can affect unrelated objects. Retired templates disable known native key
hashes, including keys omitted from the latest snapshot. History is retained.
Unknown/corrupt ownership never becomes an empty inventory or a legacy exemption.

Every applicable key is intersected with its current template, protected effective
limits and owned native team. Native readback checks nonempty models/literal
routes, native expiry, budget, routing overrides, extra model grants and required
metadata. Expiry/spend are not reset on ordinary deploys; native blocks are never
undone implicitly. Different budget-window durations fail closed rather than
silently widening a grant. Native disable failure is an error; **N05's request-path
hook remains necessary**, not emulated here.

## R06 → N04: association snapshot v1

The language-neutral shape is
[`atrium-litellm-associations-v1.schema.json`](fixtures/atrium-litellm-associations-v1.schema.json).
The Python read-only integration is `AssociationSource.read(now) -> Snapshot`;
the deployed implementation is `ProtectedSnapshotSource`. R06 need not import
this package: it publishes the JSON contract from its protected
`credential_associations` state.

Envelope fields:

| Field | Contract |
| --- | --- |
| `schema_version`, `kind` | `1`, `atrium.litellm-associations` |
| `installation`, `issuer` | Exact configured installation and native issuer, not a human issuer inferred from email |
| `generation` | Positive, durable, monotonically increasing integer |
| `generated_at`, `expires_at` | UTC epoch seconds; deadline is at most 300 seconds after generation |
| `associations` | Complete current issuance snapshot, including explicitly revoked records as applicable |

Each association has **exactly**:

```text
issuer
credential_id       SHA256(raw native key), lowercase 64-hex
native_key_id       same SHA256 on the pinned native version
principal_id        canonical principal
authority_id        retained authenticating authority
domain
template_id
native_team_id      actual controller-published native ID, never a cc.* desired ID
issued_at           UTC epoch seconds
expires_at          verified native expiry, UTC epoch seconds
device_id           canonical enrolled device ID or null
state               active | revoked
effective_limits    {models: [exact aliases], routes: [literal inference routes],
                     budget: {usd: positive finite number, duration_seconds: positive integer}}
```

Additional semantic checks, beyond JSON Schema:

1. Every row's issuer equals the envelope/configured issuer; both hash fields are
   equal and unique. Issuance precedes expiry.
2. Native expiry and limits are verified **before exposure**. R06 commits its
   association and atomically publishes a fresh snapshot before returning any raw
   credential. Failed publication cannot expose an untracked key.
   Serialize native fractional expiry by rounding **up** to an integer second,
   never beyond the authorized deadline; comparing that ceiling rejects even a
   fractional native overrun. Native expiry is not replaced by metadata expiry.
3. Publish a new generation whenever content or freshness changes. Equal
   generations require the same canonical JSON SHA256; older generations and
   equivocation fail. Refetch does not refresh age. Generation time may be at most
   five seconds ahead; expiry has no extra freshness allowance.
4. R06 must periodically refresh the complete snapshot, even without new
   issuance. An explicitly initialized, verified empty snapshot is permitted;
   missing/unreadable/stale/unverified input is an error, **never empty ownership**.
5. Omission does not erase history: a previously known key without current
   authorization is disabled. Identity/authority/team/template changes or expiry
   extensions under the same key hash fail. Revocation cannot roll back.
6. The source is a regular, single-link, non-symlink file owned by the configured
   publisher UID, with no group/other write or other read access. Parent directories
   must be trusted and not group/other writable. Use `0600` or narrowly shared
   `0640`; N03 must provision the actual read-only access. A `"verified": true`
   property, file name, or untrusted native metadata is not authentication.

These are private OS-bound snapshots, **not** public control APIs, signed deny
documents, credential profiles, or Nix desired-state files. Their paths are
implementation/configuration details, not existing live paths.

## N04 → R06/N05: native bindings and service ownership

`bindings_snapshot` is atomically published only after native verification.
It uses this exact shape:

```text
schema_version: 1
kind: atrium.litellm-bindings
installation, issuer, generation, generated_at, expires_at
desired_state_sha256: SHA256(canonical schema-2 LiteLLM desired document)
teams:
  <logical team ID>: {native_team_id, domain, models: [alias IDs]}
aliases:
  <logical alias ID>:
    [{native_model_id, backend_id, model, api_base, native_credential_name,
      domain, provider, account, credential_id}]
```

`credential_id` in a **binding** is a declared provider-credential reference;
`credential_id` in a **credential association** is the native key SHA256. No
credential value is included in either. R06 must validate this protected
publication's installation/issuer/freshness/generation and use the exact
`native_team_id`; a logical ID or matching native team name cannot substitute.
The desired-state SHA256 binds the native check to the companion N02 document.

`service_association_snapshot` uses the same association schema as R06's input,
but is a **separate trusted producer** containing only controller-issued service
keys. It is published before the secret credential file. Its `authority_id` is
`controller`; this is service issuance provenance, not a human OIDC authority or
admin-outage entitlement. N05 keeps independent generation high-water marks for
the two producers and never treats a missing producer as legacy. Retired service
keys remain in history and export `state: revoked`.

Default output files remain private in the controller state directory.

### Opt-in protected reader group

The CLI and `Controller` accept optional `publication_reader_gid`. Existing
`bindings_snapshot` and `service_association_snapshot` select the two paths:

```json
{
  "publication_reader_gid": 62201,
  "bindings_snapshot": "/run/atrium-publications/controller/native-bindings.json",
  "service_association_snapshot": "/run/atrium-publications/controller/service-associations.json"
}
```

The GID is illustrative, not a production assignment. The publisher must belong
to it. Each output directory must already be publisher-owned with exact reader
GID and mode `2750`, outside checkouts/store and separate from ownership,
provider-credential and live service-token custody. The CLI also rejects overlap
with its management credential. Missing/unsafe directories and invalid
owner/group/mode/link/JSON state fail closed before replacement; configuration
does not silently create or relax a directory.

Only these non-secret snapshots use the new guarded publication mode. Existing
private journal writes and service-token delivery, acknowledgement and overlap
semantics retain their original helpers/defaults. In particular, a metadata
reader group is **not** the service-token consumer group. No raw token enters a
metadata publication, and the group gains no state/key access or write access.

Publication reuses the existing atomic JSON helper with an explicit guarded
mode: staging is `0600` until the full object is written, then gets its actual
publisher GID/`0640` mode and file fsync. The directory/old output are rechecked,
replacement is descriptor-relative and the directory is fsynced. Unchanged
bytes are not rewritten. Pre-switch failures retain the working output;
post-switch directory-fsync failures surface uncertain durability instead of
claiming success. No error renews timestamps or changes authority/history.
An identical retry must still sync the validated parent directory before
reporting success. A continuing sync failure remains an error; recovery does not
rewrite the snapshot or renew its bytes, generation, timestamps or freshness.

N03 can provision distinct publisher-owned `2750` directories and a dedicated
read group, then configure the existing R06/N05 readers with actual publisher
UIDs. There is no root/chown relay, shared signing UID or rotating credential
snapshot. Omitting the new option preserves private `0600` output behavior.

The cross-UID lane invokes real R06/N04 export APIs, actual N05
`read_producer` and N04 `ProtectedSnapshotSource` under different unprivileged
UIDs in a network-disabled container. Synthetic normalized producer state is
input data; the lane does not claim native key creation or a complete model
gateway/admission gate. Source/helper bytes, exact ownership, replacement/fault
observations and cleanup are recorded separately from ordinary unit fixtures.
The paired Atrium candidate's `harness/PUBLICATIONS.md` documents the N03
configuration handoff, exact isolated UID/GID roles, clean-source runner and
Darwin setgid test limitation. Neither repository activates N03 in this follow-up.
Its `harness.publications_models` follow-up enables these exports in the existing
real R06 native driver and checks their actual outputs from a separate metadata
reader UID. `tests/atrium_n04/publication_models.py` is only the invocation-owned
fixture worker; it neither changes the controller nor claims split N03 service
or live inference-hook coverage.

## Actual pinned native API findings

The N07 `pins.json` digest is authoritative; native package metadata and
`GET /openapi.json` both report **1.99.1**. `GET /health/readiness` contains health,
not a version. Routing is read from `GET /router/settings.current_values`.

- `/model/info` preserves `litellm_credential_name` but removes secret values.
  `/credentials` plus protected creation provenance establishes reference identity.
- `/key/generate` returns `token_id`/`token` hashes. `/key/info?key=<sha256>`,
  `/key/update` and `/key/block` accept the hash; no raw key is needed for
  reconciliation or retirement.
- `key_type: llm_api` **replaces** literal routes with `llm_api_routes`, which is
  too broad for a one-route template. Issue using `key_type: default` plus exact,
  nonempty `allowed_routes`, and verify native `/key/info` before exposure.
- Supported key router fields are `num_retries: 0`, `fallbacks: []`,
  `context_window_fallbacks: []`, `model_group_alias: {}`. Native key serialization
  drops `max_fallbacks` and `content_policy_fallbacks`; those are independently
  verified as `0`/`[]` in the global router. The controller never changes shared
  global routing to satisfy an owned key.
- Inference keys cannot create/update/delete keys or administer users/teams,
  including when `user_id` names a native `proxy_admin`. The fixture verifies
  the native human role and pairs each denial with inference success. A separate
  explicit-route controller key can manage objects but cannot infer.

### Credential readback across workers

Pinned 1.99.1 keeps a worker-local credential list. A successful credential POST
can be visible immediately to its writer while another worker's
`GET /credentials` returns HTTP 200 without that row until the default
30-second refresh. The [isolated readback diagnostic](../../tests/atrium_n04/READBACK.md)
observed exact convergence at 30.035 seconds without changing native polling,
authentication or credential metadata.

After its single credential POST, the controller requires exact metadata
readback within a 35-second convergence budget (one native refresh period plus
five seconds). It retries only GET reads, at most twice per second. Each read
uses the smaller of the remaining budget and the existing native transport
timeout; a response arriving after the budget cannot establish success.
Authentication, transport and malformed-response errors still propagate rather
than becoming a successful or empty readback.

Missing or different metadata after that budget still raises
`native_credential_not_applied`; pending ownership is not promoted and later
infrastructure actions do not proceed. The wait neither repeats the POST nor
accepts masked credential values as ownership evidence. Native cache settings,
poll intervals, roles, model ceilings and alias guards are unchanged.

## Acknowledged runtime service publication

`runtime_key_path` contains one atomically replaced **secret JSON** document:

```text
schema_version: 1
kind: atrium.litellm-service-key
installation, issuer, template_id
native_key_id: SHA256(token)
publication_id: unique 32-hex ID
expires_at: verified native UTC epoch expiry
token: runtime-only native secret
```

No example raw credential is stored in this repository. The publisher uses
exclusive creation, restrictive mode, file fsync, same-directory atomic replace,
and directory fsync. Secret paths inside any repository or the Nix store are
refused. The live file is `0600`, or `0640` for the consumer's read-only group.
The consumer has no write access to this directory or controller management state.

The running consumer reads the file per request, checks the token's actual
SHA256 and expiry, performs allowed inference, and **only after success** publishes
a non-secret acknowledgement:

```text
schema_version: 1
kind: atrium.litellm-service-key-ack
installation, issuer, template_id, native_key_id, publication_id
acknowledged_at: UTC epoch seconds
```

The acknowledgement is owned by the configured consumer UID. Use a separate
consumer-writable directory and `0640` consumer-group file; the controller can
belong to that read-only group without giving the consumer controller privileges.
Its hash/publication identity must match the actual replacement; a filename,
old acknowledgement, or forged new publication ID does not confirm delivery.

The previous key is retired at the durable **acknowledgement + overlap** deadline.
Repeated runs do not restart overlap. The timer has one-second scheduling
granularity; native requests have bounded timeouts. Missing acknowledgement,
publication/read failure, or native failure retains the last working key and
reports failure; no successful bounded-retirement claim is made during those
failures. Native expiration still applies. A journaled unpublished key is revoked
or confirmed absent on retry; a publication completed before a crash is recovered
by its exact file/native identity. State contains hashes, never escrowed raw keys.

There is no provider fallback, prompt/UI change, or assumption that process
environment/systemd credential snapshots update live. The native fixture runs a
long-lived consumer under another UID and observes both keys during overlap.
**Whiskey's actual text helper remains W03**, not replaced by this fixture.

## Operation, recovery, and validation

Use the existing UV environment/lock from the checked N07 harness:

```sh
uv run --frozen --project "$ATRIUM_N07/resolver" python -m pytest \
  -c "$ATRIUM_N07/resolver/pyproject.toml" tests/atrium_n04/test_controller.py \
  -q --assert=plain --tb=short --basetemp=.atrium-n04-state/pytest

uv run --frozen --project "$ATRIUM_N07/resolver" python \
  tests/atrium_n04/native_runner.py --harness "$ATRIUM_N07" \
  --spec "$ATRIUM_OWNER_SPEC" \
  --evidence tests/atrium_n04/results/<new-run>.json

nix build --no-write-lock-file --builders '' --no-link \
  .#atrium-litellm-controller .#checks.aarch64-darwin.atrium-n04-units
```

The supervisor reuses N07 at `d373d7c6b6d944b2e09eb93ad540803c10fdf206`, including
the original native bootstrap/provider and exact-ID cleanup. Source code and
generated secrets enter the additional owned controller container via attached
stdin. Required credential files are private runtime files under `/run`, outside
all repositories/stores. Database/model/provider fixtures are synthetic; no paid
provider, household account, or production service is used. Evidence records the
owner spec hash, component/source revisions, N02 output, image/platform/package,
paired statuses, provider counters and resource cleanup without native bodies.
The unchanged provider runs twice with distinct synthetic account credentials;
permits verify the expected account and denials leave both counters unchanged.

The opt-in unit does **not** initialize missing state at startup or deploy.
After isolated runtime inputs and a fresh trusted snapshot are explicitly
provisioned, a new installation can be initialized once:

```sh
atrium-litellm-controller init --config /etc/atrium/n04-controller.json \
  --confirm-new-installation atrium-n04-fixture
atrium-litellm-controller reconcile --config /etc/atrium/n04-controller.json --dry-run
```

Run under the provisioned controller identity with its separately delivered
management credential. Restore the protected inventory and its lock from a
trusted backup after loss/corruption; never regenerate it from desired names or
run initialization over a damaged installation. Retain snapshot generation
high-water marks. Pending native identities are retried individually. No global
key deletion, broad prune, or VM modification is part of recovery. The fixture
unit is evaluation-only here; N03 owns durable live backup/alert/access wiring.

## Gate reporting

Native results are controller slices, not unit-fixture gate claims:

| Gate | Actual N04/native coverage | Remaining integration |
| --- | --- | --- |
| T5 | Personal permit / family-model denial, zero provider requests on denial | R06 real broker |
| T13 | Same-team child designated permit / adult-model denial; live permission repair | R06 real policy/issuance |
| T19 | New runtime key survives; complete selected unowned rows unchanged; removed-template hash disabled; missing/corrupt state refuses | N05/R06 integrated adapter |
| T22 | Owned native binding create/update; wrong backend/account or shared binding refuses without mutation | Continuous N05 admission scope is separate |
| T29 | Real controller + running consumer, atomic replacement, bound acknowledgement, overlap, old-key denial, delivery/read/native-failure twins | W03 actual helper and N03 activated units |
| T30 | Native key/user/team write and read-management denials with an actual human native admin; separate management-only control key | N05 all-protocol/worker/cache matrix |

N05 admission, signed-feed outages/revocation fallback, multiple workers, warm
output caches, streaming/other inference protocols, real R06 broker integration,
and W03 are **not implemented or claimed** by this ticket. The full gate remains
blocked on those owners.

### Executed, revision-bound evidence

Implementation: `ae51fdfb8eff63ce76021ad93d99133fb3345efd`.
Validated controller/fixture revision: `bd0e871510502bcf88e11dc2877c5bd5ddbe5318`
(explicit non-secret state-digest representation; controller unchanged).
Native evidence: `tests/atrium_n04/results/n04-native-bd0e8715.json`.
The committed controller/harness source hashes and the owner's current spec SHA256
`7948bf3e47a1098db984bfd23e0b660d8fd0b818c317611e4de30d824536939e`
are included in that report. The owner document was unchanged throughout the runs.

| Validation | Observed result |
| --- | --- |
| Existing pytest/UV runner, `tests/atrium_n04/test_controller.py` | **44 passed** |
| Real N04 + pinned native harness, committed source above | **17 executed controller cases passed** |
| Native key/user/team management | **12 HTTP 403 denials**, each with a same-key inference permit |
| Live service consumer | **35 concurrent successful reads**, old/new identities observed without restart |
| Synthetic provider accounts | **73 received = 73 authorized**: personal account 68, family account 5; denial deltas zero |
| Isolated Nix unit evaluation | **12 assertions passed**, not activated-unit runtime evidence |
| Exported Nix package + `checks.aarch64-darwin.atrium-n04-units` | **Built successfully**, local builders only |
| Installed package CLI | `--help` executed successfully |
| Original repository pre-commit hooks | **Passed**; non-applicable shell/YAML checks skipped |
| Native resource cleanup | **Six owned containers and the owned network removed**; cached images retained |
| Foreign resource observation | `ambit-db` ID `a914bf6c7045` remained `running`, unchanged before/after |
| Production/source preservation | Live LiteLLM/Forge configuration and `flake.lock` unchanged; no push, PR, merge or deployment |

The exact native invocation was:

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --frozen \
  --project /Users/ryan/src/atrium-n07/resolver python \
  tests/atrium_n04/native_runner.py \
  --harness /Users/ryan/src/atrium-n07 \
  --spec /Users/ryan/src/atrium/docs/atrium-spec-v1.0.md \
  --evidence tests/atrium_n04/results/n04-native-bd0e8715.json
```

The successful normal build used the command above without `--offline`. Two
earlier offline attempts were interrupted after their logs showed Darwin
toolchain source bootstrapping; they are not counted as successful builds.
Normal substitution fetched three small official-cache build dependencies and
completed the exact package derivation, followed by the exported flake targets.
No dependency or native-image pin was changed to make the gate pass.

No amendment is proposed. T5/T13/T19/T29/T30 are reported at their executed N04
controller/native scope; parent R06, N05 and W03 must supply their real integrated
twins before claiming the complete adapter/promotion gate.
