{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "pg-backup-scripts";
  version = "1.0.1"; # Version bump to reflect changes

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin

    # Pre-snapshot script: pg_backup_start
    cat > $out/bin/pg-backup-start <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    # Put PostgreSQL into backup mode before ZFS snapshot
    # This creates a backup_label file that makes the snapshot a proper base backup
    # Note: This script is run as root by systemd (via "+" prefix in ExecStartPre)

    echo "[$(date -Iseconds)] Starting PostgreSQL backup mode for Sanoid snapshot..."

    # Use pg_backup_start (exclusive mode wrapper) with:
    # - Label: 'sanoid snapshot'
    # - Fast checkpoint: false (wait for checkpoint to complete for consistency)
    # This command creates the backup_label file in the PGDATA directory.
    if ! /run/current-system/sw/bin/runuser -u postgres -- /run/current-system/sw/bin/psql -v ON_ERROR_STOP=1 -d postgres -c "SELECT pg_backup_start('sanoid snapshot', false);" 2>&1; then
        echo "ERROR: Failed to start PostgreSQL backup mode" >&2
        exit 1
    fi

    # Force flush all filesystem buffers to disk to ensure the backup_label
    # file is physically present before the instantaneous ZFS snapshot.
    # The 'sleep' command is not a reliable guarantee; 'sync' is.
    echo "[$(date -Iseconds)] Forcing filesystem sync..."
    sync

    echo "[$(date -Iseconds)] PostgreSQL is in backup mode and filesystems are synced. Proceeding with snapshot."
    exit 0
    EOF

    # Post-snapshot script: pg_backup_stop
    cat > $out/bin/pg-backup-stop <<'EOF'
    #!/usr/bin/env bash
    set -uo pipefail # NOTE: -e is removed to handle exit codes manually

    # Take PostgreSQL out of backup mode after ZFS snapshot
    # This removes the backup_label file from the live system
    # Note: This script is run as root by systemd (via "+" prefix in ExecStartPost)

    echo "[$(date -Iseconds)] Ending PostgreSQL backup mode..."

    # Use pg_backup_stop. We must handle the case where the backup is already
    # stopped, as snapshots are instant. We capture stderr to check for the
    # specific "not in progress" message, which is an expected state.
    if output_and_stderr=$(/run/current-system/sw/bin/runuser -u postgres -- /run/current-system/sw/bin/psql -v ON_ERROR_STOP=1 -d postgres -c "SELECT * FROM pg_backup_stop();" 2>&1); then
        echo "[$(date -Iseconds)] PostgreSQL backup stopped successfully."
        # The output can be verbose, so only log it if needed for debugging
        # echo "Output: $output_and_stderr"
    elif echo "$output_and_stderr" | grep -q "backup is not in progress"; then
        echo "[$(date -Iseconds)] PostgreSQL backup was not in progress (this is expected with fast snapshots)."
    else
        echo "ERROR: pg_backup_stop failed with an unexpected error:" >&2
        echo "$output_and_stderr" >&2
        exit 1
    fi

    echo "[$(date -Iseconds)] PostgreSQL backup mode finished."
    exit 0
    EOF

    chmod +x $out/bin/pg-backup-start
    chmod +x $out/bin/pg-backup-stop
  '';

  meta = with pkgs.lib; {
    description = "PostgreSQL backup coordination scripts for ZFS snapshots";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
