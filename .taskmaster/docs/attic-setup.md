# Attic Binary Cache Setup Guide

## Overview
This guide walks through completing the Attic binary cache setup on your luna server. The configuration has been added to your Nix flake and is ready for deployment.

## Prerequisites
- SSH access to luna.holthome.net
- NixOS configuration deployed successfully
- DNS pointing attic.holthome.net to luna server

## Deployment Steps

### 1. Deploy Attic Configuration
```bash
# From your nix-config directory on a machine that can reach luna
task nix:apply-nixos host=luna
```

### 2. Initialize Attic Cache
SSH to luna and run these commands:

```bash
# Check Attic server is running
sudo systemctl status atticd

# Create the cache (this generates the signing keys automatically)
attic cache create homelab

# Get the public key for client configuration
attic cache info homelab
```

### 3. Update Client Configuration
Copy the public key from step 2 and update the binary cache configuration:

**Edit:** `hosts/_modules/common/binary-cache.nix`
```nix
trusted-public-keys = [
  "homelab:PASTE_PUBLIC_KEY_HERE"  # Replace with actual key from attic cache info
  "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
];
```

### 4. Deploy Updated Configuration
```bash
# Deploy to all hosts to enable cache usage
task nix:apply-darwin host=rymac    # macOS
task nix:apply-nixos host=rydev     # Development host
task nix:apply-nixos host=nixpi     # Pi host
```

### 5. Test Cache Functionality
```bash
# On any host, build something and push to cache
nix build .#nixosConfigurations.luna
attic push homelab result

# Verify cache contents
attic cache info homelab
```

## Task Runner Integration

### Update Taskfile to Push to Cache
Add these commands to your build tasks in `.taskfiles/nix/Taskfile.yaml`:

**For Darwin builds:**
```yaml
cmds:
  - darwin-rebuild build --flake "{{.ROOT_DIR}}/#{{.host}}"
  - nvd diff /run/current-system result
  - attic push homelab result  # Add this line
```

**For NixOS builds:**
```yaml
cmds:
  - nix-shell -p nixos-rebuild --run 'nixos-rebuild build --flake .#{{.host}} --fast --use-remote-sudo --build-host "{{.ssh_user}}@{{.host}}.holthome.net" --target-host "{{.ssh_user}}@{{.host}}.holthome.net"'
  - attic push homelab result  # Add this line
```

## Verification

### Cache is Working
```bash
# Clear local cache and try to fetch
sudo rm -rf /nix/store/*-some-package
nix-store --realise /nix/store/some-path  # Should fetch from your cache
```

### Performance Improvement
Monitor build times before and after cache deployment:
- **Before**: Full compilation of packages
- **After**: Fast downloads from cache (~10x faster for repeated builds)

## Troubleshooting

### Attic Service Issues
```bash
# Check service status
sudo systemctl status atticd
sudo journalctl -u atticd -f

# Check configuration
atticd --mode check-config -f /etc/atticd/config.toml
```

### Cache Access Issues
```bash
# Test cache connectivity
curl -v https://attic.holthome.net/homelab

# Check client configuration
nix show-config | grep substituters
nix show-config | grep trusted-public-keys
```

### DNS Issues
```bash
# Verify DNS resolution
dig attic.holthome.net
nslookup attic.holthome.net
```

## Security Notes

- Cache signing keys are automatically generated and managed by Attic
- Only machines with the public key can verify cache contents
- Private cache is accessible only within your network
- Caddy provides TLS termination for secure transport

## Performance Benefits

Once operational, you should see:
- **90% faster** rebuilds for unchanged derivations
- Reduced bandwidth usage on slower hosts (rydev, nixpi)
- Faster CI/CD if you implement automated builds
- Shared builds across all your hosts

## Next Steps

After setup is complete, consider:
1. Automating cache pushes in your deployment workflow
2. Setting up cache warming for commonly used packages
3. Monitoring cache hit ratios and storage usage
4. Configuring automated cleanup policies
