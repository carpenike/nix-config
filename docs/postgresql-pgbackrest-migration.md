# PostgreSQL Backup Migration: pg-backup-scripts → pgBackRest

## Overview

This document covers the migration from custom `pg-backup-scripts` to industry-standard `pgBackRest` for PostgreSQL backups on the forge server.

**Migration Date**: 2024-01
**Status**: ✅ Complete

## What Changed

### Removed Components
- ❌ `pkgs/pg-backup-scripts.nix` (161 lines of custom backup scripts)
- ❌ `systemd.services.pg-zfs-snapshot` (coordinated PostgreSQL + ZFS snapshots)
- ❌ `systemd.services.pg-check-stale-backup-label` (backup_label verification)
- ❌ `modules/nixos/services/postgresql/backup-integration.nix` (Restic integration module)
- ❌ `modules.backup.restic.jobs.postgresql-offsite` (complex snapshot mounting/unmounting logic)

### Added Components
- ✅ `pkgs.pgbackrest` (industry-standard PostgreSQL backup tool)
- ✅ `/etc/pgbackrest.conf` (45-line configuration file)
- ✅ `systemd.services.pgbackrest-stanza-create` (one-time initialization)
- ✅ `systemd.services.pgbackrest-full-backup` (daily full backups)
- ✅ `systemd.services.pgbackrest-incr-backup` (hourly incremental backups)
- ✅ `systemd.services.pgbackrest-diff-backup` (6-hourly differential backups)
- ✅ `systemd.timers.pgbackrest-*` (three timers with randomized delays)
- ✅ `systemd.services.pgbackrest-metrics` (Prometheus monitoring)
- ✅ PostgreSQL `archive_command` using pgBackRest

### Simplified Components
- ✨ Sanoid configuration: Removed `autosnap = false`, now uses standard `wal-frequent` template
- ✨ ZFS datasets: No longer require custom snapshot coordination

## Architecture

### Old System (pg-backup-scripts)
```
PostgreSQL → pg_start_backup()
          → ZFS snapshot (coordinated)
          → pg_stop_backup()
          → Mount snapshot read-only
          → Restic backup from snapshot
          → Unmount snapshot
          → Upload to R2
```

### New System (pgBackRest)
```
PostgreSQL → WAL archiving (continuous via archive_command)
          ↓
          → pgBackRest stanza "main"
             ├─ repo1: /mnt/nas-backup/pgbackrest (local NAS)
             ├─ repo2: s3://R2/nix-homelab-prod-servers (offsite)
             ├─ Full backup: Daily 2 AM
             ├─ Incremental backup: Hourly
             └─ Differential backup: Every 6 hours
```

## Configuration

### pgBackRest Config (`/etc/pgbackrest.conf`)

```ini
[global]
repo1-path=/mnt/nas-backup/pgbackrest
repo1-retention-full=7
repo1-retention-diff=4

repo2-type=s3
repo2-s3-bucket=nix-homelab-prod-servers
repo2-s3-region=auto
repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com
repo2-s3-key-type=shared
repo2-path=/forge/pgbackrest
repo2-retention-full=30
repo2-retention-diff=14

process-max=2
compress-type=lz4
compress-level=3
delta=y

[main]
pg1-path=/var/lib/postgresql/16/main
pg1-port=5432
```

### PostgreSQL Settings

```nix
services.postgresql.settings = {
  archive_mode = "on";
  archive_command = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=main archive-push %p";
  archive_timeout = "300";  # 5-minute RPO
};
```

### Backup Schedules

| Backup Type | Schedule | Retention (Local) | Retention (R2) |
|-------------|----------|-------------------|----------------|
| **Full** | Daily @ 2 AM | 7 backups | 30 backups |
| **Incremental** | Hourly | N/A (depends on full) | N/A |
| **Differential** | Every 6 hours | 4 backups | 14 backups |

## Operations Guide

### Check Backup Status

```bash
# View all backups
sudo pgbackrest --stanza=main info

# View detailed JSON output
sudo pgbackrest --stanza=main --output=json info

# Check specific repository
sudo pgbackrest --stanza=main --repo=1 info  # Local NAS
sudo pgbackrest --stanza=main --repo=2 info  # R2 offsite
```

### Manual Backup Operations

