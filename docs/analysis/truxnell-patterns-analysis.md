# Truxnell Nix-Config Pattern Analysis

Date: 2025-01-02

## Overview

This document captures the analysis of design patterns from [truxnell/nix-config](https://github.com/truxnell/nix-config) that could benefit our repository, focusing on DRY principles, secrets management, and backup configurations.

## Key Patterns Identified

### 1. Profile-Based Architecture for DRY

truxnell uses a clever separation of hardware and role profiles that significantly reduces duplication:

```nix
# In flake.nix, hosts are composed like:
"daedalus" = mkNixosConfig {
  hostname = "daedalus";
  hardwareModules = [ ./nixos/profiles/hw-generic-x86.nix ];
  profileModules = [
    ./nixos/profiles/role-server.nix
    ./nixos/profiles/role-dev.nix
  ];
};
```

**Benefits:**
- Reuse common hardware configs across similar machines
- Mix and match roles (server, dev, workstation) without duplicating config
- Cleaner host definitions in flake.nix

### 2. Helper Functions for Services

Their `lib.mySystem.mkService` function standardizes container deployments:

```nix
# Creates standardized container configuration with:
# - Automatic Traefik label generation
# - Security hardening options
# - Persistence folder management
# - User/group creation
mkService = options: {
  virtualisation.oci-containers.containers.${options.app} = {
    image = "${options.container.image}";
    user = "${user}:${group}";
    environment = { TZ = options.timeZone; };
    labels = mkTraefikLabels { ... };
    extraOptions = containerExtraOptions;
  };
};
```

### 3. Advanced Backup System

**Current Gap:** Our repository has no backup system configured.

truxnell's approach:
- ZFS snapshots at 2AM before backups (ensures consistency)
- Per-service restic backups to both local and remote
- Automatic systemd service/timer creation
- Built-in warnings for disabled backups

```nix
# Per-service backup configuration
services.restic.backups = mkIf cfg.backup (
  config.lib.mySystem.mkRestic {
    inherit app user;
    paths = [ appFolder ];
    appFolder = appFolder;
  }
);
```

Key implementation details:
- Snapshot creation: `zfs snapshot rpool/local/root@restic_nightly_snap`
- Mount snapshot: `mount -t zfs rpool/local/root@restic_nightly_snap /mnt/nightly_backup`
- Restic backs up from snapshot (not live filesystem)
- Both local (NAS) and remote (Cloudflare R2) destinations

### 4. Security Improvements

#### Per-Machine Age Keys
truxnell derives age keys from SSH host keys:
```yaml
# .sops.yaml
keys:
  - &luna age1lj5vmr02qkudvv2xedfj5tq8x93gllgpr6tzylwdlt7lud4tfv5qfqsd5u
  - &rydev age17edew3aahg3t5nte5g0a505sn96vnj8g8gqse8q06ccrrn2n3uysyshu2c
```

This is more secure than our current shared key approach.

#### Container Security Hardening
```nix
containerExtraOptions =
  lib.optionals (caps.privileged) ["--privileged"]
  ++ lib.optionals (caps.readOnly) ["--read-only"]
  ++ lib.optionals (caps.noNewPrivileges) ["--security-opt=no-new-privileges"]
  ++ lib.optionals (caps.dropAll) ["--cap-drop=ALL"];
```

### 5. NixOS Warnings for Operational Safety

They add warnings for critical misconfigurations:
```nix
warnings = [
  (mkIf (!cfg.backup && config.mySystem.purpose != "Development")
    "WARNING: Backups for ${app} are disabled!")
];
```

## Implementation Roadmap

### Phase 1: Profile Architecture (1-2 days)
1. Create `modules/profiles/` directory
2. Extract hardware-specific configs:
   - `hw-x86_64-vm.nix` (for luna, rydev)
   - `hw-aarch64-darwin.nix` (for rymac)
3. Create role profiles:
   - `role-server.nix` (common server settings)
   - `role-workstation.nix` (desktop/laptop settings)
   - `role-dev.nix` (development tools)
4. Refactor host configs to use these profiles

### Phase 2: Service Helpers (2-3 days)
1. Create `lib/service-helpers.nix` with:
   - `mkPodmanService` - Similar to their mkService but for our Podman/Caddy stack
   - `mkCaddyVirtualHost` - Standardize Caddy config generation
   - Security defaults for containers
2. Refactor existing services to use these helpers

### Phase 3: Backup Infrastructure (3-4 days)
1. Implement `lib/backup-helpers.nix` with `mkRestic` function
2. Add restic module configuration in `modules/nixos/services/restic/`
3. Configure per-service backups for:
   - 1Password Connect
   - Attic
   - UniFi/Omada controllers
   - Other critical services
4. Set up both local (to NAS) and remote (B2/R2) destinations
5. Create restore documentation and taskfiles

### Phase 4: Security Hardening (2-3 days)
1. Migrate to per-machine age keys:
   - Generate age keys from SSH host keys
   - Update `.sops.yaml` with per-host keys
   - Re-encrypt all secrets
2. Add container security options:
   - Drop all capabilities by default
   - Read-only containers where possible
   - No new privileges
3. Implement systemd hardening for services

### Phase 5: Operational Excellence (1-2 days)
1. Add NixOS warnings for:
   - Disabled backups
   - Disabled monitoring
   - Missing security configurations
2. Create restore taskfiles similar to their approach
3. Document backup/restore procedures
4. Add backup monitoring/alerting

## Priority Recommendations

1. **Backup system** (Critical - currently missing entirely)
2. **Profile architecture** (High - major DRY improvement)
3. **Service helpers** (Medium - consistency and security)
4. **Per-machine secrets** (Medium - security improvement)
5. **Operational warnings** (Low - nice to have)

## Comparison with Current Architecture

### What We Have
- Unified mkNixosSystem/mkDarwinSystem builders
- SOPS secrets management (but with shared keys)
- Podman container infrastructure
- Caddy reverse proxy with DNS integration

### What We're Missing
- Backup system (biggest gap)
- Profile-based configuration
- Service helper functions
- Per-machine security keys
- Operational warnings

### What We Do Better
- DNS integration is more sophisticated
- Binary cache (Attic) setup
- Cross-platform Darwin support
- DNS record aggregation from Caddy configs

## Next Steps

1. Start with backup implementation (most critical)
2. Implement profile architecture (biggest DRY win)
3. Create service helpers (improve consistency)
4. Enhance security posture
5. Add operational safeguards

## Code Examples to Reference

### mkRestic Helper (from truxnell)
```nix
lib.mySystem.mkRestic = options: {
  "${options.app}-local" = {
    pruneOpts = [
      "--keep-last 3"
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
    ];
    timerConfig = {
      OnCalendar = "02:05";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    paths = map (x: "${config.mySystem.system.resticBackup.mountPath}/${x}") options.paths;
    passwordFile = config.sops.secrets."services/restic/password".path;
    repository = "${config.mySystem.system.resticBackup.local.location}/${options.appFolder}";
  };

  "${options.app}-remote" = {
    # Similar config for remote backups
  };
};
```

### Profile Usage Pattern
```nix
# Host configuration becomes much cleaner:
mkNixosConfig {
  hostname = "luna";
  hardwareModules = [ ./profiles/hw-x86_64-server.nix ];
  profileModules = [
    ./profiles/role-server.nix
    ./profiles/role-container-host.nix
  ];
}
```

This pattern analysis provides a roadmap for improving our Nix configuration while maintaining what we've already built well.
