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

The inventory is based on W03 source `c26e318`, not `.env` or live service state.
Configured origins, account selections, subscription URLs and tokens are not read.

| Capability | Actual code / destination source | Isolated treatment |
| --- | --- | --- |
| Adopted text | `lib/anthropic.ts`, `lib/atrium-model.ts`; configured LiteLLM origin, exact `/v1/messages` | TLS fixture proxy → real pinned gateway → actual N04-declared provider/account |
| OpenAI image generation/edit | `lib/image-gen.ts`; `api.openai.com/v1/images/{generations,edits}` | Direct native adapter, synthetic provider-owned key |
| Gemini image generation | `lib/image-gen.ts`; `generativelanguage.googleapis.com/v1beta/models/...:generateContent` | Direct native adapter, separate synthetic key |
| OpenRouter image generation | `lib/image-gen.ts`; `openrouter.ai/api/v1/chat/completions` | Direct native adapter, separate synthetic key |
| Partiful Firebase refresh | `integrations/partiful-firebase.ts`; `securetoken.googleapis.com` | Actual client with a synthetic fixture refresh grant; never a live grant |
| Partiful reads/writes | Same client; `api.partiful.com`, `firestore.googleapis.com` | Non-actuating API fixtures; no real events, messages or writes |
| Partiful calendar | `lib/partiful.ts`; origin of `PARTIFUL_CALENDAR_URL` (including webcal→HTTPS) | Explicit synthetic calendar destination; full sync permit remains separate |
| OIDC | `lib/oidc.ts`; `WWW_OIDC_ISSUER` discovery and declared authorization/token/JWKS/userinfo origins | Actual discovery client against synthetic TLS issuer; full login flow not claimed |
| External resource-server identity | `lib/resource-server.ts`; `WWW_EXTERNAL_AS_ISSUER` discovery/JWKS | Inventory only; existing W01/W02 authorization is not replaced |
| Pocket ID admin | `lib/pocketid-admin.ts`; `WWW_POCKETID_API_URL`, `X-API-KEY` credential | Inventory only; real invitation/admin operations not performed |
| Plex | `lib/plex.ts`; `PLEX_BASE_URL`, header credential | Actual identity read against synthetic Plex |
| Cooklang | `lib/cooklang.ts`; `COOKLANG_BASE_URL` | Explicit synthetic destination; native recipe permit not claimed |
| Mailgun | `lib/mailer.ts`; configured API base or `api.mailgun.net` / `api.eu.mailgun.net` | Explicit synthetic destination; native mail permit not claimed |
| Web push | `lib/web-push.ts`; per-subscription endpoint and VAPID runtime keys | Explicit synthetic destination; platform endpoint policy still requires owner selection |
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
silently disable these features, or add an internet escape. Full calendar sync,
Firestore/media upload, external issuer, Pocket ID admin, recipe, mail and push
permit coverage remains unexecuted; those are **remaining N06 gates**, not green
inferences from a successful TCP request.

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
  restrictions. The unexecuted integration portions remain listed above.
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
