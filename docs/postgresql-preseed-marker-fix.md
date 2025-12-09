# PostgreSQL Disaster Recovery Flow - Root Cause Analysis & Fix

## Issue Summary

The disaster recovery test failed because the `.preseed-completed` marker file persisted after PGDATA deletion, preventing the preseed service from running and causing PostgreSQL to create a fresh database instead of restoring from backup.

## Root Cause: ZFS Dataset Layering

### The Problem

Two conflicting dataset configurations created overlapping ZFS datasets at the same mountpoint:

1. **hosts/forge/default.nix** (line 320): `tank/services/postgres` (old name)
2. **PostgreSQL module storage-integration.nix**: `tank/services/postgresql` (new name)

Both datasets mounted at `/var/lib/postgresql/16/`, creating a **layered filesystem**:

```bash
$ zfs list | grep postgres
tank/services/postgres       96K   797G    96K  /var/lib/postgresql/16
tank/services/postgresql   23.8M   797G  23.8M  /var/lib/postgresql/16
```

### What Happened During DR Test

1. **14:03** - Preseed service ran, found initialized PGDATA from nixos-bootstrap
2. **14:03** - Created `.preseed-completed` marker in PGDATA
3. **14:17** - Attempted to delete PGDATA with `rm -rf /var/lib/postgresql/16/*`
4. **14:17** - Command only deleted files on **top dataset** (`postgresql`)
5. **14:25** - Restarted services to test DR
6. **14:25:34** - Preseed condition check: marker EXISTS on **bottom dataset** (`postgres`)
7. **14:25:34** - Preseed service **SKIPPED** (condition not met)
8. **14:25:35** - PostgreSQL's initdb ran → fresh database created ❌

The marker file survived because it was on the hidden bottom dataset that wasn't affected by the deletion command.

## Solutions Applied

### Fix 1: Remove Duplicate Dataset Configuration

**File**: `hosts/forge/default.nix`

Removed the `postgres` dataset declaration from forge-specific config. The PostgreSQL module's `storage-integration.nix` is now the single source of truth.

**Before**:
```nix
services = {
  postgres = {
    recordsize = "8K";
    mountpoint = "/var/lib/postgresql/16";
    properties = { ... };
  };
}
```

**After**:
```nix
services = {
  # PostgreSQL dataset is now managed by the PostgreSQL module's storage-integration.nix
  # to avoid duplicate dataset creation and configuration conflicts.
  # See: modules/nixos/services/postgresql/storage-integration.nix
}
```

### Fix 2: Merge Advanced ZFS Properties

**File**: `modules/nixos/services/postgresql/storage-integration.nix`

Added the advanced ZFS properties from forge's config to the module:

```nix
"postgresql" = {
  properties = {
    "com.sun:auto-snapshot" = "false";
    logbias = "throughput";
    primarycache = "metadata";
    redundant_metadata = "most";
    sync = "standard";
    # ... other properties
  };
};
```

### Fix 3: Move Marker File Outside PGDATA

**File**: `modules/nixos/postgresql-preseed.nix`

Changed marker location from **inside** PGDATA to **parent directory**:

**Before**: `/var/lib/postgresql/16/.preseed-completed` (inside PGDATA)
**After**: `/var/lib/postgresql/.preseed-completed-16` (parent directory)

This prevents the marker from being caught in dataset layering issues.

**Changes**:
- Added `markerFile` variable: `/var/lib/postgresql/.preseed-completed-${version}`
- Updated all marker creation calls to use new path
- Updated systemd condition to check new path

## Deployment Plan

### Step 1: Clean Up Existing Datasets (On Forge)

```bash
# SSH to forge
ssh ryan@forge.holthome.net

# Stop PostgreSQL
sudo systemctl stop postgresql

# Check current datasets
zfs list | grep postgres

# Unmount both datasets
sudo zfs umount tank/services/postgresql
sudo zfs umount tank/services/postgres

# Destroy the old duplicate dataset (96K, nearly empty)
sudo zfs destroy tank/services/postgres

# Remount the correct dataset
sudo zfs mount tank/services/postgresql
sudo zfs set mountpoint=/var/lib/postgresql/16 tank/services/postgresql

# Remove old marker if it exists
sudo rm -f /var/lib/postgresql/16/.preseed-completed
sudo rm -f /var/lib/postgresql/.preseed-completed-16
```

### Step 2: Deploy Configuration

```bash
# On local machine
cd ~/src/nix-config

# Review changes
git diff

# Commit the fixes
git add hosts/forge/default.nix \
        modules/nixos/services/postgresql/storage-integration.nix \
        modules/nixos/postgresql-preseed.nix

git commit -m "fix(forge): resolve PostgreSQL dataset layering and preseed marker issues

- Remove duplicate postgres dataset config from forge/default.nix
- Consolidate dataset management in storage-integration.nix
- Move preseed marker outside PGDATA to parent directory
- Prevents marker from being hidden by ZFS dataset layering

Fixes disaster recovery flow where marker persisted across
PGDATA deletion, preventing automatic restore."

# Build and deploy
nix flake check
nixos-rebuild switch --flake .#forge --target-host ryan@forge.holthome.net
```

