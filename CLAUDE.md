# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a comprehensive Nix configuration repository that manages both NixOS and Darwin (macOS) systems using Nix flakes. The repository follows a sophisticated modular architecture with support for multiple hosts, unified user configurations, and enterprise-level patterns including secrets management, impermanence, and automated validation.

## Custom Project Commands

These commands streamline common operations and enforce best practices. Use them for routine development and operational tasks.

| Command | Description | When to Use | Preconditions/Limitations |
|---------|-------------|-------------|---------------------------|
| `/nix-validate` | Comprehensive pre-deployment validation | **ALWAYS** before deployment, commits, or PRs | None |
| `/nix-deploy` | Unified deployment with automatic OS detection | Deploy configurations to any host | Requires valid configuration |
| `/task-list` | Discover available Task runner commands | Explore automation options | None |
| `/sops-edit` | Edit encrypted secrets with path resolution | Add/modify secrets | Requires GPG/age key access |
| `/nix-test-vm` | Test NixOS configs in QEMU VMs | Test risky changes safely | **CRITICAL: Linux only - fails on macOS (Darwin) due to QEMU incompatibility** |
| `/nix-update` | Update flake inputs with validation reminders | Regular maintenance | Always validate after updates |
| `/nix-scaffold` | Generate boilerplate for modules/hosts | Create new components | Follow up with imports/registration |
| `/sops-reencrypt` | Re-encrypt all SOPS secrets | After key changes | Requires decryption access |
| `/nix-diff` | Compare system generations | Debug deployment changes | Requires SSH to target host |
| `/nix-why-depends` | Analyze package dependency chains | Understand closures | Build must be evaluatable |

## External Tools (MCP Servers)

These specialized servers are available for complex tasks. Choose the right tool based on its strengths.

| Tool | Primary Function | Usage Guidelines & Examples |
|------|------------------|----------------------------|
| **Zen** | Deep Thinking & Analysis | - Use for architectural decisions, complex debugging, code review<br>- *Example*: "Use Zen to analyze this modular deployment architecture"<br>- *Example*: "Ask Zen to review the security implications of this change" |
| **Context7** | Library & API Docs | - Use for framework documentation, function signatures, API references<br>- *Example*: "Use Context7 to find nixpkgs.lib function documentation"<br>- *Example*: "Look up home-manager options with Context7" |
| **Perplexity** | Web Search & Best Practices | - Use for current best practices, tool research, recent updates<br>- *Example*: "Search Perplexity for NixOS impermanence best practices"<br>- *Example*: "Find recent security advisories for package X" |
| **GitHub** | Repository Operations | - Use for all Git/GitHub operations: branches, PRs, issues<br>- *Example*: "Create PR from feature branch"<br>- *Example*: "Search for similar issues in nixpkgs repository" |

## Common Workflow Patterns

Combine tools and commands to accomplish common goals efficiently.

### New Feature Development
1. **Perplexity**: Research libraries or best practices for the feature
2. **Zen**: Discuss and refine the architecture
3. **GitHub**: Create a new feature branch
4. `/nix-scaffold`: Generate module boilerplate if needed
5. *(Code Development)*
6. `/nix-validate`: Check code quality
7. `/nix-test-vm`: (If on Linux) Perform integration test
8. **GitHub**: Create pull request for review

### Bug Fix Workflow
1. **GitHub**: Locate the issue describing the bug
2. **Zen**: Analyze the bug report and code to form hypothesis
3. **GitHub**: Create branch (e.g., `fix/issue-123`)
4. `/nix-diff`: Compare system generations if deployment-related
5. *(Code Development & Debugging)*
6. `/nix-validate`: Ensure code quality
7. `/nix-test-vm`: (If on Linux) Confirm fix under integration
8. **GitHub**: Create PR linking the resolved issue

### Dependency Update Workflow
1. `/nix-update`: Update specific or all flake inputs
2. `/nix-validate`: Immediate validation of all configs
3. `/nix-test-vm`: (If on Linux) Test critical services
4. `/nix-deploy host=rydev --build-only`: Test build on dev host
5. `/nix-deploy host=rydev`: Deploy to development first
6. Monitor for issues, then deploy to production hosts

### Secret Management Workflow
1. `/sops-edit host=<hostname>`: Edit encrypted secrets
2. `/nix-validate host=<hostname>`: Validate configuration with new secrets
3. `/nix-deploy host=<hostname> --build-only`: Test build
4. `/sops-reencrypt`: (If keys changed) Re-encrypt all secrets
5. Deploy carefully with validation at each step

## Essential Commands

### Validation (ALWAYS run before deployment)

```bash
# Run flake checks to validate configurations
nix flake check

# List available tasks
task
```

### Building and Applying Configurations

Use Task (go-task) runner for all build operations:

**Darwin (macOS):**
```bash
# Build Darwin configuration
task nix:build-darwin host=rymac

# Apply Darwin configuration
task nix:apply-darwin host=rymac
```

**NixOS:**
```bash
# Build NixOS configuration
task nix:build-nixos host=luna

# Apply NixOS configuration
task nix:apply-nixos host=luna
```

