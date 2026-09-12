# ATR-N03 — Forge runtime foundation

This change builds a real, fail-closed foundation. It does **not** activate
Forge, initialize production identity/trust, adopt native credentials or complete
the N03 gate. `services.atriumForge.enable` owns the new host contributions.
The ordinary Home MCP and Whiskey services are not switched to Atrium profiles.

The dependency is immutable Atrium
`279bcfc186d7de674678fe41c344edf2147f341c`
([app PR39](https://github.com/carpenike/atrium/pull/39)), containing the
source-qualified TLS bootstrap and public-only signing JWKS export. The native
MCP pin remains `23de14d586c668e1662294ff1f2a8d5da265cf24`; Whiskey remains
`273cf414cac75276492ee849bb3ea257ce47f8de`. LiteLLM remains exactly
`ghcr.io/berriai/litellm:v1.100.1@sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf`.

## What is wired

| Surface | Concrete value / boundary |
| --- | --- |
| Resolver | `https://atrium.holthome.net`, Caddy → `127.0.0.1:18765` |
| Upstream identity | `https://id.holthome.net`, audience `https://atrium.holthome.net/resolver` |
| Owner | Reviewed canonical `ryan`, explicit `admin` / `adult`; no seeded groups or grants |
| Device registration | `https://forge.holthome.net:19443`, bound to `10.20.0.30` on `enp8s0` |
| Registration transport | `socat` forwards TLS bytes to `serve-devices` at `127.0.0.1:18766`; the actual enrolled-device TLS handshake terminates in the resolver |
| Native issuance target | Reserved direct HTTPS `https://127.0.0.1:9200/cc/issue`; not enabled |
| Native policy target | Reserved direct mTLS `https://127.0.0.1:18767/v1/native-policy`; not enabled |
| Retained native services | Home MCP `https://mcp.holthome.net`, client `mcp`; Whiskey `https://whiskeywhiskeywhiskey.org`, native resource `/api/mcp` |

Caddy denies `/cc/issue`, `/v1/native-policy`, and device registration on the
public resolver origin. It also explicitly denies native issuance/policy
backchannels on the public Home MCP origin. Claimed proxy identity/certificate
headers are stripped; native `Authorization` and `X-Atrium-Grant` remain intact.
Existing Home MCP OAuth/discovery and Whiskey native/PAT/session routes retain
their native authentication.

The registration port is **not** an HTTP Cloudflare-tunnel route. Clients need
the declared LAN path and explicit registration-CA trust. Opening the Caddy
device-registration path is not an alternative.

Only Caddy's existing UID239 can open the resolver loopback listener; only the
registration forwarder's UID1062 can open the registration loopback listener.
The host keeps its existing iptables firewall. IPv4 destination-port/UID checks
are not hostname or model-provider egress proof.

## Custody and persistence

Production identities are centrally allocated in `lib/service-uids.nix`:

* `atrium-resolver`: UID/GID1060. Private
  `/var/lib/atrium-resolver` contains canonical identity, SQLite/WAL, signing
  ring, references, devices, grants, deny generations and the initialization
  receipt. Only resolver-owned units share this custody.
* `atrium-trust`: UID/GID1061. Private `/var/lib/atrium-trust` contains the
  explicitly initialized TLS authorities and leaves. Individual credential
  files are mode0600 within mode0700 custody.
* `atrium-registration`: UID/GID1062. No key, token, database or CA access;
  it only forwards encrypted bytes.
* `/var/lib/atrium-policy`: root-owned policy provenance. No empty policy is
  generated, copied from a fixture or inferred from absent state.

Runtime listeners receive only four needed device-CA/registration files through
systemd `LoadCredential`. Resolver signing stays live in its own private ring.
The six TLS roots separately authorize enrolled devices, registration servers,
native servers, resolver issuance clients, native-policy servers and
native-policy clients. Server/client purposes and exact SANs are explicit.
CA lifetime is five years; leaf lifetime is one year; enrolled device certificates
are bounded to one day. Generating these files does not enroll a device or adopt
an adapter.

Each state set has its own `tank/services/atrium-*` dataset, local snapshots,
standard Forge replication, and snapshot-based encrypted `nas-primary` and
`r2-offsite` Restic jobs. Empty automatic bootstrap/recovery is forbidden.
No automatic preseed substitutes an old deny generation or missing signing state.
Restore must preserve the matching identity/signing/deny and TLS/policy state,
not merely recover a healthy HTTP process.

## Installed operator inputs

```text
/etc/atrium/bootstrap/identity.json
/etc/atrium/bootstrap/resolver.json
/etc/atrium/bootstrap/foundation.json
/etc/atrium/bootstrap/tls-plan.json
/etc/atrium/bootstrap/registry-base.json
/etc/atrium/runtime/atrium-resolver.json
/etc/atrium/runtime/atrium-device-registration.json
/etc/atrium/runtime/adoption.json
```

All are non-secret values/references. External adapter/provider credentials must
use the repository's SOPS secret flow when explicitly assigned; existing master
keys, provider aliases and refresh grants are not automatically reused.

After a separately authorized deployment, explicit first-use commands are:

```sh
sudo systemctl start atrium-initialize.service
sudo systemctl start atrium-trust-initialize.service
sudo systemctl start atrium-trust-check.service
```

**These commands have not been executed against Forge by this change.**
Neither initializer has a boot target/timer or is a dependency of a running
service. Identity initialization invokes the packaged `bootstrap` and
`signing initialize` commands as the resolver UID. It refuses an existing SQLite
file and records completion only after both succeed. TLS initialization invokes
the packaged strict `tls initialize` command as the trust UID. Concurrent,
repeated, partial or foreign-plan initialization is refused.

Inspect/export only public material through the actual app commands:

```sh
sudo -u atrium-resolver atrium-resolver \
  --config /etc/atrium/bootstrap/foundation.json signing jwks
sudo -u atrium-trust atrium-resolver \
  --config /etc/atrium/bootstrap/foundation.json \
  tls --plan /etc/atrium/bootstrap/tls-plan.json status
```

The latter verifies all private custody before emitting public fingerprints,
validity and certificate paths. Transfer only the selected public CA/certificate
files through the independent operator path. Never publish the private directory
or pass secret bytes in command-line arguments. TLS status is not a renewal or
restore command; never remove `.initialize`, `trust.json`, the resolver receipt,
or deny history to bypass a failure.

## Exact remaining operational inputs

The N02 validator requires one owned team with nonempty approved aliases for
every active wing. Current reviewed inventory does not establish the provider
accounts/domain ownership, exact models/aliases, budgets, or designated family
model needed to satisfy that contract. **Missing model information is not an
empty managed inventory and is not permission to adopt brownfield aliases.**

Therefore the complete registry is not published. The reviewed fragment in
`registry-base.nix` contains real owner/wing/`rymac` eligibility and the pinned
ordinary native source catalog—not the synthetic M03 catalog. Its bounded
`hermes` view is correctly labeled read-write: all three current native scopes
(`admin`, `advisor`, `hermes`) include writes. Public native templates remain
explicit ceilings, not seeded grants or a migration decision.

Both listener units require the initialized identity receipt, existing SQLite
state, and `/var/lib/atrium-policy/resolver.json` to be present and nonempty
**before** startup. The app
then validates the complete policy and signing/TLS state. Missing material
fails the unit; no successful empty service is substituted. Until a reviewed
complete N02 policy can be generated and installed with root provenance, these
listeners are deliberately **not ready**. Do not install the fragment as policy.
With no registry supplied, the generic app module's publication switch remains
off; the Forge host units consume the real packaged CLI with this explicit
missing-policy barrier rather than relaxing the validator. Supplying reviewed
complete values through the existing `services.atrium.registry` option enables
the app generator and selects `/etc/atrium/desired-state/resolver.json` instead.
The unchanged validator still rejects missing teams/aliases, and Forge refuses
isolated registry metadata. The generic app runtime switches stay off to avoid
duplicate units; this does not enable any model/native adapter.

Further activation needs the inputs listed in `/etc/atrium/runtime/adoption.json`:

1. Dedicated Pocket ID client/API resource and explicit user authorization, owned
   by network-config; this host does not create or repurpose either.
2. Home MCP issuer-key continuity/public JWKS, explicit legacy identity and
   refresh-family mappings, retained reuse/deny history, and current grants.
   Direct HTTPS issuance/native-policy wiring must consume the generated exact
   client fingerprints. No header assertion or CA trust alone authorizes a peer.
3. Explicit new model credentials/ownership and real signed live resolver and
   controller publications under distinct producer UIDs. No root/chown relay,
   stale credential snapshot, shared signing UID or guessed account binding.
4. Whiskey's explicit adopted text service template/live key/acknowledgement
   path, image credential ownership and complete reviewed non-model egress
   destinations. No direct-provider text fallback or blanket Internet allowance.

These are operational-input blockers, not proposed contract amendments. No
additional phase-3 client, work authority, cross-wing view or child identity is
introduced.

## Health, recovery and evidence

Service-down/restart-churn alerts cover the resolver, device listener and
registration entry. A separate hourly TLS status unit alerts on missing,
invalid or expired custody. Gatus probes the public `/healthz` route. That is
liveness, **not** policy/adoption or native-gate readiness.

Use the existing Nix/SSH recovery path independently of Atrium authorization:

```sh
systemctl status atrium-resolver atrium-device-registration atrium-registration-entry
systemctl status atrium-trust-check
journalctl -u atrium-resolver -u atrium-device-registration -u atrium-trust-check
```

Preserve failed/partial initialization and security-state history for coherent
recovery; never regenerate missing deny caches, lower generations/clocks, clear
adoption markers or introduce a permissive fallback. TLS renewal remains an
explicit operator task, not repeated initialization.

Focused checks: `atrium-forge-preparation`, `atrium-forge-caddy`,
`atrium-identity-bootstrap`, `atrium-n03-units`, and
`atrium-n03-model-preparation`, built on Darwin with
`--option allow-import-from-derivation false`. They check source composition,
actual public configuration schemas, Caddy syntax, and actual identity bootstrap
permit/repeat/foreign-authority refusals. They are not new native N03 gate proof.
The parent app's bootstrap qualification remains at its own source boundary;
it is not relabeled as this deployment's T8/T26 result.

Full Forge compilation uses only:

```sh
task -d /Users/ryan/src/nix-config nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

Do not run `task nix:validate host=forge` on Darwin. No `naf`, activation,
`apply`, `rebuild switch`, live identity mutation, native-adapter request or paid
provider call is part of this work. T1/T4/T8/T15/T20/T26 against this runtime remain
unexecuted and ATR-N03 is not reported as a completed gate.
