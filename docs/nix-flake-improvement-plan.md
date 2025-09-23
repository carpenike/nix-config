# Nix Flake Repository Improvement Plan

This document outlines a comprehensive plan to align the nix-config repository with modern Nix flake best practices for multi-host configurations.

## Executive Summary

The repository already demonstrates excellent architectural patterns with its unified system builders and layered module system. The main improvements focus on:

1. Converting from comment-based to declarative module enablement
2. Eliminating configuration duplication
3. Improving module organization patterns
4. Cleaning up legacy code

## Current State Analysis

### ✅ Strengths
- **Excellent cross-platform abstraction** via `lib/mkSystem.nix`
- **Clear module layering**: common → platform → host-specific
- **Modern Nix practices**: flakes, SOPS, impermanence
- **Per-service module structure** with dedicated directories

### ⚠️ Areas for Improvement

#### 1. Comment-Based Module Enablement
**Current State:**
- Modules are enabled/disabled by commenting out imports
- Found in: `hosts/_modules/nixos/services/default.nix`, `home/_modules/shell/default.nix`, etc.
- Example: `# ./k3s`, `# ./atuin`

**Issues:**
- Requires modifying shared files for host-specific changes
- Not declarative or reproducible
- Prone to merge conflicts

#### 2. Configuration Duplication
**Current State:**
- Identical configurations across hosts:
  - `bind.nix` (luna/rydev) - 70 lines, 100% identical
  - `haproxy.conf` (luna/rydev) - 58 lines, 100% identical
  - `adguard.nix` (luna/rydev) - 395 lines, 100% identical
- Rydev has orphaned configs (services not enabled but configs present)

**Issues:**
- Maintenance burden when updating configurations
- Risk of configuration drift
- Wasted disk space

#### 3. Archive Directory
**Current State:**
- Large `_archive/` directory with old configurations
- Contains encrypted secrets file
- No documentation about its purpose

**Issues:**
- Adds cognitive overhead
- Unclear if code is referenced or abandoned

#### 4. Module Import Organization
**Current State:**
- Manual import lists requiring updates when adding/removing modules
- Mixed patterns between explicit and implicit imports

## Improvement Roadmap

### Phase 1: Quick Wins (Week 1-2)

#### Task 1.1: Archive Cleanup
- [ ] Review `_archive/` contents for any needed references
- [ ] Create git tag `archive/pre-flake-refactor` with current state
- [ ] Remove `_archive/` directory from main branch
- [ ] Document in commit message what was archived

#### Task 1.2: Remove Orphaned Configurations
- [ ] Delete unused configs from `hosts/rydev/config/`:
  - [ ] `bind.nix`
  - [ ] `haproxy.conf`
  - [ ] `adguard.nix`
  - [ ] `dnsdist.conf` (if not used)

#### Task 1.3: Document Module Pattern
- [ ] Create `docs/architecture/module-patterns.md`
- [ ] Document the mkSystem.nix pattern
- [ ] Explain the three-tier module hierarchy
- [ ] Add examples of proper module structure

### Phase 2: Declarative Module System (Week 3-4)

#### Task 2.1: Convert Service Modules to Declarative Pattern

**Example transformation for k3s module:**

```nix
# hosts/_modules/nixos/services/k3s/default.nix
{ lib, config, ... }:
{
  options.modules.services.k3s = {
    enable = lib.mkEnableOption "k3s Kubernetes";
    # ... other options
  };

  config = lib.mkIf config.modules.services.k3s.enable {
    # ... existing k3s configuration
  };
}
```

**Modules to convert:**
- [ ] All services in `hosts/_modules/nixos/services/`
- [ ] All shell tools in `home/_modules/shell/`
- [ ] Development tools in `home/_modules/development/`

#### Task 2.2: Update Host Configurations

**Example host configuration after conversion:**
```nix
# hosts/luna/default.nix
{
  modules.services = {
    bind.enable = true;
    k3s.enable = false;  # Explicit disable
    nginx.enable = true;
    # ... etc
  };
}
```

- [ ] Update luna configuration
- [ ] Update rydev configuration
- [ ] Update nixpi configuration
- [ ] Update rymac configuration

#### Task 2.3: Clean Up Import Files

