# Backup System Configuration for Forge

This document describes the backup configuration for the `forge` NixOS host.

## Overview

Forge uses a comprehensive backup system with:

- **ZFS snapshots** for point-in-time consistency
- **Restic** for encrypted, deduplicated file-based backups
- **NFS** to store backups on nas-1
- **Automated monitoring** and verification

## Architecture

```text
forge (source)                     nas-1 (destination)
├── ZFS Pools                      └── backup/forge/
│   ├── rpool/safe/home                ├── restic/          (Restic repository)
│   └── rpool/safe/persist             └── zfs-recv/        (Future: ZFS replication)
│
├── ZFS Snapshot Creation
│   └── /mnt/backup-snapshot
│
├── Restic Backup
│   └── NFS Mount: /mnt/nas-backup
│       └── nas-1:/mnt/backup/forge/restic
│
└── Backup to Repository
```

## Configuration Files

- **hosts/forge/backup.nix** - Main backup configuration
- **hosts/forge/secrets.nix** - SOPS secrets including Restic password
- **hosts/forge/secrets.sops.yaml** - Encrypted secrets file

## Storage on nas-1

### ZFS Datasets

```text
backup/forge/restic          # 300GB quota - Restic repository
backup/forge/zfs-recv        # 500GB quota - Future ZFS replication
```

### NFS Export

```text
/mnt/backup/forge/restic → forge.holthome.net (rw, no_root_squash)
```

## Backup Jobs

### System Backup

- **Paths**: `/home`, `/persist`
- **Schedule**: Daily
- **Repository**: nas-primary (nas-1 via NFS)
- **Retention**: 14 daily, 8 weekly, 6 monthly, 2 yearly
- **Features**:
  - Backed up from ZFS snapshots for consistency
  - Excludes cache directories and build artifacts
  - Resource-limited to avoid impacting system performance

### Excluded Patterns

- Cache directories (`**/.cache`, `**/Cache`)
- Build artifacts (`**/node_modules`, `**/target`, `**/result`)
- Temporary files (`**/*.tmp`)
- Direnv directories (`**/.direnv`)

## Backup Strategy with Impermanence

Forge uses NixOS impermanence, which means:

- Root filesystem (`/`) is ephemeral and wiped on every boot
- Only `/persist` and `/home` contain data that survives reboots
- All system state, configs, and service data lives in `/persist` (via impermanence module)

### What Gets Backed Up (and Why)

#### ✅ `/home` - User Data (CRITICAL)

- Personal files, documents, projects
- User-specific configurations
- Cannot be recreated from NixOS config

#### ✅ `/persist` - System State (CRITICAL)

- SSH host keys and machine-id
- Service data (Plex metadata, databases, etc.)
- System logs and persistent cache
- All data declared in impermanence configuration
- Cannot be recreated from NixOS config

#### ❌ `/nix` - Nix Store (NOT BACKED UP)

- Completely reproducible from `configuration.nix`
- Can be rebuilt by running `nixos-rebuild`
- Backing up saves download time but not necessary for recovery

#### ❌ `/` - Root Filesystem (NOT BACKED UP)

- Ephemeral, rolled back to blank snapshot on boot
- Fully reconstructed from NixOS config at boot time

### Single Job vs Multiple Jobs

#### Current Setup: Single Job (Recommended)

```nix
jobs = {
  system = {
    paths = [ "/home" "/persist" ];
    # Backs up everything in one consistent snapshot
  };
}
```

**Advantages:**

- ✅ Simple configuration and maintenance
- ✅ Consistent point-in-time backup across all services
- ✅ Can still restore individual services selectively (see below)
- ✅ One schedule and retention policy to manage

**Use when:**

- All services can share the same backup schedule
- All services can share the same retention policy
- You want simplicity over granular control

#### Alternative: Multiple Jobs (Advanced)

```nix
jobs = {
  system-critical = {
    paths = [ "/home" "/persist/etc" "/persist/var/lib/nixos" ];
    schedule = "daily";
  };

  plex = {
    paths = [ "/persist/var/lib/plex" ];
    schedule = "weekly";  # Metadata changes less frequently
    excludePatterns = [ "**/Cache/**" "**/Logs/**" ];
  };

  databases = {
    paths = [ "/persist/var/lib/postgresql" ];
    schedule = "hourly";  # More frequent for critical data
    preBackupScript = "pg_dumpall > /persist/var/lib/postgresql/dump.sql";
  };
}
```

