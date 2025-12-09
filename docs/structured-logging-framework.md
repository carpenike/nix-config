# Structured Logging Framework

This document describes the standardized structured logging framework implemented for critical infrastructure services in the nix-config repository. The framework provides enterprise-grade observability with JSON-formatted logs, Prometheus metrics integration, and comprehensive error handling.

## Overview

The structured logging framework addresses common operational challenges:
- **Limited visibility** into long-running operations (backups, restores)
- **Difficult log correlation** across related services
- **No performance metrics** for critical operations
- **Silent failure detection** issues
- **Inconsistent error reporting** across services

## Architecture

### Core Components

1. **Structured JSON Logging** - Consistent log format with contextual metadata
2. **Prometheus Metrics Integration** - Automatic success/failure and performance tracking
3. **Error Handling** - Trap-based error detection with automatic failure metrics
4. **Performance Monitoring** - Duration tracking for operations

### Log Format

All structured logs use consistent JSON format:

```json
{
  "timestamp": "2025-10-22T18:31:41+00:00",
  "service": "postgresql-preseed",
  "level": "INFO|ERROR|WARN",
  "event": "operation_start|operation_complete|error_occurred",
  "message": "Human-readable description",
  "details": {
    "key": "value",
    "duration_seconds": 123
  }
}
```

### Metrics Format

Prometheus metrics follow this pattern:

```prometheus
# HELP service_operation_status Indicates success (1) or failure (0) of operation
# TYPE service_operation_status gauge
service_operation_status{stanza="main",operation="restore"} 1

# HELP service_operation_duration_seconds Duration of operation in seconds
# TYPE service_operation_duration_seconds gauge
service_operation_duration_seconds{stanza="main",operation="restore"} 45

# HELP service_operation_completion_timestamp_seconds Unix timestamp of completion
# TYPE service_operation_completion_timestamp_seconds gauge
service_operation_completion_timestamp_seconds{stanza="main",operation="restore"} 1729622501
```

## Implementation Guide

### Step 1: Shell Script Integration

Add these helper functions to any bash script requiring structured logging:

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Structured Logging & Error Handling ---
LOG_SERVICE_NAME="your-service-name"
METRICS_FILE="/var/lib/node_exporter/textfile_collector/your_service.prom"

# Logs a structured JSON message to stdout
# Usage: log_json <LEVEL> <EVENT_NAME> <MESSAGE> [JSON_DETAILS]
log_json() {
  local level="$1"
  local event="$2"
  local message="$3"
  local details_json="${4:-{}}"

  printf '{"timestamp":"%s","service":"%s","level":"%s","event":"%s","message":"%s","details":%s}\n' \
    "$(date -u --iso-8601=seconds)" \
    "${LOG_SERVICE_NAME}" \
    "$level" \
    "$event" \
    "$message" \
    "$details_json"
}

# Atomically writes metrics for Prometheus
# Usage: write_metrics <status: "success"|"failure"> <duration_seconds> [additional_labels]
write_metrics() {
  local status="$1"
  local duration="$2"
  local additional_labels="${3:-}"
  local status_code=$([ "$status" = "success" ] && echo 1 || echo 0)

  cat > "${METRICS_FILE}.tmp" <<EOF
# HELP ${LOG_SERVICE_NAME}_status Indicates the status of the last operation (1 for success, 0 for failure).
# TYPE ${LOG_SERVICE_NAME}_status gauge
${LOG_SERVICE_NAME}_status${additional_labels} ${status_code}
# HELP ${LOG_SERVICE_NAME}_last_duration_seconds Duration of the last operation in seconds.
# TYPE ${LOG_SERVICE_NAME}_last_duration_seconds gauge
${LOG_SERVICE_NAME}_last_duration_seconds${additional_labels} ${duration}
# HELP ${LOG_SERVICE_NAME}_last_completion_timestamp_seconds Timestamp of the last operation completion.
# TYPE ${LOG_SERVICE_NAME}_last_completion_timestamp_seconds gauge
${LOG_SERVICE_NAME}_last_completion_timestamp_seconds${additional_labels} $(date +%s)
EOF
  mv "${METRICS_FILE}.tmp" "$METRICS_FILE"
}

# Trap for logging errors before exiting
trap_error() {
  local exit_code=$?
  local line_no=$1
  local command="$2"
  log_json "ERROR" "script_error" "Script failed with exit code $exit_code at line $line_no: $command" \
    "{\"exit_code\": ${exit_code}, \"line_number\": ${line_no}, \"command\": \"$command\"}"
  # Write failure metrics before exiting
  write_metrics "failure" 0
  exit $exit_code
}
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR
# --- End Helpers ---
```

### Step 2: Service Implementation Pattern

```bash
log_json "INFO" "operation_start" "Starting critical operation..." \
  "{\"parameter1\": \"value1\", \"parameter2\": \"value2\"}"

start_time=$(date +%s)

# ... perform operation ...

end_time=$(date +%s)
duration=$((end_time - start_time))

log_json "INFO" "operation_complete" "Operation completed successfully." \
  "{\"duration_seconds\": ${duration}, \"records_processed\": 1234}"

# Write success metrics
write_metrics "success" "${duration}" "{stanza=\"main\"}"

