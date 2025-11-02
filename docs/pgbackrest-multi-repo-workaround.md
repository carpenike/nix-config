# pgBackRest Multi-Repository Configuration Workaround

## Overview

This document explains the configuration pattern used to support two pgBackRest repositories (NFS + S3) while preventing WAL archiving failures caused by credential validation issues.

## The Problem

When both repositories are defined in `/etc/pgbackrest.conf`, the `archive_command` (run by PostgreSQL) attempts to validate **all** configured repositories, including repo2 (R2/S3). However:

- Repo2 requires S3 credentials (`PGBACKREST_REPO2_S3_KEY`)
- These credentials are NOT available to the PostgreSQL process
- Result: `archive-push command requires option: repo2-s3-key` errors

### What We Tried (That Didn't Work)

1. ❌ `--repo=1` flag in archive_command → `option 'repo' not valid for command 'archive-push'`
2. ❌ `repo1-archive-push=y` option → `configuration file contains invalid option 'repo1-archive-push'`
3. ❌ `[global:archive-push]` section with `repo=1` → `configuration file contains command-line only option 'repo'`

**None of these documented pgBackRest options actually exist or work in pgBackRest 2.55.1.**

## The Solution

**Remove repo2 from `/etc/pgbackrest.conf` entirely** and define it exclusively via command-line flags in backup services.

### Configuration Files

#### `/etc/pgbackrest.conf`

Contains **only** repo1 (NFS) configuration:

```ini
[global]
repo1-path=/mnt/nas-postgresql/pgbackrest
repo1-retention-full=7

archive-async=y
spool-path=/var/lib/pgbackrest/spool

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

#### Systemd Services

Each service that needs repo2 access defines these flags:

```bash
REPO2_FLAGS="--repo2-type=s3 --repo2-path=/forge-pgbackrest --repo2-s3-bucket=nix-homelab-prod-servers --repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com --repo2-s3-region=auto --repo2-s3-uri-style=path"
```

Services that use these flags:
- `pgbackrest-stanza-create.service`
- `pgbackrest-post-preseed.service`
- `pgbackrest-full-backup.service`
- `pgbackrest-incr-backup.service`
- `pgbackrest-metrics.service`

### How It Works

1. **Archive Command**: PostgreSQL's `archive_command` only sees repo1 in the config, so it doesn't require S3 credentials
2. **Backup Services**: Load S3 credentials via `EnvironmentFile` and pass repo2 config via command-line flags
3. **Credentials**: Transformed in service scripts:
   ```bash
   export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
   export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"
   ```

## Operational Procedures

### Manual Commands

When running pgBackRest commands manually, you must include the repo2 flags if you want to see/use both repositories.

#### View Both Repositories

```bash
sudo -u postgres bash -c '
  source /run/secrets/restic/r2-prod-env
  export PGBACKREST_REPO2_S3_KEY=$AWS_ACCESS_KEY_ID
  export PGBACKREST_REPO2_S3_KEY_SECRET=$AWS_SECRET_ACCESS_KEY
  pgbackrest --stanza=main \
    --repo2-type=s3 \
    --repo2-path=/forge-pgbackrest \
    --repo2-s3-bucket=nix-homelab-prod-servers \
    --repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com \
    --repo2-s3-region=auto \
    --repo2-s3-uri-style=path \
    info
'
```

#### View Only Repo1 (NFS)

```bash
sudo -u postgres pgbackrest --stanza=main info
```

#### Restore from Repo1 (Primary - Has PITR)

```bash
sudo -u postgres pgbackrest --stanza=main --repo=1 restore
```

#### Restore from Repo2 (DR - Backup Timestamps Only)

```bash
sudo -u postgres bash -c '
  source /run/secrets/restic/r2-prod-env
  export PGBACKREST_REPO2_S3_KEY=$AWS_ACCESS_KEY_ID
  export PGBACKREST_REPO2_S3_KEY_SECRET=$AWS_SECRET_ACCESS_KEY
  pgbackrest --stanza=main --repo=2 \
    --repo2-type=s3 \
    --repo2-path=/forge-pgbackrest \
    --repo2-s3-bucket=nix-homelab-prod-servers \
    --repo2-s3-endpoint=21ee32956d11b5baf662d186bd0b4ab4.r2.cloudflarestorage.com \
    --repo2-s3-region=auto \
    --repo2-s3-uri-style=path \
    restore
