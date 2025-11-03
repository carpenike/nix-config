# Pre-Deployment Backup Orchestrator

**Purpose:** Single command to trigger comprehensive backups across all systems before major deployments.

**Status:** Design Complete - Ready for Implementation
**Expert Review:** Gemini Pro 2.5 - Validated ✅

---

## Overview

This orchestrator provides on-demand execution of ALL backup systems before major system changes (NixOS rebuilds, kernel updates, configuration migrations). It coordinates existing systemd services rather than reimplementing backup logic.

## Problem Statement

Current backup infrastructure runs on independent timers:
- **Sanoid**: ZFS snapshots every 5 minutes (7 datasets)
- **Syncoid**: ZFS replication to nas-1 every 15 minutes (7 jobs)
- **Restic**: 6 application backup jobs with automatic ZFS snapshot coordination
- **pgBackRest**: PostgreSQL backups with incremental and full backup schedules

**Gap:** No on-demand orchestration to trigger ALL backup systems synchronously before deployment.

## Key Architectural Insight

**The backup system already implements proper snapshot coordination.** When Restic jobs have `useSnapshots = true`:
- Systemd automatically starts `zfs-snapshot-${jobName}` service via `bindsTo` relationship
- The snapshot service creates: ZFS snapshot → clone snapshot → mount clone
- Restic backs up from the **clone mountpoint** (not live filesystem, not .zfs/snapshot)
- After backup completes, clone and temporary snapshot are automatically destroyed

**Services using this pattern:** Plex, Dispatcharr, Sonarr, Grafana, Loki, Omada, Unifi, AdGuard Home

**This orchestrator does NOT need to manage snapshots - it simply triggers existing services.**

---

## Architecture

### Stage-Based Execution

```
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

Stage 2: ZFS Replication (Parallel)
  ├─ syncoid-rpool-safe-home.service
  ├─ syncoid-rpool-safe-persist.service
  ├─ syncoid-tank-services-*.service (multiple)
  └─ Auto-discovered via systemctl list-units
     └─ Timeout: 30 minutes per job
     └─ Must succeed: NO (continue, aggregate failures)

Stage 3: Application Backups (Parallel)
  ├─ Restic Jobs (auto-create temp snapshots):
  │  ├─ restic-backup-plex
  │  ├─ restic-backup-dispatcharr
  │  ├─ restic-backup-sonarr
  │  └─ ... (auto-discovered)
  ├─ pgBackRest Jobs (independent):
  │  ├─ pgbackrest-dispatcharr.service
  │  ├─ pgbackrest-paperless.service
  │  └─ ... (auto-discovered)
  └─ Timeout: 1 hour per job
     └─ Must succeed: NO (continue, aggregate failures)

Stage 4: Verification
  └─ Check systemctl Result property for each service
  └─ Aggregate failures and report
  └─ Exit code: 0=success, 1=partial failure, 2=critical failure
```

---

## Design Principles

### 1. Leverage Existing Services

**DO NOT** reimplement backup logic. The orchestrator is a **thin coordination layer** that:
- Discovers services via `systemctl list-units`
- Triggers them via `systemctl start`
- Monitors completion via `systemctl is-active`
- Verifies success via `systemctl show --property=Result`

### 2. Stage Dependencies

- **Stage 1 must complete** before Stage 2 (Sanoid creates snapshots that Syncoid replicates)
- **Stage 2 must complete** before Stage 3 (replication before offsite backups)
- **Parallel execution within stages** for performance (Stage 2 and 3)

### 3. Timeout Strategy

Different backup types have different performance characteristics:

| Stage | Operation | Timeout | Rationale |
|-------|-----------|---------|-----------|
| 1 | ZFS Snapshots | 5 minutes | Fast, just creates snapshots |
| 2 | ZFS Replication | 30 minutes | Network transfer dependent |
| 3 | Application Backups | 1 hour | Large data transfers to offsite |

### 4. Failure Handling

- **Stage 1 failure**: Exit immediately (critical prerequisite)
- **Stage 2/3 failures**: Continue with other jobs, aggregate failures, report at end
- **Timeouts**: Kill hung service, mark as failed, continue with others
- **Exit codes**: 0=all success, 1=partial failure, 2=critical failure

### 5. Service Discovery

Use dynamic discovery instead of hardcoding service names:

```bash
# Discover Restic jobs
restic_services=($(systemctl list-units --all --plain --no-legend 'restic-backup-*.service' | awk '{print $1}'))

# Discover pgBackRest jobs
pgbackrest_services=($(systemctl list-units --all --plain --no-legend 'pgbackrest-*.service' | awk '{print $1}'))

# Discover Syncoid jobs
syncoid_services=($(systemctl list-units --all --plain --no-legend 'syncoid-*.service' | awk '{print $1}'))
```

