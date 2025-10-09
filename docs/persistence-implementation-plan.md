🧩 Homelab Storage, Backup, and Service Architecture (NixOS + ZFS + S3 + PostgreSQL)

Goal: Build a declarative, self-healing, and testable homelab environment using NixOS, ZFS, and S3-based backups — inspired by CloudNativePG but adapted for a single-node, break-friendly setup where experimentation is encouraged.

⸻

🏁 Quick Start (Phase 0 MVP)
    1.  Create ZFS pool tank with datasets under /persist
    2.  Configure Sanoid for hourly/daily snapshots
    3.  Set up Restic to back up /persist → S3/B2
    4.  Test manual restore (restic restore → temporary path)
    5.  Done — you now have a working 3-2-1 baseline

      ┌──────────────┐     snapshots     ┌──────────────┐
      │   ZFS Pool   │──────────────────▶│   Backup     │
      │   tank/…     │                   │   Server     │
      └────┬─────────┘                   └────┬─────────┘
           │                                  │
           ▼                                  ▼
         Restic                           S3 / B2


⸻

⚙️ Core Principles

Principle   Description
Declarative-first   All datasets + services defined in Nix; reproducible rebuilds
Service-isolated    Each service (Plex, Sonarr, Radarr, Home Assistant, PostgreSQL) gets its own dataset
Self-healing    preseed@.service restores from ZFS → Restic → S3 if data missing
Disaster-resilient  Sanoid + Syncoid + Restic + Barman provide full 3-2-1 coverage
Testable    Restores and PITR validated regularly (break it → restore it)


⸻

🗂️ Service Data Layout

tank/persist/
├── plex
├── sonarr
├── radarr
├── home-assistant
└── pg
    ├── data
    └── wal

Typical properties:

Dataset recordsize  compression notes
plex    128K    lz4 media caches
sonarr/radarr   16K lz4 small SQLite
home-assistant  16K lz4 frequent writes
pg/data 8K  lz4 Postgres pages
pg/wal  128K    off sequential WAL I/O


⸻

🪄 Pre-Seeding & Restore Logic

Behavior

If a service’s dataset or directory is missing:
    1.  Attempt ZFS receive from backup pool
    2.  If unavailable → Restic restore from S3
    3.  If still unavailable → skip + log warning

Systemd Ordering

zfs-mount.service
   ↓
preseed@sonarr.service (TimeoutStartSec=3600, Before=sonarr.service)
   ↓
sonarr.service

All services After=preseed@%i.service to ensure restores finish first.

Logging

Each preseed logs:
    • Data source (ZFS/Restic)
    • Duration
    • Checksum verification
    • “Skipped restore” if data already present

⸻

🛠️ Backup & Replication

Local
    • Hourly + daily Sanoid snapshots
    • Syncoid –no-destroy to secondary pool (prevents backup deletion)
    • Periodic ZFS scrubs + alerts

Offsite
    • Restic to S3 / B2 (encrypted by provider)
    • Lifecycle: 30 days hot → archive → delete @ 90 days
    • Typical cost: ~$6/mo @ B2 for 100 GB

Decision Matrix

Need    Use Notes
Fast local rollback ZFS snapshot    sub-second
Replica copy    Syncoid no destroy flag
Offsite dedup backup    Restic → S3   encrypted
Database PITR   Barman-Cloud    CNPG-style


⸻

🗄️ PostgreSQL (CNPG-Inspired)

Architecture
    • One Postgres cluster (pg_main) initially
    • Barman-Cloud handles WAL archival + base backups

archive_mode = on
archive_command = 'barman-cloud-wal-archive s3://pg-backups %p'

⚠️ PITR Limitations
    • All-or-nothing restore (instance-wide)
    • Recovery = base backup + WAL replay (may take hours)
    • Requires complete WAL sequence
    • Use separate clusters only for isolation or version differences

⸻

🔁 Failure Scenarios & Mitigations

