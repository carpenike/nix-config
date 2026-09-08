# ATR-N03 — isolated foundation entrypoints

This is an unimported, synthetic foundation definition under
`tests/atrium_n03/`. It does not enable Forge, run a rebuild/switch/deploy,
provision production identities, decrypt live secrets, or change host/VM trust,
DNS, routes or firewall rules. The guarantee remains credential-scoped access
and accident prevention, not conversation/context isolation.

## Current C8 wiring slice

The stacked `atr/N03-native-policy-wiring` slice consumes accepted Atrium
`5f919f085ca0e77664b72d13e96ceeb0680688e4` and Home MCP
`338cbbdb990a5751d199f276c5d65b07730cd97d`; Whiskey remains
`273cf414cac75276492ee849bb3ea257ce47f8de`. C8 is **accepted and implemented**,
including current group-deadline enforcement. Its N03 wiring is now explicit:

* `atrium-native-policy.service` runs the actual `serve-native-policy` command
  at `https://127.0.0.1:18767/v1/native-policy` inside the owned namespace.
* Only the resolver role/UID shares its existing R01 state and signing ring.
  Native MCP and all other consumers receive no access to that database/key
  custody.
* Dedicated policy-server and native policy-client CA/certificate/key material
  is distinct from R05's resolver client at `/cc/issue`. Actual client
  fingerprints are inserted by runtime PKI provisioning; Nix stores references
  and an unfilled public configuration template, never key contents.
* `HOMELAB_MCP_ATRIUM_POLICY` names the exact private endpoint, retained
  authority, resolver issuer/JWKS, CA/client material and bounded timeout.
  Allowed service deployment/views/upstream OIDC audience are explicit.
* Caddy rejects `/v1/native-policy` on public resolver/native origins and still
  refuses public `/cc/issue`; it never acquires either service client key.

The public `/mcp` fixture keeps the existing explicit admin grant and adds the
existing source-derived `fixture.read` profile under the same synthetic
child/adult eligibility already used by the child view. This allows the real
native public OAuth/current-policy path to prove scoped reads and resources
without inventing a catalog or broadening a child's operation rights.

Independent preparation currently passes 29 isolated unit assertions, real
Caddy adaptation, scoped formatting/lint, immutable wheel/source checks and
runtime artifact preparation. **New native network rows are not yet executed**:
the publication owner retains the exclusive runtime lease, N06 is scheduled
next, and N03 must await explicit owner-qualified cleanup/release, parent green
light and atomic claim. Resource inspection is not lease authority.

The extended fixture requires actual native OIDC callback/PKCE/code exchange,
private service TLS, R01/R02 current decisions, native scope/resource dispatch,
warm access/refresh, wrong-peer/route/parameter refusal, group expiry and policy
outage pairs. It also reruns the previously blocked native-JTI row using the
accepted R07 classifier. Until a clean-source native receipt executes those
rows, this section claims wiring/preparation only, not their gate completion.

## Historical source-bound bounded result

Implementation source: `a03c68e4717f5cf082d016c43ec7f5e9fe975a3a`.
The [clean native receipt](../../tests/atrium_n03/results/n03-clean-a03c68e4.json)
records **13 passing paired groups** across T1/T4/T8/T15/T20/T26 portions and
**two explicitly blocked integration rows**. The overall result remains
`partial`, not a completed N03 or phase-1 gate.

The actual C1 run waits 310.105 seconds without clock mutation. Healthy native
device denial propagated in 12.342 seconds and Whiskey companion denial in
20.546 seconds. Native MCP refused ordinary stale-feed use, verified eligible
admin use produced a durable alert, Whiskey's known-denied companion remained
refused, and recovery restored permitted use.

[Clean Nix/package evidence](../../tests/atrium_n03/results/n03-clean-static-a03c68e4.json)
records 20 isolated unit assertions, actual Caddy adaptation, impacted
registry/N04/N05 checks and **59 admission pytest passes / three native-SDK
module skips**. These skips are not reclassified as native gateway execution.
Existing scoped formatting, linting, YAML and staged secret checks passed.

The final foundation and client containers
`5fe0dd9ef7167775aa688652b29511bf2085ba0a84d563b5b371961b012058a2`
and `87fb24e2654dd33081aed9912e46700d5914f173463dbecb635411edaeed8932`,
plus network `atrium-harness-n03-e025f54182bdfac9-net`, were removed by their
recorded ownership lifecycle. Running `a914bf6c7045` (`ambit-db`) was unchanged.
All application/client processes ran non-root with zero capabilities and
`NoNewPrivs`. Earlier diagnostic receipts are retained unchanged.

