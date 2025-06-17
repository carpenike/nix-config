# /nix-update

Update flake inputs with automatic validation reminders.

## Usage

```
/nix-update [--input=<input>]
```

## Parameters

- `--input` (optional): Update only the specified input (e.g., `nixpkgs`)

## Examples

```bash
# Update all inputs
/nix-update

# Update only nixpkgs
/nix-update --input=nixpkgs

# Update specific input
/nix-update --input=home-manager
```

## Implementation

### Update all inputs
```bash
nix flake update
```

### Update specific input
```bash
nix flake update --update-input {input}
```

## Available Inputs

Based on your flake.nix:

### Core Inputs
- `nixpkgs` - Main package collection (24.11)
- `nixpkgs-unstable` - Unstable package collection
- `home-manager` - User environment management
- `nix-darwin` - macOS system management

### Utilities
- `disko` - Declarative partitioning and formatting
- `sops-nix` - Secrets management
- `impermanence` - Ephemeral filesystem support
- `nixvim` - Neovim configuration
- `catppuccin` - Theming

### Development
- `nix-vscode-extensions` - VSCode extensions
- `rust-overlay` - Rust toolchain
- `nix-inspect` - Interactive tui for inspecting configs
- `flake-parts` - Flake module system

## Post-Update Workflow

**CRITICAL**: After updating inputs, always:

1. **Validate immediately**: `/nix-validate`
2. **Test specific hosts**: `/nix-validate host=<hostname>`
3. **Consider VM testing**: `/nix-test-vm host=<nixos-host>`
4. **Deploy cautiously**: Start with development hosts

## Update Strategy

### Safe Update Process
1. Update unstable inputs first: `/nix-update --input=nixpkgs-unstable`
2. Test with `/nix-validate`
3. Update stable inputs: `/nix-update --input=nixpkgs`
4. Full validation: `/nix-validate`
5. Deploy to development hosts first

### Emergency Rollback
If updates break configurations:
```bash
# Restore previous flake.lock
git checkout HEAD~1 -- flake.lock

# Or manually pin to working revision
nix flake update --update-input nixpkgs github:NixOS/nixpkgs/<commit>
```

## Notes

- Updates modify `flake.lock` - commit these changes
- Major updates can introduce breaking changes
- Test thoroughly before deploying to production systems
- Consider updating inputs individually for easier troubleshooting
- Monitor for security updates in stable inputs
