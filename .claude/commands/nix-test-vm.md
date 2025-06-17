# /nix-test-vm

Build and run NixOS configurations in QEMU VMs for safe testing of system-level changes.

## ⚠️ Platform Limitation

**This command is only available on Linux systems.** It will fail on macOS (Darwin) due to QEMU compatibility issues.

### Alternative Testing Methods for macOS Users:
- **Build validation**: `/nix-deploy host=<hostname> --build-only`
- **Configuration check**: `/nix-validate host=<hostname>`
- **Remote testing**: SSH to a Linux host and run the command there

## Usage

```
/nix-test-vm host=<hostname>
```

## Parameters

- `host` (required): NixOS hostname to test in VM

## Examples

```bash
# Test luna configuration in VM (Linux only)
/nix-test-vm host=luna

# Test development environment (Linux only)
/nix-test-vm host=rydev

# Test bootstrap configuration (Linux only)
/nix-test-vm host=nixos-bootstrap
```

## Implementation

```bash
task nix:test-vm host={hostname}
```

This runs the Task that:
1. **Checks platform**: Ensures not running on Darwin (macOS)
2. **Builds VM derivation**: `nix build .#nixosConfigurations.{host}.config.system.build.vm`
3. **Runs the VM**: `./result/bin/run-{host}-vm`

## Supported Hosts

**NixOS only** (VM testing not available for Darwin):
- `luna` - x86_64-linux NixOS server
- `rydev` - aarch64-linux NixOS (Parallels devlab)
- `nixos-bootstrap` - aarch64-linux bootstrap deployment

## Platform Detection

The Task includes platform detection that will provide a helpful error message on macOS:

```
❌ VM testing is not supported on macOS (Darwin)

The 'nix-test-vm' command requires QEMU, which has compatibility issues on macOS.
Please run this command on a Linux host, or use alternative testing methods:
- Build-only validation for a host: /nix-deploy host=<hostname> --build-only
- General configuration check: /nix-validate
```

## VM Characteristics

- **Isolated**: Runs completely separate from your actual system
- **Ephemeral**: Changes don't persist between VM runs
- **Quick**: Much faster than deploying to real hardware
- **Safe**: Perfect for testing dangerous system changes

## Use Cases

- **Service configuration changes**: Test nginx, bind, or other service configs
- **System-level modifications**: Kernel modules, boot configuration, filesystem changes
- **New module validation**: Test custom modules before deployment
- **Dependency changes**: Verify major package updates work correctly
- **Security testing**: Test firewall rules, user permissions, etc.

## Notes

- Requires QEMU and virtualization support
- VM will open in a new window - close to exit
- Useful for testing before running `/nix-deploy`
- Integrates with planned VM testing for checks
- Much safer than testing directly on production systems