'
```

**Note**: Repo2 restores are limited to the last backup timestamp (no continuous WAL replay).

### Disaster Recovery

In a DR scenario where repo1 (NFS) is unavailable:

1. The simplified command will fail (repo2 not in config)
2. You must use the full command with repo2 flags (see above)
3. **Document this procedure in your DR runbook**

### Health Checks

#### Check Repo1

```bash
sudo -u postgres pgbackrest --stanza=main --repo=1 check
```

#### Check Both Repos

You must add the repo2 flags (see "View Both Repositories" above) and cannot use `--repo=2` to select it individually.

## Maintenance

### Changing S3 Endpoint or Bucket

The repo2 configuration is defined in **5 locations** in `/Users/ryan/src/nix-config/hosts/forge/default.nix`:

1. Line ~1078: `pgbackrest-stanza-create` service
2. Line ~1343: `pgbackrest-post-preseed` service
3. Line ~1470: `pgbackrest-full-backup` service
4. Line ~1504: `pgbackrest-incr-backup` service
5. Line ~1674: `pgbackrest-metrics` service

**To update repo2 configuration:**

1. Search for `REPO2_FLAGS=` in `hosts/forge/default.nix`
2. Update all 5 occurrences with the new values
3. Deploy with `nixos-rebuild switch`

### Future Improvement

Consider centralizing `REPO2_FLAGS` in a Nix `let` binding to reduce duplication:

```nix
let
  repo2Flags = "--repo2-type=s3 --repo2-path=/forge-pgbackrest ...";
in {
  # Use ${repo2Flags} in all services
}
```

## Backup Strategy Summary

- **Repo1 (NFS)**: `/mnt/nas-postgresql/pgbackrest`
  - Continuous WAL archiving (every 5 minutes via `archive_command`)
  - Full backups: Daily at 2 AM
  - Incremental backups: Hourly
  - Retention: 7 full backups
  - **Recovery**: Point-in-Time Recovery (PITR) available

- **Repo2 (R2/S3)**: `s3://nix-homelab-prod-servers/forge-pgbackrest`
  - Full backups: Daily at 2 AM
  - Incremental backups: Hourly
  - Retention: 30 full backups
  - **NO continuous WAL archiving** (intentional, for cost optimization)
  - **Recovery**: Limited to last backup timestamp (~1 hour RPO)

## Monitoring

WAL archiving health is monitored via:

```promql
# Alert fires if failed_count increases in 15 minutes
rate(pg_stat_archiver_failed_count[15m]) > 0
```

Check current status:

```bash
ssh forge.holthome.net "sudo -u postgres psql -c 'SELECT * FROM pg_stat_archiver;'"
```

## Troubleshooting

### "No such repository" errors

If you see errors about repo2 not existing, remember that repo2 is NOT in `/etc/pgbackrest.conf`. You must pass the full repo2 configuration via command-line flags.

### Archive failures returning

Check:
1. NFS mount health: `mountpoint /mnt/nas-postgresql`
2. Spool directory: `ls -lh /var/lib/pgbackrest/spool/`
3. PostgreSQL logs: `journalctl -u postgresql | grep archive`

### Service failures

If backup services fail with repo2 errors, verify:
1. S3 credentials are in `/run/secrets/restic/r2-prod-env`
2. Service has `EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path`
3. The `REPO2_FLAGS` match across all services

## References

- Configuration: `/Users/ryan/src/nix-config/hosts/forge/default.nix`
- PostgreSQL config: `/Users/ryan/src/nix-config/hosts/forge/postgresql.nix`
- Related docs:
  - `docs/postgresql-pitr-guide.md`
  - `docs/pgbackrest-unified-config.md`
  - `docs/postgresql-pgbackrest-migration.md`
