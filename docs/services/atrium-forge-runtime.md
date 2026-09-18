# ATR-N03 — Forge runtime foundation

**Follow-up:** [Cloud-first registry and adapter wiring](atrium-forge-cloud.md)
replaces the missing-policy stopgap below with complete Nix values and explicit
conditional adoption. This page and its receipt describe the prior verified
foundation; its old model-selection blockers are no longer current. Cloud-only
rollout is approved, and no local-model prerequisite exists.

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
Both listeners require successful firewall startup, and their generated
settings files are explicit restart triggers so configuration changes do not
leave a process using an older authority or certificate-lifetime setting.

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

Runtime listeners receive the four needed device-CA/registration files through
systemd `LoadCredential`. Only the resolver additionally receives the four
native broker files and/or `model-management` when those adoption flags are
explicitly enabled. Resolver signing stays live in its own private ring.

### Foundation and model credential projection

Systemd 258 supplies these credentials inside each service's private mount
namespace: a root-owned `0550` directory and `0440` files on read-only tmpfs,
with a POSIX ACL granting only root and the consuming service UID access. The group
mode bits are the ACL mask, not a grant to the root group. This is valid
systemd custody, but it is not the service-owned private-file contract required
by Atrium's existing readers. Host-global `/run/credentials` visibility cannot
diagnose a private service namespace.

The foundation listeners and model units therefore project their fixed
`LoadCredential` sets as their existing service UID before starting the
application. Initializer projections finish before the bootstrap program can
write persistent state:

| Unit | UID | Volatile material directory |
| --- | --- | --- |
| `atrium-resolver` | 1060 | `/run/atrium-resolver-credentials/material/` |
| `atrium-device-registration` | 1060 | `/run/atrium-device-registration-credentials/material/` |
| `atrium-model-resolver-initialize` | 1060 | `/run/atrium-model-resolver-initialize-credentials/material/` |
| `atrium-model-controller-initialize` | 1063 | `/run/atrium-model-controller-initialize-credentials/material/` |
| `atrium-reconciler` | 1063 | `/run/atrium-reconciler-credentials/material/` |

Each runtime directory and its material directory are service-owned `0700`;
copied files are `0400`. The
projector verifies the exact root/service-only source ACL and read-only mount,
opens directories and files without following symlinks, bounds reads, creates
files exclusively, and atomically publishes a complete directory. Unexpected
names, partial native sets, nonempty destinations, unsafe metadata and failed
copies stop startup. Failed staging is cleaned; `RuntimeDirectoryPreserve=no`
also removes all volatile copies on stop, failure or restart. No existing key
is regenerated, changed in place, relabeled or copied into durable state.

The same selected credential map drives `LoadCredential` and projection.
Every configured consumer on these units points to that unit's material
directory:

| Names | Consumer |
| --- | --- |
| `device-ca`, `device-ca-key` | Real `DeviceCertificateAuthority` |
| `registration-cert`, `registration-key`, `device-ca` | Direct registration TLS configuration |
| `native-ca`, `native-client-cert`, `native-client-key`, `native-jwks` | Optional resolver `home_mcp_native.transport_context` |
| `model-management` | Resolver or model resolver initializer `litellm_native.read_controller_key` |
| `management` | Controller initializer or reconciler `atrium_litellm.files.read_bytes` |
| `personal-anthropic`, `family-anthropic` | Reconciler `atrium_litellm.controller.read_provider_credential` |

Shared `private_directory`, `private_open`, CA profile, key-pair and validity
checks, and the controller's protected-file reader, remain unchanged.
The two model initializers each receive exactly one management credential;
the reconciler receives exactly its management credential and both provider
credentials. Foundation listeners never receive the controller/provider set.
Provider runtime references point to the reconciler's projection; their wing,
principal, account, backend and source-secret bindings are unchanged.
The native extension below leaves these foundation/model sets unchanged.
Caddy and Whiskey credential paths are not redirected.
Adoption flags, UID separation, persistent signing/deny state, public issuer,
ports and the admitted `cc.atrium.operator` client are unchanged.

