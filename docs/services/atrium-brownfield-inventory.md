# ATR-N01 — Brownfield inventory

**Source-only snapshot: 2026-09-05. No objects adopted. T4 and T19 are blocked,
not passed.**

Implements the inventory portion of Atrium spec §5.3, Appendix A.3(f), and
Appendix B C2. Appendix B wins on conflict, including C7's corrected T19:
removed-template owned keys stop working; authorized newly minted runtime keys
survive, and unowned teams, aliases, and keys remain unchanged.

This is an operational inventory, **not** a deployed registry, an authoritative
managed-object ledger, permission to adopt anything, or proof of live state.
Atrium's guarantee is credential-scoped access plus accident prevention, not
isolation of conversation context.

## Evidence boundary

Only repository source and local Git objects were inspected. No production API,
database, host, credential file, secret decryption, deployment, model request, or
household operation was used. In particular, no LiteLLM management API was called
and no Home MCP refresh grant or Whiskey route was changed.

| Source | Revision |
| --- | --- |
| nix-config, assigned ATR-N01 worktree | `73ca6839f19dd1362e33359d2f96a6d9a6b2967e` |
| Home MCP input in that `flake.lock` | `f322463f6dd46e83ef066d8d09b7a9f210b7f062` |
| Home MCP local source inspected | `1dd85bf4cb7723b90c9edc770552a8c2e9bbf10d` |
| Whiskey input in that `flake.lock` | `b0ae5c0c7fa04bab0f995f4dc92e295cc100b861` |
| Whiskey local source inspected | `aca26a2e1554ea2ac8761fbcce00a54ca5e5b29e` |

These pins are declared configuration, not an assertion of what is running.
Home MCP's inspected application/auth configuration sources agree with its pin;
its Nix module differs. Whiskey's text, image, Partiful, and OAuth-discovery
sources agree with its pin, but other files differ. In particular, the pinned
Whiskey source has Web Push support absent from the inspected HEAD; its
`server/lib/web-push.ts`, `notify.ts`, and `nix/module.nix` were inspected at the
pin as well. Do not drop that dependency based on HEAD alone.

Unless another repository is named, paths below are relative to nix-config at
the revision above. `hosts/forge/default.nix` imports the inventoried service
files. References to encrypted files mean **names/paths only**; their contents
were not opened.

## Existing teams, keys, and ownership

| Object or question | Source observation | Live state / adoption |
| --- | --- | --- |
| Native LiteLLM teams: IDs, aliases, members, owners, budgets | Stored in LiteLLM's PostgreSQL state, not enumerated by the host module | **Unknown; unadopted.** Not an empty team list. |
| Native virtual keys: IDs/hashes, `key_alias`, human/service owners, team membership, expiry, budgets | Issued through native administration; no existing key rows are declared here | **Unknown; unadopted.** No synthetic key below represents a live key. |
| Existing `cc.*` metadata or protected issuance associations | Not established by this source-only inventory | **Unknown.** Never infer absence of managed credentials from an unread database. |
| Native Admin UI administrator | `sso.adminUi.proxyAdminId = "ryan"`; OIDC client `litellm` | A configured native UI role, **not** proof that Ryan owns every team/key, and not Atrium admin eligibility. |
| Source model routes / friendly aliases | Seventeen declarations, enumerated below | All existing declarations remain **unadopted/out of scope**. Native row IDs and extra DB aliases are unknown. |
| Provider subscriptions/accounts and credential ownership | Environment-variable and secret references only | **Unknown domain/account ownership.** Neither a provider name nor the Azure resource name proves personal, family, or work authority. |
| Adoption approvals | None supplied for existing objects | **Zero adoptions**, not zero existing objects. |

`generalSettings.store_model_in_db = true` means config-defined models are
mirrored into the database. The source route list is not an exhaustive native
model/alias-row inventory. A name starting with `cc.`, a familiar team name,
membership in an owned team, or a self-asserted `cc.owner` value is not permission
to mutate an object. See the [ownership runbook](atrium-ownership.md).

