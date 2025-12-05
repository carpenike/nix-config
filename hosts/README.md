<h1 align="center">🖥️ Hosts</h1>

<p align="center">
  <em>Hardware configurations and network topology for my personal homelab infrastructure.</em>
</p>

---

> [!WARNING]
> **Personal Hardware Configuration**
>
> This directory contains configurations for my specific hardware and network topology. These configurations **will not work** on other systems without significant modification. They reference specific:
> - MAC addresses and static IPs
> - ZFS pool names and layouts
> - Hardware (CPUs, GPUs, NICs, TPUs)
> - Network VLANs and subnets
> - SOPS secrets that only I can decrypt

---

## 🌐 Network Topology

```text
                                    ┌─────────────────┐
                                    │   Internet      │
                                    │  (Verizon FiOS) │
                                    └────────┬────────┘
                                             │
                                    ┌────────▼────────┐
                                    │    Mikrotik     │
                                    │ CCR2004-16G-2S+ │
                                    │   (10.x.0.1)    │
                                    └────────┬────────┘
                                             │
              ┌──────────────────────────────┼──────────────────────────────┐
              │                              │                              │
     ┌────────▼────────┐           ┌────────▼────────┐           ┌────────▼────────┐
     │  VLAN 20        │           │  VLAN 10        │           │  VLAN 30        │
     │  SERVERS        │           │  WIRED          │           │  WIRELESS       │
     │  10.20.0.0/16   │           │  10.10.0.0/16   │           │  10.30.0.0/16   │
     └────────┬────────┘           └─────────────────┘           └─────────────────┘
              │
   ┌──────────┼──────────┬──────────────────┐
   │          │          │                  │
┌──▼──┐   ┌───▼──┐   ┌───▼──┐          ┌────▼───┐
│forge│   │nas-0 │◄──│nas-1 │          │  luna  │
│ .30 │   │ .10  │   │ .11  │          │  .15   │
└──┬──┘   └───┬──┘   └──────┘          └────────┘
   │          │
   │     NFS exports
   │     (/mnt/media, /mnt/backup)
   │          │
   └──────────┘
      mounts
```

## 📡 VLAN Structure

| VLAN ID | Name | Subnet | Purpose |
|---------|------|--------|---------|
| 10 | WIRED | 10.10.0.0/16 | Wired client devices |
| 20 | SERVERS | 10.20.0.0/16 | Server infrastructure |
| 30 | WIRELESS | 10.30.0.0/16 | Wireless client devices |
| 40 | IOT | 10.40.0.0/16 | IoT devices (isolated) |
| 50 | VIDEO | 10.50.0.0/16 | Security cameras |
| — | WireGuard | 10.8.0.0/24 | VPN tunnel |
| — | Management | 10.9.18.0/24 | Network management |

---

## 📦 Host Inventory

### NixOS Servers (VLAN 20 - Servers)

| Host | IP | Hardware | Storage | Role |
|------|-----|----------|---------|------|
| `forge` | 10.20.0.30 | Intel i9-9900K (8C/16T), 32GB RAM | 2×NVMe (ZFS mirror: `rpool` 476GB, `tank` 928GB) | Primary homelab server, 43+ services |
| `nas-0` | 10.20.0.10 | Intel i3-7100 (2C/4T), 64GB RAM | 28×HDD in 14 mirrored vdevs (`tank` 117TB) | Primary storage, NFS exports |
| `nas-1` | 10.20.0.11 | Intel i3-7100 (2C/4T), 32GB RAM | 4×HDD RAIDZ1 (`backup` 51TB) | Backup target, ZFS replication |
| `luna` | 10.20.0.15 | Intel Celeron J3455 (4C), 8GB RAM | 128GB SATA SSD (`rpool` 118GB) | Infrastructure services |

### macOS Workstation

| Host | Hardware | Role |
|------|----------|------|
| `rymac` | Apple M1 Max, 32GB RAM | MacBook Pro, primary workstation |

### Other Hosts

| Host | Hardware | Role | Status |
|------|----------|------|--------|
| `rydev` | VM (aarch64-linux) | Development environment | Active |
| `nixpi` | Raspberry Pi | Experimental | Inactive |

---

## 💻 Host Details

### 🔧 forge — Primary Homelab Server

**Hardware:**
- **CPU**: Intel Core i9-9900K @ 3.60GHz (8 cores, 16 threads)
- **Memory**: 32GB DDR4
- **GPU**: EVGA GeForce GTX 1080 Ti (for Plex/Tdarr transcoding)
- **iGPU**: Intel UHD Graphics 630 (QuickSync for Frigate)
- **Storage**:
  - `rpool`: 476GB NVMe mirror (OS, impermanence)
  - `tank`: 928GB NVMe mirror (service data, per-service datasets)

**Role**: Runs 43+ services including Plex, Home Assistant, Frigate, *arr stack, Prometheus/Grafana, and more.

**Network Mounts**:
- `/mnt/media` → nas-0:/mnt/tank/media (media library)
- `/mnt/nas-backup` → nas-1:/mnt/backup/forge/restic (backup destination)

---

### 🗄️ nas-0 — Primary Storage (TrueNAS)

> [!NOTE]
> This host runs TrueNAS (FreeBSD-based), not NixOS. Configuration is managed via TrueNAS UI, not this repository.

