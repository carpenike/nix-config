# Pre-Deployment Backup Orchestrator v2

**Status:** Design - Incorporating Gemini Pro Critical Feedback
**Created:** 2025-11-03
**Updated:** 2025-11-03

## Executive Summary

This orchestrator provides on-demand triggering of ALL backup systems across forge before major deployments. Addresses critical issues identified in v1 design review.

### Key Improvements from v1

1. **Pre-flight checks:** Disk space validation before starting backups
2. **Service state verification:** Detect already-running services from timers
3. **PostgreSQL conflict resolution:** Only trigger full backup (avoid stanza lock)
4. **Resource limits:** Limit concurrent Restic jobs to reduce contention
5. **Failure thresholds:** Distinguish between acceptable partial failures vs critical failures
6. **Stage 1 downgrade:** Sanoid failure is WARNING not CRITICAL (automated snapshots every 5min provide fallback)

## Critical Issues Addressed

### Issue #1: PostgreSQL Backup Conflict
**Problem:** v1 triggered both `pgbackrest-full-backup` and `pgbackrest-incr-backup` in parallel, causing stanza lock conflict.
**Solution:** Only trigger `pgbackrest-full-backup` for pre-deployment. Sequential execution before Restic jobs.

### Issue #2: Resource Contention
**Problem:** 16 parallel backup jobs could saturate network, exhaust ZFS ARC, cause OOM.
**Solution:** Limit Restic to 3 concurrent jobs. pgBackRest runs sequentially before Restic stage.

### Issue #3: Service State Race Condition
**Problem:** Can't distinguish orchestrator-triggered backup from timer-triggered backup.
**Solution:** Check `systemctl is-active` before starting. Skip if already running.

### Issue #4: No Disk Space Pre-Flight Checks
**Problem:** Backups could fail due to full disk, reported as "partial failure" with no new backups.
**Solution:** Check `/mnt/nas-backup` (50GB min) and `/mnt/nas-postgresql` (20GB min) before starting.

### Issue #5: Stage 1 Criticality Too Strict
**Problem:** Treating Sanoid failure as CRITICAL is overly strict - automated Sanoid runs every 5min anyway.
**Solution:** Downgrade to WARNING. Continue with existing snapshots if Sanoid fails.

## Stage Execution Order

### Stage 0: Pre-Flight Checks
**Purpose:** Verify system readiness before starting backups
**Checks:**
- `/mnt/nas-backup` has ≥50GB available
- `/mnt/nas-postgresql` has ≥20GB available
**Failure Handling:** CRITICAL - exit immediately if checks fail

### Stage 1: ZFS Snapshots (WARNING - not critical)
**Purpose:** Create fresh ZFS snapshots for all datasets
**Service:** `sanoid.service`
**Timeout:** 5 minutes
**Failure Handling:** WARNING only - continue with existing snapshots (automated Sanoid runs every 5min, so recent snapshots always exist)

### Stage 2: ZFS Replication (Parallel execution, wait for all)
**Purpose:** Replicate ZFS datasets to nas-1 for offsite redundancy
**Services:** All `syncoid-*` services (7 replication jobs), filtered to exclude utility services:
- Exclude: `syncoid-replication-info` (monitoring utility)
- Exclude: `syncoid-target-reachability` (health check utility)
**Timeout:** 30 minutes per service
**Failure Handling:** Non-critical - continue, aggregate failures, report at end

### Stage 3a: PostgreSQL Backup (Sequential)
**Purpose:** Full PostgreSQL cluster backup (all databases)
**Service:** `pgbackrest-full-backup.service` ONLY (avoid stanza lock with incremental)
**Timeout:** 1 hour
**Failure Handling:** Non-critical - continue to Restic even if fails

### Stage 3b: Restic Application Backups (Limited parallel execution)
**Purpose:** Backup application data to offsite storage (R2 + NFS)
**Services:** All `restic-backup-*` services (6 jobs: plex, dispatcharr, sonarr, radarr, prowlarr, lidarr)
**Concurrency Limit:** 3 simultaneous jobs (reduce network/CPU contention)
**Timeout:** 45 minutes per service
**Failure Handling:** Non-critical - continue, aggregate failures, report at end

### Stage 4: Verification and Reporting
**Purpose:** Aggregate results and determine exit code
**Exit Codes:**
- **0**: All backups completed successfully
- **1**: Partial failure (<50% failure rate) - acceptable for deployment
- **2**: Critical failure (>50% failure rate or pre-flight checks failed) - DO NOT deploy

## Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Pre-flight checks
check_disk_space() {
    local path=$1
    local min_free_gb=$2
    local available_gb=$(df -BG "$path" | tail -1 | awk '{print $4}' | sed 's/G//')

    if [ "$available_gb" -lt "$min_free_gb" ]; then
        log_error "Insufficient space on $path: ${available_gb}GB available, need ${min_free_gb}GB"
        return 1
    fi
    log_info "Disk space check passed: $path has ${available_gb}GB available"
    return 0
}

# Service state verification
check_service_idle() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        return 1
    fi
    return 0
}

# Track results
declare -A failed_services
declare -A success_services
declare -A timeout_services
declare -A skipped_services

# Parse command line arguments
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Stage 0: Pre-flight checks
log_info "========================================="
log_info "Stage 0: Pre-Flight Checks"
log_info "========================================="

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would check disk space on /mnt/nas-backup and /mnt/nas-postgresql"
else
    if ! check_disk_space "/mnt/nas-backup" 50; then
        log_error "Pre-flight check failed: insufficient space on nas-backup"
        exit 2
    fi
    if ! check_disk_space "/mnt/nas-postgresql" 20; then
        log_error "Pre-flight check failed: insufficient space on nas-postgresql"
        exit 2
    fi
    log_info "Pre-flight checks passed"
fi

# Stage 1: Force Sanoid snapshots (WARNING only - not critical)
log_info "========================================="
log_info "Stage 1: Creating ZFS snapshots (Sanoid)"
log_info "========================================="

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would start: sanoid.service"
else
    # Check if already running
    if ! check_service_idle "sanoid.service"; then
        log_warn "Sanoid already running from timer - skipping manual trigger"
        skipped_services["sanoid.service"]="already-running"
    else
        log_info "Starting sanoid.service..."
        systemctl start sanoid.service

        # Wait for completion with timeout
        timeout=300  # 5 minutes
        elapsed=0
        while systemctl is-active --quiet sanoid.service; do
            sleep 2
            elapsed=$((elapsed + 2))
            if [ $elapsed -ge $timeout ]; then
                log_warn "sanoid.service timed out after ${timeout}s"
                systemctl stop sanoid.service 2>/dev/null || true
                timeout_services["sanoid.service"]=1
                break
            fi
        done

        # Check result (non-critical)
        result=$(systemctl show -p Result --value sanoid.service)
        if [ "$result" != "success" ]; then
            log_warn "sanoid.service failed with result: $result (continuing with existing snapshots)"
            failed_services["sanoid.service"]="$result"
        else
            success_services["sanoid.service"]=1
            log_info "Stage 1 complete: Sanoid snapshots created successfully"
        fi
    fi
fi

# Stage 2: ZFS Replication (Syncoid) - PARALLEL within stage
log_info "========================================="
log_info "Stage 2: ZFS Replication (Syncoid)"
log_info "========================================="

# Discover syncoid services, excluding utility services
mapfile -t syncoid_services < <(systemctl list-units --all --type=service 'syncoid-*.service' --no-pager --plain | awk '{print $1}' | grep -E '^syncoid-.*\.service$' | grep -v 'replication-info\|target-reachability')

log_info "Found ${#syncoid_services[@]} Syncoid replication jobs"

declare -A pids

if [ "$DRY_RUN" = true ]; then
    for service in "${syncoid_services[@]}"; do
        log_info "[DRY RUN] Would start: $service"
    done
else
    # Start all services in parallel
    for service in "${syncoid_services[@]}"; do
        # Skip if already running
        if ! check_service_idle "$service"; then
            log_warn "$service already running - skipping"
            skipped_services["$service"]="already-running"
            continue
        fi

        log_info "Starting $service..."
        systemctl start "$service" &
        pids["$service"]=$!
    done

    # Wait for all services with timeout
    timeout=1800  # 30 minutes per service
    for service in "${!pids[@]}"; do
        elapsed=0
        while systemctl is-active --quiet "$service"; do
            sleep 5
            elapsed=$((elapsed + 5))
            if [ $elapsed -ge $timeout ]; then
                log_warn "$service timed out after ${timeout}s"
                systemctl stop "$service" 2>/dev/null || true
                timeout_services["$service"]=1
                break
            fi
        done

        # Check result if not timed out
        if [ -z "${timeout_services[$service]}" ]; then
            result=$(systemctl show -p Result --value "$service")
            if [ "$result" != "success" ]; then
                log_warn "$service failed with result: $result"
                failed_services["$service"]="$result"
            else
                success_services["$service"]=1
            fi
        fi
    done

    log_info "Stage 2 complete"
