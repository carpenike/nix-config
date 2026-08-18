# Temporary Workarounds & Overrides

This document tracks temporary workarounds, package overrides, and unstable package usage that should be periodically reviewed. These exist due to upstream bugs, missing features in stable, or test failures in the Nix build sandbox.

**Last Reviewed**: 2026-08-16 (hermes-agent entry only; full review still due)
**Next Review**: 2026-08-17 (monthly)

---

## Review Checklist

When reviewing workarounds:
1. Check if upstream issue is resolved
2. Check if nixpkgs has been updated with a fix
3. Test removing the workaround and rebuilding
4. Update this document with findings

---

## Channel Lifecycle Debt

Not a workaround and not a pin — a dependency that stopped moving on its own
and now owes a migration. Tracked here because it has the same review cadence
as everything else in this file.

### nixpkgs - nixos-25.11 is EOL, migration to 26.05 owed

| Field | Value |
| --- | --- |
| **Recorded** | 2026-08-17 |
| **Location** | `flake.nix` (`inputs.nixpkgs`) and `flake.lock` |
| **Affects** | Every host. This is the channel the whole fleet builds from. |
| **Status** | **NOT A PIN.** Nobody pinned anything. `inputs.nixpkgs` tracks the `nixos-25.11` *branch*, and that branch went EOL upstream and stopped receiving commits. The lock simply froze at the last one. |
| **Evidence** | The root nixpkgs node is locked at rev `b6018f87da`, `lastModified` 2026-06-30. Walking 400 commits of `flake.lock` shows it advancing on a clean weekly cadence from 25.05 all the way through 2026-07-01 (…Jun 26 → Jun 28 → Jun 29 → Jun 30) and then stopping dead, while lock commits from the weekly job continue to land through 2026-08-18 touching other inputs. The freeze date lines up with 26.05 + one month, which is the NixOS support window. |
| **Consequence** | The fleet is not receiving security patches on the stable channel, and `update-flake-lock.yml` cannot tell anyone: it runs weekly, finds nothing new for nixpkgs, and reports success. This is a silent-by-construction gap, not a noisy one. |
| **Do not** | "Document the pin with exit criteria." There is no pin to document, and adding a `follows` or a rev pin would convert a fixable branch problem into a real one. Do not bump `nixpkgs` to `nixos-unstable` either — `nixpkgs-unstable` already exists as a separate input for the packages that need it (see the `unstable-packages` overlay). |
| **Owed** | Migrate `inputs.nixpkgs` to `github:NixOS/nixpkgs/nixos-26.05`. This touches every host and every overlay and needs its own planned effort with its own verification — build all hosts, re-check every entry in this file (several exist only because of 25.11-era package versions), and re-verify the service modules against the new NixOS release notes. It is deliberately NOT bundled into unrelated work. |
| **Exit criteria** | `inputs.nixpkgs` tracks a supported channel, `flake.lock`'s nixpkgs node resumes advancing on the weekly job, and this entry is deleted. |
| **Watch for** | A stale-channel detector would have caught this months earlier than a human review did. Consider a check that fails when the locked nixpkgs `lastModified` is older than ~45 days — the weekly job succeeding is currently indistinguishable from the channel being alive. |

---

## Pinned Flake Inputs

### Actual Budget - 26.7 Schema Compatibility Pin

