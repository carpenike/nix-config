# Direct Home MCP cutover

This selects the native Atrium path for Ryan's single-user installation.
Breaking old client connections is intentional: sign in again to the bounded
views rather than migrating legacy refresh grants. Existing registrations,
signers, refresh/reuse history and deny records are retained.

Models stay enabled. Whiskey remains unadopted. Foundation, trust and model
initializers are not repeated.

## Owner command sequence

From the reviewed deployment checkout, before applying its native selection:

```sh
task nix:prepare-atrium-native
naf
```

The first command uses the existing remote build-only workflow. It then runs
the selected `atrium-native-prepare` package on Forge as an explicit owner
action, before activating the candidate. It does not switch the host or restart
services. The second command is the normal deployment.

Preparation retains the existing installation, exports only public verification
keys, creates the exact default resource's native profile with migration
disabled, prepares native deny custody, and appends the separately declared
finance grants. The native approval receipt is published only after those
prerequisites succeed. Missing or conflicting retained state is an error, not
permission to create replacement signing or OAuth history.

Do not apply the native selection first: startup deliberately refuses missing
runtime artifacts rather than serving an unrestricted fallback. There is no
extra compatibility service or rolling old/new issuer period.

## Fresh client sign-in

Use these separate Home MCP connections:

| Connection | URL | Authorization scope |
| --- | --- | --- |
| Advisor finance | `https://mcp.holthome.net/cc/views/personal-finance` | `atrium-personal-finance` |
| Hermes finance summaries and notes | `https://mcp.holthome.net/cc/views/personal-scribe` | `atrium-personal-scribe` |
| Hermes status | `https://mcp.holthome.net/cc/views/personal-status` | `atrium-personal-status` |

Using the existing Forge-managed Hermes CLI, sign in sequentially:

```sh
hermes mcp login atrium-finance
hermes mcp login atrium-status
```

The existing confidential client and callback are reused. The new aliases have
separate target-bound token caches. No broad cache deletion or `--force` option
is needed. Reconfigure Advisor to its finance URL and complete a fresh login.
The default `/mcp` connection becomes the ordinary Personal read-only view,
not an administrator or finance scope alias.

Finance eligibility still requires fresh verified Personal group evidence.
The bounded scribe/status grants use explicit Ryan principal eligibility;
group removal alone does not revoke those grants. Current grants, identity,
credential validity, exact targets and denies remain enforced.

## Refusal and recovery

If preparation refuses a prerequisite, keep existing state and correct the
reported cause before applying. If startup fails after cutover, recover through
the independent SSH/Nix path with the same signers, profile and databases.
Do not erase deny state, refresh tombstones or cutover markers, reopen the
migration window, or roll back to legacy admission to make a check green.

Code, isolated qualification and a successful host build are not a live client
sign-in result. Actual preparation, deployment and sign-in are owner operations.