### Step 3: Test Disaster Recovery Flow

Once you have backups again (after Step 4), test the DR flow:

```bash
# SSH to forge
ssh ryan@forge.holthome.net

# Stop PostgreSQL
sudo systemctl stop postgresql

# Verify backup exists
sudo -u postgres pgbackrest --stanza=main info

# Delete PGDATA completely
sudo rm -rf /var/lib/postgresql/16/*

# Delete marker (if exists)
sudo rm -f /var/lib/postgresql/.preseed-completed-16

# Start services - preseed should automatically restore
sudo systemctl start postgresql-preseed
sudo systemctl status postgresql-preseed

# Check if restore succeeded
sudo -u postgres psql -l
sudo -u postgres psql -d dispatcharr -c "\dt"

# Verify it's the restored database (not fresh)
sudo -u postgres psql -d dispatcharr -c "SELECT COUNT(*) FROM channels;"  # Should have data
```

### Step 4: Take New Backups

After deployment and verification:

```bash
# Start a full backup
sudo systemctl start pgbackrest-full-backup.service
sudo systemctl status pgbackrest-full-backup.service

# Verify backup completed
sudo -u postgres pgbackrest --stanza=main info

# Check archive status
sudo -u postgres pgbackrest --stanza=main --repo=1 repo-ls archive/main/16-1
```

## Verification Checklist

After deployment:

- [ ] Only one `tank/services/postgresql` dataset exists
- [ ] Dataset mounted at `/var/lib/postgresql/16/`
- [ ] No `tank/services/postgres` dataset exists
- [ ] Marker file location is `/var/lib/postgresql/.preseed-completed-16`
- [ ] Preseed service has correct `ConditionPathExists` path
- [ ] New full backup created successfully
- [ ] DR test: Delete PGDATA + marker → restore works → PostgreSQL starts with restored data

## Manual Marker Management (When Needed)

The preseed service automatically creates the marker when:
1. It finds an already-initialized PGDATA (skips restore)
2. It successfully completes a restore

To force a restore (disaster recovery scenario):

```bash
# 1. Stop PostgreSQL
sudo systemctl stop postgresql

# 2. Delete PGDATA
sudo rm -rf /var/lib/postgresql/16/*

# 3. Delete marker (CRITICAL!)
sudo rm -f /var/lib/postgresql/.preseed-completed-16

# 4. Start services (preseed will run automatically)
sudo systemctl start postgresql

# Preseed service will:
# - Check marker doesn't exist ✓
# - Find empty PGDATA ✓
# - Restore from latest backup ✓
# - Create marker after success ✓
# - PostgreSQL starts with restored data ✓
```

## Monitoring and Logging

Check preseed status:

```bash
# Service status
systemctl status postgresql-preseed

# Full logs
sudo journalctl -u postgresql-preseed --no-pager

# Check if marker exists
ls -la /var/lib/postgresql/.preseed-completed-16

# Check PostgreSQL data timestamp
sudo ls -lt /var/lib/postgresql/16/ | head
```

## Technical Notes

### Why Move Marker Outside PGDATA?

When the marker is inside PGDATA (`/var/lib/postgresql/16/.preseed-completed`):
- It's subject to ZFS dataset mount layering
- Can persist on hidden bottom dataset layers
- Survives `rm -rf /var/lib/postgresql/16/*` deletion
- Breaks DR flow by preventing preseed execution

When the marker is in parent directory (`/var/lib/postgresql/.preseed-completed-16`):
- Outside any PGDATA-specific dataset
- Always on the same filesystem layer
- Reliable deletion with `rm -f`
- DR flow works correctly

### Dataset Naming Convention

Going forward, use the PostgreSQL module's storage-integration for dataset management:
- **Dataset name**: `postgresql` (not `postgres`)
- **Management**: Automatic via `storage-integration.nix`
- **Properties**: Defined in module, inherited by all hosts
- **Host overrides**: Use module options, not direct dataset config

## Future Improvements

Consider these enhancements:

1. **Pre-flight checks**: Add service that verifies only one PostgreSQL dataset exists
2. **Marker validation**: Script to check marker file location matches systemd condition
3. **DR documentation**: Update `docs/postgresql-auto-restore-homelab.md` with marker details
4. **Automated testing**: Include DR scenario in NixOS tests

## References

- Preseed module: `modules/nixos/postgresql-preseed.nix`
- Storage integration: `modules/nixos/services/postgresql/storage-integration.nix`
- Forge config: `hosts/forge/default.nix`
- ZFS dataset module: `modules/nixos/storage/datasets.nix`