log_json "INFO" "service_complete" "Service finished successfully."
```

### Step 3: NixOS Integration

#### Metrics File Management

Add to `systemd.tmpfiles.rules`:

```nix
systemd.tmpfiles.rules = [
  "f /var/lib/node_exporter/textfile_collector/your_service.prom 0644 service-user node-exporter - -"
];
```

#### User Groups

Ensure service user can write metrics:

```nix
users.users.service-user.extraGroups = [ "node-exporter" ];
```

#### Service Configuration

```nix
systemd.services.your-service = {
  # ... other config ...

  serviceConfig = {
    User = "service-user";
    Group = "service-user";
    # Security settings...
  };

  script = ''
    # Include the structured logging framework
    ${structuredLoggingScript}
  '';
};
```

## Current Implementations

### PostgreSQL Pre-Seed Service

**File**: `modules/nixos/postgresql-preseed.nix`
**Metrics**: `/var/lib/node_exporter/textfile_collector/postgresql_preseed.prom`

Provides structured logging for disaster recovery database restoration:
- Restore operation progress and timing
- Safety checks and decision logic
- Performance metrics for large database restores

### PostgreSQL Post-Preseed Service

**File**: `hosts/forge/default.nix` (pgbackrest-post-preseed service)
**Metrics**: `/var/lib/node_exporter/textfile_collector/postgresql_postpreseed.prom`

Provides structured logging for post-restoration backup creation:
- Backup necessity detection
- PostgreSQL readiness checks
- Fresh backup creation timing

## Log Analysis Examples

### Filtering Structured Logs

```bash
# View all structured logs for a service
journalctl -u postgresql-preseed.service | jq 'select(.service == "postgresql-preseed")'

# View only errors
journalctl -u postgresql-preseed.service | jq 'select(.level == "ERROR")'

# View operation timings
journalctl -u postgresql-preseed.service | jq 'select(.details.duration_seconds != null) | {event, duration: .details.duration_seconds}'

# Monitor real-time events
journalctl -u postgresql-preseed.service -f | jq 'select(.event == "restore_start" or .event == "restore_complete")'
```

### Prometheus Queries

```promql
# Success rate over time
rate(postgresql_preseed_status[1h])

# Average operation duration
avg_over_time(postgresql_preseed_last_duration_seconds[24h])

# Alert on failures
postgresql_preseed_status == 0
```

## Best Practices

### Event Naming Conventions

- **start/complete**: `operation_start`, `operation_complete`
- **status checks**: `condition_check`, `validation_complete`
- **errors**: `script_error`, `operation_failed`
- **skipped operations**: `operation_skipped`

### Log Levels

- **INFO**: Normal operations, status updates, completions
- **WARN**: Non-fatal issues, degraded conditions
- **ERROR**: Failures, exceptions, critical issues

### Details Object Guidelines

```json
{
  "duration_seconds": 123,        // Always include timing
  "records_processed": 1000,      // Quantify work done
  "target_path": "/var/lib/data", // Include relevant paths
  "exit_code": 1,                 // Include exit codes for errors
  "reason": "no_work_needed"      // Explain skipped operations
}
```

### Performance Considerations

- Use atomic writes for metrics files (`.tmp` then `mv`)
- Avoid excessive logging in tight loops
- Include timing for operations > 1 second
- Buffer logs for high-frequency operations

## Future Enhancement Targets

### High-Priority Services

1. **pgbackrest-full-backup** / **pgbackrest-incr-backup**
   - Multi-repository backup tracking
   - Granular failure detection (NFS vs R2)
   - Backup size and performance metrics

2. **ZFS replication services** (syncoid)
   - Snapshot transfer timing
   - Replication lag metrics
   - Error correlation across datasets

3. **Restic backup services**
   - Backup completion verification
   - Repository health checks
   - Retention policy execution

### Medium-Priority Services

1. **Container orchestration** (Podman services)
   - Service startup/shutdown timing
   - Health check failures
   - Resource usage tracking

2. **Network monitoring** (UPS, network controllers)
   - Status change events
   - Performance degradation detection
   - Alert correlation

## Migration Checklist

When adding structured logging to existing services:

- [ ] Identify critical operations requiring visibility
- [ ] Define service-specific events and metrics
- [ ] Add metrics file to tmpfiles configuration
- [ ] Ensure service user has node-exporter group access
- [ ] Implement structured logging helpers
- [ ] Add timing measurements for long operations
- [ ] Test error handling and failure metrics
- [ ] Update monitoring/alerting rules
- [ ] Document service-specific log events

## Troubleshooting

### Common Issues

**Empty metrics files**: Service hasn't run or conditions weren't met
```bash
# Check service status and conditions
systemctl status your-service.service
```

**Permission denied on metrics**: User not in node-exporter group
```bash
# Verify group membership
id service-user
```

**Malformed JSON logs**: Incorrect string escaping
```bash
# Test JSON parsing
journalctl -u your-service.service | tail -1 | jq .
```

**Missing metrics in Prometheus**: File ownership or format issues
```bash
# Check file ownership and format
ls -la /var/lib/node_exporter/textfile_collector/
cat /var/lib/node_exporter/textfile_collector/your_service.prom
```

This framework provides the foundation for enterprise-grade observability across all critical infrastructure services. Consistent implementation ensures operational teams have the visibility needed for effective monitoring, debugging, and performance analysis.
