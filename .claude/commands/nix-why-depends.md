# /nix-why-depends

Explain why a specific package is part of a system's closure - essential for dependency analysis.

## Usage

```
/nix-why-depends package=<package> host=<hostname>
```

## Parameters

- `package` (required): Package name to analyze (e.g., `openssl`, `curl`)
- `host` (required): Host configuration to analyze

## Examples

```bash
# Why does luna depend on openssl?
/nix-why-depends package=openssl host=luna

# Trace curl dependency
/nix-why-depends package=curl host=rymac

# Check Python dependency
/nix-why-depends package=python3 host=rydev
```

## Implementation

### NixOS hosts
```bash
nix why-depends .#nixosConfigurations.{host} nixpkgs#{package}
```

### Darwin hosts
```bash
nix why-depends .#darwinConfigurations.{host} nixpkgs#{package}
```

## Package Reference Formats

### Standard packages
- `nixpkgs#openssl` - OpenSSL from nixpkgs
- `nixpkgs#curl` - cURL from nixpkgs
- `nixpkgs#python3` - Python 3 from nixpkgs

### Specific versions (if using overlays)
- `nixpkgs-unstable#package` - From unstable overlay
- `rust-overlay#rust` - From rust overlay

### Custom packages
- Check `pkgs/` directory for custom package definitions
- Reference as `nixpkgs#custom-package-name`

## Output Interpretation

### Dependency Chain
```
/nix/store/...-system
└── /nix/store/...-systemd-250.4
    └── /nix/store/...-curl-7.80.0
        └── /nix/store/...-openssl-1.1.1q
```

### Multiple Paths
Some packages may have multiple dependency paths:
```
openssl is required by:
1. curl → openssl (for HTTPS)
2. openssh → openssl (for crypto)
3. nginx → openssl (for TLS)
```

## Use Cases

### Dependency Optimization
- **Closure size reduction**: Identify unexpected large dependencies
- **Duplicate dependencies**: Find packages pulled in multiple ways
- **Unnecessary packages**: Locate packages that shouldn't be included

### Security Auditing
- **Vulnerability tracking**: Understand which services use vulnerable packages
- **Update planning**: Identify all components affected by security updates
- **Attack surface analysis**: Map security-critical dependencies

### Troubleshooting
- **Missing libraries**: Understand why expected packages aren't included
- **Version conflicts**: Trace why wrong package versions are selected
- **Build failures**: Identify missing build-time dependencies

### System Understanding
- **Architecture analysis**: Map how your system components interconnect
- **Service dependencies**: Understand service-level package requirements
- **Configuration validation**: Verify packages match intended architecture

## Common Packages to Analyze

### Security-Critical
- `openssl` - Cryptographic library used by many services
- `glibc` - Core C library, fundamental to system operation
- `systemd` - Init system and service manager

### Development Tools
- `gcc` - Compiler, may indicate development tools in production
- `python3` - Scripting language, check if needed in production
- `nodejs` - JavaScript runtime, verify necessity

### Network Services
- `curl` - HTTP client, often pulled in by various tools
- `openssh` - SSH client/server
- `nginx` - Web server dependencies

## Performance Considerations

### Large closures
- Some analyses may take time for complex systems
- Consider analyzing specific services vs entire system
- Use on development systems first

### Caching
- Nix caches evaluation results
- Subsequent queries for same system will be faster

## Advanced Usage

### Reverse dependencies
```bash
# Find what depends ON a package
nix why-depends .#nixosConfigurations.luna /nix/store/...-openssl-path
```

### Service-specific analysis
Focus analysis on specific services by examining their closures:
```bash
# Analyze nginx service dependencies
nix why-depends .#nixosConfigurations.luna.config.systemd.services.nginx nixpkgs#openssl
```

## Notes

- **Build required**: System must be evaluatable (run `/nix-validate` first)
- **Package resolution**: Uses nixpkgs from your flake inputs
- **Custom packages**: Include your custom packages from `pkgs/`
- **Multiple instances**: Same package may appear at different versions
- **Transitive dependencies**: Shows full dependency chain, not just direct deps
