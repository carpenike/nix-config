# NixOS Backup System Onboarding Guide

**Last Updated**: 2025-10-08

## Overview

This guide provides comprehensive instructions for onboarding new hosts and services to the centralized NixOS backup system. The backup system is built on Restic with ZFS snapshot integration, comprehensive monitoring, automated testing, and enterprise-grade features including error analysis and documentation generation.

## Table of Contents

- [System Architecture](#system-architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Host Onboarding](#host-onboarding)
  - [Step 9: Configure ZFS Replication (Optional)](#step-9-configure-zfs-replication-optional-but-recommended)
- [Service Onboarding](#service-onboarding)
- [Configuration Reference](#configuration-reference)
- [Advanced Features](#advanced-features)
- [Monitoring & Alerting](#monitoring--alerting)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## System Architecture

The backup system consists of several integrated components:

### Core Components

1. **Restic Backup Engine**: Modern, encrypted, deduplicated file-based backup solution
2. **ZFS Snapshot Integration**: Consistent point-in-time backups via ZFS snapshots
3. **Sanoid/Syncoid (Optional)**: Automated ZFS snapshot management and block-level replication
4. **Service Module**: Pre-configured backup profiles for common services (UniFi, Omada, 1Password Connect, Attic, System configs)
5. **Monitoring System**: Multi-tier monitoring with Prometheus metrics, error analysis, and notifications
6. **Automated Testing**: Repository verification and restore testing
7. **Documentation Generator**: Self-documenting system with runbooks

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        NixOS Host                           │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │  ZFS Pool    │  │   Service    │  │   System     │     │
│  │  Snapshots   │  │   Data       │  │   Configs    │     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│         │                  │                  │              │
│         └──────────────────┴──────────────────┘              │
│                            │                                 │
│                    ┌───────▼────────┐                       │
│                    │ Restic Backups │                       │
│                    │   (Encrypted)  │                       │
│                    └───────┬────────┘                       │
│                            │                                 │
│         ┌──────────────────┼──────────────────┐            │
│         │                  │                  │             │
│    ┌────▼────┐      ┌─────▼─────┐      ┌────▼────┐       │
│    │ Primary │      │ Secondary │      │  Cloud  │       │
│    │  Repo   │      │   Repo    │      │  Repo   │       │
│    └─────────┘      └───────────┘      └─────────┘       │
│                                                             │
│  ┌──────────────────────────────────────────────────┐     │
│  │           Monitoring & Testing Layer              │     │
│  ├──────────────────────────────────────────────────┤     │
│  │ • Prometheus Metrics  • Error Analysis           │     │
│  │ • Repository Checks   • Restore Testing          │     │
│  │ • ntfy Notifications  • Healthchecks.io          │     │
│  │ • Auto Documentation  • Audit Logging            │     │
│  └──────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

Before onboarding a host, ensure the following are available:

### Required

1. **NixOS System**: Host must be running NixOS
2. **Backup Repository**: At least one configured Restic repository (local, NAS, or cloud)
3. **Repository Password**: Secure password file for repository encryption
4. **Network Access**: Connectivity to backup destinations

### Optional but Recommended

1. **ZFS Filesystem**: For consistent snapshots during backup
2. **NFS Mount Management**: For standardized NAS-based backup storage (see [NFS Mount Management Guide](./nfs-mount-management.md))
3. **Node Exporter**: For Prometheus metrics export
4. **SOPS/Age**: For secure secret management (repository passwords, credentials)
5. **Notification Service**: ntfy.sh or Healthchecks.io for alerts

### SOPS Secret Management

Repository passwords and service credentials should be managed via SOPS:

```nix
# In secrets.sops.yaml
restic-primary-password: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
restic-b2-env: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
unifi-mongo-credentials: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
```

```nix
# In your host configuration
sops.secrets.restic-primary-password = {
  sopsFile = ./secrets.sops.yaml;
  owner = "restic-backup";
  group = "restic-backup";
  mode = "0400";
};
```

## Quick Start

### Basic Host Backup Configuration

The simplest configuration to get started:

```nix
# In your host's configuration.nix
{
  modules.backup = {
    enable = true;

    # Configure at least one repository
    restic = {
      enable = true;

      repositories.primary = {
        url = "/mnt/nas/backups/${config.networking.hostName}";
        passwordFile = config.sops.secrets.restic-password.path;
        primary = true;
      };

      # Define backup jobs
      jobs.system = {
        enable = true;
        paths = [
          "/etc/nixos"
          "/home"
        ];
        repository = "primary";
        tags = [ "system" "essential" ];
      };
    };

    # Enable basic monitoring
    monitoring = {
      enable = true;
      ntfy = {
        enable = true;
        topic = "https://ntfy.sh/my-backups";
      };
    };
  };
}
```

This minimal configuration provides:
- Daily backups at 02:00
- 14 daily, 8 weekly, 6 monthly, 2 yearly retention
- ntfy notifications on failure
- Structured JSON logging

## Host Onboarding

### Step 1: Import the Backup Module

The backup module is located at `/hosts/_modules/nixos/backup.nix` and is automatically imported via the default module imports.

Verify it's imported:

```nix
# In /hosts/_modules/nixos/default.nix
{
  imports = [
    # ... other modules
    ./backup.nix
    ./services/backup-services.nix
  ];
}
```

### Step 2: Configure Repositories

Define one or more backup repositories. Repositories can be local, NAS-based, or cloud-based.

#### Local/NAS Repository

For NAS-based repositories, use the NFS mount management module for standardized configuration:

```nix
# First, configure the NFS mount (see nfs-mount-management.md)
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
    autoMount = false;  # Manual mount, only needed during backups
    soft = true;        # Don't hang if NAS is unavailable
    options = [ "noexec" "nosuid" "nodev" ];
  };
};

# Then configure the backup repository
modules.backup.restic.repositories = {
  primary = {
    url = "/mnt/nas/backups";
    passwordFile = config.sops.secrets.restic-primary-password.path;
    primary = true;
  };
};
```

> **Note**: See the [NFS Mount Management Guide](./nfs-mount-management.md) for comprehensive NFS configuration options and best practices.

#### Backblaze B2 Repository

```nix
modules.backup.restic.repositories = {
  b2-cloud = {
    url = "b2:bucket-name:/${config.networking.hostName}";
    passwordFile = config.sops.secrets.restic-b2-password.path;
    environmentFile = config.sops.secrets.restic-b2-env.path;  # Contains B2 credentials
    primary = false;
  };
};
```

Environment file format for B2:
```bash
B2_ACCOUNT_ID=your_account_id
B2_ACCOUNT_KEY=your_account_key
```

#### SFTP Repository

```nix
modules.backup.restic.repositories = {
  remote-sftp = {
    url = "sftp:backup@backup-server.example.com:/backups/${config.networking.hostName}";
    passwordFile = config.sops.secrets.restic-sftp-password.path;
    primary = false;
  };
};
```

### Step 3: Configure ZFS Integration (Optional)

If your host uses ZFS, enable snapshot integration for consistent backups:

```nix
modules.backup.zfs = {
  enable = true;
  pool = "rpool";  # Your ZFS pool name
  datasets = [
    ""              # Root dataset
    "home"          # Additional datasets
    "var/lib"
  ];
  retention = {
    daily = 7;
    weekly = 4;
    monthly = 3;
  };
};
```

**How ZFS Integration Works:**
1. Before backup, a snapshot is created for each dataset
2. The snapshot is mounted at `/mnt/backup-snapshot`
3. Restic backs up from the snapshot (consistent state)
4. After backup, snapshots are cleaned up based on retention

### Step 4: Define Backup Jobs

Create backup jobs for different data types:

```nix
modules.backup.restic.jobs = {
  # System configuration backup
  system-config = {
    enable = true;
    paths = [
      "/etc/nixos"
      "/etc/systemd"
    ];
    repository = "primary";
    tags = [ "system" "configuration" ];
    excludePatterns = [
      "*.tmp"
      "*/.git"
    ];
  };

  # Home directories backup
  home = {
    enable = true;
    paths = [
      "/home"
    ];
    repository = "primary";
    tags = [ "user-data" "home" ];
    excludePatterns = [
      "*/.cache"
      "*/node_modules"
      "*/target"
      "*/.git"
    ];
    resources = {
      memory = "512m";
      cpus = "1.0";
    };
  };

  # Application data backup
  app-data = {
    enable = true;
    paths = [
      "/var/lib/postgresql"
      "/var/lib/mysql"
    ];
    repository = "primary";
    tags = [ "databases" "critical" ];
    preBackupScript = ''
      # Dump databases before backup
      echo "Creating database dumps..."
      # Add your database dump commands here
    '';
    postBackupScript = ''
      # Cleanup dumps
      echo "Cleaning up database dumps..."
    '';
  };
};
```

### Step 5: Configure Monitoring

Enable comprehensive monitoring and alerting:

```nix
modules.backup.monitoring = {
  enable = true;

  # ntfy.sh notifications
  ntfy = {
    enable = true;
    topic = "https://ntfy.sh/my-homelab-backups";
  };

  # Healthchecks.io monitoring
  healthchecks = {
    enable = true;
    uuidFile = config.sops.secrets.healthchecks-uuid.path;
  };

  # Immediate failure notifications
  onFailure = {
    enable = true;
    notificationScript = ''
      # Custom failure handling
      echo "Backup failed for $JOB_NAME on $HOSTNAME"
      # Add custom notification logic
    '';
  };

  # Prometheus metrics export
  prometheus = {
    enable = true;
    metricsDir = "/var/lib/node_exporter/textfile_collector";
  };

  # Error analysis and categorization
  errorAnalysis = {
    enable = true;
    # Uses default error categories or customize
  };
};
```

### Step 6: Enable Advanced Features

#### Repository Verification

```nix
modules.backup.verification = {
  enable = true;
  schedule = "weekly";           # daily/weekly/monthly
  checkData = false;             # Set true for full data integrity check
  checkDataSubset = "5%";        # Percentage to check when checkData=false
};
```

#### Automated Restore Testing

```nix
modules.backup.restoreTesting = {
  enable = true;
  schedule = "monthly";
  sampleFiles = 10;              # Number of random files to test
  testDir = "/tmp/backup-restore-test";
  retainTestData = false;        # Cleanup after test
};
```

#### Configuration Validation

```nix
modules.backup.validation = {
  enable = true;
  preFlightChecks = {
    enable = true;
    minFreeSpace = "10G";
    networkTimeout = 30;
  };
  repositoryHealth = {
    enable = true;
    maxAge = "48h";              # Alert if no backup in 48h
    minBackups = 3;              # Minimum snapshots to maintain
  };
};
```

#### Performance Tuning

```nix
modules.backup.performance = {
  cacheDir = "/var/cache/restic";
  cacheSizeLimit = "1G";
  ioScheduling = {
    enable = true;
    ioClass = "idle";            # Don't impact other I/O
    priority = 7;                # Lowest priority
  };
};
```

#### Security Hardening

```nix
modules.backup.security = {
  enable = true;
  restrictNetwork = true;        # Only allow access to backup repos
  readOnlyRootfs = true;         # Read-only root filesystem
  auditLogging = true;           # Detailed audit logs
};
```

#### Documentation Generation

```nix
modules.backup.documentation = {
  enable = true;
  outputDir = "/var/lib/backup/docs";
  includeMetrics = true;
};
```

This generates comprehensive documentation including:
- System overview and configuration
- Operational procedures and runbooks
- Troubleshooting guides
- Metrics reference
- Emergency procedures

### Step 7: Customize Global Settings

```nix
modules.backup.restic.globalSettings = {
  compression = "auto";          # auto/off/max
  readConcurrency = 2;           # Concurrent read operations
  retention = {
    daily = 14;
    weekly = 8;
    monthly = 6;
    yearly = 2;
  };
};

modules.backup.schedule = "02:00";  # Backup time (24-hour format)
```

### Step 8: Apply Configuration

```bash
# Build and switch to new configuration
sudo nixos-rebuild switch

# Verify backup services are enabled
systemctl list-timers "restic-*"

# Check service status
systemctl status restic-backups-*

# View logs
journalctl -u restic-backups-* -f
```

### Step 9: Configure ZFS Replication (Optional but Recommended)

For hosts with ZFS, add automated snapshot management and replication using Sanoid and Syncoid. This provides block-level replication complementing the file-based Restic backups.

#### Prerequisites

1. **ZFS-based filesystem** on source host
2. **ZFS dataset** on destination (e.g., nas-1)
3. **SSH key** for zfs-replication user
4. **ZFS permissions** granted on both source and destination

#### Configure Sanoid (Snapshot Management)

Add to your host configuration (e.g., `hosts/forge/zfs-replication.nix`):

```nix
{ config, ... }:

{
  config = {
    # Create dedicated user for ZFS replication
    users.users.zfs-replication = {
      isSystemUser = true;
      group = "zfs-replication";
      home = "/var/lib/zfs-replication";
      createHome = true;
      shell = "/run/current-system/sw/bin/nologin";
      description = "ZFS replication service user";
    };

    users.groups.zfs-replication = {};

    # Manage SSH private key via SOPS
    sops.secrets."zfs-replication/ssh-key" = {
      owner = "zfs-replication";
      group = "zfs-replication";
      mode = "0600";
      path = "/var/lib/zfs-replication/.ssh/id_ed25519";
    };

    # Create .ssh directory
    systemd.tmpfiles.rules = [
      "d /var/lib/zfs-replication/.ssh 0700 zfs-replication zfs-replication -"
    ];

    # Configure Sanoid for snapshot management
    services.sanoid = {
      enable = true;

      templates = {
        production = {
          hourly = 24;      # 1 day of hourly snapshots
          daily = 7;        # 1 week of daily snapshots
          weekly = 4;       # 1 month of weekly snapshots
          monthly = 3;      # 3 months of monthly snapshots
          yearly = 0;       # No yearly snapshots
          autosnap = true;
          autoprune = true;
        };
      };

      datasets = {
        "rpool/safe/home" = {
          useTemplate = [ "production" ];
          recursive = false;
        };

        "rpool/safe/persist" = {
          useTemplate = [ "production" ];
          recursive = false;
        };
      };
    };

    # Configure Syncoid for replication
    services.syncoid = {
      enable = true;
      interval = "hourly";
      sshKey = "/var/lib/zfs-replication/.ssh/id_ed25519";

      commands = {
        "rpool/safe/home" = {
          target = "zfs-replication@nas-1.holthome.net:backup/forge/zfs-recv/home";
          recursive = false;
          sendOptions = "w";  # Raw encrypted send
          recvOptions = "u";  # Receive without mounting
        };

        "rpool/safe/persist" = {
          target = "zfs-replication@nas-1.holthome.net:backup/forge/zfs-recv/persist";
          recursive = false;
          sendOptions = "w";
          recvOptions = "u";
        };
      };
    };
  };
}
```

#### Post-Deployment: Verify ZFS Permissions

ZFS permissions are now applied **automatically** via a systemd service (`zfs-delegate-permissions.service`). After deploying, verify they were applied correctly:

```bash
# On source host (e.g., forge)
ssh forge.holthome.net

# Verify the systemd service ran successfully
systemctl status zfs-delegate-permissions.service

# Verify permissions were granted
sudo zfs allow rpool/safe/home
sudo zfs allow rpool/safe/persist

# Expected output should show:
# - sanoid: send,snapshot,hold,destroy
# - zfs-replication: send,snapshot,hold
```

> **Note**: The configuration includes a `systemd.services.zfs-delegate-permissions` service that automatically applies ZFS permissions at boot, making the system fully declarative and reproducible.

On destination host (nas-1), the zfs-replication user needs receive permissions:

```bash
# On destination host (nas-1)
ssh nas-1.holthome.net

# Grant receive permissions
sudo zfs allow zfs-replication receive,create,mount,hold backup/forge/zfs-recv

# Verify permissions
sudo zfs allow backup/forge/zfs-recv
```

#### Verify ZFS Replication Setup

```bash
# On source host - check services
systemctl status sanoid.timer
systemctl status syncoid.timer

# Trigger initial snapshot
sudo systemctl start sanoid.service

# Check snapshots were created
zfs list -t snapshot | grep autosnap

# Trigger initial replication (will take time for first full send)
sudo systemctl start syncoid.service

# Monitor replication progress
sudo journalctl -u syncoid.service -f

# On destination - verify snapshots arrived
ssh nas-1.holthome.net 'zfs list -t all backup/forge/zfs-recv'
```

#### ZFS Replication Monitoring

```bash
# Check timer schedules
systemctl list-timers sanoid syncoid

# View recent snapshot activity
sudo journalctl -u sanoid.service -n 50

# View recent replication activity
sudo journalctl -u syncoid.service -n 50

# Check for errors
systemctl --state=failed | grep -E "sanoid|syncoid"

# Compare snapshot counts (source vs destination)
echo "Source snapshots:"
zfs list -t snapshot rpool/safe/home | wc -l
echo "Destination snapshots:"
ssh nas-1.holthome.net 'zfs list -t snapshot backup/forge/zfs-recv/home | wc -l'
```

> **Note**: For comprehensive ZFS replication documentation, see [Sanoid & Syncoid Setup Guide](./sanoid-syncoid-setup.md)

#### Benefits of Sanoid/Syncoid

**Complements Restic by providing:**
- Near-instant snapshots (copy-on-write)
- Efficient block-level replication (only changed blocks)
- Fast bare-metal recovery
- Preserves ZFS properties and attributes
- Hourly snapshots with automatic pruning

**Use cases:**
- Quick rollback to recent snapshot
- Fast recovery of entire datasets
- Replication to off-site ZFS storage
- Disaster recovery with block-level consistency

## Service Onboarding

The backup system includes pre-configured profiles for common homelab services. These profiles handle service-specific requirements like database dumps, application quiescence, and proper exclusion patterns.

### Available Service Profiles

1. **UniFi Controller**: MongoDB dumps and configuration backup
2. **Omada Controller**: Database export and configuration
3. **1Password Connect**: Vault and credentials backup
4. **Attic Binary Cache**: Large dataset backup with optional ZFS send
5. **System Configuration**: NixOS generation and flake tracking

### Enabling Service Backups

Import the service backup module (already imported by default):

```nix
# In /hosts/_modules/nixos/default.nix
imports = [
  ./backup.nix
  ./services/backup-services.nix
];
```

### UniFi Controller Backup

```nix
modules.services.backup-services = {
  enable = true;

  unifi = {
    enable = true;
    dataPath = "/var/lib/unifi";  # Default path
    mongoCredentialsFile = config.sops.secrets.unifi-mongo-creds.path;
  };
};
```

**What it backs up:**
- MongoDB database with oplog (point-in-time consistency)
- Configuration files
- Keystore
- Excludes: logs, work, temp directories

**SOPS secret format** (mongoCredentialsFile):
```bash
MONGO_USER=admin
MONGO_PASSWORD=your_secure_password
```

### Omada Controller Backup

```nix
modules.services.backup-services = {
  enable = true;

  omada = {
    enable = true;
    dataPath = "/var/lib/omada";
    containerName = "omada";      # If running in container
  };
};
```

**What it backs up:**
- MongoDB collections (sites, devices)
- Controller data and configuration
- Excludes: logs, work, temp directories

### 1Password Connect Backup

```nix
modules.services.backup-services = {
  enable = true;

  onepassword-connect = {
    enable = true;
    dataPath = "/var/lib/onepassword-connect/data";
    credentialsFile = config.sops.secrets.op-connect-creds.path;
  };
};
```

**What it backs up:**
- Vault data
- Credentials and sync state
- Excludes: temporary files, cache

### Attic Binary Cache Backup

```nix
modules.services.backup-services = {
  enable = true;

  attic = {
    enable = true;
    dataPath = "/var/lib/attic";

    # Option 1: Standard Restic backup (smaller caches)
    useZfsSend = false;

    # Option 2: ZFS send/receive (recommended for large caches)
    useZfsSend = true;
    nasDestination = "backup@nas.holthome.net";
  };
};
```

**What it backs up:**
- Binary cache data
- Cache metadata
- Option for efficient ZFS replication

**ZFS Send Method:**
- More efficient for large datasets
- Incremental sends to NAS
- Preserves ZFS features (compression, dedup)

### System Configuration Backup

```nix
modules.services.backup-services = {
  enable = true;

  system = {
    enable = true;
    paths = [
      "/etc/nixos"
      "/home/ryan/.config"
      "/var/log"
    ];
    excludePatterns = [
      "*.tmp"
      "*.cache"
      "*/.git"
      "*/node_modules"
    ];
  };
};
```

**What it backs up:**
- NixOS configuration
- System generations list
- Flake lock files
- User configurations
- System logs (with exclusions)

### Creating Custom Service Profiles

To add a new service profile, edit `/hosts/_modules/nixos/services/backup-services.nix`:

```nix
# Add to options section
myservice = {
  enable = mkEnableOption "MyService backup";

  dataPath = mkOption {
    type = types.str;
    default = "/var/lib/myservice";
    description = "Path to MyService data directory";
  };

  # Additional service-specific options
};

# Add to config section
(mkIf cfg.myservice.enable {
  myservice = {
    enable = true;
    paths = [ cfg.myservice.dataPath ];
    repository = "primary";
    tags = [ "myservice" "application" ];

    preBackupScript = ''
      # Service-specific preparation
      echo "Preparing MyService for backup..."
      # Example: Stop service, dump database, etc.
    '';

    postBackupScript = ''
      # Service-specific cleanup
      echo "Cleaning up MyService backup..."
      # Example: Restart service, remove temp files
    '';

    excludePatterns = [
      "*/logs/*"
      "*/temp/*"
    ];

    resources = {
      memory = "512m";
      cpus = "1.0";
    };
  };
})
```

## Configuration Reference

### Module Options

#### `modules.backup.enable`
- **Type**: `boolean`
- **Default**: `false`
- **Description**: Enable the comprehensive backup system

#### `modules.backup.zfs`
- **enable**: Enable ZFS snapshot integration
- **pool**: ZFS pool name (default: "rpool")
- **datasets**: List of datasets to snapshot
- **retention**: Snapshot retention policy

#### `modules.backup.restic`
- **enable**: Enable Restic backup
- **globalSettings**: Global Restic configuration
  - **compression**: "auto", "off", or "max"
  - **readConcurrency**: Number of concurrent read operations
  - **retention**: Backup retention policy
- **repositories**: Repository definitions
  - **url**: Repository URL
  - **passwordFile**: Path to password file
  - **environmentFile**: Path to environment file (optional)
  - **primary**: Is this the primary repository?
- **jobs**: Backup job definitions
  - **enable**: Enable this job
  - **paths**: List of paths to backup
  - **repository**: Repository name to use
  - **tags**: Backup tags
  - **excludePatterns**: Patterns to exclude
  - **preBackupScript**: Script to run before backup
  - **postBackupScript**: Script to run after backup
  - **resources**: Resource limits

#### `modules.backup.monitoring`
- **enable**: Enable monitoring and notifications
- **healthchecks**: Healthchecks.io integration
- **ntfy**: ntfy.sh notifications
- **onFailure**: Immediate failure notifications
- **prometheus**: Prometheus metrics export
- **errorAnalysis**: Intelligent error categorization
- **logDir**: Directory for structured logs

#### `modules.backup.verification`
- **enable**: Enable automated repository verification
- **schedule**: Verification schedule (daily/weekly/monthly)
- **checkData**: Full data integrity check
- **checkDataSubset**: Percentage of data to verify

#### `modules.backup.restoreTesting`
- **enable**: Enable automated restore testing
- **schedule**: Testing schedule
- **sampleFiles**: Number of files to test
- **testDir**: Directory for test restores
- **retainTestData**: Keep test data after validation

#### `modules.backup.validation`
- **enable**: Enable pre-flight validation
- **preFlightChecks**: Pre-backup checks
  - **enable**: Enable checks
  - **minFreeSpace**: Minimum free space required
  - **networkTimeout**: Network connectivity timeout
- **repositoryHealth**: Repository health monitoring
  - **enable**: Enable health monitoring
  - **maxAge**: Maximum backup age before alert
  - **minBackups**: Minimum backup count

#### `modules.backup.performance`
- **cacheDir**: Restic cache directory
- **cacheSizeLimit**: Maximum cache size
- **ioScheduling**: I/O scheduling optimization

#### `modules.backup.security`
- **enable**: Enable security hardening
- **restrictNetwork**: Restrict network access
- **readOnlyRootfs**: Read-only root filesystem
- **auditLogging**: Detailed audit logging

#### `modules.backup.documentation`
- **enable**: Enable documentation generation
- **outputDir**: Documentation output directory
- **includeMetrics**: Include metrics in docs

#### `modules.backup.schedule`
- **Type**: `string`
- **Default**: "02:00"
- **Description**: Backup time in 24-hour format

## Advanced Features

### Multi-Repository Strategy

Configure multiple repositories for redundancy:

```nix
modules.backup.restic.repositories = {
  # Primary: Fast local/NAS storage
  primary = {
    url = "/mnt/nas/backups/${config.networking.hostName}";
    passwordFile = config.sops.secrets.restic-primary-password.path;
    primary = true;
  };

  # Secondary: Off-site replication
  secondary = {
    url = "sftp:backup@remote.example.com:/backups/${config.networking.hostName}";
    passwordFile = config.sops.secrets.restic-secondary-password.path;
    primary = false;
  };

  # Tertiary: Cloud backup
  b2-cloud = {
    url = "b2:my-bucket:/${config.networking.hostName}";
    passwordFile = config.sops.secrets.restic-b2-password.path;
    environmentFile = config.sops.secrets.restic-b2-env.path;
    primary = false;
  };
};

# Configure jobs to use different repositories
modules.backup.restic.jobs = {
  # Critical data goes to all repositories
  critical-data = {
    enable = true;
    paths = [ "/var/lib/critical" ];
    repository = "primary";  # Will also be replicated to secondary/tertiary
    tags = [ "critical" ];
  };

  # Less critical data only to primary
  cache-data = {
    enable = true;
    paths = [ "/var/cache/apps" ];
    repository = "primary";
    tags = [ "cache" ];
  };
};
```

### Custom Error Categories

Customize error analysis rules:

```nix
modules.backup.monitoring.errorAnalysis = {
  enable = true;
  categoryRules = [
    {
      pattern = "(timeout|connection reset)";
      category = "network";
      severity = "high";
      actionable = true;
      retryable = true;
    }
    {
      pattern = "(disk full|out of space)";
      category = "storage";
      severity = "critical";
      actionable = true;
      retryable = false;
    }
    # Add custom rules specific to your environment
  ];
};
```

### Scheduled Maintenance Windows

Adjust backup timing to avoid peak usage:

```nix
modules.backup.schedule = "03:30";  # Run at 3:30 AM

# Individual job overrides
modules.backup.restic.jobs.large-dataset = {
  # ... other config ...
  # Note: Individual job scheduling requires modifying the timer
};
```

### Resource Management

Fine-tune resources for different backup jobs:

```nix
modules.backup.restic.jobs = {
  # Light backup job
  configs = {
    enable = true;
    paths = [ "/etc" ];
    repository = "primary";
    resources = {
      memory = "128m";
      memoryReservation = "64m";
      cpus = "0.25";
    };
  };

  # Heavy backup job
  databases = {
    enable = true;
    paths = [ "/var/lib/databases" ];
    repository = "primary";
    resources = {
      memory = "2g";
      memoryReservation = "1g";
      cpus = "2.0";
    };
  };
};
```

## Monitoring & Alerting

### Systemd Service Monitoring

```bash
# List all backup timers
systemctl list-timers "restic-*"

# Check specific backup job status
systemctl status restic-backups-system

# View real-time logs
journalctl -u restic-backups-* -f

# Check last run result
systemctl show -p ActiveEnterTimestamp restic-backups-system
systemctl show -p ActiveState restic-backups-system
```

### Structured Logs

All backup events are logged in JSON format:

```bash
# View backup job logs
tail -f /var/log/backup/backup-jobs.jsonl | jq

# View error analysis
tail -f /var/log/backup/error-analysis.jsonl | jq

# View restore test results
tail -f /var/log/backup/backup-restore-tests.jsonl | jq

# Query specific events
jq 'select(.event == "backup_failure")' /var/log/backup/*.jsonl
```

### Prometheus Metrics

Available metrics (when `prometheus.enable = true`):

```promql
# Backup job duration
restic_backup_duration_seconds{job="system"}

# Last successful backup timestamp
restic_backup_last_success_timestamp{job="system"}

# Backup status (1=success, 0=failure)
restic_backup_status{job="system"}

# Error counts by category
backup_errors_by_category_total{category="network"}

# Error counts by severity
backup_errors_by_severity_total{severity="critical"}

# Repository verification status
restic_verification_status{repository="primary"}

# Restore test results
restic_restore_test_status{repository="primary"}
```

### Alert Rules

Example Prometheus alert rules:

```yaml
groups:
  - name: backup.rules
    rules:
      - alert: BackupJobFailed
        expr: restic_backup_status == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Backup job {{ $labels.job }} failed on {{ $labels.hostname }}"

      - alert: BackupJobNotRunning
        expr: time() - restic_backup_last_success_timestamp > 86400
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Backup job {{ $labels.job }} hasn't run in 24+ hours"

      - alert: HighBackupErrorRate
        expr: increase(backup_errors_by_severity_total{severity="critical"}[1h]) > 5
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "High backup error rate on {{ $labels.hostname }}"

      - alert: RestoreTestFailed
        expr: restic_restore_test_status == 0
        for: 0m
        labels:
          severity: high
        annotations:
          summary: "Restore test failed for repository {{ $labels.repository }}"
```

### Notification Channels

#### ntfy.sh

Simple push notifications:

```nix
modules.backup.monitoring.ntfy = {
  enable = true;
  topic = "https://ntfy.sh/my-backups";
};
```

Receives notifications:
- On backup failure
- On verification failure
- On restore test failure

#### Healthchecks.io

Dead man's switch monitoring:

```nix
modules.backup.monitoring.healthchecks = {
  enable = true;
  uuidFile = config.sops.secrets.healthchecks-uuid.path;
};
```

Pings on:
- Backup success
- Backup failure
- Each check-in

## Troubleshooting

### Common Issues

#### Backup Job Fails with "Permission Denied"

**Symptoms**: Backup fails with permission errors

**Solutions**:
```bash
# Check backup user/group
id restic-backup

# Verify file permissions
ls -la /path/to/backup

# Check SELinux/AppArmor if enabled
getenforce  # or apparmor_status

# Fix: Ensure backup user has read access
sudo chown -R restic-backup:restic-backup /path/to/backup
```

#### "Repository Not Found" Error

**Symptoms**: Backup fails with repository initialization error

**Solutions**:
```bash
# Check repository URL is accessible
restic -r <repo-url> snapshots

# Verify password file exists
cat /path/to/password/file

# Initialize repository manually
restic -r <repo-url> init

# Check environment file for cloud repos
cat /path/to/env/file
```

#### ZFS Snapshot Mount Fails

**Symptoms**: Backup fails with ZFS-related errors

**Solutions**:
```bash
# Check ZFS pool status
zpool status

# List existing snapshots
zfs list -t snapshot

# Clean up stale snapshots
zfs list -t snapshot | grep backup- | awk '{print $1}' | xargs -n1 zfs destroy

# Verify mount point
ls -la /mnt/backup-snapshot
```

#### High Memory Usage

**Symptoms**: Backup process consuming excessive memory

**Solutions**:
```nix
# Reduce resources for the job
modules.backup.restic.jobs.problematic-job = {
  resources = {
    memory = "512m";  # Reduce from higher value
    memoryReservation = "256m";
    cpus = "1.0";
  };
};

# Reduce read concurrency
modules.backup.restic.globalSettings.readConcurrency = 1;

# Clear Restic cache
# rm -rf /var/cache/restic/*
```

#### Slow Backup Performance

**Symptoms**: Backups taking too long to complete

**Solutions**:
```nix
# Enable compression
modules.backup.restic.globalSettings.compression = "auto";

# Increase read concurrency
modules.backup.restic.globalSettings.readConcurrency = 4;

# Adjust I/O scheduling
modules.backup.performance.ioScheduling = {
  enable = true;
  ioClass = "best-effort";  # Instead of "idle"
  priority = 4;  # Higher priority
};

# Increase cache size
modules.backup.performance.cacheSizeLimit = "2G";
```

#### Repository Corruption

**Symptoms**: Repository check fails with errors

**Solutions**:
```bash
# Run repository check
restic -r <repo-url> check

# Attempt repair with rebuild-index
restic -r <repo-url> rebuild-index

# Full data check (slow)
restic -r <repo-url> check --read-data

# If irreparable, restore from secondary repository
```

### Debug Mode

Enable verbose logging for troubleshooting:

```bash
# Run backup manually with verbose output
sudo -u restic-backup restic -r <repo-url> backup /path --verbose

# Check systemd service logs with all details
journalctl -u restic-backups-system -b --no-pager

# Enable debug logging in Restic
export RESTIC_DEBUG=1
```

### Manual Recovery

#### Restore Single File

```bash
# List snapshots
restic -r <repo-url> snapshots

# Find file
restic -r <repo-url> find /path/to/file

# Restore from specific snapshot
restic -r <repo-url> restore <snapshot-id> \
  --target /tmp/restore \
  --include /path/to/file
```

#### Full System Restore

```bash
# 1. Boot from NixOS installation media

# 2. Configure network
systemctl start NetworkManager
nmtui

# 3. Mount target filesystem
mount /dev/sdX /mnt

# 4. Install Restic
nix-shell -p restic

# 5. Restore system
restic -r <repo-url> restore latest --target /mnt

# 6. Install bootloader
nixos-install --root /mnt

# 7. Reboot
reboot
```

## Best Practices

### NFS Mount Configuration

#### Backup Storage (Occasional Access)

For backup destinations that need occasional access, use systemd automount with idle timeout:

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

**Benefits:**

- Won't block boot if NAS is down
- Automatically unmounts after idle period (security + resource efficiency)
- Auto-mounts on first access (transparent to services)
- Available system-wide for any service that needs it

#### Media Library (Continuous Access)

For shared media libraries accessed by multiple services (Plex, Sonarr, Radarr, SABnzbd, etc.), use a single shared mount point:

```nix
fileSystems."/mnt/media" = {
  device = "nas-1.holthome.net:/mnt/media";
  fsType = "nfs";
  options = [
    "nfsvers=4.2"
    "rw"
    "noatime"
    "x-systemd.automount"  # Optional but recommended for resilience
    "noauto"               # Required with automount
  ];
};
```

**Best Practices for Shared Media:**

- **Single mount point**: All services reference the same path (e.g., `/mnt/media`)
- **Shared group**: Create a `media` group and add all service users to it
- **Consistent permissions**: Ensure NFS export and local permissions align (UID/GID mapping)
- **Do not create separate mounts per service**: This adds complexity and can cause file sync issues

**Example user/group configuration:**

```nix
users.groups.media = { gid = 1500; };  # Match GID across NAS and clients

users.users = {
  plex.extraGroups = [ "media" ];
  sonarr.extraGroups = [ "media" ];
  radarr.extraGroups = [ "media" ];
  sabnzbd.extraGroups = [ "media" ];
};
```

### Security

1. **Encrypt Repository Passwords**: Always use SOPS or similar for password management
2. **Rotate Credentials**: Periodically rotate repository passwords
3. **Least Privilege**: Run backups with minimal required permissions
4. **Audit Logs**: Enable audit logging for compliance
5. **Network Isolation**: Restrict backup process network access

### Reliability

1. **Test Restores**: Enable automated restore testing
2. **Multiple Repositories**: Use at least two repositories (local + off-site)
3. **Monitor Actively**: Configure alerts for failures
4. **Verify Regularly**: Enable weekly repository verification
5. **Document Procedures**: Keep runbooks updated

### Performance

1. **Schedule Wisely**: Run backups during low-activity periods
2. **Resource Limits**: Prevent backup impact on production services
3. **Compression**: Enable auto compression for better efficiency
4. **Prune Regularly**: Configure retention policies appropriately
5. **Use ZFS Snapshots**: Ensure consistent backups

### Data Management

1. **Exclude Patterns**: Don't backup cache, logs, temp files
2. **Tag Appropriately**: Use tags for easy snapshot identification
3. **Retention Policy**: Balance storage costs with recovery needs
4. **Pre/Post Scripts**: Handle application-specific requirements
5. **Incremental Backups**: Leverage Restic's deduplication

### Operational

1. **Monitor Trends**: Track backup size and duration over time
2. **Capacity Planning**: Monitor repository storage growth
3. **Error Analysis**: Review error categories weekly
4. **Update Documentation**: Keep generated docs current
5. **Test Disaster Recovery**: Practice full system restores

## Example Configurations

### Complete Production Host

```nix
{ config, lib, pkgs, ... }:
{
  # Enable backup system
  modules.backup = {
    enable = true;

    # ZFS integration
    zfs = {
      enable = true;
      pool = "rpool";
      datasets = [ "" "home" "var/lib" ];
      retention = {
        daily = 7;
        weekly = 4;
        monthly = 3;
      };
    };

    # Restic configuration
    restic = {
      enable = true;

      globalSettings = {
        compression = "auto";
        readConcurrency = 2;
        retention = {
          daily = 14;
          weekly = 8;
          monthly = 6;
          yearly = 2;
        };
      };

      # Multiple repositories
      repositories = {
        primary = {
          url = "/mnt/nas/backups/${config.networking.hostName}";
          passwordFile = config.sops.secrets.restic-primary-password.path;
          primary = true;
        };
        b2-cloud = {
          url = "b2:homelab-backups:/${config.networking.hostName}";
          passwordFile = config.sops.secrets.restic-b2-password.path;
          environmentFile = config.sops.secrets.restic-b2-env.path;
          primary = false;
        };
      };

      # Backup jobs
      jobs = {
        system = {
          enable = true;
          paths = [ "/etc/nixos" "/etc/systemd" ];
          repository = "primary";
          tags = [ "system" "configuration" ];
        };
        home = {
          enable = true;
          paths = [ "/home" ];
          repository = "primary";
          tags = [ "user-data" ];
          excludePatterns = [
            "*/.cache"
            "*/Downloads"
            "*/node_modules"
          ];
        };
      };
    };

    # Comprehensive monitoring
    monitoring = {
      enable = true;

      ntfy = {
        enable = true;
        topic = "https://ntfy.sh/homelab-backups";
      };

      healthchecks = {
        enable = true;
        uuidFile = config.sops.secrets.healthchecks-uuid.path;
      };

      onFailure = {
        enable = true;
      };

      prometheus = {
        enable = true;
      };

      errorAnalysis = {
        enable = true;
      };
    };

    # Automated verification
    verification = {
      enable = true;
      schedule = "weekly";
      checkDataSubset = "5%";
    };

    # Restore testing
    restoreTesting = {
      enable = true;
      schedule = "monthly";
      sampleFiles = 10;
    };

    # Validation
    validation = {
      enable = true;
      preFlightChecks = {
        enable = true;
        minFreeSpace = "10G";
      };
      repositoryHealth = {
        enable = true;
        maxAge = "48h";
        minBackups = 3;
      };
    };

    # Performance
    performance = {
      ioScheduling = {
        enable = true;
        ioClass = "idle";
        priority = 7;
      };
    };

    # Security
    security = {
      enable = true;
      restrictNetwork = true;
      auditLogging = true;
    };

    # Documentation
    documentation = {
      enable = true;
      includeMetrics = true;
    };

    schedule = "02:30";
  };

  # Enable service backups
  modules.services.backup-services = {
    enable = true;

    # Add service-specific backups as needed
    system.enable = true;
  };
}
```

### Minimal Laptop Configuration

```nix
{ config, lib, pkgs, ... }:
{
  modules.backup = {
    enable = true;

    restic = {
      enable = true;

      repositories.laptop-backup = {
        url = "b2:my-laptop-backups:/";
        passwordFile = config.sops.secrets.restic-password.path;
        environmentFile = config.sops.secrets.restic-b2-env.path;
        primary = true;
      };

      jobs.laptop-data = {
        enable = true;
        paths = [
          "/home/user/Documents"
          "/home/user/Pictures"
        ];
        repository = "laptop-backup";
        excludePatterns = [
          "*/.cache"
          "*/Downloads"
        ];
        resources = {
          memory = "256m";
          cpus = "1.0";
        };
      };
    };

    monitoring = {
      enable = true;
      ntfy = {
        enable = true;
        topic = "https://ntfy.sh/my-laptop";
      };
    };

    schedule = "22:00";  # Evening backup
  };
}
```

## Conclusion

The NixOS backup system provides enterprise-grade backup capabilities with:

- Encrypted, deduplicated backups via Restic
- ZFS snapshot integration for consistency
- Pre-configured service profiles
- Comprehensive monitoring and alerting
- Automated verification and testing
- Self-documenting system

For additional help:

- Review generated documentation in `/var/lib/backup/docs/`
- Check structured logs in `/var/log/backup/`
- Consult Prometheus metrics for system health
- Review backup module source: `/hosts/_modules/nixos/backup.nix`
