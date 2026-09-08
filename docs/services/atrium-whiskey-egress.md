# ATR-N06 — isolated Whiskey egress

This is isolated phase-1 implementation, not production adoption. No Forge module
imports it, and no live keys, routes, firewall tables, identity grants, or household
services are changed. The guarantee remains credential-scoped access, not context
isolation.

## Enforcement and credential placement

`tests/atrium_n06/fixture.nix` derives one registry from the existing N04/N02
isolated values, then renders the real Atrium policy. Its image exceptions retain
their synthetic `personal:ryan` owner/account and explicitly declare `ip`
granularity. Provider names match the actual Whiskey adapters; test-only host
resolution leads exclusively to non-actuating TLS fixtures.

`egress.py` installs an `inet` nftables table **inside one invocation-owned network
namespace**, scoped to synthetic consumer UID 11001. The consumer receives no
capabilities and runs with `NoNewPrivileges`. Every outgoing consumer packet is
refused unless its destination IPv4 address and TCP port match the generated
policy. Replies to incoming connections remain possible; there is no blanket
`established` exception that could grandfather an outgoing connection to a removed
destination. IPv6 and DNS have no allow rule in this static-host fixture.

The setup process verifies the expected namespace identity and refuses an existing
table. It never flushes a ruleset or changes the host/shared VM firewall. N07 owns
all container/network IDs and cleanup. An unrestricted setup UID demonstrates that
denied destinations are live without disabling consumer enforcement.

**This is not hostname isolation.** Hostnames are inventory/configuration inputs;
the kernel enforces resolved addresses and ports. The fixture explicitly tests a
different hostname on an allowed address. Likewise, an allowed provider address
is not image-only: a non-image request to the OpenAI exception remains reachable.
Neither limitation is hidden behind the registry's purpose label.

The actual W03 helper reads `WWW_ATRIUM_MODEL_CONFIG` and the actual N04 rotating
JSON publication. Controller material is root-only. The service key and image
credential files are root-published, group-readable 0640 files in non-writable
directories; the acknowledgement directory belongs to the consumer. W03's live
read, atomic acknowledgement and N04 publication/retirement contracts are reused,
not reimplemented. `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL` are absent from the
adopted consumer environment. No model key enters source, build inputs, logs, or
the Nix store.

The unimported NixOS module supplies equivalent namespace, UID, capability,
credential-path and environment restrictions to a `*-fixture` unit. Namespace
creation and runtime secrets are explicit external prerequisites. Its evaluation
checks are **not** native systemd/Forge deployment evidence.

Both consumer capability settings use forced **empty systemd reset directives**.
An ordinary empty Nix list neither overrides another module's capability list nor
emits a reset into the generated unit. `lib.mkForce [ "" ]` clears normal/default/
ordered definitions and renders `CapabilityBoundingSet=` and
`AmbientCapabilities=`. A final-composition assertion rejects a competing forced
or stronger definition that would retain any capability. The namespace setup unit
alone retains `CAP_NET_ADMIN`; the selected consumer does not.

Composition regressions cover pre-existing `CAP_NET_ADMIN`, `CAP_NET_RAW`,
`CAP_SYS_ADMIN` and `CAP_DAC_OVERRIDE`, including forced overrides. The native lane
records all five Linux capability sets and attempts filter removal as the actual
consumer UID before executing its existing paired egress cases.

## Required outbound inventory

The inventory is checked against immutable accepted Whiskey
`273cf414cac75276492ee849bb3ea257ce47f8de`, not `.env` or live service state.
Earlier receipts retain their original W03 source pins. Real configured origins,
account selections, subscription URLs and tokens are not read.