fi

# Stage 3a: PostgreSQL backup (pgBackRest) - SEQUENTIAL
log_info "================================================"
log_info "Stage 3a: PostgreSQL backup (pgBackRest)"
log_info "================================================"

# Only trigger full backup (avoid stanza lock conflict with incremental)
pgbackrest_service="pgbackrest-full-backup.service"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would start: $pgbackrest_service"
else
    # Check if already running
    if ! check_service_idle "$pgbackrest_service"; then
        log_warn "$pgbackrest_service already running - skipping"
        skipped_services["$pgbackrest_service"]="already-running"
    else
        log_info "Starting $pgbackrest_service..."
        systemctl start "$pgbackrest_service"

        # Wait for pgBackRest to complete (sequential)
        timeout=3600  # 1 hour
        elapsed=0
        while systemctl is-active --quiet "$pgbackrest_service"; do
            sleep 5
            elapsed=$((elapsed + 5))
            if [ $elapsed -ge $timeout ]; then
                log_warn "$pgbackrest_service timed out after ${timeout}s"
                systemctl stop "$pgbackrest_service" 2>/dev/null || true
                timeout_services["$pgbackrest_service"]=1
                break
            fi
        done

        # Check result
        result=$(systemctl show -p Result --value "$pgbackrest_service")
        if [ "$result" != "success" ]; then
            log_warn "$pgbackrest_service failed with result: $result"
            failed_services["$pgbackrest_service"]="$result"
        else
            success_services["$pgbackrest_service"]=1
            log_info "pgBackRest full backup completed successfully"
        fi
    fi
fi

# Stage 3b: Application backups (Restic) - LIMITED PARALLEL
log_info "================================================"
log_info "Stage 3b: Application backups (Restic)"
log_info "================================================"

# Discover Restic backup services
mapfile -t restic_services < <(systemctl list-units --all --type=service 'restic-backup-*.service' --no-pager --plain | awk '{print $1}' | grep -E '^restic-backup-.*\.service$')

log_info "Found ${#restic_services[@]} Restic backup services"

if [ "$DRY_RUN" = true ]; then
    for service in "${restic_services[@]}"; do
        log_info "[DRY RUN] Would start: $service (limited to 3 concurrent)"
    done
