# UPS Monitoring Configuration

## Overview

This document describes UPS monitoring using Network UPS Tools (NUT) directly via NixOS's `services.nut` options.

**Note**: The custom UPS wrapper module was removed (2025-10-16) in favor of using NixOS's built-in `services.nut` directly for clarity and maintainability. This eliminates an unnecessary abstraction layer while providing the same functionality.

## Current Implementation

See `hosts/forge/ups.nix` for the reference implementation.

## Features

- **Dual Mode Operation**: NUT supports both client (network UPS) and server (local UPS) modes
- **Automatic Shutdown**: Graceful system shutdown on critical battery events
- **Security**: Credential file-based authentication with configurable permissions
- **Network Protocol**: Standard NUT protocol over TCP port 3493

## Future Enhancements

- [ ] Prometheus metrics integration via node_exporter textfile collector
- [ ] sops-nix integration for secure password management
- [ ] Alert rules for battery events (on battery, low battery, communication loss)
- [ ] Notification integration with existing pushover/ntfy infrastructure

## Architecture

### Client Mode (Network UPS)

In client mode, the NixOS system connects to a remote UPS server:

```text
[APC UPS] <--USB--> [APC NUT Server:3493] <--Network--> [NixOS Client (upsmon)]
```

The client monitors the UPS status and initiates shutdown when battery is critically low.

### Server Mode (Local UPS)

In server mode, the NixOS system is directly connected to a UPS:

```text
[UPS] <--USB/Serial--> [NixOS Server (upsd + upsmon)] <--Network--> [Other Clients]
```

The server runs `upsd` to share UPS status with network clients.

## Configuration Examples

### Example 1: Network UPS Monitoring (Current Implementation)

This is the setup for monitoring a remote APC device over the network:

```nix
# hosts/forge/ups.nix
{ pkgs, ... }:

{
  # UPS monitoring via NUT in netclient mode
  services.nut = {
    enable = true;
    mode = "netclient";

    monitors = [
      {
        name = "apc@10.9.18.245";
        user = "monuser";
        passwordFile = "/run/secrets/ups-password";  # TODO: Migrate to sops-nix
        type = "secondary";  # Modern terminology (replaces "slave")
        powervalue = 1;
      }
    ];
  };

  # Install NUT client utilities for manual querying
  environment.systemPackages = [ pkgs.nut ];
}
```

### Example 2: With sops-nix Integration (Recommended)

```nix
{ pkgs, config, ... }:

{
  # Secure password management with sops-nix
  sops.secrets.ups-password = {
    sopsFile = ./secrets.sops.yaml;
    owner = "nut";
    group = "nut";
    mode = "0400";
  };

  services.nut = {
    enable = true;
    mode = "netclient";

    monitors = [
      {
        name = "apc@10.9.18.245";
        user = "monuser";
        passwordFile = config.sops.secrets.ups-password.path;
        type = "secondary";
        powervalue = 1;
      }
    ];
  };

  environment.systemPackages = [ pkgs.nut ];
}
```

### Example 3: USB-Connected UPS (Server Mode)

For a system directly connected to a UPS via USB:

```nix
{ pkgs, ... }:

{
  services.nut = {
    enable = true;
    mode = "standalone";  # or "netserver" to share with other hosts

    # UPS device configuration
    ups."local-ups" = {
      driver = "usbhid-ups";
      port = "auto";
    };
  };

  # Optional: Allow network access
  networking.firewall.allowedTCPPorts = [ 3493 ];

  environment.systemPackages = [ pkgs.nut ];
}
```

## NixOS services.nut Options Reference

