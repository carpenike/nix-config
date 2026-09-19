# Direct Whiskey adoption

Whiskey uses the existing Personal-wing model foundation. This does not repeat
Atrium setup, replace native credentials, change browser/PAT permissions, or
touch Home MCP's working connections.

## Owner commands

From the updated nix-config checkout on the Mac:

```sh
task nix:prepare-atrium-whiskey
naf
```

The first command builds the candidate on Forge and invokes that candidate's
immutable preparation package. Preparation verifies the existing model approval,
three existing Whiskey image-secret references, and resolution of the exact
configured destinations. It initializes only the new native Whiskey deny store,
validates it with the installed application, then publishes approval last.
It does not start services, issue model keys, modify application data or reset
any foundation.

Matching retries reuse the existing deny history and approval. Partial history,
an existing legacy-location deny store, wrong ownership, a missing image secret,
incomplete SQLite schema or conflicting approval stops preparation. Do not
delete history or approval to bypass a refusal.

Normal activation enables the existing controller's service-key rotation and
Whiskey's live key reader. The key is never copied into an environment variable
or systemd credential snapshot. Both the application and its manual maintenance
unit use the declared static identity, the live model configuration, and no
direct Anthropic credential. The native application database, sessions, PATs,
Partiful credentials, VAPID keys and subscriptions stay in their existing
StateDirectory. `DynamicUser=yes` is intentionally retained: systemd uses the
preallocated NSS account at UID 1067 while retaining the private, ID-mapped
directory layout. Turning that flag off is not an automatic ownership migration
for the existing files.

The new deny store is a private service-owned child at
`/var/lib/atrium-policy/whiskey-admission`, within the already protected policy
dataset. This avoids initializing under the old DynamicUser's private,
ID-mapped application directory before the static-user transition. The parent
remains root-owned; Whiskey cannot change its permission ceiling or approval.
The existing policy dataset's snapshots and local/offsite backup jobs cover
this history.

## First-use and idle-rotation alerts

`service_ack_timeout` means Whiskey has not yet confirmed successful inference
with the published key. It is not a missing-file diagnosis or proof that the
application is down. The same alert can occur after the first deployment or a
later daily rotation while no one is using Whiskey's generation features.

Only an actual successful server-side model request writes the acknowledgement.
A Claude answer based on MCP data, a readable key, an HTTP 200 MCP envelope,
or a health check does not establish that. For an intended first-use check, have
Claude call the native Whiskey `draft_dispatch` tool for an existing operation,
with `kind: custom`, `include_history: false`, and an explicit short instruction.
Do not save or transmit the draft. This makes a real model request and can incur
provider charges; no automatic keepalive or background paid probe is installed.

If the tool fails, inspect its actual result rather than blindly retrying. Once
Whiskey writes a valid acknowledgement, the next existing reconciler timer run
can accept it even after the acknowledgement deadline. Confirm with:

```sh
systemctl show atrium-reconciler.service -p Result -p ExecMainStatus
```

An inactive/dead oneshot with `Result=success` and `ExecMainStatus=0` is normal.
The timer runs again after 20 seconds of inactivity. No restart, reauthentication
or repeated preparation is needed just because a first-use acknowledgement was
late.

The timeout remains a real reported failure: it must not be suppressed with
`SuccessExitStatus`, converted to a successful rotation, or bypassed by writing
an acknowledgement manually. A previously working key is not retired until the
replacement is acknowledged and its overlap elapses; native key expiry still
applies. Missing, unreadable, denied and expired credentials need their actual
cause fixed, not a reset of ownership or deny history.

## What changes

Text generation uses the existing `cc.personal.ryan.whiskey-service` template
and `cc.personal.ryan.sonnet` alias through LiteLLM 1.100.1. Its budget remains
USD 2 per 86,400 seconds, per key, not a household-wide spending cap. File,
credential or gateway failures do not fall back to Anthropic directly.

Image generation retains the existing separately stored Whiskey OpenAI,
Gemini and OpenRouter credentials as declared Personal-wing provider exceptions.
No key is regenerated, copied to another wing, or committed.

The Atrium route is:

```text
https://whiskeywhiskeywhiskey.org/cc/mcp
```

It requires **both** the native Pocket ID access token and its matching,
resolver-signed `X-Atrium-Grant` companion. The ordinary grant remains read/write
without `host`; native permissions can further restrict it. A display name or
an OAuth-only Desktop connector cannot supply the missing companion or renew it.
Keep an existing ordinary Claude Desktop Whiskey connector on `/api/mcp`;
do not relabel it as Atrium-scoped. The existing browser and PAT routes remain
native-authorized, outside the companion route's policy.