**Benefit:** Resilient to service additions/removals, no maintenance required.

---

## Implementation

### Package Definition

**File:** `/pkgs/backup-orchestrator.nix`

```nix
{ pkgs, lib }:

pkgs.writeShellApplication {
  name = "backup-orchestrator";
  runtimeInputs = with pkgs; [ systemd coreutils gnugrep gawk util-linux ];

  text = ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Configuration
    readonly SANOID_TIMEOUT="5m"
    readonly SYNCOID_TIMEOUT="30m"
    readonly APP_BACKUP_TIMEOUT="1h"

    # Color output
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly NC='\033[0m'

    # Failure tracking
    declare -a FAILURES=()
    FINAL_EXIT_CODE=0

    # Logging functions
    log() {
      echo -e "''${GREEN}[$(date +'%H:%M:%S')]''${NC} $*"
    }

    log_warn() {
      echo -e "''${YELLOW}[$(date +'%H:%M:%S')] WARNING:''${NC} $*" >&2
    }

    log_error() {
      echo -e "''${RED}[$(date +'%H:%M:%S')] ERROR:''${NC} $*" >&2
    }

    # Start a service
    start_service() {
      local service="$1"
      log "Starting $service..."
      if ! systemctl start "$service"; then
        log_error "Failed to start $service"
        return 1
      fi
      return 0
    }

    # Wait for a service to complete with timeout
    wait_for_service() {
      local service="$1"
      local timeout_duration="$2"
      log "Waiting for $service to complete (timeout: $timeout_duration)..."

      # Use timeout command to prevent indefinite hangs
      local wait_command="while systemctl is-active --quiet '$service'; do sleep 5; done"

      if timeout "$timeout_duration" bash -c "$wait_command"; then
        log "Service $service completed."
        return 0
      else
        log_error "Service $service timed out after $timeout_duration!"
        # Attempt clean stop
        systemctl stop "$service" 2>/dev/null || true
        return 1
      fi
    }

    # Check service result
    check_service_result() {
      local service="$1"
      local result
      result=$(systemctl show --property=Result "$service" | cut -d= -f2)

      if [ "$result" = "success" ]; then
        log "✓ $service succeeded"
        return 0
      else
        log_error "✗ $service failed (result: $result)"
        FAILURES+=("$service ($result)")
        FINAL_EXIT_CODE=1
        return 1
      fi
    }

    # Stage 1: ZFS Snapshots
    stage1_zfs_snapshots() {
      log "--- Stage 1: ZFS Snapshots ---"

      if ! start_service "sanoid.service"; then
        log_error "CRITICAL: Sanoid failed to start"
        exit 2
      fi

      if ! wait_for_service "sanoid.service" "$SANOID_TIMEOUT"; then
        log_error "CRITICAL: Sanoid timed out"
        FAILURES+=("sanoid.service (timeout)")
        exit 2
      fi

      if ! check_service_result "sanoid.service"; then
        log_error "CRITICAL: Sanoid failed"
        exit 2
      fi
    }

    # Stage 2: ZFS Replication (parallel)
    stage2_zfs_replication() {
      log "--- Stage 2: ZFS Replication (Syncoid) ---"

      local syncoid_services
      # Filter out utility services (info/metrics and reachability checks)
      mapfile -t syncoid_services < <(systemctl list-units --all --plain --no-legend 'syncoid-*.service' | \
        awk '{print $1}' | \
        grep -v 'replication-info\|target-reachability')

      if [ ''${#syncoid_services[@]} -eq 0 ]; then
        log_warn "No Syncoid services found, skipping."
        return 0
      fi

      log "Found ''${#syncoid_services[@]} Syncoid replication jobs"

      # Start all services
      for service in "''${syncoid_services[@]}"; do
        start_service "$service"
      done

      # Wait for all in parallel using background jobs
      local pids=()
      for service in "''${syncoid_services[@]}"; do
        (
          if wait_for_service "$service" "$SYNCOID_TIMEOUT"; then
            check_service_result "$service"
          else
            FAILURES+=("$service (timeout)")
            FINAL_EXIT_CODE=1
          fi
        ) &
        pids+=($!)
      done

      # Wait for all background wait processes
      for pid in "''${pids[@]}"; do
        wait "$pid" || true
      done
    }

    # Stage 3: Application Backups (parallel)
    stage3_application_backups() {
      log "--- Stage 3: Application Backups (Restic + pgBackRest) ---"

      local restic_services pgbackrest_services all_services
      # Restic services - all are backup jobs
      mapfile -t restic_services < <(systemctl list-units --all --plain --no-legend 'restic-backup-*.service' | awk '{print $1}')

      # pgBackRest - filter to only backup jobs (exclude metrics, stanza-create)
      mapfile -t pgbackrest_services < <(systemctl list-units --all --plain --no-legend 'pgbackrest-*.service' | \
        awk '{print $1}' | \
        grep -E '(full|incr|diff)-backup')

      all_services=("''${restic_services[@]}" "''${pgbackrest_services[@]}")

      if [ ''${#all_services[@]} -eq 0 ]; then
        log_warn "No application backup services found!"
        return 0
      fi

      log "Found ''${#restic_services[@]} Restic jobs and ''${#pgbackrest_services[@]} pgBackRest backup jobs"

      # Start all services
      for service in "''${all_services[@]}"; do
        start_service "$service"
      done

      # Wait for all in parallel
      local pids=()
      for service in "''${all_services[@]}"; do
        (
          if wait_for_service "$service" "$APP_BACKUP_TIMEOUT"; then
            check_service_result "$service"
          else
            FAILURES+=("$service (timeout)")
            FINAL_EXIT_CODE=1
          fi
        ) &
        pids+=($!)
      done

      # Wait for all background processes
      for pid in "''${pids[@]}"; do
        wait "$pid" || true
      done
    }

    # Stage 4: Verification
    stage4_verification() {
      log "--- Stage 4: Verification ---"

      if [ ''${#FAILURES[@]} -eq 0 ]; then
        log "✅ All backup services completed successfully!"
        return 0
      else
        log_error "❌ Backup orchestration completed with ''${#FAILURES[@]} failure(s):"
        for failure in "''${FAILURES[@]}"; do
          log_error "  - $failure"
        done
        return 1
      fi
    }

    # Main execution
    main() {
      log "Starting Pre-Deployment Backup Orchestration"
      log "============================================="

      stage1_zfs_snapshots
      stage2_zfs_replication
      stage3_application_backups
      stage4_verification

      log "============================================="
      if [ $FINAL_EXIT_CODE -eq 0 ]; then
        log "Backup orchestration completed successfully"
      else
        log_error "Backup orchestration completed with failures (exit code: $FINAL_EXIT_CODE)"
      fi

      exit $FINAL_EXIT_CODE
    }

    main "$@"
  '';
}
```

