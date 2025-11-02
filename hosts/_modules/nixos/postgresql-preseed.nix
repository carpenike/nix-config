{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.postgresql.preSeed;
  pgCfg = config.services.postgresql;

  # Helper to determine if PGDATA is empty
  pgDataPath = pgCfg.dataDir;

  # Marker file location - OUTSIDE PGDATA to avoid dataset layering issues
  # Stored in parent directory (/var/lib/postgresql/) to survive PGDATA deletion
  # Version-independent to avoid orphaned markers after upgrades
  markerFile = "/var/lib/postgresql/.preseed-completed";

  # Build the pgbackrest restore command
  restoreCommand = pkgs.writeShellScript "postgresql-preseed-restore" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # --- Structured Logging & Error Handling ---
    LOG_SERVICE_NAME="postgresql-preseed"
    METRICS_FILE="/var/lib/node_exporter/textfile_collector/postgresql_preseed.prom"

    # Logs a structured JSON message to stdout.
    # Usage: log_json <LEVEL> <EVENT_NAME> <MESSAGE> [JSON_DETAILS]
    log_json() {
      local level="$1"
      local event="$2"
      local message="$3"
      local details_json="''${4:-{}}"

      # Using printf for safer string handling.
      printf '{"timestamp":"%s","service":"%s","level":"%s","event":"%s","message":"%s","details":%s}\n' \
        "$(date -u --iso-8601=seconds)" \
        "''${LOG_SERVICE_NAME}" \
        "$level" \
        "$event" \
        "$message" \
        "$details_json"
    }

    # Atomically writes metrics for Prometheus.
    # Usage: write_metrics <status: "success"|"failure"> <duration_seconds> <repository>
    write_metrics() {
      local status="$1"
      local duration="$2"
      local repo="''${3:-none}"
      local status_code=$([ "$status" = "success" ] && echo 1 || echo 0)

      # Write directly to avoid directory write permission requirement
      cat > "$METRICS_FILE" <<EOF
# HELP postgresql_preseed_status Indicates the status of the last pre-seed attempt (1 for success, 0 for failure).
# TYPE postgresql_preseed_status gauge
postgresql_preseed_status{stanza="${cfg.source.stanza}",repository="''${repo}"} ''${status_code}
# HELP postgresql_preseed_last_duration_seconds Duration of the last pre-seed restore in seconds.
# TYPE postgresql_preseed_last_duration_seconds gauge
postgresql_preseed_last_duration_seconds{stanza="${cfg.source.stanza}",repository="''${repo}"} ''${duration}
# HELP postgresql_preseed_last_completion_timestamp_seconds Timestamp of the last pre-seed restore completion.
# TYPE postgresql_preseed_last_completion_timestamp_seconds gauge
postgresql_preseed_last_completion_timestamp_seconds{stanza="${cfg.source.stanza}",repository="''${repo}"} $(date +%s)
EOF
    }

    # Trap for logging errors before exiting.
    trap_error() {
      local exit_code=$?
      local line_no=$1
      local command="$2"
      log_json "ERROR" "script_error" "Script failed with exit code $exit_code at line $line_no: $command" \
        "{\"exit_code\": ''${exit_code}, \"line_number\": ''${line_no}, \"command\": \"$command\"}"
      # Write failure metrics before exiting (resilient to write failure)
      write_metrics "failure" 0 "none" || true
      exit $exit_code
    }
    trap 'trap_error $LINENO "$BASH_COMMAND"' ERR
    # --- End Helpers ---

    log_json "INFO" "preseed_start" "PostgreSQL pre-seed restore starting." \
      "{\"target\":\"${pgDataPath}\",\"stanza\":\"${cfg.source.stanza}\",\"backup_set\":\"${cfg.source.backupSet}\",\"repository\":${toString cfg.source.repository}}"

    # Create in-progress marker for debuggability
    # Allows detection of crashed/incomplete restores on subsequent boots
    PROGRESS_MARKER="/var/lib/postgresql/.preseed-in-progress"
    cat > "$PROGRESS_MARKER" <<EOF
started_at=$(date -Iseconds)
pid=$$
stanza=${cfg.source.stanza}
repository=${toString cfg.source.repository}
EOF
    log_json "INFO" "preseed_progress_marker" "Created in-progress marker at $PROGRESS_MARKER"

    # Ensure PGDATA directory exists (pgbackrest restore can create it, but explicit is better)
    log_json "INFO" "pgdata_ensure" "Ensuring PGDATA directory exists." "{\"path\":\"${pgDataPath}\"}"
    mkdir -p "${pgDataPath}"

    # Safety check: Decide what to do if PGDATA is not empty
    if [ -d "${pgDataPath}" ] && [ "$(ls -A "${pgDataPath}" 2>/dev/null)" ]; then
      # Validate PGDATA integrity by checking for essential files and directories
      # More robust than just postgresql.conf + PG_VERSION to catch corrupted restores
      if [ -f "${pgDataPath}/postgresql.conf" ] && \
         [ -f "${pgDataPath}/PG_VERSION" ] && \
         [ -d "${pgDataPath}/global" ] && \
         [ -d "${pgDataPath}/pg_wal" ]; then
        log_json "INFO" "preseed_skipped" "PGDATA is already initialized. Skipping pre-seed restore." '{"reason":"existing_pgdata"}'
        # Create the completion marker to ensure this check is skipped on future boots.
        cat > "${markerFile}" <<EOF
postgresql_version=${toString pgCfg.package.version}
restored_at=$(date -Iseconds)
restored_from=existing_pgdata
EOF
        log_json "INFO" "marker_created" "Completion marker created at ${markerFile}"
        exit 0
      else
        log_json "ERROR" "preseed_failed" "PGDATA directory is not empty but appears incomplete or corrupted." '{"reason":"incomplete_pgdata"}'
        log_json "ERROR" "preseed_failed" "Missing one or more essential components: postgresql.conf, PG_VERSION, global/, or pg_wal/"
        log_json "ERROR" "preseed_failed" "To force a re-seed, stop postgresql, clear PGDATA, remove ${markerFile}, and reboot."
        exit 1
      fi
    fi

    # Wait up to 30 seconds for the PGDATA directory to be owned by the 'postgres' user.
    # This mitigates a common race condition on boot where a ZFS dataset is mounted
    # as root:root before a separate systemd service or tmpfiles rule has a chance
    # to chown it to postgres:postgres.
    log_json "INFO" "ownership_wait" "Waiting for PGDATA directory to be owned by postgres user..." "{\"path\":\"${pgDataPath}\"}"
    WAIT_TIMEOUT=30
    while [ "$(stat -c '%U' "${pgDataPath}")" != "postgres" ]; do
      if [ $WAIT_TIMEOUT -le 0 ]; then
        CURRENT_OWNER="$(stat -c '%U' "${pgDataPath}")"
        log_json "ERROR" "ownership_timeout" "Timed out waiting for correct ownership on PGDATA." \
          "{\"path\":\"${pgDataPath}\", \"expected_owner\":\"postgres\", \"current_owner\":\"''${CURRENT_OWNER}\"}"
        exit 1
      fi
      WAIT_TIMEOUT=$((WAIT_TIMEOUT - 1))
      sleep 1
    done
    log_json "INFO" "ownership_ok" "PGDATA directory ownership is correct."

    ${optionalString (cfg.source.fallbackRepository == 2 && cfg.environmentFile != null) ''
      # Transform AWS credentials to pgBackRest format for repo2 fallback
      if [ -n "''${AWS_ACCESS_KEY_ID:-}" ] && [ -n "''${AWS_SECRET_ACCESS_KEY:-}" ]; then
        export PGBACKREST_REPO2_S3_KEY="$AWS_ACCESS_KEY_ID"
        export PGBACKREST_REPO2_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"
        log_json "INFO" "repo2_credentials_configured" "R2/S3 credentials configured for fallback repository."
      fi
    ''}

    # Execute the restore with fallback support
    log_json "INFO" "restore_start" "Running pgBackRest restore from primary repository ${toString cfg.source.repository}..."
    start_time=$(date +%s)

    restore_success=false
    restore_repo=""

    # Attempt primary repository restore
    if ${pkgs.pgbackrest}/bin/pgbackrest \
      --stanza=${cfg.source.stanza} \
      --repo=${toString cfg.source.repository} \
      ${optionalString (cfg.source.backupSet != "latest") "--set=${cfg.source.backupSet}"} \
      --type=immediate \
      --target-action=${cfg.targetAction} \
      --delta \
      --log-level-console=info \
      restore 2>&1; then
      restore_success=true
      restore_repo="${toString cfg.source.repository}"
      log_json "INFO" "restore_primary_success" "Primary repository restore succeeded." "{\"repository\":${toString cfg.source.repository}}"
    else
      log_json "WARN" "restore_primary_failed" "Primary repository restore failed" "{\"primary_repo\":${toString cfg.source.repository}}"
${optionalString (cfg.source.fallbackRepository != null) ''
      log_json "INFO" "restore_fallback_attempt" "Attempting fallback to repository ${toString cfg.source.fallbackRepository}" "{\"fallback_repo\":${toString cfg.source.fallbackRepository}}"

      # Pre-flight check: Validate fallback repository is accessible before attempting restore
      log_json "INFO" "restore_fallback_preflight" "Validating fallback repository accessibility..."
      if ! ${pkgs.pgbackrest}/bin/pgbackrest \
        --stanza=${cfg.source.stanza} \
        --repo=${toString cfg.source.fallbackRepository} \
        info >/dev/null 2>&1; then
        log_json "ERROR" "restore_fallback_unreachable" "Fallback repository is unreachable or misconfigured. Check credentials and connectivity." "{\"fallback_repo\":${toString cfg.source.fallbackRepository}}"
        exit 1
      fi
      log_json "INFO" "restore_fallback_preflight_ok" "Fallback repository is accessible, proceeding with restore..."

      if ${pkgs.pgbackrest}/bin/pgbackrest \
        --stanza=${cfg.source.stanza} \
        --repo=${toString cfg.source.fallbackRepository} \
        ${optionalString (cfg.source.backupSet != "latest") "--set=${cfg.source.backupSet}"} \
        --type=immediate \
        --target-action=${cfg.targetAction} \
        --delta \
        --log-level-console=info \
        restore 2>&1; then
        restore_success=true
        restore_repo="${toString cfg.source.fallbackRepository}"
        log_json "INFO" "restore_fallback_success" "Fallback repository restore succeeded" "{\"repository\":${toString cfg.source.fallbackRepository}}"
      else
        log_json "ERROR" "restore_all_failed" "Both primary and fallback repository restores failed" "{\"primary_repo\":${toString cfg.source.repository},\"fallback_repo\":${toString cfg.source.fallbackRepository}}"
        exit 1
      fi
''}${optionalString (cfg.source.fallbackRepository == null) ''
      log_json "ERROR" "restore_failed_no_fallback" "Primary repository restore failed and no fallback configured" "{\"repository\":${toString cfg.source.repository}}"
      exit 1
''}
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    log_json "INFO" "restore_complete" "pgBackRest restore completed successfully from repository ''${restore_repo}." "{\"duration_seconds\":''${duration},\"repository\":\"''${restore_repo}\"}"

    # Run post-restore hook if configured
    ${optionalString (cfg.postRestoreScript != null) ''
      log_json "INFO" "post_restore_script_start" "Running post-restore sanitization script."
      script_start_time=$(date +%s)
      ${cfg.postRestoreScript}
      script_end_time=$(date +%s)
      script_duration=$((script_end_time - script_start_time))
      log_json "INFO" "post_restore_script_complete" "Post-restore sanitization completed." "{\"duration_seconds\":''${script_duration}}"
    ''}

    # Create completion marker to prevent re-runs
    cat > "${markerFile}" <<EOF
postgresql_version=${toString pgCfg.package.version}
restored_at=$(date -Iseconds)
restored_from=${cfg.source.stanza}@repo''${restore_repo}
restore_type=$([ "''${restore_repo}" = "${toString cfg.source.repository}" ] && echo "primary" || echo "fallback")
duration_seconds=''${duration}
EOF
    log_json "INFO" "marker_created" "Completion marker created at ${markerFile}" "{\"restored_from_repo\":\"''${restore_repo}\"}"

    # Remove in-progress marker on successful completion
    rm -f "$PROGRESS_MARKER"
    log_json "INFO" "preseed_progress_cleanup" "Removed in-progress marker"

    # Write success metrics with repository label (resilient to write failure)
    write_metrics "success" "''${duration}" "''${restore_repo}" || true

    log_json "INFO" "preseed_complete" "Pre-seed restore process finished successfully."
  '';

in {
  options.services.postgresql.preSeed = {
    enable = mkEnableOption "automatic restore of PostgreSQL from backup on empty PGDATA";

    environment = mkOption {
      type = types.nullOr (types.enum [ "production" "development" "staging" "test" ]);
      default = null;
      description = ''
        Environment type for multi-environment setups.

        For homelab/single-server setups: Leave as null (default).
        For production with staging: Set to prevent accidental production restores.

        When set to "production", the module will refuse to run (safety check).
        This is only useful if you have separate production AND staging configs.
      '';
    };

    source = {
      stanza = mkOption {
        type = types.str;
        example = "main";
        description = "pgBackRest stanza name to restore from";
      };

      repository = mkOption {
        type = types.int;
        default = 1;
        example = 2;
        description = ''
          pgBackRest repository number to restore from.

          repo1 (NFS) is RECOMMENDED for pre-seeding:
          - Faster restore (local network)
          - No egress costs
          - Has WAL files for more complete restore

          repo2 (R2) use cases:
          - Remote staging servers (not on NAS network)
          - Longer retention needs (30 days vs 7 days)
          - Testing offsite recovery procedures
        '';
      };

      fallbackRepository = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 2;
        description = ''
          Optional fallback repository to attempt if primary repository fails.

          Recommended: Set to 2 (R2/S3) when repository = 1 (NFS).
          This enables disaster recovery when NFS is unavailable but offsite backup exists.

          The fallback will only be attempted if the primary restore fails.
          Requires R2 credentials to be available if fallback is repo2.
        '';
      };

      backupSet = mkOption {
        type = types.str;
        default = "latest";
        example = "20231015-120000F";
        description = ''
          Backup set to restore. Use "latest" for most recent backup,
          or specify a backup label for consistent test environments.
        '';
      };
    };

    targetAction = mkOption {
      type = types.enum [ "promote" "shutdown" ];
      default = "promote";
      description = ''
        Action after restore completes. "promote" brings database online immediately,
        "shutdown" leaves it stopped for manual inspection (rarely needed).
      '';
    };

    postRestoreScript = mkOption {
      type = types.nullOr types.lines;
      default = null;
      example = literalExpression ''
        ''''
          echo "Sanitizing PII..."
          # IMPORTANT: Wrap SQL in transactions with error handling for atomicity
          ''${pkgs.postgresql}/bin/psql -v ON_ERROR_STOP=1 -d myapp -U postgres <<SQL
            BEGIN;
            UPDATE users SET email = 'user-' || id || '@example.com';
            UPDATE customers SET phone = '555-0000';
            COMMIT;
          SQL
        ''''
      '';
      description = ''
        Script to run after restore but before PostgreSQL starts.
        Critical for data sanitization, PII removal, and test data generation.
        Runs as the postgres user with PGDATA available but PostgreSQL not yet running.

        BEST PRACTICES:
        - Always wrap SQL statements in explicit BEGIN/COMMIT transactions
        - Use psql's -v ON_ERROR_STOP=1 flag to abort on first error
        - Test scripts thoroughly in non-production environments first
        - If any statement fails, the transaction will rollback automatically
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/pgbackrest/r2-credentials";
      description = ''
        Path to environment file containing credentials for repo2 (R2/S3).
        Required when fallbackRepository is set to 2.

        File should contain AWS-compatible credentials:
          AWS_ACCESS_KEY_ID=...
          AWS_SECRET_ACCESS_KEY=...

        These will be transformed to pgBackRest format automatically.
      '';
    };
  };

  config = mkIf cfg.enable {
    # SAFETY CHECK: Prevent accidental auto-restore in multi-environment setups
    # For homelab: This check is effectively disabled (environment = null)
    # For prod+staging: Set environment = "production" to block auto-restore
    assertions = [
      {
        assertion = cfg.environment != "production";
        message = ''
          ERROR: PostgreSQL automatic restore is DISABLED when environment = "production".

          This safety check prevents auto-restore on production servers in multi-environment setups.

          For homelab disaster recovery: Set environment = null (or omit it entirely)
          For staging/dev environments: Set environment = "staging" or "test"

          If you need to restore production, either:
          1. Temporarily set environment = null to allow auto-restore
          2. Use manual restore: pgbackrest --stanza=main --repo=1 restore
        '';
      }
      {
        assertion = pgCfg.enable;
        message = "PostgreSQL must be enabled to use pre-seed restore";
      }
      {
        assertion = cfg.source.stanza != "";
        message = "pgBackRest stanza name must be specified for pre-seed restore";
      }
    ];

    # Declaratively manage the metrics file for Prometheus textfile collector
    systemd.tmpfiles.rules = [
      "f /var/lib/node_exporter/textfile_collector/postgresql_preseed.prom 0644 postgres node-exporter - -"
    ];

    # Prepare service to ensure PGDATA ownership/permissions after ZFS mount
    systemd.services.postgresql-preseed-prepare = {
      description = "Prepare PGDATA mountpoint (ownership, permissions)";
      after = [ "zfs-service-datasets.service" "zfs-mount.service" ];
      path = with pkgs; [ util-linux coreutils ];
      unitConfig = {
        RequiresMountsFor = [ "${pgDataPath}" ];
        AssertPathIsMountPoint = "${pgDataPath}";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        # Ensure mountpoint exists and is the real dataset
        if ! mountpoint -q "${pgDataPath}"; then
          echo "PGDATA ${pgDataPath} is not a mountpoint" >&2
          exit 1
        fi

        # Fix marker directory ownership for marker file access
        MARKER_DIR="$(dirname "${markerFile}")"
        [[ "$MARKER_DIR" = "/var/lib/postgresql" ]] || { echo "Refusing to chown unexpected marker directory: $MARKER_DIR" >&2; exit 1; }
        install -d -m 0755 -o postgres -g postgres "$MARKER_DIR"

        # Enforce strict perms on PGDATA itself
        install -d -m 0700 -o postgres -g postgres "${pgDataPath}"

        echo "PGDATA and marker directory ownership/permissions set correctly"
      '';
    };

    # Create the systemd service for pre-seeding
    systemd.services.postgresql-preseed = {
      description = "PostgreSQL Pre-Seed Restore (New Server Provisioning)";
      wantedBy = [ "multi-user.target" ];
      before = [ "postgresql.service" ];
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" "zfs-service-datasets.service" "postgresql-preseed-prepare.service" ];
      wants = [ "network-online.target" ];
      requires = [ "systemd-tmpfiles-setup.service" "zfs-service-datasets.service" "postgresql-preseed-prepare.service" ];

      # Always evaluate whether preseed is needed - script handles idempotency
      unitConfig = {
        # Proper NFS mount dependency - eliminates brittle unit name encoding
        # Also wait for the PGDATA path itself to be mounted
        RequiresMountsFor =
          [ "${pgDataPath}" ]
          ++ lib.optional (cfg.source.repository == 1) "/mnt/nas-postgresql";
        AssertPathIsMountPoint = "${pgDataPath}";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = "${restoreCommand}";
      }
      // optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      }
      // {

        # Security hardening - DISABLED for NFS mount access
        # CRITICAL: Status 226 (NAMESPACE) error occurs even with ProtectSystem=full
        # when accessing NFS mounts. The systemd namespace isolation completely blocks
        # network filesystem access regardless of ReadWritePaths declarations.
        # Since this is a oneshot preseed service that runs only on empty PGDATA,
        # the security trade-off is acceptable for operational reliability.
        PrivateTmp = true;
        NoNewPrivileges = true;
        # ProtectSystem disabled - required for NFS mount access
        # ProtectHome disabled - required for NFS mount access
        # ReadWritePaths not needed when ProtectSystem is disabled

        # Timeout: Restores can take a while for large databases
        TimeoutStartSec = "2h";

        # Don't restart on failure - manual intervention needed
        Restart = "no";
      };
    };

    # Ensure PostgreSQL service waits for pre-seed if needed
    # Use requires instead of wants to prevent auto-init if preseed fails
    systemd.services.postgresql = {
      after = [ "postgresql-preseed.service" ];
      requires = [ "postgresql-preseed.service" ];
    };

    # Add helpful environment indicator
    environment.etc."postgresql-preseed-info".text = ''
      PostgreSQL Pre-Seed Configuration
      ==================================
      Environment: ${if cfg.environment != null then cfg.environment else "homelab (unspecified)"}
      Stanza: ${cfg.source.stanza}
      Repository: repo${toString cfg.source.repository}
      Backup Set: ${cfg.source.backupSet}

      This database will be automatically seeded from backup on first boot
      if PGDATA is empty. Subsequent boots will skip the restore.

      To force a re-seed:
      1. Stop PostgreSQL: systemctl stop postgresql
      2. Remove PGDATA: rm -rf ${pgDataPath}/*
      3. Remove completion marker: rm -f ${markerFile}
      4. Start PostgreSQL: systemctl start postgresql

      WARNING: This will destroy all local data!
    '';
  };
}
