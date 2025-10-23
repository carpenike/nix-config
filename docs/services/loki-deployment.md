# Loki Log Aggregation Deployment Guide

This guide covers deploying Grafana Loki for centralized log aggregation in your homelab using the modular Nix configuration.

## Overview

The Loki implementation follows established patterns in this repository:
- **Modular Design**: Separate modules for Loki, Promtail, and unified observability
- **Security First**: Localhost binding with reverse proxy authentication
- **Resource Optimized**: Homelab-appropriate resource limits and retention
- **Backup Integrated**: ZFS snapshots + selective Restic backup
- **Monitoring Ready**: Prometheus metrics and alerting rules

## Architecture

```
┌─────────────┐    ┌──────────────┐    ┌─────────────┐
│   Promtail  │───▶│     Loki     │◀───│   Grafana   │
│ (Log Agent) │    │ (Aggregator) │    │ (Frontend)  │
└─────────────┘    └──────────────┘    └─────────────┘
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐    ┌──────────────┐    ┌─────────────┐
│ Journal +   │    │ ZFS Dataset  │    │ Caddy RP +  │
│ Containers  │    │ + Snapshots  │    │ Basic Auth  │
└─────────────┘    └──────────────┘    └─────────────┘
```

## Quick Start

### 1. Enable Observability Stack

Add to your host configuration (e.g., `hosts/luna/default.nix`):

```nix
{
  # Simple unified approach
  modules.services.observability = {
    enable = true;
    loki.zfsDataset = "tank/services/loki";  # Optional but recommended
    reverseProxy.subdomain = "loki";
  };
}

# OR fine-grained control
{
  modules.services.loki = {
    enable = true;
    retentionDays = 30;  # Adjust based on storage
    zfs.dataset = "tank/services/loki";
    reverseProxy = {
      enable = true;
      subdomain = "loki";
      auth = {
        user = "admin";
        passwordHashEnvVar = "CADDY_LOKI_ADMIN_BCRYPT";
      };
    };
  };

  modules.services.promtail = {
    enable = true;
    containers.source = "journald";  # or "podmanFiles"
    journal.dropIdentifiers = [
      "systemd-logind"
      "systemd-networkd"
      "NetworkManager"
    ];
  };
}
```

### 2. Configure Authentication

Add to your SOPS secrets file:

```bash
sops hosts/luna/secrets.sops.yaml
```

Add the bcrypt hash:
```yaml
services:
  caddy:
    environment:
      CADDY_LOKI_ADMIN_BCRYPT: "$2a$12$..."  # Generate with: htpasswd -bnBC 12 admin password
```

### 3. Create ZFS Dataset (Recommended)

```bash
# Create optimized dataset for log storage
zfs create -o compression=zstd \
           -o recordsize=1M \
           -o atime=off \
           -o com.sun:auto-snapshot=true \
           tank/services/loki
```

### 4. Deploy and Validate

```bash
# Validate configuration
/nix-validate

# Deploy to target host
/nix-deploy host=luna

# Verify services
systemctl status loki promtail
curl -s http://127.0.0.1:3100/ready
curl -s http://127.0.0.1:9080/ready

# Test web access
curl -u admin:password https://loki.holthome.net/ready
```

## Configuration Options

### Loki Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `dataDir` | `/var/lib/loki` | Loki data storage directory |
| `port` | `3100` | HTTP server port |
| `retentionDays` | `14` | Log retention period |
| `logLevel` | `info` | Logging verbosity |
| `zfs.dataset` | `null` | ZFS dataset for data storage |
| `backup.excludeDataFiles` | `true` | Exclude chunks from backup |

### Promtail Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `port` | `9080` | Metrics server port |
| `containers.source` | `journald` | Container log source |
| `journal.maxAge` | `12h` | Max journal entry age on startup |
| `journal.dropIdentifiers` | `[...]` | Units to exclude from collection |

### Resource Limits

```nix
modules.services.loki.resources = {
  MemoryMax = "512M";
  MemoryReservation = "256M";
  CPUQuota = "50%";
};

modules.services.promtail.resources = {
  MemoryMax = "128M";
  CPUQuota = "25%";
};
```

## Integration Points

### Grafana Integration

1. **Add Loki Data Source**:
   - URL: `http://127.0.0.1:3100` (local) or `https://loki.holthome.net` (remote)
   - Access: Server (for local) or Browser (for remote with auth)

2. **Example Dashboard Queries**:
   ```logql
   # Recent errors across all services
   {host="luna"} |= "error" | json | line_format "{{.timestamp}} {{.level}}: {{.message}}"

   # Container logs for specific service
   {unit="podman-dispatcharr.service"} | json | line_format "{{.message}}"

   # System authentication events
   {unit="sshd.service"} |= "authentication"

   # High-frequency log sources
   topk(10, sum by (unit) (rate({host="luna"}[5m])))
   ```

