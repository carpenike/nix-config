# Persistence Implementation - Status Tracker

**Last Updated**: 2025-10-09
**Current Phase**: Phase 2 Complete (Module) - Ready for Phase 3

---

## Quick Status Overview

| Phase | Status | Progress | Notes |
|-------|--------|----------|-------|
| Phase 0: Foundation | ✅ Complete | 100% | Existing infrastructure validated |
| Phase 1: Storage Module | ✅ Complete | 100% | Module production-ready (2 code reviews) |
| Phase 2: Pilot Service | ✅ Complete | 100% | Module complete, deployment pending |
| Phase 3: All Services | 🔵 Ready | 0% | Ready to replicate Sonarr pattern |
| Phase 4: Sanoid/Syncoid | 🟡 Partial | 50% | Already configured on forge |
| Phase 5: Preseed | 🟡 Partial | 50% | Implemented in Sonarr, needs templates |
| Phase 6: PostgreSQL PITR | ⚪ Optional | 0% | If using PostgreSQL |

**Legend**: ✅ Complete | 🟢 In Progress | 🟡 Partial | 🔵 Ready | ⚪ Pending | 🔴 Blocked

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

## Phase 2: Pilot Service (Sonarr) ✅ COMPLETE

**Status**: ✅ Module Implementation Complete 100%

**Current Phase**: Code complete and production-ready. Actual deployment/migration pending.

**Goal**: Create pilot service module to validate the per-service dataset pattern

### Tasks

- [x] Create/update Sonarr service module
  - [x] Add dataset declaration (recordsize=16K, compression=zstd)
  - [x] Configure dataDir (/var/lib/sonarr)
  - [x] ~~Set up tmpfiles rules (0700 sonarr:sonarr)~~ → Removed (handled by storage.datasets)
  - [x] Integrate backup job (Restic with excludes)
  - [x] Add user/group creation (UID/GID 568)
  - [x] Configure Podman container (linuxserver/sonarr)
  - [x] Test with dry-build (525 derivations - PASSED)

- [x] Apply code review improvements (Gemini Pro 2.5)
  - [x] Remove unused imports (pkgs, storageCfg)
  - [x] Add media group integration (extraGroups + group creation)
  - [x] Remove redundant tmpfiles rule (now handled by datasets module)
  - [x] Add container health check (Podman --health-* flags)
  - [x] Make backup repository configurable (backup.repository option)
  - [x] Add failure notifications (systemd OnFailure + template registration)
  - [x] Test all changes (dry-build passed)

- [ ] Migrate data on forge (DEPLOYMENT PHASE - Not Yet Executed)
  - [ ] Backup current data (if exists)
  - [ ] Deploy config (nixos-rebuild switch)
  - [ ] Verify dataset created (zfs list | grep sonarr)
  - [ ] Stop service & migrate data (if migrating existing data)
  - [ ] Start service & verify (systemctl status, web UI)
  - [ ] Clean up old data (after validation)

**Files Created/Modified**:

- Created: `hosts/_modules/nixos/services/sonarr/default.nix` (354 lines)
  - ZFS dataset declaration with optimal properties (recordsize=16K, compression=zstd)
  - Podman container configuration with resource limits
  - User/group management with media group integration
  - Container health check (Podman native with 90s start period)
  - Backup integration with centralized primaryRepo pattern
  - Notification integration (failure alerts)
  - **Preseed service** (self-healing restore automation) 🎉
  - Comprehensive comments explaining all technical choices
- Modified: `hosts/_modules/nixos/services/default.nix` (added sonarr import)
- Modified: `hosts/forge/default.nix` (enabled sonarr with all features)
- Created: `hosts/_modules/nixos/storage/helpers-lib.nix` (preseed service generator)

**Configuration Details (After Improvements)**:

```nix
# Dataset Configuration (tank/services/sonarr)
recordsize = "16K"        # Optimal for SQLite
compression = "zstd"       # Better compression for text/config
mountpoint = "/var/lib/sonarr"
owner = "sonarr:sonarr"    # UID/GID 568
mode = "0700"              # Restrictive permissions

# User Configuration
extraGroups = ["media"]    # NFS mount access

# Health Check
enable = true
interval = "1m"
timeout = "10s"
retries = 3

# Backup Configuration
enable = true
repository = "nas-primary" # Now configurable!
excludes = [".cache", "cache", "*.tmp", "logs/*.txt"]
tags = ["sonarr", "media", "database"]

# Notifications
enable = true
priority = "high"
template = "sonarr-failure"
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

## Phase 4: Sanoid/Syncoid 🟡 PARTIAL

**Status**: 🟡 Partially Complete (50%)

**Goal**: Replace custom snapshot logic with declarative Sanoid

### Tasks

- [x] Configure Sanoid for datasets on forge
  - [x] Production template (48h hourly, 30d daily, 3m monthly)
  - [x] Services template (24h hourly, 7d daily, no monthly)
  - [x] Applied to tank/services and rpool/safe/persist
- [x] Add notification templates (already integrated)
- [ ] Create formal `hosts/_modules/nixos/replication/zfs.nix` module (optional - forge config works)
- [ ] Set up Syncoid replication to backup server
- [ ] Remove custom snapshot logic from backup.nix (if desired)
- [ ] Test snapshot creation and replication to remote

**Note**: Sanoid is already working on forge with proper retention policies. This phase is mostly about:
1. Replicating the pattern to other hosts
2. Adding Syncoid for remote replication
3. Optionally creating a reusable module

**Files Modified**:
- `hosts/forge/default.nix` (lines 114-184): Full Sanoid configuration

**Estimated Time**: 2-3 hours (for Syncoid + module creation)

**Started**: 2025-10-09 (forge configuration)
**Completed**: Partial - Core Sanoid working

---

## Phase 5: Preseed Services 🟡 PARTIAL

**Status**: 🟡 Partially Complete (50%)

**Goal**: Implement self-healing restore automation

### Tasks

- [x] Add `mkPreseedService` to `hosts/_modules/nixos/storage/helpers-lib.nix` 🎉
- [x] Create preseed service template (systemd oneshot with ZFS + Restic fallback)
- [x] Integrate with Sonarr module
- [x] Add notification templates (success/failure)
- [x] Test restore automation logic (dry-build passed)
- [ ] Create templates for additional services (Radarr, Plex, etc.)
- [ ] Document preseed usage pattern for service modules
- [ ] Test actual restore scenarios on forge

**Implementation Details**:
- Three-tier restore strategy: ZFS rollback → ZFS snapshot → Restic backup
- Runs before service starts (systemd Before= dependency)
- Configurable paths for selective restore
- Success/failure notifications via centralized system

**Files Created**:
- `hosts/_modules/nixos/storage/helpers-lib.nix` (136 lines)

**Files Modified**:
- `hosts/_modules/nixos/services/sonarr/default.nix` (preseed integration)
- `hosts/forge/default.nix` (preseed configuration)

**Estimated Time**: 1-2 hours (for additional service templates)

**Started**: 2025-10-09
**Completed**: Core implementation done, needs templates
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
