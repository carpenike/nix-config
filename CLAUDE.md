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
| **Taskmaster** | Task & Project Management | - Use for tracking multi-step tasks, breaking down complex projects<br>- *Example*: "Update taskmaster with completed infrastructure work"<br>- *Example*: "Mark task 30 as complete and add findings" |
| **Serena** | Semantic Code Navigation | - Use for intelligent code search, symbol navigation, refactoring<br>- *Example*: "Find all references to this function"<br>- *Example*: "Search for similar patterns in the codebase" |

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

### Infrastructure Service Development Workflow
1. **Research**: Use Perplexity for current best practices and security considerations
2. **Code Review**: Use Zen or Gemini Pro for security and architecture review
3. **Module Creation**: **CRITICAL** - Follow the standardized modular design patterns documented in `/docs/modular-design-patterns.md`
4. **Pattern Compliance**: Ensure new services use standardized submodules (reverseProxy, metrics, logging, backup, notifications, container)
5. **Auto-Registration**: Services must automatically register with infrastructure systems (Caddy, Prometheus, Promtail)
6. **Security**: Localhost binding + reverse proxy + authentication + systemd hardening
7. **Testing**: Validate with `/nix-validate` and test deployment on `rydev` first
8. **Migration Planning**: For existing services, follow the roadmap in `/docs/service-migration-roadmap.md`
9. **Tracking**: Update Taskmaster with findings and completed work

### Package Management Workflow
1. **Determine package type**: CLI tool → Nix, GUI app → Homebrew
2. **Add to configuration**: Edit appropriate module file
3. `/nix-validate`: Check configuration syntax
4. `darwin-rebuild build --flake .`: Preview changes safely
5. `darwin-rebuild switch --flake .`: Apply if build succeeds
6. **Important**: Never use `brew install` directly - always declare in configuration

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

## Service Module Design Standards

This repository enforces standardized modular design patterns for all service modules to ensure consistency, maintainability, and automatic integration with infrastructure systems.

### Mandatory Design Patterns

All new service modules **MUST** follow these patterns as documented in `/docs/modular-design-patterns.md`:

#### 1. Structured Submodules
Services must use `types.submodule` for complex configuration instead of simple strings or booleans:

- **`reverseProxy`** - Web services must auto-register with Caddy
- **`metrics`** - Services exposing metrics must auto-register with Prometheus
- **`logging`** - Services must auto-register log sources with Promtail
- **`backup`** - Stateful services must declare backup requirements
- **`notifications`** - Services must integrate with centralized notification system
- **`container`** - Containerized services must use standardized resource management

#### 2. Auto-Registration Requirements
Services **MUST NOT** require manual infrastructure configuration:

- ✅ **Correct**: Service declares `reverseProxy.enable = true` → Automatically appears in Caddy
- ❌ **Incorrect**: Manual addition to Caddy configuration required

#### 3. Type Safety and Validation
- Use proper `types.submodule` definitions for all complex options
- Include comprehensive `assertions` to catch configuration errors at evaluation time
- Provide clear descriptions and examples for all options

