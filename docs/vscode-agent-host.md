# Standalone VS Code Agent Host on Forge

## Status and scope

This is the **RB-10/RB-11 foundation**, not production acceptance or a finance
integration. Forge's declaration is disabled, has no boot activation, and
does not create a secret, account, dataset, or listener until explicitly
enabled. Existing `services.vscode-server.enable` remains unchanged and is
**not** this Agent Host.

The native, reusable module is
`modules/nixos/services/vscode-agent-host/default.nix`; Forge's co-located
storage, SOPS, backup and alert declarations are in
`hosts/forge/services/vscode-agent-host.nix`.

Do not mark RB-10/RB-12 complete on the strength of packaging or a green
systemd status. Account login, an actual AI coding session, provider refresh
over two token lifetimes, interrupted-run semantics, and reboot/restore
acceptance require the operator. No account login, model inference, financial
credentials, production service restart, or deployment is part of the build
tests.

## What is pinned

`pkgs/vscode-agent-host.nix` pins both the CLI source and the Linux server
bundle. Supported architecture for this initial package: **x86_64-linux**.
The CLI exposes upstream's actual `code agent host` command; no alternative
host implementation, Electron desktop, `code-server` web IDE, or container is
substituted.

| Component | Pin |
| --- | --- |
| VS Code stable | `1.139.1` |
| Upstream commit | `04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1` |
| CLI source (unpacked SHA-256) | `sha256-ik/S5+aczpBeJyo3RRRNYkFBP01e4Zi+8QqWtRnuYHU=` |
| Cargo dependencies | `sha256-qubW1HgtP1NxoBL9SuPo0j4zJjuO7ylaZu8FUqJPEHQ=` |
| Linux server archive SHA-256 | `e2ce35b8c0b90cf217feee9873a19c1e2ee414cf01a5989d67c87e0ef8416894` |
| Bundled Node | `24.20.0` |
| Bundled Copilot SDK | `1.0.15-unstable.35393089353.gfc44743` |
| Negotiated AHP version | `0.9.0` |

Install source:

