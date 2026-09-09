# Isolated N03 foundation lane

This lane runs actual Caddy, R01/R02/R03/R04/R05/R07/R08, native M01–M04,
Whiskey W01/W02 and S01 over real socket/TLS boundaries. It reuses the accepted
N07 `Resources` lifecycle and the existing N06 UID/address/port implementation.
It is **not full N03/N07 or phase-1 completion**.

## Source-only model preparation

The model assembly preparation in this branch is documented in
[the model wiring guide](../../docs/services/atrium-model-preparation.md).
It adds disabled service/configuration declarations, existing-reader references,
bounded HTTP/probe helpers and a seven-group **unexecuted** topology catalog.
It does not activate a gateway, acquire/query a fixture lease, or supply any new
model permit. Accepted exact publisher pins and a later reviewed/authorized
native assignment are still required. The receipts below remain historical
source-bound evidence, not proof of this new model preparation.

## Accepted native C8/JTI evidence

Clean source `6fac02ef3f93005556a58cfd66fe32c3ec2da38a` executes
[20 paired groups with the model plane deliberately blocked](results/n03-c8-native-6fac02ef.json).
The [bounded handoff](results/n03-c8-native-6fac02ef-handoff.json) records exact
pins, private TLS/process boundaries, exclusions and independently verified
cleanup. This is a `partial` result, not full N03 or complete T-gate evidence.

Original source `a03c68e4717f5cf082d016c43ec7f5e9fe975a3a` and its
[13 paired groups/two blockers](results/n03-clean-a03c68e4.json) remain unchanged.
Original [Nix/package evidence](results/n03-clean-static-a03c68e4.json) and
diagnostic results are not overwritten or promoted to new proof.

Read [the service/network runbook](../../docs/services/atrium-foundation.md).
The public URLs and private destinations preserve R05's same-origin contract:
external clients reach Caddy, while the resolver reaches the native TLS peer.
Caddy holds no resolver client credential and never proxies public `/cc/issue`.
The native SDK's host guard stays enabled; Caddy uses the trusted loopback Host
upstream and preserves the public host separately in its overwritten forwarded
headers. Registration is encrypted-byte forwarding to the actual native peer
listener, not a proxy-header assertion.

## Build inputs

`fixture.nix` uses the real N02 renderer and immutable MCP source catalog.
`host.nix` is unimported by every production host. `operations.nix` uses the
repository's real alert helper and records health/coherent-backup/recovery
references, without enabling external jobs, notifications or SSH.

This wiring slice advances Atrium to accepted `5f919f08` and MCP to `338cbbdb`;
Whiskey remains `273cf41`. `pins.json` identifies the
matching Node22/Linux SQLite addon. The native image is the N07-pinned LiteLLM
1.99.1 image **as a Python runtime only**; this bounded lane does not start a
gateway or substitute standalone N05/N06 results for N03.

The actual Linux service-export closures were requested with `--builders ''`.
Custom closures were not cached for this Darwin machine; no remote/Forge build
was attempted. Runtime validation therefore uses byte-verified service wheels
and unchanged compiled Whiskey from the same accepted source, with separate
native/resolver Python payloads. Native MCP retains its own verified vendored
shared pin. Actual Nix Caddy/socat/Node22/kernel tools and Nix-patched `certifi`
come from the locked binary cache. This is explicit artifact scope, not a claim
that an unbuilt Linux service closure ran.

## Reproduce

1. Resolve the three explicit flake input paths/revisions into
   `.artifacts/n03-inputs.json`. Copy immutable sources into owned
   `.artifacts/source/{atrium,mcp,whiskey}` build trees, never another agent's
   mutable source. Do not copy `.env` or live state.
2. Use Atrium's existing resolver `uv.lock` environment, and Whiskey's existing
   `package-lock.json`/`npm run build`. Build profiles/resolver/sidecar/native
   wheels using their declared hatch backends into `.artifacts/n03-wheels`.
   Native contract files must pass the native build's immutable checks.
3. Build `runtime-tools.nix` with `--builders ''`; record the tool, Node and
   certifi output JSON at `.artifacts/n03-{tools,node,certifi}-build.json`.
   `build_runtime.py` bundles the actual compiled app and full tool closures.
   Fetch only the addon in `pins.json` and verify its SHA-256.