**Advantages:**

- ✅ Different schedules per service (hourly DB, weekly Plex)
- ✅ Different retention policies per service
- ✅ Service-specific pre/post backup scripts
- ✅ Easier to monitor individual services

**Disadvantages:**

- ⚠️ More complex configuration
- ⚠️ Services backed up at different times (less consistency)
- ⚠️ More snapshots to manage

**Use when:**

- Services need different backup frequencies
- Services need different retention policies
- Services need pre/post backup scripts (e.g., database dumps)
- You need granular monitoring per service

### Selective Restore from Single Job

Even with one backup job, you can restore individual services:

```bash
# Restore only Plex configuration
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/var/lib/plex

# Restore only PostgreSQL data
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/var/lib/postgresql

# Restore only a specific user's home directory
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /home/ryan

# Restore SSH keys only
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/etc/ssh
```

After restoring to `/tmp/restore`, copy the files back:

```bash
sudo cp -a /tmp/restore/persist/var/lib/plex /persist/var/lib/
sudo systemctl restart plex.service
```

### When to Add Service-Specific Jobs

Consider adding separate backup jobs when:

1. **Different backup frequencies needed**
   - Database: hourly
   - Plex metadata: weekly
   - System configs: daily

2. **Different retention policies needed**
   - Keep database backups for 90 days
   - Keep Plex backups for 30 days
   - Keep system backups for 2 years

3. **Pre/post backup scripts required**
   - Database dumps before backup
   - Application quiesce/resume
   - Custom validation scripts

4. **Large datasets with specific exclusions**
   - Plex: exclude Cache, Logs, Transcodes
   - Containers: exclude build cache
   - Databases: exclude temp files

### Adding Plex-Specific Backup (Example)

If you later decide to split out Plex, here's how:

```nix
# In hosts/forge/backup.nix
jobs = {
  system = {
    enable = true;
    paths = [ "/home" "/persist" ];
    excludePatterns = [
      # Exclude Plex from system backup (handled by separate job)
      "/persist/var/lib/plex/**"
    ];
  };

  plex = {
    enable = true;
    repository = "nas-primary";
    paths = [ "/persist/var/lib/plex" ];
    schedule = "weekly";  # Less frequent than system backup
    excludePatterns = [
      # Plex-specific exclusions
      "**/Plex Media Server/Cache/**"
      "**/Plex Media Server/Logs/**"
      "**/Plex Media Server/Crash Reports/**"
      "**/Plex Media Server/Updates/**"
      "**/Transcode/**"
    ];
    retention = {
      weekly = 4;
      monthly = 3;
      yearly = 1;
    };
    tags = [ "plex" "media-metadata" ];
  };
}
```

## Monitoring & Verification

### Automated Checks

- **Repository verification**: Weekly
- **Restore testing**: Monthly (tests random file samples)
- **Error analysis**: Automatic categorization of failures
- **Prometheus metrics**: Exported to `/var/lib/node_exporter/textfile_collector`

### Logs

- **Backup logs**: `/var/log/backup/`
- **Documentation**: `/var/lib/backup-docs/`

## Setup Instructions

### Prerequisites on nas-1

Before setting up backups on forge, you need to prepare nas-1:

#### 1. Create ZFS Datasets

```bash
# SSH to nas-1
ssh nas-1.holthome.net

# Create the forge parent dataset
sudo zfs create backup/forge

# Create Restic dataset (for file-based backups via NFS)
sudo zfs create backup/forge/restic
sudo zfs set compression=lz4 backup/forge/restic
sudo zfs set atime=off backup/forge/restic
sudo zfs set quota=300G backup/forge/restic
sudo zfs set recordsize=1M backup/forge/restic

# Create ZFS replication dataset (for future use)
sudo zfs create backup/forge/zfs-recv
sudo zfs set compression=lz4 backup/forge/zfs-recv
sudo zfs set atime=off backup/forge/zfs-recv
sudo zfs set quota=500G backup/forge/zfs-recv
sudo zfs set readonly=on backup/forge/zfs-recv

# Verify
zfs list -o name,used,avail,refer,mountpoint,quota,compression backup/forge backup/forge/restic backup/forge/zfs-recv
```

#### 2. Configure NFS Export

```bash
# Add NFS export for Restic
echo "/backup/forge/restic forge.holthome.net(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports

# Reload NFS exports
sudo exportfs -ra

# Verify
sudo exportfs -v
```