See the [NixOS NUT documentation](https://search.nixos.org/options?query=services.nut) for complete option reference.

Key options:
- `services.nut.enable` - Enable NUT
- `services.nut.mode` - Operation mode: "netclient", "netserver", "standalone"
- `services.nut.monitors` - List of UPS monitors (for netclient mode)
- `services.nut.ups` - UPS device configuration (for server modes)

## Future: Prometheus Metrics Integration

When Prometheus metrics are implemented, they will export:

### Core Metrics

- `ups_battery_charge` - Battery charge percentage (0-100)
- `ups_battery_runtime` - Estimated battery runtime in seconds
- `ups_battery_voltage` - Battery voltage
- `ups_input_voltage` - Input voltage
- `ups_output_voltage` - Output voltage
- `ups_load` - Load percentage (0-100)

### Status Flags

- `ups_status_online` - Online (1 = true, 0 = false)
- `ups_status_on_battery` - On Battery
- `ups_status_low_battery` - Low Battery
- `ups_status_replace_battery` - Replace Battery
- `ups_status_info{ups="name",status="BOOST"}`: Voltage boost
- `ups_status_info{ups="name",status="FSD"}`: Forced shutdown

## Alert Examples

You can add UPS-related alerts to your monitoring configuration:

```nix
# In hosts/forge/alerting.nix
modules.alerting.rules = lib.mkMerge [
  # Existing alerts...

  # UPS alerts
  {
    "ups-on-battery" = {
      type = "promql";
      alertname = "UPSOnBattery";
      expr = ''ups_status_info{status="OB"} == 1'';
      for = "2m";
      severity = "warning";
      summary = "UPS {{ $labels.ups }} is running on battery";
      description = "The UPS has been on battery power for 2 minutes.";
    };

    "ups-low-battery" = {
      type = "promql";
      alertname = "UPSLowBattery";
      expr = ''ups_battery_charge < 50'';
      for = "1m";
      severity = "critical";
      summary = "UPS {{ $labels.ups }} has low battery ({{ $value }}%)";
      description = "Battery charge is below 50%. System may shut down soon.";
    };

    "ups-battery-replace" = {
      type = "promql";
      alertname = "UPSBatteryReplace";
      expr = ''ups_status_info{status="RB"} == 1'';
      for = "5m";
      severity = "warning";
      summary = "UPS {{ $labels.ups }} battery needs replacement";
      description = "The UPS has indicated that its battery should be replaced.";
    };

    "ups-communication-failure" = {
      type = "promql";
      alertname = "UPSCommFailure";
      expr = ''ups_scrape_success == 0'';
      for = "5m";
      severity = "critical";
      summary = "Cannot communicate with UPS {{ $labels.ups }}";
      description = "Failed to scrape UPS metrics for 5 minutes.";
    };
  }
];
```

## Security Considerations

### Design Principles

1. **Secure Defaults**: Server mode listens on localhost only by default
2. **Minimal Privileges**: Exporter runs as a dynamic user with only necessary group memberships
3. **Secrets Management**: Supports external password files (sops-nix, agenix)
4. **Filesystem Protection**: Strict systemd hardening with minimal write access
5. **Firewall Control**: Explicit opt-in for network exposure

### Systemd Hardening

The Prometheus exporter service includes comprehensive hardening:

- `DynamicUser=true`: Ephemeral user with no persistent state
- `ProtectSystem=strict`: Read-only system directories
- `ProtectHome=true`: No home directory access
- `PrivateTmp=true`: Isolated /tmp
- `NoNewPrivileges=true`: Cannot gain new privileges
- `RestrictAddressFamilies`: Only necessary network protocols
- `SystemCallFilter=@system-service`: Restricted syscalls

### Network Security

- Client mode: No inbound ports required
- Server mode: Firewall closed by default, explicit opt-in required
- Uses standard NUT port 3493/tcp
- Authentication required for all connections

## Troubleshooting

### Check UPS Status Manually

```bash
# List available UPS devices
upsc -l

# Get all variables from a UPS
upsc apc-main@10.9.18.245

# Check specific variable
upsc apc-main@10.9.18.245 battery.charge
```

### View Exporter Service Status

```bash
# Check service status
systemctl status ups-exporter.service

# Check timer status
systemctl status ups-exporter.timer

# View recent logs
journalctl -u ups-exporter.service -n 50

# Manually trigger export
systemctl start ups-exporter.service
```

### View Prometheus Metrics

```bash
# View raw metrics file
cat /var/lib/node_exporter/textfile_collector/ups.prom

# Check if node exporter is picking up the metrics
curl localhost:9100/metrics | grep ups_
```

### Common Issues

#### "Connection refused" Error

**Symptom**: `ups_scrape_success` is 0, logs show connection refused.

**Solutions**:
1. Verify UPS host is reachable: `ping 10.9.18.245`
2. Check if UPS server is listening: `nc -zv 10.9.18.245 3493`
3. Verify firewall allows outbound connections to port 3493

#### "Authentication failed" Error

**Symptom**: Connection succeeds but authentication fails.

**Solutions**:
1. Verify credentials are correct
2. Check if passwordFile path is accessible
3. Ensure the user has proper permissions on the UPS server

#### Metrics Not Appearing in Prometheus

**Symptom**: UPS data scrapes successfully but doesn't appear in Prometheus.

**Solutions**:
1. Verify textfile collector is enabled: `modules.monitoring.nodeExporter.textfileCollector.enable = true`
2. Check metrics file exists and has content: `cat /var/lib/node_exporter/textfile_collector/ups.prom`
3. Verify node exporter is configured to read from the directory
4. Check file permissions on the metrics file

## Module Pattern Compliance

This module follows the established patterns in your NixOS configuration:

1. ✅ **Namespace**: Uses `modules.services.*` namespace
2. ✅ **Options Pattern**: Uses `mkEnableOption`, `mkOption` with proper types
3. ✅ **Security**: Includes firewall options, secure defaults, minimal privileges
4. ✅ **Assertions**: Validates configuration at build time
5. ✅ **Warnings**: Provides operational awareness warnings
6. ✅ **Monitoring**: Integrates with existing Prometheus infrastructure
7. ✅ **Documentation**: Comprehensive inline comments and external docs
8. ✅ **DRY**: Reusable across multiple hosts

## Related Modules

- `monitoring.nix`: Base monitoring configuration
- `node-exporter/default.nix`: Prometheus node exporter configuration
- `alerting/default.nix`: Alert rule definitions

## References

- [NUT Documentation](https://networkupstools.org/docs/)
- [NUT Configuration Examples](https://networkupstools.org/docs/user-manual.chunked/index.html)
- [NixOS NUT Options](https://search.nixos.org/options?query=services.nut)
- [Prometheus Textfile Collector](https://github.com/prometheus/node_exporter#textfile-collector)
