# Bootstrap New NixOS Host - Quick Reference

## Overview

This guide covers the manual process for bootstrapping a new NixOS host in your homelab. For occasional deployments (2-3 hosts/year), this manual approach is more flexible and maintainable than complex automation.

**Estimated Time:** ~25 minutes (mostly waiting for builds)

## Prerequisites

- NixOS LiveCD booted on target hardware
- Network connectivity to GitHub and NixOS cache
- SSH access configured (if deploying remotely)

## Step-by-Step Process

### 1. Boot LiveCD and Setup SSH Access (if deploying remotely)

**On the LiveCD**, set a password for the `nixos` user to enable SSH access:

```fish
# Set password for nixos user
sudo passwd nixos

# Start SSH service (usually already running)
sudo systemctl start sshd

# Get the IP address
ip addr show
```

**From your development machine**, you can now SSH in:

```fish
ssh nixos@<livecd-ip-address>
```

### 2. Format Disks with Disko

**For existing hosts** (forge, luna, etc.), disko can pull the config directly from GitHub:

```fish
# Format disks using the host's disko-config.nix from GitHub
# Replace 'forge' with your target hostname
sudo nix run --extra-experimental-features "nix-command flakes" \
  github:nix-community/disko -- --mode disko --flake github:carpenike/nix-config#forge
```

**For new hosts**, you'll need to create a disko-config.nix first, then either:

- Push to GitHub and use the command above
- Use a local file: `sudo nix run --extra-experimental-features "nix-command flakes" github:nix-community/disko -- --mode disko /path/to/disko-config.nix`

**Note:** If testing first, you can use `--mode format` for a dry-run without actually writing to disks.

### 3. Create Host Directory (if new host)

**Skip this step if deploying an existing host like forge or luna.**

For a brand new host, you'll need to create the host configuration on your development machine first:

```fish
# Copy the bootstrap template
cp -r hosts/nixos-bootstrap hosts/newhostname

# Edit the host configuration
cd hosts/newhostname

# Generate a unique hostId (ZFS requirement - must be unique per host)
head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
# Example output: 1b3031e7
```

**Required changes in `default.nix`:**

```nix
# Update hostname
networking.hostName = "newhostname";

# Use the hostId you just generated
networking.hostId = "1b3031e7";  # Replace with YOUR generated ID

# Update disk paths if different hardware
boot.loader.grub.devices = [ "/dev/sda" ];  # Adjust as needed

# Update disko-config.nix if disk layout differs
```

**IMPORTANT:** You must generate the hostId and update the config BEFORE proceeding to step 4.

### 4. Register Host in flake.nix (for new hosts)

**Skip this step if deploying an existing host.**

Add your new host to the `nixosConfigurations` section in `flake.nix`, commit, and push to GitHub:

```nix
# In flake.nix, around line 130-140
nixosConfigurations = {
  # ... existing hosts ...

  newhostname = mkSystemLib.mkNixosSystem "x86_64-linux" "newhostname";
};
```

**Validate and push:**

```fish
nix flake check
git add .
git commit -m "feat: add newhostname configuration"
git push
```

### 5. Install Bootstrap Configuration (without secrets)