### Prometheus Monitoring

Metrics automatically exposed:
- **Loki**: `http://127.0.0.1:3100/metrics`
- **Promtail**: `http://127.0.0.1:9080/metrics`

Key alerts included:
- No logs ingested for 10 minutes
- Query failures detected
- Promtail dropping logs (backpressure)

### Backup Strategy

**ZFS Snapshots** (Primary):
```bash
# Automatic via sanoid
zfs list -t snapshot tank/services/loki
```

**Restic Backup** (Configuration only):
- Includes: Rules, configuration, index
- Excludes: Chunks, WAL, cache (regenerable)

## Log Sources

### Automatic Collection

**Systemd Journal**:
- System services (`sshd`, `caddy`, `nginx`)
- Podman containers (via systemd units)
- Kernel messages and system events

**Container Logs**:
- Podman containers managed by systemd
- JSON-formatted with container metadata
- Stream separation (stdout/stderr)

### Custom Log Sources

Add additional sources via `extraScrapeConfigs`:

```nix
modules.services.promtail.extraScrapeConfigs = [
  {
    job_name = "nginx";
    static_configs = [{
      targets = ["localhost"];
      labels = {
        job = "nginx";
        __path__ = "/var/log/nginx/*.log";
      };
    }];
    pipeline_stages = [
      {
        regex = {
          expression = "^(?P<remote>[^ ]*) (?P<host>[^ ]*) (?P<user>[^ ]*) \\[(?P<time>[^\\]]*)\\]";
        };
      }
      {
        timestamp = {
          source = "time";
          format = "02/Jan/2006:15:04:05 -0700";
        };
      }
    ];
  }
];
```

## Operations

### Log Queries

**Basic Filtering**:
```logql
{host="luna"}                           # All logs from host
{unit="caddy.service"}                  # Specific service
{job="containers"}                      # All container logs
{container="dispatcharr"}               # Specific container
```

**Content Filtering**:
```logql
{host="luna"} |= "error"                # Contains "error"
{host="luna"} |~ "failed|error"         # Regex match
{host="luna"} != "systemd"              # Exclude pattern
```

**Structured Data**:
```logql
{unit="caddy.service"} | json | level="error"
{job="containers"} | json | line_format "{{.message}}"
```

**Aggregations**:
```logql
sum(rate({host="luna"}[5m])) by (unit)  # Log rate by service
count_over_time({level="error"}[1h])    # Error count per hour
```

### Maintenance

**Storage Management**:
```bash
# Check disk usage
du -sh /var/lib/loki/*
zfs list tank/services/loki

# Monitor retention
systemctl status loki | grep compactor
```

**Performance Tuning**:
```bash
# Check Loki metrics
curl -s http://127.0.0.1:3100/metrics | grep loki_ingester

# Monitor Promtail
journalctl -u promtail -f
curl -s http://127.0.0.1:9080/metrics | grep promtail_client
```

**Troubleshooting**:
```bash
# Service status
systemctl status loki promtail

# Check configuration
loki -config.file=/etc/loki/loki.yml -verify-config

# Test connectivity
curl -s http://127.0.0.1:3100/ready
curl -s http://127.0.0.1:3100/metrics

# View logs
journalctl -u loki -f
journalctl -u promtail -f
```

## Security Considerations

- **Network Binding**: Services bind to localhost only
- **Authentication**: Basic auth via Caddy reverse proxy
- **Systemd Hardening**: Full sandboxing and privilege restrictions
- **Log Access**: Promtail requires `systemd-journal` group membership
- **TLS**: Automatic certificates via Caddy with DNS-01 challenges

## Performance Notes

**Homelab Optimizations**:
- Single-instance monolithic deployment
- Filesystem storage backend
- In-memory ring for service discovery
- Compressed ZFS storage with 1M recordsize
- Query result caching enabled
- Conservative resource limits

**Scaling Considerations**:
- 14-day retention with ~500MB/day = ~7GB storage
- ZFS compression typically achieves 2-3x reduction
- Adjust retention based on available storage
- Monitor query performance with high-cardinality labels

## Migration and Upgrades

**Data Migration**:
```bash
# Stop services
systemctl stop loki promtail

# Move data (if changing storage)
zfs send tank/services/loki@snapshot | zfs receive new/location

# Update configuration
# Start services
systemctl start loki promtail
```

**Upgrades**:
- Loki maintains backward compatibility
- Configuration schema v11 is stable
- No migration required for minor versions
- Always validate configuration after updates

This implementation provides a production-ready log aggregation solution optimized for homelab environments while maintaining enterprise-grade patterns for security, monitoring, and operational excellence.
