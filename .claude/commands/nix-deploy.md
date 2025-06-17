# /nix-deploy

Unified deployment interface with automatic OS detection and Task integration.

## Usage

```
/nix-deploy host=<hostname> [--build-only]
```

## Parameters

- `host` (required): The hostname to deploy to
- `--build-only` (optional): Build configuration without applying it

## Examples

```bash
# Deploy to NixOS server
/nix-deploy host=luna

# Deploy to Darwin machine
/nix-deploy host=rymac

# Build only (no deployment)
/nix-deploy host=rydev --build-only
```

## Implementation

### Host-to-OS Mapping

| Host | OS | Architecture |
|------|-------|-------------|
| `rymac` | Darwin | aarch64-darwin |
| `luna` | NixOS | x86_64-linux |
| `rydev` | NixOS | aarch64-linux |
| `nixos-bootstrap` | NixOS | aarch64-linux |

### Generated Commands

#### NixOS Hosts (luna, rydev, nixos-bootstrap)

**Deploy:**
```bash
task nix:apply-nixos host={hostname}
```

**Build only:**
```bash
task nix:build-nixos host={hostname}
```

#### Darwin Hosts (rymac)

**Deploy:**
```bash
task nix:apply-darwin host={hostname}
```

**Build only:**
```bash
task nix:build-darwin host={hostname}
```

## Deployment Details

- **Darwin**: Local builds using `darwin-rebuild`
- **NixOS**: Remote builds via SSH with `--build-host --target-host`
- **Validation**: Always run `/nix-validate` before deployment
- **Sequential**: Current implementation deploys one host at a time

## Notes

- Automatically selects correct Task command based on host OS
- Hides complexity of platform-specific deployment logic
- Build-only mode useful for testing configuration changes
- Darwin deployments are local, NixOS deployments are remote
