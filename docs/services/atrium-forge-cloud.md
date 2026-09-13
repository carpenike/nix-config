# ATR-N03 — Cloud-first Forge registry and adapter wiring

This is **build/deployment wiring, not a live activation or completed native
gate**. It stacks on PR1086 at
`b47cee4dff8d55afc6b111399477ad366c3d0edb`. The prior foundation evidence is
retained in [atrium-forge-runtime.json](evidence/atrium-forge-runtime.json).
The [source-bound cloud receipt](evidence/atrium-forge-cloud.json) records the
implementation commit, exact artifacts, owner-data preservation and blocked checks.

C9 was accepted by Ryan and merged in Atrium PR40 at
`21a4df41ccdc52eb2282387816b3e164c1e32c3c`. The locked specification remains
SHA-256 `7948bf3e47a1098db984bfd23e0b660d8fd0b818c317611e4de30d824536939e`;
it is neither modified nor copied here. There is **no local-model prerequisite**.

## Authoritative declarations

[`hosts/forge/atrium/registry.nix`](../../hosts/forge/atrium/registry.nix)
is the complete concrete permission ceiling. It consumes the actual cloud
inventory in `hosts/forge/services/litellm.nix` and the pinned Home MCP
source-exported catalog. It never creates a parallel tool catalog.

The app module renders `renderForGateway` for **v1.100.1**, producing:

```text
/etc/atrium/desired-state/registry.json
/etc/atrium/desired-state/resolver.json
/etc/atrium/desired-state/home-mcp.json
/etc/atrium/desired-state/litellm.json
/etc/atrium/desired-state/whiskey.json
/etc/atrium/desired-state/sidecar.json
```

All six documents have `schema_version: 2`, `phase: 1` and
`environment: "production"`. The resolver document contains canonical
principals/authority bindings, group eligibility, devices, source catalogs,
instances, route/model templates, provider/credential references, owned
teams/aliases/backends, exceptions and ownership rules. The adapter documents
are generated projections, not independent permission ceilings.

The resolver always reads `/etc/atrium/desired-state/resolver.json`.
There is no external-policy fallback and no installed `registry-base.json`
fragment. `/var/lib/atrium-policy/model-policy.json` is only an atomic,
root-provenance copy of that generated policy for the admission loader's
protected-file contract. Runtime services cannot rewrite either ceiling.

### Ordinary permissions

* Ryan is the only human enrolled by the declared bootstrap. His reviewed
  Pocket ID subject and `admin`/`adult` roles are preserved.
* `personal:ryan` and `family:holt` are separate wings. Eligibility groups are
  `atrium-personal-ryan` and `atrium-family`. An operator must create/assign
  their actual Pocket ID memberships. Nix group lists confer no membership.
* Group-only ACLs require fresh, verified Pocket ID evidence at authorization.
  Bootstrap creates **no group observations**, token claims or native grants.
  Missing group evidence denies access; there is no principal-ACL shortcut.
* Personal data uses source scope `atrium-personal-read`; Family household
  information uses `atrium-family-read`. Both must be source-classified
  read-only exports. Existing writable `admin`, `advisor` and `hermes` maps
  retain their original definitions and are not assigned to Family.
* Whiskey's companion permits only `read` and `write`, still intersected with
  native rights per operation. It grants no `host` projection. No
  infrastructure administration, shell, generic filesystem or household-control
  write is declared.
* `rymac` remains an eligibility declaration, not an enrolled certificate.
  No local filesystem instance or phase-3 client is added.
* C9 permits later per-human Personal wings, including children, but this
  registry creates no real child account. Child enrollment requires its own
  identity, Personal ownership, source-enforced resources, same designated
  backend across its separately bound wing aliases, and the accepted explicit
  emergency ceiling. No standing parental/emergency grant is seeded here.

`bootstrap.nix` emits a strict real-app enrollment document, an ordinary
`PolicySeed`, a separate optional Opus seed, and a non-authorizing group
provisioning description. Ordinary grants are nondelegating, subordinate
standing grants; each credential remains lifetime/budget/native-rights bounded.
Nothing applies them at boot.

### Cloud bindings and budgets

| New managed alias | Exact configured backend | Use |
| --- | --- | --- |
| `cc.personal.ryan.sonnet` | `anthropic/claude-sonnet-5` | Personal default and Whiskey text |
| `cc.personal.ryan.opus` | `anthropic/claude-opus-5` | Explicit adult selection only |
| `cc.family.holt.haiku` | `anthropic/claude-haiku-4-5-20251001` | Initial Family/designated child model |

Teams are new `cc.personal.ryan` and `cc.family.holt` objects. Backends and key
templates also use new `cc.*` identifiers. Each client template allows only
one alias. Opus is absent from the ordinary seed and has a separate target and
explicit `atrium-select-opus` operator action. No alias has fallback edges.