4. The pinned runtime lacks `authlib`, `asyncpg` and `joserfc`; after its actual
   import failure, these declared native dependencies were restored into
   `.artifacts/n03-native-extra` for Linux aarch64/Python3.13. The receipt
   fingerprints all copied runtime members.
5. Run:

   ```sh
   PYTHONDONTWRITEBYTECODE=1 \
     .artifacts/source/atrium/resolver/.venv/bin/python \
     tests/atrium_n03/native_runner.py \
       --spec /path/to/current-owner-spec.md \
       --evidence tests/atrium_n03/results/NEW.json
   ```

The normal lane deliberately waits **310 real seconds** for C1 outage aging.
No host/VM clock is changed. `--imports-only` and `--bootstrap-only` are explicitly
non-gate probes; `--fault-probe` checks only the exact namespace fault mechanism.
The full selected lane reports `partial`/exit 2 while the model-publication gap
remains in this slice. Passing paired rows are not discarded or relabeled as a
full gate.

All generated keys, credentials, device state and native data stay in private
invocation-owned tmpfs. Non-root service/client processes have empty capability
sets and `NoNewPrivs`; only namespace setup/fault controllers hold namespace
capabilities. No environment snapshots contain a live W03 model key.
No command exposes a credential in argv or an exported diagnostic. The host
supervisor's private stdin/stdout channels carry fixture credentials only to
their intended test client; evidence retains statuses, counts, public hashes,
namespace identities and exact cleanup—not bodies or key material.

## Executed boundaries and explicit gaps

Paired rows exercise native OAuth discovery/JWKS; direct backend socket refusal;
real R05 native issuance and wrong mTLS peer recovery; cross-view and foreign
reference denial; overwritten proxy/certificate headers; real S01 enrollment,
TLS-preserving R08 registration, challenge/replay and device denial; actual
Whiskey native/companion routes; expiry; healthy R07 deny propagation; and C1
outage/admin-alert/known-deny/recovery.

The new native groups execute public OIDC callback/PKCE/code exchange through
actual C8 mTLS/R01/R02, scoped tool and resource reads, current refresh without
scope widening, private route/peer/audience/authority/view refusal, required
policy outage/recovery, and original group expiry without renewal. Actual
R05-issued native credentials now pass issuer-qualified R07 JTI
permit/denial/recovery with the delivery hash unchanged.

The model plane stays deliberately disabled: this pinned N03 slice has not
integrated the separate R06/N04 protected-publication changes across its
distinct service UIDs. Its two observed 503s are refusals, not model permits.

No root/chown relay, shared signer UID across application roles, removed
association hash or fabricated feed bypasses that boundary. The clean native
receipt records 310.098 real seconds of C1 outage aging, durable admin alerts,
known-deny refusal and recovery; native-JTI denial propagated in 18.545 seconds.

The C8 fixture uses a separate resolver-owned private loopback listener,
distinct native policy-client PKI, actual native OIDC callback/PKCE/code exchange
and real current policy/SDK enforcement. No in-process `native_policy` or
`CurrentNativeGrant` substitute provides its permit cases. Group observations
retain the signed fixture issuer's original bounds. Resource data uses only
the non-actuating document provider and an inert private `file://` origin;
the real configuration guard, resource handler and scope checks remain intact.

Two clean-source failures are retained:
[738f0a6e](results/n03-c8-native-738f0a6e-first.json) failed native import before
any rows because runtime dependencies were absent;
[35c8a030](results/n03-c8-native-35c8a030.json) passed six retained groups before
the unconfigured synthetic resource guard refused the read. Declared runtime
dependencies and the fixture-only resource inputs were corrected in ordinary
source commits before the successful rerun; no accepted adapter bytes changed.

Following parent review/authorization and atomic claim, N03 completed the
cohort and released only its own lease after all five exact containers and
three networks from these attempts were independently verified absent. All
before/after foreign inventories matched; `ambit-db` was unchanged. Future
native use still requires parent coordination and a fresh owner-qualified
claim; resource availability alone is not authorization.

Full public C8/T28 migration/admin coverage, final-SDK transport-crossing-expiry
regression in this network lane, browser-origin/local-network permission, all
native stream modes, model/N06 feature permits, backup execution and production
promotion are not claimed. The accepted adapter's timing regression remains
upstream evidence, not a newly executed N03 case.
