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

Pin host-specific versions at the host level. Renovate also tracks image option
defaults used directly by hosts:

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

The authoritative configuration is
[`.github/renovate.json5`](https://github.com/carpenike/nix-config/blob/main/.github/renovate.json5). Its Docker custom managers
recognize literal assignments to `image`, `default`, and fields ending in
`Image`, including dotted attributes such as `container.image`. They support
the configured registries (`ghcr.io`, `docker.io`, `lscr.io`, `quay.io`) and
Docker Hub `org/repo` shorthand, with tags and optional SHA-256 digests.

Keep these declarations on their own assignment lines. `#`-commented assignments,
`example` attributes, interpolated strings, and variable references are not
dependency declarations for these managers.

An option default is a real dependency when the host does not override it.
Before this coverage was added, Plex and other enabled services silently missed
updates because their literals used `default = "..."`, not `image = "..."`.

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

## Update Ownership

| Dependency | Update owner |
| --- | --- |
| OCI image tags and digests, including module defaults | Renovate Docker custom managers |
| nixpkgs and other moving flake inputs | `.github/workflows/update-flake-lock.yml`; Renovate's Nix manager is disabled |
| Sources generated from `pkgs/nvfetcher.toml` | `.github/workflows/update-nvfetcher.yml`; Renovate updates are disabled for `pkgs/_sources/**` |
| Custom GitHub releases with Nix hashes | Renovate proposes versions; maintainers refresh hashes and build before merging |
| Intentionally gated application commits | The application's reviewed release/cutover process |

Updating nixpkgs does not update a service running from a pinned OCI image.
Likewise, restarting a container or pulling its existing digest cannot advance
it to a new application version. A merged image update must still be deployed.

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

**Solution**: Check that the effective image is listed in
[Dependency Dashboard #145](https://github.com/carpenike/nix-config/issues/145),
not just that Renovate is opening unrelated PRs. These forms are supported:

```nix
image = "ghcr.io/example/service:1.2.3";
container.image = "ghcr.io/example/service:1.2.3@sha256:...";
image = lib.mkOption {
  type = lib.types.str;
  default = "ghcr.io/example/service:1.2.3@sha256:...";
};
```

The extraction regression check parses the real JSON5 configuration and runs
its patterns with RE2, the regex engine used by Renovate. CI runs it in the
required lint job:

```bash
# Apple Silicon macOS
nix build --no-link .#checks.aarch64-darwin.renovate-extraction

# x86-64 Linux
nix build --no-link .#checks.x86_64-linux.renovate-extraction
```

Dashboard visibility establishes detection, not successful version lookup,
safe upgrades, deployment, or vulnerability clearance. Investigate registry
lookup warnings and blocked PRs separately.

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

**Last Updated**: 2026-10-18
**Maintainer**: System Administrator