- [Official server archive](https://vscode.download.prss.microsoft.com/dbazure/download/stable/04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1/vscode-server-linux-x64.tar.gz)
- [Tagged upstream CLI](https://github.com/microsoft/vscode/tree/04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1/cli)
- [Official Agent Host documentation](https://code.visualstudio.com/docs/agents/concepts/agent-host)
- [Remote sessions documentation](https://code.visualstudio.com/docs/agents/run/remote-agent-sessions)

**Why compile the CLI?** The released CLI is only a launcher pin: its Agent
Host eagerly downloads the newest server and runs a background update loop.
Upstream's compile-time `VSCODE_CLI_OVERRIDE_SERVER_PATH` bypasses both paths.
We compile the unchanged tagged Rust source with that override pointing to
the same-commit, hash-verified server in the Nix store. This is an upstream
development hook, not a documented promise of immutable-runtime support;
revalidate it on every update. See [workarounds](workarounds.md).

The official server bundle is unfree and its license terms apply. Only its
headless runtime assets are installed: Node, `out`, `node_modules`, launch
scripts and product metadata. Desktop extensions, including GUI MSAL, are
not installed. `autoPatchelfHook` resolves all installed ELF dependencies;
missing libraries fail the build rather than being ignored.

Built on Forge without activation:
`/nix/store/zy97xfbsk0dnv7vz98gh7p4h8vkgai5q-vscode-agent-host-1.139.1`
reported `code 1.139.1 (commit 04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1)`
and passed the mandatory-flag install checks. Its runtime is
`/nix/store/5c3kl063g403j8z1mcqwssb5a095x2ms-vscode-agent-host-runtime-1.139.1`.
These store paths are build evidence, not GC roots or deployment status.

The bundled Copilot SDK is covered by the server archive hash. Additional
Claude/Codex SDK downloads and provider credentials are not provisioned here;
do not claim those harnesses are accepted. Record the selected harness's
actual version during operator acceptance. A new VS Code client that demands
a newer AHP protocol is a controlled package-update request, not permission
to start a competing auto-installed host.

## Isolation and lifetime

- Dedicated `vscode-agent-host` UID/GID **1068**; no supplementary groups,
  SSH login keys, sudo rules, or container socket access.
- Only `127.0.0.1:17890`, always with a connection token. No firewall opening,
  reverse proxy, public tunnel, or authentication-disable option.
- Token comes from SOPS through systemd `LoadCredential`; neither value nor
  bearer URL appears in the Nix store, service arguments, or unit environment.
  A missing, shared-readable, malformed, or short token fails preflight.
- `--foreground --new-instance` keeps one supervisor owned by systemd, not
  a launcher that detaches or silently reuses an editor's process.
- Private `0700` home/state at `/var/lib/vscode-agent-host`; runtime sockets
  under `/run/vscode-agent-host`. Declared workspace names become private
  directories under `.../workspaces/`; the initial one is `scratch`.
- All sessions share **one OS trust domain**. Workspace declarations and
  worktrees are not isolation between untrusted projects. Use another
  identity/container for materially different trust.
- Other `/var/lib` state is hidden by a private mount, with only this
  `StateDirectory` bound back. Home directories, `/data`, `/mnt`, `/persist`,
  SOPS source files and administration sockets are inaccessible.
  `ProtectSystem=strict`, `NoNewPrivileges`, empty capabilities and private
  devices apply to the entire process tree.
- Default resource bounds: 4 GiB RAM, two CPU-equivalents, 256 tasks; Forge's
  dataset has a 20 GiB quota. Three failed starts within 321 seconds exhaust
  the restart budget; each startup is bounded to 120 seconds plus at most
  30 seconds of process-tree cleanup.
- Runtime network access is not a general egress sandbox. Do not add unrelated
  credentials, finance MCP configuration, SSH-agent forwarding, Docker, or
  unrestricted sudo.

## Validation (no deployment)

```sh
task nix:agent-host-check host=forge
nix flake check --no-build
```

The targeted task builds two lightweight local checks, then copies and
builds only the Linux smoke derivation on Forge. It does not build the whole
Forge closure, use sudo, restart a service, log in, or call a model.

Equivalent Linux outputs:

```sh
nix build --no-link .#packages.x86_64-linux.vscode-agent-host
nix build --no-link .#checks.x86_64-linux.vscode-agent-host-smoke
```

Checks:

1. **Package install checks:** exact runtime commit/version, executable
   bundled Node, and CLI support for every mandatory host flag. An old CLI
   returning exit zero for generic help is not accepted.
2. **Unit tests:** token validation, missing command/version failure,
   malformed/partial/multiple-host health results, and credential-free argv.
3. **Forge evaluation:** inert default; both boot gates; credential references;
   private stable identity; no added firewall/proxy; sandbox/resource settings;
   storage ordering; NAS/offsite backup and replication; unchanged editor server.
4. **Linux smoke:** isolated non-root home, ephemeral loopback listener,
   missing/wrong-token rejection, authenticated AHP session listing, native
   terminal `id`/`uname`, a tiny coding/assertion fixture finishing with every
   client disconnected, fresh-client inspection, and retained files after
   restarting only the disposable supervisor. No mock agent or provider login.
   The test has whole-process deadlines and terminates only its own process group.

The build sandbox does not contain NixOS's normal `/etc/NIXOS` marker or
`ldconfig`. Only the smoke harness supplies the already-patched runtime's
actual ELF linker to upstream's prerequisite check. The deployed service does
not bypass prerequisites. This is distinct from accepting an unsupported binary.

Verified on 2026-09-29: package install checks, twelve Python safety tests,
seventeen Forge configuration assertions, the real Linux smoke, the documented
Taskfile command, Statix, Deadnix, and `nix flake check --no-build` passed.
Forge still reported `LoadState=not-found` for the production unit and no
listener on 17890. This is build/test evidence only, **not RB-12 acceptance**.

## Operator provisioning and acceptance

1. Review the package/license and approve a dedicated coding trust domain.
   Add a high-entropy URL-safe token (for example 32 random bytes encoded as
   hex) under `vscode-agent-host/connection-token` in
   `hosts/forge/secrets.sops.yaml` **using SOPS**. Do not put it in Nix,
   shell history, chat, or an environment file. No encrypted value is added by
   this foundation.
2. Set `enable = true` in Forge's declaration. Leave `startAtBoot = false`
   and `runtimeAccepted = false` for manual acceptance.
3. Run the targeted checks above, then the existing guarded workflow:

   ```sh
   task nix:build-nixos host=forge NIXOS_DOMAIN=holthome.net
   task nix:apply-nixos host=forge NIXOS_DOMAIN=holthome.net
   ```

   These commands are operator deployment steps, not executed by the foundation.
   Check the generated dataset and account before starting anything.
4. Manually start the declared service, not a second `code agent host`:

   ```sh
   sudo systemctl start vscode-agent-host.service
   sudo systemctl start vscode-agent-host-healthcheck.service
   systemctl status vscode-agent-host.service vscode-agent-host-healthcheck.service
   ss -ltn 'sport = :17890'
   ```

   Verify only `127.0.0.1:17890` is present. Both unauthenticated and deliberately
   wrong-token requests must return HTTP 403. Never pass the real token in CLI
   arguments or capture it in diagnostic output.
5. From the approved desktop, establish an **operator-managed SSH local
   forward**, not a public VS Code dev tunnel:

   ```sh
   ssh -N -o ExitOnForwardFailure=yes \
     -L 127.0.0.1:17890:127.0.0.1:17890 ryan@forge.holthome.net
   ```

   In a compatible VS Code Agents window run **Sessions: Add Remote Agent
   Host...** (`sessions.remoteAgentHost.add`) and enter the loopback WebSocket
   address with its connection token through the UI. Upstream stores WebSocket
   entries in `chat.remoteAgentHosts`; treat that local profile as credential
   material, exclude this setting from Settings Sync, never use workspace/repo
   settings, and do not screenshot/publish the token.

   Do **not** choose “Connect via SSH” / “Start New Dedicated Agent Host” for
   this managed service: those paths can auto-install and launch another CLI
   under the operator identity. No service-identity SSH shell is provisioned.
6. Authenticate the chosen provider through the supported client flow with a
   dedicated account. Connection-token authentication is **not** provider
   authentication. Do not copy Ryan's home, Hermes state, MCP credentials, or
   Actual budget/credentials into this identity.
7. In `/var/lib/vscode-agent-host/workspaces/scratch`, demonstrate:
   - a native read-only command, a small real coding/test task, and approved
     tool permissions;
   - continuation while every client is disconnected, then a different
     client's successful inspection;
   - forced network disconnection plus authentication over **two real provider
     token lifetimes**;
   - a host-owned scheduled test with no client-only tools;
   - no access to other service state, SOPS sources, operator homes or
     administration sockets, and no sudo/group privilege;
   - after an approved service restart and reboot, retained sessions/files and
     truthful interrupted-turn reporting (not an invented successful result).
8. Verify backups/restoration below. Only after recording acceptance set
   **both** `runtimeAccepted = true` and `startAtBoot = true`, revalidate,
   rebuild, and deploy via Taskfile. That arms boot startup, the independent
   health timer and availability/protocol/restart-churn alerts.

## Readiness and logs

Startup and the two-minute independent timer use authenticated
`code agent ps --json` against the private endpoint registry. Readiness
requires exactly one standalone host at the configured loopback port with a
successful session-list result. A dead backend, competing host, malformed
response, or authentication failure is unhealthy.

This is explicitly **transport readiness**, not a paid inference probe or
evidence that a provider token is valid. A revoked provider token or failed
model task must be inspected as such; the transport timer can remain green.
Human acceptance and later workload outcome monitoring cover that layer.

Failures emit **fixed safe codes and reasons**, never exception text or raw
subprocess output. Preflight distinguishes `TOKEN_UNAVAILABLE`,
`TOKEN_PERMISSIONS`, `TOKEN_FORMAT`, `CLI_UNAVAILABLE`, `CLI_TIMEOUT`,
`CLI_QUERY_FAILED`, `CLI_VERSION_MISMATCH`, `UNSUPPORTED_CLI` and
`CLI_INVALID_OUTPUT`. Health reports the last attempt's `TIMEOUT`,
`CLI_UNAVAILABLE`, `STATUS_QUERY_FAILED` or `INVALID_STATUS`; a subsequent
successful retry reports readiness normally. `STATUS_QUERY_FAILED` requires
checking host lifecycle, the private registry and connection authentication;
it does not guess which failed or claim a provider token expired.

- `journalctl -u vscode-agent-host -u vscode-agent-host-healthcheck`:
  lifecycle, sanitized preflight failures and protocol checks.
- `/var/lib/vscode-agent-host/logs/supervisor.log`: private raw supervisor
  stdout/stderr, **may contain the connection token** in upstream's banner.
- `/var/lib/vscode-agent-host/.vscode-server/cli/agent-host-stable.log`:
  upstream's separate trace sink. It ignores `--cli-data-dir` for its path.
- Runtime/session logs live under the same private state tree.

The two supervisor files rotate daily / at 10 MiB with seven compressed
copies. Raw files are deliberately not shipped to Loki or exposed as journal
output. Do not paste logs or endpoint-registry JSON without sanitizing them.

## Backups, recovery, update and rollback

One private ZFS dataset, `tank/services/vscode-agent-host`, covers the home,
session stores, provider state, registry, and all declared workspaces.
Forge uses the standard Sanoid/Syncoid policy, snapshot-based Restic to the
NAS, and a separate encrypted R2 job. Treat all backups as credential-bearing.
Cache/supervisor logs are excluded from Restic; credentials, workspace `.git`
directories, and uncommitted work are not intentionally excluded.

Snapshots are **crash-consistent**, not proof of correct application recovery.
No semantic restore validator is invented; `validator = null` is deliberate.
Initial empty bootstrap is operator-only; the protection policy does not
authorize automatic empty recovery. After real state exists, an empty
directory is not an acceptable substitute for a restore.

After activation, verify the real units and snapshot contents:

```sh
systemctl list-timers \
  'restic-backup-*vscode-agent-host*' 'syncoid-*vscode-agent-host*'
sudo zfs list -t snapshot -r tank/services/vscode-agent-host
```

Follow the existing backup runbook to restore into a **separate private
dataset**, retain UID/GID 1068 and `0700`, and test files plus session history
using a different loopback port and disposable supervisor. Do not start two
hosts against the same state, restore over live files, reuse production
provider tokens for a fixture, or silently generate empty replacement state.
Reauthorize expired credentials explicitly; record actual restore outcome.

For an update, change source commit, source hash, Cargo hash and runtime hash
together; confirm CLI flags, bundled SDK versions, all ELF dependencies, smoke
tests and client protocol compatibility. No `code update`, editor-managed
host update, flake-input churn, or runtime latest-download path is required.
Take/verify a pre-update snapshot and stop the unit only in an approved window.

Rollback is the previous reviewed Nix generation/package **plus a compatible
state snapshot** when schemas changed. A package rollback alone does not undo
session-database migrations. Keep boot disabled during uncertain recovery and
repeat provider/login/reconnection checks before restoring production startup.