#### 3. Set Up ZFS Replication User (Optional - for Phase 2)

```bash
# Create system user for ZFS replication
sudo useradd -r -m -d /var/lib/zfs-replication -s /usr/sbin/nologin -c "ZFS replication receiver" zfs-replication

# Create .ssh directory
sudo mkdir -p /var/lib/zfs-replication/.ssh
sudo chmod 700 /var/lib/zfs-replication/.ssh

# Add forge's public key (from hosts/forge/ssh-keys.md)
sudo tee /var/lib/zfs-replication/.ssh/authorized_keys > /dev/null <<'EOF'
command="zfs recv -F backup/forge/zfs-recv",no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4aPwHeW7/p2YcKI41srC8X6Cw2D6e5mCbQuVp0USW1 zfs-replication@forge
EOF

# Set proper permissions
sudo chmod 600 /var/lib/zfs-replication/.ssh/authorized_keys
sudo chown -R zfs-replication:zfs-replication /var/lib/zfs-replication/.ssh

# Grant ZFS permissions
sudo zfs allow zfs-replication receive,create,mount,hold backup/forge/zfs-recv
```

### Setup on forge

#### 1. Add Restic Password Secret

Generate a secure password and add it to SOPS:

```bash
cd /Users/ryan/src/nix-config

# Generate password
RESTIC_PASSWORD=$(openssl rand -base64 32)
echo "Generated password: $RESTIC_PASSWORD"

# Edit SOPS secrets file
sops hosts/forge/secrets.sops.yaml

# Add this section:
# restic:
#   password: <paste the generated password>
```

#### 2. Build and Deploy

```bash
# From your nix-config directory
nixos-rebuild switch --flake .#forge --target-host forge.holthome.net
```

#### 3. Verify Configuration

```bash
# SSH to forge
ssh forge.holthome.net

# Check NFS mount
ls -la /mnt/nas-backup

# Check backup service
systemctl status restic-backups-system.service
systemctl list-timers restic-*

# Check ZFS snapshot service
systemctl status zfs-snapshot.service
```

### 4. Run Initial Backup

```bash
# Manually trigger the first backup
sudo systemctl start restic-backups-system.service

# Watch the logs
sudo journalctl -u restic-backups-system.service -f
```

### 5. Verify Backup

```bash
# List snapshots
restic -r /mnt/nas-backup snapshots

# Check repository statistics
restic -r /mnt/nas-backup stats
```

## Daily Operations

### Manual Backup

```bash
sudo systemctl start restic-backups-system.service
```

### Check Backup Status

```bash
# View timer schedule
systemctl list-timers restic-*

# View recent logs
sudo journalctl -u restic-backups-system.service -n 50

# Check last backup status
systemctl status restic-backups-system.service
```

### List Backups

```bash
restic -r /mnt/nas-backup snapshots
```

### Browse Backup Contents

```bash
# Mount latest snapshot
restic -r /mnt/nas-backup mount /mnt/restic-browse

# Browse files
ls -la /mnt/restic-browse/snapshots/latest/

# Unmount when done
fusermount -u /mnt/restic-browse
```

## Restore Operations

### Common Restore Scenarios

All restore commands use this pattern:

```bash
restic -r /mnt/nas-backup restore [snapshot] --target [destination] --path [what-to-restore]
```

Where:

- `[snapshot]`: Use `latest` or a specific snapshot ID (from `restic snapshots`)
- `[destination]`: Temporary location like `/tmp/restore`
- `[what-to-restore]`: Specific path from the backup

#### Restore Specific File or Directory

```bash
# Find a file in backups
restic -r /mnt/nas-backup find filename

# Restore specific file
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /home/ryan/important-file.txt

# Restore entire directory
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /home/ryan/Documents
```

#### Restore Service-Specific Data (From Single Backup)

Even though everything is in one backup job, you can restore individual services:

```bash
# Restore Plex configuration only
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/var/lib/plex

# Copy back to system
sudo systemctl stop plex.service
sudo cp -a /tmp/restore/persist/var/lib/plex /persist/var/lib/
sudo chown -R plex:plex /persist/var/lib/plex
sudo systemctl start plex.service

# Restore PostgreSQL database only
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/var/lib/postgresql

# Restore and import
sudo systemctl stop postgresql.service
sudo -u postgres psql < /tmp/restore/persist/var/lib/postgresql/dump.sql
sudo systemctl start postgresql.service

# Restore SSH host keys only
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/etc/ssh

sudo cp -a /tmp/restore/persist/etc/ssh/* /persist/etc/ssh/
sudo chmod 600 /persist/etc/ssh/ssh_host_*_key
sudo systemctl restart sshd.service
```