**Hardware:**
- **CPU**: Intel Core i3-7100 @ 3.90GHz (2 cores, 4 threads)
- **Memory**: 64GB ECC RAM
- **Storage**: `tank` pool — 117TB usable
  - 14× mirrored vdevs (28 HDDs total)
  - ~90TB used, ~27TB free

**Role**: Primary bulk storage for media library, shared via NFS.

**Exports**:
- `/mnt/tank/media` → Media library (Plex, *arr stack)
- `/mnt/tank/backup` → Backup staging

---

### 💾 nas-1 — Backup NAS

**Hardware:**
- **CPU**: Intel Core i3-7100 @ 3.90GHz (2 cores, 4 threads)
- **Memory**: 32GB RAM
- **Storage**: `backup` pool — 51TB usable
  - RAIDZ1 (4 HDDs)
  - ~6TB used, ~45TB free

**Role**: Backup target for all hosts.

**Receives**:
- ZFS replication from forge (Syncoid)
- ZFS replication from nas-0 (dataset mirrors)
- Restic backups from all hosts

---

### 🌙 luna — Infrastructure Services

**Hardware:**
- **CPU**: Intel Celeron J3455 @ 1.50GHz (4 cores)
- **Memory**: 8GB RAM
- **Storage**: 128GB SATA SSD (`rpool` 118GB)

**Role**: Lightweight infrastructure services (DNS, etc.)

---

### 💻 rymac — MacBook Pro Workstation

**Hardware:**
- **Chip**: Apple M1 Max
- **Memory**: 32GB unified
- **Platform**: nix-darwin

**Role**: Primary development workstation. Managed via nix-darwin + home-manager.

---

## 🌐 Network Infrastructure

### 📡 Router: Mikrotik CCR2004-16G-2S+

- **CPU**: ARM64, 4 cores @ 1700MHz
- **Memory**: 4GB RAM
- **Ports**: 16× 1GbE, 2× SFP+
- **Software**: RouterOS 7.19.3 (stable)
- **Uptime**: Typically months between updates

**Features in use:**
- VLAN trunking
- Inter-VLAN routing
- DHCP server (per-VLAN)
- DNS forwarding
- WireGuard VPN
- Firewall rules

---

## 📥 Data Flow

### 💾 Backup Architecture

```text
┌─────────┐     ZFS Replication      ┌─────────┐
│  forge  │ ────────────────────────▶│  nas-1  │
│  (tank) │       (Syncoid)          │(backup) │
└────┬────┘                          └─────────┘
     │                                    ▲
     │  Restic backup                     │
     └────────────────────────────────────┘

┌─────────┐     ZFS Replication      ┌─────────┐
│  nas-0  │ ────────────────────────▶│  nas-1  │
│  (tank) │     (critical data)      │(backup) │
└─────────┘                          └─────────┘
```

### 🎬 Media Flow

```text
┌─────────┐      Download      ┌─────────┐      Store       ┌─────────┐
│ *arr    │ ──────────────────▶│ SABnzbd │ ───────────────▶ │  nas-0  │
│ stack   │                    │qBittorr │                  │ (media) │
└─────────┘                    └─────────┘                  └────┬────┘
     │                                                           │
     └───────────────────────── Organize ────────────────────────┘
                                                                 │
                                                           NFS mount
                                                                 │
                                                          ┌──────▼──────┐
                                                          │    Plex     │
                                                          │  (forge)    │
                                                          └─────────────┘
```

---

## 📂 Directory Structure

```text
hosts/
├── _modules/           # Reusable NixOS/Darwin modules (70+ modules)
│   ├── common/         # Cross-platform modules
│   ├── darwin/         # macOS-specific modules
│   ├── nixos/          # NixOS-specific modules
│   └── lib/            # Shared types and helpers
│
├── forge/              # Primary homelab server
│   ├── core/           # Boot, networking, users
│   ├── infrastructure/ # Storage, backup, observability
│   ├── services/       # 43+ application services
│   └── lib/            # Host-specific helpers (forgeDefaults)
│
├── luna/               # Infrastructure services host
├── nas-1/              # Backup NAS
├── rymac/              # MacBook Pro (nix-darwin)
├── rydev/              # Development VM
├── nixpi/              # Raspberry Pi (experimental)
│
├── common/             # Shared host configuration
├── files/              # Static files for hosts
└── nixos-bootstrap/    # Bootstrap configuration for new installs
```

---

## ➕ Adding a New Host

> [!CAUTION]
> This section documents my personal workflow. If you're trying to use this repo, **don't** — start fresh with your own configuration.

1. **Generate hardware configuration**:
   ```bash
   nixos-generate-config --show-hardware-config > hosts/newhost/hardware-configuration.nix
   ```

2. **Create host directory** based on a similar existing host

3. **Update flake.nix** with new nixosConfiguration

4. **Configure SOPS secrets** for the new host

5. **Add to network documentation** (this file)

6. **Deploy**:
   ```bash
   task nix:apply-nixos host=newhost NIXOS_DOMAIN=holthome.net
   ```

---

## 📚 References

- [docs/modular-design-patterns.md](../docs/modular-design-patterns.md) — Service module architecture
- [docs/backup-system-onboarding.md](../docs/backup-system-onboarding.md) — Backup configuration
- [docs/persistence-quick-reference.md](../docs/persistence-quick-reference.md) — ZFS dataset patterns
- [hosts/forge/README.md](forge/README.md) — Forge-specific architecture details
