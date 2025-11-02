# pgBackRest Unified Configuration Refactoring

**Date:** November 1, 2025
**Status:** Implemented
**Related Issue:** Archive configuration duplication and semantic ambiguity

## Overview

Refactored from a split-config architecture to a single unified pgBackRest configuration file, eliminating duplication and improving maintainability.

## Problem Statement

The previous architecture used two separate configuration files:
- `/etc/pgbackrest.conf` - Runtime config with repo1 only + archive settings
- `/etc/pgbackrest-init.conf` - Init config with both repo1 and repo2

This caused:
1. **Configuration duplication**: Archive settings (`archive-async`, `spool-path`) existed in both files
2. **Semantic confusion**: Init config defined repo2 (R2/S3) but archive settings only applied to repo1
3. **Maintenance burden**: Changes to archiving had to be synchronized across both files

## Solution

### Single Unified Configuration

Now using **one** configuration file (`/etc/pgbackrest.conf`) that defines both repositories:

```ini
[global]
# Repo1 (NFS) - Primary for WAL archiving and local backups
repo1-path=/mnt/nas-postgresql/pgbackrest
repo1-retention-full=7

# Repo2 (R2/S3) - Offsite DR, backup-only
repo2-type=s3
repo2-path=/forge-pgbackrest
repo2-s3-bucket=nix-homelab-prod-servers
repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com
repo2-s3-region=auto
repo2-s3-uri-style=path
repo2-retention-full=30

# Global archive settings (apply only where archive_command is used)
archive-async=y
spool-path=/var/lib/pgbackrest/spool

# Other global settings
process-max=2
log-level-console=info
log-level-file=detail
start-fast=y
delta=y
compress-type=lz4
compress-level=3

[main]
pg1-path=/var/lib/postgresql/16
pg1-port=5432
pg1-user=postgres
```

### Explicit Repository Targeting

**archive_command** now explicitly targets repo1:
```nix
archive_command = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=main --repo=1 archive-push %p";
```

This makes it unambiguous that WAL archiving only applies to repo1 (NFS), not repo2 (R2).

## Changes Made

### 1. Configuration Files
- ✅ Removed `/etc/pgbackrest-init.conf` entirely
- ✅ Updated `/etc/pgbackrest.conf` to include both repo1 and repo2 definitions
- ✅ Removed archive configuration duplication

### 2. PostgreSQL Configuration
**File:** `hosts/forge/postgresql.nix`
- ✅ Updated `archive_command` to explicitly use `--repo=1` flag
- ✅ Updated comments to reflect explicit repository targeting

### 3. Systemd Services
**File:** `hosts/forge/default.nix`

#### pgbackrest-stanza-create
- ✅ Removed `--config=/etc/pgbackrest-init.conf` flags
- ✅ Moved credential transformation to top of script (applies to both create and upgrade)
- ✅ Simplified stanza-create and stanza-upgrade commands

#### pgbackrest-post-preseed
- ✅ Removed hardcoded `--repo2-*` command-line flags
- ✅ Now reads repo2 configuration from unified config file
- ✅ Simplified to: `pgbackrest --stanza=main --type=full --repo=2 --no-archive-check backup`

#### pgbackrest-full-backup
- ✅ Removed redundant `--repo2-*` flags and retention settings
- ✅ Simplified to: `pgbackrest --stanza=main --type=full --repo=2 --no-archive-check backup`

#### pgbackrest-incr-backup
- ✅ Removed redundant `--repo2-*` flags and retention settings
- ✅ Simplified to: `pgbackrest --stanza=main --type=incr --repo=2 --no-archive-check backup`

## Benefits

1. **Single Source of Truth**: All pgBackRest configuration in one place
2. **Reduced Maintenance**: No need to sync changes across multiple config files
3. **Clear Intent**: Explicit `--repo=1` in archive_command clarifies WAL archiving targets
4. **Simplified Services**: Removed redundant command-line flags from all backup services
5. **Better Architecture**: Eliminates semantic confusion about which repo has archiving

## Architecture Validation

This refactoring was recommended by Gemini Pro 2.5 during a critical code review challenge. The expert analysis validated:
- ✅ Correct diagnosis of the original problem
- ✅ Appropriate architectural solution
- ✅ Maintains robust dual-repository backup strategy
- ✅ Improves long-term maintainability

## Operational Notes

### WAL Archiving
- **Repo1 (NFS)**: Receives continuous WAL archiving via `archive_command`
- **Repo2 (R2/S3)**: Backup-only repository, no WAL archiving (cost optimization)

### Credentials
Repo2 S3 credentials are supplied via environment variables in services:
```bash
export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"
```

This keeps sensitive credentials out of the configuration file while maintaining Nix declarative approach via SOPS secrets.

### Recovery Scenarios
Both disaster recovery paths now use the unified configuration:
1. **Fresh install**: `stanza-create` reads both repos from single config
2. **Database rebuild**: `stanza-upgrade` reads both repos from single config

## Testing Checklist

Before deploying to production, verify:
- [ ] pgbackrest-stanza-create.service succeeds
- [ ] WAL archiving to repo1 works (check `/mnt/nas-postgresql/pgbackrest/archive/`)
- [ ] Full backup to repo1 succeeds
- [ ] Full backup to repo2 succeeds
- [ ] Incremental backup to repo1 succeeds
- [ ] Incremental backup to repo2 succeeds
- [ ] Post-preseed backup to both repos succeeds
- [ ] `pgbackrest info` shows both repositories with current backups

## Related Documentation

- [PostgreSQL Preseed System](./postgresql-preseed-marker-fix.md)
- [Backup System Design](./unified-backup-design-patterns.md)
- [pgBackRest Configuration Guide](https://pgbackrest.org/configuration.html)