#### Restore Entire Home Directory

```bash
# Restore a user's entire home directory
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /home/ryan

# Copy back
sudo cp -a /tmp/restore/home/ryan /home/
sudo chown -R ryan:ryan /home/ryan
```

#### Restore All Persistent State

```bash
# Restore everything in /persist
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist

# Review what was restored
ls -la /tmp/restore/persist

# Selective copy back (safer than full restore)
sudo systemctl stop all-services.target  # Stop services first
sudo cp -a /tmp/restore/persist/var/lib/specific-service /persist/var/lib/
sudo systemctl start all-services.target
```

#### Full System Disaster Recovery

If you need to rebuild the entire system from scratch:

1. **Prepare new system:**

   ```bash
   # Install NixOS with same disk layout (use disko-config.nix)
   # Ensure /persist and /home are mounted
   ```

2. **Restore persistent data:**

   ```bash
   # Mount NFS share
   sudo mount -t nfs nas-1.holthome.net:/mnt/backup/forge/restic /mnt/nas-backup

   # Restore /persist
   cd /
   sudo restic -r /mnt/nas-backup restore latest --path /persist

   # Restore /home
   sudo restic -r /mnt/nas-backup restore latest --path /home
   ```

3. **Deploy NixOS configuration:**

   ```bash
   # Clone your nix-config repo
   git clone https://github.com/carpenike/nix-config.git

   # Deploy configuration (this rebuilds /nix automatically)
   cd nix-config
   nixos-rebuild switch --flake .#forge
   ```

4. **Reboot:**

   ```bash
   sudo reboot
   ```

The system is now fully restored! The NixOS configuration rebuilds `/nix` automatically, while Restic restored all the actual state data.

#### Restore from Specific Snapshot

```bash
# List all snapshots with dates
restic -r /mnt/nas-backup snapshots

# Restore from specific snapshot (e.g., before a bad change)
restic -r /mnt/nas-backup restore abc123def \
  --target /tmp/restore \
  --path /persist/var/lib/plex
```

#### Restore with Exclusions

```bash
# Restore Plex but exclude cache
restic -r /mnt/nas-backup restore latest \
  --target /tmp/restore \
  --path /persist/var/lib/plex \
  --exclude '*/Cache/*' \
  --exclude '*/Logs/*'
```

## Troubleshooting

### NFS Mount Issues

```bash
# Check NFS mount
mount | grep nas-backup

# Manually mount
sudo mount -t nfs nas-1.holthome.net:/mnt/backup/forge/restic /mnt/nas-backup

# Check network connectivity
ping nas-1.holthome.net
showmount -e nas-1.holthome.net
```

### Backup Failures

```bash
# View detailed logs
sudo journalctl -u restic-backups-system.service -n 100

# Check error analysis
cat /var/log/backup/error-analysis.jsonl | jq .

# Manual backup test
sudo -u restic-backup restic -r /mnt/nas-backup snapshots
```

### Repository Issues

```bash
# Check repository integrity
restic -r /mnt/nas-backup check

# Verify data (slow but thorough)
restic -r /mnt/nas-backup check --read-data

# Unlock repository if locked
restic -r /mnt/nas-backup unlock
```

### Performance Issues

```bash
# Check I/O scheduling
systemctl show restic-backups-system.service | grep -i io

# Monitor resource usage during backup
sudo systemd-cgtop

# Check cache size
du -sh /var/cache/restic
```

## Security

### Encryption

- All backups are encrypted at rest using Restic's built-in encryption
- Password stored securely via SOPS
- Only accessible by the `restic-backup` user

### Access Control

- Backup service runs as dedicated `restic-backup` user
- SystemD security hardening enabled
- NFS mount with `no_root_squash` (required for backup user access)

### Secrets Management

- Restic password managed via SOPS with AGE encryption
- SSH keys for NixOS deployment secure the secrets access
- Never commit plaintext passwords

## Adding Additional Backup Nodes

To replicate this backup setup for other systems (e.g., luna, cluster-0), follow this pattern:

### 1. On nas-1: Create ZFS Datasets

For each new node, create dedicated datasets:

```bash
# Replace "nodename" with the actual hostname
NODE=nodename

# Create parent dataset
sudo zfs create backup/$NODE

# Create Restic dataset
sudo zfs create backup/$NODE/restic
sudo zfs set compression=lz4 backup/$NODE/restic
sudo zfs set atime=off backup/$NODE/restic
sudo zfs set quota=300G backup/$NODE/restic  # Adjust size as needed
sudo zfs set recordsize=1M backup/$NODE/restic

# Create ZFS replication dataset (optional, for Phase 2)
sudo zfs create backup/$NODE/zfs-recv
sudo zfs set compression=lz4 backup/$NODE/zfs-recv
sudo zfs set atime=off backup/$NODE/zfs-recv
sudo zfs set quota=500G backup/$NODE/zfs-recv  # Adjust size as needed
sudo zfs set readonly=on backup/$NODE/zfs-recv
```

### 2. On nas-1: Configure NFS Export

```bash
# Add NFS export for the node
echo "/backup/$NODE/restic $NODE.holthome.net(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports

# Reload NFS exports
sudo exportfs -ra
```

### 3. On the Node: Copy Configuration Files

```bash
cd /Users/ryan/src/nix-config

# Copy forge configuration as a template
cp hosts/forge/backup.nix hosts/$NODE/backup.nix

# Update the NFS mount path in the new backup.nix:
# Change: device = "nas-1.holthome.net:/backup/forge/restic"
# To:     device = "nas-1.holthome.net:/backup/$NODE/restic"
```

### 4. On the Node: Generate Secrets

```bash
# Generate Restic password
RESTIC_PASSWORD=$(openssl rand -base64 32)
echo "Generated Restic password for $NODE: $RESTIC_PASSWORD"

# Edit SOPS secrets file
sops hosts/$NODE/secrets.sops.yaml

# Add this section:
# restic:
#   password: <paste the generated password>
```

### 5. On the Node: (Optional) Set Up ZFS Replication

If you want ZFS send/recv replication:

```bash
# Copy ZFS replication configuration
cp hosts/forge/zfs-replication.nix hosts/$NODE/zfs-replication.nix

# Generate SSH key pair
ssh-keygen -t ed25519 -f /tmp/zfs-replication-$NODE -C "zfs-replication@$NODE" -N ""

# Document the public key
cat /tmp/zfs-replication-$NODE.pub >> hosts/$NODE/ssh-keys.md

# Add the private key to SOPS
sops hosts/$NODE/secrets.sops.yaml
# Add:
# zfs-replication:
#   ssh-key: |
#     <paste contents of /tmp/zfs-replication-$NODE>

# Clean up temporary files
rm /tmp/zfs-replication-$NODE*
```

### 6. On nas-1: Add ZFS Replication User (Optional)

If setting up ZFS replication:

```bash
# Add the node's public key to authorized_keys
NODE_PUBKEY="<paste from hosts/$NODE/ssh-keys.md>"

sudo tee -a /var/lib/zfs-replication/.ssh/authorized_keys > /dev/null <<EOF
command="zfs recv -F backup/$NODE/zfs-recv",no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc $NODE_PUBKEY
EOF

# Grant ZFS permissions
sudo zfs allow zfs-replication receive,create,mount,hold backup/$NODE/zfs-recv
```

### 7. Deploy and Test

```bash
# Build and deploy to the node
nixos-rebuild switch --flake .#$NODE --target-host $NODE.holthome.net

# Test the backup
ssh $NODE.holthome.net 'sudo systemctl start restic-backups-system.service'

# Verify
ssh $NODE.holthome.net 'restic -r /mnt/nas-backup snapshots'
```

## Future Enhancements

### Phase 2: ZFS Replication

Consider adding ZFS send/recv replication for:

- Bare-metal restore capability
- Block-level backup efficiency
- Faster full system recovery

Implementation would use `backup/forge/zfs-recv` dataset on nas-1.

### Additional Repositories

Add cloud backup as secondary repository:

```nix
repositories = {
  nas-primary = { ... };
  cloud-secondary = {
    url = "b2:bucket-name:/forge";
    passwordFile = config.sops.secrets."restic/password".path;
    environmentFile = config.sops.secrets."restic/b2-credentials".path;
    primary = false;
  };
};
```

## References

- [Restic Documentation](https://restic.readthedocs.io/)
- [NixOS Restic Module](https://search.nixos.org/options?query=services.restic)
- [ZFS Best Practices](https://openzfs.github.io/openzfs-docs/)
