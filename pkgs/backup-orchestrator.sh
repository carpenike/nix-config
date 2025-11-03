#!/usr/bin/env bash
set -euo pipefail

# Pre-Deployment Backup Orchestrator
# Triggers all backup systems (Sanoid, Syncoid, Restic, pgBackRest) before major deployments
# Version: 2.0 (incorporating Gemini Pro critical feedback)

# shellcheck disable=SC2034  # Variables accessed via eval in array_size() function appear unused

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Pre-flight checks
check_disk_space() {
    local path=$1
    local required=$2
    # BUG FIX #3: Use --output=avail to avoid issues with spaces in mount point names
    local available
    available=$(df -BG --output=avail "$path" | tail -1 | sed 's/G//' | tr -d ' ')

    if [ "$available" -lt "$required" ]; then
        return 1
    fi
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

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        log_error "Please run: sudo backup-orchestrator"
        exit 1
    fi
}

# Track results
declare -A failed_services
declare -A success_services
declare -A timeout_services
declare -A skipped_services

# Service discovery arrays (will be populated during execution)
declare -a syncoid_services
declare -a restic_services

# Helper function to safely get associative array size (works with empty arrays under set -u)
# Returns 0 for empty/unset arrays, actual count otherwise
array_size() {
    local array_name=$1
    # Temporarily disable 'unbound variable' check for empty array access
    set +u
    eval "local size=\${#${array_name}[@]}"
    set -u
    echo "${size:-0}"
}

# Helper function to check if key exists in associative array (works with set -u)
# Returns 0 (true) if key exists, 1 (false) otherwise
array_has_key() {
    local array_name=$1
    local key=$2
    set +u
    eval "local value=\${${array_name}[$key]}"
    set -u
    [ -n "$value" ]
}