### Initial domain teams — intention, not existing objects

| Domain | Policy owner from the fixed spec | Intended team use | Native identity / status |
| --- | --- | --- | --- |
| `personal:ryan` | Ryan | Personal client templates and the future Whiskey text service template | **Unallocated.** Create a new managed team through N04; do not reuse a matching name. |
| `family:holt` | Ryan and Stefanie | Family model templates; child access capped by its per-principal key allowlist | **Unallocated.** Create a separate new managed team through N04; do not reuse a matching name. |

No existing credential/account is assigned to either domain by this document.
The concrete provider/account bindings, approved aliases, budgets, and designated
child model still need owner input and N02/N04 implementation. No local-model
route is presently declared in the LiteLLM model list, even though a separate
consumer declares an Ollama endpoint. No work team or Entra integration is
introduced in phase 1. User-facing labels use “wing”; these are machine domain
identifiers.

## Source LiteLLM routes and provider references

Evidence: `hosts/forge/services/litellm.nix:64-192`,
`modules/nixos/services/litellm/default.nix:79-100`.
The image is pinned to `ghcr.io/berriai/litellm:v1.99.1` with digest
`sha256:a53a7d3ffebede1925bd3ee8a21e4a7b9b63e2e68ec883af136edcccb6eeb82c`.
The table describes declarations, not confirmed reachable models.

| Request model / alias | Declared backend | Credential reference |
| --- | --- | --- |
| `copilot/*` | `anthropic/*` at `http://host.containers.internal:4141` | `COPILOT_API_KEY` |
| `copilot-oai/*` | `openai/*` at `http://host.containers.internal:4141/v1` | `COPILOT_API_KEY` |
| `anthropic/*` | Anthropic provider wildcard | `ANTHROPIC_API_KEY` |
| `gemini/*` | Google AI Studio provider wildcard | `GOOGLE_API_KEY` |
| `openai/*` | OpenAI provider wildcard | `OPENAI_API_KEY` |
| `claude-opus` | `anthropic/claude-opus-5` | `ANTHROPIC_API_KEY` |
| `claude-sonnet` | `anthropic/claude-sonnet-5` | `ANTHROPIC_API_KEY` |
| `claude-haiku` | `anthropic/claude-haiku-4-5-20251001` | `ANTHROPIC_API_KEY` |
| `gpt-4o` | `azure/gpt-4o` | `AZURE_API_KEY` |
| `gpt-5` | `azure/gpt-5` | `AZURE_API_KEY` |
| `gpt-5-chat` | `azure/gpt-5-chat` | `AZURE_API_KEY` |
| `gpt-5-codex` | `azure/gpt-5-codex` | `AZURE_API_KEY` |
| `gpt-5-pro` | `azure/gpt-5-pro` | `AZURE_API_KEY` |
| `gpt-5.1` | `azure/gpt-5.1` | `AZURE_API_KEY` |
| `gpt-5.1-codex` | `azure/gpt-5.1-codex` | `AZURE_API_KEY` |
| `o3-mini` | `azure/o3-mini` | `AZURE_API_KEY` |
| `text-embedding-3-small` | `azure/text-embedding-3-small`, embedding mode | `AZURE_API_KEY` |

All Azure entries use
`https://ryholt-simplechat-aifoundry.cognitiveservices.azure.com`.
Their API version is `2024-12-01-preview`, except `gpt-5.1-codex`
(`2025-04-01-preview`) and `o3-mini` (`2025-01-01-preview`).
The two Copilot routes are conditional on copilot-api, which is enabled in the
source host configuration.

The router sets `max_fallbacks = 0`; that alone does not establish domain
ownership. Wildcard expansion, native DB additions, all reachable alias targets,
provider-account ownership, and management-route restrictions need N04/N05
verification on the pinned version. None of these aliases is approved for a new
Atrium template merely by appearing here.