### NixOS Integration

**Add to** `/pkgs/default.nix`:

```nix
{
  backup-orchestrator = pkgs.callPackage ./backup-orchestrator.nix { };
}
```

**Add to** `/hosts/forge/default.nix`:

```nix
{
  # Add package to environment
  environment.systemPackages = with pkgs; [
    backup-orchestrator
  ];

  # Optional: systemd service wrapper
  systemd.services.backup-orchestrator = {
    description = "Pre-deployment backup orchestrator";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.backup-orchestrator}/bin/backup-orchestrator";
    };
  };
}
```

### Taskfile Integration

**Add to** `Taskfile.yaml`:

```yaml
tasks:
  backup:orchestrate:
    desc: "Run comprehensive backup orchestration before deployment"
    cmds:
      - ssh forge.holthome.net "backup-orchestrator"
```

---

## Usage

### Before Major System Change

```bash
# Option 1: Direct command
ssh forge.holthome.net "backup-orchestrator"

# Option 2: Via systemd
ssh forge.holthome.net "systemctl start backup-orchestrator.service"

# Option 3: Via Taskfile
task backup:orchestrate
```

### Example Output

```
[12:00:00] Starting Pre-Deployment Backup Orchestration
[12:00:00] =============================================
[12:00:00] --- Stage 1: ZFS Snapshots ---
[12:00:00] Starting sanoid.service...
[12:00:00] Waiting for sanoid.service to complete (timeout: 5m)...
[12:00:12] Service sanoid.service completed.
[12:00:12] ✓ sanoid.service succeeded

[12:00:12] --- Stage 2: ZFS Replication (Syncoid) ---
[12:00:12] Found 7 Syncoid jobs
[12:00:12] Starting syncoid-rpool-safe-home.service...
[12:00:12] Starting syncoid-tank-services-plex.service...
... [7 jobs starting]
[12:00:12] Waiting for all ZFS replication jobs to complete...
[12:02:34] ✓ syncoid-rpool-safe-home.service succeeded
[12:03:15] ✓ syncoid-tank-services-plex.service succeeded
... [all complete]

[12:03:45] --- Stage 3: Application Backups (Restic + pgBackRest) ---
[12:03:45] Found 6 Restic jobs and 7 pgBackRest jobs
[12:03:45] Starting restic-backup-plex...
[12:03:45] Starting pgbackrest-dispatcharr.service...
... [13 jobs starting]
[12:15:23] ✓ restic-backup-plex succeeded
[12:18:45] ✓ pgbackrest-dispatcharr.service succeeded
... [all complete]

[12:25:00] --- Stage 4: Verification ---
[12:25:00] ✅ All backup services completed successfully!
[12:25:00] =============================================
[12:25:00] Backup orchestration completed successfully
```

