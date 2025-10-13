{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "pg-backup-scripts";
  version = "1.2.0"; # Version bump for non-exclusive backup handling

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin

    # Coordinated snapshot script that holds a PG connection open
    cat > $out/bin/pg-zfs-snapshot <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    # This script performs a ZFS snapshot of a PostgreSQL data directory using
    # the modern non-exclusive backup API. It manually creates the backup_label
    # file, takes the snapshot, and cleans up, all while holding a single
    # database connection open.

    # --- Configuration ---
    # The ZFS dataset containing the PostgreSQL PGDATA directory.
    # This should be passed as the first argument to the script.
    if [[ -z "''${1:-}" ]]; then
        echo "ERROR: ZFS dataset must be provided as the first argument." >&2
        exit 1
    fi
    PG_DATASET="$1"
    # Sanoid uses a specific format, which we mimic for pruning compatibility.
    SNAPSHOT_NAME="''${PG_DATASET}@autosnap_$(date -u +%Y-%m-%d_%H:%M:%S)_frequently"

    # --- Script Body ---
    # Use two temporary named pipes (FIFOs) for bidirectional communication.
    FIFO_IN=$(mktemp -u)
    FIFO_OUT=$(mktemp -u)
    mkfifo "$FIFO_IN" "$FIFO_OUT"
    # Set a comprehensive trap to ensure FIFOs are always removed.
    trap 'rm -f "$FIFO_IN" "$FIFO_OUT"' EXIT

    echo "[$(date -Iseconds)] Starting coordinated PostgreSQL snapshot for ''${PG_DATASET}..."

    # Start psql in the background, reading from FIFO_IN and writing to FIFO_OUT.
    # -tA flags provide clean, script-friendly output (tuples-only, no-alignment).
    /run/current-system/sw/bin/runuser -u postgres -- \
        /run/current-system/sw/bin/psql -v ON_ERROR_STOP=1 --quiet -d postgres -tA \
        < "$FIFO_IN" > "$FIFO_OUT" &
    PSQL_PID=$!

    # Ensure the background process is terminated on script exit/error.
    trap 'kill ''${PSQL_PID} 2>/dev/null || true; rm -f "$FIFO_IN" "$FIFO_OUT"' EXIT

    # Open FIFO_IN for writing on FD 3, and FIFO_OUT for reading on FD 4.
    exec 3>"$FIFO_IN" 4<"$FIFO_OUT"

    # --- Critical Section: Query, Create Label, Snapshot, Cleanup, Stop ---

    # 1. Query for required metadata from within the persistent psql session.
    echo "[$(date -Iseconds)] Gathering backup metadata..."
    echo "SHOW data_directory;" >&3
    read -r PGDATA <&4

    echo "SELECT timeline_id FROM pg_control_checkpoint();" >&3
    read -r TIMELINE_ID <&4

    echo "SELECT checkpoint_lsn FROM pg_control_checkpoint();" >&3
    read -r CHECKPOINT_LSN <&4

    echo "SELECT pg_backup_start('zfs-snapshot', false);" >&3
    read -r LSN <&4

    LSN_QUOTED="'$LSN'"
    echo "SELECT pg_walfile_name($LSN_QUOTED);" >&3
    read -r WAL_FILE_NAME <&4

    BACKUP_LABEL_PATH="''${PGDATA}/backup_label"

    # 2. Construct and write the backup_label file as the 'postgres' user.
    # This file makes the snapshot a valid base backup instead of just crash-consistent.
    echo "[$(date -Iseconds)] Writing backup_label to ''${BACKUP_LABEL_PATH}..."
    LABEL_CONTENT=$(printf "START WAL LOCATION: %s (file %s)\nCHECKPOINT LOCATION: %s\nBACKUP METHOD: streamed\nBACKUP FROM: primary\nSTART TIME: %s\nLABEL: zfs-snapshot\nSTART TIMELINE: %s\n" \
        "''${LSN}" "''${WAL_FILE_NAME}" "''${CHECKPOINT_LSN}" "$(date -u +"%Y-%m-%d %H:%M:%S %Z")" "''${TIMELINE_ID}")

    /run/current-system/sw/bin/runuser -u postgres -- /run/current-system/sw/bin/bash -c "printf '%s' \"''${LABEL_CONTENT}\" > \"''${BACKUP_LABEL_PATH}\""

    # Update trap to ensure the backup_label is removed if the script fails.
    trap 'kill ''${PSQL_PID} 2>/dev/null || true; /run/current-system/sw/bin/runuser -u postgres -- rm -f "''${BACKUP_LABEL_PATH}"; rm -f "$FIFO_IN" "$FIFO_OUT"' EXIT

    # 3. Force all OS filesystem buffers to disk. This is critical.
    echo "[$(date -Iseconds)] Syncing filesystems..."
    sync

    # 4. Take the atomic ZFS snapshot. This is the actual backup moment.
    echo "[$(date -Iseconds)] Creating snapshot: ''${SNAPSHOT_NAME}"
    ${pkgs.zfs}/bin/zfs snapshot "''${SNAPSHOT_NAME}"

    # 5. Remove the temporary backup_label from the live filesystem. It now exists
    #    only within the ZFS snapshot, which is the desired state.
    echo "[$(date -Iseconds)] Removing temporary backup_label file..."
    /run/current-system/sw/bin/runuser -u postgres -- rm -f "''${BACKUP_LABEL_PATH}"

    # 6. Take PostgreSQL out of backup mode. This writes the 'backup end' WAL record.
    echo "[$(date -Iseconds)] Exiting backup mode..."
    echo "SELECT * FROM pg_backup_stop();" >&3
    # Read the multi-line output from the FIFO to prevent psql from blocking.
    while read -r -t 1 line <&4; do :; done

    # --- End Critical Section ---

    # Close the FIFOs. This sends EOF to the psql process, causing it to exit.
    exec 3>&-
    exec 4<&-

    # Wait for the psql process to terminate cleanly and check its exit code.
    if ! wait "$PSQL_PID"; then
        echo "ERROR: psql process exited with an error." >&2
        exit 1
    fi

    echo "[$(date -Iseconds)] Snapshot process for ''${PG_DATASET} complete."
    exit 0
    EOF

    chmod +x $out/bin/pg-zfs-snapshot
  '';

  meta = with pkgs.lib; {
    description = "A coordinated script for creating application-consistent PostgreSQL ZFS snapshots.";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