## Model consumers

“Enabled” below means enabled in imported source configuration, not probed live.
Every existing consumer remains unadopted; service/file ownership is not
LiteLLM-key or domain ownership.

| Consumer | Source configuration / evidence | Brownfield boundary |
| --- | --- | --- |
| Claude Code and OpenAI-compatible SDK users | LiteLLM host header and `docs/services/ai-gateway.md` describe `llm.holthome.net` and virtual-key setup | Documented clients; actual installations, virtual-key IDs, and owners **unknown**. |
| Direct copilot-api clients | `hosts/forge/services/copilot-api.nix:7-20` documents Claude Code/tools using `copilot.holthome.net` | Native client-key path remains; users and upstream account identity **unknown**. |
| LiteLLM itself | Enabled; routes above; uses copilot-api and direct providers | A downstream model consumer as well as the gateway; no existing account adopted. |
| Hermes Agent | `hosts/forge/services/hermes-agent.nix:19-20,872-887,960-963`: enabled, provider `anthropic`, model `claude-sonnet-5` | Direct provider configuration, not a declared LiteLLM consumer. Secret `hermes-agent/anthropic-api-key` via template `hermes-agent-env`. |
| Paperless-AI | `hosts/forge/services/paperless-ai.nix:263-294`: enabled, Anthropic, `claude-haiku-4-5-20251001`; module maps to `https://api.anthropic.com/v1/` | Secret `paperless-ai/llm_api_key`; do not migrate or relabel. |
| Mealie | `hosts/forge/services/mealie.nix:82-88`: OpenAI enabled, `gpt-4o-mini`, no custom model base URL set | Secret `mealie/openai_api_key`; provider default, not demonstrably LiteLLM. |
| Whiskey text features | `server/lib/anthropic.ts:58-109`: shared `callAnthropic`, direct `api.anthropic.com/v1/messages`, default `claude-sonnet-4-6`, optional `ANTHROPIC_MODEL` | Future W03 migration only; no prompt/helper/credential change in N01. |
| Whiskey image generation | `server/lib/image-gen.ts`: OpenAI, Gemini, OpenRouter; Forge defaults to Gemini and enables all three credential references | Future declared personal-domain exceptions, **not** currently adopted credentials; do not move to LiteLLM in phase 1. |
| World Monitor | `hosts/forge/services/worldmonitor.nix:10-41`: enabled, Ollama `http://127.0.0.1:11434`, `llama3.1:8b`, secret reference `worldmonitor/env` | Endpoint/provider availability and additional runtime environment contents **unknown**; no gateway/team inferred. |
| Open WebUI | `hosts/forge/services/open-webui.nix:27-86`: service disabled; dormant Azure config and `open-webui/azure_openai_key` reference | Not evidence of an active LiteLLM key. Disabled OpenAI/Anthropic/local-provider examples are not consumers. |
| Home Assistant | `hosts/forge/services/home-assistant.nix` includes the OpenAI Python dependency | A dependency is not a configured conversation integration; runtime integrations/credentials **unknown**. |
| Home MCP | Native tools deployment used by Claude and Hermes; `hosts/forge/services/homelab-mcp.nix` | No tool-side model account inferred from being an MCP server. Preserve native grants and downstream services. |

## Credential references — never values

Encrypted declarations use `hosts/forge/secrets.nix` and its
`hosts/forge/secrets.sops.yaml` reference. Symbolic SOPS names below resolve through
`config.sops.secrets."<name>".path`; this inventory does not read those paths.