`atrium-forge-credential-projection` checks all four native/model adoption
combinations, the listeners, both manual model initializers and the opted-in
reconciler. It also refuses incomplete or cross-role credential sets.
`atrium-forge-credential-systemd` is a bounded
NixOS test guest using actual systemd `LoadCredential`, the production
projector, actual CA/TLS/native/model readers and the current TLS bootstrap
profile. It generates synthetic keys only in guest `/run`, tests paired
custody/profile/key/expiry refusals, failed-copy cleanup and restart cleanup.
The model cases additionally exercise the actual controller management/provider
readers under UID1063, root-owned input rejection, writable/foreign/symlinked
material rejection, and empty/oversize input cleanup for every model unit.
Hard-link refusals exercise the projector's single-link invariant for all model
units and the controller reader's additional single-link check. The shared
resolver reader does not claim that extra invariant and remains unchanged.
No native model management or inference request is made by this fixture.
Its execution status must be reported separately from evaluation; preparing
this fixture is not an executed N03 gate or a full resolver-policy test.

The [2026-09-15 deployment receipt](evidence/atrium-credential-projection.json)
records actual execution at `6b6c1eda`: two real `LoadCredential` reproductions,
two permits through the real readers, 17 denials and 12 cleanup checks, in
116.4 seconds. The owned guest was terminated and its exact PIDs checked absent;
the qualified fixture lease was released afterward. Earlier dependency/build
timeouts remain recorded as failures, not relabeled passes. All six focused
checks and whole-flake evaluation for every system pass at `e88262df`.
Projection and runtime-fixture sources are unchanged between those revisions.
This proves the startup-custody correction, not live Forge startup, full
T1/T4/T8/T15/T20/T26 policy/adapter gates, native adoption or deployment.

The [model-unit extension receipt](evidence/atrium-model-credential-projection.json)
records the later run at `0fb141f0`: the original 2/2/17/12 foundation cases plus
3 model reproductions, 3 permits, 21 denials and 24 cleanup checks. The
x86_64-linux guest completed in 215.75 seconds within the unchanged 300-second
deadline. The initial fixture failure and its correction remain recorded;
application verifiers were not changed to satisfy a new test assumption.
This is credential-loading evidence, not executed production initialization,
model adoption, inference or a new full-ticket T-case claim.

The same receipt separately preserves the hosted CI timeout at `951843ea`.
The fixture-only follow-up at `bee72953` moves application imports out of
filesystem-only cleanup/input-staging phases. Its non-import Python AST,
test script, unit wiring, cases and deadlines are unchanged. All recorded
foundation/model cases then passed in 135.54 seconds on the isolated Linux
guest. Fresh public CI for the PR head remains an independent merge condition;
neither the earlier local pass nor this timing improvement bypasses it.

### Native credential projection (pre-adoption)

The same host projector now covers the conditional native units. This corrects
pre-adoption wiring: native adoption remains **off**, and it is not evidence of
a failed live native service. At Atrium `370d275ac57ed4ca7a4c324e86353f950993a6ce`,
`native_policy_server_config` calls `device_certificates.read_material`, which
requires service-owned private directories/files. Home MCP
`8523ee680e4531dd33e132435c36666464e2174c` likewise uses strict custody in
`NativePolicyClient`, its issuance TLS loader, and `deny_store.read_private`.
Direct root-owned systemd credential paths do not satisfy those contracts.

| Unit | Existing identity | Exact projected set |
| --- | --- | --- |
| `atrium-native-policy` | `atrium-resolver` | `policy-server-cert`, `policy-server-key`, `policy-client-ca`, `policy-client-cert` |
| `atrium-native-settings` | `homelab-mcp` | `native-profile`, `resolver-client-cert` |
| `homelab-mcp` | `homelab-mcp` | `server-cert`, `server-key`, `resolver-client-ca`, `resolver-client-cert`, `resolver-jwks`, `native-profile`, `public-ca`, `policy-ca`, `policy-client-cert`, `policy-client-key` |

Each unit publishes only to `/run/<unit>-credentials/material/`, using the
unchanged root/read-only/exact-ACL input checks and service-owned `0700`/`0400`
output custody. The credential map still drives both `LoadCredential` and
projection. Native policy projects before rendering its fingerprint-bound
settings, retaining `/run/atrium-native-policy/settings.json`. Native settings
projects before rendering `/run/atrium-native-mcp/native.env`; its existing
oneshot lifetime, `PartOf`, and Home MCP startup ordering are preserved.
The renderer itself previously used ordinary reads: projecting its inputs
provides consistent bounded custody, rather than fixing a strict-reader error
in that script.

Only `native-profile` and `public-ca` receive a **1 MiB** projection bound:
the renderer already admits 1 MiB JSON, and the complete public CA bundle is
not an individual certificate. Individual certificates, private keys, and JWKS
retain the projector's **32 KiB** limit; existing model-specific bounds are
unchanged. The `public-ca` source remains
`/etc/ssl/certs/ca-certificates.crt`, without curating or replacing its trust set.

