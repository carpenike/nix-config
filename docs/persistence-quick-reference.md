# Persistence Implementation - Quick Reference

This is a condensed reference for the persistence implementation. For full details, see:
- **Execution Plan**: `persistence-implementation-execution-plan.md`
- **Status Tracker**: `IMPLEMENTATION-STATUS.md`

---

## Architecture Summary

```
Current (Monolithic):
  /persist → rpool/safe/persist (everything mixed together)

Target (Isolated):
  /persist → tank/persist (forge) OR rpool/safe/persist (others)
    ├── /persist/sonarr → tank/persist/sonarr (recordsize=16K)
    ├── /persist/plex → tank/persist/plex (recordsize=1M)
    ├── /persist/postgres → tank/persist/postgres (recordsize=8K)
    └── ...
```

---

## Key Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Dataset creation | Automatic via activation scripts | Fully declarative, no manual commands |
| Pool configuration | Host-level (`parentDataset` option) | forge=tank, others=rpool |
| Mount strategy | Hybrid (legacy base + auto service) | Control + automation |
| Breaking changes | Acceptable | Homelab = fast iteration |
| Validation | Gemini Pro 2.5 + O3-mini | Both models concur |

---

## Per-Service ZFS Properties

```nix
# Media servers (streaming, large files)
plex = { recordsize = "1M"; compression = "lz4"; };

# Small file apps (SQLite databases)
sonarr = { recordsize = "16K"; compression = "lz4"; };
radarr = { recordsize = "16K"; compression = "lz4"; };

# Databases
postgres-data = { recordsize = "8K"; compression = "lz4"; };
postgres-wal = { recordsize = "128K"; compression = "off"; };

# IoT / Home automation
home-assistant = { recordsize = "16K"; compression = "lz4"; };
```

---

## Module Structure

```
lib/
  storage-helpers.nix (Phase 5: preseed functions)

hosts/_modules/nixos/
  storage/
    datasets.nix (Phase 1: core module)
  replication/
    zfs.nix (Phase 4: Sanoid/Syncoid)
  database/
    postgresql/
      pitr.nix (Phase 6: Barman-Cloud)
  services/
    sonarr/default.nix (Phase 2: service integration)
    radarr/default.nix (Phase 3)
    # etc...
```

---

## Configuration Pattern

### Host Config (forge)
```nix
modules.storage.datasets = {
  enable = true;
  parentDataset = "tank/persist";  # Override default
  parentMount = "/persist";
};
```

### Service Module
```nix
{ config, lib, ... }:
let
  cfg = config.services.sonarr;
  storageCfg = config.modules.storage.datasets;
in {
  config = lib.mkIf cfg.enable {
    # 1. Declare dataset
    modules.storage.datasets.services.sonarr = {
      recordsize = "16K";
      compression = "lz4";
    };

    # 2. Configure service
    services.sonarr.dataDir = "${storageCfg.parentMount}/sonarr";

    # 3. Permissions
    systemd.tmpfiles.rules = [
      "d ${storageCfg.parentMount}/sonarr 0755 sonarr sonarr - -"
    ];

    # 4. Backup integration
    modules.backup.restic.jobs.sonarr = {
      enable = true;
      paths = [ "${storageCfg.parentMount}/sonarr" ];
    };
  };
}
```

---

## Migration Commands

```bash
# For each service:

# 1. Backup
restic backup /persist/var/lib/sonarr --tag pre-migration

# 2. Deploy config
nixos-rebuild switch

# 3. Verify dataset
zfs list | grep sonarr

# 4. Stop and migrate
systemctl stop sonarr
rsync -avP /persist/var/lib/sonarr/ /persist/sonarr/

# 5. Start and verify
systemctl start sonarr
systemctl status sonarr

# 6. Cleanup (after 24-48h)
rm -rf /persist/var/lib/sonarr
```

---

## Testing Checklist

Per service:
- [ ] Dataset created automatically
- [ ] Properties correct (`zfs get all tank/persist/sonarr`)
- [ ] Service starts
- [ ] Data accessible
- [ ] Backup runs
- [ ] No errors in journal

---

## Troubleshooting

### Dataset not created
```bash
# Check activation script ran
journalctl -u nixos-activation

# Manually trigger (testing)
/nix/store/*-activate/bin/activate
```

### Wrong ZFS properties
```bash
# Check current
zfs get recordsize,compression tank/persist/sonarr

# Fix manually
zfs set recordsize=16K tank/persist/sonarr

# Update config and rebuild
```

### Service won't start
```bash
# Check dependencies
systemctl list-dependencies sonarr.service

# Check permissions
ls -la /persist/sonarr

# Fix ownership
chown -R sonarr:sonarr /persist/sonarr
```

---

## Rollback

```bash
# Per service rollback:
systemctl stop sonarr
rsync /persist/sonarr/ /persist/var/lib/sonarr/
# Revert config
nixos-rebuild switch
systemctl start sonarr
zfs destroy tank/persist/sonarr
```

---

## Timeline

| Phase | Time | Can Start After |
|-------|------|-----------------|
| Phase 1: Storage module | 2-3h | Now |
| Phase 2: Pilot (Sonarr) | 2-3h | Phase 1 |
| Phase 3: All services | 4-8h | Phase 2 |
| Phase 4: Sanoid/Syncoid | 3-4h | Phase 3 |
| Phase 5: Preseed | 4-6h | Phase 4 |
| Phase 6: PostgreSQL PITR | 2-3h | Phase 3 |

**Total**: 17-27 hours over 2-3 weekends

---

## Files Created/Modified by Phase

### Phase 1
- **Create**: `hosts/_modules/nixos/storage/datasets.nix`
- **Modify**: `hosts/_modules/nixos/default.nix`

### Phase 2
- **Create**: `hosts/_modules/nixos/services/sonarr/default.nix` (or modify)
- **Modify**: `hosts/forge/default.nix` (enable module)

### Phase 3
- **Modify**: Multiple service modules

### Phase 4
- **Create**: `hosts/_modules/nixos/replication/zfs.nix`
- **Modify**: `hosts/_modules/nixos/backup.nix` (remove custom snapshots)
- **Modify**: `hosts/_modules/nixos/notifications/default.nix` (add templates)

### Phase 5
- **Modify**: `lib/storage-helpers.nix` (add mkPreseedService)
- **Modify**: Service modules (add preseed integration)
- **Modify**: Notification templates

### Phase 6
- **Create**: `hosts/_modules/nixos/database/postgresql/pitr.nix`
- **Modify**: PostgreSQL service configuration

---

## Success Metrics

- ✅ All services on isolated datasets
- ✅ Automatic dataset creation working
- ✅ ZFS properties optimized per service
- ✅ Backups functioning correctly
- ✅ Replication operational (Phase 4+)
- ✅ Self-healing working (Phase 5+)
- ✅ PostgreSQL PITR capable (Phase 6)
- ✅ No data loss
- ✅ Improved performance
- ✅ Reduced operational overhead

---

## Next Action

Start Phase 1: Create `hosts/_modules/nixos/storage/datasets.nix`

See full implementation details in `persistence-implementation-execution-plan.md`
