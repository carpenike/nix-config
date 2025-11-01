# StateDirectory Migration Guide

## Overview

This guide documents the Phase 2 refactor that migrated services from tmpfiles-based permission management to systemd's native StateDirectory mechanism. This provides a single source of truth for directory ownership and permissions.

**Status:** ✅ **COMPLETED** (2025-11-01)
**Services Migrated:** Grafana, Loki, Plex, Promtail, Prometheus
**Result:** All backups working, permissions persistent, cleanup automatic

## Why This Migration Was Necessary

### Problems with Previous Approach

1. **Redundant Permission Management:** Both tmpfiles AND service configuration set permissions
2. **Conflicting Sources:** tmpfiles could override service settings
3. **Root:Root Defaults:** Using `-` in tmpfiles defaulted to root:root ownership
4. **Home Directory Conflicts:** NixOS activation script enforced 700 on home directories
5. **Non-Idiomatic:** Not using systemd's native directory management

### Benefits of StateDirectory Approach

✅ **Single Source of Truth:** SystemD manages directory creation and ownership
✅ **Automatic Cleanup:** Lifecycle tied to service, no manual tmpfiles rules
✅ **Idiomatic:** Uses systemd's intended directory management mechanism
✅ **Type Safety:** Clear separation between native services and OCI containers
✅ **Persistent Permissions:** No reversion after nixos-rebuild

## Architecture

### Service Type Detection

The system automatically detects service type and applies appropriate pattern:

```
┌─────────────────────────────────────────────────────────────┐
│                    Storage Module                            │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Check: owner/group/mode present in dataset config?│    │
│  └─────────────┬──────────────────┬───────────────────┘    │
│                │                  │                         │
│           YES  │                  │  NO                     │
│                ▼                  ▼                         │
│  ┌─────────────────────┐  ┌──────────────────────┐        │
│  │   OCI Container      │  │  Native SystemD      │        │
│  │                      │  │                      │        │
│  │ • Use tmpfiles       │  │ • Use StateDirectory │        │
│  │ • Set mode/owner/    │  │ • No tmpfiles rules  │        │
│  │   group explicitly   │  │ • Service manages it │        │
│  └─────────────────────┘  └──────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

### Permission Flow

**Native Services:**
```
1. NixOS build → systemd unit with StateDirectory directive
2. Service start → systemd creates /var/lib/<service>
3. Ownership → User:Group from serviceConfig
4. Permissions → StateDirectoryMode (750)
5. Files → Created with UMask (027 = 640)
```

**OCI Containers:**
```
1. NixOS build → tmpfiles rule generated
2. Boot → tmpfiles creates directory
3. Ownership → From dataset owner/group config
4. Permissions → From dataset mode config
5. Container → Mounts existing directory
```

## Implementation Patterns

### Pattern 1: Native SystemD Service

**Service Module (`hosts/_modules/nixos/services/<service>/default.nix`):**

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.services.<service>;
in {
  options.modules.services.<service> = {
    enable = lib.mkEnableOption "<service>";
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/<service>";
      description = "Data directory";
    };
  };

  config = lib.mkIf cfg.enable {
    # User configuration - CRITICAL: home must be /var/empty
    users.users.<service> = {
      isSystemUser = true;
      group = "<service>";
      home = lib.mkForce "/var/empty";  # Prevents activation script interference
    };

    users.groups.<service> = {};

    # SystemD service configuration
    systemd.services.<service> = {
      serviceConfig = {
        # StateDirectory tells systemd which directory to create
        StateDirectory = "<service>";

        # StateDirectoryMode sets permissions (750 = rwxr-x---)
        StateDirectoryMode = "0750";

        # UMask ensures files are group-readable (640 = rw-r-----)
        UMask = "0027";

        User = "<service>";
        Group = "<service>";
      };
    };

    # ZFS dataset (if used) - NO owner/group/mode
    modules.storage.datasets.services.<service> = lib.mkIf (cfg.zfs.dataset != null) {
      mountpoint = cfg.dataDir;
      properties = cfg.zfs.properties;
      # DO NOT SET: owner, group, mode - StateDirectory handles ownership
    };
  };
}
```

