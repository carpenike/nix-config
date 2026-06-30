# Temporary Workarounds & Overrides

This document tracks temporary workarounds, package overrides, and unstable package usage that should be periodically reviewed. These exist due to upstream bugs, missing features in stable, or test failures in the Nix build sandbox.

**Last Reviewed**: 2026-05-23
**Next Review**: 2026-06-23 (monthly)

---

## Review Checklist

When reviewing workarounds:
1. Check if upstream issue is resolved
2. Check if nixpkgs has been updated with a fix
3. Test removing the workaround and rebuilding
4. Update this document with findings

---

## Package Overrides (overlays/default.nix)

### coachiq - Missing `access_token_expire_minutes` Compatibility Patch

| Field | Value |
|-------|-------|
| **Added** | 2026-06-29 |
| **Location** | `hosts/nixpi/coachiq.nix` (`services.coachiq.package.overridePythonAttrs`) |
| **Affects** | nixpi CoachIQ startup at upstream rev `f5699554751cf22d9890f332209a0d3ea461d9f8` |
| **Reason** | `backend/core/security_config_validator.py` references stale `AuthenticationSettings` fields (`access_token_expire_minutes`, `mode`, `admin_password_hash`, `enable_magic_link`). The model now uses `jwt_expire_minutes`, `admin_password`, and `enable_magic_links`, and has no `mode` field. CoachIQ validates successfully in `coachiq-validate-config`, then crashes during FastAPI startup with `AttributeError`. |
| **Workaround** | Patch the validator to read the current field names and treat missing `mode` as `"none"`, skipping legacy single/multi mode checks. |
| **Check** | Remove once upstream either restores the field on `AuthenticationSettings` or updates the validator to use the security config service/defaults. |
| **Upstream** | https://github.com/carpenike/coachiq |
| **Impact** | Without fix: `coachiq.service` exits during app lifespan startup after SOPS and CAN recorder initialization succeed. |

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
| **Last reviewed** | 2026-05-23 (still required at upstream HEAD `d4131c0b`) |
| **Location** | `pkgs/cooklang-federation.nix` + `pkgs/patches/cooklang-federation-normalize-field-query.patch` |
| **Affects** | `cooklang-federation` recipe search (RSS-sourced recipes) |
| **Reason** | Upstream `Crawler` (`src/crawler/mod.rs`) does **not** hold a `SearchIndex` reference and never writes to Tantivy after an RSS crawl. Only the GitHub indexer (`src/github/indexer.rs`) commits to the search index. Result on a vanilla build: every recipe pulled from an RSS feed is stored in SQLite but is **invisible to `/search`**. Additionally, the upstream schema defines `servings` and `total_time` as `FAST | STORED` only (no `INDEXED`), so range queries against those fields silently return nothing. |
| **Workaround** | Local patch adds: (1) `search_index: Option<Arc<SearchIndex>>` field + `set_search_index()` setter on `Crawler`; (2) `process_entry` returns `(ProcessResult, recipe_id)`; (3) new `Crawler::index_recipes()` called after each `crawl_feed()` to commit new/updated recipes to Tantivy and mark them via `mark_recipe_indexed`; (4) GitHub indexer also calls `mark_recipe_indexed` + `search_index.reload()`; (5) schema gets `INDEXED` on `servings` and `total_time`. |
| **Check** | At each nvfetcher bump: if upstream `Crawler` ever gains a `search_index` field or calls `index_recipes()` from `crawl_feed()`, drop the patch. Currently upstream is low-velocity (last commit 2026-04-13, ~4 commits in 2026) so churn risk is low. |
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

### Omada Controller - Pinned to v5.x (No AVX on Luna)

| Field | Value |
|-------|-------|
| **Added** | 2026-03-10 |
| **Last reviewed** | 2026-05-04 |
| **Location** | `modules/nixos/services/omada/default.nix` (container image) |
| **Reason** | Luna's Intel Celeron J3455 (Apollo Lake) lacks AVX instruction support. Omada Controller v6.x ships MongoDB 8 which requires AVX (or armv8.2-a on arm64). Container exits immediately with `ERROR: your system does not support AVX`. |
| **Workaround** | Pinned to `mbentley/omada-controller:5.15.24.19` — currently the latest v5.x release. v5.x uses the embedded MongoDB 3.6 which has no AVX requirement. The image is still being refreshed by upstream as of 2026-05-04. |
| **Upstream** | <https://github.com/mbentley/docker-omada-controller/blob/master/README.md#your-system-does-not-support-avx-or-armv82-a> |
| **Available v6 path (not chosen)** | Set `MONGO_EXTERNAL=true` + `EAP_MONGOD_URI=…` and run a separate non-AVX MongoDB container. Upstream documents this as the only AVX-free way onto v6. Rejected because the chosen MongoDB build would need to be a custom or non-default image (TP-Link officially specs MongoDB 8 for v6; older versions may lack required features), and the long-term plan is to move Omada off Luna entirely. |
| **Planned resolution** | **Migrate Omada controller to forge** (Intel Xeon, has AVX). This unblocks the upstream-supported v6 path with no surgery. Tracked in [#434](https://github.com/carpenike/nix-config/issues/434). |
| **Re-check trigger** | (a) Omada migrated to forge (then drop this entry entirely), (b) Luna replaced with AVX-capable hardware, (c) `mbentley` archives the v5 line (would force the migration). |

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