**From the LiveCD** (or SSH'd into `nixos@livecd-ip`), install directly from GitHub:

```fish
# Install using nixos-bootstrap configuration (no SOPS secrets required)
nixos-install --flake github:carpenike/nix-config#nixos-bootstrap --root /mnt --no-root-password
```

**Note:** We use `nixos-bootstrap` because it doesn't have SOPS-encrypted secrets. This config (and all subsequent host configs) will create user `ryan` with sudo access. You'll deploy the full config after registering the SSH key.

### 6. Reboot and Verify Boot

```fish
sudo reboot
```

**Verify the system boots successfully:**

- Check ZFS pools imported correctly: `zpool list`
- Check datasets mounted: `zfs list`
- Verify network connectivity: `ping 1.1.1.1`

### 7. Extract SSH Host Key and Register with SOPS

**On the newly booted host** (SSH as user `ryan` that was created during install), extract the SSH host key and convert to age format:

```fish
# SSH into the new host as ryan
ssh ryan@newhostname.holthome.net

# Run this command directly on the host
nix-shell -p ssh-to-age --run 'cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age'
```

**Alternative from your development machine:**

```fish
# Extract remotely via SSH (as user ryan)
ssh ryan@newhostname.holthome.net 'nix-shell -p ssh-to-age --run "cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age"'

# Or use the Taskfile helper (uses ryan by default):
task bootstrap:extract-ssh-key host=newhostname
```

**Copy the age public key output** (starts with `age1...`)

**Add to `.sops.yaml`:**
```yaml
creation_rules:
  - path_regex: secrets/[^/]+\.sops\.ya?ml$
    key_groups:
      - age:
          - age1... # your admin key
          - age1... # forge host key
          - age1... # NEW HOST KEY - add here
```

**Re-encrypt all secrets:**
```fish
task sops:re-encrypt
```

**Commit the changes:**
```fish
git add .sops.yaml
git commit -m "feat: add newhostname to SOPS recipients"
git push
```

### 8. Deploy Full Configuration

Now that SOPS can decrypt secrets on the new host:

```fish
# Build and deploy the full configuration from your dev machine
# This uses 'ryan' user that was created during bootstrap install
task nix:apply-nixos host=newhostname

# Or manually using GitHub flake:
nixos-rebuild switch --flake github:carpenike/nix-config#newhostname \
  --target-host ryan@newhostname.holthome.net \
  --build-host ryan@newhostname.holthome.net
```

**Note:** Both `nixos-bootstrap` and all host-specific configs create user `ryan` with sudo access. Use `ryan@hostname` for all deployments after the initial install.

### 9. Verify Services

SSH into the new host and verify critical services:

```fish
ssh root@newhostname.holthome.net

# Check systemd services
systemctl status

# Verify monitoring agent (if configured)
systemctl status prometheus-node-exporter

# Check ZFS health
zpool status

# Verify datasets
zfs list
```

## Common Issues and Solutions

### Issue: "Parent dataset does not exist" on boot

**Solution:** The activation script now auto-creates parent datasets with a 30-second pool import wait. If you still see this:
1. Boot to LiveCD
2. Import pools manually: `zpool import -f poolname`
3. Create parent dataset: `zfs create -p -o mountpoint=none poolname/parent`
4. Reboot

### Issue: SOPS secrets fail to decrypt

**Causes:**
- SSH host key not added to `.sops.yaml`
- Secrets not re-encrypted after adding key
- Wrong age key format (needs to start with `age1`)

**Solution:**
```fish
# Verify the host's age key is in .sops.yaml
cat .sops.yaml | grep "age1"

# Re-encrypt all secrets
task sops:re-encrypt

# Redeploy
task nix:apply-nixos host=newhostname
```

### Issue: Disk layout detection fails

**Solution:** Check your disko-config.nix matches actual hardware:
```fish
# List available disks
lsblk

# Update disko-config.nix device paths
# Then re-run disko
sudo nix run github:nix-community/disko -- --mode disko /path/to/disko-config.nix
```

## Tips and Best Practices

### Generating Unique hostId

```fish
# ZFS requires unique hostId across systems
head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
```

### Testing Configuration Changes

```fish
# Build without deploying (syntax check)
nix build .#nixosConfigurations.newhostname.config.system.build.toplevel

# Test in VM before deploying
task nix:test-vm host=newhostname
```

### Backing Up Before Major Changes

```fish
# Create a ZFS snapshot before risky operations
zfs snapshot -r rpool@pre-rebuild
zfs snapshot -r tank@pre-rebuild

# Rollback if needed
zfs rollback rpool@pre-rebuild
```

### Remote Debugging

```fish
# View remote logs during deployment (user ryan)
ssh ryan@newhostname journalctl -f

# Check activation script output
ssh ryan@newhostname systemctl status --failed
```

## Quick Reference Commands

| Task | Command |
|------|---------|
| LiveCD: Set password | `sudo passwd nixos` (enables SSH to `nixos@livecd-ip`) |
| Format disks (existing host) | `sudo nix run --extra-experimental-features "nix-command flakes" github:nix-community/disko -- --mode disko --flake github:carpenike/nix-config#HOSTNAME` |
| Install bootstrap | `nixos-install --flake github:carpenike/nix-config#nixos-bootstrap --root /mnt --no-root-password` |
| SSH after install | `ssh ryan@HOSTNAME.holthome.net` (user `ryan` created by bootstrap) |
| Extract SSH key (on host) | `nix-shell -p ssh-to-age --run 'cat /etc/ssh/ssh_host_ed25519_key.pub \| ssh-to-age'` |
| Extract SSH key (remote) | `task bootstrap:extract-ssh-key host=HOSTNAME` (uses `ryan` user) |
| Re-encrypt secrets | `task sops:re-encrypt` |
| Deploy full config | `task nix:apply-nixos host=HOSTNAME` (uses `ryan` user) |
| Check flake | `nix flake check` |
| Test VM | `task nix:test-vm host=HOSTNAME` |

## Next Steps After Bootstrap

1. **Configure monitoring** - Ensure node_exporter is reporting to Prometheus
2. **Set up backups** - Configure Sanoid/Syncoid for ZFS replication
3. **Test disaster recovery** - Verify you can restore from backups
4. **Document host-specific quirks** - Note any hardware-specific configuration in `hosts/HOSTNAME/README.md`

## Related Documentation

- [SOPS Secrets Management](./shared-config-example.md)
- [Storage Module Guide](./storage-module-guide.md)
- [ZFS Replication Setup](./zfs-replication-setup.md)
- [Persistence Quick Reference](./persistence-quick-reference.md)