| Capability | Actual code / destination source | Isolated treatment |
| --- | --- | --- |
| Adopted text | `lib/anthropic.ts`, `lib/atrium-model.ts`; configured LiteLLM origin, exact `/v1/messages` | TLS fixture proxy → real pinned gateway → actual N04-declared provider/account |
| OpenAI image generation/edit | `lib/image-gen.ts`; `api.openai.com/v1/images/{generations,edits}` | Direct native adapter, synthetic provider-owned key |
| Gemini image generation | `lib/image-gen.ts`; `generativelanguage.googleapis.com/v1beta/models/...:generateContent` | Direct native adapter, separate synthetic key |
| OpenRouter image generation | `lib/image-gen.ts`; `openrouter.ai/api/v1/chat/completions` | Direct native adapter, separate synthetic key |
| Partiful Firebase refresh | `integrations/partiful-firebase.ts`; `securetoken.googleapis.com` | Actual client with a synthetic fixture refresh grant; never a live grant |
| Partiful reads/writes | Same client; `api.partiful.com`, `firestore.googleapis.com` | Actual paginated guest read, masked schedule update and multipart image upload; finite synthetic effects only |
| Partiful calendar | `lib/partiful.ts`; origin of `PARTIFUL_CALENDAR_URL` (including webcal→HTTPS) | Actual HTTPS feed sync/reconciliation, persisted status and suggestion; invalid feed credential preserves operation schedule |
| OIDC | `lib/oidc.ts`; `WWW_OIDC_ISSUER` discovery and declared authorization/token/JWKS/userinfo origins | Actual discovery client against synthetic TLS issuer; full login flow not claimed |
| External resource-server identity | `lib/resource-server.ts`; `WWW_EXTERNAL_AS_ISSUER` discovery/JWKS | Actual metadata/JWKS and native JWT verification against a synthetic issuer; existing W01/W02 authorization is not replaced |
| Pocket ID admin | `lib/pocketid-admin.ts`; `WWW_POCKETID_API_URL`, `X-API-KEY` credential | Actual single-use signup-token mint/delete against synthetic admin API; no real invitation/account creation |
| Plex | `lib/plex.ts`; `PLEX_BASE_URL`, header credential | Actual identity read against synthetic Plex |
| Cooklang | `lib/cooklang.ts`; `COOKLANG_BASE_URL` | Actual index, cache warm and parsed native recipe against synthetic API |
| Mailgun | `lib/mailer.ts`; configured API base or `api.mailgun.net` / `api.eu.mailgun.net` | Actual authenticated form transport to a non-delivering synthetic recipient fixture |
| Web push | `lib/web-push.ts`; per-subscription endpoint and VAPID runtime keys | Actual subscription CRUD and encrypted transport to a non-delivering fixture; production platform endpoint selection remains separate |
| Reference/media reads | `lib/safe-fetch.ts`, `fetchReferenceImage`, Partiful media/Firebase Storage | Actual DNS-pinned SSRF-safe reference/image-edit calls against a synthetic public-looking address |

`safe-fetch.ts` accepts arbitrary public HTTP/HTTPS URLs and revalidates redirects.
The fixture assigns its public-looking reference address **only inside an owned
container namespace**, with an owned-namespace route to the fixture; it never
routes to that address on the public internet.

### Owner decisions and remaining gates

