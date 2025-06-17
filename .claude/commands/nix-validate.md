# /nix-validate

Comprehensive pre-deployment validation for Nix configurations. **ALWAYS run before deployment.**

## Usage

```
/nix-validate [host=<hostname>] [--fast]
```

## Parameters

- `host` (optional): Validate only the specified host configuration
- `--fast` (optional): Skip slower checks (currently same as default)

## Examples

```bash
# Validate all configurations
/nix-validate

# Validate specific host only
/nix-validate host=luna

# Fast validation
/nix-validate --fast
```

## Implementation

### Default (all hosts)
```bash
# Check all flake outputs
nix flake check --all-systems --show-trace

# Verify formatting
nix fmt -- --check
```

### Host-specific validation
```bash
# For NixOS hosts (luna, rydev, nixos-bootstrap)
nix build .#nixosConfigurations.{host}.config.system.build.toplevel --show-trace

# For Darwin hosts (rymac)
nix build .#darwinConfigurations.{host}.config.system.build.toplevel --show-trace
```

## Host Mappings

- `rymac`: Darwin (aarch64-darwin)
- `luna`: NixOS (x86_64-linux)
- `rydev`: NixOS (aarch64-linux)
- `nixos-bootstrap`: NixOS (aarch64-linux)

## Notes

- Always run this before any deployment
- Catches syntax errors, evaluation failures, and formatting issues
- Host-specific validation is much faster for targeted changes
- This is your primary safety net for configuration changes