### Pattern 2: OCI Container

**Service Module:**

```nix
config = lib.mkIf cfg.enable {
  # User configuration
  users.users.<service> = {
    isSystemUser = true;
    group = "<service>";
    home = "/var/empty";
  };

  # OCI container configuration
  virtualisation.oci-containers.containers.<service> = {
    # ... container config ...
    volumes = [
      "${cfg.dataDir}:/data"
    ];
  };

  # ZFS dataset WITH explicit permissions (OCI needs tmpfiles)
  modules.storage.datasets.services.<service> = lib.mkIf (cfg.zfs.dataset != null) {
    mountpoint = cfg.dataDir;
    properties = cfg.zfs.properties;
    owner = "<service>";
    group = "<service>";
    mode = "0750";
    # Comment: OCI containers don't support StateDirectory, use tmpfiles
  };
};
```

### Pattern 3: Service with Special Permissions (Prometheus)

When upstream module sets StateDirectoryMode, use `lib.mkForce` to override:

```nix
systemd.services.prometheus.serviceConfig = {
  # Override upstream default of 0700
  StateDirectoryMode = lib.mkForce "0750";
  UMask = "0027";
};
```

## Backup Integration

### Backup User Group Membership

Add all service groups to backup user:

```nix
users.users.restic-backup.extraGroups = [
  "grafana"
  "loki"
  "plex"
  "promtail"
  "postgres"
  # Add all services that need backup
];
```

### Handling Permission-Denied Files

Some services create security-sensitive files with 600 permissions. Add exclude patterns:

```nix
# Example: Plex creates .LocalAdminToken with 600 permissions
backup = {
  enable = true;
  excludePatterns = [
    "**/Plex Media Server/.LocalAdminToken"
    "**/Plex Media Server/Setup Plex.html"
  ];
};
```

## Storage Module Changes

**File:** `hosts/_modules/nixos/storage/datasets.nix`

### Before (Problematic)

```nix
systemd.tmpfiles.rules = [
  # This creates directory as root:root for native services!
  "d \"${mountpoint}\" - - - - -"
];
```

### After (Fixed)

```nix
systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (serviceName: serviceConfig:
  let
    hasExplicitPermissions = (serviceConfig.mode or null) != null
                          && (serviceConfig.owner or null) != null
                          && (serviceConfig.group or null) != null;
  in
    if hasExplicitPermissions then [
      # OCI containers: Use tmpfiles with explicit permissions
      "d \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
      "z \"${mountpoint}\" ${serviceConfig.mode} ${serviceConfig.owner} ${serviceConfig.group} - -"
    ] else [
      # Native services: No tmpfiles rules - StateDirectory handles it
    ]
) cfg.services);
```

## Migration Checklist

When migrating a service to StateDirectory:

- [ ] Set `users.users.<service>.home = lib.mkForce "/var/empty"`
- [ ] Add `StateDirectory = "<service>"` to serviceConfig
- [ ] Add `StateDirectoryMode = "0750"` to serviceConfig
- [ ] Add `UMask = "0027"` to serviceConfig
- [ ] Remove `owner`, `group`, `mode` from ZFS dataset config (native only)
- [ ] Add service group to `restic-backup.extraGroups` if backup enabled
- [ ] Test: `systemctl show <service> -p StateDirectory -p StateDirectoryMode`
- [ ] Test: `ls -ld /var/lib/<service>` (should be drwxr-x--- service:service)
- [ ] Test: Restart service and verify permissions persist
- [ ] Test: Run backup and verify success

## Validation Commands