---

## Expert Review Findings (Gemini Pro 2.5)

### Critical Improvements Identified

#### 1. Timeout Handling
**Issue:** Original `wait_for_service` could hang indefinitely on service failure.

**Solution:** Use `timeout` command with appropriate duration per stage:
```bash
timeout "$timeout_duration" bash -c "while systemctl is-active --quiet '$service'; do sleep 5; done"
```

#### 2. True Parallel Execution
**Issue:** Sequential waiting negates parallel startup benefits.

**Solution:** Background each wait operation, collect PIDs, wait for all:
```bash
for service in "${services[@]}"; do
  (
    wait_for_service "$service" "$timeout"
    check_service_result "$service"
  ) &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid"
done
```

### Validation

✅ **Robustness**: Script will not hang indefinitely - failing jobs timeout and report
✅ **Performance**: True parallel execution reduces total runtime to longest job
✅ **Clarity**: Explicit parallel logic and timeout handling improves maintainability
✅ **Simplicity**: Leverages existing systemd services, no duplicate backup logic
✅ **Homelab-appropriate**: Bash + systemd, no external dependencies

---

## Testing Plan

### 1. Dry Run Test
```bash
# Verify service discovery works
systemctl list-units --all --plain --no-legend 'restic-backup-*.service'
systemctl list-units --all --plain --no-legend 'pgbackrest-*.service'
systemctl list-units --all --plain --no-legend 'syncoid-*.service'
```

### 2. Stage Isolation Test
Test each stage independently:
```bash
# Test Stage 1
systemctl start sanoid.service
systemctl status sanoid.service

# Test Stage 2 (pick one job)
systemctl start syncoid-tank-services-plex.service
systemctl status syncoid-tank-services-plex.service

# Test Stage 3 (pick one job)
systemctl start restic-backup-plex
systemctl status restic-backup-plex
```

### 3. Full Orchestration Test
```bash
# Run full orchestrator
backup-orchestrator

# Verify all services completed
journalctl -u backup-orchestrator.service --since "5 minutes ago"
```

### 4. Failure Scenario Tests
```bash
# Test timeout handling (modify timeout to 1 second temporarily)
# Test partial failure (stop one service mid-execution)
# Test critical failure (break sanoid service)
```

---

## Operational Notes

### Monitoring Integration

The orchestrator does NOT emit metrics itself - individual services already do:
- **Restic**: Exports metrics to textfile collector
- **pgBackRest**: Writes to metrics files
- **Sanoid/Syncoid**: Built-in monitoring
- **Orchestrator**: Logs to journald (`journalctl -u backup-orchestrator.service`)

### Pre-Deployment Workflow

```bash
# 1. Run orchestrator
task backup:orchestrate

# 2. Wait for completion (typically 15-30 minutes)

# 3. If successful (exit 0), proceed with deployment
task nix:apply-nixos host=forge

# 4. If failures, investigate before deploying
journalctl -u backup-orchestrator.service
```

### Troubleshooting

#### Service Not Found
```bash
# List all backup-related services
systemctl list-units --all --type=service '*backup*' '*sanoid*' '*syncoid*'
```

#### Service Timeout
```bash
# Check service status
systemctl status <service-name>

# View logs
journalctl -u <service-name> --since "1 hour ago"

# Manual restart
systemctl restart <service-name>
```

#### Partial Failure
The orchestrator continues on partial failure. Review failures in Stage 4 output:
```
❌ Backup orchestration completed with 2 failure(s):
  - restic-backup-sonarr (timeout)
  - syncoid-tank-services-plex.service (exit-code)
```

Investigate specific failures:
```bash
journalctl -u restic-backup-sonarr --since "1 hour ago"
journalctl -u syncoid-tank-services-plex.service --since "1 hour ago"
```

---

## Future Enhancements

### Phase 2 Features
- **Dry-run mode**: `backup-orchestrator --dry-run` to show what would execute
- **Verbose mode**: `backup-orchestrator --verbose` for detailed logging
- **Selective stages**: `backup-orchestrator --stage 3` to run only specific stage
- **Notification integration**: Send Discord/ntfy notifications on completion
- **Metrics export**: Write orchestrator-level metrics to textfile collector

### Phase 3 Features
- **Pre-flight checks**: Verify disk space, network connectivity before starting
- **Dependency validation**: Check that required services exist before running
- **Progress tracking**: Real-time progress bars for long-running operations
- **Rollback on failure**: Automatic rollback of partial changes on critical failure

---

## References

- [Backup System Onboarding Guide](./backup-system-onboarding.md)
- [Unified Backup Design Patterns](./unified-backup-design-patterns.md)
- [Storage Module Guide](./storage-module-guide.md)
- [systemd Service Management](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