The metadata-only bundle measurement was **464,268 bytes**; this change does
not read its live contents or recreate trust. The prior Home MCP pin used the
**64 KiB** document/token budget for this CA input and would reject it.
The reviewed correction at `f414de23accf8fe973aef62d600a2907737d5423`, merged as
`14368deab8902fdcd2de564d3be8818b8c3e7212` in carpenike/mcp#81, is now selected.
Its actual `NativeDenial.start()` uses the separate
`MAX_CA_BUNDLE_BYTES = 1048576`; token/feed/JWKS bounds remain unchanged.

No unrelated SOPS environment secret is projected. Existing Home MCP
environment files, signing-key path, refresh database, deny history, identities,
hardening and approval guards are preserved. Policy remains required-mTLS;
native public TLS retains optional client certificates with the unchanged
exact-peer issuance authorization. JWKS roles and all original source owners
remain separate and unchanged. Native and Whiskey adoption remain disabled.

The pinned deny-store binding hashes the configured CA path as well as the
other trust settings. A store previously initialized with the old raw
`/run/credentials/homelab-mcp.service/public-ca` reference will therefore reject
the projected-path binding. No existing history is read, rewritten, migrated,
or reset by this change. Any such previously initialized binding is an explicit
pre-adoption compatibility blocker for the owner, not permission to remove
`owner.json`, recreate the deny database, or bypass the application's refusal.

`atrium-forge-credential-projection` checks exact native sets and consumer paths
alongside the existing four native/model combinations. The new
`atrium-forge-native-credential-systemd` check uses a network-isolated NixOS
guest, actual `LoadCredential`, the unchanged pinned application readers/TLS
loaders, and the production projector/renderer. Synthetic private keys exist
only in guest `/run`. Cases cover raw-root custody rejection, projected TLS
contexts, systemd-parsed rendered environment, exact source bytes, tampered
ownership/modes/links, mismatched TLS keys, incomplete/foreign selections,
renderer target/certificate failures, failed staging, and restart cleanup.
Profiles larger than 64 KiB and a synthetic 464,268-byte CA bundle test the
distinct projection bounds without using live material. CA permits and the
maximum/oversize pair invoke the selected application's real
`NativeDenial.start()` with a real, synthetic guest-local `DenyStore`. No raised
`read_private` argument, loader substitution, or transport mock supplies the
permit. Its mandatory poll targets only unused guest-loopback port 1 and must
fail closed; the test then closes the real client, tasks, and store. The 64 KiB
document budget must still reject the large bundle. Raw-source ownership denial
also goes through that real startup path. No existing native history is used.
The renderer and CA-loader maximum-size cases are tested independently of
systemd's aggregate credential-size cap.

The [Linux receipt](evidence/atrium-native-credential-projection.json) records
execution at committed source `657e9d2ed282c51eb209591bb6850f9b01a83e92`, using
the selected merged native package. Five actual root-custody reader refusals
and all three projected-unit permits pass, with 15 custody, three TLS-key,
three renderer, 12 exact-selection and six failed-copy refusals. Maximum and
oversized CA/profile cases and 24 cleanup checks also pass.

This does not execute the full N03 T1/T4/T8/T15/T20/T26 authorization gate or
authorize adoption. Repeat only on an isolated Linux test runner with the
pinned packages, QEMU and usable guest virtualization:

```sh
nix build --no-link --no-write-lock-file --print-build-logs \
  .#checks.x86_64-linux.atrium-forge-native-credential-systemd
```

No candidate override is required with this coordinated pin. The unchanged
`atrium-forge-credential-systemd` foundation/model regression target also
passed in its separate Linux guest: two foundation and three model permits,
17 foundation and 21 model denials, plus their cleanup cases. Test derivations
and source closures were transferred to the Linux builder; no Linux output
closure was built or downloaded on the Mac. Neither test deployed Forge or
started its live units.

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

Therefore the complete registry is not published. The metadata fragment in
`registry-base.nix` contains real owner/wing/`rymac` eligibility and the pinned
ordinary native source catalog, not the synthetic M03 catalog. It does not
assign native views or grants: all three existing scopes (`admin`, `advisor`,
`hermes`) include writes, and a scope name does not establish which wing owns
its data. Explicit per-wing view/scope ceilings must be supplied before
publication or native adoption; the shared deployment is not automatically
assigned to the Family wing.

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

The [source-bound deployment receipt](evidence/atrium-forge-runtime.json)
records the exact built system, check artifacts, source-specific CI, retained
skips/warnings and unexecuted native cases.

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