| Field | Value |
| --- | --- |
| **Added** | 2026-07-30 |
| **Location** | `flake.nix` (`inputs.actual-nixpkgs`) and `hosts/forge/services/actual.nix` |
| **Affects** | Actual Budget web UI, sync server, and API client compatibility on Forge |
| **Reason** | API clients running 26.7 upgraded the budget database schema. The stable nixos-25.11 package remains on 26.6.0, whose web client cannot open that newer schema. A floating `pkgs.unstable.actual-server` would silently advance again when weekly lock maintenance picks up 26.8. |
| **Workaround** | Source only `actual-server` from immutable nixpkgs revision `e2587caef70cea85dd97d7daab492899902dbf5d`, which packages Actual 26.7.0. The normal stable and unstable nixpkgs inputs continue updating independently. |
| **Validation** | Evaluate `services.actual.package.version`, build Forge, then verify the live server version, dual authentication inventory, SQLite integrity, and budget loading through the web UI. |
| **Check** | Return to `pkgs.actual-server` and remove `actual-nixpkgs` when the pinned nixos-25.11 channel provides Actual >= 26.7.0. Do not move this pin to 26.8 without first confirming all API clients and the web server will upgrade together. |
| **Upstream** | [Actual #8026](https://github.com/actualbudget/actual/pull/8026) improves the schema-skew error, but compatible server/client versions are still required. |
| **Impact** | Without the pin, the web UI is unable to open a budget after a newer API client migrates its schema; with a floating unstable package, future weekly updates can recreate the same skew in the opposite direction. |

---

### Hermes Agent - Signal, Cold-Store, and OAuth Fixes

| Field | Value |
| --- | --- |
| **Added** | 2026-07-27 (rebased onto upstream v0.20.2 on 2026-08-16) |
| **Location** | `flake.nix` (`inputs.hermes-agent`) and `flake.lock` |
| **Affects** | Forge Signal gateway, Forge evaluation, CI flake checks, automated input updates, and fixed-port MCP OAuth reauthorization |
| **Reason** | The released Signal adapter targets direct signal-cli SSE/JSON-RPC endpoints that do not exist in signal-cli-rest-api 0.100; upstream's `importNpmLock { npmRoot = fileset.toSource ...; }` breaks cold-store evaluation; and the OAuth paste fallback closes a socket while its blocking `handle_request()` thread still owns the fixed callback port, causing the SDK's next callback to fail with `Address already in use`. Verified 2026-08-17: upstream's `allow_reuse_address` fix (#44590) does NOT cover the OAuth symptom on Linux — on pure v0.20.2 a second fixed-port flow after a pasted callback fails with `[Errno 98] Address already in use` (the `handle_request()` thread keeps the closed listener's socket alive; `SO_REUSEADDR`/`SO_REUSEPORT` cannot help). macOS masks the bug, which likely explains why upstream has not hit it. The fork's managed-shutdown fix cures it (probe tests pass on the fork branch on the same host). |
| **Workaround** | Pin `hermes-agent` to immutable fork commit [`9dfd2fc32`](https://github.com/carpenike/hermes-agent/commit/9dfd2fc325f60d24d349ad47a5cf571899cede3c) (branch `nix-config/v2026.8.16`): upstream **v0.20.2** + the current PR #53696 head (REST/WebSocket adapter) + v0.100 raw-to-REST group-recipient encoding + the PR #72689 cold-store fix ported to the refactored `hermesNpmLib` (only `npmRoot = repoRoot` remains needed; desktop/tui/web eval-time reads were removed upstream) + managed OAuth listener shutdown. |
| **Validation** | 2026-08-16 on the rebased tree: Signal suites + full OAuth file pass (`144 passed, 1 skipped`); merge-adjacent suites (`test_status`, `test_send_message_tool`, `test_signal_media`, `test_mcp_reconnect_signal`) pass (`116 passed, 5 skipped`); `nix eval .#packages.x86_64-linux.default.name` → `hermes-agent-0.20.2`. All service-module assumptions re-verified on 0.20.2: NixOS module options, cron CLI flags/output format (`Name:`/`[paused]`/`[active]`, 12-hex IDs), `cron.jobs.get_job/update_job` + `context_from`, `HERMES_PYTHON` shell-wrapper export, `platform_toolsets`, `channel_overrides` in the cached-agent signature, oauth `client_secret`/`redirect_port` config keys, `[SILENT]` filter, `cron.wrap_response`, `errors.log` path, `## Response`/`## Error` output markers. Validate nix-config with `task nix:build-nixos host=forge`, then verify Signal reply and scoped MCP login on forge. |
| **Check** | After upstream PRs #53696, #72689, and #88131 all merge, restore `url = "github:NousResearch/hermes-agent"`, update only the Hermes lock node, and rerun the cold-store, Signal, and fixed-port OAuth checks before removing this entry. The OAuth fork commit is confirmed still required on Linux (2026-08-17 probe on forge); #88131 upstreams it. |
| **Upstream** | [NousResearch/hermes-agent#53696](https://github.com/NousResearch/hermes-agent/pull/53696), [NousResearch/hermes-agent#72689](https://github.com/NousResearch/hermes-agent/pull/72689), [NousResearch/hermes-agent#88131](https://github.com/NousResearch/hermes-agent/pull/88131) (OAuth listener fix, submitted 2026-08-17) |
| **Impact** | Without the pin, Hermes cannot connect to forge's Signal transport; fresh CI runners/cold Forge stores can fail before building; and pasted OAuth callbacks cannot complete reliably with a fixed redirect port. |

---

## Package Overrides (overlays/default.nix)

### copyparty - Security Release Pin

| Field | Value |
| --- | --- |
| **Added** | 2026-07-28 |
| **Affects** | Stable copyparty 1.20.12 and unstable copyparty 1.20.13 in the current lock file |
| **Reason** | Versions before 1.20.17 allow file-key/directory-key confusion ([GHSA-x5pq-m9p8-f4vx](https://github.com/9001/copyparty/security/advisories/GHSA-x5pq-m9p8-f4vx)); versions before 1.20.19 also allow the optional FTP server to upload outside configured volumes ([GHSA-phv8-wgjp-g4p9](https://github.com/9001/copyparty/security/advisories/GHSA-phv8-wgjp-g4p9)). |
| **Workaround** | Override only the source and version to upstream 1.20.19 while a channel remains older. Each channel automatically returns to its native nixpkgs package once it reaches 1.20.19 or newer. The forge service also leaves FTP disabled. |
| **Check** | Remove this override when both pinned nixpkgs channels provide copyparty >= 1.20.19, then rebuild the copyparty package and forge closure. |
| **Impact** | Without the override, the deployed file service would retain known authorization vulnerabilities. |

### Starship and Lima - Stable Darwin Linker for macOS 26

| Field | Value |
| --- | --- |
| **Added** | 2026-07-17 |
| **Affects** | `pkgs.unstable.starship` 1.26.0 and `pkgs.unstable.lima` 2.1.4 on `aarch64-darwin` |
| **Reason** | Unstable ld64 957.1 crashes with `EXC_BREAKPOINT`/`SIGTRAP` in `ld::passes::stubs::Pass::process` while linking both packages on macOS 26.5. Disassembly maps the trap to the virtual `atom->fixupsEnd()` call. Apple ld64 contains one-past-the-end `vector::operator[]` iterator implementations, which the unstable libc++ build rejects through `__libcpp_verbose_abort`. |
| **Workaround** | Keep the unstable application versions but pass `--ld-path=<stable Nix ld64>` only to their builds. Lima also receives `-Wno-unused-command-line-argument` because cgo compiles with `-Werror` before the final link. The linker is still a pinned Nix store input; `/usr/bin/ld` is not used. |
| **Validation** | Starship built with 1,228 tests passing. Lima built, codesigned, passed its 2.1.4 version check, and validated its default template. The complete nix-darwin closure subsequently built successfully. |
| **Check** | Remove the overrides and build both packages whenever unstable ld64 changes. Delete this workaround once both native unstable builds and `task nix:build-darwin host=rymac` pass. |
| **Upstream** | No exact public issue matched ld64 957.1 + macOS 26 as of 2026-07-17. Relevant source: Apple ld64 `src/ld/passes/stubs/stubs.cpp` and iterator implementations under `src/ld`. |
| **Impact** | Without the workaround, the Darwin system closure cannot build because both Lima and Starship fail during linking. |

### cooklang-federation - Tailwind v4 Import → v3 Compatibility Patch

| Field | Value |
|-------|-------|
| **Added** | 2026-02-11 |
| **Last reviewed** | 2026-05-23 (still required at upstream HEAD `d4131c0b`) |
| **Location** | `pkgs/cooklang-federation.nix` (`postPatch`) |
| **Affects** | `cooklang-federation` CSS build (ExecStartPre uses `pkgs.tailwindcss_3`) |
| **Reason** | Upstream `styles/input.css` ships `@import "tailwindcss";` (Tailwind v4 syntax). However the same repo has **no `package.json`** and `tailwind.config.js` is v3-format (`module.exports = { ... }`) — i.e. upstream is in a broken hybrid state and cannot actually build its own CSS without external tooling. Our service module runs `pkgs.tailwindcss_3` at start, which doesn't understand the v4 `@import` directive. |
| **Workaround** | `postPatch` substitutes `@import "tailwindcss";` with the v3 `@tailwind base; @tailwind components; @tailwind utilities;` directives so `tailwindcss_3` can compile the file. |
| **Check** | Re-evaluate when upstream either (a) completes the v4 migration (adds `package.json`, rewrites the JS config to `@theme` blocks) — then switch `modules/nixos/services/cooklang-federation/default.nix` to `pkgs.tailwindcss_4` and drop this patch — or (b) reverts the `input.css` change to v3 directives, in which case drop the patch and keep `tailwindcss_3`. |
| **Upstream** | https://github.com/cooklang/federation (issue tracker is disabled; cannot file) |
| **Impact** | Without fix: ExecStartPre fails when `tailwindcss_3` tries to compile `input.css`; service won't start with a working stylesheet. |

### cooklang-federation - Crawler Search Index Integration Patch

| Field | Value |
|-------|-------|
| **Added** | 2026-02-11 |
| **Last reviewed** | 2026-07-27 (still required at upstream HEAD `5d900752`) |
| **Location** | `pkgs/cooklang-federation.nix` + `pkgs/patches/cooklang-federation-normalize-field-query.patch` |
| **Affects** | `cooklang-federation` recipe search (RSS-sourced recipes) |
| **Reason** | Upstream `Crawler` (`src/crawler/mod.rs`) does **not** hold a `SearchIndex` reference and never writes to Tantivy after an RSS crawl. Only the GitHub indexer (`src/github/indexer.rs`) commits to the search index. Result on a vanilla build: every recipe pulled from an RSS feed is stored in SQLite but is **invisible to `/search`**. Additionally, the upstream schema defines `servings` and `total_time` as `FAST | STORED` only (no `INDEXED`), so range queries against those fields silently return nothing. |
| **Workaround** | Local patch adds: (1) `search_index: Option<Arc<SearchIndex>>` field + `set_search_index()` setter on `Crawler`; (2) `process_entry` returns `(ProcessResult, recipe_id)`; (3) new `Crawler::index_recipes()` called after each `crawl_feed()` to commit new/updated recipes to Tantivy and mark them via `mark_recipe_indexed`; (4) GitHub indexer also calls `mark_recipe_indexed` + `search_index.reload()`; (5) schema gets `INDEXED` on `servings` and `total_time`. |
| **Check** | At each nvfetcher bump: if upstream `Crawler` ever gains a `search_index` field or calls `index_recipes()` from `crawl_feed()`, drop the patch. As of `5d900752` (2026-07-12), upstream still stores RSS recipes only in SQLite and requires this patch to add them to Tantivy. |
| **Upstream** | https://github.com/cooklang/federation (issue tracker is disabled; consider submitting as a PR if upstream re-enables contributions). |
| **Impact** | Without fix: RSS-feed recipes never appear in search results; range filters on servings/cook time return empty. The patch IS the reason the service is useful on this host. |

---

### homekit-audio-proxy - Custom Package (not yet in nixpkgs)

| Field | Value |
|-------|-------|
| **Added** | 2026-05-07 |
| **Affects** | `pythonPackagesExtensions` (unstable overlay) |
| **Reason** | Home Assistant 2026.4's `homekit` integration unconditionally `from homekit_audio_proxy import AudioProxy` at module top of `homeassistant/components/homekit/type_cameras.py`. The HASS Bridge (port 21064) — i.e. all Apple Home exposure — fails to load without it. The package is on PyPI (v1.2.1, Apache-2.0, runtime dep `cryptography>=43`) but had not landed in nixos-unstable as of this date. |
| **Workaround** | Custom `buildPythonPackage` definition in the unstable overlay (mirrors the `thermoworks-cloud` pattern), wired into HA via `services.home-assistant.extraPackages`. |
| **Check** | When `homekit-audio-proxy` lands in nixpkgs |
| **Upstream** | https://github.com/bdraco/homekit-audio-proxy |
| **Impact** | Without fix: HomeKit Bridge fails to start; no Apple Home device exposure works. |

### aioacaia - Custom Package (not yet in nixpkgs)

| Field | Value |
|-------|-------|
| **Added** | 2026-05-07 |
| **Affects** | `pythonPackagesExtensions` (unstable overlay) |
| **Reason** | Home Assistant's built-in `acaia` integration imports `aioacaia` at config-flow time. Without it, opening the Acaia config flow raises ModuleNotFoundError. PyPI v0.1.18 (AGPL-3.0). |
| **Workaround** | Custom `buildPythonPackage` definition in the unstable overlay, wired into HA via `services.home-assistant.extraPackages`. Runtime deps: `bleak`, `bleak-retry-connector`. |
| **Check** | When `aioacaia` lands in nixpkgs |
| **Upstream** | https://github.com/zweckj/aioacaia |
| **Impact** | Without fix: the Acaia integration can't be configured; runtime use blocked. |

### aiounittest - Re-enabled on Python 3.14

| Field | Value |
|-------|-------|
| **Added** | 2026-04-28 |
| **Affects** | `pythonPackagesExtensions` (unstable overlay) |
| **Reason** | Upstream nixpkgs marks `aiounittest` 1.5.0 as `disabled = pythonAtLeast "3.14"` because the package's own test suite fails on 3.14. The library itself works fine at runtime; it is a legacy pre-Python-3.8 async-test shim that `unittest.IsolatedAsyncioTestCase` superseded years ago. Several home-assistant transitive deps still list it as a check input, so without an override the entire forge/luna closure fails to evaluate once `pkgs.unstable.python3` defaults to 3.14. |
| **Workaround** | `disabled = false; doCheck = false; doInstallCheck = false; meta.broken = false;` |
| **Check** | When aiounittest > 1.5.0 lands or nixpkgs un-disables on 3.14 |
| **Upstream** | https://github.com/kwarunek/aiounittest/issues/28 |
| **Impact** | Without fix: all CI builds fail with `error: aiounittest-1.5.0 not supported for interpreter python3.14` during forge/luna closure evaluation. |

### httpx-auth - Test Suite Disabled on Python 3.14

| Field | Value |
|-------|-------|
| **Added** | 2026-04-28 |
| **Affects** | `pythonPackagesExtensions` (unstable overlay) |
| **Reason** | The `httpx-auth` test suite (`tests/oauth2/implicit/*`) uses 6-byte HMAC keys in its OAuth2 fixtures. On Python 3.14 the bundled pyjwt raises `jwt.warnings.InsecureKeyLengthWarning` for HMAC keys shorter than 32 bytes, and the project's `filterwarnings` config promotes it to an error, causing ~30 tests to fail. Runtime is unaffected — only the test fixtures are too short. |
| **Workaround** | `doCheck = false; doInstallCheck = false;` |
| **Check** | When httpx-auth > 0.23.1 fixes its fixtures, or pyjwt downgrades the warning |
| **Upstream** | https://github.com/Colin-b/httpx_auth |
| **Impact** | Without fix: forge build fails (home-assistant transitive closure cannot be built). |

### thelounge - sqlite3 Native Module Fix

| Field | Value |
|-------|-------|
| **Added** | 2026-01-09 |
| **Affects** | `thelounge` (stable overlay) |
| **Reason** | nixpkgs thelounge package builds sqlite3 native module correctly, then deletes the `build/` directory in `postInstall`, breaking the module at runtime |
| **Error** | `[ERROR] Unable to load sqlite3 module. See https://github.com/mapbox/node-sqlite3/wiki/Binaries` |
| **Workaround** | `postInstall = "";` (remove the erroneous `rm -r .../sqlite3/build/`) |
| **Check Version** | Any thelounge update in nixpkgs |
| **Upstream** | https://github.com/NixOS/nixpkgs - should file bug report |
| **Impact** | Without fix: message history (scrollback) not persisted between restarts |

### granian - Test Suite Disabled

| Field | Value |
|-------|-------|
| **Added** | 2025-12-19 (escalated 2026-05-13) |
| **Affects** | `pythonPackagesExtensions` (stable + unstable) |
| **Reason** | 2025-12-19: HTTPS tests use self-signed certs that fail SSL verification in Nix sandbox. 2026-05-13: a non-HTTPS test wedged `nixos-upgrade.service` on `forge` for ~3.5 days (process used 3h CPU over 3.5d wall clock — almost certainly a network-dependent socket test waiting on an absurdly long timeout). Granian's behavior is exercised at runtime by paperless and home-assistant; the upstream pytest suite adds no extra safety while introducing a hard availability risk during builds. |
| **Workaround** | `doCheck = false` (previously `disabledTestPaths = ["tests/test_https.py"]`, escalated after the 2026-05-13 incident) |
| **Check Version** | Any granian update in nixpkgs |
| **Upstream** | https://github.com/emmett-framework/granian (check for sandbox-friendly tests) |
| **nixpkgs** | Check if tests are already disabled upstream |

### aio-georss-client - Tests Disabled (unstable only)

| Field | Value |
|-------|-------|
| **Added** | Unknown (pre-existing) |
| **Affects** | `pythonPackagesExtensions` (unstable overlay) |
| **Reason** | Test failure with Python 3.13 |
| **Workaround** | `doCheck = false; meta.broken = false` |
| **Check Version** | Python 3.14 release or package update |
| **Upstream** | https://github.com/NixOS/nixpkgs/issues/ (find issue) |

### kubectl-node-shell - Platform Meta Removed

| Field | Value |
|-------|-------|
| **Added** | Unknown (pre-existing) |
| **Affects** | unstable overlay |
| **Reason** | Platform restrictions preventing installation |
| **Workaround** | `builtins.removeAttrs prevAttrs.meta ["platforms"]` |
| **Check Version** | Any kubectl-node-shell update |

### kubectl-view-secret - Binary Rename

| Field | Value |
|-------|-------|
| **Added** | Unknown (pre-existing) |
| **Affects** | unstable overlay |
| **Reason** | Incorrect binary name in package |
| **Workaround** | `mv $out/bin/cmd $out/bin/kubectl-view_secret` |
| **Check Version** | Any kubectl-view-secret update |
| **Upstream** | Check if fixed in nixpkgs |

### open-webui - Drop `--legacy-peer-deps` on Frontend Build

| Field | Value |
|-------|-------|
| **Added** | 2026-05-26 |
| **Affects** | `open-webui` frontend (unstable overlay); forge service |
| **Reason** | open-webui 0.9.5 bundles `bits-ui` v2.16.3, which declares `@internationalized/date` as a peer dependency. The frontend derivation in nixpkgs invoked `npm ci` with `--force --legacy-peer-deps`; under `--legacy-peer-deps`, npm reverts to v6 behaviour and skips installing peer deps entirely. The package was therefore absent from `node_modules`, and Vite/Rollup aborted with `[vite]: Rollup failed to resolve import "@internationalized/date" from ".../node_modules/bits-ui/dist/internal/date-time/utils.js"`. |
| **Workaround** | Override `passthru.frontend` to set `npmFlags = [ "--force" ]` (drop `--legacy-peer-deps`) and re-point `makeWrapperArgs`' `FRONTEND_BUILD_DIR` to the patched frontend. `npmDepsHash` is unchanged (the lockfile already includes `@internationalized/date`; only npm's install behaviour differs). |
| **Upstream** | Fixed in nixpkgs commit [`be3620d`](https://github.com/NixOS/nixpkgs/commit/be3620d) (2026-05-23). Our `nixpkgs-unstable` lock is from 2026-05-22, one day prior. |
| **Check** | When `nixpkgs-unstable` lock advances past commit `be3620d`, remove this override entirely. |
| **Impact** | Without fix: forge build fails on `open-webui-frontend-0.9.5`, blocking the entire system closure. |

### inetutils - Darwin Build Failure (format-security)

| Field | Value |
|-------|-------|
| **Added** | 2026-02-12 |
| **Affects** | stable overlay (Darwin only) |
| **Reason** | inetutils 2.7 gnulib `openat-die.c` triggers `-Werror,-Wformat-security` on newer macOS clang |
| **Workaround** | `NIX_CFLAGS_COMPILE += -Wno-error=format-security` (Darwin only) |
| **Check Version** | inetutils > 2.7 or nixpkgs gnulib patch |
| **Upstream** | https://github.com/NixOS/nixpkgs/issues/ (gnulib compat) |
| **Impact** | Without fix: home-manager fails to build on macOS (inetutils is a dependency for `hostname`) |

---

## Unstable Package Usage

Services using `pkgs.unstable.*` instead of stable packages:

### beszel

| Field | Value |
|-------|-------|
| **Location** | `modules/nixos/services/beszel/default.nix` |
| **Reason** | Package not available or too old in stable |
| **Check** | When package lands in stable nixpkgs |

### n8n

| Field | Value |
|-------|-------|
| **Location** | `modules/nixos/services/n8n/default.nix` |
| **Reason** | Need latest version for features/fixes |
| **Check** | Compare stable vs unstable versions |

### open-webui

| Field | Value |
|-------|-------|
| **Location** | `hosts/forge/services/open-webui.nix` |
| **Reason** | Rapidly evolving AI tool, need latest features |
| **Check** | Monthly - may always want unstable for this |

### zigbee2mqtt

| Field | Value |
|-------|-------|
| **Location** | `hosts/forge/services/zigbee2mqtt.nix` |
| **Reason** | Device compatibility requires newer versions |
| **Check** | When stable version is within 1-2 minor versions |

### pocket-id

| Field | Value |
|-------|-------|
| **Location** | `hosts/forge/services/pocketid.nix` |
| **Reason** | New package, not in stable yet |
| **Check** | When package lands in stable nixpkgs |

### zfs_unstable

| Field | Value |
|-------|-------|
| **Location** | `modules/nixos/filesystems/zfs/default.nix` |
| **Reason** | Kernel compatibility, newer features, bug fixes |
| **Check** | Intentional - ZFS should track latest for security |

---

## Module-Level Workarounds

### home-assistant - Install Check Disabled

| Field | Value |
|-------|-------|
| **Location** | `modules/nixos/services/home-assistant/default.nix:28` |
| **Reason** | `doInstallCheck = false` to avoid test failures |
| **Workaround** | `overrideAttrs (old: old // { doInstallCheck = false; })` |
| **Check** | When home-assistant package is updated |

### NetVisor - OIDC terms_accepted Injection

| Field | Value |
|-------|-------|
| **Location** | `modules/nixos/services/netvisor/default.nix:531-542` |
| **Reason** | Frontend doesn't always include `terms_accepted` parameter |
| **Workaround** | Caddy rewrite rule to inject the parameter |
| **Upstream** | https://github.com/netvisor-io/netvisor |
| **Check** | When NetVisor is updated |

### LiteLLM - Generic SSO Role Bug

| Field | Value |
|-------|-------|
| **Location** | `modules/nixos/services/litellm/default.nix:494` |
| **Reason** | `generic_response_convertor` always sets `user_role=None` |
| **Workaround** | Use `proxyAdminId` instead of role claim |
| **Upstream** | https://github.com/BerriAI/litellm |
| **Check** | LiteLLM updates, specifically SSO handling |

### Plex - VA-API Hardware Transcoding Disabled (Native Mode)

| Field | Value |
|-------|-------|
| **Added** | 2025-12-31 |
| **Location** | `modules/nixos/services/plex/default.nix` (native mode config section) |
| **Reason** | Plex's FHS sandbox bundles older glibc that lacks `__isoc23_sscanf` symbol present in NixOS's libva.so (built against glibc 2.38+). Including `/run/opengl-driver/lib` in LD_LIBRARY_PATH causes Plex to crash with "Error relocating /run/opengl-driver/lib/libva.so.2: __isoc23_sscanf: symbol not found" |
| **Workaround** | In native mode: LD_LIBRARY_PATH excludes `/run/opengl-driver/lib`, only includes `/run/opengl-driver/lib/dri`. Hardware transcoding (VA-API) is unavailable; software transcoding works. |
| **Upstream** | https://github.com/NixOS/nixpkgs/issues/468070 |
| **Check** | When nixpkgs #468070 is resolved, or Plex updates their bundled glibc |
| **Solution Available** | Set `modules.services.plex.deploymentMode = "container"` to use `ghcr.io/home-operations/plex` (Ubuntu 24.04 base with matching glibc). VA-API hardware transcoding works in container mode. |

### Scrypted - Force Intel iHD VAAPI Driver / Drop NVIDIA Render Node

| Field | Value |
|-------|-------|
| **Added** | 2026-06-25 |
| **Location** | `hosts/forge/services/scrypted.nix` (`services.udev.extraRules`, `devices`, `extraEnv.LIBVA_DRIVER_NAME`) |
| **Reason** | forge exposes two render nodes: `renderD128` (NVIDIA, PCI `0000:01:00.0`, nouveau) and `renderD129` (Intel UHD 630, PCI `0000:00:02.0`, i915). libva enumerates every node under `/dev/dri` and was loading `nouveau_drv_video.so`, which fails with `Failed to initialise VAAPI connection: 2 (resource allocation failed)`. The Scrypted decoder process then became "unresponsive" → 0 frames decoded → 0 object detections on all cameras. |
| **Workaround** | (1) A udev rule creates PCI-stable, **colon-free** aliases `/dev/dri/intel-render` and `/dev/dri/intel-card` for the Intel iGPU (matched on `KERNELS=="0000:00:02.0"`). The kernel's own `/dev/dri/by-path/pci-0000:00:02.0-*` symlinks **cannot** be passed to podman `--device` because podman splits the argument on the colons in the PCI address (it tries to `stat /dev/dri/by-path/pci-0000`). (2) These aliases are passed as the `--device` *source*; the *destination* MUST be the Intel node's **real host name** (`renderD129`/`card2` today). The container shares the host's `/sys`, and libva/iHD resolves the GPU via `/sys/class/drm/<node-name>` derived from the device path — exposing the Intel device as `renderD128` (where host `/sys` points at nouveau) or a custom alias makes iHD inspect the wrong/missing sysfs node and fail with `Cannot open a VA display`. Scrypted enumerates `/dev/dri` and tries every `renderD*`, so exposing exactly `renderD129` makes it select Intel. (3) `LIBVA_DRIVER_NAME=iHD` forces the Intel media driver (`intel-media-driver`, bundled in `ghcr.io/koush/scrypted:latest`). |
| **Check** | If a kernel update renumbers the DRM nodes (Intel → `renderD128`), update the `devices` destinations in `scrypted.nix` to match; otherwise scrypted falls back to software/vulkan decode (graceful, not a crash). Re-add the NVIDIA node only if/when CUDA/TensorRT passthrough is properly wired (`/dev/nvidia*` + NVIDIA userspace driver, not nouveau). |
| **Upstream** | N/A (host hardware/driver enumeration issue, not an upstream bug) |
| **Impact** | Without fix: hardware decode fails, decoder dies, no camera frames or detections. |

### NFS Media Mount - Soft Mount to Prevent System Freeze

| Field | Value |
|-------|-------|
| **Added** | 2026-02-21 |
| **Location** | `hosts/forge/infrastructure/storage.nix` (nfsMounts.media) |
| **Reason** | Previous `hard` mount (default) caused full system freeze on 2026-02-21 when NAS became temporarily unreachable during midnight backup storm. All processes touching `/mnt/data` entered uninterruptible D-state, cascading to a complete host hang requiring hard reboot. |
| **Workaround** | Changed to `soft,timeo=150,retrans=3`. NFS ops now return EIO after ~45s instead of blocking forever. Media services may see transient I/O errors during NAS blips. |
| **Check** | If NFS reliability becomes an issue (data corruption from partial writes), consider switching back to `hard` with `timeo=300` and adding a systemd watchdog. |
| **Tradeoff** | `soft` mount risks returning EIO on transient network issues, which could cause media service errors. This is far safer than `hard`-mount freezes that require physical intervention. |

### Restic Backup Memory Limit Raised to 2G on Forge

| Field | Value |
|-------|-------|
| **Added** | 2026-05-07 |
| **Location** | `hosts/forge/infrastructure/backup.nix` (`modules.services.backup.performance.resources`) |
| **Reason** | The module-default 512 MiB `MemoryMax` for auto-discovered restic backup jobs (`modules/nixos/services/backup/default.nix`) was too low for forge: services with thousands of snapshots (paperless / home-assistant: 1545 each) consistently hit the cgroup limit at ~511 MB RSS just loading the restic index. On 2026-05-07, six services (`paperless`, `worldmonitor`, `zigbee2mqtt`, `home-assistant`, `esphome`, `pinchflat`) were OOM-killed and never recovered, triggering `ResticBackupStale` alerts. Smaller-repo services hit the limit too but recovered on retry. |
| **Workaround** | Set host-level defaults `performance.resources = { memory = "2G"; memoryReservation = "1G"; cpus = "1.5"; }`. Per-service overrides (scrypted, plex) still win because the orchestrator falls back to `performance.resources` only when `service.backup.resources` is null. |
| **Check** | When restic itself ships meaningful index-memory improvements (tracking issue: <https://github.com/restic/restic/issues/2523>) or if forge moves to a smaller-RAM host. |
| **Related** | Same OOM pattern previously addressed per-service for scrypted (2026-02-21) and plex; this generalises the fix to the host default so future services benefit automatically. |

### pgBackRest Auto-Retry on Transient NFS Errors

| Field | Value |
|-------|-------|
| **Added** | 2026-05-08 |
| **Location** | `hosts/forge/services/pgbackrest.nix` (`retryPolicy` applied to all 3 backup units) |
| **Reason** | pgBackRest backup units occasionally fail with NFS-coherency errors against `/mnt/nas-postgresql`: `[073] unable to sync missing path '.../pg_dynshmem'` and `[061] unable to remove path '.../base/<oid>': Directory not empty`. These are intermittent (~once per week, 22 lifetime [073] events in the file log going back to Dec 2025). Without `Restart=`, a single transient failure took out the entire daily full backup until 02:00 the next night, triggering `PgBackRestFullBackupStale` alerts. |
| **Workaround** | Set `Restart=on-failure`, `RestartSec=15min`, `StartLimitBurst=3`, `StartLimitIntervalSec=2h` on `pgbackrest-full-backup`, `pgbackrest-incr-backup`, `pgbackrest-incr-r2-backup`. The 15-minute backoff is long enough for transient NFS issues to clear; the burst cap surfaces sustained failures via `OnFailure=` notifications and `PgBackRestFullBackupStale` rather than looping forever. |
| **Check** | If errors persist after this is deployed, consider enabling pgBackRest file bundling (`--bundle=y` / `repo1-bundle=y`) to reduce per-backup file count by 10-100×, which directly attacks the NFS-many-small-files surface. Bundling is a one-time per-stanza decision and doesn't break existing backups. |
| **Related** | An earlier related workaround (`EXCLUDE_OPTS="--exclude=.config --exclude=.local"`, 2026-02-02) addressed a different `[073]` instance where `.config`/`.local` dirs polluted PGDATA. Today's `pg_dynshmem` failure is a normal PG directory and can't be excluded that way. |
| **Verified** | 2026-05-11: the retry fired exactly as designed in production. The 2026-05-11 02:00 full backup hit a `[061]` error at 02:02, systemd waited 15 min, retried at 02:17, and completed successfully at 02:24 (NFS) and 02:44 (R2). No alert fired. |

### Profilarr - Disabled (Upstream Image Gone)

| Field | Value |
|-------|-------|
| **Added** | 2026-05-11 |
| **Location** | `hosts/forge/services/profilarr.nix` (`enable = false`) |
| **Reason** | The original `ghcr.io/profilarr/profilarr` image registry returns 403 Forbidden as of May 2026. The project moved to <https://github.com/Dictionarry-Hub/profilarr> but no public container image is published yet at the new location (the org's packages page shows "No packages published"). The README documents `ghcr.io/dictionarry-hub/profilarr:latest` but that path is also unauthorized. The service had also never produced any output on this host: `/var/lib/profilarr/` was empty and the journal had zero successful runs in retention. |
| **Workaround** | `enable = false` with a FIXME comment pointing at the upstream situation. `recyclarr` (still enabled) does the equivalent TRaSH-guides sync work, so disabling profilarr has no functional impact on this host. |
| **Check** | Periodically check <https://github.com/orgs/Dictionarry-Hub/packages?repo_name=profilarr> for a published image. When V2 ships and an image lands, update the `image` ref in `hosts/forge/services/profilarr.nix` and toggle `enable = true`. |
| **Related** | Same FIXME-disable pattern used for n8n in `hosts/forge/services/n8n.nix`. |

---

## Custom Packages with doCheck=false

These are custom package definitions where tests are disabled:

| Package | Location | Reason |
|---------|----------|--------|
| tqm | `modules/nixos/services/tqm/package.nix` | Tests require network/fixtures |
| qbit-manage | `modules/nixos/services/qbit-manage/package.nix` | Tests require network/fixtures |
| cooklang-federation | `pkgs/cooklang-federation.nix` | Rust tests require fixtures |
| cooklang-cli | `pkgs/cooklang-cli.nix` | Rust tests require fixtures |
| usage | `pkgs/usage.nix` | 4 test failures in complete_word test suite (v2.16.1) |
| kubectl-* | `pkgs/kubectl-*.nix` | Go tests require k8s cluster |

**Note**: Most of these are intentional for custom packages where tests aren't meaningful in the Nix sandbox.

---

## How to Add New Workarounds

When adding a temporary workaround:

1. **Add inline comment** in the code with:
   - Date added
   - Brief reason
   - Upstream issue link (if exists)

2. **Add entry to this document** with:
   - Location in codebase
   - Full explanation
   - Version/condition to check for removal
   - Upstream links

3. **Example inline comment**:
```nix
# WORKAROUND (2025-12-19): granian HTTPS tests fail with expired certs
# Upstream: https://github.com/emmett-framework/granian/issues/XXX
# Remove when: granian >= X.Y.Z or nixpkgs updates test infrastructure
```

---

## Automation Ideas (Future)

- [ ] Add Renovate/Dependabot comment to check workarounds on package updates
- [ ] Create `nix flake check` assertion that warns about old workarounds
- [ ] Add calendar reminder for monthly review