**Available Hosts:**
- `rymac` - Darwin configuration (aarch64-darwin)
- `luna` - x86_64-linux NixOS server
- `rydev` - aarch64-linux NixOS (Parallels devlab)
- `nixos-bootstrap` - aarch64-linux bootstrap deployment

### Secrets Management

```bash
# Re-encrypt all SOPS secrets
task sops:re-encrypt

# Edit secrets (will decrypt, open editor, re-encrypt)
sops hosts/luna/secrets.sops.yaml
```

### Development and Testing

```bash
# Enter development shell with required tools
nix-shell

# Build specific system without applying
nix build .#nixosConfigurations.luna
nix build .#darwinConfigurations.rymac

# Test configuration changes in VM (NixOS only)
nix build .#checks.x86_64-linux.nginx-service
```

## Architecture

### Key Files & Directories

| Path | Purpose |
|------|---------|
| `flake.nix` | Main flake entry point defining inputs, outputs, and system configurations |
| `lib/mkSystem.nix` | Unified system builder functions for NixOS and Darwin |
| `hosts/_modules/` | Shared modules organized by scope (common/nixos/darwin) |
| `hosts/<hostname>/` | Individual host configurations and secrets |
| `home/` | Home Manager configurations for user environments |
| `overlays/` | Package overlays for modified/custom packages |
| `pkgs/` | Custom package definitions (kubectl plugins, utilities) |
| `.taskfiles/` | Task runner configuration for build/deploy automation |

### Layered Module Architecture

The configuration uses a sophisticated layered import system that maximizes code reuse:

```
Host Configuration → Platform Modules → Common Modules
     ↓                    ↓                ↓
hosts/luna/         hosts/_modules/    hosts/_modules/
                    nixos/             common/
```

**Import Order (most specific to most general):**
1. **Host-specific** (`hosts/<hostname>/`) - Machine-specific settings, hardware config, secrets
2. **Platform modules** (`hosts/_modules/nixos` or `hosts/_modules/darwin`) - OS-specific services and settings
3. **Common modules** (`hosts/_modules/common`) - Universal settings for all systems (shells, locale, nix config)

### System Builder Pattern

The `lib/mkSystem.nix` provides two unified builders that handle dependency injection:

- **`mkNixosSystem`** - Composes NixOS with disko, home-manager, sops-nix, impermanence
- **`mkDarwinSystem`** - Composes nix-darwin with home-manager, nixvim, catppuccin

Both builders automatically inject shared dependencies (`inputs`, `hostname`, `system`) via `specialArgs` and `_module.args`.

### Home Manager Integration

Unified user experience across platforms achieved through:
- **Shared user config**: `home/ryan/` used on all systems
- **Platform-specific modules**: Conditional imports based on `pkgs.stdenv.isDarwin`
- **Consistent tooling**: Same shell, editor, and development environment everywhere

### Advanced Features

- **SOPS Secrets**: Age-encrypted secrets with per-host key management
- **Impermanence**: Ephemeral root filesystem with explicit persistence (NixOS only)
- **Disko**: Declarative disk partitioning and formatting (NixOS only)
- **Catppuccin Theming**: Unified color scheme across all applications
- **Custom Packages**: kubectl plugins and utilities in `pkgs/`
- **Overlays**: Shared package modifications ensuring consistency across hosts

### Deployment Architecture

- **Darwin**: Local builds using `darwin-rebuild` with Task runner orchestration
- **NixOS**: Remote builds via SSH (`--build-host --target-host`) to reduce local resource usage
- **Secrets**: Decrypted on target systems using host-specific age keys
- **Validation**: Pre-deployment checks via `nix flake check` (recommended)

## Operational Best Practices

### Before Making Changes

1. **Always validate first**: `nix flake check`
2. **Test in development**: Use `rydev` host for testing NixOS changes
3. **Review secrets**: Ensure no plaintext secrets in committed files

### Adding a New Host

1. Create `hosts/<hostname>/default.nix` with host configuration
2. Add hardware configuration and secrets if needed
3. Add to `nixosConfigurations` or `darwinConfigurations` in `flake.nix`
4. Run `nix flake check` to validate

### Working with Secrets

- Use `sops <file>` to edit encrypted secrets
- Test keys stored separately from production keys
- Never commit plaintext secrets to repository

### Common Troubleshooting

- **Build failures**: Check `nix flake check` output for syntax errors
- **Secrets issues**: Verify age key is properly configured on target host
- **Task runner failures**: Run underlying nix commands directly for detailed errors
- **Darwin issues**: Ensure nix-darwin is properly installed and configured

## Testing and Validation

Future versions will include VM testing for critical services:

```nix
# Planned: VM tests for service validation
checks.x86_64-linux.nginx-service = pkgs.testers.runNixOSTest {
  name = "nginx-behavior-test";
  nodes.machine.imports = [ ../hosts/_modules/nixos/services/nginx ];
  testScript = ''
    machine.wait_for_unit("nginx.service")
    machine.succeed("curl --fail http://localhost")
  '';
};
```