| Component | Reference(s) | Runtime custody / distinction |
| --- | --- | --- |
| LiteLLM upstream providers | `litellm/provider-keys`: `AZURE_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY` | Root-only input to `litellm-env`; provider accounts and values unknown. |
| LiteLLM native controller/admin credential | `litellm/master_key` → `LITELLM_MASTER_KEY` | Root-only reference. Existing native master material is **not** an automatically adopted resolver/reconciler credential. |
| LiteLLM database | `litellm/database_password` → assembled `DATABASE_URL`; database/user `litellm` | Input readable by root/PostgreSQL group; no DB rows or DSN values inspected. |
| LiteLLM Admin UI SSO | `litellm/oidc-client-secret`, client ID `litellm`, issuer `id.holthome.net` | Root-only input; SSO is separate from native inference-key auth. |
| LiteLLM runtime assembly | `/run/litellm/env`; generated fallback `/var/lib/litellm/secrets/master-key`; generated `/var/lib/litellm/secrets/salt-key` | Runtime environment is outside the store. Source selects SOPS master material and a generated persistent salt; no salt/key rotation in N01. |
| copilot-api | `/var/lib/copilot-api/api-key`; `/var/lib/copilot-api/data/github_token`; `/var/lib/copilot-api/data/config.json` (`auth.apiKeys`, `adminApiKey`) | Generated client key, GitHub device-flow credential, and app state are distinct. LiteLLM reads the client-key reference as `COPILOT_API_KEY`; identities/values unknown. |
| Whiskey assembled environment | `config.sops.templates."whiskey-whiskey-whiskey-env".path` | Root-only `0400`; read by systemd before DynamicUser transition. Current rotation requires restart; it is **not** W03's future live key-file reader. |
| Home MCP issuer/session | `homelab-mcp/env`; names `HOMELAB_MCP_POCKETID_CLIENT_SECRET`, `HOMELAB_MCP_OAUTH_SESSION_SECRET`, `HOMELAB_MCP_OAUTH_SIGNING_KEY`; path option `HOMELAB_MCP_OAUTH_SIGNING_KEY_PATH` / `/var/lib/homelab-mcp/signing-key.pem` | File contents, configured signing-source choice, identity mappings, and refresh state unknown. Do not open or migrate them. |

Whiskey's environment mapping is explicit at
`hosts/forge/secrets.nix:1764-1800`:

| Environment name | SOPS reference name |
| --- | --- |
| `ANTHROPIC_API_KEY` | `whiskey-whiskey-whiskey/anthropic_api_key` |
| `GEMINI_API_KEY` | `whiskey-whiskey-whiskey/gemini_api_key` |
| `OPENAI_API_KEY` | `whiskey-whiskey-whiskey/openai_api_key` |
| `OPENROUTER_API_KEY` | `whiskey-whiskey-whiskey/openrouter_api_key` |
| `WWW_API_TOKEN` | `whiskey-whiskey-whiskey/api_token` |
| `WWW_OIDC_CLIENT_SECRET` | `whiskey-whiskey-whiskey/oidc_client_secret` |
| `WWW_SESSION_SECRET` | `whiskey-whiskey-whiskey/session_secret` |
| `WWW_TOKEN_KEY` | `whiskey-whiskey-whiskey/token_key` |
| `WWW_PUBLIC_TOKEN_KEY` | `whiskey-whiskey-whiskey/public_token_key` |
| `WWW_GATE_TOKEN_KEY` | `whiskey-whiskey-whiskey/gate_token_key` |
| `PARTIFUL_CALENDAR_URL` | `whiskey-whiskey-whiskey/partiful_calendar_url` |
| `PLEX_TOKEN` | `whiskey-whiskey-whiskey/plex_token` |
| `WWW_POCKETID_API_KEY` | `whiskey-whiskey-whiskey/pocketid_api_key` |
| `WWW_MAILGUN_API_KEY` | `whiskey-whiskey-whiskey/mailgun_api_key` |
| `WWW_PUSHOVER_TOKEN` | `whiskey-whiskey-whiskey/pushover_token` |
| `WWW_PUSHOVER_USER` | Shared `pushover/user-key`, **not** an independently owned Whiskey credential |

