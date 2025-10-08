# NFS Mount Management Guide

**Last Updated**: 2025-10-08

## Overview

The NFS mount management module provides a DRY (Don't Repeat Yourself) approach to configuring NFS mounts across multiple NixOS hosts. It centralizes NFS server definitions, share configurations, and mount options while allowing host-specific customization.

## Table of Contents

- [Mount Strategies by Use Case](#mount-strategies-by-use-case)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Common Patterns](#common-patterns)
- [Profiles](#profiles)
- [Advanced Usage](#advanced-usage)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)

## Mount Strategies by Use Case

### Backup Storage (Occasional Access)

**Use Case**: Restic repositories, ZFS replication targets, archive storage

**Strategy**: Systemd automount with idle timeout

```nix
fileSystems."/mnt/nas-backup" = {
  device = "nas-1.holthome.net:/mnt/backup/forge/restic";
  fsType = "nfs";
  options = [
    "nfsvers=4.2"
    "rw"
    "noatime"
    "x-systemd.automount"           # Mount on first access
    "x-systemd.idle-timeout=600"    # Unmount after 10 min idle
    "x-systemd.mount-timeout=30s"   # Fail fast if NAS down
  ];
};
```

**Benefits**:

- **Boot Reliability**: Won't block system boot if NAS is unavailable
- **Security**: Automatically unmounts after idle period, minimizing exposure
- **Resource Efficiency**: Only mounted when needed
- **Transparency**: Any service can access the path; it auto-mounts on demand

### Media Library (Continuous Access)

**Use Case**: Plex, Sonarr, Radarr, SABnzbd - services that need continuous shared access

**Strategy**: Single shared mount point (DO NOT create separate mounts per service)

```nix
# Create shared group for all media services
users.groups.media = { gid = 1500; };  # Must match NAS export UID/GID

# Single mount point for ALL media services
fileSystems."/mnt/media" = {
  device = "nas-1.holthome.net:/mnt/media";
  fsType = "nfs";
  options = [
    "nfsvers=4.2"
    "rw"
    "noatime"
    "x-systemd.automount"  # Optional: provides resilience to NAS reboots
    "noauto"               # Required when using automount
  ];
};

# Add all media service users to shared group
users.users = {
  plex.extraGroups = [ "media" ];
  sonarr.extraGroups = [ "media" ];
  radarr.extraGroups = [ "media" ];
  sabnzbd.extraGroups = [ "media" ];
};
```

**Critical Requirements**:

1. **Single Mount Point**: All services reference `/mnt/media` (not `/mnt/plex-media`, `/mnt/sonarr-media`, etc.)
2. **Shared Group**: All service users must be in the `media` group
3. **UID/GID Consistency**: Ensure NFS export uses matching UID/GID (via `anonuid`/`anongid` or user mapping)

**Why Single Mount**:

- Simpler permission management
- Better performance (single NFS connection)
- Prevents file sync issues between mounts
- Industry best practice for shared media libraries

**NFS Server Export Example**:

```bash
# /etc/exports on NAS
/mnt/media  forge.holthome.net(rw,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)
```

### Database/Application Storage (Not Recommended)

**Use Case**: PostgreSQL, Redis, high-IOPS applications

**Strategy**: Avoid NFS; use local ZFS with replication instead

```nix
# Do NOT use NFS for databases
# Instead, use local ZFS and replicate with Syncoid
services.postgresql = {
  enable = true;
  dataDir = "/persist/postgres";  # Local ZFS dataset
};

# Replicate via ZFS (see zfs-replication.nix)
services.syncoid.commands."rpool/safe/persist" = {
  target = "zfs-replication@nas-1.holthome.net:backup/forge/zfs-recv/persist";
  # ...
};
```

**Why Not NFS**:

- Network latency severely impacts database performance
- NFS locking can cause database corruption
- Local ZFS provides snapshots, compression, and better I/O
- ZFS replication provides block-level backup without NFS overhead

## Architecture

### Design Principles

1. **Centralized Definition**: Define NFS servers and shares once in your flake
2. **Host-Specific Overrides**: Each host chooses which shares to mount and where
3. **Profile-Based Configuration**: Use profiles for common scenarios (homelab, performance, readonly)
4. **Flexible Options**: Per-share, per-server, and global mount options
5. **Lazy Loading**: Optional automount for on-demand mounting

### Module Structure

```
modules.filesystems.nfs
├── servers        # NFS server definitions
│   └── <name>
│       ├── address
│       ├── version
│       └── defaultOptions
├── shares         # Share definitions
│   └── <name>
│       ├── server
│       ├── remotePath
│       ├── localPath
│       ├── options
│       └── ...
└── profiles       # Configuration profiles
    ├── homelab
    ├── performance
    ├── reliability
    └── readonly
```

## Quick Start

### Minimal Configuration

Add to your host configuration:

```nix
{
  modules.filesystems.nfs = {
    enable = true;

    # Define NFS server
    servers.nas = {
      address = "nas.holthome.net";
      version = "4.2";
    };

    # Define and mount a share
    shares.media = {
      server = "nas";
      remotePath = "/export/media";
      localPath = "/mnt/media";
      readOnly = true;
    };
  };
}
```

### Centralized Flake Configuration

For multi-host setups, define shares centrally in your flake:

```nix
# flake.nix
{
  outputs = { self, nixpkgs, ... }:
  let
    # Centralized NFS configuration
    nfsConfig = {
      # Define all servers
      servers = {
        nas = {
          address = "nas.holthome.net";
          version = "4.2";
          defaultOptions = [ "rsize=131072" "wsize=131072" ];
        };
        backup-nas = {
          address = "backup.holthome.net";
          version = "4.2";
        };
      };

      # Define all shares
      shares = {
        media = {
          server = "nas";
          remotePath = "/export/media";
          readOnly = true;
          lazy = true;
          description = "Media library (movies, TV, music)";
        };

        documents = {
          server = "nas";
          remotePath = "/export/documents";
          description = "Shared documents";
        };

        backups = {
          server = "nas";
          remotePath = "/export/backups";
          autoMount = false;
          description = "Restic backup storage";
        };

        photos = {
          server = "nas";
          remotePath = "/export/photos";
          description = "Photo library";
        };
      };
    };
  in {
    nixosConfigurations = {
      workstation = nixpkgs.lib.nixosSystem {
        modules = [
          {
            modules.filesystems.nfs = {
              enable = true;
              servers = nfsConfig.servers;

              # Host-specific share configuration
              shares = {
                media = nfsConfig.shares.media // {
                  localPath = "/mnt/media";
                };

                documents = nfsConfig.shares.documents // {
                  localPath = "/home/shared/docs";
                };

                backups = nfsConfig.shares.backups // {
                  localPath = "/mnt/nas/backups";
                };
              };
            };
          }
        ];
      };

      mediaserver = nixpkgs.lib.nixosSystem {
        modules = [
          {
            modules.filesystems.nfs = {
              enable = true;
              servers = nfsConfig.servers;

              shares = {
                media = nfsConfig.shares.media // {
                  localPath = "/var/lib/media";
                  readOnly = false;  # Override for write access
                };

                # Photos not needed on this host
                # (omit from configuration)
              };
            };
          }
        ];
      };
    };
  };
}
```

## Configuration Reference

### Module Options

#### `modules.filesystems.nfs.enable`
- **Type**: `boolean`
- **Default**: `false`
- **Description**: Enable centralized NFS mount management

#### `modules.filesystems.nfs.servers`
- **Type**: `attrsOf submodule`
- **Description**: NFS server definitions

**Server Submodule Options:**

- **address**: Server hostname or IP address
  - Type: `string`
  - Example: `"nas.holthome.net"` or `"192.168.1.100"`

- **version**: NFS protocol version
  - Type: `enum [ "3" "4" "4.0" "4.1" "4.2" ]`
  - Default: `"4.2"`
  - Recommendation: Use `"4.2"` for modern systems

- **defaultOptions**: Default mount options for all shares on this server
  - Type: `listOf string`
  - Default: `[]`
  - Example: `[ "rsize=131072" "wsize=131072" "tcp" ]`

#### `modules.filesystems.nfs.shares`
- **Type**: `attrsOf submodule`
- **Description**: NFS share definitions

**Share Submodule Options:**

- **enable**: Whether to enable this share
  - Type: `boolean`
  - Default: `true`

- **server**: NFS server name (must match a key in `servers`)
  - Type: `string`
  - Required: Yes
  - Example: `"nas"`

- **remotePath**: Remote path on NFS server
  - Type: `string`
  - Required: Yes
  - Example: `"/export/media"`

- **localPath**: Local mount point
  - Type: `nullOr string`
  - Default: `null`
  - Description: Set to `null` to skip mounting on this host
  - Example: `"/mnt/media"`

- **options**: Additional mount options
  - Type: `listOf string`
  - Default: `[]`
  - Description: Merged with server and profile options
  - Example: `[ "noexec" "nosuid" ]`

- **readOnly**: Mount as read-only
  - Type: `boolean`
  - Default: `false`

- **autoMount**: Mount automatically at boot
  - Type: `boolean`
  - Default: `true`

- **lazy**: Use systemd automount (mount on first access)
  - Type: `boolean`
  - Default: `false`
  - Description: Useful for infrequently accessed shares

- **soft**: Use soft mount instead of hard mount
  - Type: `boolean`
  - Default: `false`
  - Description: Soft mounts timeout if server unavailable; hard mounts retry indefinitely

- **cache**: Enable FS-Cache for local caching
  - Type: `boolean`
  - Default: `false`
  - Description: Requires `cachefilesd` service

- **neededForBoot**: Mount early in boot process
  - Type: `boolean`
  - Default: `false`
  - Description: Use for critical system mounts

- **hostFilter**: Only mount on these hosts
  - Type: `listOf string`
  - Default: `[]` (mount on all hosts)
  - Example: `[ "workstation" "mediaserver" ]`

- **description**: Human-readable description
  - Type: `string`
  - Default: `"NFS share <name>"`

#### `modules.filesystems.nfs.profiles`

Pre-configured option sets for common scenarios:

- **homelab**: Balanced settings for homelab use
  - Type: `boolean`
  - Default: `true`
  - Options: `tcp`, `intr`, `timeo=600`, `retrans=2`

- **performance**: High-performance settings
  - Type: `boolean`
  - Default: `false`
  - Options: Large buffers (262144), `async`, `noatime`
  - ⚠️ **Warning**: Cannot be combined with `reliability` profile

- **reliability**: Conservative, reliable settings
  - Type: `boolean`
  - Default: `true`
  - Options: `hard`, `tcp`, `intr`, moderate buffers (65536)
  - ⚠️ **Warning**: Cannot be combined with `performance` profile

- **readonly**: Security-hardened read-only
  - Type: `boolean`
  - Default: `false`
  - Options: `ro`, `noexec`, `nosuid`, `nodev`

#### `modules.filesystems.nfs.globalOptions`
- **Type**: `listOf string`
- **Default**: `[]`
- **Description**: Mount options applied to all NFS mounts

#### `modules.filesystems.nfs.createMountPoints`
- **Type**: `boolean`
- **Default**: `true`
- **Description**: Automatically create mount point directories

## Common Patterns

### Pattern 1: Backup Storage

For backup destinations (like Restic repositories):

```nix
modules.filesystems.nfs = {
  enable = true;

  servers.nas = {
    address = "nas.holthome.net";
    version = "4.2";
  };

  shares.backups = {
    server = "nas";
    remotePath = "/export/backups/${config.networking.hostName}";
    localPath = "/mnt/nas/backups";

    # Manual mount only (not needed until backup runs)
    autoMount = false;

    # Soft mount to avoid hanging if NAS is down
    soft = true;

    # Security hardening
    options = [ "noexec" "nosuid" "nodev" ];

    description = "Restic backup repository";
  };
};
```

Then in your backup configuration:

```nix
modules.backup.restic.repositories.primary = {
  url = "/mnt/nas/backups/${config.networking.hostName}";
  passwordFile = config.sops.secrets.restic-password.path;
};
```

### Pattern 2: Media Library (Read-Only)

For shared media accessed by multiple hosts:

```nix
modules.filesystems.nfs = {
  enable = true;

  # Enable performance profile for streaming
  profiles.performance = true;
  profiles.reliability = false;

  servers.nas = {
    address = "nas.holthome.net";
    version = "4.2";
    defaultOptions = [ "rsize=262144" "wsize=262144" ];
  };

  shares.media = {
    server = "nas";
    remotePath = "/export/media";
    localPath = "/mnt/media";

    # Read-only with security
    readOnly = true;
    options = [ "noexec" "nosuid" "nodev" ];

    # Auto-mount on access
    lazy = true;

    # Enable caching for better performance
    cache = true;

    description = "Media library";
  };
};
```

### Pattern 3: Shared Documents (Read-Write)

For collaborative document storage:

```nix
modules.filesystems.nfs = {
  enable = true;

  servers.nas = {
    address = "nas.holthome.net";
    version = "4.2";
  };

  shares.documents = {
    server = "nas";
    remotePath = "/export/documents";
    localPath = "/home/shared/documents";

    # Read-write access
    readOnly = false;

    # Mount at boot
    autoMount = true;

    # Hard mount for data integrity
    soft = false;

    description = "Shared documents";
  };
};
```

### Pattern 4: Host-Specific Mounts

Different hosts mount the same share at different paths:

```nix
# In flake.nix - define share once
let
  photoShare = {
    server = "nas";
    remotePath = "/export/photos";
    description = "Photo library";
  };
in {
  nixosConfigurations = {
    workstation = nixpkgs.lib.nixosSystem {
      modules = [{
        modules.filesystems.nfs.shares.photos = photoShare // {
          localPath = "/home/user/Photos";
        };
      }];
    };

    photoserver = nixpkgs.lib.nixosSystem {
      modules = [{
        modules.filesystems.nfs.shares.photos = photoShare // {
          localPath = "/var/lib/photoprism/originals";
          readOnly = false;
        };
      }];
    };

    laptop = nixpkgs.lib.nixosSystem {
      modules = [{
        modules.filesystems.nfs.shares.photos = photoShare // {
          # Don't mount on laptop
          localPath = null;
        };
      }];
    };
  };
}
```

### Pattern 5: Multiple NFS Servers

Using multiple NAS devices:

```nix
modules.filesystems.nfs = {
  enable = true;

  servers = {
    primary-nas = {
      address = "nas1.holthome.net";
      version = "4.2";
      defaultOptions = [ "rsize=131072" "wsize=131072" ];
    };

    backup-nas = {
      address = "nas2.holthome.net";
      version = "4.2";
      defaultOptions = [ "rsize=65536" "wsize=65536" ];
    };
  };

  shares = {
    media = {
      server = "primary-nas";
      remotePath = "/export/media";
      localPath = "/mnt/media";
    };

    backup = {
      server = "backup-nas";
      remotePath = "/export/backup";
      localPath = "/mnt/backup";
      autoMount = false;
    };
  };
};
```

## Profiles

### Homelab Profile (Default)

Balanced settings suitable for most homelab use cases:

```nix
modules.filesystems.nfs.profiles.homelab = true;  # Default
```

**Applied Options:**
- `tcp`: Use TCP protocol (reliable)
- `intr`: Allow interruption of hung mounts
- `timeo=600`: Timeout after 60 seconds
- `retrans=2`: Retry twice on timeout

**Best For:**
- General purpose file sharing
- Mixed workload (read and write)
- Typical homelab reliability needs

### Performance Profile

Optimized for maximum throughput:

```nix
modules.filesystems.nfs = {
  profiles.performance = true;
  profiles.reliability = false;  # Must disable
};
```

**Applied Options:**
- `rsize=262144`: Large read buffer (256KB)
- `wsize=262144`: Large write buffer (256KB)
- `async`: Asynchronous writes
- `noatime`: Don't update access times

**Best For:**
- Media streaming servers
- Large file transfers
- Read-heavy workloads
- Systems with reliable network

**⚠️ Cautions:**
- Less resilient to network issues
- Async may cause data loss on crashes
- Higher memory usage

### Reliability Profile

Conservative settings for critical data:

```nix
modules.filesystems.nfs.profiles.reliability = true;
```

**Applied Options:**
- `hard`: Retry indefinitely on failure
- `tcp`: Reliable TCP protocol
- `intr`: Allow interruption
- `rsize=65536`: Moderate read buffer (64KB)
- `wsize=65536`: Moderate write buffer (64KB)

**Best For:**
- Database storage
- Critical application data
- Systems with unreliable network
- Data integrity priority over performance

### Read-Only Profile

Security-hardened for read-only shares:

```nix
modules.filesystems.nfs.profiles.readonly = true;
```

**Applied Options:**
- `ro`: Read-only mount
- `noexec`: Prevent execution
- `nosuid`: Ignore SUID bits
- `nodev`: No device files

**Best For:**
- Public media libraries
- Software repositories
- Configuration templates
- Any untrusted content

**Can Be Combined With:** All other profiles

## Advanced Usage

### Conditional Mounting by Hostname

Mount different shares on different hosts:

```nix
modules.filesystems.nfs = {
  enable = true;

  servers.nas = {
    address = "nas.holthome.net";
    version = "4.2";
  };

  shares = {
    # Only mount on workstations
    user-data = {
      server = "nas";
      remotePath = "/export/users";
      localPath = "/mnt/users";
      hostFilter = [ "workstation1" "workstation2" "laptop" ];
    };

    # Only mount on servers
    app-data = {
      server = "nas";
      remotePath = "/export/app-data";
      localPath = "/var/lib/apps";
      hostFilter = [ "server1" "server2" ];
    };

    # Mount everywhere
    shared = {
      server = "nas";
      remotePath = "/export/shared";
      localPath = "/mnt/shared";
      # hostFilter = []; means mount on all hosts
    };
  };
};
```

### Custom Mount Options Per Share

Fine-tune options for specific shares:

```nix
modules.filesystems.nfs = {
  enable = true;

  servers.nas = {
    address = "nas.holthome.net";
    version = "4.2";
    # Server-wide defaults
    defaultOptions = [ "rsize=131072" "wsize=131072" ];
  };

  # Global options for ALL shares
  globalOptions = [ "tcp" "intr" ];

  shares = {
    # Inherits: server defaults + global options
    normal-share = {
      server = "nas";
      remotePath = "/export/normal";
      localPath = "/mnt/normal";
    };

    # Adds custom options on top of inherited ones
    special-share = {
      server = "nas";
      remotePath = "/export/special";
      localPath = "/mnt/special";
      options = [ "noatime" "nodiratime" "ac" ];
      # Final options: nfsvers=4.2 + rsize=131072 + wsize=131072 +
      #                tcp + intr + noatime + nodiratime + ac
    };
  };
};
```

### Lazy Mounting for Infrequent Access

Use automount for shares not needed at boot:

```nix
modules.filesystems.nfs.shares = {
  # Archive that's rarely accessed
  archive = {
    server = "nas";
    remotePath = "/export/archive";
    localPath = "/mnt/archive";

    # Don't mount at boot, mount on first access
    lazy = true;

    # Unmount after 10 minutes idle
    # (configured via systemd automount)
  };
};
```

The automount unit will:
1. Create a mount point
2. Watch for access attempts
3. Mount the share on first access
4. Unmount after idle timeout (default 600s)

### Integration with Backup Module

Configure NFS mounts for backup storage:

```nix
{
  # NFS mount for backup storage
  modules.filesystems.nfs = {
    enable = true;

    servers.nas = {
      address = "nas.holthome.net";
      version = "4.2";
    };

    shares.backup-storage = {
      server = "nas";
      remotePath = "/export/backups/${config.networking.hostName}";
      localPath = "/mnt/nas/backups";

      # Don't auto-mount (only needed during backups)
      autoMount = false;

      # Use soft mount to avoid hanging if NAS down
      soft = true;

      description = "Restic backup repository storage";
    };
  };

  # Backup configuration using the NFS mount
  modules.backup = {
    enable = true;

    restic = {
      enable = true;

      repositories.primary = {
        url = "/mnt/nas/backups";
        passwordFile = config.sops.secrets.restic-password.path;
      };

      jobs.system = {
        enable = true;
        paths = [ "/etc/nixos" "/home" ];
        repository = "primary";

        # Ensure NFS is mounted before backup
        preBackupScript = ''
          # Mount if not already mounted
          if ! mountpoint -q /mnt/nas/backups; then
            echo "Mounting NFS backup storage..."
            mount /mnt/nas/backups
          fi
        '';
      };
    };
  };
}
```

### Multiple Mount Points for Same Share

Mount the same NFS share at multiple locations:

```nix
modules.filesystems.nfs.shares = {
  media-readonly = {
    server = "nas";
    remotePath = "/export/media";
    localPath = "/mnt/media-ro";
    readOnly = true;
  };

  media-readwrite = {
    server = "nas";
    remotePath = "/export/media";
    localPath = "/mnt/media-rw";
    readOnly = false;
    hostFilter = [ "mediaserver" ];  # Only on specific host
  };
};
```

## Best Practices

### Security

1. **Use Read-Only When Possible**
   ```nix
   shares.public-data = {
     readOnly = true;
     options = [ "noexec" "nosuid" "nodev" ];
   };
   ```

2. **Enable NFSv4.2 for Security Features**
   ```nix
   servers.nas.version = "4.2";  # Supports better security
   ```

3. **Restrict Host Access via hostFilter**
   ```nix
   shares.sensitive = {
     hostFilter = [ "authorized-host1" "authorized-host2" ];
   };
   ```

4. **Use Kerberos for Authentication** (Advanced)
   ```nix
   shares.secure = {
     options = [ "sec=krb5p" ];  # Kerberos with encryption
   };
   ```

### Reliability

1. **Use Hard Mounts for Critical Data**
   ```nix
   shares.important = {
     soft = false;  # Default, ensures data integrity
   };
   ```

2. **Enable TCP Protocol**
   ```nix
   globalOptions = [ "tcp" ];  # More reliable than UDP
   ```

3. **Set Reasonable Timeouts**
   ```nix
   globalOptions = [ "timeo=600" "retrans=2" ];
   ```

4. **Monitor Mount Status**
   ```bash
   # Check mounted NFS shares
   mount | grep nfs

   # Check mount status
   systemctl status mnt-media.mount
   ```

### Performance

1. **Tune Buffer Sizes for Your Network**
   ```nix
   servers.nas.defaultOptions = [
     "rsize=131072"   # 128KB - good for gigabit
     "wsize=131072"   # 128KB
   ];
   ```

2. **Use Lazy Mounting for Infrequent Access**
   ```nix
   shares.rarely-used.lazy = true;
   ```

3. **Enable FS-Cache for Read-Heavy Workloads**
   ```nix
   shares.media = {
     cache = true;
     readOnly = true;
   };
   ```

4. **Disable atime Updates**
   ```nix
   shares.performance-critical.options = [ "noatime" "nodiratime" ];
   ```

### Maintainability

1. **Use Descriptive Names**
   ```nix
   shares.customer-documents = {
     description = "Customer-facing documentation and contracts";
     # ...
   };
   ```

2. **Centralize Server Definitions**
   ```nix
   # In flake.nix, define once
   nfsServers = {
     nas = { address = "nas.holthome.net"; version = "4.2"; };
   };
   ```

3. **Document Special Configurations**
   ```nix
   shares.weird-share = {
     # Note: This share requires legacy NFS3 due to server limitation
     server = "legacy-nas";
     options = [ "proto=tcp" "nolock" ];
   };
   ```

4. **Use Profiles for Consistency**
   ```nix
   # Apply same profile across all hosts
   modules.filesystems.nfs.profiles.homelab = true;
   ```

## Troubleshooting

### Mount Fails with "Connection Refused"

**Symptoms:**
```
mount.nfs: Connection refused
```

**Diagnosis:**
```bash
# Test network connectivity
ping nas.holthome.net

# Check if NFS server is listening
showmount -e nas.holthome.net

# Verify firewall allows NFS
sudo nmap -p 2049 nas.holthome.net
```

**Solutions:**

1. **Check NFS server is running:**
   ```nix
   # On NFS server
   services.nfs.server.enable = true;
   ```

2. **Verify firewall rules:**
   ```nix
   # On NFS server
   networking.firewall = {
     allowedTCPPorts = [ 111 2049 4000 4001 4002 20048 ];
     allowedUDPPorts = [ 111 2049 4000 4001 4002 20048 ];
   };
   ```

3. **Check exports configuration:**
   ```nix
   # On NFS server
   services.nfs.server.exports = ''
     /export/media 192.168.1.0/24(ro,fsid=0,no_subtree_check)
   '';
   ```

### Mount Hangs or Times Out

**Symptoms:**
- System hangs during boot
- `df` command hangs
- Cannot unmount share

**Solutions:**

1. **Use soft mounts for non-critical data:**
   ```nix
   shares.optional = {
     soft = true;
     options = [ "timeo=30" ];  # Timeout after 3 seconds
   };
   ```

2. **Don't auto-mount at boot:**
   ```nix
   shares.flaky = {
     autoMount = false;
   };
   ```

3. **Use lazy mounting:**
   ```nix
   shares.problematic = {
     lazy = true;  # Only mount when accessed
   };
   ```

4. **Force unmount if stuck:**
   ```bash
   sudo umount -f /mnt/share
   sudo umount -l /mnt/share  # Lazy unmount
   ```

### Permission Denied

**Symptoms:**
```
Permission denied
```

**Diagnosis:**
```bash
# Check mount options
mount | grep /mnt/share

# Verify permissions on NFS server
# (from server)
ls -la /export/share
```

**Solutions:**

1. **Verify server export permissions:**
   ```nix
   # On NFS server
   services.nfs.server.exports = ''
     /export/share 192.168.1.0/24(rw,no_root_squash,no_subtree_check)
   '';
   ```

2. **Check for SELinux/AppArmor:**
   ```bash
   getenforce  # Should be Permissive or Disabled
   ```

3. **Verify user mappings (NFSv4):**
   ```nix
   # Ensure idmap is configured correctly
   services.rpcbind.enable = true;
   ```

### Stale File Handle

**Symptoms:**
```
Stale file handle
```

**Cause:** NFS server was restarted or share was recreated

**Solution:**

1. **Unmount and remount:**
   ```bash
   sudo umount /mnt/share
   sudo mount /mnt/share
   ```

2. **Restart NFS client services:**
   ```bash
   sudo systemctl restart nfs-client.target
   ```

3. **Reboot if necessary:**
   ```bash
   sudo reboot
   ```

### Poor Performance

**Symptoms:**
- Slow file transfers
- High latency

**Diagnosis:**
```bash
# Test raw network speed
iperf3 -c nas.holthome.net

# Check NFS mount options
mount | grep nfs

# Monitor NFS statistics
nfsstat -c
```

**Solutions:**

1. **Increase buffer sizes:**
   ```nix
   servers.nas.defaultOptions = [
     "rsize=262144"
     "wsize=262144"
   ];
   ```

2. **Enable performance profile:**
   ```nix
   modules.filesystems.nfs.profiles.performance = true;
   ```

3. **Use TCP instead of UDP:**
   ```nix
   globalOptions = [ "tcp" ];
   ```

4. **Enable caching:**
   ```nix
   shares.slow-share.cache = true;
   ```

5. **Check network configuration:**
   ```bash
   # Verify MTU
   ip link show

   # Consider jumbo frames for gigabit+
   # MTU 9000 for 10GbE networks
   ```

### Debug Mode

Enable verbose logging:

```bash
# Mount with verbose output
sudo mount -v -t nfs4 nas.holthome.net:/export/test /mnt/test

# Check system logs
journalctl -u mnt-media.mount -f

# Enable NFS client debugging
sudo rpcdebug -m nfs -s all
sudo rpcdebug -m rpc -s all

# Disable debugging when done
sudo rpcdebug -m nfs -c all
sudo rpcdebug -m rpc -c all
```

## Examples

### Complete Homelab Configuration

```nix
{ config, lib, ... }:
{
  modules.filesystems.nfs = {
    enable = true;

    # Use homelab profile
    profiles.homelab = true;

    # Define NFS servers
    servers = {
      nas = {
        address = "nas.holthome.net";
        version = "4.2";
        defaultOptions = [
          "rsize=131072"
          "wsize=131072"
        ];
      };
    };

    # Global options for all shares
    globalOptions = [
      "tcp"
      "intr"
    ];

    # Define shares
    shares = {
      # Media library (read-only, lazy mount)
      media = {
        server = "nas";
        remotePath = "/export/media";
        localPath = "/mnt/media";
        readOnly = true;
        lazy = true;
        cache = true;
        options = [ "noexec" "nosuid" ];
        description = "Media library (movies, TV, music)";
      };

      # Documents (read-write)
      documents = {
        server = "nas";
        remotePath = "/export/documents";
        localPath = "/home/shared/documents";
        autoMount = true;
        description = "Shared documents";
      };

      # Backup storage (manual mount)
      backups = {
        server = "nas";
        remotePath = "/export/backups/${config.networking.hostName}";
        localPath = "/mnt/nas/backups";
        autoMount = false;
        soft = true;
        options = [ "noexec" "nosuid" "nodev" ];
        description = "Restic backup repository";
      };

      # Photos (read-only for most hosts)
      photos = {
        server = "nas";
        remotePath = "/export/photos";
        localPath = "/mnt/photos";
        readOnly = true;
        lazy = true;
        description = "Photo library";
      };
    };

    # Automatically create mount point directories
    createMountPoints = true;
  };
}
```

### Minimal Workstation

```nix
{
  modules.filesystems.nfs = {
    enable = true;

    servers.nas = {
      address = "192.168.1.100";
    };

    shares = {
      home-backup = {
        server = "nas";
        remotePath = "/export/backup";
        localPath = "/mnt/backup";
        autoMount = false;
      };
    };
  };
}
```

### High-Performance Media Server

```nix
{
  modules.filesystems.nfs = {
    enable = true;

    # Performance-focused
    profiles.performance = true;
    profiles.reliability = false;

    servers.nas = {
      address = "nas.holthome.net";
      version = "4.2";
      defaultOptions = [
        "rsize=262144"
        "wsize=262144"
      ];
    };

    shares.media = {
      server = "nas";
      remotePath = "/export/media";
      localPath = "/var/lib/media";
      readOnly = false;  # Need write access for Plex/Jellyfin
      cache = true;
      options = [ "async" "noatime" ];
    };
  };
}
```

### Critical Database Server

```nix
{
  modules.filesystems.nfs = {
    enable = true;

    # Reliability-focused
    profiles.reliability = true;

    servers.storage = {
      address = "storage.holthome.net";
      version = "4.2";
    };

    shares.db-data = {
      server = "storage";
      remotePath = "/export/database";
      localPath = "/var/lib/postgresql";

      # Hard mount, never give up
      soft = false;

      # Mount before PostgreSQL starts
      neededForBoot = true;

      # Conservative options
      options = [
        "sync"      # Synchronous writes
        "noatime"   # Performance without risking integrity
      ];
    };
  };
}
```

## Migration Guide

### From Manual fileSystems Configuration

**Before:**
```nix
fileSystems."/mnt/media" = {
  device = "nas.holthome.net:/export/media";
  fsType = "nfs4";
  options = [ "nfsvers=4.2" "ro" "rsize=131072" "wsize=131072" "tcp" "intr" ];
};
```

**After:**
```nix
modules.filesystems.nfs = {
  enable = true;

  servers.nas = {
    address = "nas.holthome.net";
    version = "4.2";
    defaultOptions = [ "rsize=131072" "wsize=131072" ];
  };

  globalOptions = [ "tcp" "intr" ];

  shares.media = {
    server = "nas";
    remotePath = "/export/media";
    localPath = "/mnt/media";
    readOnly = true;
  };
};
```

**Benefits:**
- Server configuration reused across shares
- Options organized by purpose
- Easier to add more shares
- Better documentation

## Conclusion

The NFS mount management module provides:
- **DRY Configuration**: Define servers and shares once, use everywhere
- **Flexible Options**: Per-share, per-server, and global customization
- **Profile Support**: Pre-configured settings for common use cases
- **Host Filtering**: Mount only where needed
- **Integration Ready**: Works seamlessly with backup module and other services

For additional help:
- Check system logs: `journalctl -u '*.mount' -f`
- List NFS mounts: `mount | grep nfs`
- View module source: `/hosts/_modules/nixos/filesystems/nfs/default.nix`
