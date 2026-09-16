# ATR-N03 — Cloud-first Forge registry and adapter wiring

The accepted C10 follow-up is documented in
[C10 group-evidence configuration](atrium-c10-groups.md). Client admission is
explicit and currently unconfigured. A source-bound native/helper receipt is
now supplied and qualified appca is selected; final coordinated MCP/vendor
inputs and the full C10 build remain separate from the C9 history below.

This is **build/deployment wiring, not a live activation or completed native
gate**. It stacks on PR1086 at
`b47cee4dff8d55afc6b111399477ad366c3d0edb`. The prior foundation evidence is
retained in [atrium-forge-runtime.json](evidence/atrium-forge-runtime.json).
The [source-bound cloud receipt](evidence/atrium-forge-cloud.json) records the
implementation commit, exact artifacts, owner-data preservation and blocked checks.
The later [host-review receipt](evidence/atrium-forge-host-review.json) records
the independently verified container-health correction and R05
canonical-identity/private-transport fix. App806 now supplies the exact
additive interface and its strict adopted-config schema checks pass. The
review receipt records the corrected full-build result separately; historical
build receipts are not activation evidence for those corrected paths.
The [final-input receipt](evidence/atrium-forge-final-inputs.json) records the
final coordinated MCP/app source set and its deployment validation separately,
without rewriting those historical receipts.

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
  The selected exports contain 20 Personal tools and 9 Family tools, with
  zero resources in each. The Personal set covers bounded purchase, Fidelity
  and Paperless reads; it excludes `finances_*`/`finances://` paths whose
  transitive helpers can sync, refresh git state or write caches.
  These native datasets are not selected or row-filtered by Atrium principal.
  The current view is authorized only for Ryan's existing configured data;
  neither this scope name nor a Personal wing label makes it suitable for
  every human or child. See the pinned MCP `docs/ATR-M03-READONLY.md`.
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

On the pinned LiteLLM version, the **Management** key preset grants
`management_routes` but omits `/credentials` and `/router/settings`, both
required by the controller. Its allowlist must include those two explicit
paths alongside `management_routes`; do not substitute unrestricted inference
or master-key access. The resolver needs `/key/generate`, `/key/info`,
`/team/info` and `/key/delete`, which are included in `management_routes`.
The key's native owner must also have the required administrative authority:
the route preset does not grant an owner role. The isolated qualification uses
separate native `proxy_admin` control identities, never the end user's
inference key.

Changing an existing key's route permissions does not change its bearer value.
Update SOPS only if the native key itself is replaced or rotated.

### Fill the prepared SOPS fields

Open `hosts/forge/secrets.sops.yaml` with the SOPS editor from this checkout:

```sh
sops hosts/forge/secrets.sops.yaml
```

The `atrium` section is pre-created with intentionally empty strings:

```yaml
atrium:
  personal_anthropic_api_key: ""
  family_anthropic_api_key: ""
  litellm_resolver_management_key: ""
  litellm_controller_management_key: ""
```

Replace each empty value with the appropriate credential only inside the SOPS
editor. The first two are distinct Anthropic platform API keys; the last two
are separate, appropriately scoped LiteLLM management credentials. Do not paste
values into chat, shell arguments, documentation or an unencrypted file, and do
not reuse `litellm/master_key` or another application's provider key implicitly.

`hosts/forge/secrets.nix` maps these keys to the four flat `/run/secrets/atrium-*`
paths above with root-only `0400` custody. They are declared when the Atrium
foundation is enabled, independently of model adoption, so real values can be
staged before explicit model initialization. Empty values are not working keys.

The scaffold does not enable any adoption switch, initialize model state, or
create/update native keys, teams or aliases. Secret updates do not restart any
service while model adoption is off. Once models are explicitly adopted,
updates restart only the matching resolver or reconciler consumer; initializer
units are never automatic restart targets. Existing secret entries and service
bindings remain separate.

## Public and private bindings