```bash
# Trigger full backup (both repos)
sudo systemctl start pgbackrest-full-backup.service

# Trigger incremental backup
sudo systemctl start pgbackrest-incr-backup.service

# Trigger differential backup
sudo systemctl start pgbackrest-diff-backup.service

# Manual backup to specific repo
sudo pgbackrest --stanza=main --repo=1 --type=full backup
```

### Monitor Backup Jobs

```bash
# Check service status
systemctl status pgbackrest-full-backup.timer
systemctl status pgbackrest-incr-backup.timer
systemctl status pgbackrest-diff-backup.timer

# View recent backup logs
journalctl -u pgbackrest-full-backup.service -n 50
journalctl -u pgbackrest-incr-backup.service -n 50
journalctl -u pgbackrest-diff-backup.service -n 50

# Check Prometheus metrics
cat /var/lib/node_exporter/textfile_collector/pgbackrest.prom
```

## Disaster Recovery

### Scenario 1: Restore from Local Backup (Fastest)

**Recovery Time Objective (RTO)**: ~10-30 minutes

```bash
# 1. Stop PostgreSQL
sudo systemctl stop postgresql

# 2. Backup current state (safety)
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.old

# 3. Restore latest backup from local NAS
sudo pgbackrest --stanza=main --repo=1 restore

# 4. Start PostgreSQL (auto-recovers to latest WAL)
sudo systemctl start postgresql

# 5. Verify database
sudo -u postgres psql -c "SELECT now();"
```

### Scenario 2: Point-in-Time Recovery (PITR)

**Use Case**: Recover to specific timestamp (e.g., before accidental DELETE)

```bash
# 1. Stop PostgreSQL
sudo systemctl stop postgresql

# 2. Backup current state
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.old

# 3. Restore base backup
sudo pgbackrest --stanza=main --repo=1 restore

# 4. Create recovery.signal
sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal

# 5. Configure recovery target in postgresql.conf
cat >> /var/lib/postgresql/16/main/postgresql.auto.conf <<EOF
restore_command = 'pgbackrest --stanza=main archive-get %f "%p"'
recovery_target_time = '2024-01-15 14:30:00+00'
recovery_target_action = 'promote'
EOF

# 6. Start PostgreSQL and monitor recovery
sudo systemctl start postgresql
sudo journalctl -u postgresql -f

# 7. Verify recovered data
sudo -u postgres psql -c "SELECT * FROM my_table WHERE id = 123;"

# 8. Clean up recovery config
sudo -u postgres psql -c "ALTER SYSTEM RESET restore_command;"
sudo systemctl restart postgresql
```

### Scenario 3: Restore from R2 Offsite (Disaster Recovery)

**Use Case**: Complete NAS failure, restore from cloud

```bash
# 1. Ensure R2 credentials are available
cat /run/secrets/restic/r2-prod-env

# 2. Stop PostgreSQL
sudo systemctl stop postgresql

# 3. Backup current state
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.old

# 4. Restore from R2 (repo2)
sudo pgbackrest --stanza=main --repo=2 restore

# 5. Start PostgreSQL
sudo systemctl start postgresql

# 6. Verify
sudo -u postgres psql -c "SELECT now();"
```

### Scenario 4: Restore Specific Backup Set

```bash
# 1. List available backup sets
sudo pgbackrest --stanza=main info

# Output example:
# stanza: main
#     status: ok
#     cipher: none
#
#     db (current)
#         wal archive min/max (16): 00000001000000000000000A/00000001000000000000001F
#
#         full backup: 20240115-020015F
#             timestamp start/stop: 2024-01-15 02:00:15+00 / 2024-01-15 02:05:23+00
#             wal start/stop: 00000001000000000000000A / 00000001000000000000000C
#             database size: 1.2GB, database backup size: 1.2GB
#             repo1: backup set size: 456MB, backup size: 456MB

# 2. Restore specific backup set
sudo systemctl stop postgresql
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.old
sudo pgbackrest --stanza=main --repo=1 --set=20240115-020015F restore
sudo systemctl start postgresql
```

## Monitoring

### Prometheus Metrics

Metrics exported to `/var/lib/node_exporter/textfile_collector/pgbackrest.prom`:

