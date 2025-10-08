# nas-1 NixOS Migration TODOs

This document tracks configuration items needed when migrating nas-1 from Ubuntu to NixOS.

## Status

- **Current OS**: Ubuntu 24.04 LTS
- **Target OS**: NixOS (planned migration)
- **Purpose**: Primary backup destination and NFS server

## Required Configuration

### 1. ZFS Replication User Setup

**Status**: ⏳ TODO

Configure the `zfs-replication` user to receive snapshots from forge.

```nix
# hosts/nas-1/zfs-replication.nix
{ ... }:

{
  # Create zfs-replication user for receiving snapshots
  users.users.zfs-replication = {
    isSystemUser = true;
    group = "zfs-replication";
    home = "/var/lib/zfs-replication";
    createHome = true;
    shell = "/run/current-system/sw/bin/bash";  # IMPORTANT: Needs a working shell for syncoid
    openssh.authorizedKeys.keys = [
      # SSH key from forge's zfs-replication user
      # Note: no-agent-forwarding and no-X11-forwarding for security
      # DO NOT add a forced command - syncoid needs to run multiple commands
      "no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4aPwHeW7/p2YcKI41srC8X6Cw2D6e5mCbQuVp0USW1 zfs-replication@forge"
    ];
  };

  users.groups.zfs-replication = {};

  # Grant ZFS permissions for receiving snapshots
  # Note: This needs to run after ZFS pools are imported
  systemd.services.zfs-delegate-permissions-receive = {
    description = "Delegate ZFS permissions for receiving replication";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" "systemd-sysusers.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Grant receive permissions for forge backups
      /run/current-system/sw/bin/zfs allow zfs-replication \
        compression,create,mount,mountpoint,receive,rollback \
        backup/forge/zfs-recv

      echo "ZFS receive permissions applied successfully"
    '';
  };
}
```

**Important Notes**:

- **Shell**: User needs a working shell (e.g., `/bin/bash`), NOT `/usr/sbin/nologin`
  - Syncoid needs to execute commands like `zfs list`, `zfs receive`, etc.
  - With `nologin`, SSH connections hang waiting for input

