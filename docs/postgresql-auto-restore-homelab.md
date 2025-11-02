# PostgreSQL Automatic Restore for Homelab DR

## What This Is For

**Scenario**: You're rebuilding your homelab server from scratch (hardware failure, OS reinstall, migration, etc.) and want PostgreSQL to automatically restore from your latest backup instead of manually running restore commands.

This is **disaster recovery automation for homelabs** - not for staging environments or development servers.

## The Problem It Solves

### Without This Module

1. Rebuild server with NixOS configuration
2. PostgreSQL starts with empty database
3. SSH in, stop PostgreSQL
4. Manually run: `pgbackrest --stanza=main --repo=1 restore`
5. Start PostgreSQL again
6. Verify everything works

**Pain points**: Multiple manual steps, easy to forget, requires remembering pgBackRest syntax.

### With This Module

1. Rebuild server with NixOS configuration (with this module enabled)
2. **That's it** - PostgreSQL automatically restores from backup on first boot

## Quick Start

### Minimal Configuration (Basic)

```nix
# hosts/forge/default.nix
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    # Automatic DR restore from NFS only
    preSeed = {
      enable = true;
      source.stanza = "main";  # Your pgBackRest stanza name
      # Defaults: repository = 1 (NFS), backupSet = "latest"
    };
  };
}
```

That's it! On first boot with empty PGDATA, it automatically restores from your NFS backup.

### Recommended Configuration (With Fallback)

```nix
# hosts/forge/default.nix
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    # Automatic DR restore with R2 fallback
    preSeed = {
      enable = true;
      source = {
        stanza = "main";
        repository = 1;  # Try NFS first
        fallbackRepository = 2;  # Automatically try R2 if NFS fails
      };
      # Required for R2 access when fallback is configured
      environmentFile = config.sops.secrets."restic/r2-prod-env".path;
    };
  };
}
```

**Benefits of fallback configuration:**

- If NFS is available → fast local restore
- If NFS is dead/unavailable → automatically tries R2
- True disaster recovery - works even if NAS completely failed

## How It Works

### First Boot (Fresh Install)

```
1. NixOS activates configuration
2. postgresql-preseed.service runs (BEFORE postgresql.service)
3. Checks: Is PGDATA empty?
   ├─ Yes → Run: pgbackrest --stanza=main --repo=1 restore
   └─ No  → Skip restore, start PostgreSQL normally
4. Creates completion marker: .preseed-completed
5. PostgreSQL starts with restored data
```

### Subsequent Boots

```
1. postgresql-preseed.service checks for completion marker
2. Marker exists → Skip restore
3. PostgreSQL starts normally
```

### What If You Already Have Data?