| Surface | Binding |
| --- | --- |
| Resolver | `https://atrium.holthome.net` → `127.0.0.1:18765`, Caddy UID239 only |
| Identity resource | issuer `https://id.holthome.net`, audience `https://atrium.holthome.net/resolver` |
| Device registration | LAN `https://forge.holthome.net:19443`, `10.20.0.30`, `enp8s0` |
| Device TLS backend | `127.0.0.1:18766`, byte-forwarder UID1062 only; actual TLS terminates in resolver |
| Native issuance identity | canonical `https://mcp.holthome.net/cc/issue`; issuer and signed audience remain canonical |
| Native issuance transport | conditional direct mTLS `https://127.0.0.1:9200/cc/issue`; actual resolver leaf required |
| Native current policy | conditional direct mTLS `https://127.0.0.1:18767/v1/native-policy`; native peer only |
| Models | `https://llm.holthome.net`; adopted gateway binds `127.0.0.1:4100`, Caddy only |
| Whiskey | `https://whiskeywhiskeywhiskey.org/cc/mcp`; retained native audience remains `/api/mcp` |

Public Caddy rejects service-only issuance/policy and device-registration paths
and strips claimed identity/certificate headers. Native authorization and the
Whiskey companion header are retained. Native TLS trust uses real nominated
public leaf certificates, checked for client purpose and validity; the runtime
renderer computes their fingerprints. It does not invent certificate enrollment.

R05's configured `endpoint` remains the canonical issuance URL above.
The additive `transport_endpoint` selects only the actual private mTLS
connection. It cannot change the response issuer, resource target, audience,
verification keys or native authorization. Redirect, TLS and identity
fallbacks are not introduced. The host consumes the parent-owned feature at
`806ae19e853ae5614523430f5fc2397786fd9839`. Strict schema checks verify the
canonical endpoint/derived issuer and the separately resolved private request
endpoint. The historical `rq34…` artifact predates this fix
and remains build-only historical evidence, not activation qualification.

At explicit native cutover, `/mcp` becomes the declared Personal read target;
the Family read view is `/cc/views/family-read`. This is **not** an implicit
migration of every existing client or refresh grant. Review each affected
client, the bounded native migration window and explicit identity/hash mappings
before enabling it. Until then, the existing native service behavior is unchanged.

## Adoption, custody and live publications

All four `services.atriumForge.adoption` switches default to false:
`models`, `native`, `whiskey`, `whiskeyText`. The owner-selected
[`adoption.nix`](../../hosts/forge/atrium/adoption.nix) now opts Forge into
**models only**; Home MCP, Whiskey routes and Whiskey text remain off.
Removing that concrete selection still exercises the actual unadopted module
defaults in the preparation checks. Static configuration/reference
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

Before each reconciliation, the controller republishes its retained service
associations through the actual N04 ledger/publisher under UID1063. This follows
credential projection and precedes native management calls, which themselves
need fresh admission publications. It advances the publication generation, not
credential expiry or permissions. Missing, corrupt or mismatched history fails;
the pre-start path never initializes an empty replacement. The resolver is an
explicit startup dependency and publishes its own associations independently.

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
2. `atrium-seed-policy`: ordinary grants only; the seed cannot manufacture group
   evidence. C10 is accepted; group-dependent use still requires explicit
   admitted public clients and a qualified carrier. Requesting `openid groups`
   alone does not fix the resource access JWT. `atrium-select-opus` remains a
   separate optional adult action, subject to the same group ceiling.
