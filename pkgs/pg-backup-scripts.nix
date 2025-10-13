{ pkgs, ... }:

pkgs.stdenv.mkDerivation {
  pname = "pg-backup-scripts";
  version = "1.1.0"; # Version bump for new stateful approach

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin

    # Coordinated snapshot script that holds a PG connection open
    cat > $out/bin/pg-zfs-snapshot <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    # This script performs a ZFS snapshot of a PostgreSQL data directory
    # while holding a database connection open to ensure the backup is
    # consistent and contains the required backup_label file.

    # --- Configuration ---
    # The ZFS dataset containing the PostgreSQL PGDATA directory.
    # This should be passed as the first argument to the script.
    if [[ -z "${1:-}" ]]; then
        echo "ERROR: ZFS dataset must be provided as the first argument." >&2
        exit 1
    fi
    PG_DATASET="$1"
    # Sanoid uses a specific format, which we mimic for pruning compatibility.
    SNAPSHOT_NAME="${PG_DATASET}@autosnap_$(date -u +%Y-%m-%d_%H:%M:%S)_frequently"

    # --- Script Body ---
    # Use a temporary named pipe (FIFO) to communicate with a background psql process.
    FIFO=$(mktemp -u)
    mkfifo "$FIFO"
    trap 'rm -f "$FIFO"' EXIT

    echo "[$(date -Iseconds)] Starting coordinated PostgreSQL snapshot for ${PG_DATASET}..."

    # Start psql in the background, reading commands from our FIFO.
    # The session stays open as long as the FIFO is open for writing on our end.
    /run/current-system/sw/bin/runuser -u postgres -- \
        /run/current-system/sw/bin/psql -v ON_ERROR_STOP=1 --quiet -d postgres < "$FIFO" &
    PSQL_PID=$!

    # Ensure the background process is terminated on script exit/error.
    trap 'kill ${PSQL_PID} 2>/dev/null || true; rm -f "$FIFO"' EXIT

    # Open the FIFO for writing on file descriptor 3.
    # This will block until the background psql process starts reading from it.
    exec 3>"$FIFO"

    # --- Critical Section: Start, Sync, Snapshot, Stop ---

    # 1. Put PostgreSQL into backup mode.
    echo "[$(date -Iseconds)] Entering backup mode..."
    echo "SELECT pg_backup_start('zfs-snapshot', false);" >&3

    # 2. Force all OS filesystem buffers to disk. This is critical.
    echo "[$(date -Iseconds)] Syncing filesystems..."
    sync

    # 3. Take the atomic ZFS snapshot. This is the actual backup moment.
    echo "[$(date -Iseconds)] Creating snapshot: ${SNAPSHOT_NAME}"
    ${pkgs.zfs}/bin/zfs snapshot "${SNAPSHOT_NAME}"

    # 4. Take PostgreSQL out of backup mode.
    echo "[$(date -Iseconds)] Exiting backup mode..."
    echo "SELECT * FROM pg_backup_stop();" >&3

    # --- End Critical Section ---

    # Close the FIFO. This sends EOF to the psql process, causing it to exit.
    exec 3>&-

    # Wait for the psql process to terminate cleanly and check its exit code.
    if ! wait "$PSQL_PID"; then
        echo "ERROR: psql process exited with an error." >&2
        exit 1
    fi

    echo "[$(date -Iseconds)] Snapshot process for ${PG_DATASET} complete."
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
