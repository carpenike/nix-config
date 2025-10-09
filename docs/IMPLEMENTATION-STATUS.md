# Persistence Implementation - Status Tracker

**Last Updated**: 2025-10-09
**Current Phase**: Phase 1 Complete - Ready for Phase 2

---

## Quick Status Overview

| Phase | Status | Progress | Notes |
|-------|--------|----------|-------|
| Phase 0: Foundation | ✅ Complete | 100% | Existing infrastructure validated |
| Phase 1: Storage Module | ✅ Complete | 100% | Module production-ready (2 code reviews) |
| Phase 2: Pilot Service | 🔵 Ready | 0% | Next to implement |
| Phase 3: All Services | ⚪ Pending | 0% | After Phase 2 |
| Phase 4: Sanoid/Syncoid | ⚪ Pending | 0% | After Phase 3 |
| Phase 5: Preseed | ⚪ Pending | 0% | After Phase 4 |
| Phase 6: PostgreSQL PITR | ⚪ Optional | 0% | If using PostgreSQL |

**Legend**: ✅ Complete | 🟢 In Progress | 🔵 Ready | ⚪ Pending | 🔴 Blocked

---

## Phase 1: Storage Dataset Module ✅ COMPLETE

**Goal**: Create declarative ZFS dataset management module

### Tasks

- [x] Create `hosts/_modules/nixos/storage/datasets.nix`
  - [x] Define options structure (parentDataset, services)
  - [x] Implement activation script with idempotency
  - [x] Add property validation (recordsize regex, compression enum)
  - [x] Add shell escaping for security
  - [x] Add configurable permissions (owner/group/mode)
  - [x] Add mountpoint validation assertions

- [x] Import module in `hosts/_modules/nixos/default.nix`

- [x] Architecture validation
  - [x] Validated with Gemini Pro + O3-mini
  - [x] Decision: tank/services (not tank/persist)
  - [x] Parent dataset: mountpoint=none (logical container)
  - [x] Service datasets: mount to FHS paths

- [x] Test on forge host
  - [x] Enable module with tank/services config
  - [x] dry-build passes successfully
  - [x] Verified activation script logic

- [x] Code review (Gemini Pro)
  - [x] First review: 9/10 (EXCELLENT)
  - [x] Applied fixes: shell escaping, validation, permissions
  - [x] Second review: 10/10 (EXCELLENT) - Production ready

**Files Created**:
- ✅ `hosts/_modules/nixos/storage/datasets.nix` (268 lines)

**Files Modified**:
- ✅ `hosts/_modules/nixos/default.nix` (added import)
- ✅ `hosts/forge/default.nix` (configured for tank/services)
- ✅ `hosts/forge/disko-config.nix` (added tank/services dataset)
- ✅ `hosts/_modules/nixos/filesystems/zfs/default.nix` (added persistDataset/homeDataset options)

**Time Spent**: ~4 hours (including reviews and fixes)

**Started**: 2025-10-09
**Completed**: 2025-10-09

### Key Decisions Made:
- **Architecture**: Validated layered approach (disko creates parents, module creates children)
- **Naming**: `tank/services` over `tank/persist` (semantic clarity)
- **Mount Strategy**: Parent dataset unmounted, services mount to FHS paths
- **Defaults**: Single-disk systems use `rpool/safe/persist`, multi-disk override
- **Security**: Comprehensive shell escaping with `lib.escapeShellArg`
- **Validation**: Build-time type checking for recordsize and compression---

## Phase 2: Pilot Service (Sonarr)

**Status**: 🔵 In Progress 80%

**Current Phase**: Module created, testing complete - Ready for deployment

**Goal**: Migrate one service to validate pattern

### Tasks

- [x] Create/update Sonarr service module
  - [x] Add dataset declaration (recordsize=16K, compression=zstd)
  - [x] Configure dataDir (/var/lib/sonarr)
  - [x] Set up tmpfiles rules (0700 sonarr:sonarr)
  - [x] Integrate backup job (Restic with excludes)
  - [x] Add user/group creation (UID/GID 568)
  - [x] Configure Podman container (linuxserver/sonarr)
  - [x] Test with dry-build (525 derivations - PASSED)

- [ ] Migrate data on forge (DEPLOYMENT PHASE - Not Yet Executed)
  - [ ] Backup current data (if exists)
  - [ ] Deploy config (nixos-rebuild switch)
  - [ ] Verify dataset created (zfs list | grep sonarr)
  - [ ] Stop service & migrate data (if migrating existing data)
  - [ ] Start service & verify (systemctl status, web UI)
  - [ ] Clean up old data (after validation)

**Files Created/Modified**:
- Created: `hosts/_modules/nixos/services/sonarr/default.nix` (152 lines)
  - ZFS dataset declaration with optimal properties
  - Podman container configuration
  - User/group management
  - Backup integration
  - Comprehensive comments
