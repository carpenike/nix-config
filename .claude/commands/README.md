# Claude Commands for Nix Configuration

This directory contains custom Claude commands designed to streamline operations for this sophisticated NixOS/Darwin flake configuration.

## Quick Reference

### Essential Commands (Daily Use)
- **`/nix-validate`** - Pre-deployment validation (ALWAYS run first)
- **`/nix-deploy`** - Unified deployment with automatic OS detection
- **`/task-list`** - Discover available Task runner commands
- **`/sops-edit`** - Edit encrypted secrets with path resolution

### Development & Testing
- **`/nix-test-vm`** - Test NixOS configurations in QEMU VMs
- **`/nix-update`** - Update flake inputs with validation reminders
- **`/nix-update-package`** - Update custom package hashes using nix-update
- **`/nix-scaffold`** - Generate boilerplate for modules and hosts
- **`/sops-reencrypt`** - Re-encrypt all SOPS secrets

### Troubleshooting & Analysis
- **`/nix-diff`** - Compare system generations to debug deployments
- **`/nix-why-depends`** - Analyze package dependency chains

## Command Categories

### 🔒 Safety & Validation
Commands that prevent deployment failures and ensure system integrity.

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `/nix-validate` | Comprehensive configuration validation | Before every deployment |
| `/nix-test-vm` | Test changes in isolated VM | Before risky system changes |

### 🚀 Deployment & Operations
Commands for building and deploying configurations to hosts.

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `/nix-deploy` | Unified deployment interface | Deploy to any host |
| `/task-list` | Discover available operations | Explore automation options |

### 🔐 Secrets Management
Commands for working with encrypted secrets and SOPS.

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `/sops-edit` | Edit encrypted secrets | Add/modify secrets |
| `/sops-reencrypt` | Re-encrypt all secrets | After key changes |

### 🛠️ Development Tools
Commands for creating new components and maintaining the repository.

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `/nix-update` | Update flake inputs | Regular maintenance |
| `/nix-update-package` | Update custom package hashes | After nvfetcher updates |
| `/nix-scaffold` | Generate boilerplate | Create new modules/hosts |

### 🔍 Debugging & Analysis
Commands for troubleshooting deployment issues and understanding system state.

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `/nix-diff` | Compare system generations | Debug deployment changes |
| `/nix-why-depends` | Analyze dependency chains | Understand package inclusion |

## Recommended Workflows

### Safe Deployment Workflow
```bash
1. /nix-validate                    # Validate all configurations
2. /nix-validate host=<target>      # Validate specific host
3. /nix-test-vm host=<target>       # Test in VM (NixOS only)
4. /nix-deploy host=<target>        # Deploy to target
```

### New Module Development
```bash
1. /nix-scaffold type=module name=<name> layer=<layer>
2. # Edit generated module file
3. /nix-validate                    # Validate changes
4. /nix-test-vm host=<test-host>    # Test in VM
5. /nix-deploy host=<dev-host>      # Deploy to development host
```

### Maintenance Workflow
```bash
1. /nix-update                      # Update all flake inputs
2. /nix-update-package <pkg>        # Update custom package hashes (if needed)
3. /nix-validate                    # Ensure still valid
4. /nix-test-vm host=rydev          # Test on development host
5. /nix-deploy host=rydev           # Deploy to dev first
6. /nix-deploy host=luna            # Deploy to production
```

### Troubleshooting Workflow
```bash
1. /nix-diff host=<host>            # What changed?
2. /nix-why-depends package=<pkg> host=<host>  # Why is this included?
3. /nix-validate host=<host>        # Is configuration valid?
4. /nix-test-vm host=<host>         # Test fix in VM
```

## Host Mappings

All commands automatically handle these host configurations:

| Host | OS | Architecture | Purpose |
|------|-------|-------------|---------|
| `rymac` | Darwin | aarch64-darwin | macOS development machine |
| `luna` | NixOS | x86_64-linux | Production server |
| `rydev` | NixOS | aarch64-linux | Development/testing |
| `nixos-bootstrap` | NixOS | aarch64-linux | Bootstrap deployment |

## Integration with Task Runner

These commands integrate seamlessly with your existing Task (go-task) workflow:

- **Commands build on Task**: `/nix-deploy` uses `task nix:apply-*` internally
- **Task discovery**: `/task-list` exposes all available tasks
- **Enhanced functionality**: Commands add validation, safety checks, and convenience

## Command Implementation

Each command is documented in its own file with:
- **Usage syntax** and parameters
- **Implementation details** showing generated commands
- **Examples** for common use cases
- **Integration notes** for workflow context
- **Safety considerations** and best practices

## Getting Started

1. **Start with validation**: `/nix-validate` to ensure current state is good
2. **Explore available tasks**: `/task-list` to see automation options
3. **Try VM testing**: `/nix-test-vm host=rydev` to experience safe testing
4. **Use unified deployment**: `/nix-deploy host=<target>` for all deployments

## Notes

- **Always validate first**: Run `/nix-validate` before any deployment
- **VM testing recommended**: Use `/nix-test-vm` for risky changes
- **Host-specific paths**: Commands automatically resolve correct paths and OS commands
- **Safety by default**: Commands include validation reminders and safety checks
- **Task integration**: Leverages existing Task runner for actual operations
