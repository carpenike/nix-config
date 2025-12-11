# NAS-0 Host Configuration

Primary bulk storage NAS for the homelab.

## Hardware

| Component | Specification |
|-----------|--------------|
| CPU | Intel i3-7100 (2C/4T @ 3.9GHz) |
| RAM | 64GB DDR4 |
| Boot | 64GB Transcend MTS600 SSD |
| Storage | 117TB across 14 mirror vdevs (28 drives) |
| Network | Intel 10GbE |

## Architecture

```text
nas-0/
├── core/                    # OS-level concerns
│   ├── boot.nix            # Boot configuration
│   ├── hardware.nix        # Hardware-specific settings
│   ├── monitoring.nix      # Node exporter for Prometheus
│   ├── networking.nix      # Network configuration (10.20.0.10)
│   ├── packages.nix        # System packages
│   └── users.nix           # User accounts
├── infrastructure/          # Cross-cutting concerns
│   ├── nfs.nix             # NFS server exports
│   ├── smb.nix             # SMB shares
│   └── storage.nix         # ZFS/Sanoid/Syncoid configuration
├── lib/
│   └── defaults.nix        # Host-specific defaults wrapper
├── default.nix             # Main configuration entry point
├── disko-config.nix        # Disk partitioning (boot disk only)
└── secrets.nix             # SOPS secrets
```

## Role

### Primary Storage Server

- **Media storage**: 86.6TB in `tank/share` for Plex, Sonarr, Radarr, etc.
- **Home directories**: User homes in `tank/home`
- **Object storage**: MinIO data in `tank/minio`

### NFS Exports

| Export | Purpose | Clients |
|--------|---------|---------|
| `/mnt/tank/share` | Media files | forge (10.20.0.0/16) |
| `/mnt/tank/home` | User homes | 10.20.0.0/16 |
| `/mnt/tank/share/pictures` | Photo storage | 10.20.0.0/16 |

### SMB Shares

- Windows/macOS access to media and home directories

## ZFS Configuration

### Pools

| Pool | Purpose | Configuration |
|------|---------|---------------|
| `rpool` | Boot/OS | Single SSD (disko managed) |
| `tank` | Data | 14 mirror vdevs (imported via `boot.zfs.extraPools`) |

### Replication

| Source | Destination | Interval |
|--------|-------------|----------|
| `tank/home` | `nas-1:backup/nas-0/zfs-recv/home` | Daily |

**Note**: `tank/share` (86TB) is optionally replicated - uncomment in storage.nix if bandwidth allows.

### Snapshots (Sanoid)

| Dataset | Template | Retention |
|---------|----------|-----------|
| `rpool/safe/persist` | local | 24h/7d/4w/3m |
| `rpool/safe/home` | local | 24h/7d/4w/3m |
| `tank/share` | media | 7d/4w/3m (no hourly - too large) |
| `tank/home` | production | 24h/30d/8w/12m/1y |
| `tank/minio` | production | 24h/30d/8w/12m/1y |

## Monitoring

### Metrics Exposed

- **Port 9100**: node_exporter (scraped by Prometheus on forge)
- **ZFS metrics**: Pool health, capacity via textfile collector

### Alerts (defined on forge)

- Disk space critical (<10%)
- ZFS pool degraded
- Node exporter down
- NFS service down

## Network

| Interface | IP | Purpose |
|-----------|------|---------|
| Primary (MAC: ac:1f:6b:1a:8e:40) | 10.20.0.10/16 | Main network |
| tailscale0 | Dynamic | Remote access |

**DNS**: `nas-0.holthome.net`, `nas.holthome.net` (alias)

## Migration Notes

This host was migrated from TrueNAS. The `tank` pool was preserved and imported; only the boot disk was reformatted for NixOS.

### TrueNAS Artifacts to Clean

- `tank/.system` dataset (TrueNAS system data)

## Maintenance

### Check Pool Status

```bash
zpool status tank
zpool status rpool
```

### View Snapshots

```bash
zfs list -t snapshot | head -20
```

### SMART Status (28 drives!)

```bash
smartctl -a /dev/sdX  # Per drive
# Or use smartd logs
journalctl -u smartd
```
