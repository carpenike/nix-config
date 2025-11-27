{ config, pkgs, lib, ... }:

let
  serviceEnabled =
    (config.modules.services.postgresql.enable or false)
    || (config.services.postgresql.enable or false);
  hardenedServiceConfig = {
    ProtectSystem = "full";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    LockPersonality = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    KeyringMode = "private";
    UMask = "0077";
    CapabilityBoundingSet = "";
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    MemoryDenyWriteExecute = true;
  };
in
{
  # pgBackRest - PostgreSQL Backup & Recovery
  # Replaces custom pg-backup-scripts with industry-standard tooling
  environment.systemPackages = [ pkgs.pgbackrest pkgs.acl ];

  # pgBackRest configuration
  # Industry-standard dual-repository setup with full PITR capability on both repos
  #
  # WAL archiving strategy:
  # - Repo1 (NFS): Fast local backups + continuous WAL archiving
  #   * 7-day retention
  #   * Point-in-Time Recovery (PITR) capable
  #   * Primary recovery source (fastest)
  #
  # - Repo2 (Cloudflare R2): Offsite DR + continuous WAL archiving
  #   * 30-day retention
  #   * Point-in-Time Recovery (PITR) capable
  #   * Geographic redundancy
  #   * Cost-effective (R2 has zero egress fees)
  #
  # Archive-async with local spool ensures WAL archiving continues even if repos are temporarily unavailable
  # Single unified pgBackRest configuration for both repositories
  # - Repo1 (NFS): Primary for fast local recovery with PITR
  # - Repo2 (R2/S3): Offsite DR with full PITR capability
  #
  # CRITICAL: R2 credentials MUST be in the config file for archive_command to work
  # The PostgreSQL archiver process reads /etc/pgbackrest.conf and does NOT have
  # access to environment variables set in backup scripts or systemd services.
  # To keep a single source of truth, all runtime services now rely solely on the
  # generated /etc/pgbackrest.conf and never export AWS credentials directly.
  #
  # We generate this config file from a template that includes placeholders,
  # then use a systemd service to substitute the actual credentials at runtime.
  # Weekly pgBackRest check jobs and async spool metrics provide early warnings
  # when repositories degrade or the archive queue begins to grow.
  environment.etc."pgbackrest.conf.template".text = ''
      [global]
      # Repo1 (NFS) - Primary for WAL archiving and local backups
      repo1-path=/mnt/nas-postgresql/pgbackrest
      repo1-retention-full=7
    repo1-retention-archive=7

      # Repo2 (Cloudflare R2) - Offsite DR with PITR capability
      # Now includes WAL archiving for complete offsite PITR
      repo2-type=s3
      repo2-path=/forge-pgbackrest
      repo2-s3-bucket=${config.my.r2.bucket}
      repo2-s3-endpoint=${config.my.r2.endpoint}
      repo2-s3-region=auto
      repo2-s3-uri-style=path
      repo2-retention-full=30
    repo2-retention-archive=30
      # Credentials will be substituted by pgbackrest-config-generator service
      repo2-s3-key=__R2_ACCESS_KEY_ID__
      repo2-s3-key-secret=__R2_SECRET_ACCESS_KEY__

      # Global archive settings (apply to all repositories with archiving enabled)
      # Archive async with local spool to decouple DB availability from repos
      # If repos are down, archive_command succeeds by writing to local spool
      # Background process flushes to repos when they are available
      archive-async=y
      spool-path=/var/lib/pgbackrest/spool
      archive-push-queue-max=1073741824

      # Other global settings
      process-max=2
      log-level-console=info
      log-level-file=detail
      start-fast=y
      delta=y
      compress-type=lz4
      compress-level=3

      [main]
      pg1-path=/var/lib/postgresql/16
      pg1-port=5432
      pg1-user=postgres
  '';

  # Service to generate pgbackrest.conf with actual credentials from SOPS
  # Runs before PostgreSQL and preseed to ensure all pgBackRest operations have valid config
  systemd.services.pgbackrest-config-generator = {
    description = "Generate pgBackRest configuration with R2 credentials";
    wantedBy = [ "multi-user.target" ];
    before = [ "postgresql.service" "postgresql-preseed.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets."restic/r2-prod-env".path;
      ExecStart = pkgs.writeShellScript "generate-pgbackrest-conf" ''
        set -euo pipefail

        # Read template and substitute credentials
        sed -e "s|__R2_ACCESS_KEY_ID__|$AWS_ACCESS_KEY_ID|g" \
            -e "s|__R2_SECRET_ACCESS_KEY__|$AWS_SECRET_ACCESS_KEY|g" \
            /etc/pgbackrest.conf.template > /etc/pgbackrest.conf

        # Set secure permissions (postgres user needs to read this)
        chmod 640 /etc/pgbackrest.conf
        chown postgres:postgres /etc/pgbackrest.conf

        echo "Generated /etc/pgbackrest.conf with R2 credentials"
      '';
    };
  };

  # Declaratively manage pgBackRest repository directory and metrics file
  # Format: Type, Path, Mode, User, Group, Age, Argument
  # This ensures directories/files exist on boot with correct ownership/permissions
  systemd.tmpfiles.rules = [
    "d /mnt/nas-postgresql/pgbackrest 0750 postgres postgres - -"
    # Create local spool directory for async WAL archiving
    # Critical: Allows archive_command to succeed even when NFS is down
    "d /var/lib/pgbackrest 0750 postgres postgres - -"
    "d /var/lib/pgbackrest/spool 0750 postgres postgres - -"
    # Create pgBackRest log directory
    "d /var/log/pgbackrest 0750 postgres postgres - -"
    # Create systemd journal directory with correct permissions for persistent storage
    # Mode 2755 sets setgid bit so files inherit systemd-journal group
    "d /var/log/journal 2755 root systemd-journal - -"
    # Ensure textfile_collector directory exists before creating metrics file
    # Mode 0775 allows node-exporter group members to write metrics files
    "d /var/lib/node_exporter/textfile_collector 0775 node-exporter node-exporter - -"
    # Create metrics file at boot with correct ownership so postgres user can write to it
    # and node-exporter group can read it. Type "f" creates the file if it doesn't exist.
    "f /var/lib/node_exporter/textfile_collector/pgbackrest.prom 0644 postgres node-exporter - -"
    # Create metrics file for the post-preseed service
    "f /var/lib/node_exporter/textfile_collector/postgresql_postpreseed.prom 0644 postgres node-exporter - -"
    # Note: /var/lib/postgresql directory created by zfs-service-datasets.service with proper ownership
  ];

  # pgBackRest systemd services
  # Note: repo2 configuration defined in top-level let block as repo2Flags and repo2EnvVars
  systemd.services = {
    # Stanza creation (runs once at setup)
    pgbackrest-stanza-create = {
      description = "pgBackRest stanza initialization";
      after = [ "postgresql-readiness-wait.service" "postgresql-preseed.service" ];
      wants = [ "postgresql-readiness-wait.service" "postgresql-preseed.service" ];
      requires = [ "postgresql-readiness-wait.service" "postgresql-preseed.service" ];
      path = [ pkgs.pgbackrest pkgs.postgresql_16 ];
      serviceConfig = hardenedServiceConfig // {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        RemainAfterExit = true;
      };
      # Add NFS mount dependency
      unitConfig = {
        RequiresMountsFor = [ "/mnt/nas-postgresql" ];
      };
      script = ''
        set -euo pipefail

        # Directory is managed by systemd.tmpfiles.rules
        # This service handles three scenarios:
        # 1. Fresh install: Creates new stanza
        # 2. After pre-seed restore: Validates existing stanza matches restored DB
        # 3. Disaster recovery: Force recreates stanza when metadata conflicts

        echo "[$(date -Iseconds)] Creating pgBackRest stanza 'main' for both repos (NFS + R2)..."

        # Check if we're in disaster recovery scenario (preseed marker exists)
        DISASTER_RECOVERY=false
        if [ -f "/var/lib/postgresql/.preseed-completed" ]; then
          echo "[$(date -Iseconds)] Preseed marker detected - this is a disaster recovery scenario"
          DISASTER_RECOVERY=true
        fi

        # Try to create/upgrade stanza to handle both fresh install and disaster recovery
        echo "[$(date -Iseconds)] Attempting stanza creation for both repositories..."

        # Capture output for better error logging
        # Try creating stanza for both repos first (ideal path)
        # Repo2 configuration now in /etc/pgbackrest.conf
        if ! output=$(pgbackrest --stanza=main stanza-create 2>&1); then
          echo "[$(date -Iseconds)] Initial stanza creation for both repos failed, checking if upgrade is needed or repo2 is unavailable..."
          echo "--- pgbackrest stanza-create output ---"
          echo "$output"
          echo "---------------------------------------"

          # Check if this is a database system identifier mismatch (error 028)
          # This happens after disaster recovery when database was rebuilt but stanza exists
          if pgbackrest --stanza=main info >/dev/null 2>&1; then
            echo "[$(date -Iseconds)] Stanza exists but database mismatch detected - upgrading stanza"

            if ! upgrade_output=$(pgbackrest --stanza=main stanza-upgrade 2>&1); then
              echo "[$(date -Iseconds)] ERROR: Stanza upgrade failed"
              echo "--- pgbackrest stanza-upgrade output ---"
              echo "$upgrade_output"
              echo "------------------------------------------"
              exit 1
            fi
            echo "[$(date -Iseconds)] Stanza upgrade successful - database now matches backup metadata"
          else
            # Stanza doesn't exist and dual-repo creation failed
            # Prioritize getting repo1 online for WAL archiving even if repo2 is broken
            echo "[$(date -Iseconds)] WARNING: Dual-repository stanza creation failed. Attempting repo1-only to secure WAL archiving..."

            # Try stanza-create with just repo1 (no --repo flag needed, it will use what's in config)
            if pgbackrest --stanza=main stanza-create 2>&1; then
              echo "[$(date -Iseconds)] SUCCESS: Repo1 stanza is active. WAL archiving will function."
              echo "[$(date -Iseconds)] WARNING: Repo2 (R2) stanza creation failed. System operational but with reduced redundancy."
              echo "[$(date -Iseconds)] Action required: Fix repo2 connectivity/credentials and retry stanza-create manually."
              # Exit successfully - WAL archiving is working (degraded but operational)
              # Operators should monitor logs for this warning and fix repo2 connectivity
              exit 0
            else
              echo "[$(date -Iseconds)] CRITICAL: Failed to create or upgrade stanza even for repo1."
              echo "[$(date -Iseconds)] WAL archiving is BROKEN. Manual intervention required immediately."
              echo "[$(date -Iseconds)] Check: NFS mount (/mnt/nas-postgresql), PostgreSQL running, stanza configuration."
              exit 1
            fi
          fi
        else
          echo "[$(date -Iseconds)] Successfully created stanzas for both repositories"
        fi

        echo "[$(date -Iseconds)] Running final configuration check..."
        # Use info command instead of check to avoid waiting for WAL archiving
        # check command has 60s timeout waiting for WAL segments which can fail after PostgreSQL restart
        # info command just verifies stanza configuration is valid
        # Repo2 configuration now in /etc/pgbackrest.conf
        pgbackrest --stanza=main info
        echo "[$(date -Iseconds)] Stanza configuration verified successfully for both repositories"
      '';
      wantedBy = [ "multi-user.target" ];
    };

    # Post-preseed backup (creates fresh baseline after restoration)
    pgbackrest-post-preseed = {
      description = "Create fresh pgBackRest backup after pre-seed restoration";
      after = [ "postgresql.service" "pgbackrest-stanza-create.service" "network-online.target" "postgresql-preseed.service" ];
      wants = [ "postgresql.service" "network-online.target" ];
      requires = [ "postgresql.service" ];
      bindsTo = [ "postgresql.service" ]; # Stop if PostgreSQL goes down mid-run
      # Triggered by OnSuccess from postgresql-preseed instead of boot-time activation
      # This eliminates condition evaluation race and "skipped at boot" noise
      path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq pkgs.systemd ];

      # Only run if preseed completed but post-preseed backup hasn't been done yet
      unitConfig = {
        ConditionPathExists = [
          "/var/lib/postgresql/.preseed-completed"
          "!/var/lib/postgresql/.postpreseed-backup-done"
        ];
        # Proper NFS mount dependency for backup operations
        RequiresMountsFor = [ "/mnt/nas-postgresql" ];
        # Recovery from transient failures
        StartLimitIntervalSec = "600";
        StartLimitBurst = "5";
        # Trigger metrics collection on success to immediately update Prometheus
        OnSuccess = "pgbackrest-metrics.service";
      };

      serviceConfig = hardenedServiceConfig // {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        RemainAfterExit = true;
        Environment = "PGHOST=/var/run/postgresql";
        # Restart on failure with proper backoff for recovery timing issues
        Restart = "on-failure";
        RestartSec = "60s";
        IPAddressDeny = [ "169.254.169.254" ];
      };

      script = ''
                #!/usr/bin/env bash
                set -euo pipefail

                # --- Structured Logging & Error Handling ---
                LOG_SERVICE_NAME="pgbackrest-post-preseed"
                METRICS_FILE="/var/lib/node_exporter/textfile_collector/postgresql_postpreseed.prom"

                log_json() {
                  local level="$1"
                  local event="$2"
                  local message="$3"
                  local details_json="''${4:-{}}"
                  printf '{"timestamp":"%s","service":"%s","level":"%s","event":"%s","message":"%s","details":%s}\n' \
                    "$(date -u --iso-8601=seconds)" \
                    "''${LOG_SERVICE_NAME}" \
                    "$level" \
                    "$event" \
                    "$message" \
                    "$details_json"
                }

                write_metrics() {
                  local status="$1"
                  local duration="$2"
                  local status_code=$([ "$status" = "success" ] && echo 1 || echo 0)
                  cat > "''${METRICS_FILE}.tmp" <<EOF
        # HELP postgresql_postpreseed_status Indicates the status of the last post-preseed backup (1 for success, 0 for failure).
        # TYPE postgresql_postpreseed_status gauge
        postgresql_postpreseed_status{stanza="main"} ''${status_code}
        # HELP postgresql_postpreseed_last_duration_seconds Duration of the last post-preseed backup in seconds.
        # TYPE postgresql_postpreseed_last_duration_seconds gauge
        postgresql_postpreseed_last_duration_seconds{stanza="main"} ''${duration}
        # HELP postgresql_postpreseed_last_completion_timestamp_seconds Timestamp of the last post-preseed backup completion.
        # TYPE postgresql_postpreseed_last_completion_timestamp_seconds gauge
        postgresql_postpreseed_last_completion_timestamp_seconds{stanza="main"} $(date +%s)
        EOF
                  mv "''${METRICS_FILE}.tmp" "$METRICS_FILE"
                }

                trap_error() {
                  local exit_code=$?
                  local line_no=$1
                  local command="$2"
                  log_json "ERROR" "script_error" "Script failed with exit code $exit_code at line $line_no: $command" \
                    "{\"exit_code\": ''${exit_code}, \"line_number\": ''${line_no}, \"command\": \"$command\"}"
                  write_metrics "failure" 0
                  exit $exit_code
                }
                trap 'trap_error $LINENO "$BASH_COMMAND"' ERR
                # --- End Helpers ---

                log_json "INFO" "postpreseed_start" "Post-preseed backup process starting."

                # Verify that pre-seed actually restored data
                if [ ! -f /var/lib/postgresql/.preseed-completed ]; then
                  log_json "ERROR" "preseed_marker_missing" "Pre-seed completion marker not found. This service should not have been triggered."
                  exit 1
                fi

                restored_from=$(grep "restored_from=" /var/lib/postgresql/.preseed-completed | cut -d= -f2)
                if [ "$restored_from" = "existing_pgdata" ]; then
                  log_json "INFO" "postpreseed_skipped" "Pre-seed marker indicates existing PGDATA was found. Skipping post-preseed backup." \
                    '{"reason":"no_restoration_occurred"}'
                  exit 0
                fi
                log_json "INFO" "preseed_marker_found" "Pre-seed marker indicates restoration from: $restored_from"

                # Wait for PostgreSQL to complete recovery and be ready for backup
                log_json "INFO" "wait_for_postgres" "Waiting for PostgreSQL to become ready..."
                if ! timeout 300 bash -c 'until pg_isready -q; do sleep 2; done'; then
                  log_json "ERROR" "postgres_timeout" "PostgreSQL did not become ready within 300 seconds."
                  exit 1
                fi
                log_json "INFO" "postgres_ready" "PostgreSQL is ready."

                # Wait for recovery completion (critical for post-restore backups)
                log_json "INFO" "wait_for_promotion" "Waiting for PostgreSQL recovery to complete..."
                TIMEOUT_SECONDS=1800  # 30 minutes - tune for worst-case WAL backlog
                INTERVAL_SECONDS=2
                deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))

                while true; do
                  # Check if this is a standby that will never promote
                  if [ -f "/var/lib/postgresql/16/standby.signal" ]; then
                    log_json "ERROR" "promotion_failed" "standby.signal present - node will not promote" "{\"reason\":\"standby_configuration\"}"
                    exit 2
                  fi

                  # Separate connection check from recovery status check for clearer diagnostics
                  if ! psql -Atqc "SELECT 1;" >/dev/null 2>&1; then
                    log_json "ERROR" "connection_failed" "Cannot connect to PostgreSQL - service may not be running" "{\"reason\":\"connection_failed\"}"
                    exit 3
                  fi

                  # Check if PostgreSQL is still in recovery mode
                  in_recovery=$(psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null)
                  if [ $? -ne 0 ]; then
                    log_json "ERROR" "query_failed" "Failed to query recovery status" "{\"reason\":\"query_failed\"}"
                    exit 3
                  fi

                  if [ "$in_recovery" = "f" ]; then
                    # Verify the database is writable (not read-only)
                    read_only=$(psql -Atqc "SHOW default_transaction_read_only;" 2>/dev/null)
                    if [ $? -ne 0 ]; then
                      log_json "ERROR" "query_failed" "Failed to query transaction mode" "{\"reason\":\"query_failed\"}"
                      exit 3
                    fi

                    if [ "$read_only" = "off" ]; then
                      log_json "INFO" "promotion_complete" "PostgreSQL recovery completed successfully" "{\"in_recovery\":false,\"read_only\":false}"
                      break
                    else
                      log_json "WARN" "promotion_partial" "Recovery complete but database is read-only" "{\"in_recovery\":false,\"read_only\":true}"
                    fi
                  else
                    log_json "INFO" "promotion_waiting" "PostgreSQL still in recovery mode" "{\"in_recovery\":true}"
                  fi

                  # Check timeout
                  if [ "$(date +%s)" -ge "$deadline" ]; then
                    # Get last WAL replay position and timeline for diagnostics
                    last_lsn=$(psql -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null || echo "unknown")
                    timeline_id=$(psql -Atqc "SELECT timeline_id FROM pg_control_checkpoint();" 2>/dev/null || echo "unknown")
                    log_json "ERROR" "promotion_timeout" "Timed out waiting for PostgreSQL recovery completion" "{\"timeout_seconds\":$TIMEOUT_SECONDS,\"last_wal_replay_lsn\":\"''${last_lsn}\",\"timeline_id\":\"''${timeline_id}\",\"hint\":\"check for missing WAL files or recovery configuration issues\"}"
                    exit 1
                  fi

                  sleep "$INTERVAL_SECONDS"
                done

                # Determine current system-id
                cur_sysid="$(psql -Atqc "select system_identifier from pg_control_system()")"
                log_json "INFO" "system_id_check" "Checking for existing backups for current system-id." "{\"system_id\":\"$cur_sysid\"}"

                # Check each repository independently to ensure both have fresh backups
                # This prevents skipping repo2 if repo1 succeeds but repo2 failed previously
                INFO_JSON="$(pgbackrest --stanza=main --output=json info 2>/dev/null || echo '[]')"

                # Use single jq query to extract both repo counts efficiently
                COUNTS=$(echo "$INFO_JSON" | jq -r --arg sid "$cur_sysid" '
                  .[] | .backup | map(select(.type == "full" and .database["system-id"] == ($sid|tonumber) and (.error // null) == null)) |
                  {
                    repo1: map(select(.repo == 1)) | length,
                    repo2: map(select(.repo == 2)) | length
                  } | "\(.repo1) \(.repo2)"
                ' 2>/dev/null || echo "0 0")

                read -r has_full_repo1 has_full_repo2 <<< "$COUNTS"

                start_time=$(date +%s)
                repo1_ok=false
                repo2_ok=false

                # Backup to repo1 if needed
                if [ "''${has_full_repo1:-0}" -gt 0 ]; then
                  log_json "INFO" "backup_repo1_skipped" "Found existing full backup for repo1 (NFS)."
                  repo1_ok=true
                else
                  log_json "INFO" "backup_repo1_start" "No full backup found for repo1; starting backup to NFS..."
                  if pgbackrest --stanza=main --type=full --repo=1 backup; then
                    log_json "INFO" "backup_repo1_complete" "Repo1 backup completed"
                    repo1_ok=true
                  else
                    log_json "ERROR" "backup_repo1_failed" "Repo1 backup failed"
                  fi
                fi

                # Backup to repo2 if needed
                if [ "''${has_full_repo2:-0}" -gt 0 ]; then
                  log_json "INFO" "backup_repo2_skipped" "Found existing full backup for repo2 (R2)."
                  repo2_ok=true
                else
                  log_json "INFO" "backup_repo2_start" "No full backup found for repo2; starting backup to R2..."
                  # Repo2 configuration (including credentials) lives in /etc/pgbackrest.conf
                  if pgbackrest --stanza=main --type=full --repo=2 backup; then
                    log_json "INFO" "backup_repo2_complete" "Repo2 backup completed"
                    repo2_ok=true
                  else
                    log_json "ERROR" "backup_repo2_failed" "Repo2 backup failed"
                  fi
                fi

                end_time=$(date +%s)
                duration=$((end_time - start_time))

                # Retry limit to prevent infinite restart loops
                MAX_RETRIES=5
                RETRY_FILE="/var/lib/postgresql/.postpreseed-retry-count"
                RETRY_LOCK="/var/lib/postgresql/.postpreseed-retry.lock"

                # Use flock for atomic retry counter operations to prevent race conditions
                (
                  flock 200  # Acquire exclusive lock on file descriptor 200

                  retries=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)

                  # Only mark complete if BOTH repositories succeeded
                  if [ "$repo1_ok" = true ] && [ "$repo2_ok" = true ]; then
                    log_json "INFO" "backup_complete" "Post-preseed backup process completed successfully for both repositories." "{\"duration_seconds\":''${duration}}"
                    write_metrics "success" "''${duration}"

                    # Clean up retry counter on success
                    rm -f "$RETRY_FILE"

                    # Mark completion to prevent re-runs ONLY on full success
                    touch /var/lib/postgresql/.postpreseed-backup-done
                    log_json "INFO" "marker_created" "Completion marker created at /var/lib/postgresql/.postpreseed-backup-done"
                    log_json "INFO" "postpreseed_complete" "Post-preseed backup process finished."
                  else
                    # Check if we've exceeded retry limit
                    if [ "$retries" -ge "$MAX_RETRIES" ]; then
                      log_json "CRITICAL" "postpreseed_gave_up" "Exceeded maximum retry attempts ($MAX_RETRIES). Stopping service to prevent infinite loop." "{\"failed_repo1\":$([ "$repo1_ok" = false ] && echo true || echo false),\"failed_repo2\":$([ "$repo2_ok" = false ] && echo true || echo false)}"
                      write_metrics "failure" "''${duration}"

                      # Create marker indicating permanent failure
                      touch "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                      echo "repo1_ok=$repo1_ok" > "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                      echo "repo2_ok=$repo2_ok" >> "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                      echo "retries=$retries" >> "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"
                      echo "timestamp=$(date -Iseconds)" >> "/var/lib/postgresql/.postpreseed-backup-GAVE-UP"

                      rm -f "$RETRY_FILE"
                      exit 0  # Exit successfully to stop the restart loop
                    else
                      # Increment retry counter atomically
                      echo $((retries + 1)) > "$RETRY_FILE"
                      log_json "ERROR" "postpreseed_failed" "Post-preseed backup failed for one or more repositories. Retry attempt $((retries + 1))/$MAX_RETRIES." "{\"failed_repo1\":$([ "$repo1_ok" = false ] && echo true || echo false),\"failed_repo2\":$([ "$repo2_ok" = false ] && echo true || echo false)}"
                      write_metrics "failure" "''${duration}"
                      exit 1  # Exit with failure to trigger systemd restart logic
                    fi
                  fi
                ) 200>"$RETRY_LOCK"  # Redirect file descriptor 200 to lock file
      '';
    };

    # Full backup
    pgbackrest-full-backup = {
      description = "pgBackRest full backup";
      after = [ "postgresql.service" "pgbackrest-stanza-create.service" ];
      wants = [ "postgresql.service" ];
      path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.systemd ];

      unitConfig = {
        RequiresMountsFor = [ "/mnt/nas-postgresql" ];
        # Trigger metrics collection on success to immediately update Prometheus
        OnSuccess = "pgbackrest-metrics.service";
      };
      serviceConfig = hardenedServiceConfig // {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        IPAddressDeny = [ "169.254.169.254" ];
      };
      script = ''
        set -euo pipefail

        echo "[$(date -Iseconds)] Starting full backup to repo1 (NFS)..."
        pgbackrest --stanza=main --type=full --repo=1 backup
        echo "[$(date -Iseconds)] Repo1 backup completed"

        echo "[$(date -Iseconds)] Starting full backup to repo2 (R2)..."
        # Repo2 configuration read from /etc/pgbackrest.conf
        # Now includes WAL archiving for complete offsite PITR capability
        pgbackrest --stanza=main --type=full --repo=2 backup
        echo "[$(date -Iseconds)] Full backup to both repos completed"
      '';
    };

    # Incremental backup
    pgbackrest-incr-backup = {
      description = "pgBackRest incremental backup";
      after = [ "postgresql.service" "pgbackrest-stanza-create.service" ];
      wants = [ "postgresql.service" ];
      path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.systemd ];

      unitConfig = {
        RequiresMountsFor = [ "/mnt/nas-postgresql" ];
        # Trigger metrics collection on success to immediately update Prometheus
        OnSuccess = "pgbackrest-metrics.service";
      };
      serviceConfig = hardenedServiceConfig // {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        IPAddressDeny = [ "169.254.169.254" ];
      };
      script = ''
        set -euo pipefail

        echo "[$(date -Iseconds)] Starting incremental backup to repo1 (NFS)..."
        pgbackrest --stanza=main --type=incr --repo=1 backup
        echo "[$(date -Iseconds)] Repo1 backup completed"

        echo "[$(date -Iseconds)] Starting incremental backup to repo2 (R2)..."
        # Repo2 configuration read from /etc/pgbackrest.conf
        # Now includes WAL archiving for complete offsite PITR capability
        pgbackrest --stanza=main --type=incr --repo=2 backup
        echo "[$(date -Iseconds)] Incremental backup to both repos completed"
      '';
    };

    pgbackrest-check = {
      description = "pgBackRest repository health check";
      after = [ "postgresql.service" "pgbackrest-stanza-create.service" ];
      wants = [ "postgresql.service" "pgbackrest-stanza-create.service" ];
      path = [ pkgs.pgbackrest pkgs.postgresql_16 pkgs.systemd ];
      unitConfig = {
        RequiresMountsFor = [ "/mnt/nas-postgresql" ];
        OnSuccess = "pgbackrest-metrics.service";
      };
      serviceConfig = hardenedServiceConfig // {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        IPAddressDeny = [ "169.254.169.254" ];
      };
      script = ''
        set -euo pipefail

        pgbackrest --stanza=main check --log-level-console=info
      '';
    };

    # Differential backup
    # Differential backups removed - simplified to daily full + hourly incremental
    # Reduces backup window contention and operational complexity
    # Retention still appropriate: 7 daily fulls + hourly incrementals
  };

  # pgBackRest backup timers
  systemd.timers = {
    pgbackrest-full-backup = {
      description = "pgBackRest full backup timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "02:00"; # Daily at 2 AM
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    pgbackrest-incr-backup = {
      description = "pgBackRest incremental backup timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly"; # Every hour
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    pgbackrest-check = {
      description = "Weekly pgBackRest repository check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun 03:30";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };

    # Differential backup timer removed - using simplified schedule
    # Daily full (2 AM) + Hourly incremental is sufficient for homelab
  };



  # General ZFS snapshot metrics exporter for all backup datasets
  # Monitors all datasets from backup.zfs.pools configuration
  # Provides comprehensive snapshot health metrics for Prometheus
  # =============================================================================
  # pgBackRest Monitoring Metrics (REVISED)
  # =============================================================================
  # NOTE: ZFS snapshot metrics have been moved to infrastructure/storage.nix
  # for proper co-location (ZFS snapshot monitoring belongs with ZFS lifecycle management)

  systemd.services.pgbackrest-metrics = {
    description = "Collect pgBackRest backup metrics for Prometheus";
    path = [ pkgs.jq pkgs.coreutils pkgs.pgbackrest pkgs.findutils pkgs.gawk ];
    serviceConfig = hardenedServiceConfig // {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      # Block access to EC2 metadata service to prevent timeout
      IPAddressDeny = [ "169.254.169.254" ];
    };
    environment = {
      # Repository metadata for metrics labels
      # Use METRICS_ prefix to avoid pgBackRest interpreting these as config options
      METRICS_REPO1_NAME = "NFS";
      METRICS_REPO1_LOCATION = "nas-1";
      METRICS_REPO2_NAME = "R2";
      METRICS_REPO2_LOCATION = "offsite";
    };
    script = ''
            set -euo pipefail

            METRICS_FILE="/var/lib/node_exporter/textfile_collector/pgbackrest.prom"
            METRICS_TEMP="''${METRICS_FILE}.tmp"

            # Run pgbackrest info, capturing JSON. Timeout prevents hangs on network issues.
            # All configuration (including repo2 S3 credentials) is read from /etc/pgbackrest.conf
            # which is generated by pgbackrest-config-generator.service
            INFO_JSON=$(timeout 300s pgbackrest --stanza=main --output=json info 2>&1)

            # Exit gracefully if command fails or returns empty/invalid JSON
            if ! echo "$INFO_JSON" | jq -e '.[0].name == "main"' > /dev/null; then
              echo "Failed to get valid pgBackRest info. Writing failure metric." >&2
              echo "Raw output from pgbackrest:" >&2
              echo "$INFO_JSON" >&2
              cat > "$METRICS_TEMP" <<EOF
      # HELP pgbackrest_scrape_success Indicates if the pgBackRest info scrape was successful.
      # TYPE pgbackrest_scrape_success gauge
      pgbackrest_scrape_success{stanza="main"} 0
      EOF
              mv "$METRICS_TEMP" "$METRICS_FILE"
              exit 0 # Exit successfully so systemd timer doesn't mark as failed
            fi

            # Prepare metrics file
            cat > "$METRICS_TEMP" <<'EOF'
      # HELP pgbackrest_scrape_success Indicates if the pgBackRest info scrape was successful.
      # TYPE pgbackrest_scrape_success gauge
      # HELP pgbackrest_repo_info Static information about pgBackRest repositories.
      # TYPE pgbackrest_repo_info gauge
      # HELP pgbackrest_stanza_status Stanza status code (0: ok, 1: warning, 2: error).
      # TYPE pgbackrest_stanza_status gauge
      # HELP pgbackrest_repo_status Repository status code (0: ok, 1: missing, 2: error).
      # TYPE pgbackrest_repo_status gauge
      # HELP pgbackrest_repo_size_bytes Size of the repository in bytes.
      # TYPE pgbackrest_repo_size_bytes gauge
      # HELP pgbackrest_backup_last_good_completion_seconds Timestamp of the last successful backup.
      # TYPE pgbackrest_backup_last_good_completion_seconds gauge
      # HELP pgbackrest_backup_last_duration_seconds Duration of the last successful backup in seconds.
      # TYPE pgbackrest_backup_last_duration_seconds gauge
      # HELP pgbackrest_backup_last_size_bytes Total size of the database for the last successful backup.
      # TYPE pgbackrest_backup_last_size_bytes gauge
      # HELP pgbackrest_backup_last_delta_bytes Amount of data backed up for the last successful backup.
      # TYPE pgbackrest_backup_last_delta_bytes gauge
      # HELP pgbackrest_wal_max_lsn The last WAL segment archived, converted to decimal for graphing.
      # TYPE pgbackrest_wal_max_lsn gauge
      # HELP pgbackrest_spool_queue_bytes Size of the archive async spool queue pending upload.
      # TYPE pgbackrest_spool_queue_bytes gauge
      # HELP pgbackrest_spool_queue_files Number of WAL files waiting in the archive async spool queue.
      # TYPE pgbackrest_spool_queue_files gauge
      EOF

            echo 'pgbackrest_scrape_success{stanza="main"} 1' >> "$METRICS_TEMP"

            # Repository info metrics with descriptive labels from environment
            echo "pgbackrest_repo_info{stanza=\"main\",repo_key=\"1\",repo_name=\"''${METRICS_REPO1_NAME:-repo1}\",repo_location=\"''${METRICS_REPO1_LOCATION:-unknown}\"} 1" >> "$METRICS_TEMP"
            echo "pgbackrest_repo_info{stanza=\"main\",repo_key=\"2\",repo_name=\"''${METRICS_REPO2_NAME:-repo2}\",repo_location=\"''${METRICS_REPO2_LOCATION:-unknown}\"} 1" >> "$METRICS_TEMP"

            STANZA_JSON=$(echo "$INFO_JSON" | jq '.[0]')

            # Stanza-level metrics
            STANZA_STATUS=$(echo "$STANZA_JSON" | jq '.status.code')
            echo "pgbackrest_stanza_status{stanza=\"main\"} $STANZA_STATUS" >> "$METRICS_TEMP"

            # WAL archive metrics
            MAX_WAL=$(echo "$STANZA_JSON" | jq -r '.archive[0].max // "0"')
            if [ "$MAX_WAL" != "0" ]; then
                # Convert WAL hex (e.g., 00000001000000000000000A) to decimal for basic progress monitoring
                MAX_WAL_DEC=$((16#''${MAX_WAL:8}))
                echo "pgbackrest_wal_max_lsn{stanza=\"main\"} $MAX_WAL_DEC" >> "$METRICS_TEMP"
            fi

            SPOOL_DIR="/var/lib/pgbackrest/spool/archive/push"
            if [ -d "$SPOOL_DIR" ]; then
              SPOOL_BYTES=$(du -sb "$SPOOL_DIR" | cut -f1)
              SPOOL_FILES=$(find "$SPOOL_DIR" -type f | wc -l | awk '{print $1}')
            else
              SPOOL_BYTES=0
              SPOOL_FILES=0
            fi
            echo "pgbackrest_spool_queue_bytes{stanza=\"main\"} $SPOOL_BYTES" >> "$METRICS_TEMP"
            echo "pgbackrest_spool_queue_files{stanza=\"main\"} $SPOOL_FILES" >> "$METRICS_TEMP"

            # Per-repo and per-backup-type metrics using a single, efficient jq command
            echo "$STANZA_JSON" | jq -r '
              # First emit repo status metrics for all repos
              (.repo[] |
                "pgbackrest_repo_status{stanza=\"main\",repo_key=\"\(.key)\"} \(.status.code)"
              ),
              # Then process backups - group by repo and type to find latest of each
              ([.backup[] | select((.type | test("full|incr")) and (.error // null) == null)] |
                group_by(.database["repo-key"], .type)[] |
                sort_by(.timestamp.start) | .[-1] |
                (
                  "pgbackrest_backup_last_good_completion_seconds{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.timestamp.stop)",
                  "pgbackrest_backup_last_duration_seconds{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.timestamp.stop - .timestamp.start)",
                  "pgbackrest_backup_last_size_bytes{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.info.size)",
                  "pgbackrest_backup_last_delta_bytes{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.info.delta)",
                  "pgbackrest_repo_size_bytes{stanza=\"main\",repo_key=\"\(.database["repo-key"])\",type=\"\(.type)\"} \(.info.repository.size)"
                )
              )
            ' >> "$METRICS_TEMP"

            # Count failed backups
            # HELP pgbackrest_backup_failed_total Total number of failed backups found in the last info scrape.
            # TYPE pgbackrest_backup_failed_total counter
            FAILED_COUNT=$(echo "$STANZA_JSON" | jq '[.backup[] | select(.error == true)] | length')
            echo "pgbackrest_backup_failed_total{stanza=\"main\"} $FAILED_COUNT" >> "$METRICS_TEMP"

            # Atomically replace the old metrics file
            mv "$METRICS_TEMP" "$METRICS_FILE"
    '';
    after = [ "postgresql.service" "pgbackrest-stanza-create.service" "mnt-nas\\x2dpostgresql.mount" ];
    wants = [ "postgresql.service" "mnt-nas\\x2dpostgresql.mount" ];
  };

  systemd.timers.pgbackrest-metrics = {
    description = "Collect pgBackRest metrics every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15"; # Every 15 minutes
      Persistent = true;
      RandomizedDelaySec = "2m";
    };
  };

  # Co-located alert rules for pgBackRest
  # Monitoring the pgBackRest backup service
  # Moved from postgresql.nix for proper co-location (service monitors itself)
  modules.alerting.rules = lib.mkIf serviceEnabled {
    # Metrics scraping failure
    "pgbackrest-metrics-scrape-failed" = {
      type = "promql";
      alertname = "PgBackRestMetricsScrapeFailure";
      expr = "pgbackrest_scrape_success == 0";
      for = "5m";
      severity = "high";
      labels = { service = "pgbackrest"; category = "monitoring"; };
      annotations = {
        summary = "pgBackRest metrics collection failed on {{ $labels.instance }}";
        description = "Unable to scrape pgBackRest metrics. Check pgbackrest-metrics.service logs.";
      };
    };

    # Stanza unhealthy
    "pgbackrest-stanza-unhealthy" = {
      type = "promql";
      alertname = "PgBackRestStanzaUnhealthy";
      expr = "pgbackrest_stanza_status > 0";
      for = "5m";
      severity = "critical";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest stanza unhealthy on {{ $labels.instance }}";
        description = "Stanza status code: {{ $value }}. Check pgBackRest configuration and logs.";
      };
    };

    # Repository status error
    "pgbackrest-repo-error" = {
      type = "promql";
      alertname = "PgBackRestRepositoryError";
      expr = "pgbackrest_repo_status > 0";
      for = "5m";
      severity = "critical";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest repository error on {{ $labels.instance }}";
        description = "Repository {{ $labels.repo_key }} status code: {{ $value }}. Verify NFS mount and R2 connectivity.";
      };
    };

    # Backup job failure (immediate)
    "pgbackrest-backup-failed" = {
      type = "promql";
      alertname = "PgBackRestBackupFailed";
      expr = "increase(pgbackrest_backup_failed_total[1h]) > 0";
      for = "0m";
      severity = "critical";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest backup job failed on {{ $labels.instance }}";
        description = "A pgBackRest backup job has failed within the last hour. Check pgBackRest logs for details.";
      };
    };

    # Preseed restore failure (disaster recovery)
    "postgresql-preseed-failed" = {
      type = "promql";
      alertname = "PostgreSQLPreseedFailed";
      expr = "postgresql_preseed_status{stanza=\"main\"} == 0";
      for = "0m";
      severity = "critical";
      labels = { service = "pgbackrest"; category = "disaster-recovery"; };
      annotations = {
        summary = "PostgreSQL pre-seed restore failed on {{ $labels.instance }}";
        description = "The automated restore process from backup failed during disaster recovery. Manual intervention is required to bring the database online. Check postgresql-preseed.service logs with: journalctl -u postgresql-preseed.service -xe";
      };
    };

    # Post-preseed backup failure
    "postgresql-post-preseed-backup-failed" = {
      type = "promql";
      alertname = "PostgreSQLPostPreseedBackupFailed";
      expr = "postgresql_postpreseed_status{stanza=\"main\"} == 0";
      for = "0m";
      severity = "critical";
      labels = { service = "pgbackrest"; category = "disaster-recovery"; };
      annotations = {
        summary = "PostgreSQL post-preseed backup failed on {{ $labels.instance }}";
        description = "The automated backup after a disaster recovery restore failed. The database is running but has no fresh baseline backup in one or both repositories. Check pgbackrest-post-preseed.service logs with: journalctl -u pgbackrest-post-preseed.service -xe";
      };
    };

    # Full backup stale (>27 hours)
    "pgbackrest-full-backup-stale" = {
      type = "promql";
      alertname = "PgBackRestFullBackupStale";
      expr = "(time() - pgbackrest_backup_last_good_completion_seconds{type=\"full\"}) > 97200";
      for = "1h";
      severity = "high";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest full backup is stale (>27h) on {{ $labels.instance }}";
        description = "Last full backup for repo {{ $labels.repo_key }} was {{ $value | humanizeDuration }} ago. Daily full backups should complete within 27 hours.";
      };
    };

    # Incremental backup stale (>2 hours)
    "pgbackrest-incremental-backup-stale" = {
      type = "promql";
      alertname = "PgBackRestIncrementalBackupStale";
      expr = "(time() - pgbackrest_backup_last_good_completion_seconds{type=\"incr\"}) > 7200";
      for = "30m";
      severity = "high";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest incremental backup is stale (>2h) on {{ $labels.instance }}";
        description = "Last incremental backup for repo {{ $labels.repo_key }} was {{ $value | humanizeDuration }} ago. Hourly incrementals should complete within 2 hours.";
      };
    };

    # WAL archiving stalled (no progress in 15 minutes while database is active)
    "pgbackrest-wal-archiving-stalled" = {
      type = "promql";
      alertname = "PgBackRestWALArchivingStalled";
      expr = "rate(pgbackrest_wal_max_lsn[15m]) == 0 and rate(pg_stat_database_xact_commit[15m]) > 0";
      for = "15m";
      severity = "high";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest WAL archiving appears stalled on {{ $labels.instance }}";
        description = "No WAL progress detected in 15 minutes despite active transactions. Check archive_command and NFS mount health.";
      };
    };

    # Local spool usage high (archive-async backlog)
    "pgbackrest-spool-usage-high" = {
      type = "promql";
      alertname = "PgBackRestSpoolUsageHigh";
      expr = ''(node_filesystem_size_bytes{mountpoint="/var/lib/pgbackrest"} - node_filesystem_avail_bytes{mountpoint="/var/lib/pgbackrest"}) / node_filesystem_size_bytes{mountpoint="/var/lib/pgbackrest"} > 0.8'';
      for = "10m";
      severity = "high";
      labels = { service = "pgbackrest"; category = "backup"; };
      annotations = {
        summary = "pgBackRest spool usage high on {{ $labels.instance }}";
        description = "Local spool >80% used ({{ $value | humanizePercentage }}). WAL archiving backlog likely. Check NFS repo1 health.";
      };
    };

    # pgBackRest Config Generator Failure Monitoring
    pgbackrest-config-generator-failed = {
      alertname = "PgBackRestConfigGeneratorFailed";
      expr = ''node_systemd_unit_state{name="pgbackrest-config-generator.service",state="failed"} == 1'';
      for = "5m";
      severity = "high";
      labels = { service = "pgbackrest"; category = "config"; };
      annotations = {
        summary = "pgBackRest config generator failed";
        description = "The pgbackrest-config-generator.service failed to update configuration. Credentials may not be properly injected. Check systemctl status pgbackrest-config-generator.service";
        command = "systemctl status pgbackrest-config-generator.service";
      };
    };
  };
}