After conversion, implement automated module discovery:
```nix
# hosts/_modules/nixos/services/default.nix
let
  # Get all subdirectories in the current directory
  moduleNames = builtins.attrNames (builtins.readDir ./.);
  # Filter out this file itself and any other non-module files
  serviceDirs = builtins.filter (name: name != "default.nix") moduleNames;
  # Create a path for each module directory
  toPath = dir: ./${dir};
in
{
  # Automatically import all service modules
  imports = map toPath serviceDirs;
}
```

**Benefits:**
- Adding a new service module automatically includes it
- No manual import list maintenance
- Eliminates forgotten imports

**Recommended (explicit imports for production stability):**
```nix
# hosts/_modules/nixos/services/default.nix
{
  imports = [
    # Core services
    ./adguardhome
    ./bind
    ./blocky
    ./caddy
    ./cfdyndns
    ./chrony
    ./cloudflared
    ./coachiq
    ./dnsdist
    ./glances
    ./haproxy

    # Infrastructure
    ./k3s        # No longer commented
    ./minio      # No longer commented
    ./nginx
    ./nfs        # No longer commented
    # ... etc
  ];
}
```

**Note:** Perplexity research confirms that explicit imports are preferred for production environments to avoid accidental inclusion of incomplete modules and maintain clear configuration boundaries.

### Phase 3: Configuration Deduplication (Week 5-6)

#### Task 3.1: Create Shared Configuration Sub-Modules

Create proper NixOS modules that provide shared configurations with host-specific customization options:

```nix
# hosts/_modules/nixos/services/bind/shared.nix
{ lib, config, ... }:
let
  cfg = config.modules.services.bind.shared;
in
{
  options.modules.services.bind.shared = {
    enable = lib.mkEnableOption "the shared holthome.net BIND configuration";

    # Allow host-specific overrides or additions
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra configuration lines to append for this specific host.";
    };

    extraZones = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {};
      description = "Additional zones specific to this host.";
    };
  };

  # When enabled, apply the shared configuration using proper NixOS options
  config = lib.mkIf cfg.enable {
    services.bind.zones."holthome.net" = {
      master = true;
      file = config.sops.secrets."networking/bind/zones/holthome.net".path;
      allowTransfer = [ "key externaldns" ];
      # Merge any host-specific zones
    } // cfg.extraZones;

    services.bind.extraConfig = ''
      include "${config.sops.secrets."networking/bind/rndc-key".path}";
      include "${config.sops.secrets."networking/bind/externaldns-key".path}";
      include "${config.sops.secrets."networking/bind/ddnsupdate-key".path}";

      # ACLs and base configuration
      acl trusted {
        10.10.0.0/16;   # LAN
        10.20.0.0/16;   # Servers
        10.30.0.0/16;   # WIRELESS
        10.40.0.0/16;   # IoT
      };

      options {
        listen-on port 5391 { any; };
        allow-recursion { trusted; };
        allow-transfer { none; };
        allow-update { none; };
        dnssec-validation auto;
      };

      ${cfg.extraConfig}
    '';
  };
}
```

#### Task 3.2: Update Main Service Modules

Import shared sub-modules within main service modules:

```nix
# hosts/_modules/nixos/services/bind/default.nix
{ lib, config, ... }:
{
  imports = [ ./shared.nix ]; # Import the shared options module

  options.modules.services.bind.enable = lib.mkEnableOption "BIND DNS Server";

  config = lib.mkIf config.modules.services.bind.enable {
    services.bind.enable = true;
    networking.firewall.allowedTCPPorts = [ 5391 ];
    networking.firewall.allowedUDPPorts = [ 5391 ];
    # Base BIND settings that are always on when enabled
  };
}
```

#### Task 3.3: Refactor Host Configurations

Update host configurations to use the new declarative shared config pattern:

```nix
# hosts/luna/default.nix
{
  modules.services.bind = {
    enable = true;
    shared.enable = true; # Opt-in to shared configuration
  };
}

# hosts/rydev/default.nix (Example of future divergence)
{
  modules.services.bind = {
    enable = true;
    shared = {
      enable = true;
      # Host-specific additions without duplicating shared config
      extraConfig = ''
        # Development-specific DNS settings
        also-notify { 192.168.1.5; };
      '';
      extraZones."dev.holthome.net" = {
        master = true;
        file = "/etc/bind/zones/dev.holthome.net";
      };
    };
  };
}
```

**Benefits of this approach:**
- Fully declarative with consistent options/config pattern
- Highly composable for host-specific customization
- No manual `import` calls in host configurations
- Easy to add host-specific settings without duplicating shared logic

#### Task 3.4: Apply Pattern to Other Services

