# ATR-N03 — isolated foundation entrypoints

This is an unimported, synthetic foundation definition under
`tests/atrium_n03/`. It does not enable Forge, run a rebuild/switch/deploy,
provision production identities, decrypt live secrets, or change host/VM trust,
DNS, routes or firewall rules. The guarantee remains credential-scoped access
and accident prevention, not conversation/context isolation.

## Accepted source boundary

* Atrium `87e1ecaea98688ea079707083413f7b2f6ba1a70`: actual N02 module,
  R01–R08, R04 profiles and S01/S02 packages.
* Home MCP `34652871465482627d645e3ea7caea7248547925`: native M01–M04.
* Whiskey `273cf414cac75276492ee849bb3ea257ce47f8de`: native W01–W03.
* LiteLLM remains **1.99.1**, manifest
  `sha256:a53a7d3ffebede1925bd3ee8a21e4a7b9b63e2e68ec883af136edcccb6eeb82c`.
* N04/N05/N06 come from this nix-config source, not a replacement controller,
  verifier or fake admission hook.

Only the Atrium root input advances. Existing accepted MCP/Whiskey lock entries
remain unchanged. C8/PR14 is an **unaccepted proposal**: its paused retained-public
native assertion/current-policy backend is neither pinned nor implemented here.

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
Missing C8-dependent current policy stays fail-closed.

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

### Native credential-specific deny administration gap

The real network lane exposes a separate upstream R07/R05 identity mismatch:
R05 records a native JWT's delivery hash in `credential_sha256` while retaining
the native issuer/JTI as its credential identifier. In accepted Atrium `87e1ec`,
`DenyService._known()` treats **every** non-null hash as an opaque-key identity
and requires `identifier == "sha256:" + hash`, so an actual native JTI deny
returns `403 deny_target_not_known`. The metadata's `native-access` profile is
consulted only when the hash is null.

Needed product correction: classify the protected association profile/type first,
retain issuer/JTI identity for native JWTs even when a delivery hash is present,
and keep hash-qualified identity for actual opaque model keys. Do not remove the
R05 hash, rename native JTIs, mutate stored associations, or publish a fabricated
deny to hide this integration issue. Native device/principal and Whiskey
companion deny paths remain independently testable; native-JTI/full-T15 claims
are withheld pending an accepted upstream correction. This is not C8 adoption.

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

Full N03/N07, retained-public C8-dependent permission permits, model publication,
all native stream modes, remaining N06 image/non-model permits, and real browser
public-origin/local-network permission are not implied by this bounded lane.
No browser security flags or trust bypasses are permitted.
