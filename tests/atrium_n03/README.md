# Isolated N03 foundation lane

This lane runs actual Caddy, R01/R02/R03/R04/R05/R07/R08, native M01–M04,
Whiskey W01/W02 and S01 over real socket/TLS boundaries. It reuses the accepted
N07 `Resources` lifecycle and the existing N06 UID/address/port implementation.
It is **not full N03/N07 or phase-1 completion**.

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

Only the Atrium input advances to accepted `87e1ec`; existing MCP `3465287`
and Whiskey `273cf41` lock entries remain unchanged. `pins.json` identifies the
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
The full selected lane reports `partial`/exit 2 while declared integration gaps
remain. Passing paired rows are not discarded or relabeled as a full gate.

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

Two independent implementation gaps stay explicit:

* Non-secret protected R06/N04 publications cannot yet be delivered across
  distinct non-root reader UIDs while preserving atomic modes/history.
* R07's accepted `_known()` logic misclassifies R05 native JWT delivery hashes
  as opaque-key identities, rejecting a valid native issuer/JTI deny.

The runbook gives exact upstream interfaces. No root/chown relay, shared signer
UID, removed association hash or fabricated feed bypasses either gap. C8/PR14
is unaccepted and remains outside the input graph. Full browser-origin/local
network permission, all native stream modes, model and remaining N06 feature
permits, backup execution and production promotion are not claimed.