else
    # Start services with concurrency limit
    concurrent_limit=3
    declare -a active_services=()

    for service in "${restic_services[@]}"; do
        # Skip if already running
        if ! check_service_idle "$service"; then
            log_warn "$service already running - skipping"
            skipped_services["$service"]="already-running"
            continue
        fi

        # Wait if at concurrent limit
        while [ ${#active_services[@]} -ge $concurrent_limit ]; do
            # Check which services have completed
            for i in "${!active_services[@]}"; do
                if ! systemctl is-active --quiet "${active_services[$i]}"; then
                    unset 'active_services[$i]'
                fi
            done
            active_services=("${active_services[@]}")  # Reindex array

            if [ ${#active_services[@]} -ge $concurrent_limit ]; then
                sleep 5
            fi
        done

        log_info "Starting $service (${#active_services[@]}/$concurrent_limit active)..."
        systemctl start "$service"
        active_services+=("$service")
    done

    # Wait for all remaining services with timeout
    timeout=2700  # 45 minutes per service
    for service in "${restic_services[@]}"; do
        # Skip if it was skipped earlier
        if [ -n "${skipped_services[$service]}" ]; then
            continue
        fi

        elapsed=0
        while systemctl is-active --quiet "$service"; do
            sleep 5
            elapsed=$((elapsed + 5))
            if [ $elapsed -ge $timeout ]; then
                log_warn "$service timed out after ${timeout}s"
                systemctl stop "$service" 2>/dev/null || true
                timeout_services["$service"]=1
                break
            fi
        done

        # Check result if not timed out
        if [ -z "${timeout_services[$service]}" ]; then
            result=$(systemctl show -p Result --value "$service")
            if [ "$result" != "success" ]; then
                log_warn "$service failed with result: $result"
                failed_services["$service"]="$result"
            else
                success_services["$service"]=1
            fi
        fi
    done

    log_info "Stage 3 complete"
fi

# Stage 4: Verification and reporting
log_info "========================================"
log_info "Stage 4: Verification and Final Report"
log_info "========================================"

total_attempted=$((${#success_services[@]} + ${#failed_services[@]} + ${#timeout_services[@]} + ${#skipped_services[@]}))
log_info "Total services: $total_attempted"
log_info "Successful: ${#success_services[@]}"
log_info "Failed: ${#failed_services[@]}"
log_info "Timed out: ${#timeout_services[@]}"
log_info "Skipped (already running): ${#skipped_services[@]}"

if [ ${#skipped_services[@]} -gt 0 ]; then
    log_warn "Skipped services (already running from timers):"
    for service in "${!skipped_services[@]}"; do
        log_warn "  - $service"
    done
fi

if [ ${#failed_services[@]} -gt 0 ]; then
    log_error "Failed services:"
    for service in "${!failed_services[@]}"; do
        log_error "  - $service: ${failed_services[$service]}"
    done
fi

if [ ${#timeout_services[@]} -gt 0 ]; then
    log_error "Timed out services:"
    for service in "${!timeout_services[@]}"; do
        log_error "  - $service"
    done
fi

# Calculate failure threshold (>50% failures is critical)
total_executed=$((${#success_services[@]} + ${#failed_services[@]} + ${#timeout_services[@]}))
total_failures=$((${#failed_services[@]} + ${#timeout_services[@]}))
failure_rate=0
if [ $total_executed -gt 0 ]; then
    failure_rate=$((total_failures * 100 / total_executed))
fi

# Exit with appropriate code
if [ ${#failed_services[@]} -eq 0 ] && [ ${#timeout_services[@]} -eq 0 ]; then
    log_info "All backups completed successfully!"
    exit 0
elif [ $failure_rate -gt 50 ]; then
    log_error "CRITICAL: More than 50% of backups failed (${failure_rate}%)"
    exit 2
else
    log_warn "Partial failure: ${failure_rate}% of backups did not complete successfully"
    log_warn "This is within acceptable threshold for deployment"
    exit 1
fi
```

## Integration

### NixOS Package

Create `/pkgs/backup-orchestrator.nix`:

```nix
{ pkgs, lib, ... }:

pkgs.writeShellApplication {
  name = "backup-orchestrator";

  runtimeInputs = with pkgs; [
    coreutils
    systemd
    gawk
    gnugrep
  ];

  text = builtins.readFile ./backup-orchestrator.sh;
}
```

### Add to Package Set

In `/pkgs/default.nix`:

```nix
{
  # ... existing packages ...
  backup-orchestrator = pkgs.callPackage ./backup-orchestrator.nix { };
}
```

### Install on forge

In `/hosts/forge/default.nix`:

```nix
{
  environment.systemPackages = with pkgs; [
    # ... existing packages ...
    backup-orchestrator
  ];
}
```

### Taskfile Integration

Add to `/Taskfile.yaml`:

```yaml
backup:orchestrate:
  desc: "Trigger all backup systems before deployment"
  cmds:
    - ssh forge.holthome.net "sudo backup-orchestrator"
```

## Usage

### Manual Pre-Deployment Backup

```bash
# From development machine
task backup:orchestrate

# Or directly on forge
ssh forge.holthome.net
sudo backup-orchestrator
```

### Dry Run Mode

```bash
backup-orchestrator --dry-run
```

### Verbose Output

```bash
backup-orchestrator --verbose
```

## Expected Behavior

### Success Scenario

```
[INFO] Stage 0: Pre-Flight Checks
[INFO] Disk space check passed: /mnt/nas-backup has 120GB available
[INFO] Disk space check passed: /mnt/nas-postgresql has 45GB available
[INFO] Pre-flight checks passed
[INFO] Stage 1: Creating ZFS snapshots (Sanoid)
[INFO] Starting sanoid.service...
[INFO] Stage 1 complete: Sanoid snapshots created successfully
[INFO] Stage 2: ZFS Replication (Syncoid)
[INFO] Found 7 Syncoid replication jobs
[INFO] Starting syncoid-tank-services-plex.service...
[INFO] Starting syncoid-tank-services-radarr.service...
...
[INFO] Stage 2 complete
[INFO] Stage 3a: PostgreSQL backup (pgBackRest)
[INFO] Starting pgbackrest-full-backup.service...
[INFO] pgBackRest full backup completed successfully
[INFO] Stage 3b: Application backups (Restic)
[INFO] Found 6 Restic backup services
[INFO] Starting restic-backup-plex (0/3 active)...
[INFO] Starting restic-backup-dispatcharr (1/3 active)...
[INFO] Starting restic-backup-sonarr (2/3 active)...
[INFO] Starting restic-backup-radarr (1/3 active)...
...
[INFO] Stage 3 complete
[INFO] Stage 4: Verification and Final Report
[INFO] Total services: 15
[INFO] Successful: 15
[INFO] Failed: 0
[INFO] Timed out: 0
[INFO] Skipped (already running): 0
[INFO] All backups completed successfully!
```

### Partial Failure Scenario

```
...
[WARN] syncoid-tank-services-prowlarr.service failed with result: exit-code
[WARN] restic-backup-lidarr timed out after 2700s
...
[INFO] Stage 4: Verification and Final Report
[INFO] Total services: 15
[INFO] Successful: 13
[INFO] Failed: 1
[INFO] Timed out: 1
[ERROR] Failed services:
[ERROR]   - syncoid-tank-services-prowlarr.service: exit-code
[ERROR] Timed out services:
[ERROR]   - restic-backup-lidarr
[WARN] Partial failure: 13% of backups did not complete successfully
[WARN] This is within acceptable threshold for deployment
```

### Critical Failure Scenario

```
[ERROR] Insufficient space on /mnt/nas-backup: 12GB available, need 50GB
[ERROR] Pre-flight check failed: insufficient space on nas-backup
Exit code: 2
```

## Operational Considerations

### Timing Recommendations

**Best Time to Run:**
- Off-peak hours (avoid 9am-5pm when databases are active)
- After automated backups have completed (check timer schedules)
- Allow 1-2 hours for completion before deployment window

**Worst Time to Run:**
- During business hours (PostgreSQL backup causes load)
- Simultaneously with automated backup timers (service conflicts)
- During existing maintenance windows (resource contention)

### Resource Impact

**Network:**
- Stage 2: 7 simultaneous Syncoid jobs → high NAS traffic
- Stage 3b: 3 simultaneous Restic jobs → R2 upload bandwidth

**CPU:**
- Restic deduplication: 1-2 cores per job
- pgBackRest compression: 2-4 cores during full backup

**Memory:**
- Restic: 1-2GB per job
- pgBackRest: 500MB-1GB during backup

**Disk I/O:**
- ZFS snapshot creation: minimal
- Syncoid replication: read-heavy on source datasets
- Restic: read-heavy on source + write to temporary snapshots
- pgBackRest: read-heavy on PostgreSQL data directory

### Monitoring Integration

Orchestrator success/failure can be monitored via:
- Exit code from task/script execution
- journald logs: `journalctl -u backup-orchestrator -f`
- systemd service metrics (if wrapped in systemd service)
- Existing notification hooks (ntfy, healthchecks, etc.)

## Testing Strategy

### Test 1: Dry Run

```bash
backup-orchestrator --dry-run
# Expected: Shows what would execute without actually starting services
```

### Test 2: Stage Isolation

```bash
# Manually trigger each stage's services individually
systemctl start sanoid.service
systemctl start syncoid-tank-services-plex.service
systemctl start restic-backup-plex.service
systemctl start pgbackrest-full-backup.service
```

### Test 3: Concurrent Limit

```bash
# While orchestrator is running Stage 3b, verify:
systemctl list-units --state=active 'restic-backup-*.service'
# Expected: No more than 3 active at once
```

### Test 4: Service Already Running

```bash
# Start a service manually, then run orchestrator
systemctl start restic-backup-plex.service
backup-orchestrator
# Expected: Skips restic-backup-plex with warning
```

### Test 5: Pre-Flight Failure

```bash
# Fill disk to trigger pre-flight failure
dd if=/dev/zero of=/mnt/nas-backup/testfile bs=1G count=100
backup-orchestrator
# Expected: Exits with code 2 before starting any backups
```

## Next Steps

1. **Create implementation file:** `/pkgs/backup-orchestrator.sh` with full bash script
2. **Create NixOS package:** `/pkgs/backup-orchestrator.nix`
3. **Add to package set:** Update `/pkgs/default.nix`
4. **Install on forge:** Update `/hosts/forge/default.nix`
5. **Add Taskfile task:** Update `/Taskfile.yaml`
6. **Test in staging:** Run dry-run and verify behavior
7. **Production validation:** Test during low-traffic window
