# Container Image Management Strategy

## Overview
This document outlines the strategy for managing container images in this NixOS configuration, ensuring stability, reproducibility, and security while staying current with updates.

## Philosophy

### Why Avoid `:latest` Tags?

**Problems with `:latest`:**
- **Unpredictable Updates**: `nixos-rebuild` can pull different images without code changes
- **No Reproducibility**: Cannot reliably recreate the exact system state
- **Difficult Rollbacks**: Hard to identify which version was working
- **CI/CD Instability**: Builds can fail unpredictably from upstream changes

**NixOS Impact:**
The declarative nature of NixOS is undermined when container images are mutable. Your configuration should define the *exact* state of the system.

## Best Practices Hierarchy

### 1. Good: Version Tags
```nix
image = "lscr.io/linuxserver/sonarr:4.0.4.1491-ls185";
```
- **Pros**: Human-readable, specific software version
- **Cons**: Tags are mutable (can be force-pushed by maintainer)
- **Use Case**: Development environments, testing

### 2. Better: Digest Pinning
```nix
image = "lscr.io/linuxserver/sonarr@sha256:f3ad4f59e6e5e4a...";
```
- **Pros**: Immutable, content-addressed identifier
- **Cons**: Not human-readable, hard to track versions
- **Use Case**: Maximum reproducibility required

### 3. Best: Version + Digest (Recommended)
```nix
image = "lscr.io/linuxserver/sonarr:4.0.4.1491-ls185@sha256:f3ad4f59e6e5e4a...";
```
- **Pros**: Human-readable AND immutable
- **Cons**: Slightly more verbose
- **Use Case**: Production systems with Renovate automation

## Repository Pin Policy (2026-07)

This repository enforces a single-source-of-truth rule for image pins, encoded
in `.github/renovate.json5`:

| Location | Role | Renovate |
|----------|------|----------|
| `hosts/**` | **Canonical pin** — full `tag@sha256:digest`, one per deployed service | Managed (digest bumps via PR) |
| `modules/**` | **Unmanaged fallback** — plain version tag only, no digest | Ignored (`enabled: false` for docker datasource) |

**Why**: Renovate previously bumped both the module default and the host
override, and the two diverged. The host value always wins at eval time, so
module bumps were dead weight that still generated PR noise and implied a
precision the module default doesn't have.

**Exceptions** (pinned with digest in the *module*, Renovate-managed there):

- `modules/nixos/services/omada/**`
- `modules/nixos/services/unifi/**`
- `modules/nixos/services/onepassword-connect/**`

These are luna-only services that are enabled without a host-level `image`
override, so the module default *is* the effective pin.

**When adding a new service:**

1. Give the module an `image` option with a plain-tag default (e.g.
   `"ghcr.io/foo/bar:1.2.3"`) — no digest.
2. Set the digest-pinned image in the host file
   (`hosts/forge/services/<name>.nix`):
   `image = "ghcr.io/foo/bar:1.2.3@sha256:...";`
3. Renovate picks up the host pin automatically (regex manager matches
   `image = "..."` in `.nix` files) and keeps it bumped.

**Note on `--pull=newer`**: the service factory previously passed
`--pull=newer` to every container. This was removed (2026-07): with digest
pins it's a no-op registry round-trip, and for unpinned tags it silently
auto-updated containers outside Renovate's control. Image updates now happen
exclusively through Renovate PRs.

## Implementation

### Module Configuration

Services should expose an `image` option for flexibility:

```nix
# In service module (e.g., sonarr/default.nix)
image = lib.mkOption {
  type = lib.types.str;
  default = "lscr.io/linuxserver/sonarr:latest";  # Fallback only
  description = ''
    Full container image name including tag or digest.

    Best practices:
    - Pin to specific version tags (e.g., "4.0.4.1491-ls185")
    - Use digest pinning for immutability (e.g., "4.0.4.1491-ls185@sha256:...")
    - Avoid 'latest' tag for production systems

    Use Renovate bot to automate version updates with digest pinning.
  '';
  example = "lscr.io/linuxserver/sonarr:4.0.4.1491-ls185@sha256:f3ad4f59e6e5e4a...";
};
```

### Host Configuration

Pin versions at the host level where Renovate can manage them:

```nix
# In hosts/forge/default.nix
modules.services.sonarr = {
  enable = true;
  image = "lscr.io/linuxserver/sonarr:4.0.4.1491-ls185";  # Renovate manages this
  # ... other options
};
```

## Renovate Bot Configuration

### Setup

