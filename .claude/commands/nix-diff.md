# /nix-diff

Compare system generations on target hosts to understand deployment changes.

## Usage

```
/nix-diff host=<hostname> [rev1=<revision>] [rev2=<revision>]
```

## Parameters

- `host` (required): Host to inspect
- `rev1` (optional): First revision to compare (default: `current`)
- `rev2` (optional): Second revision to compare (default: `previous`)

## Examples

```bash
# Compare current vs previous generation
/nix-diff host=luna

# Compare specific generations
/nix-diff host=luna rev1=current rev2=previous

# Compare with specific generation number
/nix-diff host=rydev rev1=current rev2=generation-42
```

## Implementation

### Default comparison (current vs previous)
```bash
# SSH into the target host
ssh ryan@{hostname}.bjw-s.internal

# On the target host, run:
nix-diff /nix/var/nix/profiles/system-*-link | head -50
```

### Specific generation comparison
```bash
# SSH into the target host
ssh ryan@{hostname}.bjw-s.internal

# Compare specific system generations
nix-diff /nix/var/nix/profiles/system-{rev1}-link /nix/var/nix/profiles/system-{rev2}-link
```

## System Generation Locations

### NixOS Systems
- **Current**: `/run/current-system`
- **Profiles**: `/nix/var/nix/profiles/system-*-link`
- **Boot entries**: `/boot/loader/entries/` (systemd-boot)

### Common Generation References
- `current` → `/run/current-system`
- `previous` → Previous system profile link
- `generation-N` → `/nix/var/nix/profiles/system-N-link`

## Output Interpretation

### Package Changes
```
+ package-name-1.2.3    # Added package
- package-name-1.2.2    # Removed package
package-name: 1.2.2 → 1.2.3    # Version change
```

### Configuration Changes
```
/etc/systemd/system/service.service    # Service configuration changed
/etc/nixos/configuration.nix           # System configuration modified
```

### Size Impact
```
Closure size: 2.1G → 2.3G (+200M)      # Disk usage change
```

## Use Cases

### Deployment Verification
- **Post-deployment**: Verify expected changes were applied
- **Unexpected behavior**: Identify what changed in problematic deployments
- **Rollback planning**: Understand what will change when rolling back

### System Maintenance
- **Package updates**: See exactly which packages were updated
- **Security patches**: Identify security-related package changes
- **Configuration drift**: Compare configurations over time

### Troubleshooting
- **Service failures**: Check if service configurations changed
- **Performance issues**: Identify new packages or configuration changes
- **Boot problems**: Compare system configurations before boot issues

## Remote Execution

Since this requires running on the target host:

1. **SSH access**: Ensure you can SSH to `ryan@{hostname}.bjw-s.internal`
2. **nix-diff availability**: Tool should be available in system PATH
3. **Generation access**: User needs read access to `/nix/var/nix/profiles/`

## Alternative Approaches

### Local Comparison (if builds are local)
```bash
# Compare local build results
nix-diff result-old result-new
```

### Generation Listing
```bash
# On target host - list available generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
```

## Notes

- **Run on target host**: This command requires execution on the deployed system
- **Generation cleanup**: Old generations may be garbage collected
- **Large outputs**: Pipe through `head` or `less` for readability
- **Boot verification**: Compare with known-good configurations when troubleshooting boot issues
- **Security auditing**: Use to verify security update deployments
