# AdGuard Home Modular Configuration Guide

This guide explains the modular configuration approach for AdGuard Home in our NixOS infrastructure.

## Philosophy: Minimal Baseline + Web UI Management

Based on best practices research, we use a **minimal declarative baseline** approach:

### Declarative (NixOS Config) - Infrastructure Critical Only
- **Network ports**: Web UI and DNS ports
- **Initial admin user**: For bootstrapping
- **Internal DNS forwarding**: Critical for local network operation
- **Firewall rules**: Automatic based on configured ports

### Web UI Managed - Everything Else
- Filters and blocklists
- Client-specific configurations
- Parental controls and safe search
- Service blocking schedules
- Additional DNS upstreams
- Query logging and statistics
- DHCP server settings
- Custom filtering rules

## Benefits of This Approach

1. **No Configuration Drift**: Infrastructure-critical settings are immutable
2. **Operational Flexibility**: Admins can adjust filters/rules without redeploy
3. **Quick Response**: Immediate blocking of new threats via web UI
4. **User Self-Service**: Individual client settings manageable via web UI
5. **Simplified Management**: No need to encode complex filter lists in Nix

## Usage Example

```nix
# In hosts/luna/default.nix
{
  modules.services.adguardhome = {
    enable = true;
    shared = {
      enable = true;
      adminUser = "ryan";

      # Only configure internal DNS forwarding
      localDnsServer = "127.0.0.1:5391";  # Your BIND server
      localDomains = [
        "holthome.net"
        "in-addr.arpa"
        "ip6.arpa"
      ];
    };
  };
}
```

## Migration from Full Declarative Config

If migrating from a full declarative configuration:

1. **Enable the minimal shared config** (as shown above)
2. **Deploy the configuration**
3. **Access AdGuard web UI** at `http://yourhost:3000`
4. **Configure via web UI**:
   - Add filter lists
   - Configure client settings
   - Set up parental controls
   - Add custom rules

## What Stays in Web UI

The following should **always** be managed via web UI for flexibility:

### Filters & Blocklists
- AdGuard DNS filter
- Third-party blocklists (OISD, hagezi, etc.)
- Custom filtering rules
- Allowlists and exceptions

### Client Management
- Individual device settings
- Safe search enforcement
- Service blocking schedules
- Custom upstream DNS per client

### Operational Settings
- Query log retention
- Statistics settings
- DHCP server configuration
- DNS cache settings

## Best Practices

1. **Backup Configuration**: Periodically export AdGuard config via web UI
2. **Document Changes**: Keep notes on major web UI configuration changes
3. **Monitor Performance**: Use AdGuard's built-in statistics
4. **Regular Updates**: Update filter lists via web UI regularly

## Comparison: Minimal vs Full Declarative

| Aspect | Minimal Baseline | Full Declarative |
|--------|------------------|------------------|
| Infrastructure Settings | ✅ Immutable | ✅ Immutable |
| Filter Management | 🌐 Web UI | 📝 Nix Config |
| Client Rules | 🌐 Web UI | 📝 Nix Config |
| Response Time | ⚡ Immediate | 🔄 Redeploy Required |
| Complexity | 🟢 Simple | 🔴 Complex |
| Audit Trail | 📊 AdGuard Logs | 📊 Git History |

## Security Considerations

- Admin password is managed via SOPS secrets
- Web UI should be accessed over VPN or secured network
- Regular backups of AdGuard configuration recommended
- Monitor query logs for anomalies

## Troubleshooting

### Web UI Not Accessible
- Check firewall ports: `sudo nft list ruleset | grep 3000`
- Verify service running: `systemctl status adguardhome`

### Internal Domains Not Resolving
- Verify BIND is running on configured port
- Check `localDnsServer` points to correct BIND instance
- Ensure `localDomains` includes all internal domains

### Configuration Not Persisting
- Ensure `mutableSettings = true` (default with shared config)
- Check systemd service logs for errors
- Verify disk space for AdGuard data directory
