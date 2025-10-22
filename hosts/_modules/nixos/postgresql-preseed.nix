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
    # Usage: write_metrics <status: "success"|"failure"> <duration_seconds>
    write_metrics() {
      local status="$1"
      local duration="$2"
      local status_code=$([ "$status" = "success" ] && echo 1 || echo 0)

      # Write directly to avoid directory write permission requirement
      cat > "$METRICS_FILE" <<EOF
# HELP postgresql_preseed_status Indicates the status of the last pre-seed attempt (1 for success, 0 for failure).
# TYPE postgresql_preseed_status gauge
postgresql_preseed_status{stanza="${cfg.source.stanza}"} ''${status_code}
# HELP postgresql_preseed_last_duration_seconds Duration of the last pre-seed restore in seconds.
# TYPE postgresql_preseed_last_duration_seconds gauge
postgresql_preseed_last_duration_seconds{stanza="${cfg.source.stanza}"} ''${duration}
# HELP postgresql_preseed_last_completion_timestamp_seconds Timestamp of the last pre-seed restore completion.
# TYPE postgresql_preseed_last_completion_timestamp_seconds gauge
postgresql_preseed_last_completion_timestamp_seconds{stanza="${cfg.source.stanza}"} $(date +%s)
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
      write_metrics "failure" 0 || true
      exit $exit_code
    }
    trap 'trap_error $LINENO "$BASH_COMMAND"' ERR
    # --- End Helpers ---

    log_json "INFO" "preseed_start" "PostgreSQL pre-seed restore starting." \
      "{\"target\":\"${pgDataPath}\",\"stanza\":\"${cfg.source.stanza}\",\"backup_set\":\"${cfg.source.backupSet}\",\"repository\":${toString cfg.source.repository}}"

    # Safety check: Decide what to do if PGDATA is not empty
    if [ -d "${pgDataPath}" ] && [ "$(ls -A "${pgDataPath}" 2>/dev/null)" ]; then
      if [ -f "${pgDataPath}/postgresql.conf" ] && [ -f "${pgDataPath}/PG_VERSION" ]; then
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
        log_json "ERROR" "preseed_failed" "PGDATA directory is not empty but appears incomplete. This may indicate a previously failed restore." '{"reason":"incomplete_pgdata"}'
        log_json "ERROR" "preseed_failed" "To force a re-seed, stop postgresql, clear PGDATA, and reboot."
        exit 1
      fi
    fi

    # Verify PGDATA directory exists (created by zfs-service-datasets.service)
    log_json "INFO" "pgdata_check" "Verifying PGDATA directory exists." "{\"path\":\"${pgDataPath}\"}"
    if [ ! -d "${pgDataPath}" ]; then
      log_json "ERROR" "pgdata_missing" "PGDATA directory does not exist. ZFS dataset creation may have failed." "{\"path\":\"${pgDataPath}\"}"
      exit 1
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

    # Execute the restore
    log_json "INFO" "restore_start" "Running pgBackRest restore..."
    start_time=$(date +%s)

    ${pkgs.pgbackrest}/bin/pgbackrest \
      --stanza=${cfg.source.stanza} \
      --repo=${toString cfg.source.repository} \
      ${optionalString (cfg.source.backupSet != "latest") "--set=${cfg.source.backupSet}"} \
      --type=immediate \
      --target-action=${cfg.targetAction} \
      --delta \
      --log-level-console=info \
      restore

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    log_json "INFO" "restore_complete" "pgBackRest restore completed successfully." "{\"duration_seconds\":''${duration}}"

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
restored_from=${cfg.source.stanza}@repo${toString cfg.source.repository}
EOF
    log_json "INFO" "marker_created" "Completion marker created at ${markerFile}"

    # Write success metrics (resilient to write failure)
    write_metrics "success" "''${duration}" || true

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
          ''${pkgs.postgresql}/bin/psql -d myapp -U postgres <<SQL
            UPDATE users SET email = 'user-' || id || '@example.com';
            UPDATE customers SET phone = '555-0000';
          SQL
        ''''
      '';
      description = ''
        Script to run after restore but before PostgreSQL starts.
        Critical for data sanitization, PII removal, and test data generation.
        Runs as the postgres user with PGDATA available but PostgreSQL not yet running.
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
        ConditionPathIsMountPoint = "${pgDataPath}";
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
        chown postgres:postgres "${pgDataPath}"
        chmod 0700 "${pgDataPath}"

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

      # Only run if the completion marker doesn't exist
      # Marker is outside PGDATA to avoid ZFS dataset layering issues
      unitConfig = {
        ConditionPathExists = "!${markerFile}";
        # Proper NFS mount dependency - eliminates brittle unit name encoding
        # Also wait for the PGDATA path itself to be mounted
        RequiresMountsFor = [ "/mnt/nas-postgresql" "${pgDataPath}" ];
        ConditionPathIsMountPoint = "${pgDataPath}";
        # Trigger post-preseed service on successful completion
        OnSuccess = [ "pgbackrest-post-preseed.service" ];
      };

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = "${restoreCommand}";

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
