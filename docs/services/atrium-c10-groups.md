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
The [qualified-core follow-up](evidence/atrium-c10-qualified-core.json) records
the selected appca input, supplied layered qualification and held MCP/vendor
integration without overwriting that preparation history.

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

## Qualified core and coordinated deployment inputs

The corrected core supplied for schema work and now qualified upstream is Atrium
`ca621d753529b3ba89e67fef6f3c3f80aade332d`, superseding `d7f1534`.
Its real Settings parser first passed with a non-writing override and now passes
as the selected app input. Those checks remain configuration tests, not native
execution by this branch.
The correction preserves valid explicit access-token group observations and
removals at paired admission, suppressing only absence observations. No host
configuration shape changed. The parent reports 125 related cases and a
corrected package run of 916 passed with 19 separate skips.

The actual Pocket ID/helper receipt has now arrived: network-config PR38 head
`51156b7a11b5e923414df5da31897c7843efeac8`, execution source
`a2c99ed8f05b647b8566853757889d3e1a0bbb17`, and
`tests/evidence/pocketid-atrium-c10-ca621d7-20260913-attempt2.json`.
The receipt records 53 passing checks (51 C10 plus two fixture-bootstrap
checks), zero production requests, source-clean execution and successful
cleanup. Nineteen helper tests and owner-qualified lease cleanup are reported
separately.

Its evidence layers are deliberately different:

* Actual pinned Pocket ID2.14 issuance/JWKS and operator-helper flows establish
  identity-only/group-only separation, paired admission, native empty removal,
  replay refusal and original source-time bounds.
* A real-crypto synthetic authority supplies signed adverse issuer/subject/
  client/type/hash/group/time cases, conflict/expiry/known-deny cases and
  endpoint-specific explicit access-token membership/removal ordering.
  These cases use the real resolver but are not native Pocket ID issuance.

The parent is reviewing this proof independently. This branch records the
provided receipt, does not rerun it or claim its fixture clients as production
admissions, and does not aggregate all 53 checks into an undifferentiated native
issuance gate. See network-config's
`docs/pocketid-atrium-c10-qualification.md` for the source-bound breakdown.

Only the app input is advanced to qualified `ca621d7`. The MCP input remains
the prior final C9 source until the parent supplies a final coordinated
C10/vendor result. MCP PR79 candidate `9c66234973ba0b43af8a61b8d229659dcc197ca6`
is **not** selected: its combined M04 TLS fixture failure is being diagnosed.
The vendor/app consistency guard is not weakened to hide that incomplete
pair. Full coordinated checks, final MCP pin and the full remote Forge build
remain deferred. Consumer runtime and all C9/TLS/health/privacy boundaries are
unchanged.

Actual operator-verified admitted public OAuth client IDs remain unknown in
deployment metadata. Upstream qualification does not fill that prerequisite,
so the host setting stays `null`, serving/adoption refuse as documented, and
no live provisioning is authorized. There is no C10 approval blocker.

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