Client keys: **USD1 per key per 3600 seconds**, native lifetime at most
3600 seconds. Whiskey's service key: **USD2 per 86400 seconds**, native lifetime
604800 seconds, rotation interval 86400 seconds, acknowledged overlap
3600 seconds. These are not aggregate monthly or account-wide spending caps.

Personal and Family inference material have distinct source references:

```text
/run/secrets/atrium-personal-anthropic
/run/secrets/atrium-family-anthropic
```

Systemd delivers them only to the controller as `personal-anthropic` and
`family-anthropic`. The registry references those private credential paths.
The account names `atrium-personal-ryan-anthropic` and
`atrium-family-holt-anthropic` are **new logical purpose/ownership declarations**,
not discovered provider billing identities. Provision separately owned material;
do not copy an existing Personal raw key into Family. No credential fingerprint,
provider receipt, existing account adoption, or raw/encrypted secret is fabricated.

Resolver and controller management sources are separately declared as
`atrium-litellm-resolver-management` and `atrium-litellm-controller-management`.
Neither reuses an inference credential or silently adopts `litellm/master_key`.
Use the existing SOPS provisioning mechanism; absent material is an operator
prerequisite, not a reason to weaken or externalize the Nix policy.

## Public and private bindings

| Surface | Binding |
| --- | --- |
| Resolver | `https://atrium.holthome.net` → `127.0.0.1:18765`, Caddy UID239 only |
| Identity resource | issuer `https://id.holthome.net`, audience `https://atrium.holthome.net/resolver` |
| Device registration | LAN `https://forge.holthome.net:19443`, `10.20.0.30`, `enp8s0` |
| Device TLS backend | `127.0.0.1:18766`, byte-forwarder UID1062 only; actual TLS terminates in resolver |
| Native issuance | conditional direct TLS `https://127.0.0.1:9200/cc/issue`; actual resolver leaf required |
| Native current policy | conditional direct mTLS `https://127.0.0.1:18767/v1/native-policy`; native peer only |
| Models | `https://llm.holthome.net`; adopted gateway binds `127.0.0.1:4100`, Caddy only |
| Whiskey | `https://whiskeywhiskeywhiskey.org/cc/mcp`; retained native audience remains `/api/mcp` |

Public Caddy rejects service-only issuance/policy and device-registration paths
and strips claimed identity/certificate headers. Native authorization and the
Whiskey companion header are retained. Native TLS trust uses real nominated
public leaf certificates, checked for client purpose and validity; the runtime
renderer computes their fingerprints. It does not invent certificate enrollment.

At explicit native cutover, `/mcp` becomes the declared Personal read target;
the Family read view is `/cc/views/family-read`. This is **not** an implicit
migration of every existing client or refresh grant. Review each affected
client, the bounded native migration window and explicit identity/hash mappings
before enabling it. Until then, the existing native service behavior is unchanged.

## Adoption, custody and live publications

All four `services.atriumForge.adoption` switches default to false:
`models`, `native`, `whiskey`, `whiskeyText`. Static configuration/reference
documents and foundation/model preparation commands exist without adoption.
Native/Whiskey first-use units appear with their selected configuration but
remain manual-only; normal startup refuses missing security history.
Whiskey route adoption requires its text adoption; text adoption requires models.

The LiteLLM image stays exactly:

```text
ghcr.io/berriai/litellm:v1.100.1@sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf
```

Existing wildcard/friendly aliases, provider environment, database, master/salt
state, UI authentication and unowned native teams/keys are not reconciled or
adopted. The opt-in gateway transport change requires clients to use its Caddy
origin, not the old container bridge alias. Inventory any such direct consumer
before approving that boundary. Its existing writable data directory is retained;
the non-root adopted process receives a separate protected native-data directory.

| Identity | Custody / membership |
| --- | --- |
| Resolver UID1060 | Private identity/signing/deny/model state; metadata GID1065 |
| TLS custodian UID1061 | Private six-authority TLS plan; no metadata/token group |
| Registration UID1062 | TLS bytes only; no credential/state access |
| Controller UID1063 | Private ownership ledger; metadata GID1065 and delivery GID1066 |
| Gateway UID1064 | Private admission history; metadata GID1065, **no token group** |
| Adopted Whiskey UID1067 | Own application state and delivery GID1066, **no metadata group** |

Resolver and controller own separate mode2750 publication directories under
`/run/atrium-publications`; files are their real mode0640 producer publications.
No root/chown relay, shared signer UID or systemd credential snapshot publishes
these documents. The gateway mounts neither producer-private state nor delivery
tokens. Controller bindings appear only after actual native reconciliation/readback.

Whiskey reads `/run/atrium-delivery/whiskey/key.json` live and publishes successful
delivery acknowledgements to `/run/atrium-acknowledgements/whiskey/key.json`.
The controller keeps the working key until acknowledged delivery and bounded
overlap. Without text adoption, reconciliation uses `--no-rotate`; it does not
mint a service key for an unadopted consumer.

