# ATR-N01 — Ownership and adoption runbook

**Planning boundary: source-only artifacts, zero adoptions, no deployment.**
Read the [brownfield inventory](atrium-brownfield-inventory.md) first. This
runbook implements §5.3 / A.3(f) as amended by C2; it does not replace the locked
spec or implement N04's controller.

## Selected ownership mechanism

Use an **authoritative, protected managed-object inventory**, rather than
assuming LiteLLM v1.99.1 protects every team/alias metadata field.

- N04 maintains durable records for newly created managed teams and exclusive
  alias bindings, qualified by installation/environment and native identity.
  Records are written only by the controller/control plane under an OS/DB access
  boundary; clients and inference services cannot write them.
- R01/R06 persist the trusted native-key-ID/hash-to-grant association required
  by C3. Associate principal, domain, template, native team, expiry, optional
  device, and issuance provenance **before exposing a newly issued key**.
  Runtime issuance updates the inventory continuously, not only at deploy.
- State is outside the Nix store. Root/control-service-only write access and
  narrowly scoped read access for admission/reconciliation are required.
  Backups/recovery preserve identity and provenance; an absent or unreadable
  ledger is a control-plane failure, never an empty ownership set.
- Resolver/reconciler management credentials are separate from client and
  service inference credentials. Native key/user/team management endpoints
  must be denied to inference templates; model allowlists do not prove this.
- The actual state path, persistence API, service identity and permissions are
  N04/R01 interfaces to wire through N03, **not existing deployed paths**.
  This document and the fixture file are not that authoritative runtime state.

New keys still carry the mandatory metadata:
`cc.owner=command-center`, `cc.template`, `cc.principal`, `cc.domain`, and
`cc.expires`. These are machine identifiers, not renamed for branding.
Metadata is protected/corroborated by trusted issuance records. A native
`cc.owner` string received from an untrusted or unverified source is not enough
to adopt a key. If a key is already known as managed, missing or altered native
metadata cannot turn it into an exempt legacy key (C3). Retain its protected
issuance identity and apply the current template and deny policy; fail closed
if trusted authorization state cannot be resolved.

### Object identity and authority

| Object | Required ownership evidence | Insufficient evidence |
| --- | --- | --- |
| Team | Protected record for the exact native team ID, installation/environment, domain, and controller-created or explicitly approved adoption provenance | Team alias/name, a user's native admin role, owning one member key, or unprotected metadata |
| Key | Validated native key ID/hash plus protected issuance/adoption association and template binding; preserve the association when native metadata is missing | `key_alias`, a `cc.` prefix, team membership, principal name, or caller-supplied `cc.*` |
| Alias | Protected record for the exact alias scope and native model/deployment binding identities, including the complete reachable backend/account/domain set | Alias spelling alone, a single matching backend, disabled fallbacks, or an owned key referencing the alias |

N04 must map those identities to what v1.99.1 actually exposes. An alias may be
a set of deployments, not a separately addressable “alias row.” Do not assume
per-team alias isolation or a mutable native alias-ID API. Where the complete
binding identity or exclusive ownership cannot be established, refuse that
template/alias change; never fall back to matching by name.

An unowned/shared alias or team must not be edited as a side effect of repairing
an owned key. If the key's new template would require such an edit, refuse the
affected template and require a new exclusive object or explicit, identity-bound
owner approval. Inspect **all** reachable alias backends, including wildcard
expansion and native database additions, before accepting its domain/account
expectations.

## Source inventory and future dry-run discipline

For ATR-N01, the only inventory is the source snapshot. It neither reads nor
writes live rows. There is no runnable production inventory/reconciler command
in this ticket.

N04's future inventory/dry-run mode must produce a redacted proposed diff while
performing **zero** creates, updates, deletes, blocks/revokes, metadata
backfills, key rotations, credential publications, or ownership-ledger writes.
Do not use a management API that mutates on “ensure” or discovery. Report
unknown state rather than inventing an empty native inventory.

The allowlisted report fields are object kind, installation/environment, native
team/model IDs, native key ID/hash, alias/label, principal/domain/template
references, model/backend/account references, permission/lifetime/budget
differences, ownership provenance, and a non-secret approval reference.
Never report raw keys, authorization headers, signing material, provider-key
values, entire management responses, credential-bearing URLs, native auth
bundles, or runtime environment contents.

### Adoption checklist — all steps blocked for live objects in N01

1. Obtain owner authorization for a separately scoped inventory/adoption
   operation. No approval is implied by asking for this source inventory.
