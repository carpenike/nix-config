# ATR-N03 — Accepted C10 group-evidence configuration

This sibling branch starts at final C9 PR1094 head
`2572f5bbd375b16df6b63f1e5e9ee6076bef1358`. It changes only Nix configuration,
deployment guards, documentation and configuration tests. It does not edit
the primary checkout or app/MCP/network repositories.

**C10 is accepted**, not awaiting another owner decision: PR42 acceptance
`e8e4d54`, following Ryan's “move out with what you recommend.” Acceptance
authorizes implementation and isolated qualification, not live provisioning or
deployment. The locked specification and all historical C9 receipts remain
unchanged.
The [source-bound configuration receipt](evidence/atrium-c10-config.json)
records exact candidate-only checks, metadata findings and deferred inputs.

## No admitted public client was inferred

The inspected non-secret metadata establishes Ryan's explicit native subject,
issuer/JWKS, RS256 trust and resolver resource audience. It does **not** establish
an admitted public OAuth client ID:

* `hosts/forge/atrium/identity-bootstrap.json` contains principal/subject mapping.
* `hosts/forge/atrium/pocketid-authority.json` contains the resource audience
  `https://atrium.holthome.net/resolver`, not an OAuth client ID.
* `docs/services/atrium-identity-bootstrap.md` records that the 2026-09-12
  read-only discovery found no Atrium client/resource registration.
* `network-config/docs/pocketid.md`, “Atrium identity bootstrap export,” and
  `docs/pocketid-site-holthome.md` explicitly distinguish mapping export from
  client/resource provisioning.
* The retained native `mcp` client and existing consumer client names are not
  evidence that a public OAuth client is admitted to the Atrium resource.

No live audit or provisioning was performed. This is a statement about the
available verified declarations, **not a claim that the live provider has no
clients**. No identifier from a synthetic measurement or configuration test is
copied into host values.

## Operator-declared setting

`services.atriumForge.groupEvidence` is nullable and defaults to `null`.
Only an operator-reviewed declaration may configure it:

| Option | Contract |
| --- | --- |
| `groupEvidence.clientIds` | Required exact list of actual public OAuth client IDs admitted to this resource: 1–64 distinct values, each 1–512 bytes, without whitespace/control characters or wildcard syntax |
| `groupEvidence.maxTokenLifetimeSeconds` | Fixed deployment ceiling `3600`; wider or different values are rejected |

The declaration does not create a client, authorize it at Pocket ID, grant
membership, identify a person by email, or prove native qualification. Client
IDs are opaque exact identifiers; they are not normalized, guessed from display
names, copied from service clients, or derived from the resource URI.

When configured, the runtime Settings authority selected by
`Settings.group_authority` receives exactly:

```text
Authority.group_evidence.client_ids = the explicit operator list
Authority.group_evidence.max_token_lifetime_seconds = 3600
```

Only the selected `pocketid` group authority receives this optional block.
Resolver, device-registration, native-policy and foundation Settings share the
same declaration. The original identity-only bootstrap Settings omit it,
because that file has no policy/group-authority context.

The Nix registry itself remains unchanged: resource identity still requires an
access-token bearer, the issuer/audience/subject binding is retained, and all
human wing ACLs remain group-only. The additional paired signed ID token is
group evidence for `POST /v1/group-evidence`, never a replacement bearer,
proxy identity header or infrastructure credential.

## Honest unconfigured and startup behavior

With the default `null` declaration:

* `Authority.group_evidence` is omitted, not emitted as an empty/wildcard list.
* `/etc/atrium/runtime/adoption.json` reports `accepted-unconfigured` and no
  admitted clients. It does not claim live provisioning or native qualification.
* The real resolver and device-registration units have an explicit failing
  startup preflight naming the missing operator declaration. No healthy
  placeholder daemon or empty security state is substituted.
* Any model/native/Whiskey adoption request is refused by a Nix assertion.
* Offline identity/signing/TLS preparation remains manual and does not seed
  group observations or grant eligibility.

Configuring a valid list removes only the missing-configuration startup
refusal. It does **not** make a client real or create valid group evidence.
Actual identity, paired signatures/`at_hash`, client audience, original
source-time bounds, freshness, current grants, device and deny checks remain
the app/native adapters' responsibility. Missing/invalid/stale evidence
continues to refuse group-dependent access.

No userinfo fallback, fabricated timestamp, direct human principal ACL,
administrator-group inference, automatic membership or automatic security
history regeneration is added.

## Candidate versus final deployment inputs

The explicit candidate supplied for schema work is Atrium
`d7f15342dd515e913ce7554a349241c79060d5df`. Its real Settings parser was used
with `--override-input atrium ... --no-write-lock-file`. These are configuration
tests, not actual Pocket ID2.14 qualification.

Committed runtime pins remain the final C9 inputs until the parent provides
qualified immutable C10 core and matching MCP/vendor artifacts. The old app806
does not support configured C10 fields; do not activate a configured client
list on that old runtime. A strict parser failure is not permission to bypass
the carrier or weaken the ACLs.

The parent owns the operator token-pair helper and real Pocket ID2.14 receipt;
MCP vendor refresh follows the final core. No native qualification is claimed
here before that receipt arrives. Final pin updates and the full Forge build
are deliberately deferred to those inputs.

Focused checks use existing Nix/Python runners:

* `atrium-forge-c10-settings`: configured/unconfigured structure, startup and
  adoption refusal, unchanged registry/enrollment/grants, selected authority,
  duplicates/empty/wildcard/control/oversized lists and lifetime ceilings.
* `atrium-forge-c10-schema`: actual candidate Settings parser, exact client list
  and 3600-second limit, omission when unconfigured, and refusal when evidence
  is configured without the selected group authority.
* Existing adoption/composition checks preserve the C9 health/Caddy-only
  firewall, canonical/private MCP transport, exact LiteLLM1.100.1, per-key
  budgets, per-wing provider references and data-ownership limits.

Fixture client IDs occur only in checks; none is a production declaration or
native membership observation. For the eventual full build, use only:

```sh
task -d /Users/ryan/src/nix-config-c10-groups nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

No activation, live client/group write, secret read, paid model request, CI
retry/bypass, new agent or global-task coordination is part of this branch.
