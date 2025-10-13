# PostgreSQL Offsite Backup - Setup Guide

## Overview
PostgreSQL backups have been integrated into the existing Restic backup system for Cloudflare R2 offsite storage, instead of adding pgBackRest as a separate tool.

## Implementation Summary

### Files Modified
1. **`hosts/forge/backup.nix`**
   - Added PostgreSQL datasets to ZFS snapshot pool configuration
   - Added `r2-offsite` repository (Cloudflare R2 with S3 compatibility)
   - Added `postgresql-offsite` backup job
   - Comprehensive inline documentation added

2. **`hosts/forge/secrets.nix`**
   - Added `restic/r2-env` secret for R2 API credentials

3. **`hosts/forge/r2-env.example`** (NEW)
   - Template for R2 environment variables

## Next Steps

### 1. Create Cloudflare R2 Buckets (Per-Environment Strategy)

**Bucket Organization:** Following Gemini Pro's recommendation for security isolation

Create three buckets via Cloudflare Dashboard → R2 Object Storage:

1. **`nix-homelab-prod-servers`** - forge, luna, nas-1 (critical infrastructure)
2. **`nix-homelab-edge-devices`** - nixpi (monitoring/edge)
3. **`nix-homelab-workstations`** - rydev, rymac (development machines)

**Security Benefits:**
- Compromised workstation cannot access server backups
- Least privilege principle per environment tier
- Separate lifecycle policies per bucket
- Logical security boundaries

**Note your Account ID** from the R2 endpoint URL (needed for step 4)

### 2. Generate R2 API Tokens (One Per Bucket)

Create three scoped API tokens with custom policies:

#### Production Servers Token (for forge, luna, nas-1)

In Cloudflare Dashboard → R2 → Manage R2 API Tokens:

1. Create API Token: "nix-homelab-prod-servers-backup"
2. **Use Custom Policy** (critical for security):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::nix-homelab-prod-servers"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::nix-homelab-prod-servers/*"]
    }
  ]
}
```

3. Save **Access Key ID** and **Secret Access Key**

#### Edge Devices Token (for nixpi)

Same process, but for bucket `nix-homelab-edge-devices`

#### Workstations Token (for rydev, rymac)

Same process, but for bucket `nix-homelab-workstations`

**Important:** Each token can ONLY access its assigned bucket. This prevents cross-environment compromise.

### 3. Add Secrets to SOPS

For **forge** (production server):

```bash
cd hosts/forge

# Edit secrets file (will decrypt, open in editor, re-encrypt)
sops secrets.sops.yaml

# Add this section (use production servers credentials):
restic:
  password: <existing_password>
  r2-prod-env: |
    AWS_ACCESS_KEY_ID=your_prod_servers_access_key_id
    AWS_SECRET_ACCESS_KEY=your_prod_servers_secret_access_key
```

Repeat for other hosts:
- **luna, nas-1:** Use same `r2-prod-env` credentials (shared bucket)
- **nixpi:** Add `r2-edge-env` with edge-devices bucket credentials
- **rydev, rymac:** Add `r2-workstations-env` with workstations bucket credentials

### 4. Update R2 Endpoint in backup.nix

Edit `hosts/forge/backup.nix` line 109 with your actual R2 account ID:

```nix
url = "s3:https://<YOUR_ACCOUNT_ID>.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge";
```

The `/forge` suffix creates a separate Restic repository within the shared production bucket.

### 5. Deploy and Verify

```bash
# Deploy configuration to forge
nixos-rebuild switch --flake .#forge --target-host forge.holthome.net

# SSH to forge and verify repository initialization
ssh forge.holthome.net

# Set environment variables for testing (use actual account ID)
export RESTIC_REPOSITORY="s3:https://<account_id>.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge"
export RESTIC_PASSWORD_FILE="/run/secrets/restic/password"
export AWS_ACCESS_KEY_ID="<from_sops>"
export AWS_SECRET_ACCESS_KEY="<from_sops>"

# Or use the systemd service environment:
sudo -u restic-backup restic -r s3:https://<account_id>.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge snapshots

# Trigger manual backup to test
systemctl start backup-postgresql-offsite.service

# Check status
systemctl status backup-postgresql-offsite.service
journalctl -u backup-postgresql-offsite.service -n 50

# Verify backup in R2
sudo -u restic-backup restic -r s3:https://<account_id>.r2.cloudflarestorage.com/nix-homelab-prod-servers/forge snapshots
```

### 6. Verify Integration with Existing Systems
The postgresql-offsite job automatically inherits:
- ✅ Prometheus metrics export (`/var/lib/node_exporter/textfile_collector`)
- ✅ Error analysis and structured logging (`/var/log/backup`)
- ✅ Pushover/ntfy.sh notifications on failure
- ✅ Weekly verification via `restic check`
- ✅ Monthly restore testing
- ✅ Resource limits (512MB memory, 0.5 CPU)

Check Grafana dashboard to confirm metrics are appearing.

## PostgreSQL PITR Recovery from R2

In case of disaster recovery:

```bash
# 1. Find latest snapshot
restic -r s3:https://<account_id>.r2.cloudflarestorage.com/nix-homelab-backups/forge snapshots --tag postgresql

# 2. Restore PGDATA
restic -r s3:... restore <snapshot_id> \
  --target /var/lib/postgresql/16/main \
  --include /var/lib/postgresql/16/main

# 3. Restore WAL archive
restic -r s3:... restore latest \
  --target /tmp/wal-restore \
  --include /var/lib/postgresql/16/main-wal-archive

# 4. Configure recovery
cat > /var/lib/postgresql/16/main/recovery.signal << EOF
# Recovery mode enabled
EOF

# Edit postgresql.conf to add:
# restore_command = 'cp /tmp/wal-restore/var/lib/postgresql/16/main-wal-archive/%f %p'
# recovery_target_time = '2025-10-13 15:30:00'  # Your desired recovery point

# 5. Fix permissions and start
chown -R postgres:postgres /var/lib/postgresql/16
systemctl start postgresql

# 6. Verify recovery
sudo -u postgres psql -c "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"
```

## Cost Estimate

Based on 100GB PostgreSQL database with 10% daily change:
- Storage: ~710GB/month = ~$10.65/month
- API operations: ~$0.50/month
- Egress: $0.00 (R2 zero egress fees)
- **Total: ~$11-12/month**

## Monitoring

Check backup health:
```bash
# Prometheus metrics
curl http://localhost:9100/metrics | grep restic_backup

# View logs
tail -f /var/log/backup/postgresql-offsite-*.log

# Check last backup time
restic -r s3:... snapshots --latest 1 --tag postgresql
```

## Why Not pgBackRest?

After critical evaluation with Gemini Pro, we chose to extend our existing Restic system because:

1. **We already have PITR compliance** - pg-backup-scripts creates proper backup_label files
2. **Unified operations** - Single dashboard, alerting, verification for all backups
3. **Existing verification** - Monthly restore testing is superior to pgbackrest verify
4. **Operational simplicity** - Add 1 repo + 1 job vs entire new tool stack
5. **DRY principle** - Don't duplicate monitoring, alerting, secret management

The small convenience of pgBackRest's single-command restore doesn't justify maintaining a parallel backup system.

## References

- Restic documentation: https://restic.readthedocs.io/
- Cloudflare R2 S3 API: https://developers.cloudflare.com/r2/api/s3/
- PostgreSQL PITR: https://www.postgresql.org/docs/current/continuous-archiving.html