```prometheus
# Backup timestamps (Unix epoch)
pgbackrest_last_full_backup_timestamp{stanza="main",repo="repo1",hostname="forge"}
pgbackrest_last_incr_backup_timestamp{stanza="main",repo="repo1",hostname="forge"}
pgbackrest_last_diff_backup_timestamp{stanza="main",repo="repo1",hostname="forge"}

# Backup counts
pgbackrest_backup_count{stanza="main",repo="repo1",hostname="forge"}

# Repository sizes (bytes)
pgbackrest_repo_size_bytes{stanza="main",repo="repo1",hostname="forge"}
pgbackrest_repo_backup_size_bytes{stanza="main",repo="repo1",hostname="forge"}
```

### Alerting Rules

Create Prometheus alerts for:

```yaml
# Alert if no full backup in 25 hours
- alert: PostgreSQLBackupStale
  expr: time() - pgbackrest_last_full_backup_timestamp > 90000
  labels:
    severity: warning
  annotations:
    summary: "PostgreSQL full backup is stale (>25 hours)"

# Alert if no incremental backup in 2 hours
- alert: PostgreSQLIncrementalBackupStale
  expr: time() - pgbackrest_last_incr_backup_timestamp > 7200
  labels:
    severity: warning
  annotations:
    summary: "PostgreSQL incremental backup is stale (>2 hours)"

# Alert if backup repository size is concerning
- alert: PostgreSQLBackupRepoLarge
  expr: pgbackrest_repo_size_bytes > 100e9  # 100GB
  labels:
    severity: info
  annotations:
    summary: "PostgreSQL backup repository exceeds 100GB"
```

## ZFS Snapshots Integration

### Role of ZFS Snapshots

With pgBackRest handling backups, ZFS snapshots now serve a complementary role:

- **Fast Local Rollback**: Restore in <1 minute vs 10-30 minutes for pgBackRest
- **Quick Recovery from Recent Issues**: Roll back 5-60 minutes without WAL replay
- **Not PITR-Compliant**: Snapshots are crash-consistent, not application-consistent
- **Use Case**: "Oh no, I just dropped that table 2 minutes ago!"

### Sanoid Configuration

```nix
services.sanoid.datasets."tank/services/postgresql/main" = {
  use_template = [ "prod" ];
  recursive = false;
};

services.sanoid.datasets."tank/services/postgresql/main-wal" = {
  use_template = [ "wal-frequent" ];  # 12x5min, 48h hourly, 7d daily
  recursive = false;
};
```

### Quick ZFS Rollback

```bash
# 1. Stop PostgreSQL
sudo systemctl stop postgresql

# 2. List recent snapshots
sudo zfs list -t snapshot tank/services/postgresql/main | tail -n 5

# 3. Rollback to snapshot (DESTROYS NEWER SNAPSHOTS!)
sudo zfs rollback -r tank/services/postgresql/main@autosnap_2024-01-15_14:30:00_hourly

# 4. Start PostgreSQL
sudo systemctl start postgresql

# 5. Verify
sudo -u postgres psql -c "SELECT now();"
```

⚠️ **Warning**: `zfs rollback` destroys all snapshots newer than the target. For point-in-time recovery to arbitrary timestamps, use pgBackRest PITR instead.

## Troubleshooting

### Issue: WAL Archiving Failures

**Symptoms**:
```
journalctl -u postgresql | grep "archive command failed"
```

**Diagnosis**:
```bash
# Check pgbackrest can access repositories
sudo -u postgres pgbackrest --stanza=main check

# Manually test archive command
sudo -u postgres pgbackrest --stanza=main archive-push /var/lib/postgresql/16/main/pg_wal/000000010000000000000001
```

**Solutions**:
- Ensure `/mnt/nas-backup` is mounted
- Verify R2 credentials at `/run/secrets/restic/r2-prod-env`
- Check disk space: `df -h /mnt/nas-backup`

### Issue: Backup Job Failures

**Symptoms**:
```
systemctl status pgbackrest-full-backup.service
# Output: "failed"
```

**Diagnosis**:
```bash
# View detailed logs
journalctl -u pgbackrest-full-backup.service -n 100

# Check stanza status
sudo pgbackrest --stanza=main check
```

**Common Causes**:
1. **Stanza not created**: Run `sudo systemctl start pgbackrest-stanza-create.service`
2. **Repository permissions**: Check ownership of `/mnt/nas-backup/pgbackrest`
3. **R2 credentials**: Verify SOPS secret is decrypted
4. **PostgreSQL not running**: `systemctl status postgresql`

### Issue: Slow Restore Performance

**Symptoms**: Restore taking >1 hour for small databases