#### 4. Security Hardening by Default
- Containerized services must use localhost binding + reverse proxy pattern
- Apply systemd security directives (`ProtectSystem`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`)
- Use SOPS for secrets management with proper credential loading

### Reference Implementations

- **Web Services**: `hosts/_modules/nixos/services/caddy/default.nix` - Structured backend configuration
- **Storage Services**: `hosts/_modules/nixos/services/postgresql/` - Resource provisioning patterns
- **Monitoring**: `hosts/_modules/nixos/services/glances/default.nix` - Reverse proxy integration

### Migration Status

See `/docs/service-migration-roadmap.md` for the current status of migrating existing services to these patterns.

**Current Priority**: Phase 1 - Building foundational abstractions (metrics submodule, container helpers, logging integration)

### Development Guidelines

1. **New Services**: Must use all applicable standardized submodules from day one
2. **Existing Services**: Follow migration roadmap for systematic updates
3. **Breaking Changes**: Maintain backward compatibility during transitions
4. **Testing**: Validate auto-registration functionality before deployment

## Architecture

### Key Files & Directories

| Path | Purpose |
|------|---------|
| `flake.nix` | Main flake entry point defining inputs, outputs, and system configurations |
| `lib/mkSystem.nix` | Unified system builder functions for NixOS and Darwin |
| `lib/podman.nix` | Podman container helpers (mkHealthCheck, mkContainer, resource management) |
| `hosts/_modules/` | Shared modules organized by scope (common/nixos/darwin) |
| `hosts/_modules/nixos/services/` | NixOS service modules with reverse proxy integration patterns |
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
- **Podman Infrastructure**: Rootful container orchestration with health checks, resource limits, and security hardening

### Infrastructure Services Architecture

This configuration implements a production-grade homelab infrastructure on `luna` (primary server):

**Core Services:**
- **DNS Stack**: BIND (authoritative) + AdGuardHome (filtering/DoH) + Chrony (NTP)
- **Reverse Proxies**: HAProxy (TCP/stream) + Caddy (HTTP/HTTPS with automatic TLS)
- **Container Orchestration**: Podman with health checks, resource limits, and systemd integration
- **Monitoring**: Node Exporter (metrics) + Glances (per-host system monitoring)
- **Network Controllers**: UniFi (main network) + Omada (IoT network)
- **Binary Cache**: Attic with auto-push for faster deployments
- **Secrets Management**: 1Password Connect for secure credential storage

**Service Integration Patterns:**
- Services automatically register with Caddy reverse proxy when `reverseProxy.enable = true`
- Per-host monitoring tools use hostname-based routing (`luna.holthome.net`)
- Service-level tools use descriptive subdomains (`vault.holthome.net`, `attic.holthome.net`)
- All services binding to localhost with reverse proxy providing secure external access
- Authentication via SOPS-managed bcrypt hashes injected as environment variables

**Caddy Reverse Proxy Configuration:**
- **TLS/ACME**: Per-site DNS-01 challenges using Cloudflare DNS provider
- **Split-Horizon DNS**: External resolvers (1.1.1.1, 8.8.8.8) bypass internal BIND for ACME verification
- **HSTS**: Standardized across all services with 6-month max-age and includeSubDomains
- **Authentication**: `basic_auth` directive with bcrypt hashes from SOPS secrets
- **Best Practices**: Caddy automatically forwards X-Forwarded-For/Proto; manual header_up only when needed

### DNS Management Architecture

**Multi-Host DNS Record Generation:**

This repository implements declarative DNS management using flake-level aggregation. DNS records are automatically generated from Caddy virtual host configurations across ALL hosts in the flake.

**Architecture Pattern:**
```
Host Configs → Flake Aggregation → Manual SOPS Update → BIND Server
(luna, rydev,   (lib/dns-aggregate.nix)  (Zone File)      (luna)
 nixpi, rymac)
```

**DNS Record Sources:**
1. **Static Infrastructure (Caddy)**: Declaratively generated from NixOS config (this system)
2. **Dynamic Services (Kubernetes)**: Updated via external-dns + rndc at runtime
3. **Manual Records**: Directly edited in SOPS encrypted zone file

**Key Components:**
- `lib/dns-aggregate.nix` - Scans all hosts and collects Caddy virtual hosts
- `hosts/_modules/common/networking/host-ip.nix` - Each host declares its primary IP via `my.hostIp` option
- `hosts/_modules/nixos/services/caddy/dns-records.nix` - Per-host DNS record generation
- `.#allCaddyDnsRecords` - Flake output containing aggregated DNS records from entire fleet

**Workflow for DNS Updates:**

1. **View Generated Records:**
   ```bash
   nix eval .#allCaddyDnsRecords --raw
   ```

2. **Add New Service with DNS:**
   ```nix
   # In any host config (e.g., hosts/rydev/default.nix)
   config = {
     my.hostIp = "10.20.0.20";  # Declare host IP once

     modules.services.caddy = {
       enable = true;
       virtualHosts."myservice" = {
         enable = true;
         hostName = "myservice.holthome.net";
         proxyTo = "localhost:8080";
       };
     };
   };
   ```

3. **Regenerate and View Updated Records:**
   ```bash
   nix eval .#allCaddyDnsRecords --raw
   ```

4. **Update SOPS Zone File:**
   ```bash
   sops hosts/luna/secrets.sops.yaml
   # Navigate to: networking/bind/zones/holthome.net
   # Add the new A record(s) from step 3
   # Check for duplicates before saving
   ```

5. **Deploy BIND Configuration:**
   ```bash
   /nix-deploy host=luna
   ```

**Important Notes:**
- DNS record generation is **automatic** - records appear in flake output when you add Caddy virtual hosts
- SOPS zone file update is **manual** - you must paste records into encrypted zone file
- Always check for **duplicate records** before adding new ones to the zone file
- Records from all hosts (luna, rydev, nixpi, rymac) are aggregated into single output
- Host IPs are declared once per host via `my.hostIp` option in each host's config

**Benefits:**
- ✅ Single source of truth (NixOS config)
- ✅ Automatic aggregation across fleet
- ✅ Type-safe (caught at evaluation time)
- ✅ No manual DNS/Caddy synchronization
- ✅ Works alongside Kubernetes external-dns
- ✅ SOPS security model preserved

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
- **Container issues**: Check `podman logs <container>` and systemd service status
- **Reverse proxy issues**: Verify Caddy configuration and SOPS environment variables
- **ACME/TLS issues**: Check Caddy logs for DNS-01 challenge failures; verify Cloudflare API token has Zone:DNS:Edit permissions

### Containerized Services Best Practices

When configuring Podman-based services, follow these patterns established in 2025:

**Resource Management:**
- Set explicit memory limits and reservations for all containers
- Apply CPU quotas appropriate to service criticality
- **Examples**:
  - Lightweight APIs (1Password Connect): 128MB memory, 0.25 CPU cores
  - Monitoring tools (Glances): 256MB memory, 30% CPU quota
  - Network controllers (UniFi/Omada): 2GB memory, 50% CPU quota

**Security Hardening:**
- Bind services to localhost only; use reverse proxy for external access
- Apply systemd security directives: `ProtectSystem`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`
- Use dedicated system users with minimal permissions
- Enable authentication for all monitoring and admin interfaces

**Health Monitoring:**
```nix
# Use podmanLib.mkHealthCheck helper
healthcheck = podmanLib.mkHealthCheck {
  test = [ "CMD" "curl" "-f" "http://localhost:8080/health" ];
  interval = "30s";
  timeout = "10s";
  retries = 3;
  startPeriod = "60s";
};
```

**Module Pattern for Reverse Proxy Integration:**
```nix
# Services automatically register with Caddy when enabled
modules.services.caddy.virtualHosts.${subdomain} = lib.mkIf cfg.reverseProxy.enable {
  enable = true;
  hostName = "${subdomain}.${config.networking.domain}";
  proxyTo = "localhost:${port}";
  httpsBackend = true;  # Set true if backend uses HTTPS
  auth = cfg.reverseProxy.auth;  # Optional authentication
  headers = ''
    # Only add headers if backend specifically requires them
    # Caddy automatically passes: X-Forwarded-For, X-Forwarded-Proto, Host
    header_up X-Real-IP {remote_host}  # Only if backend needs it
  '';
};
```

**Automatic Caddy Features (Built-in per site):**
- TLS certificates via Let's Encrypt DNS-01 challenges
- External DNS resolvers (1.1.1.1, 8.8.8.8) for split-horizon DNS compatibility
- HSTS headers (6-month max-age, includeSubDomains)
- Standard reverse proxy headers (X-Forwarded-For, X-Forwarded-Proto, Host)
- HTTP → HTTPS redirects

### Podman Library Helpers

The `lib/podman.nix` provides reusable functions for container management:

**mkHealthCheck** - Standardized health check configuration:
```nix
healthcheck = podmanLib.mkHealthCheck {
  test = [ "CMD" "curl" "-f" "http://localhost:8080/health" ];
  interval = "30s";
  timeout = "10s";
  retries = 3;
  startPeriod = "60s";
};
```

**mkContainer** - Simplified container creation with resource limits:
```nix
virtualisation.oci-containers.containers.myservice = podmanLib.mkContainer "myservice" {
  image = "docker.io/service:latest";
  ports = [ "8080:8080" ];
  resources = {
    memory = "256m";
    memoryReservation = "128m";
    cpus = "0.5";
  };
  healthcheck = { /* ... */ };
};
```

**Key Features:**
- Automatic systemd service dependencies
- Standardized logging configuration
- Resource limit enforcement
- Health check integration
- Configurable UID/GID for data ownership

## Package Management Strategy

### Core Principle
This repository uses **strict declarative package management** with `homebrew.onActivation.cleanup = "zap"`. This means:
- Any package not declared in the configuration will be **removed** during deployment
- All packages must be explicitly declared in the appropriate configuration files
- Never use `brew install` directly - always add to configuration

### Package Placement Rules

| Package Type | Management Method | Location | Examples |
|--------------|-------------------|----------|----------|
| CLI tools | Nix | `home/_modules/shell/utilities/` | ripgrep, sops, go-task |
| Development languages | Nix | `home/_modules/development/languages/` | python, nodejs, go |
| Infrastructure tools | Nix | `home/_modules/infrastructure/` | terraform, kubectl, helm |
| GUI applications | Homebrew (declared) | `homebrew.casks` | Discord, Slack, VSCode |
| macOS-only tools | Homebrew (declared) | `homebrew.brews` | Tools unavailable in nixpkgs |

### Adding New Packages

1. **Determine the correct location**:
   - Is it a GUI app? → Add to `homebrew.casks` in host config
   - Is it a CLI tool? → Add to appropriate Nix module
   - Is it development-related? → Add to development modules

2. **Make Darwin-specific packages conditional**:
   ```nix
   home.packages = with pkgs; [
     # Cross-platform packages
     ripgrep
   ] ++ lib.optionals pkgs.stdenv.isDarwin [
     mas  # Darwin-only
   ];
   ```

3. **Always validate before deploying**:
   ```bash
   nix flake check
   darwin-rebuild build --flake .
   darwin-rebuild switch --flake .
   ```

### Common Package Locations

- **Shell utilities**: `home/_modules/shell/utilities/default.nix`
- **Development tools**: `home/_modules/development/utilities/default.nix`
- **Language toolchains**: `home/_modules/development/languages/default.nix`
- **Kubernetes tools**: `home/_modules/kubernetes/default.nix`
- **Infrastructure**: `home/_modules/infrastructure/default.nix`
- **Homebrew GUI apps**: `hosts/rymac/default.nix` (homebrew.casks)

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