The optional source toggles for calendar, Plex, all three image providers, crew
invites, email, and Pushover are true; Pushover also depends on alerting being
enabled. This does not prove secret presence or upstream authorization.

Per-caller Partiful bundles reside encrypted in Whiskey's `partiful_credentials`
records under `WWW_TOKEN_KEY`; runtime code does not use the old shared
`PARTIFUL_FIREBASE_AUTH` fallback. Firebase API-key/refresh-token names are part
of those bundles, not new Nix credentials. At the pinned Whiskey revision,
Web Push additionally references `WWW_VAPID_PUBLIC_KEY`,
`WWW_VAPID_PRIVATE_KEY`, and `/var/lib/whiskey-whiskey-whiskey/vapid-keys.json`,
plus `pushSubscriptions` records. Their existence, key material, subscription
endpoints, and subscribers are **unknown and uninspected**.

## Native entry points to preserve

| Service | Declared path and topology | N01 disposition |
| --- | --- | --- |
| LiteLLM inference / management | LAN Caddy `https://llm.holthome.net` → host `127.0.0.1:4100` → container `4000`; native virtual keys; Admin UI `/ui`, SSO `/sso/callback` | Preserve native auth and unowned clients. No Caddy SSO wrapper added. Actual inference/management endpoint coverage awaits N05. |
| LiteLLM liveness / container network | `/health/liveliness`; shared default Podman network, database reached via `host.containers.internal:5432` | Liveness is intentionally unauthenticated. Loopback publishing is not proof of isolation from peers or every client network. |
| copilot-api | LAN `https://copilot.holthome.net`; host loopback and `10.88.0.1:4141` bridge publication; native client key | Direct native route remains outside Atrium until adopted. Caddy answers `/usage-viewer*` and `/admin*` with 404; no route changes. |
| Home MCP resource | Cloudflare/Caddy `https://mcp.holthome.net/mcp` → `127.0.0.1:9200`; native JWT verification | Preserve public native flow. Host config sets **four-hour** access tokens, overriding the upstream 24-hour default; the Atrium 15-minute profile is future M01 work. |
| Home MCP OAuth / discovery | `/.well-known/oauth-authorization-server`, both protected-resource metadata forms, `/oauth/jwks.json`, `/oauth/register`, `/oauth/authorize`, `/oauth/callback`, `/oauth/token`; `/healthz` and contract metadata routes | No refresh-grant adoption/migration. Resolver-only mTLS `/cc/issue` is a required new M02/N03 interface, not an existing endpoint. |
| Whiskey identity / MCP | Cloudflare/Caddy `https://whiskeywhiskeywhiskey.org` → `127.0.0.1:3417`; `/api/auth/*`, `/api/mcp`, both protected-resource metadata forms | Native Pocket ID access tokens, PATs, browser sessions, and configured legacy-bearer reference stay native. New companion route belongs to W01. |
| Whiskey shares / browser / presenter / crew | Existing native REST and share/presenter/hub/join surfaces; `www.whiskeywhiskeywhiskey.org` redirect | Retain native entitlements; no companion acceptance added. Inspected OAuth route source is resource-server discovery only: do not resurrect the removed embedded AS from older documentation. |

Evidence: the three Forge service files, LiteLLM module's forced loopback
publication, copilot-api `bridgePublishAddress`, Home MCP `app.py` /
`oauth_provider.py`, and Whiskey `server/index.ts`, `routes/oauth.ts`,
`lib/auth.ts`, `lib/resource-server.ts`. These are **static** observations.
N03/N07 must test direct-backend refusal from the actual untrusted harness
network and successful authorized proxy access, including alternate
container/bridge entry paths.

## Whiskey outbound destinations

This is an input to N06, **not an installed allowlist**. All fixed API hosts use
HTTPS/443 unless noted. Preserve required non-model integrations and native
confirmation gates in permit tests with non-actuating doubles. Never invoke a
native “dry run” against production: some Partiful dry runs create/send/delete.