**Optimizations**:
```bash
# Use more processes for restore
sudo pgbackrest --stanza=main --repo=1 --process-max=4 restore

# Use delta restore (only changed blocks)
sudo pgbackrest --stanza=main --repo=1 --delta restore

# Restore from local repo (faster than R2)
sudo pgbackrest --stanza=main --repo=1 restore
```

### Issue: Metrics Not Updating

**Symptoms**: Prometheus metrics stale or missing

**Diagnosis**:
```bash
# Check metrics service
systemctl status pgbackrest-metrics.service
systemctl status pgbackrest-metrics.timer

# View metrics file
cat /var/lib/node_exporter/textfile_collector/pgbackrest.prom

# Check for errors
journalctl -u pgbackrest-metrics.service -n 50
```

**Solutions**:
- Ensure node_exporter textfile collector is enabled
- Verify directory permissions: `ls -ld /var/lib/node_exporter/textfile_collector/`
- Manually trigger metrics collection: `sudo systemctl start pgbackrest-metrics.service`

## Performance Tuning

### Backup Performance

```nix
# In /etc/pgbackrest.conf
process-max=4           # More parallel processes (default: 1)
compress-level=1        # Faster compression (default: 3)
protocol-timeout=1200   # Longer timeout for slow networks
```

### Restore Performance

```bash
# Fast restore with parallel processes
sudo pgbackrest --stanza=main --repo=1 --process-max=4 --delta restore
```

### Network Optimization

```nix
# For R2 offsite backups
repo2-storage-verify-tls=n  # Skip TLS verification (faster, less secure)
repo2-bundle=y              # Bundle small files (fewer S3 requests)
```

## Migration Notes

### What Was NOT Migrated

- ✅ **ZFS Snapshots**: Still active via Sanoid (fast local rollback)
- ✅ **Sanoid/Syncoid**: Still replicating to nas-1 (local DR)
- ✅ **Node Exporter**: Still collecting PostgreSQL metrics

### Breaking Changes

1. **Restic Commands No Longer Work**:
   ```bash
   # OLD (broken)
   restic -r /mnt/nas-backup snapshots --tag postgresql

   # NEW
   pgbackrest --stanza=main info
   ```

2. **Backup Paths Changed**:
   ```bash
   # OLD
   /mnt/nas-backup/<restic-snapshot-id>/var/lib/postgresql/16/main

   # NEW
   /mnt/nas-backup/pgbackrest/backup/main/<backup-set-id>
   ```

3. **Systemd Service Names Changed**:
   ```bash
   # OLD
   systemctl status restic-backups-postgresql-main-base.service

   # NEW
   systemctl status pgbackrest-full-backup.service
   ```

### Rollback Plan

If pgBackRest fails catastrophically, the old system can be restored:

```bash
# 1. Revert Git commits
git log --oneline | grep -i pgbackrest  # Find migration commits
git revert <commit-hash>

# 2. Rebuild
nixos-rebuild switch

# 3. Verify pg-backup-scripts are active
systemctl status pg-zfs-snapshot.service
```

However, **this is unlikely to be necessary** because:
- pgBackRest is battle-tested and widely used
- We tested restore procedures during migration
- ZFS snapshots provide immediate fallback for recent data

## References

- [pgBackRest Documentation](https://pgbackrest.org/user-guide.html)
- [PostgreSQL PITR Documentation](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [NixOS PostgreSQL Module Options](https://search.nixos.org/options?query=services.postgresql)

## Summary

### Benefits Achieved

1. **Reduced Complexity**: 161 lines of custom scripts → 45-line config file
2. **Industry Standard**: Using battle-tested pgBackRest vs custom solution
3. **Better Features**: Incremental, differential, parallel backups, delta restore
4. **Simpler Operations**: Single `pgbackrest` command vs complex Restic workflows
5. **Better Monitoring**: Built-in metrics via `pgbackrest info --output=json`

### Trade-offs

1. **New Tool**: Team must learn pgBackRest (but it's well-documented)
2. **Less ZFS Integration**: pgBackRest doesn't coordinate with ZFS snapshots (but doesn't need to)

### Conclusion

The migration to pgBackRest successfully replaced a complex custom backup system with an industry-standard tool while maintaining all PITR capabilities and simplifying operations. The result is a more maintainable, well-supported backup solution that follows the YAGNI principle.
