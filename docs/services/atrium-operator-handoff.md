# Atrium - operator checkpoint (2026-09-16)

This is the current operational handoff, not a new specification or a full
phase-1 completion claim. The latest read-only Forge observations below were
made at **13:31 EDT on 2026-09-16**, after the owner merged and deployed
[PR1127](https://github.com/carpenike/nix-config/pull/1127). Recheck live state
before making a new operational claim.

**Do not repeat identity setup, foundation/model initialization, or model
approval. Those steps are complete. Next is client credential issuance and
permitted/denied model use.**

## Authority and working rules

Start in `~/src/atrium`. Read `docs/BUILD-BRIEF.md` first, then `AGENTS.md`,
spec sections 3 and 4.5, Appendices A/B, the phase-1 tickets, and the decisions log.
Appendix B wins on conflict; C8, C9 and C10 are accepted. Do not ask for those
decisions again. The locked spec is unchanged by this handoff.

The guarantee is credential-scoped access plus accident prevention, not
conversation/context isolation. Keep `domain` in code/config and `wing` in
user-facing text. Preserve `cc.*` and `/cc/issue`.

The owner permits direct deployment with downtime and reports a new
environment with no other clients. No client migration is currently needed.
This is not a reason to erase initialized security history or implicitly adopt
existing native objects. Do not restore a permissive gateway to make health
green. Use isolated fixtures for development and paired real-adapter gates;
live provisioning/deployment is owner-operated. Never expose credentials,
signing material, complete environments or unfiltered management responses.

## Observed state

| Surface | Latest observation |
| --- | --- |
| Pocket ID | Setup and group configuration completed; `cc.atrium.operator` is explicitly admitted for paired signed group evidence |
| Foundation | Identity, signing/TLS and ordinary policy initialized; resolver running |
| Model initialization | Resolver associations, controller ownership ledger and admission history exist with their intended private custody |
| Model approval | Root-owned `/var/lib/atrium-policy/model-adoption.approved` exists; preserve it |
| Adoption flags | `models = true`; `native`, `whiskey` and `whiskeyText` remain false |
| LiteLLM | Running; actual pinned controller accepts its version and complete routing contract |
| Reconciliation | Successful; two owned teams, three aliases and two provider credential bindings recorded |
| Model health | Successful; current resolver/controller publications available |
| Client/service keys | No Atrium client or Whiskey service keys recorded in the observed controller ledger |
| Admission | Both producer sources recorded and a deny-feed document present |
| End-to-end client use | Not yet demonstrated; no paid model call was made by this work |

The reconciler and model-health services are periodic oneshots. `inactive`
after a successful run is normal; inspect `Result`, `ExecMainStatus` and run
timestamps rather than treating `inactive` as failure. An unchanged resolver
admission-association document can retain an old filesystem mtime; the actual
admission contract, not an invented mtime limit, determines its validity.

The setup command is owned by the Atrium flake, not nix-config:

```sh
nix run ~/src/atrium#setup -- --host forge --apply --login
```

Use login only when fresh operator authentication/group evidence is needed.
Do not add `--initialize-host`. Access tokens are short-lived (14 minutes in
the selected setup); an earlier successful login is not current authorization.
Paired ID-token group evidence does not make an ID token an access bearer.
Operator-private receipts live under
`~/.local/state/atrium/setup/atrium-forge/`; never print their credential contents.

## Selected sources and endpoints

| Component | Selected revision |
| --- | --- |
| Deployed nix-config merge | `d80bd658c68157b6a7d5e1338cd1a93c39b3f79d` |
| Atrium runtime input | `1762ecb82cccc9c3aef3545f119ffe0f4e9e1682` |
| Home MCP input | `8523ee680e4531dd33e132435c36666464e2174c` |
| Whiskey input | `472f877952a363321c76ce580ce41dd0810e08b8` |

Atrium's current source checkout also contains the operator-only safe login
diagnostics merged at `532a0ee8`; do not repin every server component merely
to pick up an operator-only change.

The selected gateway is LiteLLM **1.100.1**, not the historical 1.99.1:

```text
ghcr.io/berriai/litellm:v1.100.1@sha256:a3715fa7ad8387941ab697259bd2881d68931657247a41984f90fae6d11c62bf
```

Use the canonical HTTPS origins: `https://atrium.holthome.net`,
`https://id.holthome.net`, and `https://llm.holthome.net`. The owner added
internal Atrium DNS routing. Earlier IPv6/public-Cloudflare behavior was not
fully resolved; if it recurs, diagnose routing rather than bypassing TLS.

Personal default is `cc.personal.ryan.sonnet`; Family is
`cc.family.holt.haiku`. `cc.personal.ryan.opus` exists but requires the separate
explicit adult grant/selection, not the ordinary seed. Client budgets are USD1
per key per 3600 seconds, with at most 3600-second native lifetime. These are
not household/monthly caps. The Whiskey service template remains unactivated.
C9 allows later per-human Personal wings, including children; no real child
account or standing parental content access was created.

## Completed repairs - do not undo

| Change | Durable evidence |
| --- | --- |
| Foundation systemd credential custody | [Foundation receipt](evidence/atrium-credential-projection.json) |
| Model initializer/reconciler credential projection, PR1121 | [Model custody receipt](evidence/atrium-model-credential-projection.json) |
| Model-only selection and retained publication before management calls, PR1125 | [Activation preparation receipt](evidence/atrium-model-activation.json) |
| Exact adopted retry/fallback configuration, PR1127 | [Routing contract receipt](evidence/atrium-router-contract.json) |

Systemd's root-owned ACL credentials are projected into per-unit, service-owned
private `/run` custody. Shared application readers remain strict. Controller
service publications refresh from the existing ledger before reconciliation;
expired publications are not a reason to rerun initialization.

The adopted gateway requires zero retries, zero maximum fallbacks, and explicit
empty fallback/context-window/content-policy lists. Its real native guard
previously refused inherited retries of two and null lists. Do not weaken
`SAFE_ROUTER` or replace the separate management credentials with a master or
inference key. The controller's Management route category also needs explicit
`/credentials` and `/router/settings`.

All four model credential source files are provisioned. No new SOPS entry,
approval receipt or initialization is needed to continue from this checkpoint.
The declared gateway subdirectories were prepared before model initialization.
The source-bound receipts distinguish static checks, real systemd/N04/N05
component cases, and actual native LiteLLM routing cases. Keep those scopes and
their original failed attempts; do not aggregate them into a new full T-case
claim or relabel historical build artifacts as live evidence.

## Next work, in order

1. Complete the client path using the existing operator/resolver/sidecar
   interfaces. Start with read-only state inspection, then obtain fresh
   operator authentication through the supported flow. Keep access credentials
   in private runtime custody, not command arguments, chat, logs or source.
2. Exercise scoped client credential issuance and paired permit/deny behavior
   against the real adapters in the isolated harness. Use the relevant
   ATR-R03/R06/N05 ticket cases and existing runners. Report any owner-run live
   request separately; service health alone is not end-to-end model success.
3. Address Home MCP and Whiskey only after the model client path. Native
   identity/refresh/view adoption, data ownership, Whiskey delivery/acknowledgment
   and reviewed egress remain separate prerequisites. Leave their flags off.

No PWA, Work IQ, Entra work authority, Windows sidecar, cross-wing view,
local-model prerequisite, new child enrollment or parental bypass belongs in
this next task.

## Workspace and deployment

The owner's primary changes must remain untouched:
`~/src/atrium/docs/atrium-spec-v1.0.md` and
`~/src/nix-config/.serena/project.yml`. The spec hash observed at this
checkpoint is
`7948bf3e47a1098db984bfd23e0b660d8fd0b818c317611e4de30d824536939e`.

Use ticket branches and review PRs. Merge only when the owner requests it;
nix-config requires real **Lint** and **Nix Build Successful** results, with
no bypass. Preserve the independent Nix/SSH recovery path and initialized
identity, signing, ownership, grant and denial history.

The owner deploys with `naf`. Full Forge build-only work uses the existing
remote Taskfile from the intended checkout:

```sh
task -d ~/src/nix-config nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
```

Do not use a retired task worktree as the deployment checkout or download/build
the full Linux system closure on the Mac. Host-rendered YAML checks require a
Linux builder; source-only Nix evaluation can run locally. Preserve the existing
automatic-upgrade schedule; do not change household services as cleanup.
