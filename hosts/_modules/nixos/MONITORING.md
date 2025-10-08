# Monitoring Configuration

## Overview

The monitoring configuration follows NixOS best practices with a common module providing defaults and host-specific overrides.

## Architecture

### Common Module (`hosts/_modules/nixos/monitoring.nix`)

Provides shared monitoring configuration with sensible defaults:

- Enables Prometheus Node Exporter on port 9100 (standard)
- Includes common collectors (systemd by default)
- Configurable textfile collector for custom metrics
- **Security**: `openFirewall` defaults to `false` - must be explicitly enabled per host
- **Security**: `listenAddress` defaults to `0.0.0.0` but should be reviewed per host

### Host-Specific Configuration

Each host can enable monitoring with custom settings:

```nix
modules.monitoring = {
  enable = true;
  nodeExporter = {
    enabledCollectors = [ "systemd" "textfile" ];
    textfileCollector.enable = true;
  };
};
```

## Forge Configuration

Forge is configured as a backup server with additional monitoring capabilities:

- **Port**: 9100 (standard node-exporter port)
- **Listen Address**: `0.0.0.0` (internal network access)
- **Firewall**: Explicitly enabled (safe on internal network)
- **Enabled Collectors**: `systemd`, `textfile`
- **Textfile Directory**: `/var/lib/node_exporter/textfile_collector`

### Security Considerations

- Forge is on internal network (10.20.0.0/24) behind router firewall
- Listening on all interfaces (`0.0.0.0`) is safe for internal access
- Firewall is explicitly opened for Prometheus scraping
- No authentication configured (rely on network-level security)

### Integration with Backup Module

The backup module writes metrics to the textfile collector directory:

- Backup success/failure timestamps
- Backup duration and data size
- Repository verification status
- Restore test results
- Error analysis metrics
- Documentation generation status

## Security Best Practices

### Decision Matrix for Host Configuration

| Setting | Public-Facing Host | Internal Host | Development Host |
|---------|-------------------|---------------|------------------|
| `listenAddress` | `127.0.0.1` | `0.0.0.0` | `127.0.0.1` |
| `openFirewall` | `false` | `true` | `false` |
| Reasoning | Localhost only, use SSH tunnel or proxy | Safe on internal network | Localhost only, manual access |

### Guidelines

1. **listenAddress**:
   - Use `127.0.0.1` for hosts exposed to internet (even if behind firewall)
   - Use `0.0.0.0` only for hosts on trusted internal networks
   - Document the network topology in host configuration

2. **openFirewall**:
   - Default is `false` for security
   - Set to `true` only after confirming network security
   - Consider additional firewall rules for specific source IPs if needed

3. **Port Selection**:
   - Use standard port 9100 unless there's a conflict
   - Document any non-standard ports clearly

## Adding Monitoring to Other Hosts

To enable monitoring on a new host:

1. Create `monitoring.nix` in the host directory:

   ```nix
   { ... }:

   {
     modules.monitoring.enable = true;
   }
   ```

1. Import it in the host's `default.nix`:

   ```nix
   imports = [
     ./monitoring.nix
   ];
   ```

1. For hosts with custom metrics, enable textfile collector:

   ```nix
   modules.monitoring = {
     enable = true;
     nodeExporter.textfileCollector.enable = true;
   };
   ```

## Prometheus Scrape Configuration

Add to your Prometheus config:

```yaml
scrape_configs:
  - job_name: 'nixos-nodes'
    static_configs:
      - targets:
          - 'forge.holthome.net:9100'
          - 'other-host.holthome.net:9100'
```

## Benefits of This Approach

1. **DRY Principle**: Common configuration is defined once
2. **Maintainability**: Updates to common settings affect all hosts
3. **Flexibility**: Hosts can override defaults as needed
4. **Type Safety**: Module options provide type checking
5. **Documentation**: Options are self-documenting
6. **Consistency**: All hosts follow the same patterns
