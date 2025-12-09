# Storage Module Configuration Guide

## Overview

The NixOS storage module provides declarative ZFS dataset management for services. It separates concerns between base disk layout (disko-config) and service-specific storage needs.

## Architecture

```
┌─────────────────────────────────────────┐
│ disko-config.nix                        │
│ • Creates base ZFS pools (rpool, tank)  │
│ • Creates parent datasets               │
│ • Defines disk partitioning             │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│ storage module (modules/nixos/)  │
│ • Creates service datasets dynamically  │
│ • Sets ZFS properties per service       │
│ • Manages mountpoints and permissions   │
└─────────────────────────────────────────┘
```

## Configuration Pattern

### In Host Config (e.g., `hosts/forge/default.nix`)

```nix
{
  config = {
    modules.storage.datasets = {
      enable = true;
      parentDataset = "tank/services";  # Parent must exist in disko-config
      parentMount = "/srv";  # Fallback for services without explicit mountpoint

      services = {
        # Example: PostgreSQL with optimized settings
        postgres = {
          recordsize = "8K";  # Match PostgreSQL page size
          compression = "lz4";
          mountpoint = "/var/lib/postgresql/16";
          owner = "postgres";
          group = "postgres";
          mode = "0700";
          properties = {
            "com.sun:auto-snapshot" = "true";
            logbias = "throughput";
          };
        };

        # Example: Media service with default settings
        sonarr = {
          recordsize = "128K";  # Default, good for large files
          compression = "lz4";
          mountpoint = "/var/lib/sonarr";
          owner = "sonarr";
          group = "media";
          mode = "0755";
        };
      };
    };
  };
}
```

## How It Works

### System Activation

1. **disko-config** runs during initial install:
   - Creates `tank` pool on physical disks
   - Creates `tank/services` parent dataset with `mountpoint=none`

2. **Storage module** runs during every system activation:
   - Checks if `tank/services/postgres` exists
   - Creates dataset if missing
   - Sets ZFS properties (`recordsize`, `compression`, etc.)
   - Creates mount directory with correct permissions
   - Mounts dataset to target path

### Properties

#### Common ZFS Properties

| Property | PostgreSQL | Media | General |
|----------|-----------|-------|---------|
| recordsize | 8K | 128K | 128K |
| compression | lz4 | lz4 | lz4 |
| logbias | throughput | latency | latency |
| sync | standard | standard | standard |

#### Filesystem Permissions

- **owner**: Unix user that owns the directory
- **group**: Unix group for the directory
- **mode**: Permissions (octal format)
  - `0700`: Owner only (PostgreSQL requires this)
  - `0755`: Owner write, group/others read+execute
  - `02775`: setgid bit, group write (media sharing)

## Service-Specific Examples

### PostgreSQL

```nix
postgres = {
  recordsize = "8K";  # Match 8KB page size
  compression = "lz4";  # Fast compression
  mountpoint = "/var/lib/postgresql/16";
  owner = "postgres";
  group = "postgres";
  mode = "0700";  # Strict permissions required
  properties = {
    "com.sun:auto-snapshot" = "true";  # Automatic snapshots
    logbias = "throughput";  # Optimize for bulk writes
  };
};
```

### Media Services (Sonarr/Radarr/Plex)

```nix
sonarr = {
  recordsize = "128K";  # Good for large video files
  compression = "lz4";
  mountpoint = "/var/lib/sonarr";
  owner = "sonarr";
  group = "media";  # Shared media group
  mode = "02775";  # setgid for group inheritance
  properties = {
    "com.sun:auto-snapshot" = "false";  # Media is backed up elsewhere
  };
};
```

### Container/Docker

```nix
containers = {
  recordsize = "128K";
  compression = "lz4";
  mountpoint = "/var/lib/containers";
  owner = "root";
  group = "root";
  mode = "0755";
  properties = {
    "com.sun:auto-snapshot" = "false";  # Ephemeral data
  };
};
```

## Dataset Management

### Checking Datasets

```bash
# List all service datasets
zfs list -r tank/services

# Check specific dataset properties
zfs get all tank/services/postgres

# Check recordsize
zfs get recordsize tank/services/postgres
```

### Manual Dataset Creation (if needed)

Usually not needed - the module handles this automatically. But for reference:

```bash
# Create manually
sudo zfs create \
  -o recordsize=8K \
  -o compression=lz4 \
  -o mountpoint=/var/lib/postgresql/16 \
  tank/services/postgres

# Set ownership
sudo chown postgres:postgres /var/lib/postgresql/16
sudo chmod 0700 /var/lib/postgresql/16
```

## Common Patterns

### Don't Modify disko-config for Services

❌ **Wrong**: Adding service datasets to disko-config
```nix
# DON'T DO THIS in disko-config.nix
datasets = {
  "tank/services/postgres" = {  # WRONG PLACE
    type = "zfs_fs";
    mountpoint = "/var/lib/postgresql/16";
  };
};
```

✅ **Correct**: Use storage module in host config
```nix
# DO THIS in hosts/forge/default.nix
modules.storage.datasets.services.postgres = {
  recordsize = "8K";
  mountpoint = "/var/lib/postgresql/16";
};
```

### Parent Dataset Must Exist

The `parentDataset` must be created by disko-config:

```nix
# In disko-config.nix
"tank/services" = {
  type = "zfs_fs";
  mountpoint = "none";  # Parent dataset, not mounted
};
```

Then use it in storage module:

```nix
# In host config
modules.storage.datasets = {
  parentDataset = "tank/services";  # Must already exist
  services = { ... };
};
```

## Migration from Manual ZFS

If you have manually created datasets, migrate them to the storage module:

### Step 1: Document Current Setup

```bash
# Check current dataset properties
zfs get recordsize,compression,mountpoint tank/services/postgres
```

### Step 2: Add to Configuration

```nix
# Add matching configuration to host config
modules.storage.datasets.services.postgres = {
  recordsize = "8K";  # Match current value
  compression = "lz4";
  mountpoint = "/var/lib/postgresql/16";
  owner = "postgres";
  group = "postgres";
  mode = "0700";
};
```

### Step 3: Apply and Verify

```bash
# Rebuild system
sudo nixos-rebuild switch

# Verify module took over management
systemctl status systemd-tmpfiles-setup.service
```

The storage module will detect the existing dataset and update properties if needed.

## Troubleshooting

### Dataset Not Created

```bash
# Check activation script logs
journalctl -u zfs-service-datasets

# Verify parent dataset exists
zfs list tank/services

# Check for errors
dmesg | grep -i zfs
```

### Permission Issues

```bash
# Check current permissions
ls -la /var/lib/postgresql/16

# Manually fix (or let tmpfiles do it on next boot)
sudo chown postgres:postgres /var/lib/postgresql/16
sudo chmod 0700 /var/lib/postgresql/16
```

### Properties Not Applied

```bash
# Check current vs desired
zfs get recordsize tank/services/postgres

# Module only sets on creation - manually update if needed
sudo zfs set recordsize=8K tank/services/postgres
```

## Related Documentation

- [disko documentation](https://github.com/nix-community/disko)
- [ZFS recordsize tuning](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)
- [PostgreSQL restore procedure](./postgresql-restore-procedure.md)