## Accepted source boundary

* Atrium `5f919f085ca0e77664b72d13e96ceeb0680688e4`: accepted N02,
  R01–R08, R04 profiles, S01–S03 and the accepted C8 policy transport.
* Home MCP `338cbbdb990a5751d199f276c5d65b07730cd97d`: accepted native
  M01–M04 and C8 group-bound current-policy client.
* Whiskey `273cf414cac75276492ee849bb3ea257ce47f8de`: native W01–W03.
* LiteLLM remains **1.99.1**, manifest
  `sha256:a53a7d3ffebede1925bd3ee8a21e4a7b9b63e2e68ec883af136edcccb6eeb82c`.
* N04/N05/N06 come from this nix-config source, not a replacement controller,
  verifier or fake admission hook.

Only the Atrium and Home MCP root inputs advance in this slice; Whiskey's lock
entry is unchanged. C8 was explicitly accepted through Atrium PR14 and its
implementation/review fix through Atrium PR17 and MCP PR76. The original locked
specification and older N03 receipts remain unchanged.

The fixture consumes the existing nix-config isolated registry, the immutable
MCP source-generated scope catalog and the real N02 renderer. It does not
transcribe tool/resource lists. Synthetic subjects remain explicit enrollments;
registry ACLs alone do not create runtime grants.

## Network and native identity

The foundation services join an explicitly owned network namespace. Native
backends bind loopback; only Caddy and the dedicated registration TCP forwarder
bind the fixture's declared non-loopback address. External client namespaces
cannot reach backend loopback listeners. Namespace setup must match its protected
identity marker and cannot operate in the host's initial network namespace.

The native public origin is identical in policy, credentials and R05:
`https://home-mcp.atrium.invalid:18443`. External clients route it to Caddy;
the resolver's private namespace routes the same name to the actual native TLS
listener. Caddy verifies native TLS but holds **no resolver client certificate**.
Public `/cc/issue` is refused before reverse proxying. R05 reaches `/cc/issue`
directly with its real resolver mTLS certificate, preserving M02 peer identity.

R08 registration uses a separate declared TLS entrypoint on port 19443. `socat`
forwards encrypted bytes to the actual `serve-devices` listener; it does not
terminate TLS or manufacture peer headers. The native listener authenticates the
real enrolled certificate and exposes only registration.

Caddy strips proxy identity/certificate assertions and overwrites forwarded
address/host/scheme at the trusted boundary. Native `Authorization` and
`X-Atrium-Grant` carriage is retained. Native OAuth discovery, JWKS, public
metadata and intentional legacy routes are not wrapped in blanket SSO.
Whiskey's existing private `/metrics` route stays closed at the public vhost.
Unavailable required C8 current policy stays fail-closed, including during a
C1 verified-admin freshness exception.
The native SDK's host guard remains enabled: Caddy uses the canonical loopback
Host upstream while preserving the public forwarded host and verifying the
configured public TLS server name. This is routing, not native identity
masquerading; real resolver mTLS still terminates at Home MCP.

Whiskey reuses N06's UID-scoped nftables implementation in the exact owned
namespace. Its enforcement is **IPv4 destination address plus TCP port**, not
hostname or modality isolation. Existing image/non-model inventory limitations
are unchanged; declaring destinations does not prove unexecuted feature permits.

## Private state and credentials

The actual service modules/packages remain authoritative. Public N02/runtime
configuration may enter the store; secret contents, signing keys, TLS keys,
credentials and state may not. Reference-only `LoadCredential` entries supply
non-rotating runtime material. CA paths are explicit: native R05/M04 use their
actual protected TLS loaders; the accepted Nix `certifi` package supports the
per-service `NIX_SSL_CERT_FILE` trust reference for R01/R06. Whiskey uses
`NODE_EXTRA_CA_CERTS`. No system-wide CA installation is required.

Resolver, native and Whiskey state directories remain private. The fixture uses
centralized synthetic UID/GID assignments and clears both final capability sets
for application consumers. Only the invocation's namespace setup/egress units
receive `CAP_NET_ADMIN`; they are not application services.

