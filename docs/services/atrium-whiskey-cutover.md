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