- [ ] Extract shared bind configuration using sub-module pattern
- [ ] Extract shared haproxy configuration using sub-module pattern
- [ ] Extract shared adguard configuration using sub-module pattern
- [ ] Update host configurations to use new shared patterns

### Phase 4: Polish & Documentation (Week 7-8)

#### Task 4.1: Module Interface Documentation
- [ ] Create standard module template
- [ ] Document required vs optional module options
- [ ] Add module development guidelines

#### Task 4.2: Automation Improvements
- [ ] Add Task commands for common operations:
  - [ ] `task module:new name=servicename`
  - [ ] `task host:enable-service host=hostname service=servicename`
  - [ ] `task validate:all`

#### Task 4.3: Testing Framework
- [ ] Add `nix flake check` validation for all host configurations
- [ ] Create basic module evaluation tests
- [ ] Add CI pipeline for automated validation
- [ ] Document testing approach

**Example flake.nix check addition:**
```nix
# flake.nix
{
  checks = {
    # Verify each host configuration can be evaluated
    luna-eval = self.nixosConfigurations.luna.config.system.build.toplevel;
    rydev-eval = self.nixosConfigurations.rydev.config.system.build.toplevel;
    nixpi-eval = self.nixosConfigurations.nixpi.config.system.build.toplevel;
    rymac-eval = self.darwinConfigurations.rymac.system;
  };
}
```

## Success Metrics

- [ ] Zero commented imports in module files
- [ ] Zero duplicate configuration files
- [ ] All modules use declarative `enable` pattern
- [ ] Archive directory removed
- [ ] Documentation complete for module patterns

## Migration Guidelines

### For Service Modules

1. Add `options.modules.services.<name>.enable`
2. Wrap existing config in `lib.mkIf`
3. Update all host configurations to explicitly enable/disable
4. Remove comments from import lists

### For Configuration Files

1. Identify shared portions of configs
2. Extract to shared module with parameters
3. Update hosts to import and customize shared config
4. Remove duplicate files

### For New Modules

Follow the established pattern:
```nix
{ lib, config, pkgs, ... }:
let
  cfg = config.modules.services.myservice;
in
{
  options.modules.services.myservice = {
    enable = lib.mkEnableOption "my service";
    # Additional options...
  };

  config = lib.mkIf cfg.enable {
    # Service configuration...
  };
}
```

## Risk Mitigation

- **Testing**: Test each change on rydev before production
- **Rollback**: Tag repository before major changes
- **Gradual Migration**: Convert one module type at a time
- **Documentation**: Update docs as changes are made

## Timeline Summary

- **Week 1-2**: Quick wins and cleanup
- **Week 3-4**: Declarative module conversion
- **Week 5-6**: Configuration deduplication
- **Week 7-8**: Polish and documentation

Total estimated time: 8 weeks of part-time effort

## Expert Feedback Integration

Based on feedback from Gemini Pro, O3, and Perplexity, the following key improvements have been incorporated:

### Gemini Pro Recommendations ✅
- **Sub-module pattern** for shared configurations instead of raw string imports
- **Automated module discovery** option with explicit alternative
- **Proper NixOS module structure** using options/config pattern consistently
- **Enhanced testing framework** with flake checks

### O3 Recommendations ✅
- **Host-specific override capabilities** via `extraConfig` and `extraZones` options
- **Explicit merge strategies** using proper NixOS module composition
- **Future-proof flexibility** for host divergence without breaking shared logic
- **Early CI integration** to catch errors during refactoring

### Perplexity Validation ✅
- **Sub-module pattern confirmed** as recognized best practice in Nix community
- **Declarative enable approach** aligns with standard NixOS module conventions
- **Host customization strategy** follows established "inherit and override" workflows
- **Explicit imports recommended** for production/team environments over automation
- **Architecture scales well** for large multi-host deployments
- **No major anti-patterns detected** in the proposed approach

### Key Design Principles
1. **Fully declarative**: No manual imports or string manipulation in host configs
2. **Highly composable**: Easy host-specific customization without duplication
3. **Future-proof**: Host configs can diverge without breaking shared patterns
4. **Consistent patterns**: Same options/config structure across all modules
5. **Production-ready**: Explicit over automated imports for stability and auditability

## Notes

- Maintain backward compatibility during migration
- Prioritize high-value improvements first
- Keep commits atomic and well-documented
- Update CLAUDE.md as patterns change
- Test each phase thoroughly on rydev before production deployment