## Network boundary and monitoring

`hosts/forge/atrium/whiskey-egress.nix` records hostname-only configuration:
`calendars.partiful.com`, the application's own media origin and the current
Apple Web Push service, in addition to the fixed provider and integration hosts.
No calendar capability URL, push subscription endpoint, key or personal row is
included. A new external reference site or push-provider hostname needs an
explicit configuration update.

After `network-online.target`, the root network unit resolves only these declared
names and atomically installs their IPv4/TCP-443 bindings, plus the exact DNS
resolver on UDP/TCP 53. A separate
oneshot refreshes addresses every minute so CDN address changes do not require
redeployment. Resolution must complete before rules change; an error is reported
and leaves the previous complete address boundary in place. There is no wildcard
internet fallback or automatic hostname discovery. IPv6 egress is refused.

This is **destination-address/port enforcement**, not hostname attestation or
image-only provider isolation. Different names sharing an allowed IP cannot be
distinguished by these rules. Original-direction connections must still match
the current destination set; only reply-direction traffic receives the
established-connection exemption.

Only Caddy can connect directly to Whiskey's backend. Prometheus therefore uses
the explicitly loopback-bound Caddy listener at `127.0.0.1:13417`, which forwards
only `GET /metrics` and returns 404 for application routes and other methods.
The public `/metrics` path remains 404.

## Qualification

The original adoption application was carpenike/whiskey-whiskey-whiskey#95, merged at
`4aac8d822a1dfe8a9875c41131cdde88075bdf80`. Its runtime and dependency files
remain unchanged from the separately recorded `472f877` application input;
the original receipts retain their actual source IDs.

The follow-up in carpenike/whiskey-whiskey-whiskey#96 adds bounded transport
errors, caller-side rejection of incomplete drafts, and explicit custom-format
precedence. The selected release is
`d58aca900bd804e7b0de8d480fe8c64f3d2719c5`, with the exact reviewed
`38274ce` tree. The shared helper's native acknowledgement remains distinct from
accepting a finished draft: successful native inference may acknowledge a key
even when a caller rejects its token-limited or refused output. There is no new
automatic request retry or direct-provider fallback.

The [source-bound host receipt](evidence/atrium-whiskey-cutover.json) records the
executed preparation and host groups, the original failed identity transition,
its correction, and the independent boot-order review finding and regression.

`atrium-whiskey-cutover-wiring` checks the actual Forge selection, identities,
secret references, live-reader paths, maintenance unit, network refresh,
approval guards and the generated Caddy/Prometheus routing.

`atrium-whiskey-cutover` runs an isolated Linux guest using the installed
Whiskey deny store, actual systemd transition to a preallocated UID while
retaining ID-mapped state,
Caddy and kernel iptables. Preparation refusals have recovery twins; network
cases cover permitted and forbidden addresses, unchanged unrelated-service
egress, delayed-network startup ordering, metrics-only ingress, address
replacement and DNS-failure recovery.
Its execution receipt is separate from the application-owned W01-W03/N06
credential, text-caller and LiteLLM qualification; neither is a live deployment
claim.

That guest also invokes the selected application's own
`scripts/check-installed-generation.mjs`, not a deployment-owned replacement
for the helper or acceptance logic. The probe runs as an unprivileged synthetic
user against the installed Node 22.22.2 package, verifies all 16 changed compiled
modules, exercises nine bounded local cases, and removes its private fixture
state. The host wrapper additionally refuses an unsafe runtime directory before
allowing the private-directory recovery. Scripted provider responses and prompt
construction checks do not prove a real model will obey every formatting request.

The application-owned
[W01-W03 receipt](https://github.com/carpenike/whiskey-whiskey-whiskey/blob/4aac8d822a1dfe8a9875c41131cdde88075bdf80/docs/evidence/ATR-W01-W03-adoption-ad23136.json)
records 180 classified source cases and nine actual Node 22/LiteLLM 1.100.1
groups, including 40 same-process rotation requests. The separate
[current W03/N06 receipt](https://github.com/carpenike/atrium/blob/15ae109b79f4d459d1badf0ee78aea4f39e0df14/harness/evidence/ATR-N07-W03-current-adoption-handoff.json)
records 44 bounded native groups: all 12 text callers, image and required
non-model integrations, and additional publication/read/rotation/alias/backend
pairs. That larger cohort uses the image's Node 26 on Linux arm64, not the
installed Nix Node 22 runtime; its exact environment and exclusions are recorded.
These overlapping cohorts are not added into a synthetic total.