The live configuration is `.github/renovate.json5` — it contains the
`packageRules` that implement the pin policy above (docker datasource disabled
for `modules/**`, re-enabled for the three exception modules). A minimal
generic setup looks like:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:base"
  ],
  "nix": {
    "enabled": true
  },
  "packageRules": [
    {
      "matchDatasources": ["docker"],
      "pinDigests": true,
      "separateMinorPatch": true,
      "semanticCommits": "enabled",
      "commitMessagePrefix": "feat(containers):"
    }
  ],
  "regexManagers": [
    {
      "fileMatch": ["\\.nix$"],
      "matchStrings": [
        "image\\s*=\\s*\"(?<depName>[^:@]+):(?<currentValue>[^@\"]+)(@(?<currentDigest>sha256:[a-f0-9]+))?\""
      ],
      "datasourceTemplate": "docker"
    }
  ]
}
```

### How It Works

1. **Detection**: Renovate scans `.nix` files for image definitions
2. **Update Check**: Monitors registries for new versions
3. **PR Creation**: Creates pull requests with:
   - Updated version tag
   - Pinned digest (if `pinDigests: true`)
   - Changelog/release notes links
4. **Review & Merge**: Review the PR, test if needed, then merge

### Example Renovate PR

```diff
# hosts/forge/default.nix
  modules.services.sonarr = {
    enable = true;
-   image = "lscr.io/linuxserver/sonarr:4.0.4.1491-ls185";
+   image = "lscr.io/linuxserver/sonarr:4.0.5.1500-ls186@sha256:a1b2c3d4e5f6...";
  };
```

## Current Status

The policy above is fully deployed:

- **All deployed services** carry their digest pin in `hosts/**` (forge
  service files under `hosts/forge/services/`), managed by Renovate.
- **Module defaults** under `modules/**` carry plain-tag fallbacks and are
  excluded from Renovate.
- **Module-pinned exceptions** (luna, no host override — Renovate manages the
  module default):
  - **Omada Controller**: `mbentley/omada-controller` (pinned to v5.x — see
    [`workarounds.md`](workarounds.md#omada-controller-pinned-to-v5x-no-avx-on-luna))
  - **UniFi Controller**: `jacobalberty/unifi-docker`
  - **1Password Connect** (API + Sync): `1password/connect-api` /
    `1password/connect-sync`
- **Deliberate tag pins** (not `:latest`): `tracearr` is pinned to `1.3.8`
  in `hosts/forge/services/tracearr.nix` (replacing a floating `latest` tag
  that Renovate could never pin or update); `profilarr` points at
  `ghcr.io/dictionarry-hub/profilarr:2.0.9` (service currently disabled —
  see [`workarounds.md`](workarounds.md)).

## Migration Guide

### For Existing Services

**Before:**
```nix
virtualisation.oci-containers.containers.myservice = {
  image = "registry/image:latest";
  # ...
};
```

**After (Module):**
```nix
# In service module
options.modules.services.myservice = {
  image = lib.mkOption {
    type = lib.types.str;
    default = "registry/image:latest";  # Fallback only
    description = "Container image with version or digest";
  };
};

# In config
virtualisation.oci-containers.containers.myservice = {
  image = cfg.image;
  # ...
};
```

**After (Host):**
```nix
# In hosts/<hostname>/default.nix
modules.services.myservice = {
  enable = true;
  image = "registry/image:1.2.3-tag@sha256:...";  # Renovate manages
};
```

## LinuxServer.io Specific Notes

### Tag Format
LinuxServer.io uses this tag format:
```
<version>-ls<build>
```
Example: `4.0.4.1491-ls185`
- `4.0.4.1491`: Upstream Sonarr version
- `ls185`: LinuxServer.io build number

### Finding Versions
- **Docker Hub**: https://hub.docker.com/r/linuxserver/sonarr/tags
- **GitHub**: https://github.com/linuxserver/docker-sonarr/releases
- **lscr.io**: https://lscr.io/linuxserver/sonarr:tags

### Recommended Strategy
Use the full version tag with LinuxServer.io build number for maximum specificity.

## Security Considerations

### Digest Verification
When using digests, the container runtime verifies:
- Image hasn't been tampered with
- Exact same image layers are used
- Content matches the manifest

### Update Cadence
Balance security and stability:
- **Security Patches**: Merge quickly (same/next day)
- **Minor Updates**: Review within a week
- **Major Updates**: Test thoroughly, review breaking changes

### Automated Scanning
Consider enabling:
- **Renovate Vulnerability Alerts**: Flags known CVEs in images
- **Dependabot**: Alternative to Renovate
- **Trivy/Grype**: Local image scanning in CI/CD

## Troubleshooting

### Renovate Not Detecting Images

**Problem**: Renovate doesn't find your image definitions

**Solution**: Ensure regex pattern matches your syntax
```nix
# This works
image = "registry/image:tag";

# This also works
image = "registry/image:tag@sha256:...";
```

### Image Pull Failures

**Problem**: Digest no longer exists in registry

**Solution**:
1. Check if image was deleted by maintainer
2. Use version tag only (without digest) temporarily
3. Wait for Renovate to provide new digest

### Merge Conflicts

**Problem**: Multiple Renovate PRs cause conflicts

**Solution**: Configure Renovate to:
```json
"prConcurrentLimit": 3,
"branchConcurrentLimit": 5
```

## Resources

- [Renovate Documentation](https://docs.renovatebot.com/)
- [Docker Digest Pinning](https://docs.renovatebot.com/docker/#digest-pinning)
- [NixOS Container Options](https://search.nixos.org/options?query=virtualisation.oci-containers)
- [LinuxServer.io Images](https://www.linuxserver.io/)

## Maintenance

**Review Period**: Quarterly
- Audit all container images
- Verify Renovate is working correctly
- Check for stuck/abandoned PRs
- Update this documentation as needed

**Last Updated**: 2026-07-07
**Maintainer**: System Administrator