| Feature | Destination / source of destination | Source evidence and boundary |
| --- | --- | --- |
| Current shared text helper | `api.anthropic.com` | `server/lib/anthropic.ts:102`. W03 must move the actual helper to designated LiteLLM endpoint/model using a new personal-domain runtime service credential; remove its direct-provider fallback, not just change UI settings. |
| Future adopted text helper | Designated LiteLLM route; current gateway hostname is `llm.holthome.net` | W03/N04/N06 must agree on reachable endpoint, alias, runtime publication path, overlap acknowledgement, and no fallback. These values are not installed by N01. |
| OpenAI image generation/edit | `api.openai.com` | `server/lib/image-gen.ts:382,400`; declared-exception candidate using `OPENAI_API_KEY`. |
| Gemini image generation | `generativelanguage.googleapis.com` | `server/lib/image-gen.ts:460`; declared-exception candidate using `GEMINI_API_KEY`. |
| OpenRouter image generation | `openrouter.ai` | `server/lib/image-gen.ts:535`; declared-exception candidate using `OPENROUTER_API_KEY`. Image outputs here are decoded inline; do not invent a provider-output CDN requirement. |
| Partiful authentication | `securetoken.googleapis.com` | `server/integrations/partiful-firebase.ts:601-624`, `refreshIdToken`; credentials come from the caller's encrypted bundle. |
| Partiful data / schedule | `firestore.googleapis.com` | Same file `fetchGuestsPaginated`, `fetchEventDoc`, `updateEventSchedule` (`:869,948,1115`). This is not an image-model destination. |
| Partiful RPCs / media upload | `api.partiful.com` | Same file `callApi`, `uploadCoverImage`, event/invite/blast/activity/location operations; upload is directly to this host (`:1691-1780`). `partiful.com` also appears as a Referer/link, which alone is not an outbound request. |
| Partiful calendar sync | **Unknown hostname and redirect destinations** from `PARTIFUL_CALENDAR_URL` | `server/lib/partiful.ts:121-137`; `webcal` normalizes to HTTPS. The whole URL is a credential. Owner must supply redacted hostname-only inventory later; do not decrypt it for N01. |
| Reference and imported media | `firebasestorage.googleapis.com` is a source-generated Partiful image host; additional user-selected public hosts/redirects are **unknown** | Partiful integration `:128`, `image-gen.ts` reference fetch, and `safe-fetch.ts`. Bound all supported reference destinations with owner input; no `*.googleapis.com`, arbitrary-public-host, or blanket internet escape hatch. |
| Browser/native identity and crew administration | `id.holthome.net` | `lib/oidc.ts` discovery/token/userinfo; `resource-server.ts` discovery/JWKS; `pocketid-admin.ts` group lookup and signup-token operations. The existing admin API key is instance-wide; possession does not confer Atrium admin status. |
| Cooklang recipe index/document reads | `cook.holthome.net` | Forge `COOKLANG_BASE_URL`; `server/lib/cooklang.ts`, boot/hourly refresh and recipe reads. |
| Plex lookup / library reads | `plex.holthome.net` | Forge `PLEX_BASE_URL` when Plex enabled, same upstream default; `server/lib/plex.ts`. Preserve scoped `PLEX_TOKEN` use. |
| Guest invite email | `api.mailgun.net` | `server/lib/mailer.ts:66-72,112`; configured sending domain, default US API host. `WWW_MAILGUN_API_BASE` can override it; no EU host automatically approved. |
| Host notifications | `api.pushover.net` | `server/lib/notify.ts`; dedicated app token and shared recipient-key reference. |
| Browser Web Push, **pinned revision** | **Unknown push-service hosts** from stored subscription endpoints | `server/lib/web-push.ts` at `b0ae5c0…`; `sendNotification` uses per-subscription endpoints. No subscription capability URL or VAPID key belongs in this inventory. Owner must identify supported push hosts before N06 closes egress. |
| Name resolution | Deployment's explicitly configured resolver, address/transport still to be selected for isolated egress | N06/N07 infrastructure dependency, not permission for arbitrary DNS or internet access. |