3. `atrium-model-resolver-initialize`: publish from real initialized resolver
   state. `atrium-model-controller-initialize`: initialize the actual ledger
   and its real initial service publication. `atrium-model-admission-initialize`:
   initialize actual admission history. None performs native management writes.
   The resolver and controller initializers project only their own management
   credential before entering the bootstrap program. The adopted reconciler
   separately projects its controller credential and the two wing provider
   credentials. All use service-owned `0700` volatile directories and `0400`
   files, with cleanup on stop/failure; the strict application readers and
   persistent initialization/refusal history are unchanged. See
   [credential custody](atrium-forge-runtime.md#foundation-and-model-credential-projection).
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

### Owner-run model-only activation

The owner approved preparing model-only activation on 2026-09-16 and reported
that this is a new environment with no other clients. No direct-client
migration is needed for that inventory. Existing native objects are still
unadopted; matching names are not permission to overwrite or delete them.
The completed resolver/controller/admission initialization must be preserved.

After reviewing and merging the activation PR, pull the deployment checkout.
Before `naf` or the automatic upgrade consumes this selection, explicitly
record approval on Forge. This is a non-secret operator receipt, not a token,
a generated grant or an automatic Nix activation artifact. The command refuses
an existing receipt and checks the initialized prerequisites; it does not
initialize, reset, reconcile or call a provider.

From a Bash/Zsh terminal in `~/src/nix-config`:

```sh
nix eval --json .#nixosConfigurations.forge.config.services.atriumForge.adoption |
  jq -e '. == {models: true, native: false, whiskey: false, whiskeyText: false}' &&
ssh forge 'sudo -n sh -eu' <<'SH'
grep -qx atrium-forge /var/lib/atrium-resolver/models/initialized
for path in \
  /var/lib/atrium-resolver/models/associations.json \
  /var/lib/atrium-resolver/models/admission-associations.json \
  /var/lib/atrium-reconciler/ownership.json \
  /var/lib/atrium-model-gateway/admission/initialized \
  /var/lib/atrium-model-gateway/admission/admission-state.json; do
  test -s "$path"
done
receipt=/var/lib/atrium-policy/model-adoption.approved
test ! -e "$receipt"
test ! -L "$receipt"
umask 077
set -C
printf '%s\n' \
  'installation=atrium-forge' \
  'operator_approval=models-only' \
  'native_objects=controller-created-cc-only' \
  'home_mcp=false whiskey=false whiskey_text=false' \
  "approved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$receipt"
sync -f "$receipt"
SH
```

Only after that command succeeds, deploy from the usual shell:

```sh
naf
```

Activation enables the broker, owned-object reconciler and admission hook.
It can create the declared new teams, aliases and provider bindings. Client
keys are issued only through their templates; the unadopted Whiskey text
service is still not issued a rotating key. Use `https://llm.holthome.net`,
not a direct container/loopback endpoint.

Do not repeat the initializers to refresh expired publications: normal
producers now do that from retained history. If activation fails, preserve the
receipt and all history rather than clearing them or switching to an
unprotected gateway. Fresh operator login/group evidence is still needed for
subsequent authorized client requests; this approval does not grant it.

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

### R01 group-carrier dependency — accepted C10, explicit admission required

On 2026-09-13 the parent reported verified Pocket ID2.14 measurements from
network-config PR37 at `4ed8810`, native measurement source `f17c887`:
11 completed measurements, the expected blocked exit status2, and complete
cleanup. This deployment branch did not rerun those probes, read their raw
tokens or modify the identity provider. These references are measurement
provenance, **not replacement Atrium or Home MCP deployment pins**.

The resource access JWT contains no groups, including when requesting
`openid groups`. The separately signed ID token contains group names and
an `at_hash` binding to the exact access token. Userinfo contains live but
unsigned group data without source `iat`/`exp`.

The current access-token group carrier therefore cannot supply the required
fresh verified membership. Identity authentication or a green health endpoint
does not establish wing eligibility. **Missing group evidence continues to
refuse group-dependent access.**

C10 (Atrium PR42, proposal `c3089ff`, acceptance `e8e4d54`) is accepted for
separately verified signed group evidence. This branch adds the narrowly typed
operator admission setting described in the C10 guide. Qualified immutable
runtime/native inputs and actual admitted public client IDs are still needed
before activation. Do not reinterpret ID tokens as access bearers,
use unsigned userinfo as a fallback, seed observations, or add direct human
principal ACLs to make access succeed. All human instances, route templates
and client-model templates retain their exact group-only ceilings; the
cloud-schema check asserts them. No auth/group fallback is implemented here.

This is a runtime authorization/acceptance dependency, not a local-model or
raw-secret build prerequisite. `/etc/atrium/runtime/adoption.json` reports it
explicitly as operational metadata. Optional C10 Settings configure only the
selected authority's signed group-evidence admission; the resource bearer
authentication contract is unchanged.

### Build and native-source dependencies

Focused checks use the existing Nix runner with
`--option allow-import-from-derivation false`: identity bootstrap, cloud schema/
real certificate binding refusals and group-only ACL preservation, N03 fixture
composition, Caddy syntax and protection coverage. They are not new native
T-cases or evidence of C10 integration.

The current explicit candidates are:

| Component | Immutable revision | Qualification boundary |
| --- | --- | --- |
| Atrium PR43 | `806ae19e853ae5614523430f5fc2397786fd9839` | Corrected C9 core plus canonical/private R05 transport, not a full native C9 gate |
| Whiskey PR95 | `472f877952a363321c76ce580ce41dd0810e08b8` | Supplied canonical profile refresh |
| MCP PR78 | `ec1e796d1ae8bca9d8d16a11f00aebc22b5ba4e7` | Final app806-vendored head; native execution source `8ff9ee2ff1889fe0cfba5c21a702f1a9f1323789`, followed only by evidence |

The previously missing read-catalog exports are now present. Complete policy
composition (55 assertions), conditional adoption wiring (32), and both
retained/adopted Caddy syntax checks pass without weakening the validator.
The adopted gateway now uses an explicit `publishPort = false` setting: an
empty list could not override the module's forced bridge mapping at the same
priority. Legacy bridge publication remains unchanged when not adopted.

The subsequent host review found that container probes still used the private
listener despite the external Gatus/Homepage URLs. The LiteLLM module now
exposes `healthUrl`, and the existing service factory uses that same command
for both `--health-startup-cmd` and `--health-cmd`. Adopted probes use
`https://llm.holthome.net/health/liveliness`; unadopted probes retain
`http://127.0.0.1:4000/health/liveliness`. UID1064 receives no firewall bypass.
Exact evaluated-command assertions cover both phases and both modes; the
existing smoke runner checks success, unhealthy status and transport failure.
These command-level checks are not a live network or native-admission gate.

The corrected app core addresses terminal emergency deny-removal resurrection,
rollback after native issuance, and the device-required emergency activation/
proof cycle. No registry or host-setting shape changed; the existing deployment
checks pass unchanged. The parent's 173 resolver and 19 targeted real local
cases remain separately attributed evidence rather than new deployment
T-cases. Corrected sidecar qualification is now parent-confirmed at 90/90 in
both modes; resolver package qualification also passed 863 cases.

App806 adds only the exact R05 endpoint/transport separation used by this host.
The parent reports 39 configuration/context/real-TLS transport/issuance cases
passing. Only the exchange network URL changes; issuer, signed audience and
native JWT target are never rewritten. Model, R04, child/device and emergency
runtime code remains identical to `6930938`, so its existing qualification
stays source-bound rather than requiring an evidence-only model repin.

Model/runtime qualification is complete on the same `6930938` runtime:
native execution `c56aa0ac3603b1a2278dca0a6fb9327813219dba`, with the separate
stacked PR44 report at `1c032d5d84f48eb550c9fdbbee22df6f46d80a6b`. The parent
confirmed all 20 real LiteLLM1.100.1 model groups: 38 permits, 15 no-effect
inference denies, 8 R06 refusals and 4 controller refusals, plus 107 host cases.
These counts are separate categories, not additive claims of new deployment
T-cases. Model/runtime source outside R05 transport is unchanged versus
`6930938`, so no additional model configuration or qualification is needed.
PR43's `87d42ca` is evidence-only; app806 is the separate runtime update
required for R05 transport.

Whiskey's documentation/evidence revision
`e3aba82bbf2634d59190c511230cab2d37afe6a1` records 132 properly classified cases:
1 artifact, 41 native-identity/companion authentication, 10 deny state/freshness,
31 operation classification, 39 trusted-fixture dispatch, and 10 retained
native MCP cases. The initial 42 are included, not additive. This is not a
runtime pin change or a full C9 deployment gate.

Final MCP vendors exact app806. The added host assertion checks its actual
`vendor/atrium-artifacts.lock.json` revision against the app input, rather than
trusting a label. Runtime code is unchanged between native execution source
`8ff9ee2` and evidence head `ec1e796`. The parent reviewed the five small runtime
files/provenance and reports 59 native cases plus five exact upstream R05 cases,
including canonical/private TLS, wrong CA/hostname, no fallback, physical
issuer/audience/target refusal and revoke-after-issue association/denial.
Native B1 retains the original emergency grant ID in the existing private
public-access/refresh bindings; no JWT wire change is introduced.

The coordinated app-consumer dependency is now consumed. Do not follow mutable
worktrees, manufacture scopes, swap in synthetic catalogs or infer per-human
dataset ownership. Parent native/AS qualification and this branch's Nix,
schema, smoke and build results remain distinct; AS conformance is being handled
by the parent and was not executed here. This branch does not claim production
activation or a new full gate by aggregating those different evidence layers.
Private app/MCP CI remains independently subject to the account startup
restriction; this branch does not rerun it or alter billing, settings or checks.

Before the host-review corrections, deployment commit
`c3b2f923ff7e62bb2d6fd330d06eb3e357ef90b4` passed the full remote Taskfile build
and produced this retained historical artifact:

```text
/nix/store/rq34rsn29nmdw9svpk15rgmp67ss5520-nixos-system-forge-25.11.20260630.b6018f8
```

The system artifact, its derivation and all six generated policy files were
verified in Forge's Nix store without activation. The resolver package pytest
phase passed 863 cases and skipped 19; this remains package-build evidence,
not the parent's full native C9 qualification.
Nine focused checks passed; exact paths and boundaries are in the source-bound
receipt. No full Linux closure was built on the Mac. Qualified C10 inputs and
explicit public client admission, separately coordinated AS/promotion work, and the documented
native data-ownership/operator-adoption prerequisites remain activation
boundaries.

After the host review, deployment commit
`a87db00352fb639ea13e53bad89125404c1dc86b` passed the strict app806
canonical/private R05 schema, nine focused checks (including 32 adoption
assertions and both real generated health commands), and the full remote
Taskfile build:

```text
/nix/store/zi8146m4lgav66bqhrqg2gp5mpi0wcrz-nixos-system-forge-25.11.20260630.b6018f8
```

The corrected artifact and six generated policy files were verified in Forge's
Nix store. Its resolver package phase passed 877 cases with 19 skipped. The
separate host-review receipt preserves the original receipts and records this
correction's exact artifacts. These results are still build/schema/command
evidence, not live activation, health-network proof or final native routed
broker qualification.

With final coordinated MCP input `ec1e796`, deployment commit
`471e7e7407ad4ca95f6e901ca0903671bcf73e46` passed all nine focused checks and
the full remote Forge Taskfile build:

```text
/nix/store/wp6blpsrpph0cxzhgw2sa4zsj3pxyhwz-nixos-system-forge-25.11.20260630.b6018f8
```

The final artifact, six policy documents and packaged native executable were
verified in Forge's Nix store. Its exact source/vendor/catalog bindings and
separately classified build/native evidence are in the final-input receipt.
No historic artifact was replaced or relabeled, no activation occurred, and
AS conformance was not executed by this deployment branch.

Full Forge compilation uses only:

```sh
task -d /Users/ryan/src/nix-config-c9-cloud nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

No `naf`, apply/switch, Pocket ID write, production key/team operation, native
refresh migration, household restart or paid model call is authorized here.
ATR-N02/N03/N04/N05/N06 native paired gates and C9 native acceptance remain
the parent's integration work; this deployment branch does not claim them done.