Production adoption requires an explicit allowed-origin/address update policy for
arbitrary reference URLs, calendar feed origins, push endpoints, OIDC off-origin
metadata and configured household services. A fixed allowlist cannot preserve every
possible public URL. This change does not choose Ryan's real accounts/origins,
silently disable these features, or add an internet escape. Those production
choices do not block isolated proof at explicitly declared synthetic destinations.
The required calendar, Firestore/media-upload, external-issuer, Pocket ID admin,
recipe, mail and push helper permits now have their own
[source-bound native evidence](#required-feature-preservation-follow-up);
they are not inferred from successful TCP requests.

The selected helper/transport proof does not claim complete browser login,
invitation or push-permission workflows, and does not make those deferred UI
workflows new phase-1 prerequisites. Assembled T16/N03/N07 gate promotion and
production adoption remain separate.

T4 here concerns the Whiskey namespace's direct native gateway access, not a full
LAN/N03 ingress audit. T22 reuses real N04 foreign-alias refusal paired with the
actual valid-alias helper call. N05 admission, cross-adapter authorization and
production network topology remain separate. No contract amendment is proposed.

## Reproducible isolated checks

The policy renderer uses the existing pytest runner. Nix evaluation uses the
existing flake inputs and always disables remote builders:

```sh
python -m pytest -q -p no:cacheprovider tests/atrium_n06/test_egress.py
nix eval --builders '' --offline --no-write-lock-file --impure --json --expr \
  'let f = builtins.getFlake "/path/to/nix-config"; in import ./tests/atrium_n06/evaluate.nix { inherit (f.inputs) nixpkgs atrium; }'
```

`build_runtime.py` uses the existing TypeScript compiler and production dependencies
to compile the actual Whiskey source into this worktree's ignored `.artifacts`.
It never reads `.env`. The pinned gateway image supplies Node 26 (ABI 147).
After its native-addon load failed, the existing `better-sqlite3` 12.10.0 dependency
was restored with the matching upstream Linux/ARM64 artifact, verified against
GitHub's published SHA-256. Public Linux nftables/iproute2/util-linux closures come
from the existing pinned nixpkgs cache, not a Forge build. Runtime archives and
source/image hashes are included in evidence.

```sh
python tests/atrium_n06/build_runtime.py --whiskey /path/to/whiskey-atrium-w03 \
  --output .artifacts/n06-whiskey-runtime
python tests/atrium_n06/native_runner.py --harness /path/to/atrium-r06 \
  --whiskey /path/to/whiskey-atrium-w03 --spec /path/to/current-owner-spec.md \
  --evidence tests/atrium_n06/results/n06-egress-NEW.json
```

The first full attempt reached namespace setup but the consumer exited before
testing: restrictive umask made its code and delivery directories inaccessible.
Explicit read/traverse modes were corrected; signing/control directories remain
private. The failed receipt is retained, not represented as gate evidence.

## Clean native evidence

The [final receipt](../../tests/atrium_n06/results/n06-egress-17de47c2.json) binds
**14 passing bounded cases** to clean source
`17de47c2e3b8a61d9340313db6ea3d4593f154cd`, actual W03 source
`c26e318c8c67d8051bf58f369d4b69dbaf998538`, Atrium
`1d620cd30f27f2b5849533fb2a9bdb5016385f69`, and the owner spec's recorded SHA-256.
The existing checks also pass **10 policy tests and 9 Nix assertions**.

* **T4 portion:** the real native gateway's direct backend is reachable from the
  setup UID but refused to Whiskey UID 11001; the kernel rejection counter
  increases. The actual adopted helper succeeds through the TLS proxy.
* **T16 portion:** actual W03 text returns 200 from `/v1/messages`, with precisely
  one authenticated native provider call to `/v1/responses`, model
  `fixture-personal`, and zero foreign-provider calls. Missing publication yields
  503 without fallback; recovery succeeds. The live direct-Anthropic canary is
  refused with a second measured kernel rejection.
* **T16 required permits exercised:** actual OpenAI/Gemini/OpenRouter image
  adapters, OIDC discovery, Partiful refresh/read, Plex identity, SSRF-safe
  reference fetch and OpenAI reference edit all work through the selected
  restrictions. This historical receipt does not include the nine newer
  required-feature groups documented below.
* **T22 portion:** the actual N04 parser refuses `foreign_alias_backend`, paired
  with the configured valid alias reaching only its declared synthetic account.

The same Node process (PID 8) uses UID 11001, zero effective capabilities and
`NoNewPrivileges=1`; neither direct Anthropic environment variable is present.
The different-host/same-address and non-image/provider-address permits explicitly
demonstrate the enforcement limits rather than pretending they are denials.

Every owned container and
`atrium-harness-n06-76e9c77578dc074e-net` was removed. The pre-existing
`ambit-db` container `a914bf6c7045` remained running unchanged. Images and the
shared VM were not removed. Full N06/phase-1 completion is **not** claimed.

### Capability-composition regression closure

The [post-fix receipt](../../tests/atrium_n06/results/n06-egress-66d72010.json)
binds **15 passing native cases and 16 passing Nix checks** to clean source
`66d72010e918dfa8a03bf4871da5d5dac5b92de6`. The capability fix itself is
`5f8b3ebcd7cd0a28d5ad3822b0f0889466322810`. The existing 10 policy tests pass.

Pre-fix composition reproduced retained capabilities in ordinary and ordered
privileged service definitions. Post-fix composition clears those definitions,
emits explicit empty systemd resets, and rejects forced/higher-priority privilege
retention. The separate namespace setup unit still has its required `NET_ADMIN`.

The actual UID-11001 consumer reports zero inheritable, permitted, effective,
bounding and ambient capabilities. Its `nft delete table` attempt executes and
returns status 1; the table remains, and all original paired egress cases pass.
The [preceding diagnostic](../../tests/atrium_n06/results/n06-egress-5f8b3ebc.json)
is retained: it already showed zero capabilities and 14 working egress cases,
but the new deletion probe initially stopped at inaccessible public tool
directories. Only those invocation-owned container directories were made
traversable; credential/control permissions were not widened.

Cleanup removed all exact owned resources and
`atrium-harness-n06-a6f1542252fb5305-net`, retaining `ambit-db` unchanged.
Enforcement remains IPv4 **address + TCP port**, not hostname or modality
isolation. The newer required-feature permits are separately source-bound below;
production adoption and assembled-gate limits are unchanged.

### Required feature-preservation follow-up

The [owned required-permit extension](../../tests/atrium_n06/README.md#required-non-model-permit-extension)
executes the required real client/helper paths against finite synthetic
services. Its [corrected native receipt](../../tests/atrium_n06/results/n06-required-native-b47ce525.json)
records **24 passing groups** at clean source
`b47ce5258da163189350a8891e0ba3ba117c2b57`, with immutable accepted Whiskey
`273cf414cac75276492ee849bb3ea257ce47f8de`. The exact
[handoff](../../tests/atrium_n06/results/n06-required-native-b47ce525-handoff.json)
records commands, pins, cleanup and scope limits.

All nine added groups have native permit, deny and recovery results; the 18
explicit feature denials have zero prohibited fixture effects. Every helper
uses the same PID 8 / UID 11001, zero inheritable/permitted/effective/bounding/
ambient capabilities and `NoNewPrivileges=1`. The original 15 text/image/
reference and negative egress controls also pass at this same source pin.
The existing 20 focused host tests and 16 isolated Nix assertions pass but are
not substituted for the native proof.

| Native group (`T16-required-*`) | Actual permit / bounded effect | Actual refusal |
| --- | --- | --- |
| `calendar-sync` | `GET calendar.atrium.invalid/calendar.ics`; two feed events, two schedule-field changes, one suggestion, persisted status; protected title/notes unchanged | Invalid capability query credential: 401, no operation schedule change |
| `firestore-guests` | Native securetoken refresh then Firestore event GET and two guest pages | Invalid refresh; foreign event denied before successful event/guest reads |
| `firestore-schedule` | Native refresh/GET/PATCH; exact four-field update mask, duration and timezone preserved | Invalid refresh; foreign event; zero schedule writes |
| `partiful-upload` | Native refresh, SSRF-safe reference fetch and `POST api.partiful.com/uploadPhoto`; exact native PNG multipart body and parsed upload response | Invalid refresh; no media fetch or accepted upload |
| `external-issuer` | Native resource-server discovery/JWKS and RFC9068 verification at `identity.atrium.invalid` | Wrong audience, issuer, scope, expiry and signature all yield no verified identity |
| `pocketid-admin` | Native group lookup and `POST /api/signup-tokens` with exact single-use/group/TTL DTO; DELETE 204 and repeated 404 treated idempotently | Wrong native API key, invalid TTL and ungranted group; no signup creation |
| `recipe` | Native recipe index, warm/cache and parsed ingredients/cookware/steps; two observed document requests within the documented prewarm bound | Unknown native index reference: no document fetch |
| `mail` | Native Basic-authenticated `POST mail.atrium.invalid/v3/fixture.atrium.invalid/messages`, exact recipient/form and tracking disabled | Wrong key and invalid recipient; zero accepted fixture messages |
| `push` | Native subscription CRUD and `POST push.atrium.invalid/fixture/subscription`; ES256 VAPID and AES128GCM decrypted payload verified, HTTP 201 | Foreign-owner deletion refused; wrong subscription auth gets 400 with zero accepted delivery; recovery gets 201 |

Allowed validation reads and native calendar error-log persistence are not
misreported as absent. The denial accounting concerns each case's explicitly
prohibited data/action effect. Mail, upload and push are synthetic and
non-delivering; no live account, device or household destination is used.

The [first run](../../tests/atrium_n06/results/n06-required-native-80cffd3f.json)
is retained unchanged: 23/24 groups passed, but push stopped before any outbound
request with `SQLITE_CONSTRAINT_FOREIGNKEY`. The fixture had omitted the owner
required by the native subscription table. The only repair provisions a
synthetic crew row with the unchanged `upsertUserOnLogin` helper. No source
adapter, schema, authentication, fetch or egress exception was changed.

Both attempts' 14 exact containers and two networks were rechecked absent.
The complete foreign container inventory remained unchanged, including the
running `ambit-db`; only N06's lease row was removed and the lease query was
empty. No subsequent VM use is part of this handoff. Full N06/T16/N03/N07,
admission-hook integration, browser workflows and production origin selection
are not claimed.
