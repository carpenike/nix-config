# Temporary Workarounds & Overrides

This document tracks temporary workarounds, package overrides, and unstable package usage that should be periodically reviewed. These exist due to upstream bugs, missing features in stable, or test failures in the Nix build sandbox.

**Last Reviewed**: 2026-01-09
**Next Review**: 2026-02-09 (monthly)

---

## Review Checklist

When reviewing workarounds:
1. Check if upstream issue is resolved
2. Check if nixpkgs has been updated with a fix
3. Test removing the workaround and rebuilding
4. Update this document with findings

---

## Package Overrides (overlays/default.nix)

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

### granian - HTTPS Test Disabled

| Field | Value |
|-------|-------|
| **Added** | 2025-12-19 |
| **Affects** | `pythonPackagesExtensions` (stable + unstable) |
| **Reason** | HTTPS tests use self-signed certs that fail SSL verification in Nix sandbox |
| **Workaround** | `disabledTestPaths = ["tests/test_https.py"]` |
| **Check Version** | Any granian update in nixpkgs |
| **Upstream** | https://github.com/emmett-framework/granian (check for cert updates) |
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

---

## Custom Packages with doCheck=false

These are custom package definitions where tests are disabled:

| Package | Location | Reason |
|---------|----------|--------|
| tqm | `modules/nixos/services/tqm/package.nix` | Tests require network/fixtures |
| qbit-manage | `modules/nixos/services/qbit-manage/package.nix` | Tests require network/fixtures |
| beads | `pkgs/beads.nix` | Tests require network/fixtures |
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
