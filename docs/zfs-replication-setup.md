# ZFS Replication Setup for Forge → nas-1

This document covers the **Phase 2** ZFS send/recv replication setup for bare-metal recovery capability.

## Overview

This setup provides block-level ZFS snapshot replication from forge to nas-1, complementing the file-based Restic backups configured in Phase 1.

## Architecture

```
forge (source)                           nas-1 (destination)
├── zfs-replication user                 ├── zfs-replication user
│   ├── SSH private key (SOPS)           │   ├── SSH public key (authorized_keys)
│   └── ZFS delegated permissions        │   └── ZFS delegated permissions
│       - send                            │       - receive
│       - snapshot                        │       - create
│       - hold                            │       - mount
│                                         │       - hold
├── ZFS datasets:                        │
│   ├── rpool/safe/home                  └── backup/forge/zfs-recv/
│   ├── rpool/safe/persist                   └── (receives replicated snapshots)
│   └── rpool/local/nix
│
└── Manual or scheduled replication
    using native zfs send/recv
```

## Security Model

### Non-Root Operation
- Uses dedicated `zfs-replication` service user (not root)
- ZFS permissions delegated via `zfs allow`
- No sudo or elevated privileges required

### SSH Key Restrictions
- ed25519 key type (modern, secure)
- No passphrase (required for automation)
- Command restriction in authorized_keys: only `zfs recv` allowed
- Additional restrictions: no-pty, no-agent-forwarding, no-X11-forwarding

### Key Management
- Private key encrypted with SOPS/age
- Deployed declaratively via NixOS configuration
- Stored in `/var/lib/zfs-replication/.ssh/` with 0600 permissions

## Setup Instructions

### Step 1: Generate SSH Key Pair

Run the setup script on your local machine:

```bash
cd /Users/ryan/src/nix-config
chmod +x scripts/setup-zfs-replication-key.sh
./scripts/setup-zfs-replication-key.sh
```

This will:
- Generate an ed25519 SSH key pair
- Add the private key to `hosts/forge/secrets.sops.yaml`
- Display the public key for nas-1 configuration

### Step 2: Configure nas-1

Add the zfs-replication user to nas-1's configuration:

```nix
# In nas-1's configuration.nix or a separate module

users.users.zfs-replication = {
  isSystemUser = true;
  group = "zfs-replication";
  home = "/var/lib/zfs-replication";
  createHome = true;
  shell = pkgs.nologin;
  description = "ZFS replication receiver";
  openssh.authorizedKeys.keys = [
    # Add the public key from step 1 with command restriction
    ''command="zfs recv -F backup/forge/zfs-recv",no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA... zfs-replication@forge''
  ];
};

users.groups.zfs-replication = {};
```

Deploy to nas-1:
```bash
# Adjust based on your deployment method
nixos-rebuild switch --flake .#nas-1 --target-host nas-1.holthome.net
```

### Step 3: Grant ZFS Permissions

#### On nas-1 (destination):
```bash
ssh nas-1.holthome.net
sudo zfs allow zfs-replication receive,create,mount,hold backup/forge/zfs-recv
```

Verify:
```bash
sudo zfs allow backup/forge/zfs-recv
```

#### On forge (source):
```bash
ssh forge.holthome.net
sudo zfs allow zfs-replication send,snapshot,hold rpool
sudo zfs allow zfs-replication send,snapshot,hold tank  # if you have tank
```

Verify:
```bash
sudo zfs allow rpool
sudo zfs allow tank  # if applicable
```

### Step 4: Deploy forge Configuration

```bash
cd /Users/ryan/src/nix-config
nixos-rebuild switch --flake .#forge --target-host forge.holthome.net
```

### Step 5: Test SSH Connection

From forge:
```bash
sudo -u zfs-replication ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 zfs-replication@nas-1.holthome.net
```