2. Under that authorization, obtain a redacted native-ID inventory through an
   approved isolated workflow or owner-supplied export. Resolve the exact
   installation, team, key, alias binding, and credential-account relationships.
   Do not infer canonical principals from email equality or ownership from names.
3. Record approval for **each object identity** and the intended domain,
   principal/service template, account/backend constraints, lifetime/budget,
   and legacy-consumer impact. Approval for a key does not approve its team,
   siblings, alias, or upstream credential. Renames do not transfer ownership.
4. Prefer newly created exclusive teams/aliases and newly issued credentials
   where a shared object would affect unadopted consumers. Existing matching
   names are collisions, not adoption instructions.
5. Exercise the proposed change against synthetic state with the real pinned
   adapter in N07. Compare unowned team, alias, and key objects before/after,
   including model sets, membership, permissions, budgets, expiry, and metadata.
   Redacted evidence must identify the component and fixture revisions.
6. Only after the paired gates and an explicit owner cutover decision may the
   responsible later ticket change production. Persist approved identity-bound
   provenance before reconciliation. Never retroactively mark a failed or
   ambiguous issuance as safely owned by its display name.

Nothing in these steps authorizes changing current LiteLLM objects, Whiskey
PAT/session routes or provider credentials, Home MCP refresh grants, or other
household services. No signing or management material is created here.

## Reconciliation fixture handoff

[Ownership scenarios v1](fixtures/atrium-reconciliation-ownership-v1.json) is
synthetic **test data**, not an implementation, API payload, registry schema,
live snapshot, or R04 credential profile. Native IDs, fixture principals, and
account references use `fixture-*`; the domain strings are the two phase-1
domains. No token secrets are included.

The fixture has a catalog of observed objects, a separate protected inventory,
templates, and independent cases:

- Each case selects observed objects and trusted inventory entries by catalog
  reference. Unselected objects do not exist in that case's native fixture.
- `observed_overrides` replace the named top-level fields; they do not modify
  protected entries. This deliberately models tampering and identity mismatch.
- `active_templates` selects the current ceiling. Native keys are not a
  deploy-time desired-key list; a newly minted authorized key is still valid.
- `required_actions` and `must_preserve` describe expectations, not operations
  this JSON executes. `inference_after` is an assertion for a future real-adapter
  run, **not a measured result**. Preservation means all native fields unchanged,
  not just retaining an ID.
- Synthetic alias `native_id` values stand for stable binding identities that
  the real adapter must map to native deployment IDs/scope. A null identity
  models an unsupported/unverified mapping, not permission to use its name.

| Case | Required distinction |
| --- | --- |
| N01-01 | Inventory/dry-run is non-mutating, even with obsolete managed keys present |
| N01-02 | Owned and unowned teams with the **same name** have different native IDs |
| N01-03 | Post-deploy authorized runtime key survives; same-name unowned key and unowned member of an owned team remain untouched |
| N01-04 | Removed-template owned key stops working; unowned key is not disabled |
| N01-05 | Verified exclusive in-domain alias succeeds |
| N01-06 | Same-name shared/unowned alias binding prevents implicit alias adoption/rewriting |
| N01-07 | Owned key needing a change to an unowned team cannot widen that team |
| N01-08 | Familiar names and self-asserted `cc.owner` do not confer ownership of any object type |
| N01-09 | Erased metadata on a known managed key is not a legacy exemption |
| N01-10 | Missing protected inventory stops reconciliation without writes |
| N01-11 | Same native ID in a different installation is not the owned object |
| N01-12 | Missing native alias identity cannot be repaired by matching its name |

### Validation and gate status

Source-only checks, run from this ticket's nix-config worktree:

```bash
python3 -m json.tool docs/services/fixtures/atrium-reconciliation-ownership-v1.json >/dev/null
git diff --check
mkdocs build --strict
```

The MkDocs command is the existing `.github/workflows/docs.yml` build; its
dependencies are pinned in `docs/requirements.txt`. No NixOS service definition
changes here, and no remote-build/apply command is appropriate for source-only
documentation. JSON syntax/catalog checks cannot validate a reconciler.

**T4: BLOCKED (both twins unexecuted).** N03/N06/N07 must demonstrate authorized
proxy success and refused direct-backend access from the isolated untrusted
network; loopback declarations are not runtime evidence.

**T19: BLOCKED (both twins unexecuted).** N04/R06/N05/N07 must run the real
v1.99.1 adapter: a removed-template key must fail inference; a key minted since
the last deploy must still work; unowned teams/aliases/keys must remain unchanged.
Fixture scenarios and a green documentation build do not complete this gate.
