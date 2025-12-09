# Cooklang Service - Quick Reference

> **Status**: ✅ Implemented & Reviewed (November 15, 2025)
> **Module**: `modules/nixos/services/cooklang/default.nix`
> **Review**: Critical security and reliability improvements applied

## Overview

Cooklang is a markup language for recipes. This module provides a native NixOS service for running the Cooklang web server to manage your personal recipe collection.

## Quick Start

### 1. Enable the Service

Create or edit `hosts/forge/services/cooklang.nix`:

```nix
{
  modules.services.cooklang = {
    enable = true;
    recipeDir = "/data/cooklang/recipes";

    reverseProxy = {
      enable = true;
  domain = "cook.holthome.net";
    };
  };

  # ZFS storage
  modules.storage.datasets."cooklang" = {
    dataset = "tank/services/cooklang";
    mountpoint = "/data/cooklang";
  };

  # Backup
  modules.backup.sanoid.datasets."tank/services/cooklang" = {
    useTemplate = [ "services" ];
    recursive = true;
  };
}
```

### 2. Deploy

```bash
task nix:apply-nixos host=forge
```

### 3. Access

Navigate to: [cook.holthome.net](https://cook.holthome.net)

## Adding Recipes

### Method 1: Direct File Creation

```bash
ssh forge
cd /data/cooklang/recipes
nano "Chocolate Chip Cookies.cook"
```

### Method 2: Import from Web

```bash
# Use the cook.md converter
# In browser: https://cook.md/https://example.com/recipe-url
```

### Example Recipe Format

```cooklang
>> title: Chocolate Chip Cookies
>> tags: dessert, cookies, baking
>> time: 45 minutes
>> servings: 24

Preheat oven to @oven temp{375%°F}.

Mix @butter{1%cup} with @sugar{3/4%cup} and @brown sugar{3/4%cup}.
Add @eggs{2} and @vanilla{2%tsp}.

In separate bowl, combine @flour{2 1/4%cups}, @baking soda{1%tsp},
and @salt{1%tsp}.

Mix wet and dry ingredients. Fold in @chocolate chips{2%cups}.

Drop spoonfuls onto #baking sheet{}.

Bake for ~{10%minutes} until golden brown.
```

## Configuration Options

### Declarative Aisle Configuration

```nix
modules.services.cooklang.settings.aisle = ''
  [produce]
  tomatoes
  onions

  [dairy]
  milk
  cheese
'';
```

### Declarative Pantry (Optional)

```nix
modules.services.cooklang.settings.pantry = {
  pantry = {
    salt = "{ quantity = \"1%kg\", low = \"500%g\" }";
  };
};
```

Or leave as `null` to manage via CLI.

## CLI Usage

### View a Recipe

```bash
ssh forge
cd /data/cooklang/recipes
cook recipe "Chocolate Chip Cookies.cook"
```

### Generate Shopping List

```bash
cook shopping-list "Recipe1.cook" "Recipe2.cook"
```

### Check Pantry

```bash
cook pantry depleted
cook pantry expiring
```

### Search Recipes

```bash
cook search "chocolate"
```

## Monitoring

### Service Status

```bash
systemctl status cooklang
journalctl -u cooklang -f
```

### Logs in Grafana

```logql
{service="cooklang"}
```

### Alerts

- **Service Down**: Fires after 5 minutes of downtime
- **Dataset Unavailable**: Fires after 2 minutes if ZFS dataset is unavailable

## Backup & Recovery

### Manual Snapshot

```bash
sudo zfs snapshot tank/services/cooklang@manual-$(date +%Y%m%d-%H%M%S)
```

### List Snapshots

```bash
zfs list -t snapshot tank/services/cooklang
```

### Restore from Snapshot

```bash
# List snapshots
zfs list -t snapshot tank/services/cooklang

# Rollback to snapshot
sudo zfs rollback tank/services/cooklang@2025-11-15-12:00:00
```

### Disaster Recovery

The preseed service automatically restores recipes on fresh deployment:

1. Checks if recipe directory is empty
2. Attempts restore from Syncoid (replicated snapshots)
3. Falls back to Restic if Syncoid unavailable
4. Creates `.preseed-marker` on success

## Troubleshooting

### Service Won't Start

```bash
# Check service status
systemctl status cooklang

# Check logs
journalctl -u cooklang -n 50

# Verify recipe directory exists
ls -la /data/cooklang/recipes

# Check permissions
sudo ls -la /data/cooklang
```

### Web UI Not Accessible

```bash
# Check if service is listening
ss -tlnp | grep 9080

# Check Caddy proxy
systemctl status caddy
journalctl -u caddy | grep cook.holthome.net

# Test direct access (from forge)
curl http://127.0.0.1:9080
```

### Recipes Not Appearing

```bash
# Verify recipe files exist
ls -la /data/cooklang/recipes/*.cook

# Check file permissions
sudo ls -la /data/cooklang/recipes/

# Restart service
sudo systemctl restart cooklang
```

### Configuration Not Applied

```bash
# Check config files
cat /data/cooklang/recipes/config/aisle.conf
cat /data/cooklang/recipes/config/pantry.conf

# Rebuild and switch
sudo nixos-rebuild switch --flake .
```

## File Locations

- **Module**: `modules/nixos/services/cooklang/default.nix`
- **Host Config**: `hosts/forge/services/cooklang.nix`
- **Design Doc**: `docs/services/cooklang-module-design.md`
- **Recipes**: `/data/cooklang/recipes/*.cook`
- **Config**: `/data/cooklang/recipes/config/`
- **Logs**: `journalctl -u cooklang`
- **State**: `/var/lib/cooklang/`

## Resources

- **Cooklang Spec**: [cooklang.org/docs/spec](https://cooklang.org/docs/spec/)
- **Getting Started**: [cooklang.org/docs/getting-started](https://cooklang.org/docs/getting-started/)
- **CLI Documentation**: [github.com/cooklang/cookcli](https://github.com/cooklang/cookcli)
- **Recipe Examples**: [github.com/cooklang/awesome-cooklang-recipes](https://github.com/cooklang/awesome-cooklang-recipes)
- **Community**: [discord.gg/fUVVvUzEEK](https://discord.gg/fUVVvUzEEK)

## Related Modules

- **Caddy**: Reverse proxy configuration
- **Loki/Promtail**: Log aggregation
- **Storage**: ZFS dataset management
- **Sanoid**: Backup snapshots
- **Alerting**: Prometheus alerts

## Security Notes

- Service binds to `127.0.0.1` only (not exposed to network)
- All access goes through Caddy reverse proxy with HTTPS
- SystemD sandboxing enabled (ProtectSystem, PrivateTmp, etc.)
- Resource limits: 512MB RAM max, 50% CPU quota
- Consider adding caddy-security/PocketID authentication if exposing externally

## Performance

- **Memory**: ~50-100MB typical usage
- **CPU**: Minimal (< 5% during normal operation)
- **Storage**: Recipes are plain text (~1-5KB each)
- **Compression**: ZFS compression saves ~60-70% on text files

## Next Steps

1. Add your first recipes
2. Configure pantry inventory
3. Generate shopping lists
4. Set up mobile access (PWA-capable)
5. Consider importing recipes from favorite sites

---

**Need Help?** Check the design doc at `docs/services/cooklang-module-design.md` or review the module source.