```bash
# 1. Check StateDirectory configuration
systemctl show <service>.service -p StateDirectory -p StateDirectoryMode -p User -p Group

# Expected output:
# User=<service>
# Group=<service>
# StateDirectoryMode=0750
# StateDirectory=<service>

# 2. Verify directory ownership and permissions
ls -ld /var/lib/<service>

# Expected output:
# drwxr-x--- <service> <service> /var/lib/<service>

# 3. Check user home directory
getent passwd <service>

# Expected output:
# <service>:x:NNN:GGG::/var/empty:/sbin/nologin

# 4. Verify tmpfiles rules
systemd-tmpfiles --cat-config | grep <service>

# Native services: Should be EMPTY or no "d" directives
# OCI containers: Should show "d" and "z" with explicit mode/owner/group

# 5. Test permission persistence
sudo systemctl restart <service>.service
ls -ld /var/lib/<service>
# Should still be drwxr-x--- <service>:<service>

# 6. Test backup functionality
sudo systemctl start restic-backup-service-<service>.service
systemctl status restic-backup-service-<service>.service
# Should show: Active: inactive (dead) ... status=0/SUCCESS
```

## Troubleshooting

### Problem: Permissions revert to 700 after nixos-rebuild

**Symptoms:**
```bash
ls -ld /var/lib/<service>
drwx------ <service> <service> /var/lib/<service>  # Wrong!
```

**Cause:** User home directory set to data directory, activation script enforces 700

**Solution:**
```nix
users.users.<service>.home = lib.mkForce "/var/empty";
```

### Problem: Directory owned by root:root

**Symptoms:**
```bash
ls -ld /var/lib/<service>
drwxr-x--- root root /var/lib/<service>  # Wrong!
```

**Cause:** Missing StateDirectory directive or tmpfiles rule with "-"

**Solution:**
```nix
systemd.services.<service>.serviceConfig.StateDirectory = "<service>";
```

### Problem: Backup fails with permission denied

**Symptoms:**
```
error: open /var/lib/<service>/file: permission denied
```

**Cause:** File created with 600 permissions (user-only)

**Solution:** Add exclude pattern for the file:
```nix
backup.excludePatterns = [ "**/path/to/file" ];
```

### Problem: Service fails to start after migration

**Symptoms:**
```
systemd[1]: Failed to set up mount namespacing: No such file or directory
```

**Cause:** StateDirectory not creating directory

**Solution:** Verify StateDirectory is set correctly and matches service user

## Results

### Before Migration

```bash
# Directory ownership
drwxr-x--- root root /var/lib/grafana     # WRONG
drwxr-x--- root root /var/lib/plex        # WRONG

# Backup status
restic-backup-service-grafana: failed (exit-code)
restic-backup-service-plex: failed (exit-code)

# tmpfiles rules
d "/var/lib/grafana" 0750 root root - -   # Creates root:root!
```

### After Migration

```bash
# Directory ownership
drwxr-x--- grafana grafana /var/lib/grafana  # CORRECT
drwxr-x--- plex plex /var/lib/plex           # CORRECT

# Backup status
restic-backup-service-grafana: inactive (dead) status=0/SUCCESS
restic-backup-service-plex: inactive (dead) status=0/SUCCESS

# tmpfiles rules
# (empty for native services)

# StateDirectory configuration
StateDirectory=grafana
StateDirectoryMode=0750
```

## References

- Systemd documentation: https://www.freedesktop.org/software/systemd/man/systemd.exec.html#RuntimeDirectory=
- NixOS manual: https://nixos.org/manual/nixos/stable/#sec-user-management
- Original issue tracking: Phase 2 refactor (2025-11-01)

## Lessons Learned

1. **StateDirectory is idiomatic:** SystemD's intended way to manage service directories
2. **Home directory matters:** NixOS activation script enforces 700 on home dirs
3. **tmpfiles defaults are dangerous:** Using "-" defaults to root:root
4. **OCI containers are different:** They don't support StateDirectory, need tmpfiles
5. **lib.mkForce may be needed:** To override upstream module defaults
6. **Group membership enables backups:** With 750 permissions and proper groups
7. **Some files need exclusion:** Security-sensitive files with 600 permissions
8. **Smart detection works:** Single storage module handles both patterns

This migration pattern should be applied to all future service implementations.
