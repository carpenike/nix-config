# PostgreSQL PITR shell scripts
# Extracted from default.nix for better readability and maintainability
{ lib, pkgs }:

let
  mkScripts = {
    instanceName,
    instanceCfg,
    dataDir,
    walArchiveDir,
    walIncomingDir,
    pgPackage,
    metricsDir,
  }:
  let
    # WAL archive script - atomically archives WAL files with crash safety
    # FIXES APPLIED:
    # - Per-file fsync (HIGH #2): Uses Python fdatasync instead of global sync
    # - Atomic metrics writes (HIGH #1): Uses temp file + mv for metrics
    walArchiveScript = pkgs.writeShellScript "pg-archive-wal-${instanceName}" ''
      set -euo pipefail

      # Arguments: %p (source path) %f (filename)
      SOURCE_PATH="$1"
      WAL_FILE="$2"
      TEMP_FILE="${walIncomingDir}/$WAL_FILE.tmp"
      DEST_FILE="${walIncomingDir}/$WAL_FILE"

      # Ensure incoming directory exists with correct permissions
      umask 007
      mkdir -p "${walIncomingDir}"

      # Atomic copy: install to temp (already running as postgres)
      ${pkgs.coreutils}/bin/install -m 0640 "$SOURCE_PATH" "$TEMP_FILE"

      # Per-file fsync for crash safety (FIX: MEDIUM #2)
      ${pkgs.python3}/bin/python3 -c 'import os,sys; f=os.open(sys.argv[1], os.O_RDONLY); os.fdatasync(f); os.close(f)' "$TEMP_FILE"

      # Atomic rename
      ${pkgs.coreutils}/bin/mv -f "$TEMP_FILE" "$DEST_FILE"

      # Fsync directory after rename to ensure metadata is durable
      ${pkgs.python3}/bin/python3 -c 'import os,sys; d=os.open(sys.argv[1], os.O_RDONLY); os.fsync(d); os.close(d)' "${walIncomingDir}"

      # Log success
      echo "$(date -Iseconds): Archived WAL file $WAL_FILE" >> "${walArchiveDir}/archive.log"

      # Update metrics with atomic write (FIX: HIGH #1) - only if metrics directory exists
      if [ -d "${metricsDir}" ]; then
        METRICS_FILE="${metricsDir}/postgresql_wal_archive.prom"
        METRICS_TEMP="$METRICS_FILE.tmp"
        cat > "$METRICS_TEMP" <<EOF
      # HELP postgresql_wal_archive_files_present WAL files currently in archive
      # TYPE postgresql_wal_archive_files_present gauge
      postgresql_wal_archive_files_present{instance="${instanceName}"} $(ls -1 "${walIncomingDir}" 2>/dev/null | wc -l)
      # HELP postgresql_wal_archive_last_success_timestamp Last successful archive timestamp
      # TYPE postgresql_wal_archive_last_success_timestamp gauge
      postgresql_wal_archive_last_success_timestamp{instance="${instanceName}"} $(date +%s)
      EOF
        ${pkgs.coreutils}/bin/mv "$METRICS_TEMP" "$METRICS_FILE"
      fi

      exit 0
    '';

    # WAL restore script - for PITR recovery
    # FIXES APPLIED:
    # - Fix WAL fetch snapshot selection (HIGH #2): Uses restic find + jq to locate specific snapshot
    walRestoreScript = pkgs.writeShellScript "pg-restore-wal-${instanceName}" ''
      set -euo pipefail

      # Arguments: %f (filename) %p (destination path)
      WAL_FILE="$1"
      DEST_PATH="$2"
      SOURCE_FILE="${walIncomingDir}/$WAL_FILE"

      # Step 1: Try to restore from local archive (fastest)
      if [ -f "$SOURCE_FILE" ]; then
        ${pkgs.coreutils}/bin/cp "$SOURCE_FILE" "$DEST_PATH"
        echo "$(date -Iseconds): Restored WAL file $WAL_FILE from local archive" >> "${walArchiveDir}/restore.log"
        exit 0
      fi

      # Step 2: Try to restore from Restic backup (remote fetch for PITR)
      # FIX: HIGH #2 - Find specific snapshot containing the WAL file instead of "restore latest"
      ${lib.optionalString (instanceCfg.backup.restic.enable && instanceCfg.backup.restic.repositoryUrl != "") ''
        echo "$(date -Iseconds): WAL file $WAL_FILE not in local archive, attempting Restic restore..." >> "${walArchiveDir}/restore.log"

        ${lib.optionalString (instanceCfg.backup.restic.environmentFile != null) ''
          set -a
          source ${lib.escapeShellArg instanceCfg.backup.restic.environmentFile}
          set +a
        ''}

        RESTORE_TEMP=$(${pkgs.coreutils}/bin/mktemp -d)
        trap "${pkgs.coreutils}/bin/rm -rf \"$RESTORE_TEMP\"" EXIT

        # Find the specific snapshot containing this WAL file (prefer newest)
        SNAP_JSON=$(${pkgs.restic}/bin/restic \
          --repo ${lib.escapeShellArg instanceCfg.backup.restic.repositoryUrl} \
          --password-file ${lib.escapeShellArg instanceCfg.backup.restic.passwordFile} \
          find "$WAL_FILE" --json 2>> "${walArchiveDir}/restore.log" || true)

        # Select the newest snapshot containing the file (sort by time desc, take first)
        SNAP_ID=$(echo "$SNAP_JSON" | ${pkgs.jq}/bin/jq -r 'sort_by(.time) | reverse | .[0].matches[0].snapshot // .[0].snapshot // empty')

        if [ -n "$SNAP_ID" ]; then
          if ${pkgs.restic}/bin/restic \
              --repo ${lib.escapeShellArg instanceCfg.backup.restic.repositoryUrl} \
              --password-file ${lib.escapeShellArg instanceCfg.backup.restic.passwordFile} \
              restore "$SNAP_ID" --target "$RESTORE_TEMP" --include "**/$WAL_FILE" >> "${walArchiveDir}/restore.log" 2>&1; then
            FOUND_FILE=$(${pkgs.findutils}/bin/find "$RESTORE_TEMP" -type f -name "$WAL_FILE" -print -quit)
            if [ -n "$FOUND_FILE" ]; then
              ${pkgs.coreutils}/bin/cp "$FOUND_FILE" "$DEST_PATH"
              echo "$(date -Iseconds): Restored WAL file $WAL_FILE from Restic snapshot $SNAP_ID" >> "${walArchiveDir}/restore.log"
              exit 0
            else
              echo "$(date -Iseconds): ERROR - WAL file $WAL_FILE not found in restored snapshot $SNAP_ID" >> "${walArchiveDir}/restore.log"
            fi
          fi
        else
          echo "$(date -Iseconds): No Restic snapshot found containing WAL file $WAL_FILE" >> "${walArchiveDir}/restore.log"
        fi
      ''}

      # WAL file not available - log and fail
      echo "$(date -Iseconds): ERROR - WAL file $WAL_FILE not found in local archive or Restic backup" >> "${walArchiveDir}/restore.log"
      exit 1
    '';

    # Base backup script - pg_basebackup with verification
    # FIXES APPLIED:
    # - Atomic metrics writes (HIGH #1): Uses temp file + mv for metrics
    baseBackupScript = pkgs.writeShellScript "pg-basebackup-${instanceName}" ''
      set -euo pipefail

      BACKUP_DIR="/var/backup/postgresql/${instanceName}"
      TIMESTAMP=$(date +%Y%m%d-%H%M%S)
      BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"

      mkdir -p "$BACKUP_DIR"

      echo "$(date -Iseconds): Starting base backup to $BACKUP_PATH" >> "$BACKUP_DIR/backup.log"

      # Perform base backup
      if ${pgPackage}/bin/pg_basebackup \
        -D "$BACKUP_PATH" \
        -F tar \
        -z \
        -P \
        -U postgres \
        -h /run/postgresql \
        -p ${toString instanceCfg.port} \
        >> "$BACKUP_DIR/backup.log" 2>&1; then

        echo "$(date -Iseconds): Base backup completed successfully" >> "$BACKUP_DIR/backup.log"

        # Verify backup on PostgreSQL 13+ (only if pg_verifybackup exists)
        if [ -x "${pgPackage}/bin/pg_verifybackup" ]; then
          echo "$(date -Iseconds): Verifying backup..." >> "$BACKUP_DIR/backup.log"
          if ${pgPackage}/bin/pg_verifybackup "$BACKUP_PATH" >> "$BACKUP_DIR/backup.log" 2>&1; then
            echo "$(date -Iseconds): Backup verification passed" >> "$BACKUP_DIR/backup.log"
          else
            echo "$(date -Iseconds): WARNING - Backup verification failed" >> "$BACKUP_DIR/backup.log"
          fi
        fi

        # Update metrics with atomic write (FIX: HIGH #1) - only if metrics directory exists
        if [ -d "${metricsDir}" ]; then
          METRICS_FILE="${metricsDir}/postgresql_backup.prom"
          METRICS_TEMP="$METRICS_FILE.tmp"
          cat > "$METRICS_TEMP" <<EOF
      # HELP postgresql_backup_last_success_timestamp Last successful backup timestamp
      # TYPE postgresql_backup_last_success_timestamp gauge
      postgresql_backup_last_success_timestamp{instance="${instanceName}",type="base"} $(date +%s)
      # HELP postgresql_backup_size_bytes Backup size in bytes
      # TYPE postgresql_backup_size_bytes gauge
      postgresql_backup_size_bytes{instance="${instanceName}",type="base"} $(du -sb "$BACKUP_PATH" | cut -f1)
      EOF
          ${pkgs.coreutils}/bin/mv "$METRICS_TEMP" "$METRICS_FILE"
        fi

        # Note: Notifications are handled via systemd OnFailure in default.nix
        # Success notifications not currently supported for PostgreSQL backups

      else
        echo "$(date -Iseconds): ERROR - Base backup failed" >> "$BACKUP_DIR/backup.log"
        exit 1
      fi
    '';

    # Health check script - verifies PostgreSQL is responding
    # FIXES APPLIED:
    # - Atomic metrics writes (HIGH #1): Uses temp file + mv for metrics
    healthCheckScript = pkgs.writeShellScript "pg-healthcheck-${instanceName}" ''
      set -euo pipefail

      # Simple connection test
      if ${pgPackage}/bin/psql -U postgres -h /run/postgresql -p ${toString instanceCfg.port} -c "SELECT 1" postgres > /dev/null 2>&1; then
        STATUS=1
        MESSAGE="healthy"
      else
        STATUS=0
        MESSAGE="unhealthy"
      fi

      # Update metrics with atomic write (FIX: HIGH #1) - only if metrics directory exists
      if [ -d "${metricsDir}" ]; then
        METRICS_FILE="${metricsDir}/postgresql_health.prom"
        METRICS_TEMP="$METRICS_FILE.tmp"
        cat > "$METRICS_TEMP" <<EOF
      # HELP postgresql_health PostgreSQL health status (1=healthy, 0=unhealthy)
      # TYPE postgresql_health gauge
      postgresql_health{instance="${instanceName}"} $STATUS
      # HELP postgresql_health_last_check_timestamp Last health check timestamp
      # TYPE postgresql_health_last_check_timestamp gauge
      postgresql_health_last_check_timestamp{instance="${instanceName}"} $(date +%s)
      EOF
        ${pkgs.coreutils}/bin/mv "$METRICS_TEMP" "$METRICS_FILE"
      fi

      echo "$(date -Iseconds): Health check: $MESSAGE"
    '';

  in {
    inherit walArchiveScript walRestoreScript baseBackupScript healthCheckScript;
  };
in
{
  inherit mkScripts;
}