`safe-fetch.ts` vets public addresses, pins DNS, and rechecks redirects for
user-influenced GETs. It is **not** a provider/domain allowlist, and cannot replace
per-service egress enforcement. N06 must record actual hostname/address
granularity and test redirects and all required destinations without a broad
fallback. Provider-level image exceptions do **not** prove image-only modality
enforcement (C7).

Browser font/media/navigation traffic is not automatically Whiskey-process
egress. Likewise the same-origin telemetry `/relay/*` is Caddy forwarding to
Alloy at `127.0.0.1:12347`, not an outbound call made by the Whiskey service.
Keep those distinctions when deriving service-network rules.

## Handoff, evidence, and owner decisions

The [ownership runbook](atrium-ownership.md) defines the protected identity
mechanism and links the synthetic reconciliation cases. They contain no live
rows, are not imported by Nix, and do not execute an adapter.

| Gate / artifact | Status and remaining evidence |
| --- | --- |
| Source inventory / no adoption | Implementable N01 artifact. Review the ticket commit: documentation, navigation, and synthetic data only; no service/secret/lock-file changes. |
| Reconciliation fixtures | Static inputs and expected outcomes for N04/N07, including name/metadata collisions. JSON validation is **not** reconciliation behavior. |
| **T4 deny and permit** | **BLOCKED — not executed.** N03/N06 network boundaries and N07 isolated real-service topology must demonstrate direct-backend refusal and authorized proxy success. |
| **T19 deny and permit** | **BLOCKED — not executed.** N04 controller, R06 issuance, N05 request admission, and N07 must prove removed-template denial, post-deploy runtime-key survival, and unchanged unowned teams/aliases/keys on LiteLLM v1.99.1. |

Source-only verification executed for this ATR-N01 artifact commit:

| Check | Actual result |
| --- | --- |
| `python3 -m json.tool` on the fixture | **PASS** — valid JSON. |
| Python standard-library fixture integrity checks | **PASS** — 12 unique cases; unique JSON fields; resolved catalog/inventory/template references; owned-only action targets; no adoptions; dry-run/refusal preservation; same-name/different-ID cases; fresh post-deploy key and unexpired removed-template key. No reconciliation implementation executed. |
| Existing `mkdocs build --strict` | **PASS** — MkDocs 1.6.1 / Material 9.7.7, dependencies restored from `docs/requirements.txt` in a worktree-local environment; generated output kept inside the worktree. |
| `git diff --cached --check` and staged-path check | **PASS** — only this inventory, the ownership runbook, synthetic fixture JSON, and two documentation-navigation entries. |

These results belong to the commit adding this document, not to the upstream
source revisions or a deployed host. No real-adapter gate was run.

Owner decisions still required, rather than guesses:

1. Exact existing objects, if any, to adopt, with native IDs, provider-account
   ownership, principal/domain mapping, and explicit consent. Default: none.
2. Initial approved model/backend/account bindings, budgets, and designated
   child model; whether a local family route must be introduced. No existing
   wildcard or Azure route is automatically an approved answer.
3. Supported calendar, reference-media, redirect, and pinned Web Push hostnames.
   If a required destination cannot yet be enumerated, the affected egress
   adoption remains blocked; do not silently break the feature or allow all
   internet traffic.

N02 owns registry values/schema; N04 owns native team/alias identity mapping and
protected controller state; R01/R06 own trusted key/grant associations; R04 owns
wire profiles; N05 proves admission-hook coverage; W03 owns live service-key
reading and acknowledgement. No new contract amendment is proposed: C2 already
permits an authoritative ownership inventory when native metadata is inadequate.