- Modified: `hosts/_modules/nixos/services/default.nix` (added sonarr import)
- Modified: `hosts/forge/default.nix` (enabled sonarr service)

**Configuration Details**:
```nix
# Dataset Configuration (tank/services/sonarr)
recordsize = "16K"        # Optimal for SQLite
compression = "zstd"       # Better compression for text/config
mountpoint = "/var/lib/sonarr"
owner = "sonarr:sonarr"    # UID/GID 568
mode = "0700"              # Restrictive permissions

# Backup Configuration
repository = "nas-primary"
excludes = [".cache", "cache", "*.tmp", "logs/*.txt"]
tags = ["sonarr", "media", "database"]
```

**Estimated Time**: 2-3 hours

**Started**: 2025-10-09
**Completed (Module)**: 2025-10-09
**Deployment**: Pending actual forge deployment

### Migration Procedure (For Actual Deployment)

When ready to deploy to forge:

```bash
# 1. Backup current data (if Sonarr already exists)
restic backup /var/lib/sonarr --tag pre-migration-sonarr

# 2. Deploy configuration
nixos-rebuild switch --flake .#forge

# 3. Verify dataset created
zfs list | grep sonarr
# Expected: tank/services/sonarr mounted at /var/lib/sonarr

# 4. Check dataset properties
zfs get recordsize,compression,mountpoint tank/services/sonarr

# 5. If migrating existing data:
systemctl stop podman-sonarr
rsync -avP /old/sonarr/path/ /var/lib/sonarr/
chown -R sonarr:sonarr /var/lib/sonarr

# 6. Start and verify service
systemctl start podman-sonarr
systemctl status podman-sonarr
curl http://localhost:8989  # Check web UI

# 7. Verify backup integration
restic snapshots | grep sonarr

# 8. Cleanup old data (after thorough validation)
# rm -rf /old/sonarr/path
```

---

## Phase 3: Additional Services

**Goal**: Migrate all services to per-dataset storage

### Services to Migrate

- [ ] Radarr (similar to Sonarr)
- [ ] Plex (large recordsize)
- [ ] Home Assistant (if applicable)
- [ ] PostgreSQL (if applicable)
- [ ] Other services: _________________

**Estimated Time**: 1-2 hours per service

**Started**: _____
**Completed**: _____

---

## Phase 4: Sanoid/Syncoid

**Goal**: Replace custom snapshot logic with declarative Sanoid

### Tasks

- [ ] Create `hosts/_modules/nixos/replication/zfs.nix`
- [ ] Configure Sanoid for datasets
- [ ] Set up Syncoid replication
- [ ] Add notification templates
- [ ] Remove custom snapshot logic from backup.nix
- [ ] Test snapshot creation and replication

**Estimated Time**: 3-4 hours

**Started**: _____
**Completed**: _____

---

## Phase 5: Preseed Services

**Goal**: Implement self-healing restore automation

### Tasks

- [ ] Add `mkPreseedService` to `lib/storage-helpers.nix`
- [ ] Create preseed service template
- [ ] Integrate with service modules
- [ ] Add notification templates
- [ ] Test restore automation
- [ ] Document restore procedures

**Estimated Time**: 4-6 hours

**Started**: _____
**Completed**: _____

---

## Phase 6: PostgreSQL PITR (Optional)

**Goal**: Add database-specific PITR capability

### Tasks

- [ ] Create `hosts/_modules/nixos/database/postgresql/pitr.nix`
- [ ] Configure Barman-Cloud
- [ ] Set up WAL archival
- [ ] Create base backup schedule
- [ ] Exclude from general backups
- [ ] Test PITR restore

**Estimated Time**: 2-3 hours

**Started**: _____
**Completed**: _____

---

## Issues & Notes

### Blockers

- None currently

### Decisions Made

1. **Automatic dataset creation** - Via activation scripts, validated by Gemini Pro & O3
2. **Host-level pool config** - forge uses `tank`, others use `rpool`
3. **Hybrid mount strategy** - Legacy for base, auto-mount for services
4. **Breaking changes OK** - Homelab environment allows fast iteration

### Lessons Learned

_(To be filled in during implementation)_

---

## Next Action

**Start Phase 1**: Create the storage datasets module

```bash
# Create the module file
touch hosts/_modules/nixos/storage/datasets.nix

# Start implementation following execution plan
# See: docs/persistence-implementation-execution-plan.md
```

---

## Documentation References

- **Execution Plan**: `docs/persistence-implementation-execution-plan.md`
- **Original Concept**: `docs/persistence-implementation-plan.md`
- **Analysis Results**: Conversation with Gemini Pro 2.5 & O3-mini (2025-10-09)