Failure Mitigation
S3 unavailable  Restore from ZFS
Both ZFS + S3 unavailable   Manual import or re-seed from base images
Preseed failure Timeout + retry (3x) → service skip + alert
Syncoid lag > 24 h  Alert → force manual send
WAL archive gap Prometheus alert + base backup restart
Bit rot in backup   Checksums validated via Restic verify


⸻

🧪 Restore Testing Checklist
    • ZFS snapshot rollback per-service
    • ZFS send/receive from backup pool
    • Restic restore (full + incremental)
    • PostgreSQL PITR (1 h / 1 d / 7 d)
    • Preseed automation on fresh host
    • Cross-host restore (A → B)
    • Partial restore (single service)

Track restore time, success rate, and manual steps to measure complexity.

⸻

📊 Monitoring Targets

zfs:
  - pool_capacity (>80%)
  - scrub_errors
  - fragmentation
  - last_snapshot_age
syncoid:
  - last_successful_run
  - lag_seconds
restic:
  - last_backup_age
  - verify_errors
barman:
  - wal_archive_lag
  - last_base_backup
postgres:
  - wal_rate_mb_per_hour
  - archive_command_failures

Expose via Prometheus → Grafana dashboard.

⸻

🔐 Security & Secrets
    • ZFS encryption: disabled (homelab)
    • S3: SSE-S3 provider-side encryption
    • Transport: SSH for Syncoid, HTTPS for S3
    • Secrets: managed via sops-nix
    • Rotation: manual on key change

⸻

🧩 Nix Implementation Pattern

# modules/storage/zfs-dataset.nix
{ lib, config, ... }:
let
  mkDataset = { pool, name, mount, props ? {} }: {
    systemd.services."zfs-create-${name}" = {
      description = "Ensure ZFS dataset ${pool}/${name}";
      wantedBy = [ "local-fs.target" ];
      serviceConfig.ExecStart = ''
        /run/current-system/sw/bin/zfs create -p ${pool}/${name} || true
      '';
    };
    fileSystems.${mount}.device = "${pool}/${name}";
    fileSystems.${mount}.fsType = "zfs";
  };
in {
  config = mkDataset { pool = "tank"; name = "persist/sonarr"; mount = "/var/lib/sonarr"; };
}

# /etc/barman.d/homelab-pg.conf
[homelab-pg]
backup_method = postgres
archiver = on
streaming_archiver = on
slot_name = barman
create_slot = auto
backup_compression = gzip


⸻

📉 Complexity & Rollback
    • MVP (Phase 0): ZFS + Restic only
    • Rollback Plan: if automation breaks, disable preseed and rely on snapshot restores
    • Measure Complexity: can you restore in < 1 hour? if not, simplify

⸻

🧭 Monitoring & Failure Response
    • Alert if:
    • ZFS pool > 80%
    • Syncoid lag > 24 h
    • WAL archive lag > 1 h
    • Restic snapshot age > 24 h
    • Actions: automatic retries, manual runbook updates

⸻

🧰 Runbook & Troubleshooting (Skeleton)

Disaster Recovery Runbook
    1.  Verify hardware + bootable system
    2.  Import ZFS pool → check datasets
    3.  If missing, restic restore latest → /persist/<svc>
    4.  Run systemctl start preseed@all
    5.  Confirm services healthy

Troubleshooting
    • syncoid errors → re-run manually with --debug
    • restic check → verify repo integrity
    • barman-cloud-check → test S3 connectivity

⸻

📖 Glossary

Term    Meaning
PITR    Point-in-Time Recovery
WAL Write-Ahead Log (Postgres)
Syncoid ZFS replication wrapper
Sanoid  ZFS snapshot scheduler
Restic  Encrypted dedup backup tool
Barman-Cloud    PostgreSQL S3 PITR utility


⸻

💡 Final Notes

✅ All-in design — declarative, modular, testable
✅ Can break safely — restore paths proven
✅ CNPG-grade PITR — without Kubernetes
✅ ZFS resilience + S3 offsite = self-healing lab

“If you can’t restore it, you don’t own it.”
This architecture ensures you always can.