# Cleanup trap for interrupt handling (defined early, before main execution)
# shellcheck disable=SC2317  # Function invoked via trap, not directly
cleanup() {
    log_warn "Interrupted! Attempting to stop running backup services..."

    # Stop sanoid if running
    if systemctl is-active --quiet "sanoid.service" 2>/dev/null; then
        log_info "Stopping sanoid.service..."
        systemctl stop "sanoid.service" 2>/dev/null || true
    fi

    # Stop syncoid services if array is populated
    if [ ${#syncoid_services[@]} -gt 0 ]; then
        for service in "${syncoid_services[@]}"; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                log_info "Stopping $service..."
                systemctl stop "$service" 2>/dev/null || true
            fi
        done
    fi

    # Stop pgbackrest if running
    if systemctl is-active --quiet "pgbackrest-full-backup.service" 2>/dev/null; then
        log_info "Stopping pgbackrest-full-backup.service..."
        systemctl stop "pgbackrest-full-backup.service" 2>/dev/null || true
    fi

    # Stop restic services if array is populated
    if [ ${#restic_services[@]} -gt 0 ]; then
        for service in "${restic_services[@]}"; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                log_info "Stopping $service..."
                systemctl stop "$service" 2>/dev/null || true
            fi
        done
    fi

    log_error "Backup orchestration interrupted by user"
    exit 130  # Standard exit code for SIGINT
}

trap cleanup INT TERM

# Parse command line arguments
DRY_RUN=false
VERBOSE=false
NO_CONFIRM=false
JSON_OUTPUT=false
QUIET=false

show_usage() {
    cat << EOF
Usage: backup-orchestrator [OPTIONS]

Orchestrates all backup systems (Sanoid, Syncoid, Restic, pgBackRest) for
pre-deployment safety. Runs in 4 stages with progress tracking and failure aggregation.

OPTIONS:
    --dry-run           Show what would be executed without running anything
    --verbose, -v       Show detailed progress and debug information
    --yes, --no-confirm Skip all confirmation prompts (for automation)
    --json              Output results in JSON format (for monitoring)
    --quiet, -q         Minimal output (exit code only)
    --help, -h          Show this help message

STAGES:
    0. Pre-flight checks (disk space validation)
    1. ZFS snapshots (Sanoid)
    2. ZFS replication (Syncoid - parallel)
    3a. PostgreSQL backup (pgBackRest - sequential)
    3b. Application backups (Restic - limited parallel, max 3 concurrent)
    4. Verification and reporting

EXIT CODES:
    0  All backups completed successfully
    1  Partial failure (<50% failure rate) - acceptable for deployment
    2  Critical failure (>50% failure rate or pre-flight checks failed)

EXAMPLES:
    # Interactive run with confirmation
    sudo backup-orchestrator

    # Automated run (no prompts)
    sudo backup-orchestrator --yes

    # Preview what would run
    sudo backup-orchestrator --dry-run

    # Verbose output for debugging
    sudo backup-orchestrator --verbose

    # For monitoring/automation
    sudo backup-orchestrator --yes --json --quiet

EOF
}

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
        --yes|--no-confirm)
            NO_CONFIRM=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Quiet mode overrides some output
if [ "$QUIET" = true ]; then
    log_info() { :; }
    log_warn() { :; }
    # Keep log_error for critical issues
fi

# Check root privileges (unless dry-run)
if [ "$DRY_RUN" = false ]; then
    check_root
fi

# Stage 0: Pre-flight checks
if [ "$QUIET" = false ]; then
    log_info "========================================="
    log_info "Stage 0: Pre-Flight Checks"
    log_info "========================================="
fi

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

# Interactive confirmation (unless --yes or --dry-run)
if [ "$NO_CONFIRM" = false ] && [ "$DRY_RUN" = false ]; then
    echo ""
    echo "This will trigger all backup systems:"
    echo "  - 1 Sanoid snapshot job"
    echo "  - ~7 Syncoid replication jobs"
    echo "  - 1 pgBackRest full backup"
    echo "  - ~6 Restic application backups"
    echo ""
    echo "Expected duration: 30-90 minutes depending on data size and network speed"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi
fi

# Stage 1: Force Sanoid snapshots (WARNING only - not critical)
if [ "$QUIET" = false ]; then
    log_info "========================================="
    log_info "Stage 1: Creating ZFS snapshots (Sanoid)"
    log_info "========================================="
fi

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

        # BUG FIX #5: Check result only if not timed out (already present, but adding comment)
        if ! array_has_key timeout_services "sanoid.service"; then
            result=$(systemctl show -p Result --value sanoid.service)
            if [ "$result" != "success" ]; then
                log_warn "sanoid.service failed with result: $result (continuing with existing snapshots)"
                # shellcheck disable=SC2034  # Used via eval in array_size()
                failed_services["sanoid.service"]="$result"
            else
                # shellcheck disable=SC2034  # Used via eval in array_size()
                success_services["sanoid.service"]=1
                log_info "Stage 1 complete: Sanoid snapshots created successfully"
            fi
        fi
    fi
fi

# Stage 2: ZFS Replication (Syncoid) - PARALLEL within stage
if [ "$QUIET" = false ]; then
    log_info "========================================="
    log_info "Stage 2: ZFS Replication (Syncoid)"
    log_info "========================================="
fi

# Discover syncoid services, excluding utility services
mapfile -t syncoid_services < <(systemctl list-units --all --type=service 'syncoid-*.service' --no-pager --plain | awk '{print $1}' | grep -E '^syncoid-.*\.service$' | grep -v 'replication-info\|target-reachability')

# BUG FIX #13: Validate service discovery
if [ ${#syncoid_services[@]} -eq 0 ]; then
    log_error "No Syncoid services found! Check systemd configuration."
    exit 2
fi

log_info "Found ${#syncoid_services[@]} Syncoid replication jobs"

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

        log_debug "Starting $service..."
        # FIX: Keep & for parallelism, just don't capture PID (systemctl returns immediately)
        systemctl start "$service" &
    done

    # Wait for all to complete with timeout
    timeout=1800  # 30 minutes per service
    for service in "${syncoid_services[@]}"; do
        # Skip if already marked as skipped
        if array_has_key skipped_services "$service"; then
            continue
        fi
        # Skip if it was skipped earlier
        if array_has_key skipped_services "$service"; then
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
        if ! array_has_key timeout_services "$service"; then
            result=$(systemctl show -p Result --value "$service")
            if [ "$result" != "success" ]; then
                log_warn "$service failed with result: $result"
                failed_services["$service"]="$result"
            else
                success_services["$service"]=1
                log_debug "$service completed successfully"
            fi
        fi
    done

    log_info "Stage 2 complete"
fi

# Stage 3a: PostgreSQL backup (pgBackRest) - SEQUENTIAL
if [ "$QUIET" = false ]; then
    log_info "================================================"
    log_info "Stage 3a: PostgreSQL backup (pgBackRest)"
    log_info "================================================"
fi

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

            # Progress indicator every minute
            if [ $((elapsed % 60)) -eq 0 ] && [ "$VERBOSE" = true ]; then
                log_debug "pgBackRest backup in progress... (${elapsed}s elapsed)"
            fi
        done

        # Check result
        if ! array_has_key timeout_services "$pgbackrest_service"; then
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
fi

# Stage 3b: Application backups (Restic) - LIMITED PARALLEL
if [ "$QUIET" = false ]; then
    log_info "================================================"
    log_info "Stage 3b: Application backups (Restic)"
    log_info "================================================"
fi

# Discover Restic backup services
mapfile -t restic_services < <(systemctl list-units --all --type=service 'restic-backup-*.service' --no-pager --plain | awk '{print $1}' | grep -E '^restic-backup-.*\.service$')

# BUG FIX #13: Validate service discovery
if [ ${#restic_services[@]} -eq 0 ]; then
    log_error "No Restic services found! Check systemd configuration."
    exit 2
fi

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
            # BUG FIX #10: More robust array reindexing
            temp=()
            for svc in "${active_services[@]}"; do
                if systemctl is-active --quiet "$svc"; then
                    temp+=("$svc")
                fi
            done
            active_services=("${temp[@]}")

            if [ ${#active_services[@]} -ge $concurrent_limit ]; then
                sleep 5
            fi
        done

        log_debug "Starting $service (${#active_services[@]}/$concurrent_limit active)..."
        systemctl start "$service"
        active_services+=("$service")
    done

    # Wait for all remaining services with timeout
    timeout=2700  # 45 minutes per service
    for service in "${restic_services[@]}"; do
        # Skip if it was skipped earlier
        if array_has_key skipped_services "$service"; then
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
        if ! array_has_key timeout_services "$service"; then
            result=$(systemctl show -p Result --value "$service")
            if [ "$result" != "success" ]; then
                log_warn "$service failed with result: $result"
                failed_services["$service"]="$result"
            else
                success_services["$service"]=1
                log_debug "$service completed successfully"
            fi
        fi
    done

    log_info "Stage 3 complete"
fi

# Stage 4: Verification and reporting
if [ "$QUIET" = false ]; then
    log_info "========================================"
    log_info "Stage 4: Verification and Final Report"
    log_info "========================================"
fi

# Handle empty arrays in dry-run mode (set -u compatible)
total_attempted=$(( $(array_size success_services) + $(array_size failed_services) + $(array_size timeout_services) + $(array_size skipped_services) ))
total_executed=$(( $(array_size success_services) + $(array_size failed_services) + $(array_size timeout_services) ))
total_failures=$(( $(array_size failed_services) + $(array_size timeout_services) ))

# BUG FIX #9: Check if any services actually ran (prevent false success)
# Skip this check in dry-run mode where zero executions are expected
if [ $total_executed -eq 0 ] && [ "$DRY_RUN" = false ]; then
    if [ "$QUIET" = false ]; then
        log_error "No backups were executed (all $(array_size skipped_services) services already running)"
        log_error "This could indicate timer conflicts - check systemd timers"
    fi
    exit 2  # Critical failure
fi

failure_rate=0
if [ $total_executed -gt 0 ]; then
    failure_rate=$((total_failures * 100 / total_executed))
fi

# BUG FIX #11: Calculate exit code cleanly before using it
exit_code=1  # Default: partial failure
if [ "$(array_size failed_services)" -eq 0 ] && [ "$(array_size timeout_services)" -eq 0 ]; then
    exit_code=0  # All successful
elif [ $failure_rate -gt 50 ]; then
    exit_code=2  # Critical failure (>50%)
fi

# JSON output for monitoring
if [ "$JSON_OUTPUT" = true ]; then
    # BUG FIX #7: Use pre-calculated exit_code (already safely calculated)
    cat << EOF
{
  "total_services": $total_attempted,
  "successful": $(array_size success_services),
  "failed": $(array_size failed_services),
  "timed_out": $(array_size timeout_services),
  "skipped": $(array_size skipped_services),
  "failure_rate_percent": $failure_rate,
  "exit_code": $exit_code
}
EOF
    exit $exit_code
fi

# Human-readable output
if [ "$QUIET" = false ]; then
    log_info "Total services: $total_attempted"
    log_info "Successful: $(array_size success_services)"
    log_info "Failed: $(array_size failed_services)"
    log_info "Timed out: $(array_size timeout_services)"
    log_info "Skipped (already running): $(array_size skipped_services)"

    if [ "$(array_size skipped_services)" -gt 0 ]; then
        echo ""
        log_warn "Skipped services (already running from timers):"
        for service in "${!skipped_services[@]}"; do
            log_warn "  - $service"
        done
    fi

    if [ "$(array_size failed_services)" -gt 0 ]; then
        echo ""
        log_error "Failed services:"
        for service in "${!failed_services[@]}"; do
            log_error "  - $service: ${failed_services[$service]}"
        done
    fi

    if [ "$(array_size timeout_services)" -gt 0 ]; then
        echo ""
        log_error "Timed out services:"
        for service in "${!timeout_services[@]}"; do
            log_error "  - $service"
        done
    fi

    echo ""
fi

# Exit with appropriate code (using pre-calculated exit_code from BUG FIX #11)
if [ $exit_code -eq 0 ]; then
    if [ "$QUIET" = false ]; then
        log_info "✅ All backups completed successfully!"
    fi
    exit 0
elif [ $exit_code -eq 2 ]; then
    if [ "$QUIET" = false ]; then
        log_error "❌ CRITICAL: More than 50% of backups failed (${failure_rate}%)"
        log_error "DO NOT proceed with deployment until backup issues are resolved"
    fi
    exit 2
else
    if [ "$QUIET" = false ]; then
        log_warn "⚠️  Partial failure: ${failure_rate}% of backups did not complete successfully"
        log_warn "This is within acceptable threshold for deployment"
        log_warn "Review failures above and proceed with caution"
    fi
    exit 1
fi
