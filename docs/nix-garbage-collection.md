# Nix Garbage Collection

This repository has automatic garbage collection configured for all hosts.

## Configuration

| Setting | Value | Location |
|---------|-------|----------|
| Automatic | Yes | `modules/common/nix.nix` |
| Retention | 30 days | `modules/common/nix.nix` |
| Schedule (NixOS) | Weekly | `modules/nixos/nix.nix` |
| Schedule (Darwin) | Sunday 2am | `modules/darwin/nix.nix` |

## How It Works

The garbage collector removes:
- Store paths not reachable from any GC root
- System generations older than 30 days

GC roots include:
- Current system profile
- User profiles
- Running processes
- Nix build results

## Manual Operations

### Check garbage amount
```bash
nix-store --gc --print-dead | wc -l
```

### Trigger GC manually
```bash
# On NixOS
sudo systemctl start nix-gc.service

# On Darwin
sudo launchctl kickstart system/org.nixos.nix-gc
```

### Check timer status
```bash
# NixOS
systemctl list-timers | grep gc

# Darwin
launchctl list | grep nix-gc
```

### Delete specific generations
```bash
# List generations
nix-env --list-generations

# Delete specific generation
nix-env --delete-generations 42

# Delete all but last N
nix-env --delete-generations +5
```

## Rollback

Even with GC enabled, you can rollback to any generation within the 30-day window:

```bash
# List available generations
nixos-rebuild list-generations

# Rollback to previous
sudo nixos-rebuild switch --rollback

# Boot into specific generation (from GRUB menu)
# Or switch to specific generation
sudo nix-env --switch-generation 42 -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

## Disk Space Settings

Additional disk protection in `modules/common/nix.nix`:

```nix
nix.settings = {
  max-free = 1000000000;  # 1GB - trigger GC when free space drops
  min-free = 128000000;   # 128MB - minimum to maintain during builds
};
```

This ensures builds fail gracefully rather than filling the disk completely.