Image exceptions have separate new Personal credential references. The image
environment generator handles only OpenAI/Gemini/OpenRouter material; the rotating
text service key never goes through it. Adopted Whiskey removes direct
`ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL` values and has no direct text fallback.

### Egress

The production boundary is IPv4 address-and-port enforcement, **not hostname
attestation or provider modality isolation**. Nix must contain reviewed exact
addresses for the declared fixed hosts and hostname-only calendar/media/Web Push
and redirect inventories, plus exact DNS resolver addresses. IPv6 egress is
denied for this adopted consumer. Rules update atomically and default-deny
everything else. There is no wildcard, dynamic DNS widening or broad Internet
exception. Shared provider IPs remain a stated limitation.

Those dynamic destinations were unknown in the source-only N01 inventory.
`whiskeyEgress` therefore intentionally has no fabricated addresses or capability
URLs. Text adoption fails evaluation until the operator supplies the complete
reviewed bindings. Native N06 permit/deny evidence remains required.

## Explicit initialization and recovery

After separately authorized deployment/provisioning, the installed manual-only
units use actual package interfaces:

1. `atrium-initialize` and `atrium-trust-initialize`: owner/service enrollment,
   signing, and separate TLS custody. Neither repeats or runs on boot.
2. `atrium-seed-policy`: ordinary grants only. Establish fresh verified group
   evidence through the real Pocket ID flow; the seed cannot manufacture it.
   `atrium-select-opus` is a separate optional adult action.
3. `atrium-model-resolver-initialize`: publish from real initialized resolver
   state. `atrium-model-controller-initialize`: initialize the actual ledger
   and its real initial service publication. `atrium-model-admission-initialize`:
   initialize actual admission history. None performs native management writes.
4. Native adoption additionally needs operator-owned `native-profile.json`,
   native/resolver public JWKS continuity and a `native-adoption.approved`
   receipt in `/var/lib/atrium-policy`. `atrium-native-deny-initialize` invokes
   the actual deny store without starting Home MCP or migrating refresh grants.
5. Whiskey adoption needs explicit data/UID custody review, credentials/egress
   bindings and `whiskey-adoption.approved`. `atrium-whiskey-deny-initialize`
   invokes the actual compiled deny store without starting household services.
6. Model activation requires durable `model-adoption.approved`. Removing the
   adoption switch while that marker remains refuses gateway startup rather
   than silently running owned keys without admission.

These are operator commands, **not commands executed by this change**. Existing,
partial or mismatched security state is a recovery condition, never permission
to initialize an empty replacement. Normal units assert the actual private
association/ledger/deny files before startup. Missing group evidence, native
rights, trust, credentials or current publications remains a denial.

Five Atrium datasets are critical: resolver, trust, policy, reconciler and
gateway admission. Each has local snapshots, replication, encrypted NAS/offsite
backups and `allowEmptyBootstrap = false`; no automatic restore resets security
history. Baseline guard totals are 55 classified datasets, 65 snapshot datasets,
73 backup jobs and 150 guarded timers, with per-dataset/per-timer assertions.
Native and Whiskey adoption additionally classify their existing state as
critical and add offsite security-history coverage. Alerts cover service failure,
TLS custody, reconciliation and stale model publications.

Recovery remains the independent Nix/SSH path. Restore matching identities,
signers, deny generations, ownership ledgers and adapter state together. Never
clear adoption markers, lower clocks/generations or regenerate history to make
a health endpoint green. TLS renewal, JWKS rollover and native cutover are
explicit operator work.

## Validation and remaining integration

Focused checks use the existing Nix runner with
`--option allow-import-from-derivation false`: identity bootstrap, cloud schema/
real certificate binding refusals, N03 fixture composition, Caddy syntax and
protection coverage. They are not new native T-cases.

Complete policy validation and the remote build require the parent's final
immutable C9 runtime and native MCP revision/catalog. This branch currently
pins the explicitly supplied combined bootstrap/C9 source
`840e0777505febefe5a9296ae621451aac70172a`; that is not a claim of final C9
runtime qualification. The baseline MCP pin
`23de14d586c668e1662294ff1f2a8d5da265cf24` lacks `atrium-personal-read` and
`atrium-family-read`; the real registry validator correctly refuses it.
Do not manufacture those scopes, swap in the synthetic M03 catalog or
relax validation. Whiskey remains at `273cf414cac75276492ee849bb3ea257ce47f8de`
until an explicit update is supplied.

Full Forge compilation uses only:

```sh
task -d /Users/ryan/src/nix-config-c9-cloud nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

No `naf`, apply/switch, Pocket ID write, production key/team operation, native
refresh migration, household restart or paid model call is authorized here.
ATR-N02/N03/N04/N05/N06 native paired gates and C9 native acceptance remain
the parent's integration work; this deployment branch does not claim them done.