You should see: `zfs receive -F ...` followed by an error (because we didn't send any data). This confirms the command restriction is working.

## Manual Replication

### Initial Full Replication

For the first replication, send a full snapshot:

```bash
# On forge, as root or with sudo

# Create initial snapshot
zfs snapshot rpool/safe/home@initial-$(date +%Y%m%d)

# Send to nas-1
zfs send rpool/safe/home@initial-$(date +%Y%m%d) | \
  ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 \
  zfs-replication@nas-1.holthome.net \
  zfs recv -F backup/forge/zfs-recv/home
```

Repeat for other datasets:
```bash
zfs snapshot rpool/safe/persist@initial-$(date +%Y%m%d)
zfs send rpool/safe/persist@initial-$(date +%Y%m%d) | \
  ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 \
  zfs-replication@nas-1.holthome.net \
  zfs recv -F backup/forge/zfs-recv/persist
```

### Incremental Replication

After the initial sync, use incremental sends:

```bash
# Create new snapshot
zfs snapshot rpool/safe/home@incr-$(date +%Y%m%d-%H%M)

# Send incremental
zfs send -i rpool/safe/home@initial-20251008 rpool/safe/home@incr-$(date +%Y%m%d-%H%M) | \
  ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 \
  zfs-replication@nas-1.holthome.net \
  zfs recv -F backup/forge/zfs-recv/home
```

## Automated Replication (Future)

To automate replication, create a systemd service and timer:

```nix
# Future enhancement - add to hosts/forge/zfs-replication.nix

systemd.services.zfs-replicate = {
  description = "ZFS replication to nas-1";
  path = with pkgs; [ zfs openssh ];
  script = ''
    # Your replication script here
  '';
  serviceConfig = {
    Type = "oneshot";
    User = "root";  # Needed for zfs snapshot/send
  };
};

systemd.timers.zfs-replicate = {
  description = "ZFS replication timer";
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "daily";
    Persistent = true;
    RandomizedDelaySec = "30m";
  };
};
```

## Verification

### Check Replicated Datasets on nas-1

```bash
ssh nas-1.holthome.net
zfs list -r backup/forge/zfs-recv
zfs list -t snapshot -r backup/forge/zfs-recv
```

### Verify Snapshot Contents

Mount a snapshot to browse:
```bash
# On nas-1
sudo mount -t zfs backup/forge/zfs-recv/home@snapshot-name /mnt/test
ls -la /mnt/test
sudo umount /mnt/test
```

## Recovery Procedures

### Restore from ZFS Snapshot

To restore data from a replicated snapshot:

```bash
# On nas-1, send back to forge
zfs send backup/forge/zfs-recv/home@snapshot-name | \
  ssh forge.holthome.net zfs recv -F rpool/safe/home
```

### Bare-Metal Recovery

In a disaster recovery scenario:

1. Boot forge with NixOS installer
2. Recreate ZFS pool structure (or use disko)
3. Receive datasets from nas-1:
   ```bash
   zfs send backup/forge/zfs-recv/home@latest | zfs recv rpool/safe/home
   zfs send backup/forge/zfs-recv/persist@latest | zfs recv rpool/safe/persist
   ```
4. Rebuild NixOS system

## Troubleshooting

### SSH Connection Issues

```bash
# Test SSH with verbose output
sudo -u zfs-replication ssh -v -i /var/lib/zfs-replication/.ssh/id_ed25519 \
  zfs-replication@nas-1.holthome.net

# Check key permissions on forge
ls -la /var/lib/zfs-replication/.ssh/

# Check authorized_keys on nas-1
sudo cat /var/lib/zfs-replication/.ssh/authorized_keys  # if using files
# Or check NixOS config for openssh.authorizedKeys
```

### Permission Denied

```bash
# Verify ZFS permissions on source
sudo zfs allow rpool

# Verify ZFS permissions on destination
ssh nas-1.holthome.net sudo zfs allow backup/forge/zfs-recv
```

### Dataset Already Exists

If you get an error that the dataset exists:

```bash
# Use -F flag to force rollback on receive
zfs send ... | ssh ... zfs recv -F destination/dataset
```

### Check Replication Status

```bash
# Compare snapshots between source and destination
zfs list -t snapshot rpool/safe/home
ssh nas-1.holthome.net zfs list -t snapshot backup/forge/zfs-recv/home
```

## Best Practices

1. **Snapshot Naming**: Use consistent naming with timestamps
2. **Retention**: Define how long to keep snapshots on both sides
3. **Monitoring**: Track replication success/failure
4. **Testing**: Regularly test restore procedures
5. **Documentation**: Keep recovery runbooks updated
6. **Verification**: Periodically verify replicated data integrity

## Comparison: ZFS Replication vs Restic Backups

| Feature | ZFS send/recv | Restic |
|---------|--------------|---------|
| Speed | Very fast (block-level) | Slower (file-level) |
| Deduplication | Native ZFS dedup | Built-in |
| Encryption | ZFS native encryption | Built-in |
| Compression | ZFS compression | Built-in |
| Granularity | Dataset/snapshot level | File-level |
| Cross-platform restore | Requires ZFS | Any filesystem |
| Bare-metal recovery | Excellent | Good |
| Selective file restore | Good (via snapshots) | Excellent |
| Storage efficiency | Very good | Very good |

**Recommendation**: Use both for comprehensive protection:
- **Restic**: Daily file-based backups for easy file recovery
- **ZFS replication**: Weekly/daily dataset replication for fast system recovery

## Adding Additional Nodes

To set up ZFS replication for additional systems (e.g., luna, cluster-0), follow this pattern:

### 1. On nas-1: Create ZFS Replication Dataset

```bash
# Replace "nodename" with the actual hostname
NODE=nodename

# Create parent dataset if it doesn't exist
sudo zfs create backup/$NODE

# Create ZFS replication receive dataset
sudo zfs create backup/$NODE/zfs-recv
sudo zfs set compression=lz4 backup/$NODE/zfs-recv
sudo zfs set atime=off backup/$NODE/zfs-recv
sudo zfs set quota=500G backup/$NODE/zfs-recv  # Adjust size as needed
sudo zfs set readonly=on backup/$NODE/zfs-recv

# Grant ZFS permissions to the zfs-replication user
sudo zfs allow zfs-replication receive,create,mount,hold backup/$NODE/zfs-recv

# Verify
zfs list -o name,used,avail,refer,mountpoint,quota backup/$NODE/zfs-recv
sudo zfs allow backup/$NODE/zfs-recv
```

### 2. On the Node: Copy ZFS Replication Configuration

```bash
cd /Users/ryan/src/nix-config

# Copy forge configuration as a template
cp hosts/forge/zfs-replication.nix hosts/$NODE/zfs-replication.nix

# The configuration is generic and should work as-is
```

### 3. On Your Workstation: Generate SSH Key Pair

```bash
# Generate new SSH key pair for the node
ssh-keygen -t ed25519 -f /tmp/zfs-replication-$NODE -C "zfs-replication@$NODE" -N ""

# Display public key (save this for next step)
cat /tmp/zfs-replication-$NODE.pub
```

### 4. Document Public Key

```bash
# Create or append to the node's SSH keys documentation
cat /tmp/zfs-replication-$NODE.pub >> hosts/$NODE/ssh-keys.md

# Or create new file if it doesn't exist
echo "# SSH Keys for $NODE" > hosts/$NODE/ssh-keys.md
echo "" >> hosts/$NODE/ssh-keys.md
echo "## ZFS Replication" >> hosts/$NODE/ssh-keys.md
echo "" >> hosts/$NODE/ssh-keys.md
cat /tmp/zfs-replication-$NODE.pub >> hosts/$NODE/ssh-keys.md
```

### 5. Add Private Key to SOPS

```bash
# Edit the node's SOPS secrets file
sops hosts/$NODE/secrets.sops.yaml

# Add this section (paste the contents of the private key):
# zfs-replication:
#   ssh-key: |
#     -----BEGIN OPENSSH PRIVATE KEY----- # gitleaks:allow
#     <paste contents from /tmp/zfs-replication-$NODE>
#     -----END OPENSSH PRIVATE KEY-----

# Clean up temporary files
rm /tmp/zfs-replication-$NODE*
```

### 6. On nas-1: Add SSH Authorized Key

```bash
# Get the public key from the previous step
NODE_PUBKEY="<paste from hosts/$NODE/ssh-keys.md>"

# Add to zfs-replication user's authorized_keys with command restriction
sudo tee -a /var/lib/zfs-replication/.ssh/authorized_keys > /dev/null <<EOF
command="zfs recv -F backup/$NODE/zfs-recv",no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc $NODE_PUBKEY
EOF

# Verify permissions
sudo chmod 600 /var/lib/zfs-replication/.ssh/authorized_keys
sudo chown zfs-replication:zfs-replication /var/lib/zfs-replication/.ssh/authorized_keys
```

### 7. On the Node: Import Configuration

Edit `hosts/$NODE/default.nix` to import the ZFS replication module:

```nix
{
  imports = [
    # ... other imports
    ./zfs-replication.nix
  ];
}
```

### 8. Deploy and Test

```bash
# Build and deploy to the node
nixos-rebuild switch --flake .#$NODE --target-host $NODE.holthome.net

# Test SSH connection
ssh $NODE.holthome.net 'sudo -u zfs-replication ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 zfs-replication@nas-1.holthome.net'

# You should see: "zfs receive -F backup/$NODE/zfs-recv" followed by an error
# This confirms the command restriction is working correctly
```

### 9. Grant ZFS Permissions on the Source Node

```bash
# SSH to the node
ssh $NODE.holthome.net

# Grant ZFS send permissions to the zfs-replication user
# Adjust pool names as needed (rpool, tank, etc.)
sudo zfs allow zfs-replication send,snapshot,hold rpool

# If the node has additional pools:
# sudo zfs allow zfs-replication send,snapshot,hold tank

# Verify
sudo zfs allow rpool
```

### 10. Perform Initial Replication Test

```bash
# On the node, create a test snapshot
ssh $NODE.holthome.net 'sudo zfs snapshot rpool/safe/home@test-initial-$(date +%Y%m%d)'

# Send to nas-1
ssh $NODE.holthome.net "sudo zfs send rpool/safe/home@test-initial-\$(date +%Y%m%d) | \
  ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 \
  zfs-replication@nas-1.holthome.net \
  zfs recv -F backup/$NODE/zfs-recv/home"

# Verify on nas-1
ssh nas-1.holthome.net "zfs list -r backup/$NODE/zfs-recv"
```

## References

- [ZFS send/recv documentation](https://openzfs.github.io/openzfs-docs/man/8/zfs-send.8.html)
- [ZFS delegation](https://openzfs.github.io/openzfs-docs/man/8/zfs-allow.8.html)
- [NixOS ZFS options](https://search.nixos.org/options?query=zfs)