- **SSH Authorized Keys**: DO NOT use forced commands in `authorized_keys`
  - ❌ BAD: `command="zfs recv -F backup/forge/zfs-recv"` (blocks syncoid's echo tests)
  - ✅ GOOD: `no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3...`
  - Syncoid needs to run multiple commands, not just `zfs receive`
  - Security is maintained through SSH key restrictions and ZFS delegated permissions

**Manual Steps Replaced**:

- ✅ User creation: `useradd -r -s /usr/sbin/nologin zfs-replication` (NOTE: needs bash shell!)
- ✅ SSH key authorization: Adding public key to `~/.ssh/authorized_keys`
- ✅ ZFS permissions: `zfs allow` commands
- ✅ Shell fix: Changed from `/usr/sbin/nologin` to `/usr/bin/bash`
- ✅ Authorized keys fix: Removed forced command restriction

**Validation**:

```bash
# Verify user exists
getent passwd zfs-replication

# Verify ZFS permissions
zfs allow backup/forge/zfs-recv

# Test SSH from forge
ssh -i /var/lib/zfs-replication/.ssh/id_ed25519 zfs-replication@nas-1.holthome.net 'echo OK'
```

---

### 2. Sanoid for Replicated Snapshot Pruning

**Status**: ⏳ TODO

Configure sanoid on nas-1 to prune old replicated snapshots from forge.

```nix
# hosts/nas-1/sanoid.nix
{ lib, ... }:

{
  # Create static sanoid user (don't use DynamicUser)
  users.users.sanoid = {
    isSystemUser = true;
    group = "sanoid";
    description = "Sanoid ZFS snapshot management user";
  };

  users.groups.sanoid = {};

  # Override sanoid service to use static user
  systemd.services.sanoid.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "sanoid";
    Group = "sanoid";
  };

  # Grant ZFS permissions for sanoid
  systemd.services.zfs-delegate-permissions-sanoid = {
    description = "Delegate ZFS permissions for Sanoid pruning";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" "systemd-sysusers.service" ];
    before = [ "sanoid.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Grant permissions for managing replicated snapshots
      /run/current-system/sw/bin/zfs allow sanoid \
        destroy,hold,send,snapshot \
        backup/forge/zfs-recv

      echo "Sanoid ZFS permissions applied successfully"
    '';
  };

  # Configure sanoid to prune replicated snapshots
  services.sanoid = {
    enable = true;

    templates = {
      replicated = {
        hourly = 24;       # Match forge's retention
        daily = 7;
        weekly = 4;
        monthly = 3;
        yearly = 0;
        autosnap = false;  # DON'T create new snapshots (only prune)
        autoprune = true;  # DO prune old snapshots
      };
    };

    datasets = {
      "backup/forge/zfs-recv/home" = {
        useTemplate = [ "replicated" ];
        recursive = false;
      };

      "backup/forge/zfs-recv/persist" = {
        useTemplate = [ "replicated" ];
        recursive = false;
      };
    };
  };
}
```

**Why This Is Needed**:

- Syncoid does NOT prune snapshots on the destination
- Without pruning, snapshots accumulate indefinitely on nas-1
- Sanoid with `autosnap = false` prunes without creating new snapshots
- Matches forge's retention policy (24h/7d/4w/3m)

**Validation**:

```bash
# Check sanoid is pruning (not creating)
zfs list -t snapshot backup/forge/zfs-recv/home | wc -l
# Should stabilize at ~38 snapshots (24 hourly + 7 daily + 4 weekly + 3 monthly)

# Verify no new local snapshots being created
zfs list -t snapshot backup/forge/zfs-recv/home | grep -v autosnap
# Should only show snapshots replicated from forge
```

---

### 3. ZFS Dataset Configuration

**Status**: ⏳ TODO

Ensure ZFS datasets are created with proper properties.

```nix
# hosts/nas-1/zfs-datasets.nix
{ ... }:

{
  # Note: Dataset creation might need to be done via boot.postBootCommands
  # or a similar mechanism if not already created

  boot.postBootCommands = ''
    # Ensure backup datasets exist with correct properties
    if ! zfs list backup/forge >/dev/null 2>&1; then
      zfs create backup/forge
      zfs set compression=lz4 backup/forge
      zfs set atime=off backup/forge
    fi

    if ! zfs list backup/forge/restic >/dev/null 2>&1; then
      zfs create backup/forge/restic
      zfs set recordsize=1M backup/forge/restic
      zfs set quota=500G backup/forge/restic
    fi

    if ! zfs list backup/forge/zfs-recv >/dev/null 2>&1; then
      zfs create backup/forge/zfs-recv
      zfs set canmount=off backup/forge/zfs-recv
    fi
  '';
}
```

**Current Manual Configuration**:

```bash
# Already created on nas-1:
zfs create backup/forge
zfs create backup/forge/restic
zfs create backup/forge/zfs-recv
zfs set compression=lz4 backup/forge
zfs set atime=off backup/forge
zfs set recordsize=1M backup/forge/restic
zfs set quota=500G backup/forge/restic
zfs set canmount=off backup/forge/zfs-recv
```

---

### 4. NFS Server Configuration

**Status**: ⏳ TODO

Configure NFS exports for Restic backup repository.

```nix
# hosts/nas-1/nfs.nix
{ ... }:

{
  services.nfs.server = {
    enable = true;
    exports = ''
      # Restic backup repository for forge
      /mnt/backup/forge/restic  forge.holthome.net(rw,sync,no_subtree_check,root_squash,anonuid=1001,anongid=1001)
    '';
  };

  # Ensure NFS services start after ZFS
  systemd.services.nfs-server = {
    after = [ "zfs-import.target" ];
    wants = [ "zfs-import.target" ];
  };

  # Open firewall for NFS
  networking.firewall.allowedTCPPorts = [ 111 2049 ];
  networking.firewall.allowedUDPPorts = [ 111 2049 ];
}
```

**Current Manual Configuration**:

```bash
# /etc/exports on nas-1:
/mnt/backup/forge/restic  forge.holthome.net(rw,sync,no_subtree_check,root_squash,anonuid=1001,anongid=1001)
```

---

### 5. Network Configuration

**Status**: ⏳ TODO

Configure static IP and hostname.

```nix
# hosts/nas-1/network.nix
{ ... }:

{
  networking = {
    hostName = "nas-1";
    domain = "holthome.net";

    # Static IP configuration
    interfaces.eno1 = {  # Adjust interface name as needed
      ipv4.addresses = [{
        address = "10.20.0.11";
        prefixLength = 24;
      }];
    };

    defaultGateway = "10.20.0.1";
    nameservers = [ "10.20.0.1" ];
  };
}
```

---

### 6. SSH Configuration

**Status**: ⏳ TODO

Harden SSH and allow key-based authentication.

```nix
# hosts/nas-1/ssh.nix
{ ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Your admin SSH key
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3... your-admin-key"
  ];
}
```

---

## Troubleshooting Guide

### SSH Connection Hangs

**Symptom**: `ssh zfs-replication@nas-1` hangs with blank screen, syncoid reports "failed to read from stream"

**Causes**:

1. User shell set to `/usr/sbin/nologin` or similar
2. Forced command in `authorized_keys` blocking interactive commands

**Solution**:

```bash
# Check current shell
getent passwd zfs-replication

# Fix shell (Ubuntu path)
sudo usermod -s /usr/bin/bash zfs-replication

# Check authorized_keys for forced command
sudo cat /var/lib/zfs-replication/.ssh/authorized_keys

# Remove forced command, keep security restrictions
# BAD:  command="zfs recv ..." ssh-ed25519 AAAAC3...
# GOOD: no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3...
```

### Syncoid "Identity file not accessible"

**Symptom**: Service logs show "Warning: Identity file /var/lib/zfs-replication/.ssh/id_ed25519 not accessible"

**Cause**: systemd sandboxing with `PrivateMounts=true` blocks symlink resolution across mount namespaces

**Solution**: Add both symlink source and target to `BindReadOnlyPaths`:

```nix
systemd.services.syncoid-*.serviceConfig = {
  BindReadOnlyPaths = lib.mkForce [
    "/nix/store"
    "/etc"
    "/bin/sh"
    "/var/lib/zfs-replication/.ssh"      # Symlink source
    "/run/secrets/zfs-replication"       # Symlink target
  ];
};
```

**Why**: `ReadOnlyPaths` alone doesn't work for symlinks when `PrivateMounts=true`. Both ends of the symlink must be explicitly bound into the service's mount namespace.

### ZFS Receive Permission Denied

**Symptom**: "cannot receive: permission denied"

**Cause**: Missing ZFS delegated permissions

**Solution**:

```bash
# Grant all necessary permissions at once
zfs allow zfs-replication \
  compression,create,hold,mount,mountpoint,receive,rollback \
  backup/forge/zfs-recv

# Verify
zfs allow backup/forge/zfs-recv
```

---

## Integration Checklist

When migrating nas-1 to NixOS:

- [ ] Create `hosts/nas-1/default.nix` with hardware configuration
- [ ] Import all configuration modules listed above
- [ ] Configure ZFS pools in hardware configuration
- [ ] Verify zfs-replication user shell is set to bash (not nologin)
- [ ] Ensure authorized_keys has NO forced commands
- [ ] Test SSH connectivity: `ssh zfs-replication@nas-1 'echo OK'`
- [ ] Test ZFS replication from forge
- [ ] Verify sanoid pruning on nas-1 (after 48h, check snapshot count stabilizes)
- [ ] Test NFS mounts from forge
- [ ] Validate backup and restore workflows
- [ ] Update documentation with nas-1 specific notes

## Related Documentation

- [ZFS Replication Setup](../../docs/zfs-replication-setup.md)
- [Backup System Onboarding](../../docs/backup-system-onboarding.md)
- [NFS Mount Management](../../docs/nfs-mount-management.md)

## Notes

- nas-1 is currently running Ubuntu 24.04 LTS
- All manual configuration should be tracked here for later automation
- When migrating to NixOS, ensure all datasets and data are preserved
- Consider using a test VM to validate configuration before production migration