**The restore will NOT run**. The module has multiple safety checks:
- Checks if PGDATA is empty (refuses to overwrite existing data)
- Checks for completion marker (prevents re-running)
- OneShot service (doesn't retry on failure)

## Configuration Options

### Full Example

```nix
services.postgresql.preSeed = {
  # Enable automatic restore on empty PGDATA
  enable = true;

  # Optional: Environment type (null for homelab)
  # Only set this if you have BOTH production AND staging servers
  # and want to prevent auto-restore on production
  environment = null;  # or omit entirely

  source = {
    # pgBackRest stanza name
    stanza = "main";

    # Repository to restore from (1 = NFS, 2 = R2)
    # Use repo1 (NFS) - it's faster and has WAL files
    repository = 1;

    # Which backup to restore
    backupSet = "latest";  # or specific backup like "20241013-020000F"
  };

  # What to do after restore
  targetAction = "promote";  # "promote" = start immediately, "shutdown" = leave stopped

  # Optional: Script to run after restore (rarely needed for homelab)
  postRestoreScript = null;
};
```

### Repository Selection (repo1 vs repo2)

Your setup (from `forge/default.nix`):
- **repo1**: NFS at `/mnt/nas-backup/pgbackrest` (7 day retention, has WALs)
- **repo2**: Cloudflare R2 (30 day retention, NO WALs)

**Use repo1 (default)** because:
- ✅ Much faster (local network)
- ✅ Has WAL files for complete restore
- ✅ No internet dependency
- ✅ Free (no egress costs)

**Only use repo2 if:**
- NAS is dead/unavailable
- Need backup older than 7 days
- Testing offsite recovery

### NEW: Automatic Fallback to Repo2 (Recommended)

**As of November 2025**, the preseed module now supports automatic fallback:

```nix
services.postgresql.preSeed = {
  enable = true;
  source = {
    stanza = "main";
    repository = 1;  # Try NFS first
    fallbackRepository = 2;  # Automatically try R2 if NFS fails
  };
  # R2 credentials for fallback (required when fallbackRepository = 2)
  environmentFile = config.sops.secrets."restic/r2-prod-env".path;
};
```

**What this does:**
1. Attempts restore from repo1 (NFS) - fast, local
2. If repo1 fails → automatically tries repo2 (R2)
3. If both fail → logs error and exits

**Benefits:**
- ✅ True disaster recovery - works even if NAS is dead
- ✅ No manual intervention needed
- ✅ Still prefers fast local NFS when available
- ✅ Falls back to offsite only when necessary

**To use R2 only (no fallback):**
```nix
services.postgresql.preSeed.source.repository = 2;
services.postgresql.preSeed.environmentFile = config.sops.secrets."restic/r2-prod-env".path;
```

## Safety Features

| Protection | How It Works |
|------------|--------------|
| **Empty PGDATA Check** | Refuses to run if PGDATA has any files |
| **Completion Marker** | Creates `.preseed-completed` to prevent re-runs |
| **OneShot Service** | Runs once, no auto-retry on failure |
| **Manual Override** | Can always disable via `enable = false` |

## Common Operations

### Check If Restore Will Run

```bash
# On the server
ls -la /var/lib/postgresql/16/

# If empty OR missing .preseed-completed → restore will run
# If has .preseed-completed → restore will skip
```

### Force a Restore (Rebuild Scenario)

```bash
# Stop PostgreSQL
sudo systemctl stop postgresql

# Clear PGDATA (⚠️ DESTROYS ALL DATA!)
sudo rm -rf /var/lib/postgresql/16/*

# Restart PostgreSQL (triggers automatic restore)
sudo systemctl start postgresql

# Watch the restore happen
sudo journalctl -u postgresql-preseed -f
```

### Verify Restore Completed

```bash
# Check service status
sudo systemctl status postgresql-preseed

# Check completion marker
ls -la /var/lib/postgresql/16/.preseed-completed

# Verify PostgreSQL is running
sudo systemctl status postgresql
sudo -u postgres psql -c "SELECT version();"
```

### Disable Auto-Restore Temporarily

```nix
# In your config
services.postgresql.preSeed.enable = false;
```

Rebuild, and PostgreSQL will start empty (no restore).

## Troubleshooting

### Post-Preseed Backup Retry Limit

**NEW: Automatic Retry Prevention**

The post-preseed backup (which runs after restore) has retry protection to prevent infinite loops:

- **Max Retries**: 5 attempts with 30-second delays
- **Retry Counter**: Stored in `/var/lib/postgresql/.postpreseed-retry-count`
- **Give-Up Marker**: Creates `/var/lib/postgresql/.postpreseed-backup-GAVE-UP` after max retries
- **Behavior**: Exits gracefully (code 0) to stop systemd restart loop

**Check if backup gave up:**

```bash
# Check for give-up marker
ls -la /var/lib/postgresql/.postpreseed-backup-GAVE-UP

# Check retry count
cat /var/lib/postgresql/.postpreseed-retry-count

# View backup failure logs
sudo journalctl -u pgbackrest-post-preseed -n 100
```

**To retry after fixing the issue:**

```bash
# Remove markers
sudo rm /var/lib/postgresql/.postpreseed-backup-GAVE-UP
sudo rm /var/lib/postgresql/.postpreseed-retry-count

# Restart the service
sudo systemctl restart pgbackrest-post-preseed
```

**Common causes:**

- Repo2 (R2) credentials invalid/expired
- Network connectivity to Cloudflare R2 down
- NFS mount for repo1 not available
- Insufficient disk space for WAL files

### Stanza-Create Graceful Degradation

**NEW: Repo1-Only Fallback**

The `pgbackrest-stanza-create` service now handles repo2 unavailability gracefully:

**Normal operation:**

- Attempts to create/upgrade stanza with both repo1 (NFS) and repo2 (R2)
- If successful → both repositories active, everything works perfectly

**Fallback when repo2 unavailable:**

- If dual-repo creation fails → automatically attempts repo1-only stanza-upgrade
- WAL archiving continues to repo1 (NFS) even if repo2 (R2) is down
- Service exits with code 1 to trigger alerts, but PostgreSQL remains operational
- Once repo2 is back, run `sudo systemctl restart pgbackrest-stanza-create.service`

**Check stanza-create status:**

```bash
# Check service status
sudo systemctl status pgbackrest-stanza-create

# View detailed logs
sudo journalctl -u pgbackrest-stanza-create -n 50

# Manually test stanza upgrade
sudo -u postgres pgbackrest --stanza=main stanza-upgrade
```

**This prevents:**

- Complete WAL archiving failure when offsite backup is temporarily unavailable
- PostgreSQL startup delays or failures due to backup configuration
- Loss of local NFS backups when only R2 has connectivity issues

### Restore Didn't Run

**Check 1**: Is PGDATA truly empty?

```bash
ls -la /var/lib/postgresql/16/
```

**Check 2**: Does completion marker exist?

```bash
ls -la /var/lib/postgresql/16/.preseed-completed
# If exists, remove it: sudo rm /var/lib/postgresql/16/.preseed-completed
```

**Check 3**: Check service logs

```bash
sudo journalctl -u postgresql-preseed -n 100
```

### "PGDATA not empty" Error

The restore refuses to overwrite existing data. If you want to restore anyway:
```bash
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/16/*
sudo systemctl start postgresql
```

### Restore Failed

```bash
# Check logs
sudo journalctl -u postgresql-preseed -xe

# Common issues:
# - NFS mount not available
# - Invalid stanza name
# - No backups in repository
# - Network connectivity (if using R2)
```

### NFS Mount Issues

```bash
# Check NFS mount
mount | grep nas-backup

# Test connectivity
ls -l /mnt/nas-backup/pgbackrest

# Verify backups exist
sudo -u postgres pgbackrest info --stanza=main --repo=1
```

## When NOT to Use This

❌ **Don't use if:**
- You want explicit control over restores
- You have critical compliance requirements
- You need to verify backup integrity before restore
- You're paranoid about automation

✅ **Do use if:**
- You trust your backups
- You want convenience over caution
- You rebuild servers occasionally
- You don't want to remember pgBackRest commands

## The "Is This Safe?" Question

### Arguments FOR Auto-Restore (Homelab Context)

1. **Empty PGDATA check** prevents overwriting data
2. **Completion marker** prevents re-runs
3. **Homelab = lower stakes** than production
4. **Convenience** beats remembering manual commands
5. **Fast recovery** during stressful rebuild situations

### Arguments AGAINST Auto-Restore

1. **"Magical" behavior** - implicit instead of explicit
2. **Can't verify backup** before restore
3. **No confirmation prompt** - just does it
4. **Wrong backup** could auto-restore (if misconfigured)

### The Compromise

This module uses the "empty PGDATA" trigger, which means:
- ✅ Only runs when PGDATA is empty (safe)
- ✅ You explicitly enable it in config (opt-in)
- ✅ You can disable it anytime
- ❌ No confirmation prompt (automatic)

**My take**: For a homelab, the convenience wins. If you're uncomfortable, use manual restore instead.

## Alternative: Manual Restore

If you prefer explicit control:

```nix
# Don't enable preSeed
services.postgresql.preSeed.enable = false;
```

Then manually restore when needed:
```bash
sudo systemctl stop postgresql
sudo -u postgres pgbackrest --stanza=main --repo=1 --type=immediate restore
sudo systemctl start postgresql
```

Save that command somewhere for when you need it!

## Real-World Homelab Scenarios

### Scenario 1: Hardware Upgrade

*Migrating to new server hardware*

1. Build new server with same NixOS config (preSeed.enable = true)
2. Boot server
3. PostgreSQL automatically restores from NFS backup
4. Services come up with your data
5. Done!

**With fallback**: If you configure `fallbackRepository = 2`, the system will automatically try R2 if NFS fails for any reason.

### Scenario 2: OS Reinstall

*ZFS root got corrupted, reinstalling OS*

1. Reinstall NixOS
2. Apply configuration (preSeed.enable = true)
3. NFS mounts, PostgreSQL restores automatically
4. Services restart with your data

**With fallback**: Even if NFS mount fails during boot, system falls back to R2 automatically - no manual intervention needed.

### Scenario 3: Testing Disaster Recovery

*Want to verify backups work*

1. Spin up test VM with same config
2. Enable preSeed, set to repo2 (don't impact NFS)
3. Boot VM → PostgreSQL auto-restores from R2
4. Verify data integrity
5. Delete VM

**Better approach**: Use `fallbackRepository = 2` in production - you can test failover by temporarily unmounting NFS.

### Scenario 4: NFS/NAS Complete Failure

*Your NAS died and you need to rebuild the database server*

**Without fallback** (old behavior):

1. NFS mount fails or is unavailable
2. Restore attempts repo1 → fails
3. PostgreSQL starts with empty database
4. Manual intervention required: change config to repo2, rebuild

**With fallback** (new automatic behavior):

1. NFS mount fails or is unavailable
2. Restore attempts repo1 → fails (logged)
3. System automatically tries repo2 (R2) → succeeds!
4. PostgreSQL starts with data from offsite backup
5. Services come up normally, no manual intervention

**Configuration required:**

```nix
services.postgresql.preSeed = {
  enable = true;
  source = {
    stanza = "main";
    repository = 1;
    fallbackRepository = 2;
  };
  environmentFile = config.sops.secrets."restic/r2-prod-env".path;
};
```

This is the **recommended configuration** for true disaster recovery.

### Scenario 5: "Oops I Deleted Everything"

*Accidentally nuked PGDATA*

```

1. Stop PostgreSQL: `systemctl stop postgresql`
2. Check config has preSeed.enable = true
3. Remove completion marker: `rm /var/lib/postgresql/16/.preseed-completed`
4. Start PostgreSQL: `systemctl start postgresql`
5. Watch restore: `journalctl -u postgresql-preseed -f`

## Summary

**For Homelab DR**:
- ✅ Enable automatic restore
- ✅ Use repo1 (NFS) for speed
- ✅ Set `backupSet = "latest"`
- ✅ Trust the safety checks
- ✅ Enjoy convenient DR

**Configuration**:
```nix
services.postgresql.preSeed = {
  enable = true;
  source.stanza = "main";
};
```

Done! Your homelab PostgreSQL will automatically restore from backup when needed.

## Related Documentation

- [Repository Selection Guide](postgresql-preseed-repository-selection.md) - repo1 vs repo2 comparison
- [PITR Guide](postgresql-pitr-guide.md) - Point-in-time recovery (manual)
- [pgBackRest Migration](postgresql-pgbackrest-migration.md) - Backup system setup