W03 remains configured for the actual N04 publication and acknowledgement format.
Its key path is live, not copied into an environment variable or systemd credential
snapshot. The acknowledgement directory is consumer-owned, separate from
controller custody. Missing delivery cannot fall back to direct Anthropic.

## Precise model-publication interface gap

The distinct-user model plane is deliberately **disabled**, not replaced with
successful placeholders. This is an implementation delivery seam, not a new
policy axis or C8 dependency:

1. R06 `litellm_inventory.publish_associations()` and
   `_publish_controller_associations()` publish through
   `atrium_profiles.runtime.atomic_private_write()`: every replacement is 0600,
   inside the broker's required 0700 private runtime directory.
2. N04 `Controller.publish_bindings()` and `publish_service_associations()` use
   `atomic_json()` without a publication group/mode, hence 0600. Its existing
   service-token delivery **does** support consumer-group 0640 and must retain
   its real live-file/ack lifecycle.
3. Consumers already validate exact publisher UID and permit protected
   group-readable documents, but distinct non-root reader services cannot read
   these private outputs. A one-time chmod/default ACL does not survive the
   publishers' explicit modes on atomic replacements.

Needed upstream interface: optional **separate non-secret publication directory
and reader GID** for R06, preserving 0700/0600 escrow/signing custody; explicit
0640/group publication options for N04's two public protected snapshots. Keep
publisher ownership, complete history, generation/freshness, content validation
and atomic replacement unchanged. Readers gain read/traverse only, never write
or access to keys/escrow. The Nix consumer can then provision 2750 publisher-owned
directories and dedicated read groups through ordinary service configuration.

N03 does not add a root/chown relay, share the resolver's signing UID with other
services, alter producer data, take stale credential snapshots, or weaken reader
checks to conceal this gap. Required product changes belong upstream; model
positive/full-gate claims remain withheld.

## Operations and recovery boundary

### Native credential-specific deny administration: accepted fix, local proof pending

The real network lane exposes a separate upstream R07/R05 identity mismatch:
R05 records a native JWT's delivery hash in `credential_sha256` while retaining
the native issuer/JTI as its credential identifier. In accepted Atrium `87e1ec`,
`DenyService._known()` treats **every** non-null hash as an opaque-key identity
and requires `identifier == "sha256:" + hash`, so an actual native JTI deny
returns `403 deny_target_not_known`. The metadata's `native-access` profile is
consulted only when the hash is null.

That correction is now accepted via Atrium PR19 at `80c98ff` and included in the
current pin: known association type is classified first, native issuer/JTI is
retained alongside R05's delivery hash, and opaque model keys remain
hash-qualified. Accepted N07 proof at `52758ec6` exercised the real trio.
N03 does not duplicate the fix or change associations/hashes. Its original
failed row remains historical; the updated local row must independently
execute permit, actual R07 administration refusal, and recovery before N03
claims the native-JTI portion of T15.

These are isolated equivalents of the repository's native-unit, private-state,
health and independent recovery conventions—not real backup/notification jobs.

* Provision the invocation-owned namespace handle/identity and private input
  files before starting units. Missing state/material/namespace must fail startup;
  do not auto-reset an adopted installation.
* Initialize R01 enrollment, R02 subordinate grants and the actual R04 signing
  ring through their existing local operator interfaces. Provision PKI outside
  the store; no public assertion or bootstrap API is added.
* Probe Caddy's declared health endpoints with certificate verification, then
  actual native credential permit/deny. A green unit evaluation or Caddy
  adaptation is not network proof.
* Preserve coherent SQLite/WAL state, native adoption markers, signing-ring
  metadata, deny stores and alerts together during an owner-approved backup.
  No restic, replication, remote SSH or notification destination is activated.
* Observe native M04 and Whiskey W02 durable freshness alerts locally. A service
  liveness check alone does not establish fresh feed or successful admission.
* Recovery retains an independent local/Nix/SSH operator path in the design;
  this fixture does not execute SSH, rotate live trust or restart household
  services. Do not delete a deny/adoption marker or restore an older clock/cache
  to regain service.
* Stop only invocation-owned processes and remove exact recorded resources.
  Keep pre-existing `ambit-db`, images and unrelated namespaces intact.

Full N03/N07, the new retained-public N03 C8 network rows, model publication,
all native stream modes, remaining N06 image/non-model permits, and real browser
public-origin/local-network permission are not implied by this bounded lane.
No browser security flags or trust bypasses are permitted.
