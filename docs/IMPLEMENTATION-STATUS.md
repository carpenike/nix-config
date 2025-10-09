# Persistence Implementation - Status Tracker

**Last Updated**: 2025-10-09
**Current Phase**: Ready to Start Phase 1

---

## Quick Status Overview

| Phase | Status | Progress | Notes |
|-------|--------|----------|-------|
| Phase 0: Foundation | ✅ Complete | 100% | Existing infrastructure validated |
| Phase 1: Storage Module | 🔵 Ready | 0% | Next to implement |
| Phase 2: Pilot Service | ⚪ Pending | 0% | After Phase 1 |
| Phase 3: All Services | ⚪ Pending | 0% | After Phase 2 |
| Phase 4: Sanoid/Syncoid | ⚪ Pending | 0% | After Phase 3 |
| Phase 5: Preseed | ⚪ Pending | 0% | After Phase 4 |
| Phase 6: PostgreSQL PITR | ⚪ Optional | 0% | If using PostgreSQL |

**Legend**: ✅ Complete | 🟢 In Progress | 🔵 Ready | ⚪ Pending | 🔴 Blocked

---

## Phase 1: Storage Dataset Module

**Goal**: Create declarative ZFS dataset management module

### Tasks

- [ ] Create `hosts/_modules/nixos/storage/datasets.nix`
  - [ ] Define options structure
  - [ ] Implement activation script
  - [ ] Add idempotency checks
  - [ ] Test dataset creation

- [ ] Import module in `hosts/_modules/nixos/default.nix`

- [ ] Test on forge host
  - [ ] Enable module with tank pool config
  - [ ] Verify activation script runs
  - [ ] Check no errors in rebuild

**Files to Create**:
- `hosts/_modules/nixos/storage/datasets.nix` (new module)

**Files to Modify**:
- `hosts/_modules/nixos/default.nix` (add import)

**Estimated Time**: 2-3 hours

**Started**: _____
**Completed**: _____

---

## Phase 2: Pilot Service (Sonarr)

**Goal**: Migrate one service to validate pattern

### Tasks

- [ ] Create/update Sonarr service module
  - [ ] Add dataset declaration
  - [ ] Configure dataDir
  - [ ] Set up tmpfiles rules
  - [ ] Integrate backup job

- [ ] Migrate data on forge
  - [ ] Backup current data
  - [ ] Deploy config
  - [ ] Verify dataset created
  - [ ] Stop service & migrate data
  - [ ] Start service & verify
  - [ ] Clean up old data

**Files to Create/Modify**:
- `hosts/_modules/nixos/services/sonarr/default.nix`

**Estimated Time**: 2-3 hours

**Started**: _____
**Completed**: _____

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
